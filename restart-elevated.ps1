# restart-elevated.ps1 -- run ELEVATED. Guarantees a single elevated server + driver.
# -Reset also clears the conversation/state (fresh chat).
param([switch]$Reset)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$log  = "$env:TEMP\bridge_restart.txt"
"restart $(Get-Date -Format o) reset=$Reset" | Out-File $log -Encoding utf8

# kill ALL bridge processes (elevated can kill everything), repeat to be sure
1..3 | ForEach-Object {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\server.ps1*' -or $_.CommandLine -like '*\driver.ps1*' } |
    ForEach-Object { taskkill /PID $_.ProcessId /F /T 2>$null | Out-Null }
  Start-Sleep -Seconds 2
}
# wait until http.sys releases the port
$t = 0
while ((Get-NetTCPConnection -State Listen -LocalPort 8787 -ErrorAction SilentlyContinue) -and $t -lt 12) { Start-Sleep -Seconds 1; $t++ }
"port free after ${t}s" | Out-File $log -Append -Encoding utf8

if ($Reset) {
  . (Join-Path $root 'lib\common.ps1')
  Initialize-Bridge -Reset | Out-Null
  "conversation/state reset" | Out-File $log -Append -Encoding utf8
}

# start exactly one of each, elevated (this script is elevated -> children inherit)
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\server.ps1" -WindowStyle Hidden
Start-Sleep -Seconds 3
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\driver.ps1" -WindowStyle Hidden
Start-Sleep -Seconds 5
"started server+driver elevated" | Out-File $log -Append -Encoding utf8
"=== done ===" | Out-File $log -Append -Encoding utf8
