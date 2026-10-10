"""Deterministic event reduction for the snapshot v1 contract."""

from __future__ import annotations

import re
from uuid import UUID

from .common import TaskHubError, normalized, text, timestamp

KINDS = {"lane": "lanes", "task": "tasks", "decision": "decisions",
         "comment": "comments", "attachment": "attachments"}
PREFIXES = {"lane": "l", "task": "t", "decision": "d", "comment": "c", "attachment": "a"}
TASK_STATUSES = frozenset({"todo", "in_progress", "awaiting_user", "blocked", "done", "on_hold"})
DECISION_STATUSES = frozenset({"pending", "answered", "applied"})
PRIORITIES = frozenset({"low", "normal", "high", "urgent"})
TASK_FIELDS = {"title", "body", "parent_id", "priority", "due_at", "assignee", "amount", "method", "rationale"}
PAYLOADS = {
    "lane.created": ({"id", "name"}, {"description"}),
    "lane.updated": ({"id", "changes"}, set()),
    "task.created": ({"id", "lane_id", "title"}, TASK_FIELDS - {"title"}),
    "task.updated": ({"id", "changes"}, set()),
    "task.completed": ({"id", "evidence", "verified"}, set()),
    "task.reopened": ({"id", "reason"}, set()),
    "comment.added": ({"id", "target_type", "target_id", "body"}, set()),
    "decision.created": ({"id", "task_id", "title", "body", "reason"}, {"options", "due_at"}),
    "decision.answered": ({"id", "answer", "respondent"}, set()),
    "decision.applied": ({"id", "evidence"}, {"resume"}),
    "attachment.added": ({"id", "target_type", "target_id", "filename", "description", "media_type",
                          "size_bytes", "sha256", "blob_path"}, set()),
}


def _require(condition, message, code="E_INPUT"):
    if not condition:
        raise TaskHubError(code, message)


def _keys(value, required, optional=()):
    _require(isinstance(value, dict), "オブジェクトを指定する")
    _require(required <= value.keys() and value.keys() <= required | set(optional),
             "必須キーの不足、または未定義のキー")


def _choice(value, choices, name):
    _require(isinstance(value, str) and value in choices, f"不正な{name}")
    return value


def _id(kind, value):
    _choice(kind, KINDS, "種別")
    pattern = PREFIXES[kind] + r"_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}"
    _require(isinstance(value, str) and re.fullmatch(pattern, value) is not None, f"不正な{kind} ID")
    return value


def find(snapshot: dict, kind: str, entity_id: str) -> dict:
    """Return an existing entity, checking both its ID type and existence."""
    _id(kind, entity_id)
    for entity in snapshot[KINDS[kind]]:
        if entity["id"] == entity_id:
            return entity
    raise TaskHubError("E_NOT_FOUND", f"{kind} が存在しない: {entity_id}")


def empty_snapshot(manifest: dict) -> dict:
    _keys(manifest, {"schema_version", "store_id", "created_at"})
    _require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1,
             "未対応のschema_version")
    value = manifest["store_id"]
    try:
        valid = isinstance(value, str) and str(UUID(value)) == value
    except ValueError:
        valid = False
    _require(valid, "不正なstore_id")
    timestamp(manifest["created_at"])
    return {"schema_version": 1, "store_id": value, "last_event_seq": 0,
            "last_event_hash": None, "generated_at": None, **{key: [] for key in KINDS.values()}}


def _revision(entity, payload):
    if "if_revision" in payload:
        _require(entity is not None, "新規レーンにはif_revisionを指定できない")
        _require(type(payload["if_revision"]) is int and payload["if_revision"] >= 1,
                 "if_revisionは正の整数")
        _require(payload["if_revision"] == entity["revision"], "revisionが一致しない", "E_CONFLICT")


def _touch(entity, event):
    entity.update(updated_at=event["occurred_at"], updated_by=event["actor"], revision=event["seq"])


def _created(entity_id, event):
    return {"id": entity_id, "created_at": event["occurred_at"], "created_by": event["actor"],
            "updated_at": event["occurred_at"], "updated_by": event["actor"], "revision": event["seq"]}


def _add(snapshot, kind, entity):
    entities = snapshot[KINDS[kind]]
    entities.append(entity)
    entities.sort(key=(lambda item: (item["event_seq"], item["id"]))
                  if kind in {"comment", "attachment"} else (lambda item: item["id"]))


def _name(snapshot, value, entity_id):
    text(value, "name", limit=512, single_line=True)
    _require(not any(item["id"] != entity_id and normalized(item["name"]) == normalized(value)
                     for item in snapshot["lanes"]), "同名レーンが存在する", "E_CONFLICT")
    return value


def _parent(snapshot, parent_id, lane_id, entity_id):
    if parent_id is None:
        return None
    parent = find(snapshot, "task", parent_id)
    _require(parent["lane_id"] == lane_id, "親タスクは同じレーンに限定する")
    seen = {entity_id}
    while parent is not None:
        _require(parent["id"] not in seen, "親子関係の循環は禁止する")
        seen.add(parent["id"])
        parent = find(snapshot, "task", parent["parent_id"]) if parent["parent_id"] else None
    return parent_id


def _money(value):
    if value is None:
        return None
    _keys(value, {"value", "currency"})
    amount = text(value["value"], "amount.value")
    currency = text(value["currency"], "amount.currency", limit=3, single_line=True)
    _require(re.fullmatch(r"(0|[1-9][0-9]*)(\.[0-9]{1,6})?", amount) is not None, "金額は非負の十進文字列")
    _require(re.fullmatch(r"[A-Z]{3}", currency) is not None, "通貨は英大文字3文字")
    return {"value": amount, "currency": currency}


def _task_changes(snapshot, changes, lane_id, entity_id):
    _keys(changes, set(), TASK_FIELDS | {"status"})
    result = {}
    for key, value in changes.items():
        if key == "title":
            value = text(value, key, limit=512, single_line=True)
        elif key in {"body", "method", "rationale"}:
            value = text(value, key, required=False)
        elif key == "parent_id":
            value = _parent(snapshot, value, lane_id, entity_id)
        elif key == "priority":
            value = _choice(value, PRIORITIES, "priority")
        elif key == "status":
            value = _choice(value, TASK_STATUSES - {"done"}, "status（完了はcompleteを使う）")
        elif key == "due_at":
            value = timestamp(value) if value is not None else None
        elif key == "assignee":
            value = text(value, key, limit=128, single_line=True) if value is not None else None
        elif key == "amount":
            value = _money(value)
        result[key] = value
    return result


def _target(snapshot, payload, kinds):
    kind = _choice(payload["target_type"], kinds, "target_type")
    target = find(snapshot, kind, payload["target_id"])
    if kind == "comment":
        target = find(snapshot, target["target_type"], target["target_id"])
    _revision(target, payload)
    return target


def _attachment(payload):
    filename = text(payload["filename"], "filename", limit=255, single_line=True)
    _require(filename not in {".", ".."} and not any(c in filename for c in "/\\"), "filenameに区切り文字は禁止する")
    description = text(payload["description"], "description", required=False)
    media = text(payload["media_type"], "media_type", limit=255, single_line=True)
    token = r"[A-Za-z0-9!#$%&'*+.^_`|~-]+"
    _require(re.fullmatch(token + "/" + token, media) is not None, "不正なmedia_type")
    size, sha = payload["size_bytes"], payload["sha256"]
    _require(type(size) is int and size >= 0, "size_bytesは非負整数")
    _require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{64}", sha) is not None, "不正なsha256")
    _require(payload["blob_path"] == f"blobs/sha256/{sha[:2]}/{sha}", "blob_pathがsha256と一致しない")
    return {"filename": filename, "description": description, "media_type": media,
            "size_bytes": size, "sha256": sha, "blob_path": payload["blob_path"]}


def apply_event(snapshot: dict, event: dict) -> None:
    """Validate before mutation; store owns the root sequence/hash/timestamp.

    Comment attachments compare if_revision against the owning task/decision.
    Creates compare against the lane (task) or task (decision); lane creates
    have no revision target. Creating a child does not touch its ancestor.
    """
    _require(isinstance(event, dict), "イベントはオブジェクト")
    _require({"schema_version", "seq", "type", "payload", "actor", "occurred_at"} <= event.keys(),
             "イベントの必須キーが不足")
    _require(type(event["schema_version"]) is int and event["schema_version"] == 1, "未対応のschema_version")
    _require(type(event["seq"]) is int and event["seq"] >= 1, "seqは正の整数")
    text(event["actor"], "actor", limit=128, single_line=True)
    timestamp(event["occurred_at"])
    event_type = _choice(event["type"], PAYLOADS, "イベント種別")
    payload = event["payload"]
    required, optional = PAYLOADS[event_type]
    _keys(payload, required, optional | {"if_revision"})
    kind, action = event_type.split(".")
    entity_id = _id(kind, payload["id"])
    creating = action in {"created", "added"}
    if creating:
        _require(not any(item["id"] == entity_id for item in snapshot[KINDS[kind]]), "IDが重複する", "E_CONFLICT")
    else:
        entity = find(snapshot, kind, entity_id)
        _revision(entity, payload)

    if event_type == "lane.created":
        _revision(None, payload)
        entity = {**_created(entity_id, event), "name": _name(snapshot, payload["name"], entity_id),
                  "description": text(payload.get("description", ""), "description", required=False)}
        _add(snapshot, kind, entity)
    elif event_type == "lane.updated":
        changes = payload["changes"]
        _keys(changes, set(), {"name", "description"})
        _require(bool(changes), "changesは空にできない")
        changes = {key: _name(snapshot, value, entity_id) if key == "name"
                   else text(value, key, required=False) for key, value in changes.items()}
        entity.update(changes)
        _touch(entity, event)
    elif event_type == "task.created":
        lane = find(snapshot, "lane", payload["lane_id"])
        _revision(lane, payload)
        values = {"title": payload["title"], "body": "", "parent_id": None, "priority": "normal", "due_at": None,
                  "assignee": None, "amount": None, "method": "", "rationale": ""}
        values.update({key: value for key, value in payload.items() if key in TASK_FIELDS})
        values = _task_changes(snapshot, values, lane["id"], entity_id)
        _add(snapshot, kind, {**_created(entity_id, event), **values, "lane_id": lane["id"],
                              "status": "todo", "completion": None})
    elif event_type == "task.updated":
        _require(entity["status"] != "done", "完了済みタスクは先にreopenする", "E_STATE")
        changes = _task_changes(snapshot, payload["changes"], entity["lane_id"], entity_id)
        _require(bool(changes), "changesは空にできない")
        entity.update(changes)
        _touch(entity, event)
    elif event_type == "task.completed":
        _require(entity["status"] != "done", "すでに完了済み", "E_STATE")
        evidence = text(payload["evidence"], "evidence")
        _require(payload["verified"] is True, "完了には明示的なverifiedが必須")
        entity.update(status="done", completion={"evidence": evidence, "verified_by": event["actor"],
                                                 "verified_at": event["occurred_at"]})
        _touch(entity, event)
    elif event_type == "task.reopened":
        _require(entity["status"] == "done", "完了済みタスクだけreopenできる", "E_STATE")
        text(payload["reason"], "reason")
        entity.update(status="todo", completion=None)
        _touch(entity, event)
    elif event_type == "decision.created":
        task = find(snapshot, "task", payload["task_id"])
        _revision(task, payload)
        options = payload.get("options", [])
        _require(isinstance(options, list), "optionsは文字列配列")
        entity = {**_created(entity_id, event), "task_id": task["id"], "lane_id": task["lane_id"],
                  "title": text(payload["title"], "title", limit=512, single_line=True),
                  "body": text(payload["body"], "body"), "reason": text(payload["reason"], "reason"),
                  "options": [text(option, "option") for option in options],
                  "due_at": timestamp(payload["due_at"]) if payload.get("due_at") is not None else None,
                  "status": "pending", "answer": None, "application": None}
        _add(snapshot, kind, entity)
    elif event_type == "decision.answered":
        _require(entity["status"] == "pending", "未対応裁定だけ回答できる", "E_STATE")
        answer = {"text": text(payload["answer"], "answer"),
                  "respondent": text(payload["respondent"], "respondent", limit=128, single_line=True),
                  "recorded_by": event["actor"], "recorded_at": event["occurred_at"]}
        entity.update(status="answered", answer=answer)
        _touch(entity, event)
    elif event_type == "decision.applied":
        _require(entity["status"] == "answered", "回答済み裁定だけ反映できる", "E_STATE")
        evidence = text(payload["evidence"], "evidence")
        resume = payload.get("resume", False)
        _require(type(resume) is bool, "resumeは真偽値")
        task = find(snapshot, "task", entity["task_id"])
        _require(not resume or task["status"] in {"blocked", "awaiting_user"},
                 "resumeはblocked/awaiting_userのタスクに限定する", "E_STATE")
        entity.update(status="applied", application={"evidence": evidence, "applied_by": event["actor"],
                                                    "applied_at": event["occurred_at"], "resumed_task": resume})
        _touch(entity, event)
        if resume:
            task["status"] = "in_progress"
            _touch(task, event)
    else:
        target = _target(snapshot, payload, {"task", "decision"} if kind == "comment"
                         else {"task", "decision", "comment"})
        values = {"body": text(payload["body"], "body")} if kind == "comment" else _attachment(payload)
        entity = {"id": entity_id, "target_type": payload["target_type"], "target_id": payload["target_id"],
                  **values, "created_at": event["occurred_at"], "created_by": event["actor"], "event_seq": event["seq"]}
        _add(snapshot, kind, entity)
        _touch(target, event)
