# install-ensure-bridge.ps1 -- register the EXTERNAL reliability anchor (ensure-bridge.ps1) as a
# repeating scheduled task: every 5 min, elevated. It restarts a dead supervisor/watchdog (the
# AtLogon ClaudeCodexBridge task can't, because orphaned children keep it "Running") and heals a
# OneDrive-zeroed git master ref. Safe to re-run. Run this once (elevated) to install.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Stop'

$root      = Get-BridgeRoot
$ensurePs1 = Join-Path $root 'ensure-bridge.ps1'
$taskName  = 'ClaudeCodexBridge-Ensure'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ensurePs1 + '"')

# Repeating trigger: start at logon, then repeat every 5 minutes indefinitely.
$trigger = New-ScheduledTaskTrigger -AtLogOn
$rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration ([TimeSpan]::FromDays(3650))).Repetition
$trigger.Repetition = $rep

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal `
  -Description 'External reliability anchor: heal dead supervisor/watchdog + OneDrive-zeroed git ref (every 5 min, elevated).' `
  -Force | Out-Null

Write-Host "Registered scheduled task '$taskName' (every 5 min, elevated)."
Write-Host "To remove: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
