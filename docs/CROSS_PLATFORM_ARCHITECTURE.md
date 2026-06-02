# Cross-Platform Control Layer

MOS Bridge is still a Windows-first legacy engine, but it now has a portable Python control layer. The goal is to move from "PowerShell is the architecture" to "PowerShell is one adapter".

## Layers

1. `bridge_core/`
   Portable Python code. It reads config, settings, runtime status, channel state, and platform capabilities without using PowerShell.

2. `bridgectl.py`
   Operator CLI for portable control:

   ```powershell
   py .\bridgectl.py capabilities
   py .\bridgectl.py status
   py .\bridgectl.py doctor
   py .\bridgectl.py mode show
   py .\bridgectl.py mode set copilot
   py .\bridgectl.py mode set autopilot
   ```

3. Platform adapters
   `bridge_core.platforms` detects the host and chooses an adapter:

   - Windows + `powershell.exe`: can run the current legacy engine.
   - PowerShell Core (`pwsh`): transitional adapter for diagnostics and future porting.
   - No PowerShell: status/mode/capabilities still work, legacy start/stop/selftest are unavailable.

4. Legacy engine
   Existing `start.ps1`, `stop.ps1`, `server.ps1`, `driver.ps1`, and `lib/*.ps1` remain the working engine.

## Operator Modes

`autopilot`:
MOS may claim runnable backlog after quiet time. This is the long-running autonomous-worker mode.

`copilot`:
MOS responds to direct operator messages, but it does not autonomously claim backlog. This is better for experienced programmers who want frequent decision points.

The mode is stored in ignored `settings.json` as:

```json
{
  "operatorMode": "copilot"
}
```

The default in `config.json` is:

```json
{
  "autonomy": {
    "operatorMode": "autopilot"
  }
}
```

## What This Solves Now

- A non-Windows user can inspect status, capabilities, and operator mode with Python.
- The architecture has a clear future porting boundary: portable core first, platform adapters second, legacy scripts last.
- Operators can switch between long autonomous work and supervised copilot behavior without editing PowerShell.

## What Still Needs Porting

- The actual long-running server/driver engine is still PowerShell.
- Several scripts use Windows-only cmdlets (`Get-NetTCPConnection`, `Get-CimInstance`, hidden `Start-Process`).
- Autostart/watchdog are still Windows Task Scheduler oriented.

## Next Porting Direction

1. Move state/channel/backlog operations from `lib/common.ps1` and `lib/backlog.ps1` into portable Python modules.
2. Make `server.ps1` replaceable by a Python/Node HTTP API while keeping the existing web UI.
3. Replace Windows process management with platform adapters.
4. Keep PowerShell as the Windows adapter until the portable engine fully replaces it.
