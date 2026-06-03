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
from bridge_core.ops import (
    add_backlog_item,
    append_message,
    create_channel,
    list_backlog,
    list_channels,
    set_backlog_status,
    tail_messages,
)
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

    def test_message_append_updates_state_seq(self) -> None:
        paths = BridgePaths.discover(self.make_root())
        msg = append_message(paths, "main", "user", "hello")
        self.assertEqual(msg["seq"], 1)
        self.assertEqual(tail_messages(paths, "main", limit=1)[0]["text"], "hello")
        state = json.loads((paths.channels_dir / "main" / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["lastSeq"], 1)

    def test_backlog_add_and_status_update(self) -> None:
        paths = BridgePaths.discover(self.make_root())
        item = add_backlog_item(paths, "main", "portable backlog item", status="new")
        self.assertEqual(list_backlog(paths, "main")[-1]["status"], "new")
        updated = set_backlog_status(paths, "main", item["id"], "approved")
        self.assertEqual(updated["status"], "approved")
        folded = [x for x in list_backlog(paths, "main") if x.get("id") == item["id"]]
        self.assertEqual(len(folded), 1)
        self.assertEqual(folded[0]["status"], "approved")

    def test_channel_create_and_list(self) -> None:
        paths = BridgePaths.discover(self.make_root())
        create_channel(paths, "sample", name="Sample")
        slugs = [c["slug"] for c in list_channels(paths)]
        self.assertIn("sample", slugs)


if __name__ == "__main__":
    unittest.main()
