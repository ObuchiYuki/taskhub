"""Command-line interface; all persistent domain changes go through Store.mutate."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import domain, query, sync, store as storage
from .common import MAX_TEXT_BYTES, TaskHubError, text
from .store import Store, read_regular


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise TaskHubError("E_INPUT", message)


def text_arg(parser, name, *, required=False):
    group = parser.add_mutually_exclusive_group(required=required)
    group.add_argument("--" + name)
    group.add_argument("--" + name + "-file", metavar="PATH")


def target_arg(parser, *, comment=False):
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--task")
    group.add_argument("--decision")
    if comment:
        group.add_argument("--comment")


def filters(parser, *, status=True):
    parser.add_argument("--lane")
    if status:
        parser.add_argument("--status")
    parser.add_argument("--assignee")
    parser.add_argument("--since")
    parser.add_argument("--until")


def attributes(parser, *, create=False):
    parser.add_argument("--title", required=create)
    text_arg(parser, "body")
    parser.add_argument("--parent", dest="parent_id")
    parser.add_argument("--priority", choices=("low", "normal", "high", "urgent"))
    parser.add_argument("--due-at")
    parser.add_argument("--assignee")
    parser.add_argument("--amount")
    parser.add_argument("--currency")
    parser.add_argument("--method")
    parser.add_argument("--rationale")
    if not create:
        parser.add_argument("--status", choices=("todo", "in_progress", "awaiting_user", "blocked", "done", "on_hold"))
        parser.add_argument("--clear", action="append", default=[], choices=("parent", "due_at", "assignee", "amount"))


def build_parser():
    parser = Parser(prog="taskhub", description="共有サーバーのprivateタスク管理CLI",
                    epilog="共通オプション: --data-dir PATH --actor NAME --json --lock-timeout SECONDS "
                           "--request-id UUID --if-revision N。TASKHUB_DATA_DIRも使用可能。")
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="空の専用データ領域を初期化（ローカルのみ）")
    init.add_argument("--repo")
    init.add_argument("--branch", default="main")
    lane = commands.add_parser("lane").add_subparsers(dest="action", required=True)
    add = lane.add_parser("add")
    add.add_argument("--name", required=True)
    add.add_argument("--description", default="")
    update = lane.add_parser("update")
    update.add_argument("id")
    update.add_argument("--name")
    update.add_argument("--description")
    lane.add_parser("list")
    task = commands.add_parser("task").add_subparsers(dest="action", required=True)
    add = task.add_parser("add")
    add.add_argument("--lane", dest="lane_id", required=True)
    attributes(add, create=True)
    update = task.add_parser("update")
    update.add_argument("id")
    attributes(update)
    for action in ("show", "history"):
        task.add_parser(action).add_argument("id")
    filters(task.add_parser("list"))
    complete = task.add_parser("complete")
    complete.add_argument("id")
    text_arg(complete, "evidence", required=True)
    complete.add_argument("--verified", action="store_true")
    reopen = task.add_parser("reopen")
    reopen.add_argument("id")
    reopen.add_argument("--reason", required=True)
    comment = commands.add_parser("comment").add_subparsers(dest="action", required=True)
    add = comment.add_parser("add")
    target_arg(add)
    text_arg(add, "body", required=True)
    decision = commands.add_parser("decision").add_subparsers(dest="action", required=True)
    add = decision.add_parser("add")
    add.add_argument("--task", dest="task_id", required=True)
    add.add_argument("--title", required=True)
    text_arg(add, "body", required=True)
    add.add_argument("--reason", required=True)
    add.add_argument("--option", dest="options", action="append", default=[])
    add.add_argument("--due-at")
    answer = decision.add_parser("answer")
    answer.add_argument("id")
    text_arg(answer, "answer", required=True)
    answer.add_argument("--respondent", required=True)
    apply = decision.add_parser("apply")
    apply.add_argument("id")
    text_arg(apply, "evidence", required=True)
    apply.add_argument("--resume", action="store_true")
    for action in ("show", "history"):
        decision.add_parser(action).add_argument("id")
    listing = decision.add_parser("list")
    filters(listing)
    listing.set_defaults(status="open")
    attachment = commands.add_parser("attachment").add_subparsers(dest="action", required=True)
    add = attachment.add_parser("add")
    target_arg(add, comment=True)
    add.add_argument("--file", required=True)
    add.add_argument("--description", required=True)
    search = commands.add_parser("search")
    search.add_argument("query")
    filters(search)
    digest = commands.add_parser("digest")
    digest.add_argument("--now")
    digest.add_argument("--upcoming-hours", type=int, default=72)
    digest.add_argument("--stale-days", type=int, default=7)
    digest.add_argument("--lane")
    for command in ("snapshot", "rebuild", "fsck", "sync-status"):
        commands.add_parser(command)
    synchronize = commands.add_parser("sync")
    synchronize.add_argument("--repo")
    synchronize.add_argument("--branch")
    return parser


def text_value(args, name):
    path = getattr(args, name + "_file", None)
    if path is None:
        return getattr(args, name, None)
    try:
        return read_regular(Path(path), MAX_TEXT_BYTES, private=False).decode("utf-8")
    except UnicodeError as exc:
        raise TaskHubError("E_INPUT", f"{name}-fileはUTF-8で保存する") from exc


def collect(args, *keys):
    return {key: getattr(args, key) for key in keys if getattr(args, key, None) is not None}


def task_attributes(args):
    fields = collect(args, "title", "parent_id", "priority", "due_at", "assignee", "method", "rationale", "status")
    body = text_value(args, "body")
    if body is not None:
        fields["body"] = body
    if bool(args.amount is not None) != bool(args.currency is not None):
        raise TaskHubError("E_INPUT", "amountとcurrencyを同時に指定する")
    if args.amount is not None:
        fields["amount"] = {"value": args.amount, "currency": args.currency}
    for field in getattr(args, "clear", []):
        key = "parent_id" if field == "parent" else field
        if key in fields:
            raise TaskHubError("E_INPUT", f"{field}の設定とclearを併用できない")
        fields[key] = None
    return fields


def target(args):
    for kind in ("task", "decision", "comment"):
        if getattr(args, kind, None) is not None:
            return {"target_type": kind, "target_id": getattr(args, kind)}
    raise TaskHubError("E_INPUT", "対象を指定する")


def make_mutation(args):
    key = (args.command, getattr(args, "action", None))
    if key == ("lane", "add"):
        return "lane.created", collect(args, "name", "description")
    if key == ("lane", "update"):
        return "lane.updated", {"id": args.id, "changes": collect(args, "name", "description")}
    if key == ("task", "add"):
        return "task.created", {"lane_id": args.lane_id, **task_attributes(args)}
    if key == ("task", "update"):
        return "task.updated", {"id": args.id, "changes": task_attributes(args)}
    if key == ("task", "complete"):
        return "task.completed", {"id": args.id, "evidence": text_value(args, "evidence"), "verified": args.verified}
    if key == ("task", "reopen"):
        return "task.reopened", collect(args, "id", "reason")
    if key == ("comment", "add"):
        return "comment.added", {**target(args), "body": text_value(args, "body")}
    if key == ("decision", "add"):
        return "decision.created", {**collect(args, "task_id", "title", "reason", "options", "due_at"),
                                    "body": text_value(args, "body")}
    if key == ("decision", "answer"):
        return "decision.answered", {**collect(args, "id", "respondent"), "answer": text_value(args, "answer")}
    if key == ("decision", "apply"):
        return "decision.applied", {**collect(args, "id", "resume"), "evidence": text_value(args, "evidence")}
    if key == ("attachment", "add"):
        return "attachment.added", {**target(args), "description": args.description}
    return None


def details(snapshot, kind, entity_id):
    entity = domain.find(snapshot, kind, entity_id)
    comments = [item for item in snapshot["comments"] if item["target_type"] == kind and item["target_id"] == entity_id]
    comment_ids = {item["id"] for item in comments}
    attachments = [item for item in snapshot["attachments"]
                   if (item["target_type"] == kind and item["target_id"] == entity_id) or
                   (item["target_type"] == "comment" and item["target_id"] in comment_ids)]
    result = {kind: entity, "comments": comments, "attachments": attachments}
    if kind == "task":
        result["subtasks"] = [item for item in snapshot["tasks"] if item["parent_id"] == entity_id]
        result["decisions"] = [item for item in snapshot["decisions"] if item["task_id"] == entity_id]
    return result


def execute(args, global_args):
    path = global_args.data_dir or os.environ.get("TASKHUB_DATA_DIR")
    if not path:
        raise TaskHubError("E_INPUT", "--data-dirまたはTASKHUB_DATA_DIRで専用データ領域を指定する")
    store = Store(path, global_args.lock_timeout)
    global_args.store = store
    mutation = make_mutation(args)
    if mutation or args.command in {"init", "sync"}:
        text(global_args.actor, "actor", limit=128, single_line=True)
    if mutation:
        event_type, payload = mutation
        data = store.mutate(event_type, payload, global_args.actor, request_id=global_args.request_id,
                            if_revision=global_args.if_revision,
                            source=args.file if args.command == "attachment" else None)
        return data, data["event_seq"]
    if global_args.request_id or global_args.if_revision is not None:
        raise TaskHubError("E_INPUT", "request-id/if-revisionはドメイン変更コマンドで指定する")
    if args.command == "init":
        result = store.initialize(global_args.actor, args.repo, args.branch)
        return {"store_id": result["store_id"], "data_dir": str(store.path)}, 0
    if args.command == "sync":
        return sync.sync(store, global_args.actor, args.repo, args.branch), None
    if args.command == "sync-status":
        return sync.status(store), None
    if args.command == "fsck":
        result = store.fsck()
        return result, result["events"]
    if getattr(args, "action", None) == "history":
        return store.history(args.command, args.id), len(store.events)
    snapshot = store.read()
    seq = snapshot["last_event_seq"]
    if args.command in {"snapshot", "rebuild"}:
        return snapshot, seq
    if args.command == "search":
        return query.search(snapshot, args.query, **collect(args, "lane", "status", "since", "until", "assignee")), seq
    if args.command == "digest":
        return query.digest(snapshot, **collect(args, "now", "upcoming_hours", "stale_days", "lane")), seq
    if args.action == "list":
        return query.select(snapshot, args.command, **collect(args, "lane", "status", "since", "until", "assignee")), seq
    if args.action == "show":
        return details(snapshot, args.command, args.id), seq
    raise TaskHubError("E_INPUT", "未対応コマンド")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    common = Parser(add_help=False, allow_abbrev=False)
    common.add_argument("--data-dir")
    common.add_argument("--actor")
    common.add_argument("--json", action="store_true")
    common.add_argument("--lock-timeout", type=float, default=30)
    common.add_argument("--request-id")
    common.add_argument("--if-revision", type=int)
    os.umask(0o077)
    try:
        global_args, remaining = common.parse_known_args(argv)
        as_json = global_args.json
        args = build_parser().parse_args(remaining)
        data, seq = execute(args, global_args)
        size = global_args.store.snapshot_bytes
        if size >= storage.MAX_SNAPSHOT_BYTES * 0.8:
            print(f"W_CAPACITY: snapshot {size}/{storage.MAX_SNAPSHOT_BYTES} byte（80%以上）", file=sys.stderr)
        if args.command == "snapshot":
            output = data
        elif args.command == "digest" and not as_json:
            print(data["text"])
            return 0
        else:
            output = {"ok": True, "data": data, "event_seq": seq}
        print(json.dumps(output, ensure_ascii=False, indent=None if as_json else 2, allow_nan=False))
        return 0
    except (TaskHubError, OSError) as error:
        if not isinstance(error, TaskHubError):
            error = TaskHubError("E_IO", "ローカルI/Oに失敗した。権限・空き容量を確認する")
        envelope = {"ok": False, "error": {"code": error.code, "message": error.message,
                                          "committed_event_seq": error.committed_event_seq}}
        if error.entity_id is not None:
            envelope["error"]["entity_id"] = error.entity_id
        if as_json:
            print(json.dumps(envelope, ensure_ascii=False))
        else:
            print(f"{error.code}: {error.message}", file=sys.stderr)
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
