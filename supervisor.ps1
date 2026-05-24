# supervisor.ps1 -- persistent ELEVATED host for the bridge (autostart task action).
# Keeps server.ps1 + driver.ps1 alive, auto-restarts crashes, honors restart/stop flags
# WITHOUT a new UAC prompt. Never exits on its own (its job keeps children alive).
# Instrumented: captures child stdout/stderr to control/*.log for diagnosis.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'
$enc = New-Object System.Text.UTF8Encoding($false); $OutputEncoding = $enc
try { [Console]::OutputEncoding = $enc } catch {}

$root = Get-BridgeRoot
$cfg  = Get-BridgeConfig
$port = [int]$cfg.port
$ctl  = Join-Path $root 'control'
if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
$flagRestart = Join-Path $ctl 'restart.flag'
$flagStop    = Join-Path $ctl 'stop.flag'
$supLog = Join-Path $ctl 'supervisor.log'
$srvOut = Join-Path $ctl 'server.out.log'; $srvErr = Join-Path $ctl 'server.err.log'
$drvOut = Join-Path $ctl 'driver.out.log'; $drvErr = Join-Path $ctl 'driver.err.log'
function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Out-File $supLog -Append -Encoding utf8 }
$null = Initialize-Bridge

function Kill-Bridge {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\server.ps1*' -or $_.CommandLine -like '*\driver.ps1*' } |
    ForEach-Object { taskkill /PID $_.ProcessId /F /T 2>$null | Out-Null }
}
function Start-Srv {
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'server.ps1') `
    -NoNewWindow -PassThru -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
}
function Start-Drv {
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'driver.ps1') `
    -NoNewWindow -PassThru -RedirectStandardOutput $drvOut -RedirectStandardError $drvErr
}

Log "=== supervisor start, PID $PID ==="
Kill-Bridge
Start-Sleep -Seconds 2
$srv = $null; $drv = $null
Add-Message -From system -Text "Супервизор запущен (elevated). Держу сервер и драйвер живыми; перезапуск без UAC по флагу; авто-подъём при падении." -Kind event | Out-Null

while ($true) {
  try {
    if (Test-Path $flagStop) {
      Remove-Item $flagStop -Force -ErrorAction SilentlyContinue
      Log "stop flag -> exit"; Kill-Bridge; break
    }
    if (Test-Path $flagRestart) {
      Remove-Item $flagRestart -Force -ErrorAction SilentlyContinue
      Log "restart flag -> recycle"
      Add-Message -From system -Text "Перезапуск по запросу (без UAC)." -Kind event | Out-Null
      Kill-Bridge; $srv = $null; $drv = $null; Start-Sleep -Seconds 3
    }
    if ($null -eq $srv -or $srv.HasExited) {
      Log "starting server..."
      $srv = Start-Srv; Start-Sleep -Seconds 3
      Log ("server pid=" + $(if($srv){$srv.Id}else{'?'}) + " hasExited=" + $(if($srv){$srv.HasExited}else{'?'}))
    }
    if ($null -eq $drv -or $drv.HasExited) {
      Log "starting driver..."
      $drv = Start-Drv; Start-Sleep -Seconds 4
      Log ("driver pid=" + $(if($drv){$drv.Id}else{'?'}) + " hasExited=" + $(if($drv){$drv.HasExited}else{'?'}))
    }
  } catch { Log ("ERR " + $_.Exception.Message) }
  Start-Sleep -Seconds 5
}
