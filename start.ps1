# start.ps1 -- launch the bridge: web server + interactive driver.
param([switch]$NoBrowser)
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'

$cfg     = Get-BridgeConfig
$root    = Get-BridgeRoot
$runtime = Join-Path $root 'runtime'
if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Path $runtime -Force | Out-Null }
$null = Initialize-Bridge

function Start-Hidden($file) {
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$file -WindowStyle Hidden -PassThru
}
function Is-Running($needle) {
  [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$needle*" })
}

# server: only if the port is free
$portBusy = $null -ne (Get-NetTCPConnection -State Listen -LocalPort ([int]$cfg.port) -ErrorAction SilentlyContinue)
$srv = $null
if (-not $portBusy) { $srv = Start-Hidden (Join-Path $root 'server.ps1') }
else { Write-Host "Server already on port $($cfg.port); skipping." }

# driver: only if not already running
$drv = $null
if (-not (Is-Running 'driver.ps1')) { $drv = Start-Hidden (Join-Path $root 'driver.ps1') }
else { Write-Host "Driver already running; skipping." }

$pids = [ordered]@{ server = ($(if ($srv) { $srv.Id })); driver = ($(if ($drv) { $drv.Id })); ts = (Get-Date).ToString('o') }
Write-AtomicFile -Path (Join-Path $runtime 'pids.json') -Content ($pids | ConvertTo-Json -Depth 10)

if (-not $NoBrowser) {
  Start-Sleep -Seconds 2
  Start-Process ("http://localhost:$($cfg.port)/")
}
Write-Host "Bridge started. Local UI: http://localhost:$($cfg.port)/"
