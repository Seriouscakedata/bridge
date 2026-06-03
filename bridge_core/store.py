from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .config import BridgePaths, read_json, write_json


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            text = line.strip()
            if not text:
                continue
            try:
                value = json.loads(text)
            except Exception:
                continue
            if isinstance(value, dict):
                out.append(value)
    return out


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    with path.open("a", encoding="utf-8", newline="\n") as fh:
        fh.write(payload)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("%s.tmp.%s" % (path.name, uuid.uuid4().hex))
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(str(tmp), str(path))


def channel_dir(paths: BridgePaths, slug: str) -> Path:
    safe = slug.strip()
    if not safe or "/" in safe or "\\" in safe or ".." in safe:
        raise ValueError("invalid channel slug")
    return paths.channels_dir / safe


def conversation_path(paths: BridgePaths, channel: str) -> Path:
    return channel_dir(paths, channel) / "conversation.jsonl"


def backlog_path(paths: BridgePaths, channel: str) -> Path:
    return channel_dir(paths, channel) / "backlog.jsonl"


def state_path(paths: BridgePaths, channel: str) -> Path:
    return channel_dir(paths, channel) / "state.json"


def channel_config_path(paths: BridgePaths, channel: str) -> Path:
    return channel_dir(paths, channel) / "channel.json"


def ensure_channel(paths: BridgePaths, slug: str, name: str | None = None, description: str = "", project_root: str | None = None) -> dict[str, Any]:
    cfg_path = channel_config_path(paths, slug)
    if cfg_path.exists():
        value = read_json(cfg_path, {})
        if isinstance(value, dict):
            return value
    record = {
        "slug": slug,
        "name": name or slug,
        "description": description,
        "project_root": project_root,
        "created": utc_now(),
        "archived": False,
    }
    write_json(cfg_path, record)
    return record


def default_state(last_seq: int = 0) -> dict[str, Any]:
    return {
        "status": "idle",
        "lastSeq": last_seq,
        "paused": False,
        "stop": False,
        "abort": False,
        "heartbeat": "",
    }


def read_state(paths: BridgePaths, channel: str) -> dict[str, Any]:
    state = read_json(state_path(paths, channel), {})
    if isinstance(state, dict):
        return state
    return {}


def write_state(paths: BridgePaths, channel: str, state: dict[str, Any]) -> None:
    atomic_write_json(state_path(paths, channel), state)


def folded_by_id(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    order: list[str] = []
    by_id: dict[str, dict[str, Any]] = {}
    no_id: list[dict[str, Any]] = []
    for record in records:
        item_id = str(record.get("id", "") or "")
        if not item_id:
            no_id.append(record)
            continue
        if item_id not in by_id:
            order.append(item_id)
        by_id[item_id] = record
    return [by_id[item_id] for item_id in order] + no_id
