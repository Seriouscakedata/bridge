# watchdog.ps1 -- INDEPENDENT safety net (own scheduled task, every ~2 min, elevated).
# Self-contained: does NOT dot-source common.ps1, so it still works if the engine is
# broken. If the bridge is unhealthy for ~4 min, it ROLLS BACK the engine to the last
# git commit, re-adds BOM, and restarts -- so a bad self-edit can't leave a dead bridge.
$ErrorActionPreference = 'Continue'
$b   = 'C:\Users\rafie\OneDrive\Documents\bridge'
$git = 'C:\Program Files\Git\cmd\git.exe'
$ctl = Join-Path $b 'control'
if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
$log = Join-Path $ctl 'watchdog.log'
$failFile = Join-Path $ctl 'watchdog.fails'
function WLog($m){ try { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File $log -Append -Encoding utf8 } catch {} }

# --- health: API responds (with auth) ---
$apiOk = $false
try {
  $pw = (Get-Content (Join-Path $b 'auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json).password
  $cred = New-Object System.Management.Automation.PSCredential('timur', (ConvertTo-SecureString $pw -AsPlainText -Force))
  $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8787/api/status' -Credential $cred -TimeoutSec 6
  if ($r.StatusCode -eq 200) { $apiOk = $true }
} catch {}

# --- health: heartbeat is fresh (<4 min) ---
$hbOk = $false
try {
  $st = Get-Content (Join-Path $b 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($st.heartbeat) { if ((((Get-Date) - [datetime]$st.heartbeat).TotalSeconds) -lt 240) { $hbOk = $true } }
} catch {}

$healthy = $apiOk -and $hbOk
$fails = 0; if (Test-Path $failFile) { try { $fails = [int](Get-Content $failFile -Raw) } catch {} }

if ($healthy) {
  if ($fails -ne 0) { WLog "healthy again (was failing $fails)" }
  '0' | Out-File $failFile -Encoding ascii
  return
}

$fails++
"$fails" | Out-File $failFile -Encoding ascii
WLog "UNHEALTHY (api=$apiOk hb=$hbOk), consecutive=$fails"

if ($fails -ge 2) {
  WLog "ROLLBACK: restoring engine to last git commit + restart"
  try { Push-Location $b; & $git checkout -- . 2>$null; Pop-Location } catch { WLog ("git error: " + $_.Exception.Message) }
  # ensure BOM on all .ps1 (so PS 5.1 parses Russian/emoji)
  Get-ChildItem $b -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
    try { $t=[System.IO.File]::ReadAllText($_.FullName,(New-Object System.Text.UTF8Encoding($false))); [System.IO.File]::WriteAllText($_.FullName,$t,(New-Object System.Text.UTF8Encoding($true))) } catch {}
  }
  # trigger restart via supervisor flag, and make sure the supervisor is running
  Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ascii
  Start-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue
  '0' | Out-File $failFile -Encoding ascii
  WLog "rollback applied"
}
