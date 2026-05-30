# install-watchdog.ps1 -- run ELEVATED once. Registers the watchdog to run every ~2 min
# (and at logon), elevated, so it can roll back a bricked engine without UAC.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Stop'
$root = Get-BridgeRoot
$wd   = Join-Path $root 'watchdog.ps1'
$name = 'ClaudeCodexBridge-Watchdog'

$argList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + ($wd -replace '"', '\"') + '"'))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ($argList -join ' ')
$tLogon = New-ScheduledTaskTrigger -AtLogOn
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(45) `
  -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 365)
# Non-elevated: rollback is just file ops (git checkout + BOM) + writing the restart flag
# + starting the (already-elevated) supervisor task. None of that needs admin, so this
# registers WITHOUT a UAC prompt.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $name -Action $action -Trigger $tLogon,$tRepeat `
  -Principal $principal -Settings $settings -Description 'Auto-rollback watchdog for the bridge.' -Force | Out-Null
Write-Host "Watchdog registered ('$name', non-elevated): health check + git rollback every ~2 min."
Start-Sleep -Seconds 2
