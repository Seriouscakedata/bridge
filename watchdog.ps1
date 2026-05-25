# watchdog.ps1 -- INDEPENDENT safety net. Runs as a persistent background loop (every
# ~2 min). Self-contained (does NOT dot-source common.ps1, so it works even if the engine
# is broken). If the bridge is unhealthy for ~4 min, it ROLLS BACK the engine to the last
# git commit, re-adds BOM, and restarts -- so a bad self-edit can't leave a dead bridge.
$ErrorActionPreference = 'Continue'
$b   = 'C:\Users\rafie\OneDrive\Documents\bridge'
$git = 'C:\Program Files\Git\cmd\git.exe'
$ctl = Join-Path $b 'control'
if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
$log = Join-Path $ctl 'watchdog.log'
$failFile = Join-Path $ctl 'watchdog.fails'
function WLog($m){ try { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File $log -Append -Encoding utf8 } catch {} }

# Promote the 'stable' ref (last-known-good) to HEAD once HEAD has been healthy for
# >= $promoteMin minutes. Rollback targets THIS ref, so a bad COMMITTED self-edit by the
# agents can be undone too (plain 'checkout -- .' can only undo UNcommitted changes).
$promoteMin = 30
function Promote-Stable {
  try {
    Push-Location $b
    $head = (& $git rev-parse HEAD 2>$null); if ($head) { $head = ([string]$head).Trim() }
    & $git rev-parse --verify stable 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { & $git branch -f stable HEAD 2>$null; WLog "stable ref created at $head"; Pop-Location; return }
    $stable = (& $git rev-parse stable 2>$null); if ($stable) { $stable = ([string]$stable).Trim() }
    if ($head -eq $stable) { Pop-Location; return }
    $headEpoch = 0; try { $headEpoch = [int](& $git log -1 --format=%ct HEAD 2>$null) } catch {}
    $epoch0 = [datetime]'1970-01-01T00:00:00Z'
    $nowEpoch = [int]((Get-Date).ToUniversalTime() - $epoch0.ToUniversalTime()).TotalSeconds
    if ($headEpoch -gt 0 -and ($nowEpoch - $headEpoch) -ge ($promoteMin * 60)) {
      & $git branch -f stable HEAD 2>$null
      WLog "stable advanced to $head (healthy >= $promoteMin min)"
    }
    Pop-Location
  } catch { try { Pop-Location } catch {}; WLog ("promote error: " + $_.Exception.Message) }
}

function Check-Once {
  $apiOk = $false
  try {
    $pw = (Get-Content (Join-Path $b 'auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json).password
    $cred = New-Object System.Management.Automation.PSCredential('timur', (ConvertTo-SecureString $pw -AsPlainText -Force))
    $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8787/api/status' -Credential $cred -TimeoutSec 6
    if ($r.StatusCode -eq 200) { $apiOk = $true }
  } catch {}
  $hbOk = $false
  try {
    $st = Get-Content (Join-Path $b 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($st.heartbeat) { if ((((Get-Date) - [datetime]$st.heartbeat).TotalSeconds) -lt 300) { $hbOk = $true } }
  } catch {}

  $fails = 0; if (Test-Path $failFile) { try { $fails = [int](Get-Content $failFile -Raw) } catch {} }
  if ($apiOk -and $hbOk) {
    if ($fails -ne 0) { WLog "healthy again (was failing $fails)" }
    '0' | Out-File $failFile -Encoding ascii
    Promote-Stable
    return
  }
  $fails++
  "$fails" | Out-File $failFile -Encoding ascii
  WLog "UNHEALTHY (api=$apiOk hb=$hbOk), consecutive=$fails"
  if ($fails -ge 2) {
    WLog "ROLLBACK: resetting engine to last KNOWN-GOOD (stable) + restart"
    try {
      Push-Location $b
      & $git rev-parse --verify stable 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { & $git reset --hard stable 2>$null; WLog "reset --hard stable" }
      else { & $git checkout -- . 2>$null; WLog "stable missing -> checkout -- ." }
      Pop-Location
    } catch { try { Pop-Location } catch {}; WLog ("git error: " + $_.Exception.Message) }
    Get-ChildItem $b -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
      try { $t=[System.IO.File]::ReadAllText($_.FullName,(New-Object System.Text.UTF8Encoding($false))); [System.IO.File]::WriteAllText($_.FullName,$t,(New-Object System.Text.UTF8Encoding($true))) } catch {}
    }
    Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ascii
    Start-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue
    '0' | Out-File $failFile -Encoding ascii
    WLog "rollback applied"
  }
}

WLog "=== watchdog loop started (PID $PID) ==="
while ($true) {
  try { Check-Once } catch { WLog ("loop error: " + $_.Exception.Message) }
  Start-Sleep -Seconds 120
}
