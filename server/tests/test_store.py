import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

from taskhub import store as store_module
from taskhub.common import TaskHubError, canonical
from taskhub.store import Store


ACTOR = "store-test"
HARD_LIMIT = 32 * 1024 * 1024
PROJECT_ROOT = Path(__file__).resolve().parents[1]
WORKER = "from tests.test_store import run_worker; run_worker()"


def run_worker():
    """Use a fresh interpreter, with no inherited Store or flock descriptor."""
    request = json.loads(sys.stdin.readline())
    store = Store(request["path"], lock_timeout=request.get("lock_timeout", 10))
    action = request.get("action", "mutate")
    try:
        if action == "read":
            result = store.read()
        elif action == "bulk":
            result = [store.mutate("lane.created", {"name": name}, ACTOR)
                      for name in request["names"]]
        else:
            if action == "crash_snapshot":
                original = store.atomic

                def crash(path, data, **kwargs):
                    if path == store.path / "snapshot.json":
                        os._exit(73)
                    return original(path, data, **kwargs)

                store.atomic = crash
            result = store.mutate(request["type"], request["payload"], request.get("actor", ACTOR),
                                  **request.get("options", {}))
        response = {"ok": True, "result": result}
    except TaskHubError as exc:
        response = {"ok": False, "code": exc.code}
    print(json.dumps(response), flush=True)


class StoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="taskhub-store-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.addCleanup(mock.patch.stopall)
        mock.patch.dict(os.environ, {"GIT_CONFIG_NOSYSTEM": "1",
                                     "GIT_CONFIG_SYSTEM": os.devnull,
                                     "GIT_CONFIG_GLOBAL": os.devnull,
                                     "GIT_TERMINAL_PROMPT": "0"}).start()
        self.store_number = 0
        self.store = self.new_store()

    def new_store(self):
        self.store_number += 1
        store = Store(self.root / f"data-{self.store_number}")
        store.initialize(ACTOR, repo=None)
        return store

    def source(self, data=b"evidence", name="evidence.txt"):
        path = self.root / name
        self.put(path, data)
        return path

    def put(self, path, data):
        path.write_bytes(data)
        path.chmod(0o600)

    def events(self, store=None):
        store = store or self.store
        return {path.name: (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns)
                for path in sorted((store.path / "events").iterdir())}

    def persisted(self, store=None):
        store = store or self.store
        return {"events": self.events(store),
                **{name: (store.path / name).read_bytes() if (store.path / name).exists() else None
                   for name in ("manifest.json", "snapshot.json")}}

    def reject(self, code, function, *args, store=None, **kwargs):
        store = store or self.store
        before = self.persisted(store)
        try:
            with self.assertRaises(TaskHubError) as caught:
                function(*args, **kwargs)
            self.assertEqual(caught.exception.code, code)
            return caught.exception
        finally:
            self.assertEqual(self.persisted(store), before, "rejected operation changed committed data")

    def task(self, store=None):
        store = store or self.store
        lane = store.mutate("lane.created", {"name": "Persistence"}, ACTOR)
        return store.mutate("task.created", {"lane_id": lane["id"], "title": "検証"}, ACTOR)

    def attach(self, task_id, source=None, store=None, **options):
        store = store or self.store
        return store.mutate("attachment.added", {"target_type": "task", "target_id": task_id,
                                                "description": "検証記録"}, ACTOR,
                            source=source or self.source(), **options)

    def blobs(self, store=None):
        store = store or self.store
        return sorted(path for path in (store.path / "blobs" / "sha256").glob("*/*")
                      if path.is_file())

    def configure(self, store=None, **changes):
        store = store or self.store
        with store.lock():
            config = store.read_local("config.json")
            config.update(changes)
            store.write_local("config.json", config)

    def start_worker(self, request):
        process = subprocess.Popen([sys.executable, "-c", WORKER], cwd=PROJECT_ROOT,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_worker, process)
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        return process

    @staticmethod
    def stop_worker(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)

    def finish_worker(self, process):
        stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, stderr)
        return json.loads(stdout)

    def test_initialize_is_local_and_creates_an_empty_store(self):
        snapshot = self.store.read()
        self.assertEqual(snapshot["last_event_seq"], 0)
        self.assertIsNone(snapshot["last_event_hash"])
        self.assertEqual(self.events(), {})
        self.assertTrue((self.store.path / ".git").is_dir())
        remotes = subprocess.run(["git", "-C", str(self.store.path), "remote"],
                                 capture_output=True, text=True, timeout=10, check=True)
        self.assertEqual(remotes.stdout, "")
        config = self.store.read_local("config.json")
        self.assertEqual(config["initialized_by"], ACTOR)
        self.assertIsNone(config["repo"])
        self.assertEqual(config["branch"], "main")
        self.assertEqual(config["max_attachment_bytes"], 10 * 1024 * 1024)
        self.assertEqual(config["max_total_blob_bytes"], 1024 * 1024 * 1024)
        self.assertEqual(self.store.fsck()["events"], 0)

    def test_initialize_nonempty_directory_preserves_all_existing_files(self):
        path = self.root / "existing"
        path.mkdir(mode=0o700)
        nested = path / "nested"
        nested.mkdir(mode=0o700)
        self.put(path / "sentinel", b"user data")
        self.put(nested / "precious", b"keep me")
        before = {str(p.relative_to(path)): (p.read_bytes(), p.stat().st_mode)
                  for p in path.rglob("*") if p.is_file()}
        with self.assertRaises(TaskHubError) as caught:
            Store(path).initialize(ACTOR)
        self.assertEqual(caught.exception.code, "E_INPUT")
        self.assertEqual({str(p.relative_to(path)): (p.read_bytes(), p.stat().st_mode)
                          for p in path.rglob("*") if p.is_file()}, before)
        self.assertEqual(set(p.name for p in path.iterdir()), {"sentinel", "nested"})
        self.reject("E_INPUT", self.store.initialize, ACTOR)

    def test_actor_is_explicit_validated_and_persisted(self):
        for actor in (None, "", " \t", "forged\nactor", "x" * 129, "界" * 43):
            with self.subTest(actor=repr(actor)):
                self.reject("E_INPUT", self.store.mutate, "lane.created", {"name": "invalid"}, actor)
                path = self.root / "invalid-init"
                with self.assertRaises(TaskHubError) as caught:
                    Store(path).initialize(actor)
                self.assertEqual(caught.exception.code, "E_INPUT")
                self.assertFalse(path.exists())
        result = self.store.mutate("lane.created", {"name": "valid"}, "界" * 42)
        event = json.loads(next(iter(self.events().values()))[0])
        self.assertEqual(event["actor"], "界" * 42)
        self.assertEqual(self.store.read()["lanes"][0]["created_by"], event["actor"])
        self.assertEqual(result["event_seq"], 1)

    def test_request_id_is_canonical_uuid(self):
        valid = "12345678-1234-4234-8234-123456789abc"
        for index, request_id in enumerate(("", "not-a-uuid", valid.upper(), valid.replace("-", ""),
                                             "{" + valid + "}", 12, [])):
            with self.subTest(request_id=request_id):
                self.reject("E_INPUT", self.store.mutate, "lane.created", {"name": f"invalid-{index}"},
                            ACTOR, request_id=request_id)
        self.store.mutate("lane.created", {"name": "valid"}, ACTOR, request_id=valid)

    def test_idempotency_is_actor_and_request_bound_without_rewriting_events(self):
        request_id = str(uuid.uuid4())
        payload = {"name": "Original", "description": "監査"}
        original_payload = copy.deepcopy(payload)
        result = self.store.mutate("lane.created", payload, ACTOR, request_id=request_id)
        self.assertEqual(payload, original_payload)
        before = self.persisted()
        replay = Store(self.store.path).mutate("lane.created", dict(reversed(list(payload.items()))),
                                             ACTOR, request_id=request_id)
        self.assertTrue(replay["replayed"])
        self.assertEqual((replay["id"], replay["event_seq"]), (result["id"], result["event_seq"]))
        self.assertEqual(self.persisted(), before)
        self.reject("E_CONFLICT", self.store.mutate, "lane.created", payload, "different-actor",
                    request_id=request_id)
        self.reject("E_CONFLICT", self.store.mutate, "lane.created", {"name": "Changed"}, ACTOR,
                    request_id=request_id)
        self.reject("E_INPUT", self.store.mutate, "lane.created", {"id": result["id"], "name": "Forged"}, ACTOR)

    def test_revision_conflict_and_retry_after_newer_event(self):
        task = self.task()
        request_id = str(uuid.uuid4())
        payload = {"id": task["id"], "changes": {"title": "Changed"}}
        updated = self.store.mutate("task.updated", payload, ACTOR, request_id=request_id,
                                    if_revision=task["event_seq"])
        self.store.mutate("comment.added", {"target_type": "task", "target_id": task["id"],
                                            "body": "追記"}, "commenter")
        self.reject("E_CONFLICT", self.store.mutate, "task.updated", payload, ACTOR,
                    if_revision=task["event_seq"])
        before = self.persisted()
        replay = self.store.mutate("task.updated", payload, ACTOR, request_id=request_id,
                                   if_revision=task["event_seq"])
        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["event_seq"], updated["event_seq"])
        self.assertEqual(self.persisted(), before)
        for value in (True, False, 0, -1, "2", 1.5):
            with self.subTest(revision=value):
                self.reject("E_INPUT", self.store.mutate, "task.updated", payload, ACTOR, if_revision=value)
        current = self.store.read()["tasks"][0]
        self.assertEqual((current["revision"], current["updated_by"]), (4, "commenter"))

    def test_processes_serialize_writes_and_preserve_hash_chain(self):
        first = self.store.mutate("lane.created", {"name": "Initial"}, ACTOR)
        original = self.events()
        lock_inode = (self.store.path / ".taskhub" / "lock").stat().st_ino
        processes = [self.start_worker({"action": "bulk", "path": str(self.store.path),
                                        "names": [f"worker-{worker}-{i}" for i in range(3)]})
                     for worker in range(6)]
        responses = [self.finish_worker(process) for process in processes]
        self.assertTrue(all(response["ok"] for response in responses), responses)
        results = [item for response in responses for item in response["result"]]
        self.assertEqual(sorted(item["event_seq"] for item in results), list(range(2, 20)))
        self.assertEqual(len({item["id"] for item in results}), 18)
        self.assertEqual(len(self.store.read()["lanes"]), 19)
        events = self.events()
        self.assertEqual({name: events[name] for name in original}, original)
        previous = None
        for seq, (name, (raw, _, _)) in enumerate(events.items(), 1):
            event = json.loads(raw)
            self.assertEqual(name, f"{seq:020d}.json")
            self.assertEqual(event["seq"], seq)
            self.assertEqual(event["prev_hash"], previous)
            self.assertEqual(raw, canonical(event))
            previous = hashlib.sha256(raw).hexdigest()
        self.assertEqual(self.store.read()["last_event_hash"], previous)
        self.assertEqual(first["event_seq"], 1)
        self.assertEqual((self.store.path / ".taskhub" / "lock").stat().st_ino, lock_inode)
        self.assertEqual(self.store.fsck()["events"], 19)

    def test_concurrent_identical_requests_commit_once(self):
        request = {"path": str(self.store.path), "type": "lane.created", "payload": {"name": "Once"},
                   "options": {"request_id": str(uuid.uuid4())}}
        processes = [self.start_worker(request) for _ in range(4)]
        responses = [self.finish_worker(process) for process in processes]
        self.assertTrue(all(response["ok"] for response in responses), responses)
        results = [response["result"] for response in responses]
        self.assertEqual(len({(result["id"], result["event_seq"]) for result in results}), 1)
        self.assertEqual(sum(not result["replayed"] for result in results), 1)
        self.assertEqual(len(self.events()), 1)

    def test_concurrent_revision_updates_have_one_winner(self):
        task = self.task()
        original = self.events()
        processes = [self.start_worker({"path": str(self.store.path), "type": "task.updated",
                                        "payload": {"id": task["id"], "changes": {"title": title}},
                                        "options": {"if_revision": task["event_seq"]}})
                     for title in ("First", "Second")]
        responses = [self.finish_worker(process) for process in processes]
        self.assertEqual(sum(response["ok"] for response in responses), 1, responses)
        self.assertEqual([response["code"] for response in responses if not response["ok"]], ["E_CONFLICT"])
        self.assertEqual(len(self.events()), 3)
        self.assertEqual({name: self.events()[name] for name in original}, original)

    def test_lock_timeout_in_another_process_never_commits(self):
        before = self.persisted()
        inode = (self.store.path / ".taskhub" / "lock").stat().st_ino
        with self.store.lock():
            process = self.start_worker({"path": str(self.store.path), "lock_timeout": 0.05,
                                         "type": "lane.created", "payload": {"name": "Locked"}})
            self.assertEqual(self.finish_worker(process), {"ok": False, "code": "E_LOCK_TIMEOUT"})
        self.assertEqual(self.persisted(), before)
        self.assertEqual((self.store.path / ".taskhub" / "lock").stat().st_ino, inode)
        self.store.mutate("lane.created", {"name": "Unlocked"}, ACTOR)

    def test_load_requires_lock_and_lock_is_not_reentrant(self):
        self.reject("E_CONFLICT", self.store.load)
        with self.store.lock():
            with self.assertRaises(TaskHubError) as caught:
                with self.store.lock():
                    self.fail("nested lock accepted")
            self.assertEqual(caught.exception.code, "E_CONFLICT")
            self.assertEqual(self.store.load(verify_blobs=True, repair=False)["last_event_seq"], 0)

    def test_snapshot_write_failure_reports_commit_and_recovers_by_replay(self):
        request_id = str(uuid.uuid4())
        original_snapshot = (self.store.path / "snapshot.json").read_bytes()
        atomic = self.store.atomic

        def fail_snapshot(path, data, **kwargs):
            if path == self.store.path / "snapshot.json":
                self.assertEqual(len(self.events()), 1)
                raise OSError(errno.EIO, "injected snapshot fsync failure")
            return atomic(path, data, **kwargs)

        with mock.patch.object(self.store, "atomic", side_effect=fail_snapshot):
            with self.assertRaises(TaskHubError) as caught:
                self.store.mutate("lane.created", {"name": "Committed"}, ACTOR, request_id=request_id)
        self.assertEqual(caught.exception.code, "E_COMMITTED_VIEW_STALE")
        self.assertEqual(caught.exception.committed_event_seq, 1)
        self.assertIsNotNone(caught.exception.entity_id)
        self.assertEqual((self.store.path / "snapshot.json").read_bytes(), original_snapshot)
        committed = self.events()
        reopened = Store(self.store.path)
        with reopened.lock():
            recovered = reopened.load(verify_blobs=True, repair=False)
        self.assertEqual(recovered["lanes"][0]["id"], caught.exception.entity_id)
        self.assertEqual((self.store.path / "snapshot.json").read_bytes(), original_snapshot)
        self.reject("E_INTEGRITY", reopened.fsck)
        self.assertEqual(reopened.read(), recovered)
        replay = reopened.mutate("lane.created", {"name": "Committed"}, ACTOR, request_id=request_id)
        self.assertEqual((replay["id"], replay["event_seq"], replay["replayed"]),
                         (caught.exception.entity_id, 1, True))
        self.assertEqual(self.events(), committed)
        self.assertEqual(reopened.fsck()["events"], 1)

    def test_process_exit_after_event_commit_releases_lock_and_recovers(self):
        before = (self.store.path / "snapshot.json").read_bytes()
        request_id = str(uuid.uuid4())
        process = self.start_worker({"action": "crash_snapshot", "path": str(self.store.path),
                                     "type": "lane.created", "payload": {"name": "Crash"},
                                     "options": {"request_id": request_id}})
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 73, stderr)
        self.assertEqual((self.store.path / "snapshot.json").read_bytes(), before)
        committed = self.events()
        self.assertEqual(len(committed), 1)
        reopened = Store(self.store.path, lock_timeout=0.1)
        self.assertEqual(reopened.read()["last_event_seq"], 1)
        replay = reopened.mutate("lane.created", {"name": "Crash"}, ACTOR, request_id=request_id)
        self.assertTrue(replay["replayed"])
        self.assertEqual(self.events(), committed)

    def test_missing_and_stale_snapshots_rebuild_without_changing_events(self):
        self.task()
        stale = (self.store.path / "snapshot.json").read_bytes()
        self.store.mutate("lane.created", {"name": "Later"}, ACTOR)
        expected = self.store.read()
        original = self.events()
        self.put(self.store.path / "snapshot.json", stale)
        self.assertEqual(Store(self.store.path).read(), expected)
        (self.store.path / "snapshot.json").unlink()
        self.assertEqual(Store(self.store.path).read(), expected)
        self.assertEqual(self.events(), original)
        self.assertEqual((self.store.path / "snapshot.json").read_bytes(), canonical(expected))

    def test_blob_file_fsync_failure_is_precommit(self):
        task = self.task()
        source = self.source()
        fsync = os.fsync
        injected = []

        def fail_regular(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode):
                injected.append(fd)
                raise OSError(errno.EIO, "injected blob file fsync failure")
            return fsync(fd)

        try:
            with mock.patch.object(store_module.os, "fsync", side_effect=fail_regular):
                self.reject("E_IO", self.attach, task["id"], source)
        finally:
            self.assertTrue(injected)
            self.assertEqual(self.blobs(), [])
            self.assertEqual(list((self.store.path / ".taskhub").glob("tmp-*")), [])

    def test_each_new_blob_directory_fsync_failure_prevents_event_commit(self):
        cases = (("prefix", 1), ("sha256", 1), ("sha256", 2), ("blobs", 1),
                 ("prefix", 2), ("prefix", 3), ("sha256", 3), ("blobs", 2), ("data", 1))
        for location, occurrence in cases:
            with self.subTest(location=location, occurrence=occurrence):
                store = self.new_store()
                task = self.task(store)
                source = self.source()
                digest = hashlib.sha256(source.read_bytes()).hexdigest()
                targets = {"prefix": store.path / "blobs" / "sha256" / digest[:2],
                           "sha256": store.path / "blobs" / "sha256",
                           "blobs": store.path / "blobs", "data": store.path}
                target = targets[location]
                original = store_module.fsync_dir
                calls = []

                def fail_directory(path):
                    if path == target:
                        calls.append(path)
                        if len(calls) == occurrence:
                            raise OSError(errno.EIO, "injected blob ancestor fsync failure")
                    return original(path)

                try:
                    with mock.patch.object(store_module, "fsync_dir", side_effect=fail_directory):
                        self.reject("E_IO", lambda: self.attach(task["id"], source, store=store), store=store)
                finally:
                    self.assertEqual(len(calls), occurrence)
                    self.assertEqual(len(self.events(store)), 2)
                    self.assertEqual(list((store.path / ".taskhub").glob("tmp-*")), [])

    def test_blob_ancestors_are_durable_before_event_publication(self):
        task = self.task()
        source = self.source()
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        prefix = self.store.path / "blobs" / "sha256" / digest[:2]
        trace = []
        fsync_dir = store_module.fsync_dir
        atomic = self.store.atomic

        def record_fsync(path):
            result = fsync_dir(path)
            trace.append(("fsync", path))
            return result

        def record_atomic(path, data, **kwargs):
            if path.parent == self.store.path / "events":
                trace.append(("event", path))
            return atomic(path, data, **kwargs)

        with mock.patch.object(store_module, "fsync_dir", side_effect=record_fsync), \
                mock.patch.object(self.store, "atomic", side_effect=record_atomic):
            self.attach(task["id"], source)
        publication = next(i for i, (kind, _) in enumerate(trace) if kind == "event")
        ancestors = [prefix, prefix.parent, self.store.path / "blobs", self.store.path]
        last_fsyncs = [max(i for i, entry in enumerate(trace[:publication]) if entry == ("fsync", path))
                      for path in ancestors]
        self.assertEqual(last_fsyncs, sorted(last_fsyncs))
        self.assertEqual(self.store.fsck()["blobs"], 1)

    def test_event_publication_failure_leaves_accounted_orphan_blob(self):
        task = self.task()
        atomic = self.store.atomic

        def fail_event(path, data, **kwargs):
            if path.parent == self.store.path / "events":
                raise OSError(errno.EIO, "injected event publication failure")
            return atomic(path, data, **kwargs)

        with mock.patch.object(self.store, "atomic", side_effect=fail_event):
            self.reject("E_IO", self.attach, task["id"])
        blobs = self.blobs()
        self.assertEqual(len(blobs), 1)
        report = self.store.fsck()
        self.assertEqual(report["orphan_blobs"], [blobs[0].relative_to(self.store.path).as_posix()])
        self.assertEqual(report["blob_bytes"], len(b"evidence"))
        self.assertEqual(report["events"], 2)
        original_blob = (blobs[0].read_bytes(), blobs[0].stat().st_ino)
        self.attach(task["id"])
        self.assertEqual(self.store.fsck()["orphan_blobs"], [])
        self.assertEqual((blobs[0].read_bytes(), blobs[0].stat().st_ino), original_blob)

    def test_orphan_blobs_are_verified_preserved_and_counted_against_quota(self):
        task = self.task()
        data = b"orphan"
        sha = hashlib.sha256(data).hexdigest()
        blob = self.store.path / "blobs" / "sha256" / sha[:2] / sha
        blob.parent.mkdir(mode=0o700)
        self.put(blob, data)
        before = self.persisted()
        self.assertEqual(self.store.fsck()["orphan_blobs"], [blob.relative_to(self.store.path).as_posix()])
        self.assertEqual(self.persisted(), before)
        self.configure(max_total_blob_bytes=len(data))
        self.reject("E_CAPACITY", self.attach, task["id"], self.source(b"new"))
        self.assertEqual(blob.read_bytes(), data)
        self.put(blob, b"ORPHAN")
        self.reject("E_INTEGRITY", self.store.fsck)
        self.assertTrue(blob.exists())

    def test_missing_middle_and_tail_events_are_not_repaired(self):
        self.task()
        self.store.mutate("lane.created", {"name": "Third"}, ACTOR)
        for seq in (1, 2, 3):
            with self.subTest(deleted_seq=seq):
                path = self.store.path / "events" / f"{seq:020d}.json"
                raw = path.read_bytes()
                path.unlink()
                try:
                    self.reject("E_INTEGRITY", self.store.read)
                    self.reject("E_INTEGRITY", self.store.fsck)
                finally:
                    self.put(path, raw)

    def test_modified_event_hash_chain_and_tail_checkpoint_are_rejected(self):
        self.task()
        for seq in (1, 2):
            with self.subTest(modified_seq=seq):
                path = self.store.path / "events" / f"{seq:020d}.json"
                raw = path.read_bytes()
                event = json.loads(raw)
                event["actor"] = "other-actor"
                self.put(path, canonical(event))
                try:
                    self.reject("E_INTEGRITY", self.store.read)
                finally:
                    self.put(path, raw)

    def test_event_envelope_payload_version_and_request_hash_are_strict(self):
        self.store.mutate("lane.created", {"name": "Original"}, ACTOR)
        path = self.store.path / "events" / "00000000000000000001.json"
        original = json.loads(path.read_bytes())
        (self.store.path / "snapshot.json").unlink()
        cases = [("unknown", 1), ("schema_version", 2), ("schema_version", True), ("seq", True),
                 ("seq", 2), ("prev_hash", "0" * 64), ("id", "invalid"), ("request_id", "invalid"),
                 ("request_hash", "0" * 64), ("actor", ""), ("occurred_at", "2026-10-10"),
                 ("type", "lane.deleted"), ("payload", {**original["payload"], "unknown": True}),
                 ("payload", None)]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                event = copy.deepcopy(original)
                event[key] = value
                if key in {"type", "payload"} and isinstance(event["payload"], dict):
                    request_payload = {k: v for k, v in event["payload"].items() if k != "id"}
                    event["request_hash"] = hashlib.sha256(canonical({"type": event["type"],
                                                                      "payload": request_payload})).hexdigest()
                self.put(path, canonical(event))
                self.reject("E_INTEGRITY", self.store.read)
        self.put(path, canonical(original))
        self.assertEqual(self.store.read()["last_event_seq"], 1)

    def test_duplicate_event_and_request_ids_are_rejected_without_checkpoint(self):
        self.task()
        first_path = self.store.path / "events" / "00000000000000000001.json"
        second_path = self.store.path / "events" / "00000000000000000002.json"
        first, second = json.loads(first_path.read_bytes()), json.loads(second_path.read_bytes())
        (self.store.path / "snapshot.json").unlink()
        for field in ("id", "request_id"):
            with self.subTest(field=field):
                self.put(second_path, canonical({**second, field: first[field]}))
                self.reject("E_INTEGRITY", self.store.read)

    def test_manifest_unknown_fields_and_versions_are_rejected(self):
        path = self.store.path / "manifest.json"
        original = json.loads(path.read_bytes())
        for changes in ({"unknown": 1}, {"schema_version": 2}, {"schema_version": True},
                        {"store_id": "not-uuid"}, {"created_at": "2026-10-10"}):
            with self.subTest(changes=changes):
                self.put(path, canonical({**original, **changes}))
                self.reject("E_INTEGRITY", self.store.read)
        self.put(path, canonical(original))

    def test_malformed_json_and_duplicate_keys_are_rejected(self):
        self.task()
        for relative in ("manifest.json", "snapshot.json", "events/00000000000000000002.json",
                         ".taskhub/config.json"):
            path = self.store.path / relative
            original = path.read_bytes()
            for raw in (b"{", b"\xff", b'{"x":1,"x":2}\n', b'{"x":NaN}\n', b'{"x":Infinity}\n'):
                with self.subTest(path=relative, data=raw):
                    self.put(path, raw)
                    reader = (lambda: self.store.read_local("config.json")) if relative.startswith(".taskhub") \
                        else self.store.read
                    self.reject("E_INTEGRITY", reader)
            self.put(path, original)

    def test_noncanonical_event_bytes_and_unexpected_paths_are_rejected(self):
        self.store.mutate("lane.created", {"name": "Canonical"}, ACTOR)
        event_path = self.store.path / "events" / "00000000000000000001.json"
        original = event_path.read_bytes()
        (self.store.path / "snapshot.json").unlink()
        self.put(event_path, json.dumps(json.loads(original), indent=2).encode() + b"\n")
        self.reject("E_INTEGRITY", self.store.read)
        self.put(event_path, original)
        self.store.read()
        for relative in ("unexpected.txt", "events/stray.json", "blobs/extra", "blobs/sha256/invalid"):
            with self.subTest(path=relative):
                path = self.store.path / relative
                self.put(path, b"stray")
                try:
                    self.reject("E_INTEGRITY", self.store.read)
                finally:
                    path.unlink()

    def test_snapshot_ahead_and_old_hash_mismatch_are_not_silently_repaired(self):
        self.store.mutate("lane.created", {"name": "First"}, ACTOR)
        old = self.store.read()
        self.store.mutate("lane.created", {"name": "Second"}, ACTOR)
        current = self.store.read()
        for corrupt in ({**current, "last_event_seq": 3}, {**current, "last_event_seq": True},
                        {**current, "last_event_seq": -1}, {**current, "last_event_hash": "0" * 64},
                        {**old, "last_event_hash": "0" * 64}, {**current, "store_id": str(uuid.uuid4())}):
            with self.subTest(seq=corrupt["last_event_seq"], hash=corrupt["last_event_hash"]):
                self.put(self.store.path / "snapshot.json", canonical(corrupt))
                self.reject("E_INTEGRITY", self.store.read)
        self.put(self.store.path / "snapshot.json", canonical(old))
        self.assertEqual(self.store.read(), current)

    def test_snapshot_projection_is_not_trusted_as_authoritative_data(self):
        self.task()
        expected = self.store.read()
        altered = copy.deepcopy(expected)
        altered["tasks"][0]["title"] = "fabricated"
        altered["unknown_projection_field"] = "ignored"
        self.put(self.store.path / "snapshot.json", canonical(altered))
        before = self.events()
        self.assertEqual(self.store.read(), expected)
        self.assertEqual(self.events(), before)

    def test_blob_missing_size_mismatch_and_same_size_tamper(self):
        task = self.task()
        self.attach(task["id"], self.source(b"original"))
        blob = self.blobs()[0]
        original = blob.read_bytes()
        for data in (None, b"short", b"ORIGINAL"):
            with self.subTest(data=data):
                if data is None:
                    blob.unlink()
                else:
                    self.put(blob, data)
                try:
                    if data != b"ORIGINAL":
                        self.reject("E_INTEGRITY", self.store.read)
                    else:
                        self.assertEqual(self.store.read()["last_event_seq"], 3)
                        with self.store.lock():
                            self.reject("E_INTEGRITY", self.store.load, verify_blobs=True, repair=False)
                        self.reject("E_INTEGRITY", self.attach, task["id"], self.source(original))
                    self.reject("E_INTEGRITY", self.store.fsck)
                finally:
                    self.put(blob, original)

    def test_attachment_idempotency_includes_content_and_deduplicates_blobs(self):
        task = self.task()
        request_id = str(uuid.uuid4())
        source = self.source(b"same")
        first = self.attach(task["id"], source, request_id=request_id)
        original = self.persisted()
        blob = self.blobs()[0]
        inode = blob.stat().st_ino
        replay = self.attach(task["id"], source, request_id=request_id)
        self.assertTrue(replay["replayed"])
        self.assertEqual((replay["id"], replay["event_seq"]), (first["id"], first["event_seq"]))
        self.assertEqual(self.persisted(), original)
        self.put(source, b"else")
        self.reject("E_CONFLICT", self.attach, task["id"], source, request_id=request_id)
        self.assertEqual(len(self.blobs()), 1)
        self.put(source, b"same")
        second = self.attach(task["id"], source)
        self.assertNotEqual(second["id"], first["id"])
        self.assertEqual(blob.stat().st_ino, inode)
        self.assertEqual(self.store.fsck()["blob_bytes"], 4)

    def test_source_symlinks_fifo_and_directories_are_rejected_without_hanging(self):
        task = self.task()
        regular = self.source()
        symlink = self.root / "source-link"
        symlink.symlink_to(regular)
        fifo = self.root / "source-fifo"
        os.mkfifo(fifo, 0o600)
        directory = self.root / "source-directory"
        directory.mkdir(mode=0o700)
        before = self.persisted()
        for source in (symlink, fifo, directory):
            with self.subTest(source=source.name):
                process = self.start_worker({"path": str(self.store.path), "type": "attachment.added",
                                             "payload": {"target_type": "task", "target_id": task["id"],
                                                         "description": "invalid source"},
                                             "options": {"source": str(source)}})
                response = self.finish_worker(process)
                self.assertFalse(response["ok"], response)
                self.assertEqual(response["code"], "E_INPUT")
                self.assertEqual(self.persisted(), before)
                self.assertEqual(self.blobs(), [])
        self.assertEqual(regular.read_bytes(), b"evidence")

    def test_symlink_data_root_and_ancestor_are_rejected_without_writes(self):
        link = self.root / "data-link"
        link.symlink_to(self.store.path, target_is_directory=True)
        with self.assertRaises(TaskHubError) as caught:
            Store(link).read()
        self.assertEqual(caught.exception.code, "E_INTEGRITY")
        actual = self.root / "actual-parent"
        actual.mkdir(mode=0o700)
        alias = self.root / "parent-alias"
        alias.symlink_to(actual, target_is_directory=True)
        try:
            with self.assertRaises(TaskHubError) as caught:
                Store(alias / "new-data").initialize(ACTOR)
            self.assertEqual(caught.exception.code, "E_INTEGRITY")
        finally:
            self.assertEqual(list(actual.iterdir()), [], "initialization followed a symlink ancestor")

    def test_symlinks_inside_data_paths_are_rejected(self):
        task = self.task()
        self.attach(task["id"])
        blob = self.blobs()[0]
        paths = [self.store.path / name for name in ("manifest.json", "snapshot.json", "events", "blobs",
                                                     "blobs/sha256", ".taskhub", ".git",
                                                     "events/00000000000000000001.json", ".taskhub/lock")]
        paths += [blob.parent, blob]
        for number, path in enumerate(paths):
            with self.subTest(path=path.relative_to(self.store.path)):
                outside = self.root / f"displaced-{number}"
                path.rename(outside)
                path.symlink_to(outside, target_is_directory=outside.is_dir())
                try:
                    with self.assertRaises(TaskHubError) as caught:
                        Store(self.store.path).read()
                    self.assertEqual(caught.exception.code, "E_INTEGRITY")
                finally:
                    path.unlink()
                    outside.rename(path)
        self.assertEqual(self.store.fsck()["events"], 3)

    def test_local_config_names_and_symlink_targets_are_safe(self):
        with self.store.lock():
            self.assertEqual(self.store.read_local("absent.json", {"default": True}), {"default": True})
            self.store.write_local("sync-state.json", {"value": "ローカル"})
            self.assertEqual(self.store.read_local("sync-state.json"), {"value": "ローカル"})
        for name in ("../manifest.json", "x/y.json", "config", "CAPS.json", "under_score.json"):
            with self.subTest(name=name):
                self.reject("E_INPUT", self.store.read_local, name)
                self.reject("E_INPUT", self.store.write_local, name, {})
        target = self.source(b"outside", name="outside.json")
        path = self.store.path / ".taskhub" / "unsafe.json"
        path.symlink_to(target)
        self.reject("E_INTEGRITY", self.store.read_local, "unsafe.json")
        self.reject("E_INTEGRITY", self.store.write_local, "unsafe.json", {"overwrite": True})
        self.assertEqual(target.read_bytes(), b"outside")
        self.assertTrue(path.is_symlink())

    def test_attachment_and_unique_blob_quotas_are_precommit(self):
        task = self.task()
        self.configure(max_attachment_bytes=4, max_total_blob_bytes=6)
        self.reject("E_CAPACITY", self.attach, task["id"], self.source(b"12345"))
        self.assertEqual(self.blobs(), [])
        self.attach(task["id"], self.source(b"1234"))
        self.attach(task["id"], self.source(b"1234"))
        self.assertEqual(self.store.fsck()["blob_bytes"], 4)
        self.attach(task["id"], self.source(b"56"))
        before = self.blobs()
        self.reject("E_CAPACITY", self.attach, task["id"], self.source(b"7"))
        self.assertEqual(self.blobs(), before)
        self.assertEqual(self.store.fsck()["blob_bytes"], 6)

    def test_quota_configuration_rejects_invalid_values_and_hard_limit_override(self):
        task = self.task()
        source = self.source(b"")
        initial = self.store.read_local("config.json")
        for key, values in (("max_attachment_bytes", (-1, True, 1.5, "10", HARD_LIMIT + 1)),
                            ("max_total_blob_bytes", (-1, True, 1.5, "10", 1024 * 1024 * 1024 + 1))):
            for value in values:
                with self.subTest(key=key, value=value):
                    with self.store.lock():
                        self.store.write_local("config.json", {**initial, key: value})
                    self.reject("E_INPUT", self.attach, task["id"], source)
                    self.assertEqual(self.blobs(), [])
        for invalid in ([], None, "config"):
            with self.subTest(config=invalid):
                with self.store.lock():
                    self.store.write_local("config.json", invalid)
                self.reject("E_INPUT", self.attach, task["id"], source)

    def test_zero_attachment_quota_is_invalid_even_for_empty_source(self):
        task = self.task()
        self.configure(max_attachment_bytes=0)
        try:
            self.reject("E_INPUT", self.attach, task["id"], self.source(b""))
        finally:
            self.assertEqual(self.blobs(), [])

    def test_attachment_actual_size_32mib_boundary(self):
        self.assertEqual(store_module.MAX_GIT_FILE_BYTES, HARD_LIMIT)
        self.assertEqual(store_module.MAX_SNAPSHOT_BYTES, HARD_LIMIT)
        task = self.task()
        self.configure(max_attachment_bytes=HARD_LIMIT)
        source = self.root / "large.bin"
        for size in (HARD_LIMIT - 1, HARD_LIMIT, HARD_LIMIT + 1):
            with self.subTest(size=size):
                with source.open("wb") as stream:
                    stream.truncate(size)
                if size > HARD_LIMIT:
                    before = self.blobs()
                    self.reject("E_CAPACITY", self.attach, task["id"], source)
                    self.assertEqual(self.blobs(), before)
                else:
                    result = self.attach(task["id"], source)
                    attachment = next(item for item in self.store.read()["attachments"] if item["id"] == result["id"])
                    self.assertEqual(attachment["size_bytes"], size)
                    self.assertEqual((self.store.path / attachment["blob_path"]).stat().st_size, size)
        self.assertEqual(self.store.fsck()["blobs"], 2)

    def test_snapshot_utf8_and_final_newline_byte_boundary_is_precommit(self):
        for spare in (-1, 0, 1):
            with self.subTest(spare_bytes=spare):
                store = self.new_store()
                task = self.task(store)
                baseline = len(canonical(store.read()))
                body = "界" * 37
                expected = baseline + len(body.encode("utf-8"))
                payload = {"id": task["id"], "changes": {"body": body}}
                with mock.patch.object(store_module, "MAX_SNAPSHOT_BYTES", expected + spare):
                    if spare < 0:
                        self.reject("E_CAPACITY", store.mutate, "task.updated", payload, ACTOR, store=store)
                    else:
                        result = store.mutate("task.updated", payload, ACTOR)
                        raw = (store.path / "snapshot.json").read_bytes()
                        self.assertEqual(len(raw), expected)
                        self.assertTrue(raw.endswith(b"\n"))
                        self.assertGreater(len(raw), len(raw.decode("utf-8")))
                        self.assertTrue(result["capacity_warning"])
                        self.assertEqual(store.read()["tasks"][0]["body"], body)
                        self.assertEqual(store.fsck()["snapshot_bytes"], expected)

    def test_snapshot_eighty_percent_warning_boundary(self):
        for extra_capacity, warning in ((0, True), (1, False)):
            with self.subTest(extra_capacity=extra_capacity):
                store = self.new_store()
                task = self.task(store)
                baseline = len(canonical(store.read()))
                body = "x" * (100 + (-(baseline + 100) % 4))
                expected = baseline + len(body)
                limit = expected * 5 // 4 + extra_capacity
                with mock.patch.object(store_module, "MAX_SNAPSHOT_BYTES", limit):
                    result = store.mutate("task.updated", {"id": task["id"], "changes": {"body": body}}, ACTOR)
                    self.assertEqual(len((store.path / "snapshot.json").read_bytes()), expected)
                    self.assertEqual(result["capacity_warning"], warning)
                    self.assertEqual(store.fsck()["capacity_warning"], warning)

    def test_snapshot_overflow_does_not_publish_attachment_blob(self):
        task = self.task()
        baseline = len(canonical(self.store.read()))
        with mock.patch.object(store_module, "MAX_SNAPSHOT_BYTES", baseline):
            self.reject("E_CAPACITY", self.attach, task["id"])
        self.assertEqual(self.blobs(), [])

    def test_user_data_permissions_are_private(self):
        task = self.task()
        self.attach(task["id"])
        self.store.write_local("sync-state.json", {"checked": True})
        paths = [self.store.path] + list(self.store.path.rglob("*"))
        for path in paths:
            relative = path.relative_to(self.store.path)
            if ".git" in relative.parts and relative.parts != (".git",):
                continue
            with self.subTest(path=relative):
                info = path.lstat()
                self.assertEqual(info.st_uid, os.getuid())
                self.assertEqual(stat.S_IMODE(info.st_mode), 0o700 if path.is_dir() else 0o600)
                self.assertFalse(path.is_symlink())

    def test_wide_permissions_and_wrong_owner_are_rejected(self):
        task = self.task()
        self.attach(task["id"])
        paths = [self.store.path, self.store.path / "events", self.store.path / ".taskhub",
                 self.store.path / ".taskhub" / "lock", self.store.path / "manifest.json",
                 self.store.path / "snapshot.json", self.store.path / "events" / "00000000000000000001.json",
                 self.blobs()[0].parent, self.blobs()[0]]
        for path in paths:
            with self.subTest(path=path.relative_to(self.store.path)):
                mode = stat.S_IMODE(path.stat().st_mode)
                path.chmod(mode | 0o044)
                try:
                    self.reject("E_INTEGRITY", self.store.read)
                finally:
                    path.chmod(mode)
        with mock.patch.object(store_module.os, "getuid", return_value=os.getuid() + 1):
            self.reject("E_INTEGRITY", self.store.read)


if __name__ == "__main__":
    unittest.main()
