# stop.ps1 -- stop the bridge gracefully, then ensure processes are gone.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'

$root    = Get-BridgeRoot
$runtime = Join-Path $root 'runtime'
$pidFile = Join-Path $runtime 'pids.json'

# 1) ask the driver to stop after its current turn
try { Update-State { param($s) $s.stop = $true; $s.status = 'stopped' } | Out-Null } catch {}
try { Add-Message -From system -Text 'Stop requested via stop.ps1.' -Kind event | Out-Null } catch {}

Start-Sleep -Seconds 2

# 2) kill the recorded processes (the server blocks on GetContext and must be killed)
if (Test-Path $pidFile) {
  $pids = Get-Content $pidFile -Raw | ConvertFrom-Json
  foreach ($id in @($pids.server, $pids.driver)) {
    if ($id) {
      try { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}
Write-Host "Bridge stopped."
