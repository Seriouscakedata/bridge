# diag-elevated.ps1 -- run ELEVATED. Cleanly (re)start server+driver elevated and
# capture their stderr so we can see why the driver wasn't starting.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$log  = "$env:TEMP\bridge_elev_diag.txt"
"=== elevated restart diag $(Get-Date -Format o) ===" | Out-File $log -Encoding utf8

$currentUser = "$env:USERDOMAIN\$env:USERNAME"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*\server.ps1*' -or $_.CommandLine -like '*\driver.ps1*' } |
  Where-Object {
    if ($_.ProcessId -eq $PID) { return $false }
    try {
      $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
      "$($owner.Domain)\$($owner.User)" -eq $currentUser
    } catch {
      $false
    }
  } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

$serr = "$env:TEMP\bridge_srv_err.txt"; $sout = "$env:TEMP\bridge_srv_out.txt"
$derr = "$env:TEMP\bridge_drv_err.txt"; $dout = "$env:TEMP\bridge_drv_out.txt"
$ps = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\server.ps1" -WindowStyle Hidden -PassThru -RedirectStandardError $serr -RedirectStandardOutput $sout
$pd = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$root\driver.ps1" -WindowStyle Hidden -PassThru -RedirectStandardError $derr -RedirectStandardOutput $dout
Start-Sleep -Seconds 9

"server PID $($ps.Id) alive: $(-not $ps.HasExited)" | Out-File $log -Append -Encoding utf8
"driver PID $($pd.Id) alive: $(-not $pd.HasExited)" | Out-File $log -Append -Encoding utf8
"--- server stderr ---" | Out-File $log -Append -Encoding utf8
Get-Content $serr -ErrorAction SilentlyContinue | Out-File $log -Append -Encoding utf8
"--- driver stderr ---" | Out-File $log -Append -Encoding utf8
Get-Content $derr -ErrorAction SilentlyContinue | Out-File $log -Append -Encoding utf8
"=== done ===" | Out-File $log -Append -Encoding utf8
