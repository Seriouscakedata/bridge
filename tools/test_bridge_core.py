from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from bridge_core.config import BridgePaths, get_operator_mode, set_operator_mode
from bridge_core.platforms import base_capabilities
from bridge_core.state import collect_status
from bridge_core.config import load_config


class BridgeCoreTests(unittest.TestCase):
    def make_root(self) -> Path:
        root = Path(tempfile.mkdtemp(prefix="bridge-core-test-"))
        (root / "driver.ps1").write_text("", encoding="utf-8")
        (root / "server.ps1").write_text("", encoding="utf-8")
        (root / "config.json").write_text(
            json.dumps({"port": 9876, "autonomy": {"operatorMode": "autopilot"}}),
            encoding="utf-8",
        )
        channel = root / "channels" / "main"
        channel.mkdir(parents=True)
        (channel / "state.json").write_text(
            json.dumps({"status": "idle", "heartbeat": "2026-06-03T00:00:00Z"}),
            encoding="utf-8",
        )
        (channel / "backlog.jsonl").write_text('{"id":"1"}\n{"id":"2"}\n', encoding="utf-8")
        (channel / "conversation.jsonl").write_text('{"from":"user"}\n{"from":"system"}\n', encoding="utf-8")
        return root

    def test_status_reads_local_files_without_powershell(self) -> None:
        paths = BridgePaths.discover(self.make_root())
        config = load_config(paths)
        status = collect_status(paths, config, probe_http=False)
        self.assertEqual(status.port, 9876)
        self.assertEqual(status.operator_mode, "autopilot")
        self.assertEqual(status.backlog_items, 2)
        self.assertEqual(status.conversation_items, 2)
        self.assertEqual(status.last_message_from, "system")

    def test_operator_mode_roundtrip(self) -> None:
        paths = BridgePaths.discover(self.make_root())
        self.assertEqual(get_operator_mode(paths), "autopilot")
        self.assertEqual(set_operator_mode(paths, "copilot"), "copilot")
        self.assertEqual(get_operator_mode(paths), "copilot")

    def test_capabilities_shape(self) -> None:
        caps = base_capabilities()
        self.assertIn("os", caps)
        self.assertIn("python", caps)
        self.assertIn("adapter", caps)
        self.assertIn("legacy_engine", caps)


if __name__ == "__main__":
    unittest.main()
