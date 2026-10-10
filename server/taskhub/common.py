"""Shared serialization, input validation, and public errors."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from datetime import datetime, timezone
from typing import Any

SCHEMA_VERSION = 1
MAX_TEXT_BYTES = 65536
MAX_EVENT_BYTES = 1048576
MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
MAX_TOTAL_BLOB_BYTES = 1024 * 1024 * 1024


class TaskHubError(Exception):
    def __init__(self, code: str, message: str, *, committed_event_seq: int | None = None,
                 entity_id: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.committed_event_seq = committed_event_seq
        self.entity_id = entity_id

    @property
    def exit_code(self) -> int:
        if self.code in {"E_CONFLICT", "E_LOCK_TIMEOUT"}:
            return 3
        if self.code in {"E_INTEGRITY", "E_COMMITTED_VIEW_STALE"}:
            return 4
        if self.code in {"E_SYNC", "E_AUTH", "E_PRIVATE", "E_TIMEOUT"}:
            return 5
        return 2


def canonical(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                       allow_nan=False) + "\n").encode("utf-8")


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def timestamp(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        raise TaskHubError("E_INPUT", "日時はUTCの YYYY-MM-DDTHH:MM:SSZ で指定する")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise TaskHubError("E_INPUT", "存在しない日時") from exc
    return value


def text(value: Any, name: str, *, required: bool = True, limit: int = MAX_TEXT_BYTES,
         single_line: bool = False) -> str:
    if not isinstance(value, str) or (required and not value.strip()):
        raise TaskHubError("E_INPUT", f"{name} に文字列を指定する（必須値は空白のみ不可）")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError as exc:
        raise TaskHubError("E_INPUT", f"{name} に不正なUnicode") from exc
    if size > limit:
        raise TaskHubError("E_INPUT", f"{name} はUTF-8で {limit} byte以下")
    if any(unicodedata.category(c) in {"Cc", "Cs"} and
           (single_line or c not in "\n\r\t") for c in value):
        raise TaskHubError("E_INPUT", f"{name} に制御文字は使用できない")
    return value


def normalized(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold()
