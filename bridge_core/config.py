from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT_MARKERS = ("config.json", "driver.ps1", "server.ps1")
VALID_OPERATOR_MODES = {"autopilot", "copilot"}


def find_bridge_root(start: str | Path | None = None) -> Path:
    current = Path(start or os.getcwd()).resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if all((candidate / marker).exists() for marker in ROOT_MARKERS):
            return candidate
    raise FileNotFoundError("Could not find MOS Bridge root from %s" % current)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception:
        return default


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def normalize_operator_mode(value: str | None) -> str:
    mode = (value or "autopilot").strip().lower()
    if mode not in VALID_OPERATOR_MODES:
        raise ValueError("operator mode must be one of: %s" % ", ".join(sorted(VALID_OPERATOR_MODES)))
    return mode


@dataclass(frozen=True)
class BridgePaths:
    root: Path

    @classmethod
    def discover(cls, start: str | Path | None = None) -> "BridgePaths":
        return cls(find_bridge_root(start))

    @property
    def config_path(self) -> Path:
        return self.root / "config.json"

    @property
    def settings_path(self) -> Path:
        return self.root / "settings.json"

    @property
    def runtime_dir(self) -> Path:
        return self.root / "runtime"

    @property
    def channels_dir(self) -> Path:
        return self.root / "channels"

    @property
    def private_dir(self) -> Path:
        return Path.home() / ".bridge-private"

    @property
    def external_runtime_dir(self) -> Path:
        return Path.home() / ".bridge-runtime"


@dataclass(frozen=True)
class BridgeConfig:
    raw: dict[str, Any]

    @property
    def port(self) -> int:
        try:
            return int(self.raw.get("port", 8787))
        except Exception:
            return 8787

    @property
    def server(self) -> dict[str, Any]:
        value = self.raw.get("server", {})
        return value if isinstance(value, dict) else {}

    @property
    def autonomy(self) -> dict[str, Any]:
        value = self.raw.get("autonomy", {})
        return value if isinstance(value, dict) else {}


def load_config(paths: BridgePaths) -> BridgeConfig:
    value = read_json(paths.config_path, {})
    if not isinstance(value, dict):
        value = {}
    return BridgeConfig(value)


def get_operator_mode(paths: BridgePaths) -> str:
    settings = read_json(paths.settings_path, {})
    config = load_config(paths)
    raw = None
    if isinstance(settings, dict):
        raw = settings.get("operatorMode")
    if raw is None:
        raw = config.autonomy.get("operatorMode", "autopilot")
    return normalize_operator_mode(str(raw))


def set_operator_mode(paths: BridgePaths, mode: str) -> str:
    normalized = normalize_operator_mode(mode)
    settings = read_json(paths.settings_path, {})
    if not isinstance(settings, dict):
        settings = {}
    settings["operatorMode"] = normalized
    write_json(paths.settings_path, settings)
    return normalized
