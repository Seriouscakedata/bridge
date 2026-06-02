# install-oprestart.ps1 -- run ELEVATED once. Registers an on-demand, pre-authorized
# elevated task that restarts the bridge. After this, restarts can be triggered WITHOUT
# a UAC prompt via:  Start-ScheduledTask -TaskName 'ClaudeCodexBridge-OpRestart'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Stop'

$root       = Get-BridgeRoot
$restartPs1 = Join-Path $root 'restart-elevated.ps1'
$taskName   = 'ClaudeCodexBridge-OpRestart'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$restartPs1`""

# No trigger: runs only when explicitly started. Elevated (Highest) in the user session.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
  -Settings $settings -Description 'On-demand elevated restart of the Claude<->Codex bridge (no UAC needed to trigger).' `
  -Force | Out-Null

Write-Host "Registered '$taskName'. Trigger without UAC via: Start-ScheduledTask -TaskName '$taskName'"
Start-Sleep -Seconds 3
