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
# === System Sentinel config (storm detector) ===
# The watchdog judges health by heartbeat ("dead vs alive"). A driver that is ALIVE but
# restart-LOOPING, or spamming the SAME error every few seconds, is invisible to that check
# (fresh heartbeat the whole time). The 2026-05-31 StopReason storm proved the gap: ~6 identical
# driver errors + restarts, and the only thing that noticed was the operator. This sentinel adds
# a content sense: deterministic signature-counting (no LLM, self-contained), a self-heal GRACE
# window (the bridge often fixes its own bug within minutes — don't trample that), then dispatch
# via the existing repair.signal -> Doctor channel; if Doctor doesn't heal it, rollback + page.
$stormWindowMin     = if ($env:WATCHDOG_STORM_WINDOW_MIN) { [int]$env:WATCHDOG_STORM_WINDOW_MIN } else { 15 }
$stormSigThreshold  = 3     # same error/restart signature >= this many times in window = storm
$stormRestartTotal  = 4     # OR >= this many restarts (any cause) in window = storm
$stormRecencySec    = 240   # storm is "live" only if its newest hit is within this (else aging out)
$stormGraceSec      = 480   # 8 min: give the bridge time to self-heal BEFORE acting (key safety)
$stormCooldownSec   = 3600  # at most one Doctor dispatch per signature per hour
$stormEscalateSec   = 900   # 15 min still-active AFTER Doctor -> rollback + page operator
$sentinelSuspect    = Join-Path $ctl 'sentinel.suspect'
$sentinelCooldown   = Join-Path $ctl 'sentinel.cooldown'
$sentinelIncidents  = Join-Path $ctl 'sentinel.incidents.jsonl'
function WLog($m) {
  $line = ("{0}  {1}`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
  $mtx = $null
  try {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeWatchdogLog')
    [void]$mtx.WaitOne(3000)
    $fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
      $fs.Write($bytes, 0, $bytes.Length)
      $fs.Flush($true)
    } finally { $fs.Close() }
  } catch {} finally {
    if ($mtx) { try { $mtx.ReleaseMutex() } catch {}; $mtx.Dispose() }
  }
}

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

# --- System Sentinel helpers (self-contained; no common.ps1) ---
function Get-Sig8($text) {
  # Short stable key for a normalized signature (first 4 bytes of MD5, hex).
  try {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $h = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$text))
    return (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
  } catch { return 'nosig' }
}
function Get-NormSig($text) {
  # Collapse the variable parts of an error so repeats of the SAME error share one signature.
  $s = [string]$text
  $s = $s -replace '[0-9a-fA-F]{8,}', 'HEX'          # hashes/GUIDs/sha
  $s = $s -replace '\d+', 'N'                        # any number (seq, ms, counts)
  $s = $s -replace '[A-Za-z]:\\[^\s''""]+', 'PATH'   # windows paths
  $s = $s -replace '\s+', ' '
  return $s.Trim()
}
function Test-StormCooldown($sig) {
  if (-not (Test-Path $sentinelCooldown)) { return $false }
  try {
    $cd = Get-Content $sentinelCooldown -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$cd.sig -ne [string]$sig) { return $false }
    return ((((Get-Date).ToUniversalTime()) - ([datetime]$cd.ts).ToUniversalTime()).TotalSeconds -lt $stormCooldownSec)
  } catch { return $false }
}
function Set-StormCooldown($sig) {
  try { (@{ sig=$sig; ts=(Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress) | Out-File $sentinelCooldown -Encoding utf8 } catch {}
}
function Add-StormIncident($Sig,$Count,$Source,$Sample,$Action) {
  # Durable incident log -> feeds postmortem learning even when the storm self-heals.
  try {
    $s = [string]$Sample; if ($s.Length -gt 160) { $s = $s.Substring(0,160) }
    (@{ ts=(Get-Date).ToUniversalTime().ToString('o'); sig=$Sig; count=$Count; source=$Source; sample=$s; action=$Action } | ConvertTo-Json -Compress) |
      ForEach-Object { Add-Content -LiteralPath $sentinelIncidents -Value $_ -Encoding UTF8 }
  } catch {}
}

function Get-StormSignals {
  # Deterministic, LLM-free. Returns the worst storm signature crossing threshold, or $null.
  # Two sources: structured restarts.jsonl (cause+signature) and system error messages.
  $cutoff = (Get-Date).AddMinutes(-$stormWindowMin).ToUniversalTime()
  $nowU   = (Get-Date).ToUniversalTime()
  $counts = @{}   # sig8 -> @{ count; source; sample; lastU }

  # Source 1: restart events (structured) — survives driver restart-loops since it's a side file.
  try {
    $rj = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl' } else { '' }
    if ($rj -and (Test-Path $rj)) {
      $totalRestarts = 0; $lastRestartU = $null
      foreach ($line in ([System.IO.File]::ReadAllLines($rj, [System.Text.Encoding]::UTF8) | Select-Object -Last 80)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        $tu = $null; try { $tu = ([datetime]$r.ts).ToUniversalTime() } catch { continue }
        if ($tu -lt $cutoff) { continue }
        $totalRestarts++; if (-not $lastRestartU -or $tu -gt $lastRestartU) { $lastRestartU = $tu }
        $key = 'restart-cause:' + [string]$r.cause
        $sig = Get-Sig8 $key
        if (-not $counts.ContainsKey($sig)) { $counts[$sig] = @{ count=0; source='restart'; sample=([string]$r.cause); lastU=$tu } }
        $counts[$sig].count++
        if ($tu -gt $counts[$sig].lastU) { $counts[$sig].lastU = $tu }
      }
      if ($totalRestarts -ge $stormRestartTotal -and $lastRestartU) {
        $sig = Get-Sig8 'restart-volume'
        $counts[$sig] = @{ count=$totalRestarts; source='restart-volume'; sample=("$totalRestarts restarts in ${stormWindowMin}min"); lastU=$lastRestartU }
      }
    }
  } catch {}

  # Source 2: repeating system ERROR messages (the StopReason class). Read as UTF-8 so the
  # Cyrillic 'Ошибка драйвера' marker matches instead of arriving as mojibake.
  try {
    $conv = Join-Path $b 'channels\main\conversation.jsonl'
    if (Test-Path $conv) {
      $errPat = 'Ошибк|ошибк|не справил|пережила|таймаут|stderr|Cannot |Exception|\bError\b|argument transformation|timeout|rollback|❌|⚠'
      foreach ($line in ([System.IO.File]::ReadAllLines($conv, [System.Text.Encoding]::UTF8) | Select-Object -Last 200)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ([string]$m.from -ne 'system') { continue }
        $tu = $null; try { $tu = ([datetime]$m.ts).ToUniversalTime() } catch { continue }
        if ($tu -lt $cutoff) { continue }
        $txt = [string]$m.text
        if ($txt -notmatch $errPat) { continue }
        $norm = Get-NormSig $txt; if ($norm.Length -gt 100) { $norm = $norm.Substring(0,100) }
        $sig = Get-Sig8 $norm
        if (-not $counts.ContainsKey($sig)) { $counts[$sig] = @{ count=0; source='error'; sample=$txt; lastU=$tu } }
        $counts[$sig].count++
        if ($tu -gt $counts[$sig].lastU) { $counts[$sig].lastU = $tu }
      }
    }
  } catch {}

  # Worst signature that crosses threshold (restart-volume always counts).
  $worst = $null
  foreach ($k in $counts.Keys) {
    $c = $counts[$k]
    $isStorm = ($c.count -ge $stormSigThreshold) -or ($c.source -eq 'restart-volume')
    if (-not $isStorm) { continue }
    if (-not $worst -or $c.count -gt $worst.count) {
      $lastSeenSec = [int]($nowU - $c.lastU).TotalSeconds
      $worst = @{ sig=$k; count=$c.count; source=$c.source; sample=$c.sample; lastSeenSec=$lastSeenSec }
    }
  }
  return $worst
}

function Check-Storm {
  # Patient detector: suspect -> grace (self-heal) -> Doctor -> (if unhealed) rollback + page.
  # State lives in files so it survives the watchdog's own ~2-min task recycle.
  if (Test-Path $pauseFile) { return }   # honor the operator PAUSE kill-switch

  $storm = Get-StormSignals
  $suspect = $null
  if (Test-Path $sentinelSuspect) { try { $suspect = Get-Content $sentinelSuspect -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $nowU = (Get-Date).ToUniversalTime()

  # A storm is only ACTIONABLE if it is still live (recent hit). An old-but-in-window cluster
  # that stopped firing is self-healing — let it age out of the window instead of acting on it.
  $live = ($storm -and $storm.lastSeenSec -le $stormRecencySec)

  if (-not $live) {
    if ($suspect) {
      $tag = if ($storm) { "aging out (last hit $($storm.lastSeenSec)s ago)" } else { "cleared" }
      WLog ("sentinel: storm self-healed/$tag (was sig=$($suspect.sig) '$($suspect.sample)') - no action")
      try { Add-StormIncident -Sig $suspect.sig -Count ([int]$suspect.count) -Source ([string]$suspect.source) -Sample ([string]$suspect.sample) -Action 'self-healed' } catch {}
      Remove-Item $sentinelSuspect -Force -ErrorAction SilentlyContinue
    }
    return
  }

  # New storm (or a different signature) -> start the grace timer, DO NOT act yet.
  if (-not $suspect -or [string]$suspect.sig -ne [string]$storm.sig) {
    (@{ sig=$storm.sig; firstSeen=$nowU.ToString('o'); count=$storm.count; source=$storm.source; sample=$storm.sample; dispatched=$false; dispatchedAt='' } | ConvertTo-Json -Compress) | Out-File $sentinelSuspect -Encoding utf8
    WLog ("sentinel: STORM suspected sig=$($storm.sig) src=$($storm.source) count=$($storm.count) '$($storm.sample)' - grace ${stormGraceSec}s before acting")
    return
  }

  $firstSeen = $nowU; try { $firstSeen = ([datetime]$suspect.firstSeen).ToUniversalTime() } catch {}
  $ageSec = [int]($nowU - $firstSeen).TotalSeconds
  $dispatched = [bool]$suspect.dispatched

  if (-not $dispatched) {
    if ($ageSec -lt $stormGraceSec) {
      WLog ("sentinel: storm sig=$($storm.sig) persisting ${ageSec}s/${stormGraceSec}s grace (count=$($storm.count)) - waiting for self-heal")
      $suspect.count = $storm.count; ($suspect | ConvertTo-Json -Compress) | Out-File $sentinelSuspect -Encoding utf8
      return
    }
    if (Test-StormCooldown $storm.sig) {
      WLog ("sentinel: storm sig=$($storm.sig) past grace but in cooldown - not re-dispatching")
      return
    }
    # ACT (level 1): hand off to Doctor via the existing repair.signal channel.
    try { Set-Content -LiteralPath (Join-Path $ctl 'repair.signal') -Value ("storm_detected:" + $storm.source + ":" + $storm.sig) -Encoding ascii } catch {}
    Set-StormCooldown $storm.sig
    try { Add-StormIncident -Sig $storm.sig -Count $storm.count -Source $storm.source -Sample $storm.sample -Action 'doctor' } catch {}
    $suspect.dispatched = $true; $suspect.dispatchedAt = $nowU.ToString('o'); $suspect.count = $storm.count
    ($suspect | ConvertTo-Json -Compress) | Out-File $sentinelSuspect -Encoding utf8
    WLog ("sentinel: STORM CONFIRMED after ${ageSec}s grace -> repair.signal (Doctor) sig=$($storm.sig) src=$($storm.source) count=$($storm.count) '$($storm.sample)'")
    return
  }

  # ACT (level 2): Doctor was dispatched but the storm is STILL live after the escalate window.
  $dispatchedAt = $nowU; try { $dispatchedAt = ([datetime]$suspect.dispatchedAt).ToUniversalTime() } catch {}
  $sinceDispatch = [int]($nowU - $dispatchedAt).TotalSeconds
  if ($sinceDispatch -ge $stormEscalateSec) {
    WLog ("sentinel: storm sig=$($storm.sig) STILL live ${sinceDispatch}s after Doctor -> ROLLBACK + page operator")
    Invoke-Rollback
    try { Set-Content -LiteralPath (Join-Path $ctl 'repair.signal') -Value ("storm_unhealed_rollback:" + $storm.sig) -Encoding ascii } catch {}
    Request-Restart
    '0' | Out-File $failFile -Encoding ascii
    try { Add-StormIncident -Sig $storm.sig -Count $storm.count -Source $storm.source -Sample $storm.sample -Action 'rollback+page' } catch {}
    Remove-Item $sentinelSuspect -Force -ErrorAction SilentlyContinue   # post-rollback is a fresh start
    WLog ("sentinel: rollback applied (storm-unhealed) sig=$($storm.sig)")
  } else {
    WLog ("sentinel: storm sig=$($storm.sig) dispatched to Doctor ${sinceDispatch}s ago, watching (escalate at ${stormEscalateSec}s)")
    $suspect.count = $storm.count; ($suspect | ConvertTo-Json -Compress) | Out-File $sentinelSuspect -Encoding utf8
  }
}

function Test-CircuitCooldown {
  # Self-contained mirror of the supervisor's circuit-breaker trip check (lib/circuit-breaker.ps1
  # Test-CircuitTrip): count restart events in restarts.jsonl within the window; if >= maxRestarts
  # the breaker is TRIPPED (in cooldown) and the supervisor will NOT start the driver. The watchdog
  # must not restart during that window — its restart adds +1 to this very count and extends the
  # cooldown forever (the 2026-05-31 deadlock). Reads config for window/max with safe defaults.
  $windowMin = 30; $maxRestarts = 5
  try {
    $cfgP = Join-Path $b 'config.json'
    if (Test-Path $cfgP) {
      $cfg = Get-Content $cfgP -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.circuitBreaker) {
        if ($cfg.circuitBreaker.windowMin)   { $windowMin   = [int]$cfg.circuitBreaker.windowMin }
        if ($cfg.circuitBreaker.maxRestarts) { $maxRestarts = [int]$cfg.circuitBreaker.maxRestarts }
      }
    }
  } catch {}
  if ($maxRestarts -lt 1) { $maxRestarts = 5 }
  $rj = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl' } else { '' }
  if (-not $rj -or -not (Test-Path $rj)) { return $false }
  $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-1 * [Math]::Max(1, $windowMin))
  $count = 0
  try {
    foreach ($line in ([System.IO.File]::ReadAllLines($rj, [System.Text.Encoding]::UTF8))) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      # mirror circuit-breaker: MANAGED 'explicit-flag' recycles (self-deploy/recovery) don't count.
      try { $e = $line | ConvertFrom-Json; $ts = ([datetimeoffset]::Parse([string]$e.ts)).UtcDateTime; if ($ts -ge $cutoff -and [string]$e.cause -ne 'explicit-flag') { $count++ } } catch {}
    }
  } catch {}
  return ($count -ge $maxRestarts)
}

function Test-ParallelActive {
  # Returns $true if a parallel dispatch is in flight in ANY channel (workers merging into the bridge
  # repo). The watchdog only reads main's heartbeat, but a parallel run lives in the dispatching
  # channel and merges into the shared bridge repo for up to ~25min; a git reset --hard then trashes
  # the in-flight merge (load-audit finding #1). "In flight" = a channel state.json with non-empty
  # parallel_streams AND a recent mtime; if older than ~30min the run is hung -> allow the rollback.
  # Self-contained file read, no engine dependency.
  try {
    $chDir = Join-Path $b 'channels'
    if (-not (Test-Path $chDir)) { return $false }
    foreach ($d in (Get-ChildItem $chDir -Directory -ErrorAction SilentlyContinue)) {
      $sp = Join-Path $d.FullName 'state.json'
      if (-not (Test-Path $sp)) { continue }
      try { if (((Get-Date) - (Get-Item $sp).LastWriteTime).TotalMinutes -gt 30) { continue } } catch {}
      try {
        $st = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        # NB: @($null).Count is 1, not 0 -- filter null/empty so an ABSENT parallel_streams field
        # doesn't read as "active". Only real stream entries count.
        if (@($st.parallel_streams | Where-Object { $_ }).Count -gt 0) { return $true }
      } catch {}
    }
  } catch {}
  return $false
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
    try { Remove-Item -LiteralPath (Join-Path $ctl 'watchdog.stale-restart-tried') -Force -ErrorAction SilentlyContinue } catch {}
    if (-not (Test-Path $healthyFile)) { (Get-Date).ToString('o') | Out-File $healthyFile -Encoding ascii }
    Promote-Stable
    return
  }

  # unhealthy: reset the healthy streak and count the failure
  if (Test-Path $healthyFile) { Remove-Item $healthyFile -Force -ErrorAction SilentlyContinue }
  $fails++
  "$fails" | Out-File $failFile -Encoding ascii
  WLog "UNHEALTHY (api=$apiOk hbAge=${hbAge}s), consecutive=$fails"

  # 2026-05-31 DEADLOCK FIX: respect the supervisor's circuit-breaker. If it is already TRIPPED
  # (too many restarts in the window), a watchdog restart adds +1 to that very count and extends
  # the cooldown forever -> driver never starts -> heartbeat stays stale -> watchdog restarts
  # again. That loop killed the bridge for 45min today. While the breaker is tripped we HOLD:
  # no restart, no rollback. The window drains, the supervisor starts the driver cleanly, and
  # only THEN (if still unhealthy) do we act.
  if (Test-CircuitCooldown) {
    WLog "UNHEALTHY but circuit-breaker TRIPPED (cooldown) -> HOLDING; a restart now would extend the deadlock. Waiting for the restart window to drain."
    return
  }

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
    # H1 GUARD (2026-05-31 load audit, #1): do NOT reset --hard while a parallel dispatch is mid-merge.
    # The watchdog reads only main's heartbeat, but parallel runs in ANY channel merge into the bridge
    # repo for up to ~25min; rolling back then destroys in-flight merges. Hold while a fresh parallel
    # run is active anywhere (Test-ParallelActive caps the hold at ~30min so a hung run still recovers).
    if (Test-ParallelActive) {
      WLog "heartbeat STALE but a parallel dispatch is ACTIVE (workers mid-merge) -> HOLDING rollback to avoid trashing the merge"
      return
    }
    # SYSTEMIC FIX 2026-05-31: heartbeat stale = driver HUNG, not necessarily broken CODE. A
    # destructive `git reset --hard stable` here repeatedly destroyed the very fixes that stabilize
    # the bridge: rollback to an OLD stable -> the bug returns -> driver hangs again -> rollback,
    # forever ("we keep raising it from the dead"). RESTART FIRST (kills+respawns the hung driver,
    # code intact). Escalate to rollback ONLY if the code is provably broken: the restart did not
    # revive it AND smoke is red. The stale-restart marker is cleared on the next healthy check.
    $staleRestartFile = Join-Path $ctl 'watchdog.stale-restart-tried'
    if (-not (Test-Path $staleRestartFile)) {
      WLog "driver heartbeat STALE -> RESTART driver (code intact); rollback only if this fails + smoke red"
      try { Set-Content -LiteralPath $staleRestartFile -Value ((Get-Date).ToString('o')) -Encoding ascii } catch {}
      Request-Restart
      '0' | Out-File $failFile -Encoding ascii
      return
    }
    # Restart already tried and STILL stale -> is the code actually broken? Gate the destructive
    # rollback on smoke.
    $smokeRed = $false
    $smokeScript2 = Join-Path $b 'smoke.ps1'
    if (Test-Path $smokeScript2) {
      $so = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $smokeScript2 2>&1
      $smokeRed = ($LASTEXITCODE -ne 0)
      WLog ("post-restart smoke: " + $(if ($smokeRed) { 'RED -> code broken' } else { 'OK -> code fine, driver just hung' }))
    }
    try { Remove-Item -LiteralPath $staleRestartFile -Force -ErrorAction SilentlyContinue } catch {}
    if ($smokeRed) {
      WLog "driver heartbeat STALE after restart AND smoke RED -> ROLLBACK to stable + restart"
      Invoke-Rollback
      try { Set-Content -LiteralPath (Join-Path $ctl 'repair.signal') -Value 'watchdog_rollback_driver_dead' -Encoding ascii } catch {}
      Request-Restart
      '0' | Out-File $failFile -Encoding ascii
      WLog "rollback applied (code broken)"
    } else {
      WLog "heartbeat STALE but smoke OK -> NOT rolling back (would lose good code); restarting driver again"
      Request-Restart
      '0' | Out-File $failFile -Encoding ascii
    }
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
    # System Sentinel runs AFTER the core liveness check, in its own guard: a storm-detector
    # bug must never take down the watchdog's primary job (heartbeat + rollback).
    try { Check-Storm } catch { WLog ("sentinel: check error: " + $_.Exception.Message) }
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
