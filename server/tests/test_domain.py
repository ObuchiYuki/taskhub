import copy
import unittest
from uuid import UUID

from taskhub.common import TaskHubError, canonical
from taskhub.domain import apply_event, empty_snapshot, find


TIME = "2026-10-10T12:00:00Z"
LATER = "2026-10-11T12:00:00Z"


def entity_id(kind, number):
    return kind + "_" + UUID(int=number, version=4).hex


class DomainTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {"schema_version": 1, "store_id": str(UUID(int=100, version=4)), "created_at": TIME}
        self.snapshot = empty_snapshot(self.manifest)
        self.seq = 0
        self.events = []
        self.lane_id = entity_id("l", 1)
        self.task_id = entity_id("t", 1)
        self.decision_id = entity_id("d", 1)

    def event(self, kind, payload, actor="agent", at=TIME):
        seq = self.seq + 1
        return {"schema_version": 1, "seq": seq, "id": str(UUID(int=seq, version=4)),
                "request_id": str(UUID(int=seq + 100, version=4)), "request_hash": "a" * 64,
                "prev_hash": "b" * 64 if self.seq else None, "type": kind, "payload": payload,
                "actor": actor, "occurred_at": at}

    def emit(self, kind, payload, **kwargs):
        event = self.event(kind, payload, **kwargs)
        apply_event(self.snapshot, event)
        self.seq += 1
        self.events.append(copy.deepcopy(event))
        return find(self.snapshot, kind.split(".")[0], payload["id"])

    def reject(self, kind, payload, code=None, **kwargs):
        before = copy.deepcopy(self.snapshot)
        with self.assertRaises(TaskHubError) as caught:
            self.emit(kind, payload, **kwargs)
        if code:
            self.assertEqual(caught.exception.code, code)
        self.assertEqual(self.snapshot, before)

    def setup_task(self, **values):
        self.emit("lane.created", {"id": self.lane_id, "name": "TaskHub"})
        return self.emit("task.created", {"id": self.task_id, "lane_id": self.lane_id, "title": "検証", **values})

    def setup_decision(self):
        self.setup_task()
        return self.emit("decision.created", {"id": self.decision_id, "task_id": self.task_id,
                                              "title": "判断", "body": "何を選ぶか", "reason": "本人の判断が必要"})

    def attachment(self, number, target_type, target_id, **values):
        sha = "a" * 64
        return {"id": entity_id("a", number), "target_type": target_type, "target_id": target_id,
                "filename": "証拠.txt", "description": "検証記録", "media_type": "text/plain", "size_bytes": 0,
                "sha256": sha, "blob_path": f"blobs/sha256/aa/{sha}", **values}

    def test_empty_snapshot_exact_contract_and_manifest_validation(self):
        self.assertEqual(self.snapshot, {"schema_version": 1, "store_id": self.manifest["store_id"],
                                       "last_event_seq": 0, "last_event_hash": None, "generated_at": None,
                                       "lanes": [], "tasks": [], "decisions": [], "comments": [], "attachments": []})
        for key, value in (("schema_version", 2), ("schema_version", True), ("store_id", "invalid"),
                           ("store_id", None), ("created_at", "2026-10-10")):
            with self.subTest(key=key, value=value), self.assertRaises(TaskHubError):
                empty_snapshot({**self.manifest, key: value})

    def test_task_defaults_and_root_metadata_are_explicit(self):
        task = self.setup_task()
        self.assertEqual(task, {"id": self.task_id, "lane_id": self.lane_id, "parent_id": None,
                               "title": "検証", "body": "", "status": "todo", "priority": "normal", "due_at": None,
                               "assignee": None, "amount": None, "method": "", "rationale": "", "completion": None,
                               "created_at": TIME, "created_by": "agent", "updated_at": TIME,
                               "updated_by": "agent", "revision": 2})
        self.assertEqual(self.snapshot["lanes"][0]["description"], "")
        self.assertEqual(self.snapshot["last_event_seq"], 0)
        self.assertIsNone(self.snapshot["last_event_hash"])
        self.assertIsNone(self.snapshot["generated_at"])
        self.assertEqual(len(self.snapshot), 10)

    def test_lane_uniqueness_update_and_revision(self):
        self.emit("lane.created", {"id": self.lane_id, "name": "ＴａｓｋＨｕｂ"})
        self.reject("lane.created", {"id": entity_id("l", 2), "name": "taskhub"}, "E_CONFLICT")
        second = self.emit("lane.created", {"id": entity_id("l", 2), "name": "別件"})
        self.reject("lane.updated", {"id": second["id"], "changes": {"name": "TaskHub"}})
        self.reject("lane.updated", {"id": self.lane_id, "changes": {"name": "Renamed"}, "if_revision": 2}, "E_CONFLICT")
        updated = self.emit("lane.updated", {"id": self.lane_id, "changes": {"name": "TaskHub", "description": "説明"},
                                             "if_revision": 1}, actor="other", at=LATER)
        self.assertEqual((updated["revision"], updated["updated_at"], updated["updated_by"]), (3, LATER, "other"))
        self.assertEqual((updated["created_at"], updated["created_by"]), (TIME, "agent"))
        self.reject("lane.updated", {"id": self.lane_id, "changes": {}})
        self.reject("lane.created", {"id": entity_id("l", 3), "name": "新規", "if_revision": 1})

    def test_task_attributes_money_and_null_clearing(self):
        money = {"value": "1200.000001", "currency": "JPY"}
        task = self.setup_task(body="本文\n続き", priority="urgent", due_at=LATER, assignee="yuki", amount=money,
                               method="手順", rationale="根拠")
        self.assertEqual(task["amount"], money)
        money["value"] = "999"
        self.assertEqual(task["amount"]["value"], "1200.000001")
        self.emit("task.updated", {"id": self.task_id, "changes": {"amount": None, "assignee": None,
                                                                   "due_at": None, "parent_id": None}})
        for field in ("amount", "assignee", "due_at", "parent_id"):
            self.assertIsNone(task[field])
        for status in ("in_progress", "awaiting_user", "blocked", "on_hold", "todo"):
            self.emit("task.updated", {"id": self.task_id, "changes": {"status": status}})
            self.assertEqual(task["status"], status)
        for value in ("-1", "01", "1e2", "1.0000001", "1.", ".5", 1.5, True):
            with self.subTest(value=value):
                self.reject("task.updated", {"id": self.task_id, "changes": {"amount": {"value": value, "currency": "JPY"}}})
        for money in ({"value": "0", "currency": "jpy"}, {"value": "0", "currency": "JP"},
                      {"value": "0", "currency": "JPY", "extra": 1}, []):
            self.reject("task.updated", {"id": self.task_id, "changes": {"amount": money}})

    def test_completion_gate_reopen_and_independent_parent_state(self):
        parent = self.setup_task()
        child_id = entity_id("t", 2)
        child = self.emit("task.created", {"id": child_id, "lane_id": self.lane_id, "title": "子", "parent_id": self.task_id})
        self.reject("task.updated", {"id": self.task_id, "changes": {"status": "done"}})
        self.reject("task.reopened", {"id": self.task_id, "reason": "まだ未完了"}, "E_STATE")
        for evidence, verified in (("", True), (" \n", True), ("確認済み", False), ("確認済み", 1), ("確認済み", "true")):
            self.reject("task.completed", {"id": self.task_id, "evidence": evidence, "verified": verified})
        self.emit("task.completed", {"id": self.task_id, "evidence": "テスト成功", "verified": True}, actor="checker", at=LATER)
        self.assertEqual(parent["completion"], {"evidence": "テスト成功", "verified_by": "checker", "verified_at": LATER})
        self.assertEqual(child["status"], "todo")
        for changes in ({"title": "編集"}, {"status": "todo"}, {"body": "本文"}):
            self.reject("task.updated", {"id": self.task_id, "changes": changes}, "E_STATE")
        self.reject("task.completed", {"id": self.task_id, "evidence": "二重", "verified": True}, "E_STATE")
        self.reject("task.reopened", {"id": self.task_id, "reason": " "})
        self.emit("task.reopened", {"id": self.task_id, "reason": "追加検証"})
        self.assertEqual(parent["status"], "todo")
        self.assertIsNone(parent["completion"])
        self.assertEqual(self.events[-2]["payload"]["evidence"], "テスト成功")

    def test_parent_validation_and_cycles_are_atomic(self):
        self.setup_task()
        other_lane = entity_id("l", 2)
        self.emit("lane.created", {"id": other_lane, "name": "別"})
        foreign_id = entity_id("t", 9)
        self.emit("task.created", {"id": foreign_id, "lane_id": other_lane, "title": "別レーン"})
        for parent_id in (self.task_id, foreign_id, entity_id("t", 99), self.lane_id):
            self.reject("task.updated", {"id": self.task_id, "changes": {"title": "変更不可", "parent_id": parent_id}})
        child_id, grandchild_id = entity_id("t", 2), entity_id("t", 3)
        self.emit("task.created", {"id": child_id, "lane_id": self.lane_id, "title": "子", "parent_id": self.task_id})
        self.emit("task.created", {"id": grandchild_id, "lane_id": self.lane_id, "title": "孫", "parent_id": child_id})
        self.reject("task.updated", {"id": self.task_id, "changes": {"parent_id": grandchild_id}})
        self.reject("task.created", {"id": entity_id("t", 4), "lane_id": self.lane_id, "title": "不正", "parent_id": foreign_id})
        self.reject("task.updated", {"id": child_id, "changes": {"lane_id": other_lane}})
        self.emit("task.updated", {"id": child_id, "changes": {"parent_id": None}})
        self.emit("task.updated", {"id": self.task_id, "changes": {"parent_id": grandchild_id}})

    def test_decision_defaults_and_separate_respondent_recorder(self):
        decision = self.setup_decision()
        task = find(self.snapshot, "task", self.task_id)
        self.assertEqual({key: decision[key] for key in ("options", "due_at", "status", "answer", "application")},
                         {"options": [], "due_at": None, "status": "pending", "answer": None, "application": None})
        self.assertEqual(decision["lane_id"], task["lane_id"])
        self.assertEqual(task["revision"], 2)
        self.reject("decision.applied", {"id": self.decision_id, "evidence": "実施"}, "E_STATE")
        for answer, respondent in ((" ", "yuki"), ("A", ""), ("A", "user\nforged")):
            self.reject("decision.answered", {"id": self.decision_id, "answer": answer, "respondent": respondent})
        self.emit("decision.answered", {"id": self.decision_id, "answer": "A案", "respondent": "yuki"}, actor="proxy", at=LATER)
        self.assertEqual(decision["answer"], {"text": "A案", "respondent": "yuki", "recorded_by": "proxy", "recorded_at": LATER})
        self.assertEqual(task["status"], "todo")
        self.reject("decision.answered", {"id": self.decision_id, "answer": "上書き", "respondent": "yuki"}, "E_STATE")
        self.emit("decision.applied", {"id": self.decision_id, "evidence": "A案を反映"})
        self.assertEqual(decision["application"], {"evidence": "A案を反映", "applied_by": "agent", "applied_at": TIME,
                                                 "resumed_task": False})
        self.assertEqual(task["revision"], 2)
        self.reject("decision.applied", {"id": self.decision_id, "evidence": "二重"}, "E_STATE")

    def test_resume_checks_all_conditions_before_either_mutation(self):
        for status in ("todo", "in_progress", "on_hold", "done", "blocked", "awaiting_user"):
            with self.subTest(status=status):
                self.setUp()
                decision = self.setup_decision()
                if status == "done":
                    self.emit("task.completed", {"id": self.task_id, "evidence": "確認", "verified": True})
                else:
                    self.emit("task.updated", {"id": self.task_id, "changes": {"status": status}})
                self.emit("decision.answered", {"id": self.decision_id, "answer": "再開", "respondent": "yuki"})
                payload = {"id": self.decision_id, "evidence": "反映", "resume": True}
                self.reject("decision.applied", {**payload, "if_revision": 1}, "E_CONFLICT")
                self.reject("decision.applied", {**payload, "evidence": " "})
                self.reject("decision.applied", {**payload, "resume": 1})
                if status in {"blocked", "awaiting_user"}:
                    self.emit("decision.applied", {**payload, "if_revision": decision["revision"]}, actor="resume-agent", at=LATER)
                    task = find(self.snapshot, "task", self.task_id)
                    self.assertEqual(task["status"], "in_progress")
                    self.assertEqual(task["revision"], decision["revision"])
                    self.assertEqual(task["updated_by"], "resume-agent")
                    self.assertEqual(task["updated_at"], LATER)
                    self.assertTrue(decision["application"]["resumed_task"])
                else:
                    self.reject("decision.applied", payload, "E_STATE")
                    self.assertEqual(decision["status"], "answered")
                    self.emit("decision.applied", {**payload, "resume": False})

    def test_comments_and_all_attachment_targets_propagate_revision(self):
        self.setup_decision()
        self.emit("task.completed", {"id": self.task_id, "evidence": "完了", "verified": True})
        for number, kind, target_id in ((1, "task", self.task_id), (2, "decision", self.decision_id)):
            target = find(self.snapshot, kind, target_id)
            revision = target["revision"]
            comment_id = entity_id("c", number)
            payload = {"id": comment_id, "target_type": kind, "target_id": target_id, "body": "追記", "if_revision": revision}
            self.reject("comment.added", {**payload, "if_revision": 999}, "E_CONFLICT")
            comment = self.emit("comment.added", payload, actor="commenter", at=LATER)
            self.assertEqual(target["revision"], self.seq)
            self.assertEqual((target["updated_by"], target["updated_at"]), ("commenter", LATER))
            self.assertEqual(set(comment), {"id", "target_type", "target_id", "body", "created_at", "created_by", "event_seq"})
            immutable = copy.deepcopy(comment)
            self.emit("attachment.added", self.attachment(number, kind, target_id, if_revision=target["revision"]))
            self.reject("attachment.added", self.attachment(number + 10, "comment", comment_id,
                                                            if_revision=comment["event_seq"]), "E_CONFLICT")
            attachment = self.emit("attachment.added", self.attachment(number + 10, "comment", comment_id,
                                                                       if_revision=target["revision"]), actor="uploader")
            self.assertEqual(target["revision"], attachment["event_seq"])
            self.assertEqual(target["updated_by"], "uploader")
            self.assertEqual(comment, immutable)
        self.assertEqual(find(self.snapshot, "task", self.task_id)["status"], "done")

    def test_attachment_validation_is_atomic(self):
        self.setup_task()
        valid = self.attachment(1, "task", self.task_id)
        malformed = [("filename", "../secret"), ("filename", "a\\b"), ("filename", "."), ("filename", "a\n"),
                     ("filename", "あ" * 86), ("description", None), ("media_type", "text"),
                     ("media_type", "text/plain\n"), ("size_bytes", -1), ("size_bytes", True), ("size_bytes", 1.0),
                     ("sha256", "A" * 64), ("sha256", "a" * 63), ("blob_path", "/tmp/file"),
                     ("target_type", "lane"), ("target_id", self.lane_id), ("target_id", entity_id("t", 99))]
        for key, value in malformed:
            with self.subTest(key=key, value=value):
                self.reject("attachment.added", {**valid, key: value})
        item = self.emit("attachment.added", {**valid, "description": ""})
        self.assertEqual(item["description"], "")
        self.assertEqual(item["size_bytes"], 0)
        self.assertEqual(set(item), {"id", "target_type", "target_id", "filename", "description", "media_type",
                                     "size_bytes", "sha256", "blob_path", "created_at", "created_by", "event_seq"})

    def test_strict_payload_changes_types_and_text_limits(self):
        self.setup_task()
        for changes in ({}, [], None, {"title": " "}, {"title": "あ" * 171}, {"body": None},
                        {"body": "x" * 65537}, {"body": "bad\x00"}, {"body": "\ud800"}, {"priority": "highest"},
                        {"priority": []}, {"status": []}, {"due_at": "2026-10-10"}, {"due_at": "2026-02-30T00:00:00Z"},
                        {"assignee": " "}, {"assignee": "x" * 129}, {"completion": None}, {"revision": 1}):
            with self.subTest(changes=repr(changes)):
                self.reject("task.updated", {"id": self.task_id, "changes": changes})
        for payload in ([], None, {"id": self.task_id}, {"id": self.task_id, "changes": {"body": "x"}, "unknown": 1}):
            self.reject("task.updated", payload)
        for value in (True, 0, -1, "2", None):
            self.reject("task.updated", {"id": self.task_id, "changes": {"body": "x"}, "if_revision": value})
        self.reject("task.created", {"id": entity_id("t", 2), "lane_id": self.lane_id, "title": "不正", "status": "done"})
        self.reject("task.created", {"id": self.task_id, "lane_id": self.lane_id, "title": "重複"}, "E_CONFLICT")
        for options in ("A", {}, [""], [None]):
            self.reject("decision.created", {"id": self.decision_id, "task_id": self.task_id, "title": "判断",
                                             "body": "依頼", "reason": "理由", "options": options})
        for field in ("title", "body", "reason"):
            self.reject("decision.created", {"id": self.decision_id, "task_id": self.task_id, "title": "判断",
                                             "body": "依頼", "reason": "理由", field: " "})
        self.reject("comment.added", {"id": entity_id("c", 1), "target_type": "comment",
                                      "target_id": entity_id("c", 1), "body": "x"})
        self.reject("comment.added", {"id": entity_id("c", 1), "target_type": "task", "target_id": self.task_id, "body": " "})

    def test_envelope_and_id_validation(self):
        self.setup_task()
        payload = {"id": self.task_id, "changes": {"body": "x"}}
        for key, value in (("schema_version", 2), ("schema_version", True), ("seq", True), ("seq", 0), ("seq", 1.5),
                           ("actor", ""), ("actor", "agent\nforged"), ("actor", "x" * 129), ("occurred_at", "2026-10-10"),
                           ("occurred_at", "2026-10-10T00:00:00+00:00"), ("type", "task.deleted"), ("type", [])):
            with self.subTest(key=key, value=value):
                event = {**self.event("task.updated", payload), key: value}
                before = copy.deepcopy(self.snapshot)
                with self.assertRaises(TaskHubError):
                    apply_event(self.snapshot, event)
                self.assertEqual(self.snapshot, before)
        for value in (None, {}, {"type": "task.updated"}):
            with self.assertRaises(TaskHubError):
                apply_event(self.snapshot, value)
        for value in ("t_not-a-uuid", self.lane_id, "t_" + "a" * 32, "t_00000000000040007000000000000001",
                      "t_0000000000004000800000000000000A", None, []):
            with self.subTest(value=value), self.assertRaises(TaskHubError):
                find(self.snapshot, "task", value)
        with self.assertRaises(TaskHubError) as caught:
            find(self.snapshot, "task", entity_id("t", 99))
        self.assertEqual(caught.exception.code, "E_NOT_FOUND")
        for kind in ("tasks", "unknown", []):
            with self.assertRaises(TaskHubError):
                find(self.snapshot, kind, self.task_id)

    def test_create_revision_targets_and_deterministic_replay(self):
        self.setup_task()
        self.reject("task.created", {"id": entity_id("t", 2), "lane_id": self.lane_id, "title": "子", "if_revision": 2}, "E_CONFLICT")
        self.emit("task.created", {"id": entity_id("t", 2), "lane_id": self.lane_id, "title": "子", "if_revision": 1})
        options = ["A", "B"]
        self.emit("decision.created", {"id": self.decision_id, "task_id": self.task_id, "title": "選択", "body": "依頼",
                                       "reason": "理由", "options": options, "due_at": LATER, "if_revision": 2})
        options.append("外部変更")
        self.assertEqual(find(self.snapshot, "decision", self.decision_id)["options"], ["A", "B"])
        self.emit("comment.added", {"id": entity_id("c", 9), "target_type": "decision", "target_id": self.decision_id, "body": "先"})
        self.emit("comment.added", {"id": entity_id("c", 1), "target_type": "task", "target_id": self.task_id, "body": "後"})
        self.emit("lane.created", {"id": entity_id("l", 0), "name": "先頭"})
        self.assertEqual([x["id"] for x in self.snapshot["lanes"]], sorted(x["id"] for x in self.snapshot["lanes"]))
        self.assertEqual([x["id"] for x in self.snapshot["comments"]], [entity_id("c", 9), entity_id("c", 1)])
        replay = empty_snapshot(self.manifest)
        for event in self.events:
            apply_event(replay, event)
        self.assertEqual(canonical(replay), canonical(self.snapshot))


if __name__ == "__main__":
    unittest.main()
