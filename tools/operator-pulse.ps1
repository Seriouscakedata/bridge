#Requires -Version 5.1
# operator-pulse.ps1 -- one-glance bridge status for the OPERATOR (Claude as conductor).
# File-based first (works even when the bridge is DEAD -- the case where I need it most), with a
# live API health probe on top. No dependency on the engine being up. ASCII labels; data read UTF-8.
#   Usage: powershell -NoProfile -File tools\operator-pulse.ps1 [-DoneHours 24]
param([int]$DoneHours = 24, [string]$Channel = 'main')
$ErrorActionPreference = 'Continue'
$root = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { 'C:\Users\rafie\OneDrive\Documents\bridge' }
$git  = if ($env:BRIDGE_GIT) { $env:BRIDGE_GIT } else { 'C:\Program Files\Git\cmd\git.exe' }
$now  = Get-Date
$nowU = $now.ToUniversalTime()
function JFile($p) { try { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function AgeS($iso) { try { [math]::Round(($nowU - ([datetimeoffset]::Parse([string]$iso)).UtcDateTime).TotalSeconds, 0) } catch { '?' } }
function Trunc($s, $n) { $s = [string]$s; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }
# 2026-05-31 (Foundation #4): file-based "why is this channel idle" — no engine dependency.
function WhyIdle($chName) {
  $cfg = JFile (Join-Path $root 'config.json'); $set = JFile (Join-Path $root 'settings.json')
  $enabled = $true; $quiet = 10.0; $cap = 0; $disabled = @('travel')
  if ($cfg -and $cfg.autonomy) {
    if ($null -ne $cfg.autonomy.enabled) { $enabled = [bool]$cfg.autonomy.enabled }
    if ($null -ne $cfg.autonomy.idleQuietMinutes) { $quiet = [double]$cfg.autonomy.idleQuietMinutes }
    if ($null -ne $cfg.autonomy.maxAutonomousTasksPerDay) { $cap = [int]$cfg.autonomy.maxAutonomousTasksPerDay }
    if ($cfg.autonomy.autonomyDisabledChannels) { $disabled = @($cfg.autonomy.autonomyDisabledChannels) }
  }
  if ($set) {
    if ($null -ne $set.enabled) { $enabled = [bool]$set.enabled }
    if ($null -ne $set.idleQuietMinutes) { $quiet = [double]$set.idleQuietMinutes }
    if ($null -ne $set.maxAutonomousTasksPerDay) { $cap = [int]$set.maxAutonomousTasksPerDay }
  }
  if (-not $enabled) { return 'autonomy disabled' }
  if ($disabled -contains $chName) { return 'paused (autonomyDisabledChannels)' }
  $conv = Join-Path $root "channels\$chName\conversation.jsonl"; $lua = 99999.0
  if (Test-Path $conv) { try { $lua = ($nowU - (Get-Item $conv).LastWriteTimeUtc).TotalMinutes } catch {} }
  if ($lua -lt $quiet) { return ("idle-quiet: {0:N1}m < {1}m tишины" -f $lua, $quiet) }
  if ($cap -gt 0) {
    $st = JFile (Join-Path $root "channels\$chName\state.json"); $today = $now.ToString('yyyy-MM-dd')
    if ($st -and [string]$st.autonomous_day -eq $today -and [int]$st.autonomous_count -ge $cap) { return ('daily cap ' + $st.autonomous_count + '/' + $cap) }
  }
  return 'ready'
}

Write-Host ("=== BRIDGE :: OPERATOR PULSE @ " + $now.ToString('yyyy-MM-dd HH:mm:ss') + " ===") -ForegroundColor Cyan

# ---------- HEALTH ----------
$apiCode = 'DOWN'
try {
  $privAuth = Join-Path $env:USERPROFILE '.bridge-private\auth.json'
  $authP = if (Test-Path $privAuth) { $privAuth } else { Join-Path $root 'auth.json' }
  $pw = (Get-Content $authP -Raw -Encoding UTF8 | ConvertFrom-Json).password
  $cred = New-Object System.Management.Automation.PSCredential('timur', (ConvertTo-SecureString $pw -AsPlainText -Force))
  $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8787/api/status' -Credential $cred -TimeoutSec 5
  $apiCode = [string]$r.StatusCode
} catch {}

# circuit-breaker mode (mirror Test-CircuitTrip: restarts in 30m vs max 5)
$winMin = 30; $maxR = 5
$cfg = JFile (Join-Path $root 'config.json')
if ($cfg -and $cfg.circuitBreaker) { if ($cfg.circuitBreaker.windowMin) { $winMin = [int]$cfg.circuitBreaker.windowMin }; if ($cfg.circuitBreaker.maxRestarts) { $maxR = [int]$cfg.circuitBreaker.maxRestarts } }
$rj = Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl'
$cut = $nowU.AddMinutes(-$winMin); $rCount = 0; $lastR = ''
if (Test-Path $rj) { foreach ($ln in [System.IO.File]::ReadAllLines($rj, [System.Text.Encoding]::UTF8)) { if ([string]::IsNullOrWhiteSpace($ln)) { continue }; try { $e = $ln | ConvertFrom-Json; $ts = ([datetimeoffset]::Parse([string]$e.ts)).UtcDateTime; if ($ts -ge $cut) { $rCount++; $lastR = [string]$e.cause } } catch {} } }
$cbMode = if ($rCount -ge $maxR) { "COOLDOWN (TRIPPED)" } else { "allow" }
$wdPaused = Test-Path (Join-Path $env:USERPROFILE '.bridge-private\watchdog.pause')

$head = (([string](& $git -C $root rev-parse --short HEAD 2>$null)).Trim())
$dirty = @(& $git -C $root status --porcelain 2>$null | Where-Object { $_ -match '\S' }).Count

Write-Host "HEALTH:" -ForegroundColor Yellow
$apiColor = if ($apiCode -eq '200') { 'Green' } else { 'Red' }
Write-Host ("  API=" + $apiCode + "  circuit-breaker=" + $cbMode + " (" + $rCount + "/" + $maxR + " restarts/" + $winMin + "m)  watchdog=" + $(if ($wdPaused) { 'PAUSED' } else { 'armed' })) -ForegroundColor $apiColor
Write-Host ("  git: HEAD " + $head + "  " + $(if ($dirty -gt 0) { "DIRTY ($dirty files)" } else { "clean" }))

# ---------- PER-CHANNEL ----------
$channels = @(Get-ChildItem (Join-Path $root 'channels') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^[_.]' } | ForEach-Object { $_.Name })
$waiting = New-Object System.Collections.ArrayList
Write-Host "CHANNELS:" -ForegroundColor Yellow
foreach ($ch in $channels) {
  $st = JFile (Join-Path $root "channels\$ch\state.json")
  if (-not $st) { Write-Host ("  " + $ch + ": (no state)"); continue }
  $hb = AgeS $st.heartbeat
  $hbFlag = if ($hb -is [int] -and $hb -gt 300) { " STALE!" } else { "" }
  $line = "  " + $ch + ": " + [string]$st.status + " hb=" + $hb + "s" + $hbFlag
  if (-not [string]::IsNullOrWhiteSpace([string]$st.active_agent)) { $line += " agent=" + $st.active_agent }
  if ([bool]$st.doctor_active) { $line += " [DOCTOR:" + $st.doctor_reason + "]" }
  Write-Host $line -ForegroundColor $(if ($hbFlag) { 'Red' } else { 'White' })
  if (-not [string]::IsNullOrWhiteSpace([string]$st.current_task)) {
    $dur = if ($st.claimed_at) { AgeS $st.claimed_at } else { '?' }
    Write-Host ("      working: " + (Trunc $st.current_task 90) + "  (" + $dur + "s, turn " + $st.task_turn + ")") -ForegroundColor DarkGray
  } elseif ([string]$st.status -eq 'idle') {
    $wi = WhyIdle $ch
    if ($wi -and $wi -ne 'ready') { Write-Host ("      why-idle: " + $wi) -ForegroundColor DarkYellow }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$st.held_task)) { [void]$waiting.Add("[" + $ch + "] held_task: " + (Trunc $st.held_task 80)) }
}

# ---------- QUEUE (backlog, per -Channel) ----------
$bk = Join-Path $root "channels\$Channel\backlog.jsonl"
$lastStatus = @{}; $lastObj = @{}; $doneRecent = 0
if (Test-Path $bk) {
  $doneCut = $nowU.AddHours(-$DoneHours)
  foreach ($ln in [System.IO.File]::ReadAllLines($bk, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    try { $o = $ln | ConvertFrom-Json; if ($o.id) { $lastStatus[[string]$o.id] = [string]$o.status; $lastObj[[string]$o.id] = $o } } catch {}
  }
}
$grp = @{}; foreach ($s in $lastStatus.Values) { if (-not $grp.ContainsKey($s)) { $grp[$s] = 0 }; $grp[$s]++ }
Write-Host ("QUEUE (backlog: " + $Channel + "):") -ForegroundColor Yellow
$qline = ($grp.GetEnumerator() | Where-Object { $_.Key -in @('approved','running','new','held','failed') } | Sort-Object Name | ForEach-Object { $_.Key + "=" + $_.Value }) -join "  "
Write-Host ("  " + $(if ($qline) { $qline } else { '(empty)' }))
Write-Host ("  closed total: done=" + [int]$grp['done'] + " auto-resolved=" + [int]$grp['auto-resolved'] + " dropped=" + [int]$grp['auto-dropped'])
# #1 THROUGHPUT-METRIC: honest autonomy -- of tasks the bridge ATTEMPTED, how many closed without me.
$cleanClosed = [int]$grp['done'] + [int]$grp['auto-resolved']
$attempted = $cleanClosed + [int]$grp['failed']
$autoPct = if ($attempted -gt 0) { [math]::Round(100.0 * $cleanClosed / $attempted, 1) } else { 0 }
Write-Host ("  autonomy: " + $autoPct + "% (" + $cleanClosed + " closed without operator / " + $attempted + " attempted)") -ForegroundColor $(if ($autoPct -ge 80) { 'Green' } elseif ($autoPct -ge 50) { 'Yellow' } else { 'Red' })

# ---------- OPERATOR BATCHES (Block C) -- my handle on what I delegated ----------
$opLast = @{}
if (Test-Path $bk) {
  foreach ($ln in [System.IO.File]::ReadAllLines($bk, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
    try { $o = $ln | ConvertFrom-Json; if ($o.id -and (@($o.tags) -contains 'operator')) { $opLast[[string]$o.id] = $o } } catch {}
  }
}
$activeBatches = @{}
foreach ($it in $opLast.Values) {
  if ([string]$it.status -eq 'rejected') { continue }
  $bn = @($it.tags | Where-Object { $_ -like 'batch:*' } | Select-Object -First 1)
  $bn = if ($bn.Count) { [string]$bn[0] } else { 'batch:?' }
  if (-not $activeBatches.ContainsKey($bn)) { $activeBatches[$bn] = [pscustomobject]@{ total = 0; done = 0; failed = 0 } }
  $activeBatches[$bn].total++
  $s = [string]$it.status
  if ($s -in @('done', 'auto-resolved')) { $activeBatches[$bn].done++ } elseif ($s -eq 'failed') { $activeBatches[$bn].failed++ }
}
if ($activeBatches.Count -gt 0) {
  Write-Host "OPERATOR BATCHES (delegated):" -ForegroundColor Yellow
  foreach ($bn in $activeBatches.Keys) { $v = $activeBatches[$bn]; Write-Host ("  " + $bn + ": " + $v.done + "/" + $v.total + " done" + $(if ($v.failed) { " (" + $v.failed + " failed)" } else { "" })) }
}

# ---------- DONE (window: git commits) ----------
$sinceArg = "--since=$DoneHours.hours.ago"
$commits = @(& $git -C $root log $sinceArg --oneline 2>$null)
Write-Host ("PROGRESS (" + $DoneHours + "h):") -ForegroundColor Yellow
$mainState = JFile (Join-Path $root "channels\$Channel\state.json")
$autoCount = if ($mainState) { [string]$mainState.autonomous_count } else { '?' }
$streak = if ($mainState) { [string]$mainState.autonomy_streak } else { '?' }
Write-Host ("  commits=" + $commits.Count + "  autonomous_today=" + $autoCount + "  autonomy_streak=" + $streak)

# ---------- WAITING FOR OPERATOR ----------
if (Test-Path (Join-Path $root 'control\repair.signal')) { [void]$waiting.Add("repair.signal pending (Doctor dispatch)") }
$susp = Join-Path $root 'control\sentinel.suspect'
if (Test-Path $susp) { $sp = JFile $susp; if ($sp) { [void]$waiting.Add("sentinel: storm suspect sig=" + $sp.sig + " '" + (Trunc $sp.sample 50) + "'") } }
$heldCount = [int]$grp['held']; $failedCount = [int]$grp['failed']
if ($heldCount -gt 0) { [void]$waiting.Add("$heldCount task(s) HELD in backlog") }
# #4 FAILURE-CLASSIFIER (pulse-side heuristic, no LLM): group failed tasks so I know WHAT broke.
if ($failedCount -gt 0) {
  $failClasses = @{}
  foreach ($it in $lastObj.Values) {
    if ([string]$it.status -ne 'failed') { continue }
    $reason = ([string]$it.reason).ToLowerInvariant()
    $txt = ([string]$it.text).ToLowerInvariant()
    $cls = if ($reason -match 'restart.?loop|task_restart|survived') { 'flaky/timeout' }
           elseif ($txt -match 'watchdog|supervisor|process.?supervision|circuit.?break|runtime.?incident') { 'control-plane (operator-only)' }
           elseif ($reason -match 'parse|smoke|broken') { 'real-bug' }
           else { 'needs-review' }
    if (-not $failClasses.ContainsKey($cls)) { $failClasses[$cls] = 0 }
    $failClasses[$cls]++
  }
  $clsLine = ($failClasses.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key + '=' + $_.Value }) -join ', '
  [void]$waiting.Add("$failedCount FAILED -> " + $clsLine)
}
Write-Host "NEEDS YOU:" -ForegroundColor Yellow
if ($waiting.Count -eq 0) { Write-Host "  (nothing waiting)" -ForegroundColor Green }
else { foreach ($w in $waiting) { Write-Host ("  - " + $w) -ForegroundColor Magenta } }
