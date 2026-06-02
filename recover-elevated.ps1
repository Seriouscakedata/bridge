# recover-elevated.ps1 -- run ELEVATED. Stops the runaway: removes the rogue restart
# task an agent created, and kills ALL bridge processes. Does NOT restart (we fix the
# engine first, then restart cleanly).
$ErrorActionPreference = 'Continue'
$log = "$env:TEMP\bridge_recover.txt"
"recover $(Get-Date -Format o)" | Out-File $log -Encoding utf8

# 1. remove any rogue restart task(s)
foreach ($name in @('ClaudeCodexBridgeRestart')) {
  try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop; "removed task $name" | Out-File $log -Append -Encoding utf8 }
  catch { "no task $name ($($_.Exception.Message))" | Out-File $log -Append -Encoding utf8 }
}

# 2. kill ALL bridge processes (repeat)
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
1..3 | ForEach-Object {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\driver.ps1*' -or $_.CommandLine -like '*\server.ps1*' } |
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
"all bridge processes killed; port free after ${t}s" | Out-File $log -Append -Encoding utf8
"=== done (bridge is STOPPED; will be rebuilt) ===" | Out-File $log -Append -Encoding utf8
