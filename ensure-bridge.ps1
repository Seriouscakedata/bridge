#Requires -Version 5.1
# ensure-bridge.ps1 -- EXTERNAL reliability anchor. Run by a Task Scheduler repeating trigger
# (ClaudeCodexBridge-Ensure, every ~5 min, elevated). It heals two failure modes observed 2026-06-03:
#
#   (1) OneDrive zeroed .git/refs/heads/master -> "branch broken"; bridge auto-commit + watchdog
#       rollback silently died. We restore the ref ONLY from a known-valid commit, and keep a
#       backup of the healthy SHA so a future zeroing is recoverable even if stable/origin lag.
#   (2) supervisor AND watchdog died with no auto-restart (the AtLogon Task showed "Running" because
#       orphaned driver children held the job, so RestartCount never fired) -> the bridge ran
#       UNSUPERVISED for hours. We (re)start them only when genuinely absent, rate-limited.
#
# Idempotent and conservative: never destroys data, never starts a duplicate, fail-safe on query
# errors (assume alive rather than spawn-storm). ASCII-only (no BOM dependency on PS 5.1).
$ErrorActionPreference = 'Continue'

$root    = 'C:\Users\rafie\OneDrive\Documents\bridge'
$runtime = if ($env:BRIDGE_RUNTIME) { $env:BRIDGE_RUNTIME } else { 'C:\Users\rafie\.bridge-runtime' }
if (-not (Test-Path -LiteralPath $runtime)) { try { New-Item -ItemType Directory -Path $runtime -Force | Out-Null } catch {} }
$log = Join-Path $runtime 'ensure-bridge.log'
function ELog([string]$m) { try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('o') + ' ' + $m) -Encoding UTF8 } catch {} }

$gitExe = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $gitExe)) { $gitExe = 'git' }

function Test-ValidSha([string]$sha) { return ($sha -match '^[0-9a-f]{40}$' -and $sha -ne ('0' * 40)) }
function Test-CommitExists([string]$sha) {
  try { $t = & $gitExe -C $root cat-file -t $sha 2>$null; return (([string]$t).Trim() -eq 'commit') } catch { return $false }
}
function Write-RefFile([string]$path, [string]$sha) {
  # a loose ref file is exactly 40 hex + LF (41 bytes)
  [System.IO.File]::WriteAllText($path, ($sha + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
function Resolve-GitDir([string]$repoRoot) {
  # 2026-06-03: .git was moved OFF OneDrive (separate-git-dir); $repoRoot\.git is now a GITLINK FILE
  # ("gitdir: <path>"), not a directory. Resolve the real git dir so direct ref-file access still works
  # even when git commands fail (a zeroed ref). Falls back to the directory form for safety.
  $g = Join-Path $repoRoot '.git'
  try {
    if (Test-Path -LiteralPath $g -PathType Leaf) {
      $c = [string](Get-Content -LiteralPath $g -Raw -ErrorAction SilentlyContinue)
      if ($c -match 'gitdir:\s*(.+)') { return ($matches[1].Trim() -replace '/', '\') }
    }
  } catch {}
  return $g
}

# ---------- (1) git ref heal ----------
try {
  $gitDir    = Resolve-GitDir $root
  $masterRef = Join-Path $gitDir 'refs\heads\master'
  $backup    = Join-Path $runtime 'master-ref.bak'
  $cur = ''
  if (Test-Path -LiteralPath $masterRef) {
    $cur = ([string](Get-Content -LiteralPath $masterRef -Raw -ErrorAction SilentlyContinue)).Trim()
  }
  if ((Test-ValidSha $cur) -and (Test-CommitExists $cur)) {
    # healthy -> refresh the backup so we can always recover to the last-known-good SHA
    try { Set-Content -LiteralPath $backup -Value $cur -Encoding ASCII } catch {}
  } else {
    ELog ("master ref BROKEN (value='" + $cur + "') -> attempting heal")
    $candidates = @()
    if (Test-Path -LiteralPath $backup) { $candidates += ([string](Get-Content -LiteralPath $backup -Raw -ErrorAction SilentlyContinue)).Trim() }
    $stableRef = Join-Path $gitDir 'refs\heads\stable'
    if (Test-Path -LiteralPath $stableRef) { $candidates += ([string](Get-Content -LiteralPath $stableRef -Raw -ErrorAction SilentlyContinue)).Trim() }
    try { $om = & $gitExe -C $root rev-parse refs/remotes/origin/master 2>$null; if ($om) { $candidates += ([string]$om).Trim() } } catch {}
    $healed = $false
    foreach ($c in $candidates) {
      if ((Test-ValidSha $c) -and (Test-CommitExists $c)) {
        Write-RefFile -path $masterRef -sha $c
        ELog ("master ref RESTORED to " + $c)
        $healed = $true; break
      }
    }
    if (-not $healed) { ELog "FAILED to heal master ref (no valid candidate among backup/stable/origin)" }
  }
} catch { ELog ("git-heal error: " + $_.Exception.Message) }

# ---------- (2) process heal (supervisor + watchdog) ----------
# GUARD: process-heal relies on reading CommandLine, which is only reliable when ELEVATED. A non-elevated
# run sees empty CommandLine -> would falsely conclude "dead" and trigger a needless restart. So when not
# elevated, skip process-heal entirely (git-heal above already ran and is safe at any privilege level).
$isElevated = $false
try { $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) } catch {}
if (-not $isElevated) { ELog "not elevated -> skipping process-heal (CommandLine unreadable); git-heal done"; return }

# Elevated context (this Task runs Highest) can read CommandLine; exclude -Command inspections and
# this script itself. Fail-safe to "alive" on query error so a transient WMI hiccup can't spawn-storm.
function Test-ProcAlive([string]$scriptName) {
  try {
    $n = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -like ('*-File*' + $scriptName + '*') -and
        $_.CommandLine -notlike '*-Command*' -and
        $_.CommandLine -notlike '*ensure-bridge*'
      }).Count
    return ($n -gt 0)
  } catch { return $true }
}

# rate-limit supervisor restarts (a misread must not loop Stop/Start every tick)
$stamp = Join-Path $runtime 'ensure-last-suprestart'
function Get-MinutesSince([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 9999 }
  try { return ((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalMinutes } catch { return 9999 }
}

if (-not (Test-ProcAlive 'supervisor.ps1')) {
  if ((Get-MinutesSince $stamp) -ge 10) {
    ELog "supervisor NOT alive -> restarting ClaudeCodexBridge task"
    Set-Content -LiteralPath $stamp -Value ((Get-Date).ToString('o')) -Encoding ASCII
    try { Stop-ScheduledTask  -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 3
    try { Start-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue; ELog "supervisor restart issued" }
    catch { ELog ("supervisor restart FAILED: " + $_.Exception.Message) }
  } else {
    ELog "supervisor not alive but within restart cooldown (10m) -> waiting"
  }
} else {
  # supervisor alive -> belt-and-suspenders watchdog check. Watchdog liveness = process alive AND smoke
  # FRESH. A HUNG watchdog (process alive but loop stuck, no smoke for >12 min — observed 2026-06-03,
  # likely a git/OneDrive lock stall) is KILLED and respawned, because "process exists" != "working".
  $wdProcs = @()
  try { $wdProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*watchdog.ps1*' -and $_.CommandLine -notlike '*-Command*' }) } catch {}
  $wdLog = Join-Path $root 'control\watchdog.log'
  $wdStaleMin = 9999
  if (Test-Path -LiteralPath $wdLog) { try { $wdStaleMin = ((Get-Date) - (Get-Item -LiteralPath $wdLog).LastWriteTime).TotalMinutes } catch {} }
  $needRespawn = $false
  if ($wdProcs.Count -eq 0) {
    ELog "watchdog DEAD -> respawn"; $needRespawn = $true
  } elseif ($wdStaleMin -gt 45) {  # 2026-06-22: 25->45 (operator harden: the watchdog's own cycle legitimately blocks ~30min while it tolerates a busy driver (hbAge up to 1800s) + runs smoke; a 25min staleness bar false-respawned a WORKING watchdog mid-cycle, which itself caused churn). 45min still catches a genuinely dead watchdog.
    # 2026-06-20: 12->25 min (operator directive: add time where a timeout kills a WORKING process).
    # The watchdog's own smoke cycle (parse 307 ps1 + endpoint checks) legitimately takes ~12.5 min,
    # so a 12-min staleness bar false-killed a HEALTHY-but-slow watchdog mid-smoke (~2/3 of cycles
    # aborted). 25 min still catches a genuinely hung watchdog, with margin over the real smoke time.
    ELog ("watchdog HUNG (smoke stale " + [int]$wdStaleMin + "m, proc alive) -> kill+respawn")
    foreach ($wp in $wdProcs) { try { Stop-Process -Id ([int]$wp.ProcessId) -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 2
    $needRespawn = $true
  }
  if ($needRespawn) {
    $wd = Join-Path $root 'watchdog.ps1'
    if (Test-Path $wd) {
      try { Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$wd -WindowStyle Hidden; ELog "watchdog (re)spawned" }
      catch { ELog ("watchdog spawn FAILED: " + $_.Exception.Message) }
    }
  }
}
ELog "ensure tick done"
