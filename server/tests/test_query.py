import copy
import unittest
from unittest.mock import patch
from uuid import UUID

from taskhub.common import TaskHubError, canonical
from taskhub.domain import apply_event, empty_snapshot
from taskhub.query import digest, search, select


NOW = "2026-10-10T12:00:00Z"
DAY1 = "2026-10-01T12:00:00Z"
DAY2 = "2026-10-02T12:00:00Z"
DAY3 = "2026-10-03T12:00:00Z"
DAY4 = "2026-10-04T12:00:00Z"


def eid(kind, number):
    return kind + "_" + UUID(int=number, version=4).hex


class QueryTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = empty_snapshot({"schema_version": 1, "store_id": str(UUID(int=1, version=4)), "created_at": DAY1})
        self.seq = 0
        self.lane1, self.lane2 = eid("l", 1), eid("l", 2)
        self.emit("lane.created", {"id": self.lane1, "name": "開発"}, DAY1)
        self.emit("lane.created", {"id": self.lane2, "name": "別プロジェクト"}, DAY2)

    def emit(self, event_type, payload, at=NOW):
        self.seq += 1
        apply_event(self.snapshot, {"schema_version": 1, "seq": self.seq, "id": str(UUID(int=self.seq, version=4)),
                                    "request_id": str(UUID(int=self.seq + 100, version=4)), "request_hash": "a" * 64,
                                    "prev_hash": None if self.seq == 1 else "b" * 64, "type": event_type,
                                    "payload": payload, "actor": "agent", "occurred_at": at})

    def task(self, number, title="タスク", at=NOW, lane=None, status="todo", **values):
        task_id = eid("t", number)
        self.emit("task.created", {"id": task_id, "lane_id": lane or self.lane1, "title": title, **values}, at)
        if status == "done":
            self.emit("task.completed", {"id": task_id, "evidence": "完了証拠 unique-completion", "verified": True}, at)
        elif status != "todo":
            self.emit("task.updated", {"id": task_id, "changes": {"status": status}}, at)
        return task_id

    def decision(self, number, task_id, at=NOW, status="pending", **values):
        decision_id = eid("d", number)
        self.emit("decision.created", {"id": decision_id, "task_id": task_id, "title": "ユーザー判断",
                                       "body": "依頼本文", "reason": "理由", **values}, at)
        if status in {"answered", "applied"}:
            self.emit("decision.answered", {"id": decision_id, "answer": "回答 unique-answer", "respondent": "yuki"}, at)
        if status == "applied":
            self.emit("decision.applied", {"id": decision_id, "evidence": "反映証拠 unique-application"}, at)
        return decision_id

    def comment(self, number, kind, target_id, body, at=NOW):
        comment_id = eid("c", number)
        self.emit("comment.added", {"id": comment_id, "target_type": kind, "target_id": target_id, "body": body}, at)
        return comment_id

    def attachment(self, number, kind, target_id, filename="添付.txt", description="添付説明", at=NOW):
        attachment_id = eid("a", number)
        sha = "a" * 64
        self.emit("attachment.added", {"id": attachment_id, "target_type": kind, "target_id": target_id,
                                       "filename": filename, "description": description, "media_type": "text/plain",
                                       "size_bytes": 0, "sha256": sha, "blob_path": f"blobs/sha256/aa/{sha}"}, at)
        return attachment_id

    def ids(self, items):
        return [item["id"] for item in items]

    def test_select_status_lane_half_open_dates_and_assignee(self):
        t1 = self.task(1, at=DAY1, assignee="yuki")
        t2 = self.task(2, at=DAY2, assignee="agent", status="in_progress")
        t3 = self.task(3, at=DAY3, lane=self.lane2, assignee="yuki", status="done")
        d1 = self.decision(1, t1, at=DAY2)
        d2 = self.decision(2, t2, at=DAY3, status="answered")
        d3 = self.decision(3, t3, at=DAY4, status="applied")
        self.assertEqual(self.ids(select(self.snapshot, "task")), [t1, t2, t3])
        self.assertEqual(self.ids(select(self.snapshot, "task", lane=self.lane1)), [t1, t2])
        self.assertEqual(self.ids(select(self.snapshot, "task", assignee="yuki")), [t1, t3])
        self.assertEqual(self.ids(select(self.snapshot, "task", status="done")), [t3])
        self.assertEqual(self.ids(select(self.snapshot, "task", since=DAY2, until=DAY3)), [t2])
        self.assertEqual(self.ids(select(self.snapshot, "task", since=DAY3)), [t3])
        self.assertEqual(self.ids(select(self.snapshot, "task", until=DAY2)), [t1])
        self.assertEqual(self.ids(select(self.snapshot, "decision")), [d1, d2, d3])
        self.assertEqual(self.ids(select(self.snapshot, "decision", status="open")), [d1, d2])
        self.assertEqual(self.ids(select(self.snapshot, "decision", status="answered")), [d2])
        self.assertEqual(self.ids(select(self.snapshot, "decision", assignee="yuki")), [d1, d3])
        self.assertEqual(self.ids(select(self.snapshot, "decision", assignee="agent", status="open", lane=self.lane1)), [d2])
        self.assertEqual(self.ids(select(self.snapshot, "decision", since=DAY2, until=DAY3)), [d1])
        self.assertEqual(self.ids(select(self.snapshot, "lane", lane=self.lane2)), [self.lane2])
        self.assertEqual(self.ids(select(self.snapshot, "lane", since=DAY2)), [self.lane2])

    def test_select_rejects_invalid_filters_even_without_rows(self):
        for kind, kwargs in (("task", {"status": "pending"}), ("decision", {"status": "done"}),
                             ("task", {"status": "open"}), ("lane", {"status": "todo"}),
                             ("lane", {"assignee": "agent"}), ("task", {"lane": eid("l", 99)}),
                             ("task", {"lane": eid("t", 1)}), ("task", {"lane": []}),
                             ("task", {"since": "2026-10-01"}), ("decision", {"until": "not-a-date"}),
                             ("task", {"since": DAY2, "until": DAY1}), ("task", {"since": DAY1, "until": DAY1}),
                             ("task", {"assignee": ""}), ("task", {"assignee": []}), ("decision", {"status": []}),
                             ("attachment", {}), ([], {})):
            with self.subTest(kind=kind, kwargs=kwargs), self.assertRaises(TaskHubError):
                select(self.snapshot, kind, **kwargs)

    def test_unicode_search_and_all_text_fields(self):
        task = self.task(1, title="ＡＰＩ　検証", body="設計 cafe\u0301", method="unique-method", rationale="unique-rationale", status="done")
        decision = self.decision(1, task, title="unique-title", body="unique-body", reason="unique-reason",
                                 options=["unique-option", "unique-option"], status="applied")
        expected = [("api 検証", task, "title"), ("CAFÉ", task, "body"), ("unique-method", task, "method"),
                    ("unique-rationale", task, "rationale"), ("unique-completion", task, "completion.evidence"),
                    ("unique-title", decision, "title"), ("unique-body", decision, "body"),
                    ("unique-reason", decision, "reason"), ("unique-option", decision, "options"),
                    ("unique-answer", decision, "answer.text"), ("unique-application", decision, "application.evidence")]
        for needle, entity_id, field in expected:
            with self.subTest(needle=needle):
                results = search(self.snapshot, needle)
                self.assertEqual(self.ids(results), [entity_id])
                self.assertEqual(results[0]["matches"], [{"type": "task" if entity_id == task else "decision",
                                                         "id": entity_id, "field": field}])
        result = search(self.snapshot, "unique-title")[0]
        self.assertEqual(result["task_id"], task)
        self.assertEqual(result["lane_id"], self.lane1)
        self.assertEqual(result["status"], "applied")
        self.assertEqual(search(self.snapshot, "不一致"), [])

    def test_comments_and_attachments_are_aggregated_under_correct_ancestor(self):
        task = self.task(1, title="共通語")
        decision = self.decision(1, task, body="共通語")
        tc = self.comment(1, "task", task, "共通語 task-log")
        dc = self.comment(2, "decision", decision, "共通語 decision-log")
        ta = self.attachment(1, "task", task, filename="共通語.txt", description="task-attachment")
        da = self.attachment(2, "decision", decision, filename="decision-attachment.txt", description="共通語")
        tca = self.attachment(3, "comment", tc, filename="task-comment-attachment.txt", description="共通語")
        dca = self.attachment(4, "comment", dc, filename="共通語.png", description="decision-comment-attachment")
        results = {item["id"]: item for item in search(self.snapshot, "共通語")}
        self.assertEqual(set(results), {task, decision})
        self.assertEqual({(item["id"], item["field"]) for item in results[task]["matches"]},
                         {(task, "title"), (tc, "body"), (ta, "filename"), (tca, "description")})
        self.assertEqual({(item["id"], item["field"]) for item in results[decision]["matches"]},
                         {(decision, "body"), (dc, "body"), (da, "description"), (dca, "filename")})
        self.assertEqual(self.ids(search(self.snapshot, "task-log")), [task])
        self.assertEqual(self.ids(search(self.snapshot, "decision-log")), [decision])
        self.assertEqual(self.ids(search(self.snapshot, "decision-comment-attachment")), [decision])
        self.assertEqual(self.ids(search(self.snapshot, "task-comment-attachment")), [task])

    def test_search_filters_match_aggregate_updated_at_and_originating_assignee(self):
        task = self.task(1, title="needle", assignee="owner", at=DAY1)
        other = self.task(2, title="needle", assignee="other", lane=self.lane2, at=DAY2, status="done")
        pending = self.decision(1, task, title="needle", at=DAY1)
        answered = self.decision(2, other, title="needle", at=DAY2, status="answered")
        self.comment(1, "task", task, "needle", at=DAY3)
        self.attachment(1, "decision", pending, description="needle", at=DAY3)
        self.assertEqual(set(self.ids(search(self.snapshot, "needle", lane=self.lane1))), {task, pending})
        self.assertEqual(set(self.ids(search(self.snapshot, "needle", assignee="owner"))), {task, pending})
        self.assertEqual(set(self.ids(search(self.snapshot, "needle", since=DAY3, until=DAY4))), {task, pending})
        self.assertEqual(self.ids(search(self.snapshot, "needle", status="done")), [other])
        self.assertEqual(self.ids(search(self.snapshot, "needle", status="todo")), [task])
        self.assertEqual(set(self.ids(search(self.snapshot, "needle", status="open"))), {pending, answered})
        self.assertEqual(self.ids(search(self.snapshot, "needle", status="answered")), [answered])
        self.assertEqual(search(self.snapshot, "needle", status="applied"), [])

    def test_search_input_validation(self):
        for query in ("", " \n", None, [], "x" * 65537, "\ud800"):
            with self.subTest(query=repr(query)), self.assertRaises(TaskHubError):
                search(self.snapshot, query)
        for filters in ({"unknown": "value"}, {"status": "invalid"}, {"status": []}, {"lane": eid("l", 99)},
                        {"status": "done", "since": DAY3, "until": DAY1}, {"assignee": "a\nb"}):
            with self.subTest(filters=filters), self.assertRaises(TaskHubError):
                search(self.snapshot, "query", **filters)

    def test_digest_boundaries_exclusions_and_reference_contract(self):
        overdue = self.task(1, title="過去", due_at="2026-10-10T11:59:59Z", at=DAY3)
        now_due = self.task(2, title="現在", due_at=NOW, at="2026-10-03T12:00:01Z")
        upper_due = self.task(3, title="上限", due_at="2026-10-13T12:00:00Z", at=NOW)
        self.task(4, title="範囲外", due_at="2026-10-13T12:00:01Z", at=NOW)
        undated = self.task(5, title="無期限", at=DAY1)
        done = self.task(6, title="完了済み", due_at=DAY1, at=DAY1, status="done")
        overdue_decision = self.decision(1, now_due, title="期限切れ判断", due_at=DAY2, at=DAY3)
        upcoming_decision = self.decision(2, now_due, title="回答済み判断", due_at=NOW, at=NOW, status="answered")
        pending = self.decision(3, now_due, title="期限なし判断", at=NOW)
        applied = self.decision(4, now_due, title="反映済み", due_at=DAY1, at=DAY1, status="applied")
        result = digest(self.snapshot, now=NOW)
        self.assertEqual(result["as_of"], NOW)
        self.assertEqual(self.ids(result["overdue"]), [overdue_decision, overdue])
        self.assertEqual(self.ids(result["upcoming"]), [upcoming_decision, now_due, upper_due])
        self.assertEqual(self.ids(result["stale"]), [overdue_decision, overdue, undated])
        self.assertEqual(self.ids(result["decisions"]), [overdue_decision, upcoming_decision, pending])
        self.assertEqual(result["duplicates"], [])
        for category in ("overdue", "upcoming", "stale", "decisions"):
            for ref in result[category]:
                self.assertEqual(set(ref), {"type", "id", "title", "lane_id", "due_at"})
                self.assertNotIn(ref["id"], {done, applied})
        labels = [line for line in result["text"].splitlines() if not line.startswith("-")]
        self.assertEqual(labels, ["期限切れ: 2件", "期限間近: 3件", "停滞: 3件", "重複候補: 0件", "ユーザー裁定: 3件"])
        self.assertIn("期限なし", result["text"])

    def test_digest_duplicates_normalized_title_same_lane_active_tasks_only(self):
        first = self.task(1, title="ＡＰＩ   検証", due_at="2026-10-12T00:00:00Z")
        second = self.task(2, title="api 検証", due_at=NOW)
        third = self.task(3, title=" api　検証 ")
        self.task(4, title="API 検証", lane=self.lane2)
        self.task(5, title="API 検証", status="done")
        self.task(6, title="API 別機能")
        self.decision(1, first, title="API 検証")
        duplicate = digest(self.snapshot, now=NOW)["duplicates"]
        self.assertEqual(len(duplicate), 1)
        self.assertEqual(duplicate[0]["title"], "api 検証")
        self.assertEqual(duplicate[0]["lane_id"], self.lane1)
        self.assertEqual(self.ids(duplicate[0]["tasks"]), [second, first, third])
        self.assertEqual(digest(self.snapshot, now=NOW, lane=self.lane2)["duplicates"], [])

    def test_digest_zero_thresholds_and_lane_filter(self):
        current = self.task(1, due_at=NOW)
        old = self.task(2, title="古い", at=DAY1, due_at=DAY2, lane=self.lane2)
        future = self.task(3, title="未来", at="2026-10-11T00:00:00Z", due_at="2026-10-10T12:00:01Z")
        self.decision(1, old, due_at=DAY2)
        result = digest(self.snapshot, now=NOW, upcoming_hours=0, stale_days=0, lane=self.lane1)
        self.assertEqual(self.ids(result["upcoming"]), [current])
        self.assertEqual(self.ids(result["stale"]), [current])
        self.assertNotIn(future, self.ids(result["stale"]))
        self.assertEqual(result["overdue"], [])
        self.assertEqual(result["decisions"], [])
        self.assertNotIn(old, result["text"])

    def test_digest_empty_counts_clock_default_and_threshold_validation(self):
        expected = "期限切れ: 0件\n期限間近: 0件\n停滞: 0件\n重複候補: 0件\nユーザー裁定: 0件"
        with patch("taskhub.query.utc_now", return_value=NOW):
            self.assertEqual(digest(self.snapshot), {"as_of": NOW, "overdue": [], "upcoming": [], "stale": [],
                                                     "duplicates": [], "decisions": [], "text": expected})
        for kwargs in ({"now": "2026-10-10"}, {"now": "2026-02-30T00:00:00Z"}, {"lane": eid("l", 99)},
                       {"upcoming_hours": -1}, {"upcoming_hours": True}, {"upcoming_hours": 0.5},
                       {"stale_days": -1}, {"stale_days": "7"}, {"stale_days": False}):
            with self.subTest(kwargs=kwargs), self.assertRaises(TaskHubError):
                digest(self.snapshot, **kwargs)
        self.assertEqual(digest(self.snapshot, now="9999-12-31T23:59:59Z", upcoming_hours=10**100)["upcoming"], [])

    def test_all_queries_are_read_only_and_deterministically_sorted(self):
        task = self.task(5, title="needle", at=DAY1, due_at=DAY2)
        self.task(2, title="needle", at=DAY1, due_at=DAY2)
        decision = self.decision(9, task, title="needle")
        comment = self.comment(5, "decision", decision, "needle")
        self.attachment(9, "comment", comment, filename="needle.txt", description="needle")
        before = copy.deepcopy(self.snapshot)
        selection = select(self.snapshot, "task")
        matches = search(self.snapshot, "needle")
        summary = digest(self.snapshot, now=NOW)
        self.assertEqual(self.snapshot, before)
        self.assertEqual(self.ids(selection), sorted(self.ids(selection)))
        self.assertEqual([(item["type"], item["id"]) for item in matches],
                         sorted((item["type"], item["id"]) for item in matches))
        for item in matches:
            self.assertEqual(item["matches"], sorted(item["matches"], key=lambda m: (m["type"], m["id"], m["field"])))
        for values in self.snapshot.values():
            if isinstance(values, list):
                values.reverse()
        self.assertEqual(canonical(matches), canonical(search(self.snapshot, "needle")))
        self.assertEqual(canonical(summary), canonical(digest(self.snapshot, now=NOW)))


if __name__ == "__main__":
    unittest.main()
