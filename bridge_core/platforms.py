from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class PlatformReport:
    os: str
    python: str
    adapter: str
    legacy_engine: bool
    powershell: str
    notes: list[str]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class PlatformAdapter:
    name = "unsupported"
    legacy_engine = False

    def __init__(self, executable: str | None = None) -> None:
        self.executable = executable or ""

    def report(self) -> PlatformReport:
        notes = []
        if not self.legacy_engine:
            notes.append("Legacy engine is not runnable through this adapter yet.")
        return PlatformReport(
            os="%s %s" % (platform.system(), platform.release()),
            python=sys.version.split()[0],
            adapter=self.name,
            legacy_engine=self.legacy_engine,
            powershell=self.executable,
            notes=notes,
        )

    def run_script(self, root: Path, script: str, args: list[str] | None = None) -> int:
        raise RuntimeError("No runnable legacy adapter is available on this platform.")


class PowerShellAdapter(PlatformAdapter):
    legacy_engine = True

    def run_script(self, root: Path, script: str, args: list[str] | None = None) -> int:
        if not self.executable:
            raise RuntimeError("PowerShell executable is not configured.")
        script_path = root / script
        cmd = [
            self.executable,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
        ]
        if args:
            cmd.extend(args)
        return subprocess.call(cmd, cwd=str(root))


class WindowsPowerShellAdapter(PowerShellAdapter):
    name = "windows-powershell"


class PwshAdapter(PowerShellAdapter):
    name = "powershell-core"

    def __init__(self, executable: str | None = None) -> None:
        super().__init__(executable)
        self.legacy_engine = platform.system().lower() == "windows"

    def report(self) -> PlatformReport:
        report = super().report()
        notes = list(report.notes)
        if platform.system().lower() != "windows":
            notes.append("MOS legacy scripts are still Windows-first; this adapter is for transitional diagnostics and future porting.")
        return PlatformReport(
            os=report.os,
            python=report.python,
            adapter=report.adapter,
            legacy_engine=report.legacy_engine,
            powershell=report.powershell,
            notes=notes,
        )


def detect_adapter() -> PlatformAdapter:
    system = platform.system().lower()
    if system == "windows":
        exe = shutil.which("powershell.exe") or shutil.which("powershell")
        if exe:
            return WindowsPowerShellAdapter(exe)
    pwsh = shutil.which("pwsh")
    if pwsh:
        return PwshAdapter(pwsh)
    return PlatformAdapter()


def command_available(name: str) -> bool:
    return shutil.which(name) is not None


def base_capabilities() -> dict[str, Any]:
    adapter = detect_adapter()
    report = adapter.report().to_dict()
    report["git"] = command_available("git")
    report["node"] = command_available("node")
    report["codex"] = command_available("codex")
    report["claude"] = command_available("claude")
    report["cwd"] = os.getcwd()
    return report
