# install-autostart.ps1 -- register the bridge to auto-start at logon (Task Scheduler).
# Run this yourself when you want autostart. It registers a per-user scheduled task
# that launches start.ps1 at logon and restarts it on failure. Safe to re-run.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Stop'

$root      = Get-BridgeRoot
$superPs1  = Join-Path $root 'supervisor.ps1'
$taskName  = 'ClaudeCodexBridge'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $superPs1)

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

# Run ELEVATED in the interactive session so admin actions don't trigger a UAC prompt.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal `
  -Description 'Auto-start the Claude<->Codex bridge at logon (elevated).' `
  -Force | Out-Null

Write-Host "Registered scheduled task '$taskName' (elevated, runs start.ps1 at logon)."
Write-Host "To remove: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
