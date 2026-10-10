"""Private GitHub backup for a single authoritative, append-only data store."""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

from .common import MAX_EVENT_BYTES, TaskHubError, text, timestamp, utc_now

MAX_FILE_BYTES = 32 * 1024 * 1024
COMMAND_TIMEOUT = 30
SYNC_TIMEOUT = 180
PUSH_ATTEMPTS = 3
_OID = re.compile(r"[0-9a-f]{40}\Z")
_EVENT = re.compile(r"events/([0-9]{20})\.json\Z")
_BLOB = re.compile(r"blobs/sha256/([0-9a-f]{2})/([0-9a-f]{64})\Z")
_GIT_SETTINGS = (
    "core.hooksPath=/dev/null", "commit.gpgSign=false", "tag.gpgSign=false",
    "core.fsmonitor=false", "core.attributesFile=/dev/null",
    "core.excludesFile=/dev/null", "core.autocrlf=false", "core.safecrlf=false",
    "core.fileMode=false", "core.sshCommand=/usr/bin/false",
    "credential.helper=", "credential.helper=!gh auth git-credential",
    "credential.interactive=false", "http.followRedirects=false",
    "http.sslVerify=true", "protocol.allow=never", "protocol.https.allow=always",
    "fetch.fsckObjects=true", "transfer.fsckObjects=true", "receive.fsckObjects=true",
    "gc.auto=0", "maintenance.auto=false",
)
_LOCAL_SETTINGS = {
    "core.repositoryformatversion": {"0"},
    "core.filemode": {"true", "false"},
    "core.bare": {"false"},
    "core.logallrefupdates": {"true"},
    "core.ignorecase": {"true", "false"},
    "core.precomposeunicode": {"true", "false"},
    "core.hookspath": {"/dev/null"},
    "commit.gpgsign": {"false"},
}


def validate_repo(repo: Any) -> str:
    """Accept an OWNER/NAME slug, never a URL, host, or option."""
    if not isinstance(repo, str) or len(repo) > 140 or repo.count("/") != 1:
        raise TaskHubError("E_INPUT", "repo は GitHub.com の OWNER/NAME で指定する")
    owner, name = repo.split("/")
    if (not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner)
            or "--" in owner
            or not re.fullmatch(r"[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}", name)
            or name in {".", ".."} or name.lower().endswith(".git")):
        raise TaskHubError("E_INPUT", "repo は有効な OWNER/NAME で指定する（URL不可）")
    return repo.lower()


def validate_branch(branch: Any) -> str:
    """Validate a short branch name before constructing a full ref."""
    if (not isinstance(branch, str) or len(branch) > 200
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", branch)
            or branch == "HEAD" or branch.startswith("refs/")
            or ".." in branch or "//" in branch
            or any(not part or part.startswith((".", "-")) or part.endswith((".", ".lock"))
                   for part in branch.split("/"))):
        raise TaskHubError("E_INPUT", "branch は有効な短い Git branch 名で指定する")
    return branch


def _environment() -> dict[str, str]:
    # gh retains its existing credentials; Git configuration and helper overrides do not.
    keep = ("PATH", "HOME", "XDG_CONFIG_HOME", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN",
            "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env.update({
        "LANG": "C", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false", "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_ATTR_NOSYSTEM": "1", "GIT_PAGER": "cat", "PAGER": "cat",
        "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
    })
    return env


def _run(argv: list[str], *, cwd: Path, env: dict[str, str], timeout: float,
         input: bytes | None = None) -> subprocess.CompletedProcess:
    """Subprocess seam; tests replace only gh and the fixed HTTPS transport here."""
    with subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          shell=False, start_new_session=True, umask=0o077) as process:
        try:
            stdout, stderr = process.communicate(input, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


class _Commands:
    def __init__(self, path: Path):
        self.path = path
        self.deadline = time.monotonic() + SYNC_TIMEOUT

    def run(self, argv: list[str], *, input: bytes | None = None) -> subprocess.CompletedProcess:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TaskHubError("E_TIMEOUT", "同期の制限時間180秒を超えた")
        try:
            result = _run(argv, cwd=self.path, env=_environment(),
                          timeout=min(COMMAND_TIMEOUT, remaining), input=input)
        except subprocess.TimeoutExpired:
            raise TaskHubError("E_TIMEOUT", "同期コマンドが制限時間を超えた") from None
        except OSError:
            code = "E_AUTH" if argv[0] == "gh" else "E_SYNC"
            raise TaskHubError(code, "git と gh の導入・gh auth login --hostname github.com を確認する") from None
        if time.monotonic() > self.deadline:
            raise TaskHubError("E_TIMEOUT", "同期の制限時間180秒を超えた")
        return result

    def git(self, *args: str, input: bytes | None = None,
            check: bool = True) -> subprocess.CompletedProcess:
        argv = ["git", "--no-pager", "--literal-pathspecs"]
        for setting in _GIT_SETTINGS:
            argv.extend(("-c", setting))
        result = self.run(argv + list(args), input=input)
        if check and result.returncode:
            raise TaskHubError("E_SYNC", "専用データ Git リポジトリの検証・操作に失敗した")
        return result


class _Transient(Exception):
    pass


def _transport_error(result: subprocess.CompletedProcess) -> None:
    error = result.stderr.lower()
    if any(marker in error for marker in (b"authentication failed", b"could not read username",
                                         b"could not read password", b"terminal prompts disabled",
                                         b"error: 401", b"error: 403", b"http 401", b"http 403",
                                         b"permission denied", b"permission to", b"access denied",
                                         b"invalid username or token", b"repository not found")):
        raise TaskHubError("E_AUTH", "GitHub 認証・private repo 権限を確認する: gh auth login --hostname github.com")
    raise _Transient()


def _safe_file(path: Path, limit: int = MAX_FILE_BYTES) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                    or stat.S_IMODE(before.st_mode) & 0o077):
                raise TaskHubError("E_SYNC", "Git 同期対象は所有するprivateな通常ファイルに限定する")
            if before.st_size > limit:
                raise TaskHubError("E_CAPACITY", f"Git 同期対象が容量上限 {limit} byteを超えた")
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            if len(data) > limit:
                raise TaskHubError("E_CAPACITY", "Git 同期対象が読み取り中に容量上限を超えた")
            if (len(data) != before.st_size
                    or (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                    != (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
                raise TaskHubError("E_SYNC", "Git 同期対象のサイズ超過または読込中の変更を検出した")
            return data
    except OSError:
        raise TaskHubError("E_SYNC", "Git 同期対象の安全な読込に失敗した") from None


def _directory(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError:
        raise TaskHubError("E_SYNC", "専用 Git ディレクトリが存在しない") from None
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise TaskHubError("E_SYNC", "Git ディレクトリの symlink・所有者不一致・広い権限を拒否した")


def _validate_git(path: Path) -> None:
    _directory(path)
    root = path / ".git"
    _directory(root)
    def walk_error(error):
        raise error
    try:
        for folder, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
            for name in dirs + files:
                item = Path(folder) / name
                info = item.lstat()
                if (not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))
                        or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077):
                    raise TaskHubError("E_SYNC", "Git 内の symlink・特殊ファイル・所有者不一致・広い権限を拒否した")
                relative = item.relative_to(root).as_posix()
                if relative in {"commondir", "gitdir", "config.worktree", "shallow", "info/grafts",
                                "info/attributes", "objects/info/alternates", "objects/info/http-alternates",
                                "refs/replace"}:
                    raise TaskHubError("E_SYNC", "共有・置換・外部参照を含む Git リポジトリは同期できない")
                if relative.startswith("objects/"):
                    parts = relative.split("/")
                    if parts[1] not in {"info", "pack"}:
                        valid = (len(parts) == 2 and stat.S_ISDIR(info.st_mode)
                                 and re.fullmatch(r"[0-9a-f]{2}", parts[1]))
                        valid = valid or (len(parts) == 3 and stat.S_ISREG(info.st_mode)
                                          and re.fullmatch(r"[0-9a-f]{2}", parts[1])
                                          and re.fullmatch(r"[0-9a-f]{38}", parts[2]))
                        if not valid:
                            raise TaskHubError("E_SYNC", "不正な Git object パスを拒否した")
                    elif parts[1] == "pack" and len(parts) > 2:
                        if (len(parts) != 3 or not stat.S_ISREG(info.st_mode)
                                or not re.fullmatch(r"pack-[0-9a-f]{40}\.(pack|idx|rev|bitmap|keep)", parts[2])):
                            raise TaskHubError("E_SYNC", "不正な Git pack パスを拒否した")
    except OSError:
        raise TaskHubError("E_SYNC", "Git ディレクトリを安全に検証できない") from None
    try:
        config = _safe_file(root / "config", 65536).decode("utf-8")
    except UnicodeError:
        raise TaskHubError("E_SYNC", "Git 設定が不正") from None
    section = None
    seen = set()
    for raw in config.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        header = re.fullmatch(r"\[(core|commit)\]", line, re.IGNORECASE)
        if header:
            section = header[1].lower()
            continue
        entry = re.fullmatch(r"([A-Za-z][A-Za-z0-9]*)\s*=\s*([^\s#;]+)", line)
        key = section + "." + entry[1].lower() if section and entry else ""
        if (not entry or key not in _LOCAL_SETTINGS or key in seen
                or entry[2].lower() not in _LOCAL_SETTINGS[key]):
            raise TaskHubError("E_SYNC", "専用 Git の許可外設定を拒否した。URL書換え・helper・include は使用不可")
        seen.add(key)
    if not {"core.repositoryformatversion", "core.bare"}.issubset(seen):
        raise TaskHubError("E_SYNC", "専用 Git の必須設定がない")
    if _safe_file(root / "HEAD", 1024) != b"ref: refs/heads/main\n":
        raise TaskHubError("E_CONFLICT", "専用 Git のローカル branch は main に固定する")


def initialize_git(store: Any) -> None:
    """Initialize only the new local data repository; never contact GitHub."""
    path = Path(store.path)
    _directory(path)
    if os.path.lexists(path / ".git"):
        raise TaskHubError("E_SYNC", "既存 Git リポジトリは初期化しない")
    commands = _Commands(path)
    commands.git("init", "--initial-branch=main", "--template=", ".")
    commands.git("config", "--local", "core.hooksPath", "/dev/null")
    commands.git("config", "--local", "commit.gpgSign", "false")
    try:
        info = path / ".git" / "info"
        info.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(info / "exclude", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(b"/.taskhub/\n")
            stream.flush()
            os.fsync(stream.fileno())
        fd = os.open(info, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        raise TaskHubError("E_SYNC", "専用 Git のローカル除外設定を保存できない") from None
    _validate_git(path)


def _canonical_file(path: str) -> bool:
    if path in {"manifest.json", "snapshot.json"}:
        return True
    event = _EVENT.fullmatch(path)
    if event:
        return int(event[1]) > 0
    blob = _BLOB.fullmatch(path)
    return bool(blob and blob[1] == blob[2][:2])


def _canonical_directory(path: str) -> bool:
    return path in {"events", "blobs", "blobs/sha256"} or bool(
        re.fullmatch(r"blobs/sha256/[0-9a-f]{2}", path))


def _oid(value: str) -> str:
    if not _OID.fullmatch(value) or value == "0" * 40:
        raise TaskHubError("E_SYNC", "Git commit/object ID が不正")
    return value


def _decode(data: bytes) -> str:
    try:
        return data.decode("ascii")
    except UnicodeError:
        raise TaskHubError("E_SYNC", "Git メタデータが不正") from None


def _state(store: Any) -> dict:
    state = store.read_local("sync-state.json", default={})
    if not isinstance(state, dict):
        raise TaskHubError("E_SYNC", "ローカル同期状態が不正")
    if not state:
        return {}
    required = {"repo", "repo_id", "branch", "last_remote_commit", "last_successful_commit",
                "last_successful_sync", "last_synced_event_seq"}
    if set(state) != required or type(state["repo_id"]) is not int or state["repo_id"] <= 0:
        raise TaskHubError("E_SYNC", "ローカル同期 pin が不正")
    try:
        validate_repo(state["repo"])
        validate_branch(state["branch"])
        for key in ("last_remote_commit", "last_successful_commit"):
            if state[key] is not None:
                if not isinstance(state[key], str):
                    raise ValueError()
                _oid(state[key])
        if state["last_successful_sync"] is not None:
            timestamp(state["last_successful_sync"])
        if (type(state["last_synced_event_seq"]) is not int or state["last_synced_event_seq"] < 0
                or (state["last_successful_commit"] is None) != (state["last_successful_sync"] is None)
                or (state["last_successful_commit"] is not None and state["last_remote_commit"] is None)):
            raise ValueError()
    except (TaskHubError, ValueError):
        raise TaskHubError("E_SYNC", "ローカル同期状態が不正") from None
    return dict(state)


def _configuration(store: Any, state: dict, repo: Any, branch: Any) -> tuple[str | None, str, int, int]:
    config = store.read_local("config.json", default={})
    if not isinstance(config, dict):
        raise TaskHubError("E_INPUT", "ローカル設定が不正")
    selected_repo = repo if repo is not None else state.get("repo") or config.get("repo")
    selected_branch = branch if branch is not None else state.get("branch", config.get("branch", "main"))
    if selected_repo is not None:
        selected_repo = validate_repo(selected_repo)
    selected_branch = validate_branch(selected_branch)
    if state and (selected_repo != state["repo"] or selected_branch != state["branch"]):
        raise TaskHubError("E_CONFLICT", "同期済み repo/branch の変更は拒否する。別データディレクトリで管理者復旧する")
    maximum = config.get("max_attachment_bytes", 10 * 1024 * 1024)
    total = config.get("max_total_blob_bytes", 1024 * 1024 * 1024)
    if (type(maximum) is not int or not 1 <= maximum <= MAX_FILE_BYTES
            or type(total) is not int or not 0 <= total <= 1024 * 1024 * 1024):
        raise TaskHubError("E_INPUT", "添付上限は1byte〜32MiB、合計上限は0〜1GiBで設定する")
    return selected_repo, selected_branch, maximum, total


def _working_files(store: Any, maximum: int, total_maximum: int = 1024 * 1024 * 1024) -> dict[str, str]:
    paths = store.canonical_paths()
    if (not isinstance(paths, list) or any(not isinstance(p, str) or not _canonical_file(p) for p in paths)
            or len(set(paths)) != len(paths) or not {"manifest.json", "snapshot.json"}.issubset(paths)):
        raise TaskHubError("E_SYNC", "Git 登録対象に不正な正規データパスがある")
    result = {}
    blob_bytes = 0
    for name in paths:
        path = Path(store.path) / name
        for parent in path.parents:
            if parent == Path(store.path):
                break
            _directory(parent)
        is_blob = _BLOB.fullmatch(name)
        limit = min(maximum, MAX_FILE_BYTES) if is_blob else (MAX_EVENT_BYTES if _EVENT.fullmatch(name) else MAX_FILE_BYTES)
        data = _safe_file(path, limit)
        if is_blob:
            blob_bytes += len(data)
            if blob_bytes > total_maximum:
                raise TaskHubError("E_CAPACITY", "Git 同期対象の blob 合計容量が設定上限を超えた")
        result[name] = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    return result


def _tree(commands: _Commands, commit: str) -> dict[str, str]:
    result = {}
    output = commands.git("ls-tree", "-r", "-t", "-z", "--full-tree", _oid(commit)).stdout
    for raw in output.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, name = _decode(raw).split("\t", 1)
            mode, kind, oid = metadata.split(" ")
        except ValueError:
            raise TaskHubError("E_SYNC", "Git tree が不正") from None
        _oid(oid)
        if mode == "040000" and kind == "tree" and _canonical_directory(name):
            continue
        if mode != "100644" or kind != "blob" or not _canonical_file(name) or name in result:
            raise TaskHubError("E_CONFLICT", "Git 履歴に正規データ以外のパス・モードがある")
        result[name] = oid
    if not {"manifest.json", "snapshot.json"}.issubset(result):
        raise TaskHubError("E_CONFLICT", "Git 履歴の manifest/snapshot が欠落している")
    events = sorted(name for name in result if _EVENT.fullmatch(name))
    if any(name != f"events/{index:020d}.json" for index, name in enumerate(events, 1)):
        raise TaskHubError("E_CONFLICT", "Git 履歴のイベント列に欠番がある")
    return result


def _index(commands: _Commands, working: dict[str, str]) -> dict[str, str]:
    result = {}
    for raw in commands.git("ls-files", "--stage", "-z").stdout.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, name = _decode(raw).split("\t", 1)
            mode, oid, stage = metadata.split(" ")
        except ValueError:
            raise TaskHubError("E_SYNC", "Git index が不正") from None
        if mode != "100644" or stage != "0" or name not in working or name in result:
            raise TaskHubError("E_CONFLICT", "Git index に余分なファイル・競合・不正モードがある")
        result[name] = _oid(oid)
    return result


def _ancestor(commands: _Commands, older: str, newer: str) -> bool:
    result = commands.git("merge-base", "--is-ancestor", _oid(older), _oid(newer), check=False)
    if result.returncode not in (0, 1):
        raise TaskHubError("E_CONFLICT", "既知の Git 履歴を検証できない")
    return result.returncode == 0


def _inspect(commands: _Commands, working: dict[str, str], state: dict) -> tuple[str | None, dict, dict]:
    _validate_git(commands.path)
    refs = _decode(commands.git("for-each-ref", "--format=%(refname)").stdout).splitlines()
    if any(ref != "refs/heads/main" for ref in refs):
        raise TaskHubError("E_CONFLICT", "専用 Git に未知の ref がある")
    index = _index(commands, working)
    if not refs:
        if state.get("last_successful_commit"):
            raise TaskHubError("E_CONFLICT", "同期済みローカル Git 履歴が消失した")
        return None, {}, index
    head = _oid(_decode(commands.git("rev-parse", "--verify", "HEAD^{commit}").stdout).strip())
    commands.git("fsck", "--full", "--no-reflogs", "--no-dangling")
    previous_commit = None
    previous_tree = {}
    objects = set()
    history = _decode(commands.git("rev-list", "--reverse", "--topo-order", "--parents", head).stdout)
    for line in history.splitlines():
        parts = line.split(" ")
        if len(parts) != (2 if previous_commit else 1) or (previous_commit and parts[1] != previous_commit):
            raise TaskHubError("E_CONFLICT", "Git 履歴の merge・非線形な履歴を拒否した")
        commit = _oid(parts[0])
        tree = _tree(commands, commit)
        for name, oid in tree.items():
            if name != "snapshot.json" and working.get(name) != oid:
                raise TaskHubError("E_CONFLICT", "Git 記録済み manifest/events/blob の変更・削除を拒否した")
        for name, oid in previous_tree.items():
            if name != "snapshot.json" and tree.get(name) != oid:
                raise TaskHubError("E_CONFLICT", "Git 履歴内の manifest/events/blob の変更・削除を拒否した")
        objects.update(tree.values())
        previous_commit, previous_tree = commit, tree
    if previous_commit != head:
        raise TaskHubError("E_CONFLICT", "Git 履歴が不正")
    for name, oid in previous_tree.items():
        if name != "snapshot.json" and index.get(name) != oid:
            raise TaskHubError("E_CONFLICT", "Git index の履歴変更・削除を拒否した")
    sizes = commands.git("cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
                         input="".join(oid + "\n" for oid in sorted(objects)).encode("ascii")).stdout
    lines = _decode(sizes).splitlines()
    if len(lines) != len(objects):
        raise TaskHubError("E_SYNC", "Git object のサイズを検証できない")
    for line in lines:
        parts = line.split(" ")
        if (len(parts) != 3 or parts[0] not in objects or parts[1] != "blob"
                or not parts[2].isdigit() or int(parts[2]) > MAX_FILE_BYTES):
            raise TaskHubError("E_CONFLICT", "Git 履歴に32MiB超過または不正な object がある")
    successful = state.get("last_successful_commit")
    if successful and not _ancestor(commands, successful, head):
        raise TaskHubError("E_CONFLICT", "ローカル Git 履歴の巻戻し・分岐を拒否した")
    return head, previous_tree, index


def _private(commands: _Commands, repo: str) -> int:
    result = commands.run(["gh", "api", "--hostname", "github.com", "repos/" + repo])
    if result.returncode:
        raise TaskHubError("E_AUTH", "private repo と認証を確認する: gh auth login --hostname github.com")
    def unique_pairs(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError()
            value[key] = item
        return value
    try:
        if len(result.stdout) > 1024 * 1024:
            raise ValueError()
        value = json.loads(result.stdout, object_pairs_hook=unique_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError, RecursionError):
        raise TaskHubError("E_PRIVATE", "GitHub private 状態を確認できない。送信しない") from None
    if (not isinstance(value, dict) or value.get("private") is not True
            or value.get("visibility", "private") != "private"):
        raise TaskHubError("E_PRIVATE", "private=true の GitHub repo だけに同期できる。private repo を指定する")
    if (type(value.get("id")) is not int or value["id"] <= 0
            or not isinstance(value.get("full_name"), str) or value["full_name"].lower() != repo):
        raise TaskHubError("E_CONFLICT", "GitHub repo の ID・名前が一致しない")
    return value["id"]


def _remote(commands: _Commands, url: str, branch: str,
            observed: Callable[[str], None]) -> str | None:
    ref = "refs/heads/" + branch
    result = commands.git("ls-remote", "--exit-code", "--refs", url, ref, check=False)
    if result.returncode == 2 and not result.stdout:
        return None
    if result.returncode:
        _transport_error(result)
    lines = _decode(result.stdout).splitlines()
    if len(lines) != 1 or lines[0].split("\t")[1:] != [ref]:
        raise TaskHubError("E_SYNC", "remote branch の応答が不正")
    advertised = _oid(lines[0].split("\t")[0])
    observed(advertised)
    result = commands.git("fetch", "--no-tags", "--no-recurse-submodules", "--no-auto-maintenance",
                          url, ref, check=False)
    if result.returncode:
        _transport_error(result)
    fetched = _oid(_decode(commands.git("rev-parse", "--verify", "FETCH_HEAD^{commit}").stdout).strip())
    if advertised != fetched and not _ancestor(commands, advertised, fetched):
        raise TaskHubError("E_CONFLICT", "remote branch が観測と fetch の間に巻き戻された")
    return fetched


def _write_state(store: Any, state: dict) -> None:
    try:
        store.write_local("sync-state.json", state)
    except OSError:
        raise TaskHubError("E_SYNC", "同期状態の保存に失敗した。ローカル履歴を保持し sync を再実行する") from None


def _save_success(store: Any, state: dict, head: str) -> dict:
    state.update(last_remote_commit=head, last_successful_commit=head,
                 last_successful_sync=utc_now(), last_synced_event_seq=len(store.events))
    _write_state(store, state)
    return {"repo": state["repo"], "repo_id": state["repo_id"], "branch": state["branch"],
            "head": head, "last_remote_commit": head, "last_successful_commit": head,
            "last_successful_sync": state["last_successful_sync"],
            "pending_count": 0, "pending_events": 0, "dirty": False, "pending": False}


def sync(store: Any, actor: str, repo: str | None = None, branch: str | None = None) -> dict:
    """Validate, commit canonical files, and push only a private fast-forward backup."""
    commands = _Commands(Path(store.path))
    actor = text(actor, "actor", limit=128, single_line=True)
    if "<" in actor or ">" in actor:
        raise TaskHubError("E_INPUT", "Git author の actor に山括弧は使用できない")
    with store.lock():
        store.load(verify_blobs=True)
        state = _state(store)
        repo, branch, maximum, total_maximum = _configuration(store, state, repo, branch)
        if repo is None:
            raise TaskHubError("E_INPUT", "sync --repo OWNER/NAME で既存 private repo を指定する")
        working = _working_files(store, maximum, total_maximum)
        head, tree, index = _inspect(commands, working, state)
        first_observation = not state
        url = "https://github.com/" + repo + ".git"
        for attempt in range(PUSH_ATTEMPTS):
            try:
                repo_id = _private(commands, repo)
                if state and repo_id != state["repo_id"]:
                    raise TaskHubError("E_CONFLICT", "pin 済み GitHub repo ID が変更された")
                if not state:
                    state = {"repo": repo, "repo_id": repo_id, "branch": branch,
                             "last_remote_commit": None, "last_successful_commit": None,
                             "last_successful_sync": None, "last_synced_event_seq": 0}
                    _write_state(store, state)
                def observed(commit):
                    if state["last_remote_commit"] is None:
                        state["last_remote_commit"] = commit
                        _write_state(store, state)
                remote = _remote(commands, url, branch, observed)
                known_remote = state["last_remote_commit"]
                if known_remote and (remote is None or not _ancestor(commands, known_remote, remote)):
                    raise TaskHubError("E_CONFLICT", "remote branch の消失・巻戻し・履歴書換えを拒否した")
                if remote:
                    state["last_remote_commit"] = remote
                    _write_state(store, state)
                    if first_observation or head is None or not _ancestor(commands, remote, head):
                        raise TaskHubError("E_CONFLICT", "未知の nonempty remote・先行・分岐は取り込まない。管理者復旧が必要")
                first_observation = False
                if attempt:
                    working = _working_files(store, maximum, total_maximum)
                    head, tree, index = _inspect(commands, working, state)
                if working != tree:
                    commands.git("add", "--pathspec-from-file=-", "--pathspec-file-nul",
                                 input=b"\0".join(name.encode("ascii") for name in sorted(working)) + b"\0")
                    if _index(commands, working) != working:
                        raise TaskHubError("E_CONFLICT", "Git stage 内容が検証済み正規データと一致しない")
                    commands.git("-c", "user.name=" + actor, "-c", "user.email=taskhub@localhost",
                                 "commit", "--no-gpg-sign", "--no-verify", "-m", "TaskHub sync")
                    head = _oid(_decode(commands.git("rev-parse", "--verify", "HEAD^{commit}").stdout).strip())
                    tree = working
                elif index != working:
                    raise TaskHubError("E_CONFLICT", "Git index と正規データが一致しない")
                if _private(commands, repo) != state["repo_id"]:
                    raise TaskHubError("E_CONFLICT", "push 前に GitHub repo ID が変更された")
                if remote == head:
                    return _save_success(store, state, head)
                result = commands.git("push", "--porcelain", "--no-verify", url,
                                      _oid(head) + ":refs/heads/" + branch, check=False)
                if result.returncode:
                    _transport_error(result)
                return _save_success(store, state, head)
            except _Transient:
                if attempt == PUSH_ATTEMPTS - 1:
                    raise TaskHubError("E_SYNC", "GitHub 通信または通常 push が3回失敗した。ローカル履歴は保持した") from None
        raise TaskHubError("E_SYNC", "同期に失敗した")


def status(store: Any) -> dict:
    """Read local pending state without network, staging, or committing."""
    commands = _Commands(Path(store.path))
    with store.lock():
        store.load(verify_blobs=True)
        state = _state(store)
        repo, branch, maximum, total_maximum = _configuration(store, state, None, None)
        working = _working_files(store, maximum, total_maximum)
        head, tree, index = _inspect(commands, working, state)
        dirty = working != tree or index != tree
        count = len(store.events) - state.get("last_synced_event_seq", 0)
        if count < 0:
            raise TaskHubError("E_CONFLICT", "同期済みイベント数からの巻戻しを拒否した")
        return {"repo": repo, "repo_id": state.get("repo_id"), "branch": branch, "head": head,
                "last_remote_commit": state.get("last_remote_commit"),
                "last_successful_commit": state.get("last_successful_commit"),
                "last_successful_sync": state.get("last_successful_sync"),
                "pending_count": count, "pending_events": count, "dirty": dirty,
                "pending": dirty or head != state.get("last_successful_commit")}
