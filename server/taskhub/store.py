"""Append-only event storage with process locking and recoverable projections."""

from __future__ import annotations

import copy
import fcntl
import hashlib
import json
import mimetypes
import os
import re
import stat
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from .common import (MAX_ATTACHMENT_BYTES, MAX_EVENT_BYTES, MAX_TOTAL_BLOB_BYTES,
                     TaskHubError, canonical, digest_bytes, text, timestamp, utc_now)
from . import domain

MAX_SNAPSHOT_BYTES = 32 * 1024 * 1024
MAX_GIT_FILE_BYTES = 32 * 1024 * 1024
CREATE_PREFIX = {"lane.created": "l_", "task.created": "t_", "decision.created": "d_",
                 "comment.added": "c_", "attachment.added": "a_"}


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def private_path(path: Path, *, directory: bool = False) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as exc:
        raise TaskHubError("E_INTEGRITY", f"必要なパスを読めない: {path.name}") from exc
    correct_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if not correct_type or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise TaskHubError("E_INTEGRITY", f"所有者・権限・ファイル種別が不正: {path.name}")
    return info


def read_regular(path: Path, limit: int, *, private: bool = True) -> bytes:
    if private:
        private_path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise TaskHubError("E_INPUT", "通常ファイルを指定する")
            if info.st_size > limit:
                raise TaskHubError("E_CAPACITY", f"ファイル上限 {limit} byteを超えた")
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            if len(data) > limit:
                raise TaskHubError("E_CAPACITY", "ファイル上限を超えた")
            if (info.st_size, info.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise TaskHubError("E_CONFLICT", "読み取り中にファイルが変更された")
            return data
    except OSError as exc:
        raise TaskHubError("E_INPUT", f"通常ファイルを読めない: {path.name}") from exc


def decode_json(data: bytes) -> Any:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("constant")))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise TaskHubError("E_INTEGRITY", "JSONが破損している") from exc


class Store:
    def __init__(self, data_dir: str | Path, lock_timeout: float = 30):
        original = Path(data_dir).expanduser().absolute()
        if original.is_symlink():
            raise TaskHubError("E_INTEGRITY", "データディレクトリにsymlinkは使用できない")
        self._original = original
        self.path = original.parent.resolve() / original.name
        self.snapshot_bytes = 0
        if not isinstance(lock_timeout, (int, float)) or not 0 <= lock_timeout <= 3600:
            raise TaskHubError("E_INPUT", "lock-timeoutは0〜3600秒")
        self.lock_timeout = lock_timeout
        self.events: list[dict] = []
        self.manifest: dict = {}
        self._locked = False

    def _check_ancestors(self) -> None:
        for path in (self._original, *self._original.parents):
            if path.is_symlink():
                # macOS exposes its system temporary directories through these aliases.
                system_alias = (sys.platform == "darwin" and str(path) in {"/tmp", "/var"}
                                and path.lstat().st_uid == 0
                                and path.resolve() == Path("/private") / path.name)
                if not system_alias:
                    raise TaskHubError("E_INTEGRITY", "データ領域にsymlinkは使用できない")

    def mkdir(self, path: Path) -> None:
        if not path.exists():
            self.mkdir(path.parent)
            try:
                path.mkdir(mode=0o700)
            except FileExistsError:
                pass
        private_path(path, directory=True)
        fsync_dir(path)
        fsync_dir(path.parent)

    def atomic(self, path: Path, data: bytes, *, replace: bool = True) -> None:
        temp = self.path / ".taskhub" / ("tmp-" + uuid.uuid4().hex)
        try:
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            if replace:
                if path.is_symlink():
                    raise TaskHubError("E_INTEGRITY", "symlinkの置換を拒否した")
                os.replace(temp, path)
            else:
                os.link(temp, path, follow_symlinks=False)
            fsync_dir(path.parent)
        finally:
            if temp.exists():
                temp.unlink()

    def read_local(self, name: str, default=None):
        if not re.fullmatch(r"[a-z-]+\.json", name):
            raise TaskHubError("E_INPUT", "不正なローカル設定名")
        path = self.path / ".taskhub" / name
        if not path.exists() and not path.is_symlink():
            return default
        return decode_json(read_regular(path, MAX_EVENT_BYTES))

    def write_local(self, name: str, value) -> None:
        if not re.fullmatch(r"[a-z-]+\.json", name):
            raise TaskHubError("E_INPUT", "不正なローカル設定名")
        self.atomic(self.path / ".taskhub" / name, canonical(value))

    @contextmanager
    def lock(self):
        if self._locked:
            raise TaskHubError("E_CONFLICT", "ストアlockの再入を拒否した")
        self._check_ancestors()
        private_path(self.path, directory=True)
        private_path(self.path / ".taskhub", directory=True)
        lock_path = self.path / ".taskhub" / "lock"
        if lock_path.exists() or lock_path.is_symlink():
            private_path(lock_path)
        try:
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError as exc:
            raise TaskHubError("E_INTEGRITY", "lockファイルを安全に開けない") from exc
        try:
            private_path(lock_path)
            deadline = time.monotonic() + self.lock_timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TaskHubError("E_LOCK_TIMEOUT", "別プロセスがデータを使用中")
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            self._locked = True
            yield self
        finally:
            self._locked = False
            os.close(fd)

    def initialize(self, actor: str, repo: str | None = None, branch: str = "main") -> dict:
        from .sync import initialize_git, validate_branch, validate_repo
        text(actor, "actor", limit=128, single_line=True)
        validate_branch(branch)
        if repo is not None:
            validate_repo(repo)
        self._check_ancestors()
        if self.path.exists():
            if not self.path.is_dir() or any(self.path.iterdir()):
                raise TaskHubError("E_INPUT", "initには空の専用ディレクトリを指定する")
            private_path(self.path, directory=True)
        else:
            missing = []
            ancestor = self.path
            while not ancestor.exists():
                missing.append(ancestor)
                ancestor = ancestor.parent
            for directory in reversed(missing):
                directory.mkdir(mode=0o700)
                fsync_dir(directory)
                fsync_dir(directory.parent)
        self.mkdir(self.path / ".taskhub")
        with self.lock():
            self.mkdir(self.path / "events")
            self.mkdir(self.path / "blobs")
            self.mkdir(self.path / "blobs" / "sha256")
            manifest = {"schema_version": 1, "store_id": str(uuid.uuid4()), "created_at": utc_now()}
            self.atomic(self.path / "manifest.json", canonical(manifest), replace=False)
            self.write_local("config.json", {"repo": repo, "branch": branch,
                             "max_attachment_bytes": MAX_ATTACHMENT_BYTES,
                             "max_total_blob_bytes": MAX_TOTAL_BLOB_BYTES,
                             "initialized_by": actor})
            snapshot = domain.empty_snapshot(manifest)
            self.atomic(self.path / "snapshot.json", canonical(snapshot))
            self.snapshot_bytes = len(canonical(snapshot))
            old_mask = os.umask(0o077)
            try:
                initialize_git(self)
            finally:
                os.umask(old_mask)
            return snapshot

    def _layout(self) -> None:
        allowed = {"manifest.json", "snapshot.json", "events", "blobs", ".taskhub", ".git"}
        for path in self.path.iterdir():
            if path.name not in allowed:
                raise TaskHubError("E_INTEGRITY", f"データ領域に想定外のパス: {path.name}")
            private_path(path, directory=path.name in {"events", "blobs", ".taskhub", ".git"})
        for dirname in ("events", "blobs", "blobs/sha256"):
            private_path(self.path / dirname, directory=True)
        for path in (self.path / "blobs").iterdir():
            if path.name != "sha256":
                raise TaskHubError("E_INTEGRITY", "不正なblobディレクトリ")

    def blob_paths(self) -> list[Path]:
        paths = []
        for prefix in sorted((self.path / "blobs" / "sha256").iterdir()):
            if not re.fullmatch(r"[0-9a-f]{2}", prefix.name):
                raise TaskHubError("E_INTEGRITY", "不正なblob prefix")
            private_path(prefix, directory=True)
            for path in sorted(prefix.iterdir()):
                if not re.fullmatch(r"[0-9a-f]{64}", path.name) or not path.name.startswith(prefix.name):
                    raise TaskHubError("E_INTEGRITY", "不正なblobファイル名")
                private_path(path)
                paths.append(path)
        return paths

    def load(self, verify_blobs: bool = False, repair: bool = True) -> dict:
        if not self._locked:
            raise TaskHubError("E_CONFLICT", "loadにはlockが必要")
        self._layout()
        manifest = decode_json(read_regular(self.path / "manifest.json", MAX_EVENT_BYTES))
        try:
            if (set(manifest) != {"schema_version", "store_id", "created_at"} or
                    type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1 or
                    str(uuid.UUID(manifest["store_id"])) != manifest["store_id"]):
                raise ValueError()
            timestamp(manifest["created_at"])
        except (KeyError, TypeError, ValueError, AttributeError, TaskHubError) as exc:
            raise TaskHubError("E_INTEGRITY", "manifestが不正または未対応version") from exc
        self.manifest = manifest
        snapshot = domain.empty_snapshot(manifest)
        self.events = []
        seen_ids, seen_requests = set(), set()
        hashes = [None]
        for seq, path in enumerate(sorted((self.path / "events").iterdir()), 1):
            if path.name != f"{seq:020d}.json":
                raise TaskHubError("E_INTEGRITY", "イベントの欠番または想定外ファイル")
            raw = read_regular(path, MAX_EVENT_BYTES)
            event = decode_json(raw)
            try:
                expected = {"schema_version", "seq", "id", "request_id", "request_hash", "actor",
                            "occurred_at", "prev_hash", "type", "payload"}
                if (set(event) != expected or type(event["schema_version"]) is not int or
                        event["schema_version"] != 1 or type(event["seq"]) is not int or
                        event["seq"] != seq or event["prev_hash"] != hashes[-1] or canonical(event) != raw):
                    raise ValueError()
                for key in ("id", "request_id"):
                    if str(uuid.UUID(event[key])) != event[key]:
                        raise ValueError()
                if not re.fullmatch(r"[0-9a-f]{64}", event["request_hash"]):
                    raise ValueError()
                if event["id"] in seen_ids or event["request_id"] in seen_requests:
                    raise ValueError()
                if not isinstance(event["payload"], dict):
                    raise ValueError()
                if not isinstance(event["type"], str):
                    raise ValueError()
                request_payload = copy.deepcopy(event["payload"])
                if event["type"] in CREATE_PREFIX:
                    request_payload.pop("id", None)
                fingerprint = digest_bytes(canonical({"type": event["type"], "payload": request_payload}))
                if fingerprint != event["request_hash"]:
                    raise ValueError()
                domain.apply_event(snapshot, event)
            except (ValueError, TypeError, KeyError, AttributeError, TaskHubError) as exc:
                raise TaskHubError("E_INTEGRITY", f"イベント{seq}の内容・参照・hashが不正") from exc
            seen_ids.add(event["id"])
            seen_requests.add(event["request_id"])
            hashes.append(digest_bytes(raw))
            self.events.append(event)
            snapshot.update(last_event_seq=seq, last_event_hash=hashes[-1], generated_at=event["occurred_at"])
        for key in ("lanes", "tasks", "decisions"):
            snapshot[key].sort(key=lambda item: item["id"])
        for key in ("comments", "attachments"):
            snapshot[key].sort(key=lambda item: (item["event_seq"], item["id"]))
        paths = {p.relative_to(self.path).as_posix(): p for p in self.blob_paths()}
        for attachment in snapshot["attachments"]:
            path = paths.get(attachment["blob_path"])
            if path is None or path.stat().st_size != attachment["size_bytes"]:
                raise TaskHubError("E_INTEGRITY", "参照blobの欠落またはサイズ不一致")
        if verify_blobs:
            for path in paths.values():
                if digest_bytes(read_regular(path, MAX_GIT_FILE_BYTES)) != path.name:
                    raise TaskHubError("E_INTEGRITY", "blobのhash不一致")
        serialized = canonical(snapshot)
        self.snapshot_bytes = len(serialized)
        if len(serialized) > MAX_SNAPSHOT_BYTES:
            raise TaskHubError("E_CAPACITY", "snapshot容量上限を超えた")
        current_path = self.path / "snapshot.json"
        current = None
        if current_path.exists():
            raw = read_regular(current_path, MAX_SNAPSHOT_BYTES)
            current = decode_json(raw)
            if not isinstance(current, dict):
                raise TaskHubError("E_INTEGRITY", "snapshot形式が不正")
            old_seq = current.get("last_event_seq")
            if (type(old_seq) is not int or old_seq < 0 or old_seq > len(self.events) or
                    current.get("store_id") != manifest["store_id"] or
                    current.get("last_event_hash") != hashes[old_seq]):
                raise TaskHubError("E_INTEGRITY", "snapshotと正本の履歴が一致しない（巻戻し・改変の疑い）")
        if current != snapshot and repair:
            self.atomic(current_path, serialized)
        return snapshot

    def read(self) -> dict:
        with self.lock():
            return self.load()

    def canonical_paths(self) -> list[str]:
        return ["manifest.json", "snapshot.json"] + [
            f"events/{e['seq']:020d}.json" for e in self.events
        ] + [p.relative_to(self.path).as_posix() for p in self.blob_paths()]

    def _config(self) -> dict:
        config = self.read_local("config.json", {})
        if not isinstance(config, dict):
            raise TaskHubError("E_INPUT", "ローカル設定が不正")
        for key, default, upper in (("max_attachment_bytes", MAX_ATTACHMENT_BYTES, MAX_GIT_FILE_BYTES),
                                    ("max_total_blob_bytes", MAX_TOTAL_BLOB_BYTES, MAX_TOTAL_BLOB_BYTES)):
            value = config.get(key, default)
            lower = 1 if key == "max_attachment_bytes" else 0
            if type(value) is not int or not lower <= value <= upper:
                raise TaskHubError("E_INPUT", f"{key} は{lower}〜{upper} byte")
            config[key] = value
        return config

    def _stage_attachment(self, payload: dict, source: str | Path) -> tuple[dict, bytes]:
        config = self._config()
        path = Path(source)
        filename = text(path.name, "filename", limit=255, single_line=True)
        if any(c in filename for c in "/\\") or filename in {".", ".."}:
            raise TaskHubError("E_INPUT", "添付のファイル名が不正")
        data = read_regular(path, config["max_attachment_bytes"], private=False)
        sha = digest_bytes(data)
        payload.update(filename=filename, media_type=mimetypes.guess_type(filename)[0] or "application/octet-stream",
                       size_bytes=len(data), sha256=sha, blob_path=f"blobs/sha256/{sha[:2]}/{sha}")
        blob = self.path / payload["blob_path"]
        used = sum(p.stat().st_size for p in self.blob_paths())
        if blob.exists():
            if read_regular(blob, MAX_GIT_FILE_BYTES) != data:
                raise TaskHubError("E_INTEGRITY", "同じhashの既存blobが不一致")
        elif used + len(data) > config["max_total_blob_bytes"]:
            raise TaskHubError("E_CAPACITY", "blob合計容量上限を超えた")
        return payload, data

    def mutate(self, event_type: str, payload: dict, actor: str, *, request_id: str | None = None,
               if_revision: int | None = None, source: str | Path | None = None) -> dict:
        text(actor, "actor", limit=128, single_line=True)
        if request_id is None:
            request_id = str(uuid.uuid4())
        try:
            if str(uuid.UUID(request_id)) != request_id:
                raise ValueError()
        except (ValueError, TypeError, AttributeError) as exc:
            raise TaskHubError("E_INPUT", "request-idは標準UUID文字列") from exc
        with self.lock():
            snapshot = self.load()
            payload = copy.deepcopy(payload)
            if if_revision is not None:
                if type(if_revision) is not int or if_revision < 1:
                    raise TaskHubError("E_INPUT", "if-revisionは1以上の整数")
                payload["if_revision"] = if_revision
            blob_data = None
            if event_type == "attachment.added":
                if source is None:
                    raise TaskHubError("E_INPUT", "添付ファイルを指定する")
                payload, blob_data = self._stage_attachment(payload, source)
            fingerprint = digest_bytes(canonical({"type": event_type, "payload": payload}))
            for previous in self.events:
                if previous["request_id"] == request_id:
                    if previous["request_hash"] != fingerprint or previous["actor"] != actor:
                        raise TaskHubError("E_CONFLICT", "request-idが別の要求またはactorに使われた")
                    return {"id": previous["payload"]["id"], "event_seq": previous["seq"],
                            "request_id": request_id, "replayed": True}
            if event_type in CREATE_PREFIX:
                if "id" in payload:
                    raise TaskHubError("E_INPUT", "新規IDはサーバーが割り当てる")
                payload["id"] = CREATE_PREFIX[event_type] + uuid.uuid4().hex
            event = {"schema_version": 1, "seq": len(self.events) + 1, "id": str(uuid.uuid4()),
                     "request_id": request_id, "request_hash": fingerprint, "actor": actor,
                     "occurred_at": utc_now(), "prev_hash": snapshot["last_event_hash"],
                     "type": event_type, "payload": payload}
            candidate = copy.deepcopy(snapshot)
            domain.apply_event(candidate, event)
            raw = canonical(event)
            if len(raw) > MAX_EVENT_BYTES:
                raise TaskHubError("E_CAPACITY", "イベント容量上限を超えた")
            candidate.update(last_event_seq=event["seq"], last_event_hash=digest_bytes(raw),
                             generated_at=event["occurred_at"])
            for key in ("lanes", "tasks", "decisions"):
                candidate[key].sort(key=lambda item: item["id"])
            serialized = canonical(candidate)
            if len(serialized) > MAX_SNAPSHOT_BYTES:
                raise TaskHubError("E_CAPACITY", "snapshotの32MiB上限を超えるため変更を拒否した")
            if blob_data is not None:
                blob = self.path / payload["blob_path"]
                try:
                    if not blob.exists():
                        self.mkdir(blob.parent)
                        self.atomic(blob, blob_data, replace=False)
                    for directory in (blob.parent, blob.parent.parent, self.path / "blobs", self.path):
                        fsync_dir(directory)
                except OSError as exc:
                    raise TaskHubError("E_IO", "添付の永続化に失敗した。イベントは未確定") from exc
            event_path = self.path / "events" / f"{event['seq']:020d}.json"
            try:
                self.atomic(event_path, raw, replace=False)
                self.atomic(self.path / "snapshot.json", serialized)
            except OSError as exc:
                if event_path.exists():
                    raise TaskHubError("E_COMMITTED_VIEW_STALE", "イベント確定済み。rebuildまたは同じrequest-idで再実行する",
                                       committed_event_seq=event["seq"], entity_id=payload.get("id")) from exc
                raise TaskHubError("E_IO", "イベント保存に失敗した。変更は未確定") from exc
            self.snapshot_bytes = len(serialized)
            return {"id": payload["id"], "event_seq": event["seq"], "request_id": request_id,
                    "replayed": False, "capacity_warning": len(serialized) >= MAX_SNAPSHOT_BYTES * 0.8}

    def fsck(self) -> dict:
        with self.lock():
            snapshot = self.load(verify_blobs=True, repair=False)
            path = self.path / "snapshot.json"
            matches = path.exists() and read_regular(path, MAX_SNAPSHOT_BYTES) == canonical(snapshot)
            referenced = {a["blob_path"] for a in snapshot["attachments"]}
            blobs = self.blob_paths()
            orphans = [p.relative_to(self.path).as_posix() for p in blobs
                       if p.relative_to(self.path).as_posix() not in referenced]
            if not matches:
                raise TaskHubError("E_INTEGRITY", "snapshotが未生成または古い。rebuildを実行する")
            return {"events": len(self.events), "blobs": len(blobs), "orphan_blobs": orphans,
                    "blob_bytes": sum(p.stat().st_size for p in blobs),
                    "snapshot_bytes": len(canonical(snapshot)),
                    "capacity_warning": len(canonical(snapshot)) >= MAX_SNAPSHOT_BYTES * 0.8}

    def history(self, kind: str, entity_id: str) -> list[dict]:
        with self.lock():
            snapshot = self.load()
            domain.find(snapshot, kind, entity_id)
            comments = {c["id"] for c in snapshot["comments"]
                        if c["target_type"] == kind and c["target_id"] == entity_id}
            result = []
            for event in self.events:
                payload = event["payload"]
                direct = payload.get("id") == entity_id or payload.get("target_id") == entity_id
                indirect = payload.get("target_id") in comments
                resumed = (kind == "task" and event["type"] == "decision.applied" and payload.get("resume") and
                           domain.find(snapshot, "decision", payload["id"])["task_id"] == entity_id)
                if direct or indirect or resumed:
                    result.append(event)
            return result
