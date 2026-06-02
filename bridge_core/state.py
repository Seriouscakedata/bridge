from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .config import BridgeConfig, BridgePaths, get_operator_mode, read_json


def _jsonl_count(path: Path) -> int:
    if not path.exists():
        return 0
    count = 0
    with path.open("r", encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            if line.strip():
                count += 1
    return count


def _jsonl_last(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    last = None
    with path.open("r", encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            text = line.strip()
            if not text:
                continue
            try:
                last = json.loads(text)
            except Exception:
                last = {"raw": text}
    return last


def _http_health(port: int, timeout: float = 2.0) -> dict[str, Any]:
    url = "http://127.0.0.1:%d/api/health" % port
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
        data = json.loads(body)
        if isinstance(data, dict):
            data["reachable"] = True
            return data
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return {"reachable": False, "error": str(exc)}
    return {"reachable": False, "error": "unexpected health response"}


@dataclass(frozen=True)
class BridgeStatus:
    root: str
    port: int
    operator_mode: str
    channel: str
    state_status: str
    current_task: str
    heartbeat: str
    backlog_items: int
    conversation_items: int
    last_message_from: str
    runtime_pids: dict[str, Any]
    health: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def collect_status(paths: BridgePaths, config: BridgeConfig, channel: str = "main", probe_http: bool = True) -> BridgeStatus:
    channel_dir = paths.channels_dir / channel
    state = read_json(channel_dir / "state.json", {})
    if not isinstance(state, dict):
        state = {}
    backlog_path = channel_dir / "backlog.jsonl"
    conversation_path = channel_dir / "conversation.jsonl"
    last_message = _jsonl_last(conversation_path) or {}
    pids = read_json(paths.runtime_dir / "pids.json", {})
    if not isinstance(pids, dict):
        pids = {}
    health = _http_health(config.port) if probe_http else {"reachable": None}
    return BridgeStatus(
        root=str(paths.root),
        port=config.port,
        operator_mode=get_operator_mode(paths),
        channel=channel,
        state_status=str(state.get("status", "unknown")),
        current_task=str(state.get("current_task", "") or ""),
        heartbeat=str(state.get("heartbeat", "") or ""),
        backlog_items=_jsonl_count(backlog_path),
        conversation_items=_jsonl_count(conversation_path),
        last_message_from=str(last_message.get("from", "") or ""),
        runtime_pids=pids,
        health=health,
    )
