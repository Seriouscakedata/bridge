from __future__ import annotations

import uuid
from typing import Any

from .config import BridgePaths, read_json
from .store import (
    append_jsonl,
    backlog_path,
    channel_config_path,
    channel_dir,
    conversation_path,
    default_state,
    ensure_channel,
    folded_by_id,
    read_jsonl,
    read_state,
    utc_now,
    write_state,
)


def list_channels(paths: BridgePaths, include_archived: bool = False) -> list[dict[str, Any]]:
    if not paths.channels_dir.exists():
        return []
    out: list[dict[str, Any]] = []
    for child in sorted(paths.channels_dir.iterdir()):
        if not child.is_dir():
            continue
        cfg = read_json(child / "channel.json", {})
        if not isinstance(cfg, dict):
            cfg = {}
        cfg.setdefault("slug", child.name)
        cfg.setdefault("name", child.name)
        cfg.setdefault("archived", False)
        if cfg.get("archived") and not include_archived:
            continue
        out.append(cfg)
    return out


def create_channel(paths: BridgePaths, slug: str, name: str | None = None, description: str = "", project_root: str | None = None) -> dict[str, Any]:
    record = ensure_channel(paths, slug, name=name, description=description, project_root=project_root)
    channel_dir(paths, slug).mkdir(parents=True, exist_ok=True)
    return record


def _next_message_seq(paths: BridgePaths, channel: str) -> int:
    state = read_state(paths, channel)
    last = 0
    try:
        last = int(state.get("lastSeq", 0) or 0)
    except Exception:
        last = 0
    if last > 0:
        return last + 1
    for msg in read_jsonl(conversation_path(paths, channel)):
        try:
            last = max(last, int(msg.get("seq", 0) or 0))
        except Exception:
            continue
    return last + 1


def append_message(
    paths: BridgePaths,
    channel: str,
    sender: str,
    text: str,
    kind: str = "message",
    model: str = "",
) -> dict[str, Any]:
    if sender not in {"user", "system", "claude", "codex"}:
        raise ValueError("sender must be one of: user, system, claude, codex")
    ensure_channel(paths, channel)
    seq = _next_message_seq(paths, channel)
    record: dict[str, Any] = {
        "seq": seq,
        "ts": utc_now(),
        "from": sender,
        "kind": kind,
        "text": text,
    }
    if model:
        record["model"] = model
    append_jsonl(conversation_path(paths, channel), record)
    state = read_state(paths, channel)
    if not state:
        state = default_state(last_seq=seq)
    state["lastSeq"] = seq
    write_state(paths, channel, state)
    return record


def tail_messages(paths: BridgePaths, channel: str, limit: int = 20) -> list[dict[str, Any]]:
    messages = read_jsonl(conversation_path(paths, channel))
    if limit <= 0:
        return messages
    return messages[-limit:]


def list_backlog(paths: BridgePaths, channel: str, status: str | None = None) -> list[dict[str, Any]]:
    items = folded_by_id(read_jsonl(backlog_path(paths, channel)))
    if status:
        items = [item for item in items if str(item.get("status", "")) == status]
    return items


def add_backlog_item(
    paths: BridgePaths,
    channel: str,
    text: str,
    sender: str = "operator",
    status: str = "new",
    tags: list[str] | None = None,
    project: str = "",
    scope: str = "bridge",
    severity: str = "",
) -> dict[str, Any]:
    ensure_channel(paths, channel)
    record: dict[str, Any] = {
        "id": uuid.uuid4().hex,
        "ts": utc_now(),
        "from": sender,
        "status": status,
        "tags": tags or [],
        "attempts": 0,
        "score": 0.0,
        "project": project,
        "scope": scope,
        "text": text,
    }
    if severity:
        record["severity"] = severity
    append_jsonl(backlog_path(paths, channel), record)
    return record


def set_backlog_status(paths: BridgePaths, channel: str, item_id: str, status: str) -> dict[str, Any]:
    items = list_backlog(paths, channel)
    current = None
    for item in items:
        if str(item.get("id", "")) == item_id:
            current = dict(item)
            break
    if current is None:
        raise ValueError("backlog item not found: %s" % item_id)
    current["status"] = status
    current["ts"] = utc_now()
    append_jsonl(backlog_path(paths, channel), current)
    return current
