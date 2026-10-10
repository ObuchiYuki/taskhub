"""End-to-end tests invoking the installed-style module entry point."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskhub-cli-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.call("init")

    def run_cli(self, *args, actor="agent-a", json_output=True, expected=0):
        command = [sys.executable, "-m", "taskhub", "--data-dir", str(self.data)]
        if actor is not None:
            command.extend(["--actor", actor])
        if json_output:
            command.append("--json")
        command.extend(args)
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return json.loads(result.stdout) if json_output else result.stdout

    def call(self, *args, **kwargs):
        result = self.run_cli(*args, **kwargs)
        self.assertTrue(result["ok"], result)
        return result["data"]

    def lane(self, name="開発"):
        return self.call("lane", "add", "--name", name)["id"]

    def task(self, lane, title="実装", *extra):
        return self.call("task", "add", "--lane", lane, "--title", title, *extra)["id"]

    def test_full_task_decision_attachment_lifecycle(self):
        lane = self.lane()
        task = self.task(lane, "サーバー実装", "--body", "依頼を先に記録", "--priority", "high",
                         "--due-at", "2026-10-11T09:00:00Z", "--assignee", "agent-a",
                         "--amount", "123.450", "--currency", "JPY", "--method", "unittest",
                         "--rationale", "全変更を検証")
        child = self.task(lane, "子タスク", "--parent", task)
        self.call("task", "update", task, "--status", "blocked")
        comment = self.call("comment", "add", "--task", task, "--body", "認証の方式を検討")["id"]
        decision = self.call("decision", "add", "--task", task, "--title", "方式選択", "--body", "方式を選ぶ",
                             "--reason", "作業再開に必要", "--option", "A", "--option", "B")["id"]
        self.assertEqual(self.call("decision", "list", "--status", "pending")[0]["id"], decision)
        self.call("decision", "answer", decision, "--answer", "Aを採用", "--respondent", "user",
                  actor="recorder")
        self.assertEqual(self.call("decision", "list", "--status", "answered")[0]["answer"]["recorded_by"], "recorder")
        self.call("decision", "apply", decision, "--evidence", "設定Aへ変更済み", "--resume")
        self.assertEqual(self.call("task", "show", task)["task"]["status"], "in_progress")
        file = self.root / "検証.txt"
        file.write_text("検証出力", encoding="utf-8")
        for kind, entity in (("task", task), ("decision", decision), ("comment", comment)):
            self.call("attachment", "add", "--" + kind, entity, "--file", str(file), "--description", "動作証拠")
        found = self.call("search", "動作証拠", "--lane", lane, "--assignee", "agent-a")
        self.assertEqual({entry["type"] for entry in found}, {"task", "decision"})
        self.assertEqual(len(self.call("task", "show", task)["attachments"]), 2)
        self.run_cli("task", "complete", task, "--evidence", "確認結果", expected=2)
        self.run_cli("task", "update", task, "--status", "done", expected=2)
        evidence = self.root / "evidence.txt"
        evidence.write_text("全試験成功を確認\n結果添付済み", encoding="utf-8")
        self.call("task", "complete", task, "--evidence-file", str(evidence), "--verified")
        view = self.call("task", "show", task)
        self.assertEqual(view["task"]["completion"]["verified_by"], "agent-a")
        self.assertEqual(view["task"]["amount"], {"value": "123.450", "currency": "JPY"})
        self.assertEqual(view["subtasks"][0]["id"], child)
        self.assertEqual(self.call("task", "show", child)["task"]["status"], "todo")
        self.run_cli("task", "update", task, "--title", "変更", expected=2)
        self.call("comment", "add", "--task", task, "--body", "完了後の追記")
        self.call("task", "reopen", task, "--reason", "追加依頼")
        history = self.call("task", "history", task)
        self.assertIn("task.completed", {event["type"] for event in history})
        self.assertIn("decision.applied", {event["type"] for event in history})
        self.assertEqual(self.call("decision", "history", decision)[1]["actor"], "recorder")
        self.assertEqual(self.call("fsck")["blobs"], 1)
        self.assertEqual(self.call("decision", "list"), [])
        snapshot = self.run_cli("snapshot")
        self.assertEqual(snapshot["schema_version"], 1)
        self.assertEqual(snapshot["tasks"][0].keys(), snapshot["tasks"][1].keys())
        self.assertTrue(all(item["created_by"] for item in snapshot["attachments"]))
        self.call("rebuild")
        self.assertEqual(self.run_cli("snapshot"), snapshot)

    def test_filters_digest_and_revision(self):
        lane = self.lane()
        task = self.task(lane, "ＡＰＩ", "--due-at", "2026-01-01T00:00:00Z", "--assignee", "agent-a")
        self.task(lane, "api")
        other_lane = self.lane("別レーン")
        self.task(other_lane, "API")
        self.assertEqual(len(self.call("search", "api", "--lane", lane)), 2)
        revision = self.call("task", "show", task)["task"]["revision"]
        self.call("task", "update", task, "--priority", "urgent", "--if-revision", str(revision))
        self.run_cli("task", "update", task, "--title", "古い書込", "--if-revision", str(revision), expected=3)
        items = self.call("task", "list", "--lane", lane, "--status", "todo", "--assignee", "agent-a",
                          "--since", "2020-01-01T00:00:00Z", "--until", "2099-01-01T00:00:00Z")
        self.assertEqual([entry["id"] for entry in items], [task])
        args = ("digest", "--lane", lane, "--now", "2030-01-01T00:00:00Z")
        result = self.call(*args)
        self.assertEqual(len(result["overdue"]), 1)
        self.assertEqual(len(result["duplicates"]), 1)
        self.assertEqual(len(result["stale"]), 2)
        self.assertEqual(self.call(*args), result)
        rendered = self.run_cli(*args, json_output=False)
        self.assertIn("期限切れ: 1件", rendered)
        self.assertIn("ユーザー裁定: 0件", rendered)
        self.call("task", "update", task, "--clear", "due_at", "--clear", "assignee")
        self.assertIsNone(self.call("task", "show", task)["task"]["due_at"])

    def test_replay_and_invalid_requests(self):
        request = str(uuid.uuid4())
        first = self.call("lane", "add", "--name", "same", "--request-id", request)
        again = self.call("lane", "add", "--name", "same", "--request-id", request)
        self.assertEqual(first["id"], again["id"])
        self.assertTrue(again["replayed"])
        self.run_cli("lane", "add", "--name", "different", "--request-id", request, expected=3)
        self.run_cli("lane", "add", "--name", "missing actor", actor=None, expected=2)
        self.run_cli("lane", "add", "--name", " ", expected=2)
        self.run_cli("lane", "add", "--name", "ＳＡＭＥ", expected=3)
        task = self.task(first["id"])
        for options in (("--amount", "1"), ("--due-at", "2026-10-10"), ("--assignee", "x", "--clear", "assignee")):
            self.run_cli("task", "update", task, *options, expected=2)
        self.run_cli("task", "delete", task, expected=2)
        self.run_cli("task", "update", task, expected=2)
        self.run_cli("task", "show", "../../secrets", expected=2)
        self.run_cli("digest", "--stale-days", "-1", expected=2)
        self.run_cli("task", "list", "--status", "unknown", expected=2)
        self.run_cli("comment", "add", "--task", task, "--body", "x", "--body-file", "/tmp/no", expected=2)
        self.run_cli("init", expected=2)
        self.assertEqual(len(self.call("lane", "list")), 1)
        self.call("fsck")

    def test_capacity_warning_keeps_snapshot_stdout_valid_json(self):
        import contextlib
        import io
        from unittest.mock import patch
        from taskhub import cli
        size = (self.data / "snapshot.json").stat().st_size
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("taskhub.store.MAX_SNAPSHOT_BYTES", size + 1), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = cli.main(["--data-dir", str(self.data), "--json", "snapshot"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout.getvalue())["schema_version"], 1)
        self.assertIn("W_CAPACITY", stderr.getvalue())
        self.assertIn(str(size), stderr.getvalue())

    def test_help_environment_and_config_error(self):
        result = subprocess.run([sys.executable, "-m", "taskhub", "--help"], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0)
        self.assertIn("sync", result.stdout)
        env = dict(os.environ, TASKHUB_DATA_DIR=str(self.data))
        result = subprocess.run([sys.executable, "-m", "taskhub", "lane", "list", "--json"],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["data"], [])
        result = self.run_cli("sync", expected=2)
        self.assertEqual(result["error"]["code"], "E_INPUT")


if __name__ == "__main__":
    unittest.main()
