# watchdog.ps1 -- INDEPENDENT safety net (HARDENED). Persistent loop (~2 min).
# Self-contained (does NOT dot-source common.ps1) so it works even if the engine is broken.
#
# HARDENED 2026-05-25 after a FALSE rollback destroyed committed work (plan-board UI +
# radar digest). Root cause: a brief API gap during a normal server.ps1 self-edit restart
# was treated as "engine broken" and triggered `git reset --hard stable`, wiping good commits.
# Changes:
#   1) PAUSE kill-switch: <USERPROFILE>\.bridge-private\watchdog.pause present -> watchdog takes NO action.
#   2) API down but driver ALIVE (heartbeat fresh) == server restarting after a self-edit,
#      NOT a broken engine -> gentle RESTART (restart.flag); git-rollback only if the API
#      stays down across a restart (server code itself is broken).
#   3) git rollback when the driver HEARTBEAT is stale (engine truly stuck/dead) -- and it
#      ALWAYS creates a safety branch prerollback/<ts> first, so committed work is never lost.
#   4) 'stable' advances on SUSTAINED health (healthy-since marker), not on commit age, so
#      rapid healthy commits get promoted instead of being rolled back to an old ref.
$ErrorActionPreference = 'Continue'
$b   = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { 'C:\Users\rafie\OneDrive\Documents\bridge' }
$git = if ($env:BRIDGE_GIT) { $env:BRIDGE_GIT } else { 'C:\Program Files\Git\cmd\git.exe' }
# Ф0.3: the PAUSE kill-switch lives OUTSIDE the bridge root (so outside a coder turn's
# workspace-write cwd, which IS the bridge root). A coder can therefore never create it
# to silence this safety net. Only this protected path is honored -- the legacy
# control\watchdog.pause is intentionally NOT checked anymore. Operator pauses the
# watchdog by creating <USERPROFILE>\.bridge-private\watchdog.pause. Kept inline (no
# common.ps1) so the watchdog stays self-contained even if the engine is broken.
$priv = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private' } else { Join-Path ([System.IO.Path]::GetTempPath()) '.bridge-private' }
if (-not (Test-Path $priv)) { try { New-Item -ItemType Directory -Path $priv -Force | Out-Null } catch {} }
$ctl = if (Test-Path -LiteralPath $b) { Join-Path $b 'control' } else { Join-Path $priv 'watchdog-control' }
if (-not (Test-Path $ctl)) { try { New-Item -ItemType Directory -Path $ctl -Force | Out-Null } catch {} }
$log         = Join-Path $ctl 'watchdog.log'
$failFile    = Join-Path $ctl 'watchdog.fails'
$critFile    = Join-Path $ctl 'watchdog.critical'
$fatalFile   = Join-Path $ctl 'watchdog.fatal'
$pauseFile   = Join-Path $priv 'watchdog.pause'
$healthyFile = Join-Path $ctl 'watchdog.healthy-since'
$promoteMin          = 30   # advance 'stable' after this many minutes of CONTINUOUS health
$apiRestartThreshold = 3    # api down + driver alive: gentle recycle after ~6 min
$apiRollbackThreshold= 6    # api STILL down after recycle (~12 min): server code broken -> rollback
$rollbackThreshold   = 4    # driver heartbeat stale (~8 min): engine dead -> rollback
$criticalExitThreshold = if ($env:WATCHDOG_CRIT_THRESHOLD) { [int]$env:WATCHDOG_CRIT_THRESHOLD } else { 10 }
$loopSleepSec          = if ($env:WATCHDOG_SLEEP_SEC) { [int]$env:WATCHDOG_SLEEP_SEC } else { 120 }
$criticalStreak        = 0
function WLog($m){ try { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File $log -Append -Encoding utf8 } catch {} }

# Promote the 'stable' ref (last-known-good) to HEAD once the bridge has been continuously
# HEALTHY for >= $promoteMin minutes (tracked via $healthyFile, reset on any unhealthy check)
# AND smoke.ps1 passes. Rollback targets THIS ref.
function Promote-Stable {
  try {
    Push-Location $b
    $head = (& $git rev-parse HEAD 2>$null); if ($head) { $head = ([string]$head).Trim() }
    & $git rev-parse --verify stable 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { & $git branch -f stable HEAD 2>$null; WLog "stable ref created at $head"; Pop-Location; return }
    $stable = (& $git rev-parse stable 2>$null); if ($stable) { $stable = ([string]$stable).Trim() }
    if ($head -eq $stable) { Pop-Location; return }
    $healthySince = $null
    if (Test-Path $healthyFile) { try { $healthySince = [datetime]((Get-Content $healthyFile -Raw).Trim()) } catch {} }
    if (-not $healthySince) { Pop-Location; return }
    if (((Get-Date) - $healthySince).TotalSeconds -lt ($promoteMin * 60)) { Pop-Location; return }
    $smokeScript = Join-Path $b 'smoke.ps1'
    if (Test-Path $smokeScript) {
      $smokeOut = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $smokeScript 2>&1
      if ($LASTEXITCODE -ne 0) { WLog ("smoke FAILED - not promoting: " + ($smokeOut -join '; ')); Pop-Location; return }
      WLog ("smoke OK - " + ($smokeOut -join ' '))
    }
    & $git branch -f stable HEAD 2>$null
    WLog "stable advanced to $head (healthy >= $promoteMin min)"
    Pop-Location
  } catch { try { Pop-Location } catch {}; WLog ("promote error: " + $_.Exception.Message) }
}

# Create a safety branch FIRST so committed work is NEVER destroyed, then reset to stable + re-BOM.
function Invoke-Rollback {
  try {
    Push-Location $b
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $cur = (([string](& $git rev-parse --short HEAD 2>$null)).Trim())
    & $git branch -f ("prerollback/$stamp") HEAD 2>$null
    WLog "safety branch prerollback/$stamp created at $cur (recoverable)"
    & $git rev-parse --verify stable 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { & $git reset --hard stable 2>$null; WLog "reset --hard stable" }
    else { & $git checkout -- . 2>$null; WLog "stable missing -> checkout -- ." }
    Pop-Location
  } catch { try { Pop-Location } catch {}; WLog ("git error: " + $_.Exception.Message) }
  Get-ChildItem $b -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue | ForEach-Object {
    try { $t=[System.IO.File]::ReadAllText($_.FullName,(New-Object System.Text.UTF8Encoding($false))); [System.IO.File]::WriteAllText($_.FullName,$t,(New-Object System.Text.UTF8Encoding($true))) } catch {}
  }
}

function Request-Restart {
  Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ascii
  Start-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue
}

function Check-Once {
  if (Test-Path $pauseFile) { WLog 'paused (.bridge-private\watchdog.pause present) - no action'; return }

  $apiOk = $false
  try {
    $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
    $authP = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $b 'auth.json' }
    $pw = (Get-Content $authP -Raw -Encoding UTF8 | ConvertFrom-Json).password
    $cred = New-Object System.Management.Automation.PSCredential('timur', (ConvertTo-SecureString $pw -AsPlainText -Force))
    $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8787/api/status' -Credential $cred -TimeoutSec 6
    if ($r.StatusCode -eq 200) { $apiOk = $true }
  } catch {}
  # Phase 3 (full): state.json is now per-channel under channels/<slug>/state.json.
  # Watchdog monitors EVERY channel's heartbeat; "alive" means at least the main channel
  # is fresh (it's the canonical channel — bridge git auto-rollback only applies to it
  # anyway, since other channels work in unrelated project_root repos).
  # Legacy fallback: also try root state.json (very first migration moment).
  $hbOk = $false; $hbAge = 99999
  $candidates = @(
    (Join-Path $b 'channels\main\state.json'),
    (Join-Path $b 'state.json')
  )
  foreach ($sp in $candidates) {
    if (-not (Test-Path $sp)) { continue }
    try {
      $st = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($st.heartbeat) {
        $age = [int](((Get-Date) - [datetime]$st.heartbeat).TotalSeconds)
        if ($age -lt $hbAge) { $hbAge = $age }
        if ($age -lt 300) { $hbOk = $true; break }
      }
    } catch {}
  }

  $fails = 0; if (Test-Path $failFile) { try { $fails = [int](Get-Content $failFile -Raw) } catch {} }

  if ($apiOk -and $hbOk) {
    if ($fails -ne 0) { WLog "healthy again (was failing $fails)" }
    '0' | Out-File $failFile -Encoding ascii
    if (-not (Test-Path $healthyFile)) { (Get-Date).ToString('o') | Out-File $healthyFile -Encoding ascii }
    Promote-Stable
    return
  }

  # unhealthy: reset the healthy streak and count the failure
  if (Test-Path $healthyFile) { Remove-Item $healthyFile -Force -ErrorAction SilentlyContinue }
  $fails++
  "$fails" | Out-File $failFile -Encoding ascii
  WLog "UNHEALTHY (api=$apiOk hbAge=${hbAge}s), consecutive=$fails"

  if ($hbOk) {
    # Driver is ALIVE; only the API is down -> server restarting/crashed after a self-edit.
    # This is NOT a broken engine. Try a gentle recycle; escalate to rollback only if the API
    # stays down across the recycle (the server code itself is broken).
    if ($fails -eq $apiRestartThreshold) {
      WLog "API down but driver ALIVE -> gentle RESTART server/driver (NO git rollback)"
      Request-Restart
    } elseif ($fails -ge $apiRollbackThreshold) {
      WLog "API STILL down after restart -> server code likely broken -> ROLLBACK (safety branch) + restart"
      Invoke-Rollback
      # 🩺 Doctor signal: bridge picks this up on next loop and runs auto-repair.
      try { Set-Content -LiteralPath (Join-Path $ctl 'repair.signal') -Value 'watchdog_rollback_api_stuck' -Encoding ascii } catch {}
      Request-Restart
      '0' | Out-File $failFile -Encoding ascii
      WLog "rollback applied (api-stuck)"
    }
    return
  }

  # Heartbeat is STALE -> driver dead/stuck. Engine may be broken -> rollback (safely) after threshold.
  if ($fails -ge $rollbackThreshold) {
    WLog "driver heartbeat STALE -> ROLLBACK to stable (safety branch first) + restart"
    Invoke-Rollback
    # 🩺 Doctor signal: bridge picks this up on next loop and runs auto-repair.
    try { Set-Content -LiteralPath (Join-Path $ctl 'repair.signal') -Value 'watchdog_rollback_driver_dead' -Encoding ascii } catch {}
    Request-Restart
    '0' | Out-File $failFile -Encoding ascii
    WLog "rollback applied (driver-dead)"
  }
}

WLog "=== watchdog loop started (PID $PID) [hardened] ==="
while ($true) {
  # Bounded critical-error handling: this watchdog is killed/relaunched every ~2 min by its
  # scheduled task (5-min ExecutionTimeLimit), so the consecutive-critical counter is PERSISTED
  # to $critFile to survive instance recycles. A "critical" fault is one that defeats the
  # watchdog's core job (no bridge root, no git.exe to roll back with) or any unhandled loop
  # error. After $criticalExitThreshold consecutive critical iterations we raise a one-time
  # watchdog.fatal signal and EXIT (the scheduler relaunches a fresh instance) instead of
  # logging the same error forever. A clean Check-Once resets the streak.
  $critReason = $null
  if (-not (Test-Path -LiteralPath $b))       { $critReason = "bridge root missing ($b)" }
  elseif (-not (Test-Path -LiteralPath $git)) { $critReason = "git.exe missing ($git)" }
  else {
    try { Check-Once } catch { $critReason = "loop error: " + $_.Exception.Message }
  }

  if ($critReason) {
    $cf = $criticalStreak; if (Test-Path $critFile) { try { $cf = [int](Get-Content $critFile -Raw) } catch {} }
    $cf++; $criticalStreak = $cf
    try { Set-Content -LiteralPath $critFile -Value "$cf" -Encoding ascii -ErrorAction Stop } catch {}
    WLog "CRITICAL ($critReason), consecutive=$cf/$criticalExitThreshold"
    if ($cf -ge $criticalExitThreshold) {
      WLog "FATAL: $cf consecutive critical errors [$critReason] -> raising watchdog.fatal and EXITING (scheduler relaunches a fresh instance)"
      try { Set-Content -LiteralPath $fatalFile -Value (((Get-Date).ToString('o')) + ' | ' + $critReason) -Encoding utf8 } catch {}
      try { Set-Content -LiteralPath $critFile -Value '0' -Encoding ascii -ErrorAction Stop } catch {}
      exit 1
    }
  } else {
    $criticalStreak = 0
    if (Test-Path $critFile) { Remove-Item $critFile -Force -ErrorAction SilentlyContinue }
  }

  Start-Sleep -Seconds $loopSleepSec
}
