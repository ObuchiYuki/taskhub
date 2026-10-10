"""Read-only Unicode search, selection, and deterministic Japanese digests."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime

from .common import TaskHubError, normalized, text, timestamp, utc_now
from .domain import DECISION_STATUSES, TASK_STATUSES, find


def _validate_filters(snapshot, kind, lane, status, since, until, assignee):
    if not isinstance(kind, str) or kind not in {"task", "decision", "lane"}:
        raise TaskHubError("E_INPUT", "種別はtask/decision/lane")
    if lane is not None:
        find(snapshot, "lane", lane)
    statuses = TASK_STATUSES if kind == "task" else DECISION_STATUSES | {"open"} if kind == "decision" else set()
    if status is not None and (not isinstance(status, str) or status not in statuses):
        raise TaskHubError("E_INPUT", f"{kind}に指定できないstatus")
    if since is not None:
        timestamp(since)
    if until is not None:
        timestamp(until)
    if since is not None and until is not None and since >= until:
        raise TaskHubError("E_INPUT", "sinceはuntilより前の日時")
    if assignee is not None:
        text(assignee, "assignee", limit=128, single_line=True)
        if kind == "lane":
            raise TaskHubError("E_INPUT", "laneにassigneeは指定できない")


def select(snapshot: dict, kind: str, *, lane=None, status=None, since=None, until=None, assignee=None) -> list:
    """Filter updated_at in [since, until); omitted status includes all states."""
    _validate_filters(snapshot, kind, lane, status, since, until, assignee)
    result = []
    tasks = {item["id"]: item for item in snapshot["tasks"]}
    for item in snapshot[{"task": "tasks", "decision": "decisions", "lane": "lanes"}[kind]]:
        if lane is not None and (item["id"] if kind == "lane" else item["lane_id"]) != lane:
            continue
        if status is not None and (item["status"] not in {"pending", "answered"}
                                   if status == "open" else item["status"] != status):
            continue
        if since is not None and item["updated_at"] < since:
            continue
        if until is not None and item["updated_at"] >= until:
            continue
        if assignee is not None:
            task = tasks[item["task_id"]] if kind == "decision" else item
            if task["assignee"] != assignee:
                continue
        result.append(item)
    return sorted(result, key=lambda item: item["id"])


def _fields(kind, item):
    for field in ("title", "body", "method", "rationale") if kind == "task" else ("title", "body", "reason"):
        yield field, item[field]
    if kind == "task":
        if item["completion"] is not None:
            yield "completion.evidence", item["completion"]["evidence"]
    else:
        for option in item["options"]:
            yield "options", option
        if item["answer"] is not None:
            yield "answer.text", item["answer"]["text"]
        if item["application"] is not None:
            yield "application.evidence", item["application"]["evidence"]


def search(snapshot: dict, query: str, **filters) -> list:
    """Aggregate matches by task/decision, including comment attachment ancestry."""
    needle = normalized(text(query, "query"))
    if filters.keys() - {"lane", "status", "since", "until", "assignee"}:
        raise TaskHubError("E_INPUT", "未定義の検索フィルタ")
    status = filters.get("status")
    if status is not None and (not isinstance(status, str) or status not in TASK_STATUSES | DECISION_STATUSES | {"open"}):
        raise TaskHubError("E_INPUT", "不正なstatus")
    selected = {}
    for kind, statuses in (("task", TASK_STATUSES), ("decision", DECISION_STATUSES | {"open"})):
        if status is None or status in statuses:
            for item in select(snapshot, kind, **filters):
                selected[kind, item["id"]] = item
    matches = defaultdict(set)

    def match(owner, source_type, source_id, fields):
        if owner in selected:
            for field, value in fields:
                if needle in normalized(value):
                    matches[owner].add((source_type, source_id, field))

    for owner, item in selected.items():
        match(owner, owner[0], item["id"], _fields(owner[0], item))
    comments = {}
    for item in snapshot["comments"]:
        owner = item["target_type"], item["target_id"]
        comments[item["id"]] = owner
        match(owner, "comment", item["id"], [("body", item["body"])])
    for item in snapshot["attachments"]:
        owner = (comments[item["target_id"]] if item["target_type"] == "comment"
                 else (item["target_type"], item["target_id"]))
        match(owner, "attachment", item["id"], [(field, item[field]) for field in ("filename", "description")])
    result = []
    for owner in sorted(matches):
        item = selected[owner]
        entry = {"type": owner[0], **{key: item[key] for key in ("id", "lane_id", "title", "status")},
                 "matches": [{"type": kind, "id": entity_id, "field": field}
                             for kind, entity_id, field in sorted(matches[owner])]}
        if owner[0] == "decision":
            entry["task_id"] = item["task_id"]
        result.append(entry)
    return result


def _date(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")


def _ref(kind, item):
    return {"type": kind, **{key: item[key] for key in ("id", "title", "lane_id", "due_at")}}


def _order(item):
    return item["due_at"] is None, item["due_at"] or "", item["id"]


def _line(item):
    kind = "タスク" if item["type"] == "task" else "裁定"
    return f"- {kind} {item['id']} {item['title']}（{item['due_at'] or '期限なし'}）"


def digest(snapshot: dict, *, now=None, upcoming_hours=72, stale_days=7, lane=None) -> dict:
    """Use explicit UTC time for reproducible, read-only rule-based summaries."""
    as_of = timestamp(utc_now() if now is None else now)
    for name, value in (("upcoming_hours", upcoming_hours), ("stale_days", stale_days)):
        if type(value) is not int or value < 0:
            raise TaskHubError("E_INPUT", f"{name}は非負整数")
    current = _date(as_of)
    active = [(kind, item) for kind in ("task", "decision") for item in select(snapshot, kind, lane=lane)
              if item["status"] not in {"done", "applied"}]
    result = {"as_of": as_of, "overdue": [], "upcoming": [], "stale": [], "duplicates": [], "decisions": []}
    groups = defaultdict(list)
    for kind, item in active:
        reference = _ref(kind, item)
        if item["due_at"] is not None:
            seconds = (_date(item["due_at"]) - current).total_seconds()
            if seconds < 0:
                result["overdue"].append(reference)
            elif seconds <= upcoming_hours * 3600:
                result["upcoming"].append(reference)
        if (current - _date(item["updated_at"])).total_seconds() >= stale_days * 86400:
            result["stale"].append(reference)
        if kind == "decision":
            result["decisions"].append(reference)
        else:
            groups[item["lane_id"], " ".join(normalized(item["title"]).split())].append(reference)
    for (lane_id, title), items in groups.items():
        if len(items) > 1:
            result["duplicates"].append({"lane_id": lane_id, "title": title, "tasks": sorted(items, key=_order)})
    for key in ("overdue", "upcoming", "stale", "decisions"):
        result[key].sort(key=_order)
    result["duplicates"].sort(key=lambda group: _order(group["tasks"][0]))
    lines = []
    for key, label in (("overdue", "期限切れ"), ("upcoming", "期限間近"), ("stale", "停滞"),
                       ("duplicates", "重複候補"), ("decisions", "ユーザー裁定")):
        lines.append(f"{label}: {len(result[key])}件")
        if key == "duplicates":
            for group in result[key]:
                lines.append(f"- {group['lane_id']} / {group['title']}（{len(group['tasks'])}件）")
                lines.extend("  " + _line(item) for item in group["tasks"])
        else:
            lines.extend(_line(item) for item in result[key])
    result["text"] = "\n".join(lines)
    return result
