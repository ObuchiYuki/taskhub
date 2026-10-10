#!/usr/bin/env python3
"""Generate committed fixtures with the unmodified local server CLI; no network access."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT.parent / "server"
FIXTURES = ROOT / "Tests" / "TaskHubCoreTests" / "Fixtures"


def main():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (ROOT / "App" / "Resources").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="taskhub-ios-demo-", dir="/tmp") as scratch:
        scratch = Path(scratch)
        store = scratch / "store"
        evidence = scratch / "evidence.txt"
        evidence.write_bytes(b"")

        def raw(*args, actor="agent-ios"):
            result = subprocess.run(
                [sys.executable, "-B", "-m", "taskhub", "--data-dir", str(store),
                 "--actor", actor, "--json", *args],
                cwd=SERVER, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                check=True, capture_output=True,
            )
            return result.stdout

        def cli(*args, actor="agent-ios"):
            response = json.loads(raw(*args, actor=actor))
            if not response["ok"]:
                raise RuntimeError(response)
            return response["data"]

        cli("init")
        (FIXTURES / "empty-snapshot.json").write_bytes(raw("snapshot"))
        app = cli("lane", "add", "--name", "TaskHub アプリ", "--description", "Mac・iOSの読み取り専用クライアント")["id"]
        operations = cli("lane", "add", "--name", "運用・リサーチ", "--description", "共有サーバーの安全な運用", actor="agent-ops")["id"]

        def task(title, *, lane=app, status="todo", due=None, priority="normal", parent=None,
                 assignee="agent-ios", body="依頼を記録し、結果を確認してから完了する。", extra=()):
            args = ["task", "add", "--lane", lane, "--title", title, "--body", body,
                    "--priority", priority, "--assignee", assignee, "--method", "ローカルで検証して作業ログへ追記",
                    "--rationale", "情報を外部公開せず、根拠を追跡できる形で残す。", *extra]
            if due:
                args += ["--due-at", due]
            if parent:
                args += ["--parent", parent]
            identifier = cli(*args)["id"]
            if status == "done":
                cli("task", "complete", identifier, "--verified", "--evidence", "CLIのsnapshot・fsckが成功。空の標準エラーを確認した。")
            elif status != "todo":
                cli("task", "update", identifier, "--status", status)
            return identifier

        main_task = task("読み取り専用アプリを仕上げる", status="awaiting_user", due="2026-10-12T09:00:00Z", priority="high")
        sync_task = task("同期方式の最終確認", status="awaiting_user", due="2026-10-10T09:00:00Z", priority="urgent",
                         body="private GitHubのスナップショットを読み、失敗時は前回データを残す。")
        signing = task("署名設定の確認", status="blocked", due="2026-10-09T09:00:00Z", priority="high")
        task("アクセシビリティを検証する", due="2026-10-13T08:00:00Z", parent=main_task,
             body="Dynamic Type・VoiceOver・状態ラベルの見え方を点検する。")
        done = task("スナップショット契約を検証する", status="done", due="2026-10-09T12:00:00Z",
                    extra=("--amount", "0", "--currency", "JPY"))
        task("ホーム画面ウィジェットを検討する", status="on_hold", priority="low")
        backup = task("週次バックアップを確認する", lane=operations, due="2026-10-11T12:00:00Z", assignee="agent-ops",
                      extra=("--amount", "1200.50", "--currency", "JPY"))
        task("Ｓｙｎｃ  Ｒｅｖｉｅｗ", due="2026-10-11T09:00:00Z")
        task("sync review", status="in_progress", due="2026-10-12T09:00:00Z")
        task("検索と絞り込みを接続する", status="in_progress", due="2026-10-12T06:00:00Z", parent=main_task,
             body="全角英数字・Straße・追記と添付説明のUnicode部分一致を確認する。")

        pending = cli("decision", "add", "--task", sync_task, "--title", "同期先リポジトリを選んでほしい",
                      "--body", "閲覧用データを置くprivateリポジトリを指定してほしい。",
                      "--reason", "公開先をエージェントだけで決めない。", "--option", "専用privateリポジトリ",
                      "--option", "既存privateリポジトリ", "--due-at", "2026-10-10T10:00:00Z")["id"]
        answered = cli("decision", "add", "--task", backup, "--title", "通知の頻度を確認したい",
                       "--body", "バックアップ確認の頻度を選んでほしい。", "--reason", "運用負荷と確認頻度を揃える。",
                       "--option", "30分ごと", "--option", "1時間ごと", "--due-at", "2026-10-12T12:00:00Z")["id"]
        cli("decision", "answer", answered, "--answer", "30分ごとの確認を希望する。", "--respondent", "yuki", actor="agent-ops")
        applied = cli("decision", "add", "--task", main_task, "--title", "表示言語を日本語に統一する",
                      "--body", "状態とダイジェストの表示言語を確認する。", "--reason", "タスク確認の負荷を減らす。",
                      "--option", "日本語", "--option", "英語")["id"]
        cli("decision", "answer", applied, "--answer", "日本語で統一する。", "--respondent", "yuki")
        cli("decision", "apply", applied, "--evidence", "日本語の状態ラベルとダイジェストへ反映し、作業を再開した。", "--resume")
        cli("decision", "add", "--task", signing, "--title", "署名アカウントの確認",
            "--body", "実機向け署名に使うアカウントを確認してほしい。", "--reason", "本人の資格情報は代理で作成しない。",
            "--option", "既存アカウントで進める", "--option", "実機配布を保留する")
        comment = cli("comment", "add", "--task", done, "--body", "契約検証の作業ログ。終了コード0、標準エラー0バイト。証拠ファイルを添付。")["id"]
        cli("comment", "add", "--task", main_task, "--body", "閲覧画面を実装中。接続設定を保存するまで通信しない。")
        decision_comment = cli("comment", "add", "--decision", pending,
                               "--body", "候補はいずれもprivate。比較資料の説明を確認してから回答してほしい。")["id"]
        cli("attachment", "add", "--comment", comment, "--file", str(evidence), "--description", "検証時の空の標準エラー。成功の証拠。")
        cli("attachment", "add", "--task", done, "--file", str(evidence), "--description", "タスク直接添付の空テキスト。")
        cli("attachment", "add", "--decision", pending, "--file", str(evidence), "--description", "裁定の比較メモ用空テキスト。")
        cli("attachment", "add", "--comment", decision_comment, "--file", str(evidence), "--description", "裁定追記添付の比較資料。")
        cli("fsck")
        snapshot = raw("snapshot")
        (ROOT / "App" / "Resources" / "demo-snapshot.json").write_bytes(snapshot)
        (FIXTURES / "server-snapshot.json").write_bytes(snapshot)
        (FIXTURES / "evidence.txt").write_bytes(evidence.read_bytes())
        (FIXTURES / "server-digest.json").write_bytes(raw("digest", "--now", "2026-10-10T12:00:00Z"))
        document = json.loads(snapshot)
        (FIXTURES / "unknown-schema.json").write_text('{"schema_version":2,"tasks":"future format"}\n')
        malformed = {**document, "tasks": document["tasks"] + [document["tasks"][0]]}
        (FIXTURES / "duplicate-id.json").write_text(json.dumps(malformed, ensure_ascii=False) + "\n")
        print(json.dumps({"store_id": document["store_id"], "last_event_seq": document["last_event_seq"],
                          "tasks": [{"id": item["id"], "title": item["title"]} for item in document["tasks"]]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
