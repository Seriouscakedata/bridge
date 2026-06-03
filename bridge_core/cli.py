from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .config import BridgePaths, get_operator_mode, load_config, set_operator_mode
from .ops import (
    add_backlog_item,
    append_message,
    create_channel,
    list_backlog,
    list_channels,
    set_backlog_status,
    tail_messages,
)
from .platforms import base_capabilities, detect_adapter
from .state import collect_status


def _print(data: Any, as_json: bool) -> None:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                print("%s: %s" % (key, json.dumps(value, ensure_ascii=False)))
            else:
                print("%s: %s" % (key, value))
    elif isinstance(data, list):
        for item in data:
            if isinstance(item, (dict, list)):
                print(json.dumps(item, ensure_ascii=False))
            else:
                print(item)
    else:
        print(data)


def _paths(args: argparse.Namespace) -> BridgePaths:
    return BridgePaths.discover(Path(args.root).resolve() if args.root else None)


def cmd_capabilities(args: argparse.Namespace) -> int:
    _print(base_capabilities(), args.json)
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    paths = _paths(args)
    config = load_config(paths)
    status = collect_status(paths, config, channel=args.channel, probe_http=not args.no_http)
    _print(status.to_dict(), args.json)
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    paths = _paths(args)
    config = load_config(paths)
    status = collect_status(paths, config, channel=args.channel, probe_http=not args.no_http)
    caps = base_capabilities()
    problems: list[str] = []
    if not caps.get("git"):
        problems.append("git is not available in PATH")
    if not caps.get("legacy_engine"):
        problems.append("PowerShell legacy engine adapter is unavailable")
    if status.health.get("reachable") is False:
        problems.append("HTTP health endpoint is not reachable")
    result = {
        "ok": not problems,
        "problems": problems,
        "capabilities": caps,
        "status": status.to_dict(),
    }
    _print(result, args.json)
    return 0 if not problems else 1


def cmd_start(args: argparse.Namespace) -> int:
    paths = _paths(args)
    adapter = detect_adapter()
    if not adapter.legacy_engine:
        print("Cannot start MOS: no PowerShell legacy adapter is available.", file=sys.stderr)
        return 2
    script_args = ["-NoBrowser"] if args.no_browser else []
    return adapter.run_script(paths.root, "start.ps1", script_args)


def cmd_stop(args: argparse.Namespace) -> int:
    paths = _paths(args)
    adapter = detect_adapter()
    if not adapter.legacy_engine:
        print("Cannot stop MOS: no PowerShell legacy adapter is available.", file=sys.stderr)
        return 2
    return adapter.run_script(paths.root, "stop.ps1", [])


def cmd_selftest(args: argparse.Namespace) -> int:
    paths = _paths(args)
    adapter = detect_adapter()
    if not adapter.legacy_engine:
        print("Cannot run legacy selftest: no PowerShell adapter is available.", file=sys.stderr)
        return 2
    return adapter.run_script(paths.root, "driver.ps1", ["-SelfTest"])


def cmd_mode(args: argparse.Namespace) -> int:
    paths = _paths(args)
    if args.mode_command == "show":
        _print({"operatorMode": get_operator_mode(paths)}, args.json)
        return 0
    if args.mode_command == "set":
        mode = set_operator_mode(paths, args.value)
        _print({"operatorMode": mode, "settings": str(paths.settings_path)}, args.json)
        return 0
    raise RuntimeError("unknown mode command")


def cmd_channel(args: argparse.Namespace) -> int:
    paths = _paths(args)
    if args.channel_command == "list":
        _print(list_channels(paths, include_archived=args.all), args.json)
        return 0
    if args.channel_command == "create":
        record = create_channel(
            paths,
            args.slug,
            name=args.name,
            description=args.description or "",
            project_root=args.project_root,
        )
        _print(record, args.json)
        return 0
    raise RuntimeError("unknown channel command")


def cmd_message(args: argparse.Namespace) -> int:
    paths = _paths(args)
    if args.message_command == "send":
        record = append_message(paths, args.channel, args.sender, args.text, kind=args.kind, model=args.model or "")
        _print(record, args.json)
        return 0
    if args.message_command == "tail":
        _print(tail_messages(paths, args.channel, limit=args.limit), args.json)
        return 0
    raise RuntimeError("unknown message command")


def cmd_backlog(args: argparse.Namespace) -> int:
    paths = _paths(args)
    if args.backlog_command == "list":
        _print(list_backlog(paths, args.channel, status=args.status), args.json)
        return 0
    if args.backlog_command == "add":
        record = add_backlog_item(
            paths,
            args.channel,
            args.text,
            sender=args.sender,
            status=args.status,
            tags=args.tag or [],
            project=args.project or "",
            scope=args.scope,
            severity=args.severity or "",
        )
        _print(record, args.json)
        return 0
    if args.backlog_command == "set":
        record = set_backlog_status(paths, args.channel, args.id, args.status)
        _print(record, args.json)
        return 0
    raise RuntimeError("unknown backlog command")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Portable MOS Bridge controller")
    parser.add_argument("--root", help="Bridge root. Defaults to auto-discovery from cwd.")
    sub = parser.add_subparsers(dest="command", required=True)

    capabilities = sub.add_parser("capabilities", help="Show platform/tool capabilities")
    capabilities.add_argument("--json", action="store_true")
    capabilities.set_defaults(func=cmd_capabilities)

    status = sub.add_parser("status", help="Show local bridge status without requiring PowerShell")
    status.add_argument("--json", action="store_true")
    status.add_argument("--channel", default="main")
    status.add_argument("--no-http", action="store_true", help="Do not probe /api/health")
    status.set_defaults(func=cmd_status)

    doctor = sub.add_parser("doctor", help="Show status plus portability/runtime problems")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--channel", default="main")
    doctor.add_argument("--no-http", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    start = sub.add_parser("start", help="Start the legacy engine through the detected adapter")
    start.add_argument("--no-browser", action="store_true")
    start.set_defaults(func=cmd_start)

    stop = sub.add_parser("stop", help="Stop the legacy engine through the detected adapter")
    stop.set_defaults(func=cmd_stop)

    selftest = sub.add_parser("selftest", help="Run legacy driver selftest through the detected adapter")
    selftest.set_defaults(func=cmd_selftest)

    mode = sub.add_parser("mode", help="Show or set operator autonomy mode")
    mode.add_argument("--json", action="store_true")
    mode_sub = mode.add_subparsers(dest="mode_command", required=True)
    mode_show = mode_sub.add_parser("show")
    mode_show.add_argument("--json", action="store_true")
    mode_show.set_defaults(func=cmd_mode)
    mode_set = mode_sub.add_parser("set")
    mode_set.add_argument("value", choices=["autopilot", "copilot"])
    mode_set.add_argument("--json", action="store_true")
    mode_set.set_defaults(func=cmd_mode)

    channel = sub.add_parser("channel", help="Portable channel operations")
    channel.add_argument("--json", action="store_true")
    channel_sub = channel.add_subparsers(dest="channel_command", required=True)
    channel_list = channel_sub.add_parser("list")
    channel_list.add_argument("--all", action="store_true", help="Include archived channels")
    channel_list.add_argument("--json", action="store_true")
    channel_list.set_defaults(func=cmd_channel)
    channel_create = channel_sub.add_parser("create")
    channel_create.add_argument("slug")
    channel_create.add_argument("--name")
    channel_create.add_argument("--description")
    channel_create.add_argument("--project-root")
    channel_create.add_argument("--json", action="store_true")
    channel_create.set_defaults(func=cmd_channel)

    message = sub.add_parser("message", help="Portable chat message operations")
    message.add_argument("--json", action="store_true")
    message_sub = message.add_subparsers(dest="message_command", required=True)
    message_send = message_sub.add_parser("send")
    message_send.add_argument("text")
    message_send.add_argument("--channel", default="main")
    message_send.add_argument("--from", dest="sender", default="user", choices=["user", "system", "claude", "codex"])
    message_send.add_argument("--kind", default="message")
    message_send.add_argument("--model", default="")
    message_send.add_argument("--json", action="store_true")
    message_send.set_defaults(func=cmd_message)
    message_tail = message_sub.add_parser("tail")
    message_tail.add_argument("--channel", default="main")
    message_tail.add_argument("--limit", type=int, default=20)
    message_tail.add_argument("--json", action="store_true")
    message_tail.set_defaults(func=cmd_message)

    backlog = sub.add_parser("backlog", help="Portable backlog operations")
    backlog.add_argument("--json", action="store_true")
    backlog_sub = backlog.add_subparsers(dest="backlog_command", required=True)
    backlog_list = backlog_sub.add_parser("list")
    backlog_list.add_argument("--channel", default="main")
    backlog_list.add_argument("--status")
    backlog_list.add_argument("--json", action="store_true")
    backlog_list.set_defaults(func=cmd_backlog)
    backlog_add = backlog_sub.add_parser("add")
    backlog_add.add_argument("text")
    backlog_add.add_argument("--channel", default="main")
    backlog_add.add_argument("--from", dest="sender", default="operator")
    backlog_add.add_argument("--status", default="new", choices=["new", "approved", "held", "running", "done", "archived"])
    backlog_add.add_argument("--tag", action="append")
    backlog_add.add_argument("--project", default="")
    backlog_add.add_argument("--scope", default="bridge", choices=["bridge", "project"])
    backlog_add.add_argument("--severity", default="", choices=["", "critical", "warning", "info"])
    backlog_add.add_argument("--json", action="store_true")
    backlog_add.set_defaults(func=cmd_backlog)
    backlog_set = backlog_sub.add_parser("set")
    backlog_set.add_argument("id")
    backlog_set.add_argument("status", choices=["new", "approved", "held", "running", "done", "archived"])
    backlog_set.add_argument("--channel", default="main")
    backlog_set.add_argument("--json", action="store_true")
    backlog_set.set_defaults(func=cmd_backlog)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        else:
            print("bridgectl error: %s" % exc, file=sys.stderr)
        return 1
