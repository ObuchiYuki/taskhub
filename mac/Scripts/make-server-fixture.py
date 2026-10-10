#!/usr/bin/env python3
"""Create isolated Mac integration-test data using the sibling server CLI."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, help="New data directory; must not exist")
    args = parser.parse_args()
    server = Path(__file__).resolve().parents[2] / "server"
    if args.destination:
        directory = args.destination.resolve()
        if directory.exists():
            parser.error("destination must not exist")
    else:
        directory = Path(tempfile.mkdtemp(prefix="taskhub-mac-contract-"))
    os.umask(0o077)

    def cli(*command):
        result = subprocess.run(
            [sys.executable, "-m", "taskhub", "--data-dir", str(directory),
             "--actor", "agent-fixture", "--json", *command],
            cwd=server, capture_output=True, text=True, check=True, timeout=30,
        )
        return json.loads(result.stdout)["data"]

    cli("init")
    lane = cli("lane", "add", "--name", "TaskHub", "--description", "Mac統合検証")['id']
    other = cli("lane", "add", "--name", "個人")['id']
    parent = cli("task", "add", "--lane", lane, "--title", "Macアプリの同期検証", "--body", "依頼内容と全文検索を確認する。",
                 "--priority", "high", "--assignee", "agent-mac", "--amount", "1200.00", "--currency", "JPY",
                 "--method", "ローカルテスト", "--rationale", "外部送信を伴わず検証する", "--due-at", "2026-10-11T09:00:00Z")['id']
    cli("task", "update", parent, "--status", "awaiting_user")
    child = cli("task", "add", "--lane", lane, "--parent", parent, "--title", "検索と添付の確認", "--assignee", "agent-mac")['id']
    cli("task", "update", child, "--status", "in_progress")
    completed = cli("task", "add", "--lane", lane, "--title", "完了した検証")['id']
    cli("task", "complete", completed, "--evidence", "単体テストの実行結果と保存内容を確認した。", "--verified")
    cli("task", "add", "--lane", other, "--title", "別レーンの作業", "--assignee", "agent-other")
    pending = cli("decision", "add", "--task", parent, "--title", "同期方式を決める", "--body", "採用する同期方式を選んでほしい。",
                  "--reason", "本人の確認が必要", "--option", "GitHub private", "--option", "ローカルコピー")['id']
    answered = cli("decision", "add", "--task", parent, "--title", "保存期間の確認", "--body", "履歴の保存期間を確認してほしい。",
                   "--reason", "監査のため")['id']
    cli("decision", "answer", answered, "--answer", "すべて保存する", "--respondent", "user-fixture")
    applied = cli("decision", "add", "--task", child, "--title", "テスト範囲", "--body", "ローカルで検証するか確認してほしい。",
                  "--reason", "配備先は別途指定")['id']
    cli("decision", "answer", applied, "--answer", "ローカル検証を実施", "--respondent", "user-fixture")
    cli("decision", "apply", applied, "--evidence", "ローカル実行を確認した。")
    comment = cli("comment", "add", "--task", parent, "--body", "追記の全文検索語: 抹茶チェック")['id']
    cli("comment", "add", "--decision", pending, "--body", "選択肢の比較を追記した。")
    with tempfile.TemporaryDirectory(prefix="taskhub-mac-attachment-") as scratch:
        file = Path(scratch) / "検証結果.txt"
        file.write_text("TaskHub添付検証\n", encoding="utf-8")
        for kind, target in [("task", parent), ("decision", pending), ("comment", comment)]:
            cli("attachment", "add", "--" + kind, target, "--file", str(file), "--description", kind + "の添付説明")
    cli("fsck")
    print(directory)


if __name__ == "__main__":
    main()
