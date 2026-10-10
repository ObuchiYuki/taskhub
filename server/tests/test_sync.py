"""Real local Git integration; every GitHub request and transport is intercepted."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

from taskhub import sync as synchronization
from taskhub.common import TaskHubError, canonical, digest_bytes
from taskhub.store import Store

_REAL_RUN = synchronization._run
_URL = "https://github.com/owner/private-data.git"
_SECRET = "do-not-print-test-token"


class InputTests(unittest.TestCase):
    def test_strict_repository_slugs(self):
        self.assertEqual(synchronization.validate_repo("Owner/Private_Data"), "owner/private_data")
        for value in (None, "", "--help", "owner", "owner/repo/extra", "https://github.com/o/r",
                      "git@github.com:o/r", "owner/repo.git", "-owner/repo", "owner/-repo",
                      "owner/..", "owner/repo\n", "owner/repo?token=x", "owner/repo%2fextra",
                      "owner\\repo", "o--o/repo", "owner/repo\x00"):
            with self.subTest(value=value), self.assertRaises(TaskHubError) as caught:
                synchronization.validate_repo(value)
            self.assertEqual(caught.exception.code, "E_INPUT")

    def test_strict_short_branches(self):
        for value in ("main", "backup/2026-10", "release.v1", "a_b"):
            self.assertEqual(synchronization.validate_branch(value), value)
        for value in (None, "", "HEAD", "--all", "refs/heads/main", "x..y", "a@{1}", "a b",
                      "a\\b", "a:b", "a*", "a?", "a[", "a\n", "a/", "a//b", "a/.b",
                      "a/b.lock", "a/b.", "a/-b", "/main", "a" * 201):
            with self.subTest(value=value), self.assertRaises(TaskHubError) as caught:
                synchronization.validate_branch(value)
            self.assertEqual(caught.exception.code, "E_INPUT")


@unittest.skipUnless(shutil.which("git"), "git is required for local integration tests")
class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(prefix="taskhub-sync-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.environment = mock.patch.dict(os.environ, {"HOME": str(self.home),
                                                       "GH_CONFIG_DIR": str(self.home / "gh")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.remote = self.root / "remote.git"
        self.raw_git(self.root, "init", "--bare", "--initial-branch=main", "--template=", str(self.remote))
        self.calls = []
        self.gh_calls = 0
        self.pushes = 0
        self.fetches = 0
        self.repo_id = 1234
        self.private = True
        self.gh_behavior = None
        self.push_behavior = None
        self.network_behavior = None
        self.patcher = mock.patch.object(synchronization, "_run", side_effect=self.transport)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.store = Store(self.root / "data")
        self.store.initialize("fixture-author", repo="Owner/Private-Data")
        self.calls.clear()

    def raw_git(self, cwd, *args, input=None, check=True):
        self.assertFalse(any(str(arg).startswith(("http:", "https:", "ssh:")) for arg in args))
        env = synchronization._environment()
        result = subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
             "-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", *args],
            cwd=cwd, env=env, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=10, check=False, umask=0o077)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        return result

    def transport(self, argv, *, cwd, env, timeout, input=None):
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, synchronization.COMMAND_TIMEOUT)
        self.calls.append((list(argv), dict(env), timeout, input))
        if argv[0] == "gh":
            self.gh_calls += 1
            self.assertEqual(argv, ["gh", "api", "--hostname", "github.com", "repos/owner/private-data"])
            if self.gh_behavior:
                response = self.gh_behavior(self.gh_calls, argv)
                if response is not None:
                    return response
            return self.response(argv, stdout=canonical({"id": self.repo_id, "private": self.private,
                                                        "full_name": "Owner/Private-Data"}))
        self.assertEqual(argv[0], "git")
        self.assertNotIn("reset", argv)
        self.assertNotIn("rebase", argv)
        self.assertNotIn("merge", argv)
        self.assertNotIn("--force-with-lease", argv)
        if "push" in argv:
            self.assertNotIn("--force", argv)
            self.assertFalse(any(arg.startswith("+") for arg in argv))
            self.pushes += 1
            if self.push_behavior:
                response = self.push_behavior(self.pushes, argv, cwd, env, timeout, input)
                if response is not None:
                    return response
        if "fetch" in argv:
            self.fetches += 1
        if self.network_behavior and any(word in argv for word in ("fetch", "ls-remote")):
            response = self.network_behavior(argv)
            if response is not None:
                return response
        return self.local_transport(argv, cwd=cwd, env=env, timeout=timeout, input=input)

    def local_transport(self, argv, *, cwd, env, timeout, input=None):
        rewritten = []
        for arg in argv:
            if arg.startswith("https://"):
                self.assertEqual(arg, _URL)
                rewritten.append(str(self.remote))
            else:
                rewritten.append(arg)
        rewritten[1:1] = ["-c", "protocol.file.allow=always"]
        return _REAL_RUN(rewritten, cwd=cwd, env=env, timeout=timeout, input=input)

    @staticmethod
    def response(argv, returncode=0, stdout=b"", stderr=b""):
        return subprocess.CompletedProcess(argv, returncode, stdout, stderr)

    def error(self, code, action=None):
        with self.assertRaises(TaskHubError) as caught:
            (action or (lambda: synchronization.sync(self.store, "agent-日本語")))()
        self.assertEqual(caught.exception.code, code)
        self.assertNotIn(_SECRET, str(caught.exception))
        return caught.exception

    def lane(self, name="lane"):
        return self.store.mutate("lane.created", {"name": name}, "fixture-author")["id"]

    def successful(self):
        return synchronization.sync(self.store, "agent-日本語")

    def remote_head(self, branch="main"):
        result = self.raw_git(self.remote, "rev-parse", "--verify", "refs/heads/" + branch, check=False)
        return result.stdout.decode().strip() if result.returncode == 0 else None

    def remote_commit(self, parent=None, *, update=True):
        current = self.remote_head()
        tree = self.raw_git(self.remote, "rev-parse", current + "^{tree}").stdout.strip().decode()
        args = ["commit-tree", tree]
        if parent:
            args.extend(("-p", parent))
        commit = self.raw_git(self.remote, *args, input=b"External fixture commit\n").stdout.decode().strip()
        if update:
            self.raw_git(self.remote, "update-ref", "refs/heads/main", commit)
        return commit

    def local_commit(self):
        self.raw_git(self.store.path, "add", "--all")
        self.raw_git(self.store.path, "commit", "--no-verify", "-m", "Local fixture history")
        return self.raw_git(self.store.path, "rev-parse", "HEAD").stdout.decode().strip()

    def orphan_blob(self, content=b"immutable attachment"):
        sha = digest_bytes(content)
        path = self.store.path / f"blobs/sha256/{sha[:2]}/{sha}"
        path.parent.mkdir(mode=0o700, exist_ok=True)
        path.write_bytes(content)
        path.chmod(0o600)
        return path

    def test_initialize_is_local_main_and_excludes_private_state(self):
        self.assertEqual((self.store.path / ".git/HEAD").read_text(), "ref: refs/heads/main\n")
        self.assertIn("/.taskhub/", (self.store.path / ".git/info/exclude").read_text())
        config = (self.store.path / ".git/config").read_text().lower()
        self.assertIn("hookspath = /dev/null", config)
        self.assertIn("gpgsign = false", config)
        self.assertIsNone(self.remote_head())
        self.assertEqual(self.gh_calls, 0)
        self.error("E_SYNC", lambda: synchronization.initialize_git(self.store))

    def test_empty_remote_then_append_fast_forward_and_noop(self):
        first = self.successful()
        self.assertEqual(first["repo_id"], 1234)
        self.assertEqual(first["head"], self.remote_head())
        self.assertEqual(self.gh_calls, 2)
        author = self.raw_git(self.store.path, "show", "-s", "--format=%an <%ae>", "HEAD").stdout.decode().strip()
        self.assertEqual(author, "agent-日本語 <taskhub@localhost>")
        self.lane()
        pending = synchronization.status(self.store)
        self.assertEqual(pending["pending_count"], 1)
        self.assertTrue(pending["dirty"])
        second = self.successful()
        self.assertNotEqual(first["head"], second["head"])
        self.raw_git(self.remote, "merge-base", "--is-ancestor", first["head"], second["head"])
        paths = self.raw_git(self.remote, "ls-tree", "-r", "--name-only", "HEAD").stdout.decode().splitlines()
        self.assertEqual(set(paths), {"manifest.json", "snapshot.json", "events/00000000000000000001.json"})
        pushes = self.pushes
        self.assertEqual(self.successful()["head"], second["head"])
        self.assertEqual(self.pushes, pushes)
        self.assertFalse(synchronization.status(self.store)["pending"])

    def test_real_attachment_is_committed_only_at_its_canonical_path(self):
        lane = self.lane()
        task = self.store.mutate("task.created", {"lane_id": lane, "title": "attachment"}, "fixture")["id"]
        source = self.root / "image.bin"
        source.write_bytes(b"\x00\xffprivate-file")
        self.store.mutate("attachment.added", {"target_type": "task", "target_id": task,
                                               "description": "private evidence"}, "fixture", source=source)
        result = self.successful()
        snapshot = json.loads(self.raw_git(self.remote, "show", result["head"] + ":snapshot.json").stdout)
        attachment = snapshot["attachments"][0]
        uploaded = self.raw_git(self.remote, "show", result["head"] + ":" + attachment["blob_path"]).stdout
        self.assertEqual(uploaded, source.read_bytes())
        self.assertEqual(result["pending_count"], 0)

    def test_status_is_local_only_without_history_or_index_mutation(self):
        self.lane()
        before = {p: (self.store.path / p).read_bytes() for p in ("manifest.json", "events/00000000000000000001.json")}
        self.calls.clear()
        first = synchronization.status(self.store)
        self.assertIsNone(first["last_successful_sync"])
        self.assertEqual(first["pending_events"], 1)
        self.assertTrue(first["pending"])
        self.assertFalse((self.store.path / ".git/index").exists())
        self.assertFalse((self.store.path / ".taskhub/sync-state.json").exists())
        self.assertFalse(any(args[0] == "gh" or "fetch" in args or "push" in args or "commit" in args
                             for args, _, _, _ in self.calls))
        for p, data in before.items():
            self.assertEqual((self.store.path / p).read_bytes(), data)

    def test_status_repairs_snapshot_without_git_commit(self):
        self.lane()
        result = self.successful()
        (self.store.path / "snapshot.json").unlink()
        status = synchronization.status(self.store)
        self.assertFalse(status["dirty"])
        self.assertEqual(status["head"], result["head"])
        self.assertTrue((self.store.path / "snapshot.json").exists())

    def test_status_tracks_unpushed_commits_and_pending_events(self):
        self.lane()
        self.push_behavior = lambda n, *args: self.response(args[0], 1, stderr=b"temporary failure")
        self.error("E_SYNC")
        status = synchronization.status(self.store)
        self.assertFalse(status["dirty"])
        self.assertTrue(status["pending"])
        self.assertEqual(status["pending_count"], 1)
        self.assertIsNone(status["last_successful_sync"])
        self.assertIsNotNone(status["head"])

    def test_load_is_locked_and_verifies_blobs(self):
        original = self.store.load
        def loaded(*args, **kwargs):
            self.assertTrue(self.store._locked)
            self.assertEqual(kwargs, {"verify_blobs": True})
            return original(*args, **kwargs)
        with mock.patch.object(self.store, "load", side_effect=loaded) as load:
            self.successful()
            synchronization.status(self.store)
            self.assertEqual(load.call_count, 2)
        self.assertFalse(self.store._locked)

    def test_missing_repository_is_local_configuration_error(self):
        self.store.write_local("config.json", {"branch": "main"})
        self.error("E_INPUT")
        self.assertEqual(self.gh_calls, 0)

    def test_public_repository_fails_before_fetch_stage_or_push(self):
        self.private = False
        self.error("E_PRIVATE")
        self.assertEqual(self.gh_calls, 1)
        self.assertEqual(self.fetches, 0)
        self.assertEqual(self.pushes, 0)
        self.assertFalse(any("ls-remote" in args or "add" in args for args, _, _, _ in self.calls))
        self.assertFalse((self.store.path / ".taskhub/sync-state.json").exists())

    def test_private_must_be_literal_true(self):
        for value in (1, "true", None, False):
            with self.subTest(value=value):
                self.gh_behavior = lambda n, args: self.response(args, stdout=canonical(
                    {"id": 1234, "private": value, "full_name": "owner/private-data"}))
                self.error("E_PRIVATE")
        self.assertEqual(self.pushes, 0)
        self.assertEqual(self.fetches, 0)

    def test_private_is_checked_again_immediately_before_push(self):
        def visibility(n, args):
            if n == 2:
                return self.response(args, stdout=canonical({"id": 1234, "private": False,
                                                            "full_name": "owner/private-data"}))
        self.gh_behavior = visibility
        self.error("E_PRIVATE")
        self.assertEqual(self.gh_calls, 2)
        self.assertEqual(self.pushes, 0)
        self.assertIsNone(self.remote_head())
        self.assertEqual(self.store.read_local("sync-state.json")["repo_id"], 1234)

    def test_identity_and_branch_are_pinned(self):
        self.successful()
        previous = self.gh_calls
        self.error("E_CONFLICT", lambda: synchronization.sync(self.store, "actor", repo="other/repo"))
        self.error("E_CONFLICT", lambda: synchronization.sync(self.store, "actor", branch="other"))
        self.assertEqual(self.gh_calls, previous)
        self.repo_id = 5678
        pushes = self.pushes
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, pushes)

    def test_explicit_initial_branch_remains_pinned_without_repeating_flag(self):
        result = synchronization.sync(self.store, "actor", branch="backups/main")
        self.assertEqual(self.remote_head("backups/main"), result["head"])
        self.assertIsNone(self.remote_head())
        self.assertEqual(synchronization.status(self.store)["branch"], "backups/main")
        self.assertEqual(self.successful()["head"], result["head"])

    def test_repo_identity_is_pinned_before_empty_remote_push_retry(self):
        def failure(n, args, *unused):
            self.assertEqual(self.store.read_local("sync-state.json")["repo_id"], 1234)
            self.repo_id = 9999
            return self.response(args, 1, stderr=b"temporary rejection")
        self.push_behavior = failure
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)
        self.assertEqual(self.store.read_local("sync-state.json")["repo_id"], 1234)

    def test_gh_identity_name_and_id_are_validated(self):
        for value in ({"id": True, "private": True, "full_name": "owner/private-data"},
                      {"id": 0, "private": True, "full_name": "owner/private-data"},
                      {"id": 1234, "private": True, "full_name": "other/repo"}):
            with self.subTest(value=value):
                self.gh_behavior = lambda n, args: self.response(args, stdout=canonical(value))
                self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 0)

    def test_invalid_api_response_is_sanitized(self):
        self.gh_behavior = lambda n, args: self.response(args, stdout=_SECRET.encode())
        self.error("E_PRIVATE")
        self.assertEqual(self.gh_calls, 1)

    def test_ambiguous_or_nonfinite_api_json_is_rejected(self):
        for response in (b'{"id":1234,"private":false,"private":true,"full_name":"owner/private-data"}',
                         b'{"id":1234,"private":true,"full_name":"owner/private-data","extra":NaN}',
                         b'{"id":1234,"private":true,"visibility":"internal","full_name":"owner/private-data"}'):
            with self.subTest(response=response):
                self.gh_behavior = lambda n, args: self.response(args, stdout=response)
                self.error("E_PRIVATE")
        self.assertEqual(self.pushes, 0)
        self.assertEqual(self.fetches, 0)

    def test_auth_failure_does_not_retry_or_expose_command_output(self):
        self.gh_behavior = lambda n, args: self.response(args, 1, stderr=_SECRET.encode())
        self.error("E_AUTH")
        self.assertEqual(self.gh_calls, 1)
        self.assertEqual(self.pushes, 0)

    def test_push_auth_failure_does_not_retry(self):
        self.push_behavior = lambda n, args, *unused: self.response(
            args, 1, stderr=b"fatal: Authentication failed " + _SECRET.encode())
        self.error("E_AUTH")
        self.assertEqual(self.pushes, 1)

    def test_push_retries_at_most_three_with_private_and_ref_revalidation(self):
        self.push_behavior = lambda n, args, *unused: self.response(args, 1, stderr=_SECRET.encode())
        self.error("E_SYNC")
        self.assertEqual(self.pushes, 3)
        self.assertEqual(self.gh_calls, 6)
        self.assertEqual(sum("ls-remote" in args for args, _, _, _ in self.calls), 3)
        self.assertEqual(sum("commit" in args for args, _, _, _ in self.calls), 1)
        self.assertIsNone(self.remote_head())

    def test_interrupted_successful_push_is_recognized_on_retry(self):
        def interrupted(n, args, cwd, env, timeout, input):
            if n == 1:
                result = self.local_transport(args, cwd=cwd, env=env, timeout=timeout, input=input)
                self.assertEqual(result.returncode, 0)
                return self.response(args, 1, stderr=b"connection lost after server accepted")
        self.push_behavior = interrupted
        result = self.successful()
        self.assertEqual(result["head"], self.remote_head())
        self.assertEqual(self.pushes, 1)
        self.assertEqual(self.gh_calls, 4)

    def test_interrupted_success_state_write_is_recovered_next_sync(self):
        original = self.store.write_local
        def interrupted(name, value):
            if name == "sync-state.json" and value.get("last_successful_sync"):
                raise OSError("fixture interrupted state persistence")
            return original(name, value)
        with mock.patch.object(self.store, "write_local", side_effect=interrupted):
            self.error("E_SYNC")
        head = self.remote_head()
        self.assertIsNotNone(head)
        self.assertIsNone(self.store.read_local("sync-state.json")["last_remote_commit"])
        result = self.successful()
        self.assertEqual(result["head"], head)
        self.assertEqual(self.pushes, 1)

    def test_remote_ahead_and_divergence_never_change_local_authority(self):
        first = self.successful()
        ahead = self.remote_commit(first["head"])
        before = (self.store.path / "snapshot.json").read_bytes()
        self.error("E_CONFLICT")
        self.assertEqual(self.remote_head(), ahead)
        self.assertEqual(self.raw_git(self.store.path, "rev-parse", "HEAD").stdout.decode().strip(), first["head"])
        self.assertEqual((self.store.path / "snapshot.json").read_bytes(), before)
        self.assertEqual(self.store.read_local("sync-state.json")["last_remote_commit"], ahead)
        self.lane()
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_remote_divergence_after_retry_stops_immediately(self):
        first = self.successful()
        self.lane()
        def diverged(n, args, *unused):
            self.remote_commit(first["head"])
            return self.response(args, 1, stderr=b"non-fast-forward")
        self.push_behavior = diverged
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 2)

    def test_remote_rewind_is_rejected_even_when_it_is_a_local_ancestor(self):
        first = self.successful()
        self.lane()
        second = self.successful()
        self.raw_git(self.remote, "update-ref", "refs/heads/main", first["head"])
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 2)
        self.assertEqual(self.store.read_local("sync-state.json")["last_remote_commit"], second["head"])

    def test_remote_unrelated_rewrite_is_rejected(self):
        first = self.successful()
        unrelated = self.remote_commit()
        self.assertNotEqual(unrelated, first["head"])
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_known_remote_branch_deletion_is_not_recreated(self):
        self.successful()
        self.raw_git(self.remote, "update-ref", "-d", "refs/heads/main")
        self.error("E_CONFLICT")
        self.assertIsNone(self.remote_head())
        self.assertEqual(self.pushes, 1)

    def test_unknown_nonempty_remote_is_never_imported_on_first_sync(self):
        self.successful()
        old_remote = self.remote_head()
        second = Store(self.root / "second")
        second.initialize("fixture", repo="owner/private-data")
        self.error("E_CONFLICT", lambda: synchronization.sync(second, "fixture"))
        self.assertEqual(self.remote_head(), old_remote)
        self.assertFalse((second.path / ".git/refs/heads/main").exists())
        self.assertEqual(second.read_local("sync-state.json")["last_remote_commit"], old_remote)
        self.raw_git(self.remote, "update-ref", "-d", "refs/heads/main")
        self.error("E_CONFLICT", lambda: synchronization.sync(second, "fixture"))

    def test_failed_initial_fetch_still_pins_observed_remote_history(self):
        first = self.successful()
        second = Store(self.root / "second")
        second.initialize("fixture", repo="owner/private-data")
        self.network_behavior = lambda args: self.response(args, 1, stderr=b"temporary fetch failure") if "fetch" in args else None
        self.error("E_SYNC", lambda: synchronization.sync(second, "fixture"))
        self.assertEqual(second.read_local("sync-state.json")["last_remote_commit"], first["head"])
        self.network_behavior = None
        self.raw_git(self.remote, "update-ref", "-d", "refs/heads/main")
        self.error("E_CONFLICT", lambda: synchronization.sync(second, "fixture"))
        self.assertEqual(self.pushes, 1)

    def test_ref_rewind_between_advertisement_and_fetch_is_rejected(self):
        first = self.successful()
        self.lane()
        self.successful()
        def rewind(args):
            if "fetch" in args:
                self.raw_git(self.remote, "update-ref", "refs/heads/main", first["head"])
        self.network_behavior = rewind
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 2)

    def test_last_remote_observation_survives_failure_before_push(self):
        first = self.successful()
        self.lane()
        local = self.local_commit()
        self.raw_git(self.store.path, "push", str(self.remote), local + ":refs/heads/main")
        baseline_calls = self.gh_calls
        def turned_public(n, args):
            if n == baseline_calls + 2:
                return self.response(args, stdout=canonical({"id": 1234, "private": False,
                                                            "full_name": "owner/private-data"}))
        self.gh_behavior = turned_public
        self.error("E_PRIVATE")
        self.assertEqual(self.store.read_local("sync-state.json")["last_remote_commit"], local)
        self.assertEqual(self.store.read_local("sync-state.json")["last_successful_commit"], first["head"])
        self.gh_behavior = None
        self.raw_git(self.remote, "update-ref", "refs/heads/main", first["head"])
        self.error("E_CONFLICT")

    def test_inherited_git_configuration_and_global_rewrites_are_ignored(self):
        marker = self.root / "exfiltrated"
        bad_remote = self.root / "wrong.git"
        (self.home / ".gitconfig").write_text(
            f'[url "{bad_remote}"]\n\tinsteadOf = {self.remote}\n'
            f'[credential]\n\thelper = !touch {marker}\n'
            f'[core]\n\tsshCommand = touch {marker}\n[commit]\n\tgpgSign = true\n')
        inherited = {"GIT_DIR": str(bad_remote), "GIT_WORK_TREE": str(self.root),
                     "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.sshCommand",
                     "GIT_CONFIG_VALUE_0": "touch " + str(marker), "GIT_SSH_COMMAND": "touch " + str(marker),
                     "GIT_CONFIG_PARAMETERS": "invalid " + _SECRET,
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(bad_remote),
                     "GIT_OBJECT_DIRECTORY": str(bad_remote), "GIT_TRACE": str(marker),
                     "GIT_ASKPASS": str(marker), "GH_HOST": "attacker.invalid", "GH_DEBUG": "api",
                     "GH_TOKEN": _SECRET, "HTTP_PROXY": "http://attacker.invalid"}
        with mock.patch.dict(os.environ, inherited):
            result = self.successful()
        self.assertEqual(result["head"], self.remote_head())
        self.assertFalse(marker.exists())
        for argv, env, _, _ in self.calls:
            self.assertNotIn(_SECRET, " ".join(argv))
            self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
            self.assertEqual(env["GIT_CONFIG_SYSTEM"], "/dev/null")
            self.assertEqual(env["GIT_CONFIG_NOSYSTEM"], "1")
            self.assertEqual(env["GH_HOST"], "github.com")
            for key in inherited.keys() - {"GIT_ASKPASS", "GH_HOST", "GH_TOKEN"}:
                self.assertNotIn(key, env)
            if argv[0] == "git":
                self.assertIn("credential.helper=", argv)
                self.assertIn("credential.helper=!gh auth git-credential", argv)
                self.assertIn("http.followRedirects=false", argv)
                self.assertIn("protocol.allow=never", argv)

    def test_local_configuration_cannot_redirect_or_execute(self):
        path = self.store.path / ".git/config"
        original = path.read_text()
        injected = ('[url "https://attacker.invalid/"]\n insteadOf = https://github.com/\n',
                    '[remote "origin"]\n url = https://attacker.invalid/\n pushurl = https://attacker.invalid/\n',
                    '[credential]\n helper = !echo ' + _SECRET + '\n',
                    '[core]\n sshCommand = echo ' + _SECRET + '\n',
                    '[core]\n hooksPath = /tmp/attacker\n',
                    '[include]\n path = /tmp/attacker\n',
                    '[extensions]\n worktreeConfig = true\n',
                    '[filter "secret"]\n clean = echo ' + _SECRET + '\n')
        for value in injected:
            with self.subTest(value=value):
                path.write_text(original + value)
                self.error("E_SYNC")
        path.write_text(original)
        self.assertEqual(self.gh_calls, 0)
        self.assertEqual(self.calls, [])

    def test_hooks_are_not_executed(self):
        directory = self.store.path / ".git/hooks"
        directory.mkdir(mode=0o700)
        marker = self.root / "hook-ran"
        for hook in ("pre-commit", "commit-msg", "post-commit", "pre-push"):
            path = directory / hook
            path.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 7\n")
            path.chmod(0o700)
        self.successful()
        self.assertFalse(marker.exists())

    def test_symlink_git_config_or_index_is_rejected_before_git(self):
        path = self.store.path / ".git/config"
        target = self.root / "config"
        path.rename(target)
        path.symlink_to(target)
        self.error("E_SYNC")
        self.assertEqual(self.calls, [])
        path.unlink()
        target.rename(path)
        index = self.store.path / ".git/index"
        index.symlink_to(self.root / "elsewhere")
        self.error("E_SYNC")
        self.assertEqual(self.calls, [])

    def test_symlink_canonical_path_is_rejected(self):
        original = self.store.path / "snapshot.json"
        target = self.root / "snapshot.json"
        original.rename(target)
        original.symlink_to(target)
        self.error("E_INTEGRITY")
        self.assertEqual(self.gh_calls, 0)

    def test_git_permissions_fail_closed(self):
        (self.store.path / ".git/config").chmod(0o644)
        self.error("E_SYNC")
        self.assertEqual(self.calls, [])

    def test_git_alternates_replacement_and_malformed_object_paths_fail_closed(self):
        root = self.store.path / ".git"
        for relative in ("objects/info/alternates", "info/grafts", "shallow", "info/attributes",
                         "objects/not-hex", "objects/aa/not-a-sha", "objects/pack/malformed.pack"):
            path = root / relative
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_bytes(b"invalid")
            path.chmod(0o600)
            with self.subTest(path=relative):
                self.error("E_SYNC")
            path.unlink()
        self.assertEqual(self.gh_calls, 0)

    def test_extra_staged_file_even_if_missing_from_worktree_is_rejected(self):
        path = self.store.path / "secret.txt"
        path.write_bytes(_SECRET.encode())
        path.chmod(0o600)
        self.raw_git(self.store.path, "add", "--", "secret.txt")
        path.unlink()
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)
        self.assertEqual(self.pushes, 0)

    def test_local_sync_state_can_never_be_staged(self):
        self.raw_git(self.store.path, "add", "--force", "--", ".taskhub/config.json")
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_unknown_historical_paths_fail_even_after_they_are_removed(self):
        path = self.store.path / "events/not-an-event.json"
        path.write_bytes(b"{}\n")
        path.chmod(0o600)
        self.local_commit()
        path.unlink()
        self.local_commit()
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_historical_symlink_mode_is_rejected(self):
        target = self.root / "secret"
        target.write_bytes(b"secret")
        path = self.store.path / "events/00000000000000000001.json"
        path.symlink_to(target)
        self.local_commit()
        path.unlink()
        self.local_commit()
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_changed_historical_manifest_is_rejected_after_valid_replay(self):
        self.successful()
        path = self.store.path / "manifest.json"
        manifest = json.loads(path.read_bytes())
        manifest["created_at"] = "2020-01-01T00:00:00Z"
        path.write_bytes(canonical(manifest))
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_changed_historical_event_is_rejected_after_valid_replay(self):
        self.lane()
        self.successful()
        path = self.store.path / "events/00000000000000000001.json"
        event = json.loads(path.read_bytes())
        event["actor"] = "different-author"
        path.write_bytes(canonical(event))
        (self.store.path / "snapshot.json").unlink()
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_deleted_historical_event_is_rejected_even_with_rebuilt_snapshot(self):
        self.lane()
        self.successful()
        (self.store.path / "events/00000000000000000001.json").unlink()
        (self.store.path / "snapshot.json").unlink()
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_historical_event_modification_then_restoration_is_still_rejected(self):
        self.lane()
        path = self.store.path / "events/00000000000000000001.json"
        original = path.read_bytes()
        self.local_commit()
        event = json.loads(original)
        event["actor"] = "changed"
        path.write_bytes(canonical(event))
        self.local_commit()
        path.write_bytes(original)
        self.local_commit()
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_deleted_and_changed_historical_blob_are_rejected(self):
        path = self.orphan_blob()
        self.successful()
        original = path.read_bytes()
        path.write_bytes(b"wrong content")
        self.error("E_INTEGRITY")
        path.write_bytes(original)
        path.unlink()
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_staged_deletion_of_history_is_rejected(self):
        self.successful()
        self.raw_git(self.store.path, "rm", "--cached", "--", "manifest.json")
        self.error("E_CONFLICT")
        self.assertEqual(self.pushes, 1)

    def test_snapshot_change_is_repaired_before_staging(self):
        self.successful()
        path = self.store.path / "snapshot.json"
        snapshot = json.loads(path.read_bytes())
        snapshot["extra"] = _SECRET
        path.write_bytes(canonical(snapshot))
        result = self.successful()
        self.assertNotIn(_SECRET.encode(), self.raw_git(self.remote, "show", result["head"] + ":snapshot.json").stdout)
        self.assertEqual(self.pushes, 1)

    def test_history_with_merge_commit_is_rejected(self):
        root = self.local_commit()
        tree = self.raw_git(self.store.path, "rev-parse", "HEAD^{tree}").stdout.decode().strip()
        side = self.raw_git(self.store.path, "commit-tree", tree, "-p", root, input=b"side\n").stdout.decode().strip()
        merge = self.raw_git(self.store.path, "commit-tree", tree, "-p", root, "-p", side,
                             input=b"merge fixture\n").stdout.decode().strip()
        self.raw_git(self.store.path, "update-ref", "refs/heads/main", merge)
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_invalid_canonical_path_from_store_cannot_become_a_git_pathspec(self):
        with mock.patch.object(self.store, "canonical_paths", return_value=["manifest.json", "snapshot.json", "../secret"]):
            self.error("E_SYNC")
        with mock.patch.object(self.store, "canonical_paths", return_value=["manifest.json", "snapshot.json", ":(top)*"]):
            self.error("E_SYNC")
        self.assertEqual(self.calls, [])

    def test_configured_attachment_limit_cannot_exceed_absolute_git_gate(self):
        config = self.store.read_local("config.json")
        for value in (synchronization.MAX_FILE_BYTES + 1, True, -1, 0):
            config["max_attachment_bytes"] = value
            self.store.write_local("config.json", config)
            with self.subTest(limit=value):
                self.error("E_INPUT")
        self.assertEqual(self.gh_calls, 0)

    def test_oversized_historical_snapshot_is_rejected(self):
        path = self.store.path / "snapshot.json"
        original = path.read_bytes()
        with path.open("wb") as stream:
            stream.truncate(synchronization.MAX_FILE_BYTES + 1)
        self.local_commit()
        path.write_bytes(original)
        self.local_commit()
        self.error("E_CONFLICT")
        self.assertEqual(self.gh_calls, 0)

    def test_total_blob_capacity_includes_unreferenced_blobs(self):
        self.orphan_blob(b"one")
        self.orphan_blob(b"two")
        config = self.store.read_local("config.json")
        config["max_total_blob_bytes"] = 5
        self.store.write_local("config.json", config)
        self.error("E_CAPACITY")
        self.assertEqual(self.gh_calls, 0)

    def test_event_stage_gate_is_one_mib_before_commit(self):
        self.lane()
        with self.store.lock():
            self.store.load()
        event = next((self.store.path / "events").iterdir())
        with event.open("wb") as stream:
            stream.truncate(synchronization.MAX_EVENT_BYTES + 1)
        self.error("E_CAPACITY", lambda: synchronization._working_files(self.store, synchronization.MAX_FILE_BYTES))
        self.assertEqual(self.calls, [])

    def test_stage_size_gate_refuses_oversized_regular_file_before_reading_it(self):
        path = self.store.path / "snapshot.json"
        with path.open("wb") as stream:
            stream.truncate(synchronization.MAX_FILE_BYTES + 1)
        self.error("E_CAPACITY", lambda: synchronization._working_files(self.store, synchronization.MAX_FILE_BYTES))
        self.assertEqual(self.calls, [])

    def test_stage_size_gate_accepts_exactly_32_mib_and_rejects_configured_blob_overage(self):
        path = self.store.path / "snapshot.json"
        original = path.read_bytes()
        with path.open("wb") as stream:
            stream.truncate(synchronization.MAX_FILE_BYTES)
        result = synchronization._working_files(self.store, synchronization.MAX_FILE_BYTES)
        self.assertIn("snapshot.json", result)
        path.write_bytes(original)
        self.orphan_blob(b"four")
        self.error("E_CAPACITY", lambda: synchronization._working_files(self.store, 3))

    def test_auth_timeout_is_finite_sanitized_and_not_retried(self):
        def timeout(n, args):
            raise subprocess.TimeoutExpired(args, 30, output=_SECRET.encode(), stderr=_SECRET.encode())
        self.gh_behavior = timeout
        self.error("E_TIMEOUT")
        self.assertEqual(self.gh_calls, 1)
        self.assertEqual(self.pushes, 0)

    def test_push_timeout_is_not_retried(self):
        def timeout(n, args, *unused):
            raise subprocess.TimeoutExpired(args, 30, stderr=_SECRET.encode())
        self.push_behavior = timeout
        self.error("E_TIMEOUT")
        self.assertEqual(self.pushes, 1)
        self.assertIsNone(self.store.read_local("sync-state.json")["last_successful_sync"])

    def test_overall_180_second_budget_is_enforced(self):
        clock = mock.Mock(return_value=100.0)
        def exhausted(n, args):
            clock.return_value = 281.0
        self.gh_behavior = exhausted
        with mock.patch.object(synchronization, "time", SimpleNamespace(monotonic=clock)):
            self.error("E_TIMEOUT")
        self.assertEqual(self.gh_calls, 1)
        self.assertEqual(self.pushes, 0)

    def test_malformed_remote_ref_response_is_not_accepted(self):
        for oid in (b"--upload-pack=evil", b"0" * 40, b"a" * 64):
            with self.subTest(oid=oid):
                self.network_behavior = lambda args: self.response(
                    args, stdout=oid + b"\trefs/heads/main\n") if "ls-remote" in args else None
                self.error("E_SYNC")
        self.assertEqual(self.fetches, 0)
        self.assertEqual(self.pushes, 0)

    def test_low_level_timeout_terminates_the_subprocess(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            _REAL_RUN([sys.executable, "-c", "import time; time.sleep(10)"], cwd=self.root,
                      env=synchronization._environment(), timeout=0.1)
        self.assertLess(time.monotonic() - started, 3)


if __name__ == "__main__":
    unittest.main()
