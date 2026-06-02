# recover2-elevated.ps1 -- run ELEVATED. Stop the (buggy) supervisor task, kill ALL
# bridge processes, then start ONE clean elevated server + driver (RunAs-launched, so
# they survive). Restores a known-good working bridge.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
try { Stop-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue } catch {}
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
1..3 | ForEach-Object {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\supervisor.ps1*' -or $_.CommandLine -like '*\server.ps1*' -or $_.CommandLine -like '*\driver.ps1*' } |
    Where-Object {
      if ($_.ProcessId -eq $PID) { return $false }
      try {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        "$($owner.Domain)\$($owner.User)" -eq $currentUser
      } catch { $false }
    } |
    ForEach-Object { taskkill /PID $_.ProcessId /F /T 2>$null | Out-Null }
  Start-Sleep -Seconds 1
}
$t = 0
while ((Get-NetTCPConnection -State Listen -LocalPort 8787 -ErrorAction SilentlyContinue) -and $t -lt 12) { Start-Sleep -Seconds 1; $t++ }
Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"$root\server.ps1" -WindowStyle Hidden
Start-Sleep -Seconds 3
Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"$root\driver.ps1" -WindowStyle Hidden
Start-Sleep -Seconds 5
"recovered $(Get-Date -Format o)" | Out-File "$env:TEMP\bridge_recover2.txt" -Encoding utf8
