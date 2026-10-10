"""Client fixture checks independent of event-store internals."""

import hashlib
import json
import re
import unittest
from pathlib import Path

from taskhub.common import timestamp


EXAMPLES = Path(__file__).resolve().parents[1] / "examples"


class SnapshotContractTests(unittest.TestCase):
    def test_v1_client_fixture_has_all_fields_and_valid_references(self):
        snapshot = json.loads((EXAMPLES / "snapshot.json").read_text(encoding="utf-8"))
        self.assertEqual(set(snapshot), {"schema_version", "store_id", "last_event_seq", "last_event_hash",
                                         "generated_at", "lanes", "tasks", "decisions", "comments", "attachments"})
        self.assertEqual(snapshot["schema_version"], 1)
        timestamp(snapshot["generated_at"])
        self.assertRegex(snapshot["last_event_hash"], r"^[0-9a-f]{64}$")
        common = {"id", "created_at", "created_by", "updated_at", "updated_by", "revision"}
        extra = {
            "lanes": {"name", "description"},
            "tasks": {"lane_id", "parent_id", "title", "body", "status", "priority", "due_at", "assignee",
                      "amount", "method", "rationale", "completion"},
            "decisions": {"lane_id", "task_id", "title", "body", "options", "reason", "due_at", "status", "answer", "application"},
        }
        indexed = {kind: {item["id"]: item for item in snapshot[kind + "s"]}
                   for kind in ("lane", "task", "decision", "comment", "attachment")}
        for kind, prefix in (("lanes", "l"), ("tasks", "t"), ("decisions", "d")):
            for item in snapshot[kind]:
                self.assertEqual(set(item), common | extra[kind])
                self.assertRegex(item["id"], prefix + r"_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$")
                timestamp(item["created_at"])
                timestamp(item["updated_at"])
                self.assertGreater(item["revision"], 0)
                self.assertLessEqual(item["revision"], snapshot["last_event_seq"])
        for task in snapshot["tasks"]:
            self.assertIn(task["lane_id"], indexed["lane"])
            if task["parent_id"] is not None:
                self.assertIn(task["parent_id"], indexed["task"])
            self.assertEqual(task["status"] == "done", task["completion"] is not None)
            if task["completion"]:
                self.assertEqual(set(task["completion"]), {"evidence", "verified_by", "verified_at"})
            if task["amount"]:
                self.assertIsInstance(task["amount"]["value"], str)
        for decision in snapshot["decisions"]:
            self.assertEqual(decision["lane_id"], indexed["task"][decision["task_id"]]["lane_id"])
            self.assertEqual(decision["status"] == "pending", decision["answer"] is None)
            self.assertEqual(decision["status"] == "applied", decision["application"] is not None)
        for comment in snapshot["comments"]:
            self.assertIn(comment["target_id"], indexed[comment["target_type"]])
        for attachment in snapshot["attachments"]:
            self.assertIn(attachment["target_id"], indexed[attachment["target_type"]])
            sha = attachment["sha256"]
            self.assertEqual(attachment["blob_path"], f"blobs/sha256/{sha[:2]}/{sha}")
            blob = (EXAMPLES / attachment["blob_path"]).read_bytes()
            self.assertEqual(hashlib.sha256(blob).hexdigest(), sha)
            self.assertEqual(len(blob), attachment["size_bytes"])


if __name__ == "__main__":
    unittest.main()
