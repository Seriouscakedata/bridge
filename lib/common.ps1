# common.ps1 -- shared helpers for the bridge. Dot-source this.
# All state lives in files under the bridge root so it survives reboots.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common-files.ps1')
. (Join-Path $PSScriptRoot 'common-strings.ps1')
. (Join-Path $PSScriptRoot 'common-json.ps1')
. (Join-Path $PSScriptRoot 'retry-helper.ps1')

function Get-BridgeRoot {
  # lib/ is one level under the bridge root
  Split-Path -Parent $PSScriptRoot
}

function Invoke-GitNative {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][object[]]$GitArgs
  )

  $nativeArgs = @('-C', [string]$RepoRoot)
  if ($GitArgs) {
    foreach ($arg in $GitArgs) {
      if ($null -eq $arg) { continue }
      $nativeArgs += [string]$arg
    }
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $output = @()
  $exitCode = 1
  try {
    $output = @(& git @nativeArgs 2>&1)
    try { $exitCode = [int]$LASTEXITCODE } catch { $exitCode = 1 }
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = @($output | ForEach-Object { [string]$_ })
    Args     = @($nativeArgs)
  }
}

function Invoke-GitAddPaths {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [string[]]$Paths = @()
  )

  $cleanPaths = @(
    $Paths |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($cleanPaths.Count -eq 0) {
    return [pscustomobject]@{
      ExitCode = 0
      Output   = @()
      Args     = @('add', '--')
      Skipped  = $true
    }
  }

  return Invoke-GitNative -RepoRoot $RepoRoot -GitArgs (@('add', '--') + $cleanPaths)
}

function Invoke-GitCommitMessage {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$Message
  )

  return Invoke-GitNative -RepoRoot $RepoRoot -GitArgs @('commit', '-m', [string]$Message)
}


function Get-BridgeConfig {
  # Loads config.json then overlays settings.json (gitignored, survives rollbacks).
  # Keys: flat ("maxAutonomousTasksPerDay") or dotted ("parallel.maxStreams").
  # Dotted-path goes into nested config; flat key overlays only if cfg has root key.
  #
  # PERF (2026-05-29): the idle driver loop calls this 10-15x PER SECOND, and each call
  # used to read BOTH config.json and settings.json from disk on a OneDrive-backed folder
  # where reads are network-latency-bound -- a major source of "redundant loop" overhead.
  # We now cache the RAW TEXT of both files keyed on a cheap (mtime,size) stamp and re-read
  # ONLY when a file actually changes. We still ConvertFrom-Json + overlay FRESH on every
  # call, so the returned object is always a brand-new instance: callers that Add-Member
  # onto it cannot poison the cache, and a settings.json edit (e.g. a UI toggle) is picked
  # up on the very next call because the stamp changes. If stat throws (transient OneDrive
  # hiccup) the stamp goes empty and we fall back to a direct read -- correctness never
  # depends on the cache.
  $root = Get-BridgeRoot
  $cfgPath = Join-Path $root 'config.json'
  $setPath = Join-Path $root 'settings.json'

  $stamp = ''
  try { $ci = Get-Item -LiteralPath $cfgPath -ErrorAction Stop; $stamp = '' + $ci.LastWriteTimeUtc.Ticks + ':' + $ci.Length } catch { $stamp = '' }
  if ($stamp -ne '') {
    try {
      if (Test-Path -LiteralPath $setPath) { $si = Get-Item -LiteralPath $setPath -ErrorAction Stop; $stamp += '|' + $si.LastWriteTimeUtc.Ticks + ':' + $si.Length }
      else { $stamp += '|none' }
    } catch { $stamp = '' }
  }

  if ($script:__bridgeCfgCache -and $stamp -ne '' -and [string]$script:__bridgeCfgCache.stamp -eq $stamp) {
    $cfgRaw = [string]$script:__bridgeCfgCache.cfgRaw
    $setRaw = [string]$script:__bridgeCfgCache.setRaw
  } else {
    $cfgRaw = Get-Content $cfgPath -Raw -Encoding UTF8
    $setRaw = ''
    if (Test-Path -LiteralPath $setPath) { try { $setRaw = Get-Content $setPath -Raw -Encoding UTF8 } catch { $setRaw = '' } }
    if ($stamp -ne '') { $script:__bridgeCfgCache = @{ stamp = $stamp; cfgRaw = $cfgRaw; setRaw = $setRaw } }
  }

  $cfg = $cfgRaw | ConvertFrom-Json
  try {
    if (-not [string]::IsNullOrWhiteSpace($setRaw)) {
      $s = $setRaw | ConvertFrom-Json
      if ($s) {
        foreach ($p in $s.PSObject.Properties) {
          $k = [string]$p.Name; $v = $p.Value
          if ($k -match '\.') {
            $parts = $k -split '\.', 2
            $section = $parts[0]; $field = $parts[1]
            if ($cfg.PSObject.Properties.Name -notcontains $section) {
              $cfg | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $cfg.$section | Add-Member -NotePropertyName $field -NotePropertyValue $v -Force
          } else {
            if ($cfg.PSObject.Properties.Name -contains $k) {
              $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force
            }
          }
        }
      }
    }
  } catch {}
  return $cfg
}


function Get-FastLaneSettings {
  $out = @{ autoDetect = $false; minChars = 100; embedBatchEnabled = $true }
  try {
    $cfgF = Get-BridgeConfig
    if ($cfgF -and ($cfgF.PSObject.Properties.Name -contains 'fastLane') -and $cfgF.fastLane) {
      $fl = $cfgF.fastLane
      if (($fl.PSObject.Properties.Name -contains 'autoDetect') -and $null -ne $fl.autoDetect) { $out.autoDetect = [bool]$fl.autoDetect }
      if (($fl.PSObject.Properties.Name -contains 'minChars') -and $fl.minChars) { $out.minChars = [int]$fl.minChars }
      if (($fl.PSObject.Properties.Name -contains 'embedBatchEnabled') -and $null -ne $fl.embedBatchEnabled) { $out.embedBatchEnabled = [bool]$fl.embedBatchEnabled }
    }
  } catch {}
  if ([int]$out.minChars -le 0) { $out.minChars = 100 }
  return $out
}


function Resolve-CodexExe {
  param($cfg)
  # Prefer the real (non-virtualized) MSIX package path -- it is reachable from ANY
  # context, including a bare Task Scheduler process. The AppData\Local\OpenAI path is
  # MSIX-virtualized and only visible inside the package context.
  $cands = @(
    "$env:LOCALAPPDATA\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\OpenAI\Codex\bin\codex.exe",
    $cfg.codexExe,
    "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
  )
  foreach ($c in $cands) {
    if (-not $c) { continue }
    try {
      if (Test-Path -LiteralPath $c -ErrorAction Stop) { return $c }
    } catch {}
  }
  throw "codex.exe not found (tried: $($cands -join '; '))"
}

function Resolve-ClaudeExe {
  param($cfg)
  $globs = @(
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code\*\claude.exe",
    $cfg.claudeGlob,
    "$env:APPDATA\Claude\claude-code\*\claude.exe"
  )
  foreach ($g in $globs) {
    if (-not $g) { continue }
    $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  throw "claude.exe not found (tried: $($globs -join '; '))"
}


function Recover-ZombieJobs {
  # 2026-05-27v7: callable remediation for stuck active_jobs. For each job in
  # state.active_jobs, if its PID is dead (or startTicks mismatch), write a
  # fake .done marker (exit=-1) so polling loop closes the job next iteration.
  # Returns @{ recovered = N } so caller can log/report.
  # Used by: driver startup AND auditor 'wait_state_stuck' trigger.
  param([string]$Slug = 'main')
  $recovered = 0
  try {
    $sp = $null
    try {
      if (Get-Command Get-StatePath -ErrorAction SilentlyContinue) {
        $oldPin = $null; $had = $false
        try {
          if (Get-Command Get-PinnedChannel -ErrorAction SilentlyContinue) { $oldPin = Get-PinnedChannel; $had = $true }
          if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) { Set-PinnedChannel $Slug }
          $sp = Get-StatePath
        } finally {
          if ($had -and (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue)) { Set-PinnedChannel $oldPin }
        }
      }
    } catch {}
    if (-not $sp -or -not (Test-Path -LiteralPath $sp)) { return @{ recovered = 0 } }
    $st = $null
    try { $st = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @{ recovered = 0 } }
    if (-not $st -or -not ($st.PSObject.Properties.Name -contains 'active_jobs')) { return @{ recovered = 0 } }
    $jobs = @($st.active_jobs)
    if ($jobs.Count -eq 0) { return @{ recovered = 0 } }
    $jobsDir = Join-Path (Get-BridgeRoot) 'jobs'
    foreach ($bj in $jobs) {
      $jp = 0; try { $jp = [int]$bj.pid } catch {}
      $alive = $false
      if ($jp -gt 0) {
        try {
          $bp = Get-Process -Id $jp -ErrorAction SilentlyContinue
          if ($bp) {
            $ticks = 0L; try { $ticks = [long]$bj.startTicks } catch {}
            if ($ticks -le 0) { $alive = $true }
            else { try { if ($bp.StartTime.Ticks -eq $ticks) { $alive = $true } } catch {} }
          }
        } catch {}
      }
      if (-not $alive) {
        $donePath = Join-Path $jobsDir (([string]$bj.id) + '.done')
        try {
          if (-not (Test-Path -LiteralPath $donePath)) {
            [System.IO.File]::WriteAllText($donePath, '-1', (New-Object System.Text.UTF8Encoding($false)))
            $recovered++
          }
        } catch {}
      }
    }
  } catch {}
  return @{ recovered = $recovered }
}

function Register-ChildProcess {
  # 2026-05-27v6: P2 audit finding -- Start-Process powershell.exe for librarian,
  # reflect, radar, curator was fire-and-forget with no monitoring. Now caller
  # registers child PID with a label. Periodic Sweep-ChildProcesses checks status.
  # Records to control/children.jsonl: { ts, label, pid, ticks }.
  param([string]$Label, [int]$ProcessId, [long]$Ticks = 0)
  if ($ProcessId -le 0) { return }
  try {
    $dir = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'children.jsonl'
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $rec = [ordered]@{ ts = (Get-Date).ToString('o'); label = $Label; pid = $ProcessId; ticks = $Ticks; status = 'started' }
    [System.IO.File]::AppendAllText($path, ($rec | ConvertTo-Json -Compress -Depth 4) + "`n", $u8)
  } catch {}
}

function Sweep-ChildProcesses {
  # Periodic sweep of registered children. Marks crashed ones (pid gone) with
  # crash notes if running > MinAliveMin AND died without explicit exit log.
  # Reads control/children.jsonl, dedups by pid, checks each. Compacts the log
  # by writing only still-relevant entries (last 50 + alive children).
  param([int]$MaxAgeMin = 30)
  try {
    $path = Join-Path (Get-BridgeRoot) 'control\children.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @{ checked=0; dead=0 } }
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $lines = @([System.IO.File]::ReadAllLines($path, $u8))
    if ($lines.Count -eq 0) { return @{ checked=0; dead=0 } }
    # parse last N entries
    $cutoff = (Get-Date).AddMinutes(-$MaxAgeMin)
    $byPid = @{}
    foreach ($l in $lines) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      try { $obj = $l | ConvertFrom-Json } catch { continue }
      if (-not $obj.pid) { continue }
      $byPid[[string]$obj.pid] = $obj
    }
    $checked = 0; $dead = 0
    $alive = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($byPid.Keys)) {
      $obj = $byPid[$key]
      $pidNum = [int]$obj.pid
      $tsRaw = [string]$obj.ts
      $started = (Get-Date)
      try { $started = [datetime]::Parse($tsRaw) } catch {}
      if ($started -lt $cutoff) { continue }   # too old, drop from tracking
      $checked++
      $proc = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
      if ($proc) {
        # Verify ticks match (PID may have been reused)
        $tickOk = $true
        try { if ([long]$obj.ticks -gt 0 -and $proc.StartTime.Ticks -ne [long]$obj.ticks) { $tickOk = $false } } catch {}
        if ($tickOk) { [void]$alive.Add($obj) }
        else         { $dead++ }
      } else {
        $dead++
      }
    }
    # Rewrite log with last 50 records + alive set (keep audit trail short)
    $tail = @($lines | Select-Object -Last 50)
    $newContent = ($tail -join "`n") + "`n"
    try { [System.IO.File]::WriteAllText($path, $newContent, $u8) } catch {}
    return @{ checked = $checked; dead = $dead; alive_count = $alive.Count }
  } catch { return @{ checked=0; dead=0; error=$_.Exception.Message } }
}

function Test-CodexIsBridgeOwned {
  # 2026-05-28: distinguish a bridge-spawned codex.exe from an unrelated codex
  # process (e.g. user's Codex desktop app, an interactive `codex` shell the
  # user launched themselves). The bridge ALWAYS invokes codex with:
  #     codex exec --color never --skip-git-repo-check -c ... -s read-only -C <root> -o <file> -
  # This combination (`exec` subcommand + `--skip-git-repo-check`) is the
  # bridge fingerprint -- nothing the user runs interactively uses both.
  # ParentProcessId fallback: if the parent is bridge powershell.exe (driver,
  # supervisor, audit-launcher), the child is ours regardless of CLI flags.
  param([string]$CommandLine, [int]$ParentPid, [hashtable]$BridgePowershellPids)
  if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
    $cl = $CommandLine.ToLowerInvariant()
    # Both markers must be present. `exec` alone is too permissive (could be
    # any codex subcommand name fragment); the skip-flag is bridge-specific.
    if ($cl -match '\bexec\b' -and $cl -match '--skip-git-repo-check') { return $true }
  }
  if ($ParentPid -gt 0 -and $BridgePowershellPids -and $BridgePowershellPids.ContainsKey([string]$ParentPid)) {
    return $true
  }
  return $false
}

function Get-BridgePowershellPids {
  # PIDs of powershell.exe processes whose working dir or command-line ties
  # them to the bridge root. Used as a fallback ownership signal for codex.exe
  # whose CLI markers were stripped (rare, but happens with -PassThru wrappers).
  $set = @{}
  try {
    $bridgeRoot = (Get-BridgeRoot).ToLowerInvariant()
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      $cl = [string]$p.CommandLine
      $cwd = ''
      if (-not [string]::IsNullOrWhiteSpace($cl) -and $cl.ToLowerInvariant().Contains($bridgeRoot)) {
        $set[[string]$p.ProcessId] = $true
      }
    }
  } catch {}
  return $set
}

function Sweep-OrphanAgentProcesses {
  # 2026-05-28: orphan codex.exe accumulation was a real incident -- user found
  # 11 stale codex.exe processes (one 22 hours old, 360MB resident) because
  # Sweep-ChildProcesses only sweeps EXPLICITLY registered children (librarian,
  # audit, verifier), and most codex.exe instances are spawned inline by
  # Invoke-Coder without registration.
  #
  # 2026-05-28 v2: the previous allowlist-only logic killed the user's own
  # Codex desktop app and interactive `codex` shells (any codex.exe whose PID
  # wasn't in state.json/children.jsonl). Now we INVERT the check: only kill
  # codex.exe that is provably bridge-owned (Test-CodexIsBridgeOwned matches
  # bridge CLI fingerprint OR parent is a bridge powershell.exe). External
  # codex processes are always spared, age-of-process is irrelevant.
  #
  # SAFETY: NEVER touches claude.exe -- user's IDE is also claude.exe (per
  # security rule). We only sweep codex.exe (bridge-exclusive).
  param([int]$MaxIdleMin = 30)
  $result = @{ checked = 0; killed = 0; spared = 0; spared_external = 0; errors = @() }
  try {
    # Legacy belt-and-suspenders allowlist: PIDs explicitly tracked by the
    # bridge always survive even if CLI fingerprint matches (e.g. an actively
    # running codex shouldn't be touched).
    $activePids = @{}
    $chRoot = Join-Path (Get-BridgeRoot) 'channels'
    if (Test-Path -LiteralPath $chRoot) {
      Get-ChildItem -LiteralPath $chRoot -Directory -EA SilentlyContinue | ForEach-Object {
        $sp = Join-Path $_.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $sp)) { return }
        try {
          $st = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json
          foreach ($f in @('agent_pid', 'current_agent_pid')) {
            $v = $null; try { $v = $st.$f } catch {}
            if ($v -and [int]$v -gt 0) { $activePids[[string]$v] = $true }
          }
        } catch {}
      }
    }
    $registered = @{}
    $childrenPath = Join-Path (Get-BridgeRoot) 'control\children.jsonl'
    if (Test-Path -LiteralPath $childrenPath) {
      foreach ($l in (Get-Content -LiteralPath $childrenPath -Encoding UTF8 -EA SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $obj = $l | ConvertFrom-Json } catch { continue }
        if ($obj.pid) { $registered[[string]$obj.pid] = $true }
      }
    }

    $bridgePsPids = Get-BridgePowershellPids
    $cimProcs = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction SilentlyContinue)
    foreach ($cp in $cimProcs) {
      $result.checked++
      $pidStr = [string]$cp.ProcessId
      $cmdLine = [string]$cp.CommandLine
      $parentPid = 0; try { $parentPid = [int]$cp.ParentProcessId } catch {}

      # 1. External codex (user's desktop app, manual shell, etc.) -- ALWAYS spare.
      $ownedByBridge = Test-CodexIsBridgeOwned -CommandLine $cmdLine -ParentPid $parentPid -BridgePowershellPids $bridgePsPids
      if (-not $ownedByBridge) {
        $result.spared_external++
        $result.spared++
        continue
      }

      # 2. Bridge-owned but actively tracked (state.json / children.jsonl) -- spare.
      if ($activePids.ContainsKey($pidStr) -or $registered.ContainsKey($pidStr)) {
        $result.spared++
        continue
      }

      # 3. Bridge-owned, untracked, and old enough -- kill as orphan.
      $age = $null
      try {
        if ($cp.CreationDate) {
          $age = (Get-Date) - ([Management.ManagementDateTimeConverter]::ToDateTime($cp.CreationDate))
        }
      } catch {}
      if (-not $age) {
        try { $age = (Get-Date) - (Get-Process -Id $cp.ProcessId -ErrorAction Stop).StartTime } catch {}
      }
      if ($age -and $age.TotalMinutes -gt $MaxIdleMin) {
        try {
          (Get-Process -Id $cp.ProcessId -ErrorAction Stop).Kill()
          $result.killed++
        } catch {
          $result.errors += "pid=$($cp.ProcessId): $($_.Exception.Message)"
        }
      } else {
        $result.spared++
      }
    }
  } catch { $result.errors += $_.Exception.Message }
  # Compact log entry if anything happened.
  if ($result.killed -gt 0 -or $result.errors.Count -gt 0) {
    try {
      $logPath = Join-Path (Get-BridgeRoot) 'control\orphan-sweep.log'
      $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  codex sweep: killed=$($result.killed) spared=$($result.spared) (external=$($result.spared_external)) errors=$($result.errors.Count)"
      [System.IO.File]::AppendAllText($logPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
  }
  return $result
}


function Read-Summary {
  $p = Get-SummaryPath
  if (-not (Test-Path $p)) { return '' }
  $s = Get-Content $p -Raw -Encoding UTF8
  if ($null -eq $s) { return '' }
  return $s
}
function Write-Summary {
  param([string]$Text)
  Write-AtomicFile -Path (Get-SummaryPath) -Content ([string]$Text)
}

function Get-ApplyRestartStampPath {
  param([string]$Root = $null)
  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  return (Join-Path (Join-Path $Root 'control') 'apply-stamp.json')
}

function New-ApplyRestartStamp {
  param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$Reason = 'verified-ps1-diff',
    [string[]]$Touched = @(),
    [string]$Root = $null,
    [int]$TtlMinutes = 90,
    [DateTimeOffset]$CreatedAtUtc = [DateTimeOffset]::UtcNow
  )

  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'New-ApplyRestartStamp: TaskId is required' }
  if ($TtlMinutes -le 0) { $TtlMinutes = 90 }

  $cleanTouched = @(
    $Touched |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() }
  )
  $ps1Touched = @($cleanTouched | Where-Object { $_ -match '(?i)\.ps1$' })
  if ($ps1Touched.Count -lt 1) { throw 'New-ApplyRestartStamp: evidence.touched must include at least one .ps1 path' }

  $controlDir = Join-Path $Root 'control'
  if (-not (Test-Path -LiteralPath $controlDir)) { New-Item -ItemType Directory -Path $controlDir -Force | Out-Null }
  $stampPath = Get-ApplyRestartStampPath -Root $Root
  $stamp = [ordered]@{
    task_id        = [string]$TaskId
    created_at_utc = $CreatedAtUtc.UtcDateTime.ToString('o')
    ttl_minutes    = [int]$TtlMinutes
    reason         = [string]$Reason
    evidence       = [ordered]@{
      touched = @($cleanTouched)
    }
  }
  $json = $stamp | ConvertTo-Json -Depth 8
  Write-AtomicFile -Path $stampPath -Content $json -NoCopyFallback
  return [pscustomobject][ordered]@{
    ok         = $true
    path       = $stampPath
    task_id    = [string]$TaskId
    ttl_minutes = [int]$TtlMinutes
  }
}

function Consume-ApplyRestartStamp {
  param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$Root = $null,
    [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
  )

  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  if ([string]::IsNullOrWhiteSpace($TaskId)) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'missing-task-id'; path = ''; consumed_path = '' }
  }

  $stampPath = Get-ApplyRestartStampPath -Root $Root
  if (-not (Test-Path -LiteralPath $stampPath)) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'missing-stamp'; path = $stampPath; consumed_path = '' }
  }

  $controlDir = Split-Path -Parent $stampPath
  $consumedPath = Join-Path $controlDir ('apply-stamp.consumed.' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    [System.IO.File]::Move($stampPath, $consumedPath)
  } catch {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'consume-rename-failed'; path = $stampPath; consumed_path = $consumedPath; error = $_.Exception.Message }
  }

  $stamp = $null
  try {
    $raw = [System.IO.File]::ReadAllText($consumedPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty stamp' }
    $stamp = $raw | ConvertFrom-Json
  } catch {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'corrupt-json'; path = $stampPath; consumed_path = $consumedPath; error = $_.Exception.Message }
  }

  $stampTaskId = ''
  try { if ($stamp.PSObject.Properties.Name -contains 'task_id') { $stampTaskId = [string]$stamp.task_id } } catch {}
  if ($stampTaskId -ne [string]$TaskId) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'task-id-mismatch'; path = $stampPath; consumed_path = $consumedPath; expected = [string]$TaskId; actual = $stampTaskId }
  }

  $created = [DateTimeOffset]::MinValue
  $createdText = ''
  try { if ($stamp.PSObject.Properties.Name -contains 'created_at_utc') { $createdText = [string]$stamp.created_at_utc } } catch {}
  if (-not [DateTimeOffset]::TryParse($createdText, [ref]$created)) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'bad-created-at'; path = $stampPath; consumed_path = $consumedPath }
  }

  $ttl = 90
  try { if ($stamp.PSObject.Properties.Name -contains 'ttl_minutes') { $ttl = [int]$stamp.ttl_minutes } } catch { $ttl = 90 }
  if ($ttl -le 0) { $ttl = 90 }
  if ($created.ToUniversalTime().AddMinutes($ttl) -lt $NowUtc.ToUniversalTime()) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'expired'; path = $stampPath; consumed_path = $consumedPath; created_at_utc = $created.ToUniversalTime().ToString('o'); ttl_minutes = $ttl }
  }

  $touched = @()
  try {
    if ($stamp.PSObject.Properties.Name -contains 'evidence' -and $stamp.evidence -and ($stamp.evidence.PSObject.Properties.Name -contains 'touched')) {
      $touched = @($stamp.evidence.touched | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  } catch { $touched = @() }
  if (@($touched | Where-Object { $_ -match '(?i)\.ps1$' }).Count -lt 1) {
    return [pscustomobject][ordered]@{ ok = $false; reason = 'missing-ps1-evidence'; path = $stampPath; consumed_path = $consumedPath; touched = @($touched) }
  }

  return [pscustomobject][ordered]@{
    ok            = $true
    reason        = 'consumed'
    path          = $stampPath
    consumed_path = $consumedPath
    task_id       = $stampTaskId
    touched       = @($touched)
  }
}


function Save-Decision {
  # Durable, uncompressed record of a conclusion/decision. Returns the file path.
  param([string]$Title, [string]$Content)
  $dir = Get-DecisionsPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $slug = ([string]$Title).ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+','-'
  $slug = $slug.Trim('-'); if ($slug.Length -gt 50) { $slug = $slug.Substring(0,50) }
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'note' }
  $name = (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + $slug + '.md'
  $path = Join-Path $dir $name
  $body = "# $Title`n`n_Сохранено: $(Get-Date -Format 'yyyy-MM-dd HH:mm')_`n`n" + [string]$Content + "`n"
  Write-AtomicFile -Path $path -Content $body
  return $path
}


function Restore-StateFromBackup {
  # Recover state.json from the write-through backup (.bak file).
  # Uses raw helpers only — does NOT call Read-State or Write-State (no recursion).
  # Returns restored PSObject on success; $null if backup is missing, invalid, or restore write failed.
  $statePath  = Get-StatePath
  $backupPath = $statePath + '.bak'
  $bak = Read-StateJsonRawValidated -Path $backupPath
  if ($null -eq $bak) { return $null }
  $check = Test-StateShape -State $bak
  if (-not $check.ok) {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BACKUP-INVALID shape-fail: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    return $null
  }
  try {
    $json = $bak | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $statePath -Content $json
  } catch { return $null }
  return $bak
}

function Read-State {
  # FIX 2026-05-27: shape-guard — broken state forces Initialize-Bridge recreate.
  # FIX 2026-05-30: 3×50ms retry-backoff on transient parse-fail before returning $null;
  #   on real corruption quarantines bytes + tries Restore-StateFromBackup before defaults.
  #   Protects all ~40 call-sites, not only driver:3178.
  $p = Get-StatePath
  if (-not (Test-Path $p)) { return $null }
  $state = $null
  $maxRetry = 3; $retryMs = 50
  for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
    try {
      $state = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
      break
    } catch {
      if ($attempt -lt $maxRetry) {
        Start-Sleep -Milliseconds $retryMs
      } else {
        # All retries exhausted: quarantine corrupt bytes for forensics, then try backup
        try {
          $qDir = Join-Path (Get-BridgeRoot) 'control\quarantine'
          if (-not (Test-Path -LiteralPath $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
          $qFile = Join-Path $qDir ("state-corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
          Copy-Item -LiteralPath $p -Destination $qFile -Force -ErrorAction SilentlyContinue
          $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
          Add-Content -LiteralPath $alog -Value ("{0}  PARSE-FAIL quarantined to $qFile — trying backup" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding utf8 -ErrorAction SilentlyContinue
        } catch {}
        $restored = Restore-StateFromBackup
        if ($null -ne $restored) { return $restored }
        return $null  # degrade: Initialize-Bridge defaults (same as current behaviour)
      }
    }
  }
  if ($null -eq $state) { return $null }
  $check = Test-StateShape -State $state
  if (-not $check.ok) {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BROKEN-DETECTED {1} — trying backup before defaults" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    $restored = Restore-StateFromBackup
    if ($null -ne $restored) { return $restored }
    return $null
  }
  return $state
}

function Test-StateShape {
  # Verify a state object has the minimum critical fields. Used as gate by Write-State to
  # reject partial/replacement-style writes that would wipe runtime state.
  # FIX 2026-05-27: yesterday a Codex-experimental script wrote @{parallel_streams=@()} as
  # FULL state replacement -- nuked status/lastSeq/heartbeat/current_task. Driver couldn't
  # boot. State.json now only accepts writes that PRESERVE these critical fields.
  param($State)
  if ($null -eq $State) { return @{ ok=$false; reason='null state' } }
  $required = @('status','lastSeq','paused','stop','abort','heartbeat')
  $missing = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in $required) {
    $has = $false
    try { $has = ($State.PSObject.Properties.Name -contains $f) } catch {}
    if (-not $has) { [void]$missing.Add($f) }
  }
  if ($missing.Count -gt 0) {
    return @{ ok=$false; reason=('missing critical fields: ' + ($missing -join ',')) }
  }
  return @{ ok=$true; reason='' }
}

function Write-State {
  param($State, [switch]$AllowPartial)
  # FIX 2026-05-27: guard against state-wipe. Reject writes that lack minimum runtime fields,
  # UNLESS explicit -AllowPartial (only Initialize-Bridge default-create branch uses this).
  if (-not $AllowPartial) {
    $check = Test-StateShape -State $State
    if (-not $check.ok) {
      $msg = "Write-State refused: $($check.reason). Use Update-State+Add-Member for mutations; only Initialize-Bridge -Reset may use -AllowPartial."
      try {
        $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
        Add-Content -LiteralPath $alog -Value ("{0}  REFUSED {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
      } catch {}
      throw $msg
    }
  }
  $json = $State | ConvertTo-Json -Depth 10
  $sp = Get-StatePath
  Write-AtomicFile -Path $sp -Content $json
  # Write-through backup (best-effort: fail = warning only, not rollback of the main write).
  # M1 (load audit): throttle the .bak to ~10s. It used to be written on EVERY state write -- but
  # heartbeat ticks (~every 5s x N drivers) dominate, doubling the work done INSIDE the bridge lock
  # and feeding the 15s-timeout contention under load. The live state.json is always current; the
  # crash backup only needs to be RECENT, so skip it when a fresh .bak already exists.
  try {
    $bakPath = $sp + '.bak'
    $bakFresh = $false
    if (Test-Path -LiteralPath $bakPath) {
      try { $bakFresh = (((Get-Date) - (Get-Item -LiteralPath $bakPath).LastWriteTime).TotalSeconds -lt 10) } catch {}
    }
    if (-not $bakFresh) { Write-AtomicFile -Path $bakPath -Content $json }
  } catch {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BACKUP-WARN write failed: $($_.Exception.Message)" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    # Do NOT rethrow — main write succeeded; backup is best-effort
  }
}

# A named mutex serializes appends + seq increment across the server and driver processes.
function Use-BridgeLock {
  param(
    [scriptblock]$Body,
    [int]$SlowThresholdMs = 5000,
    [string]$MutexName = 'Global\ClaudeCodexBridgeLock',
    [int]$TimeoutMs = 15000
  )
  $mutex = New-Object System.Threading.Mutex($false, $MutexName)
  $got = $false
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    # FIX 2026-05-27: handle AbandonedMutexException. When the previous holder PROCESS died
    # without releasing the mutex, WaitOne THROWS AbandonedMutexException -- but the lock
    # IS acquired by this thread (.NET semantics: the exception is a WARNING that previous
    # state may be corrupt, not a failure). Before this fix, $got stayed $false, the
    # finally block skipped ReleaseMutex, and the mutex remained abandoned for the NEXT
    # caller too -- chain of silent Update-State failures. Observed overnight: Auditor's
    # pause action failed 52 consecutive times exactly via this path, never landing.
    try {
      $got = $mutex.WaitOne($TimeoutMs)
    } catch [System.Threading.AbandonedMutexException] {
      $got = $true   # we DO own the mutex; release in finally as usual
      try {
        $alog = Join-Path (Get-BridgeRoot) 'control\bridge-lock.log'
        Add-Content -LiteralPath $alog -Value ("{0}  abandoned mutex recovered by PID {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID) -Encoding utf8 -ErrorAction SilentlyContinue
      } catch {}
    }
    $elapsedMs = [int64]$sw.ElapsedMilliseconds
    if ($elapsedMs -ge $SlowThresholdMs) {
      try {
        $alog = Join-Path (Get-BridgeRoot) 'control\bridge-lock.log'
        Add-Content -LiteralPath $alog -Value ("{0}  slow_lock elapsed_ms={1} pid={2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $elapsedMs, $PID) -Encoding utf8 -ErrorAction SilentlyContinue
      } catch {}
    }
    if (-not $got) { throw ("bridge-lock-timeout-uncertain: could not acquire within {0}s (elapsed_ms={1}); caller must re-read state before retry" -f ([math]::Round($TimeoutMs / 1000, 3)), $elapsedMs) }
    & $Body
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Test-BridgeLockUncertainTimeout {
  param([System.Exception]$Err)
  if ($null -eq $Err) { return $false }
  return ($Err.Message -like '*bridge-lock-timeout-uncertain*')
}

function Invoke-BridgeMutationWithReRead {
  param(
    [scriptblock]$MutationBody,
    [scriptblock]$ReReadBody,
    [int]$SlowThresholdMs = 5000
  )
  try {
    Use-BridgeLock -Body $MutationBody -SlowThresholdMs $SlowThresholdMs
    return [pscustomobject][ordered]@{
      success = $true
      uncertain = $false
      retried = $false
    }
  } catch {
    if (-not (Test-BridgeLockUncertainTimeout -Err $_.Exception)) {
      throw
    }
  }

  $reReadResult = $null
  if ($null -ne $ReReadBody) { $reReadResult = & $ReReadBody }
  return [pscustomobject][ordered]@{
    success = $false
    uncertain = $true
    retried = $false
    reread_result = $reReadResult
  }
}

function Get-RuntimeStateMetrics {
  $root = Get-BridgeRoot
  $runtime = Get-RuntimeRoot
  $channelNames = @{}
  foreach ($base in @((Join-Path $root 'channels'), (Join-Path $runtime 'channels'))) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    try {
      Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | ForEach-Object {
        $channelNames[[string]$_.Name] = $true
      }
    } catch {}
  }

  $statePaths = @{}
  foreach ($candidate in @((Join-Path $root 'state.json'), (Join-Path $runtime 'state.json'))) {
    if (Test-Path -LiteralPath $candidate) { $statePaths[[string](Resolve-Path -LiteralPath $candidate)] = $true }
  }
  foreach ($base in @((Join-Path $root 'channels'), (Join-Path $runtime 'channels'))) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    try {
      Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | ForEach-Object {
        $sp = Join-Path $_.FullName 'state.json'
        if (Test-Path -LiteralPath $sp) { $statePaths[[string](Resolve-Path -LiteralPath $sp)] = $true }
      }
    } catch {}
  }

  $stateBytes = [long]0
  foreach ($p in $statePaths.Keys) {
    try { $stateBytes += [long](Get-Item -LiteralPath $p -ErrorAction Stop).Length } catch {}
  }

  $locks = 0
  try {
    if (Test-Path -LiteralPath $runtime) {
      $locks = @((Get-ChildItem -LiteralPath $runtime -Recurse -Filter '*.lock' -File -ErrorAction SilentlyContinue)).Count
    }
  } catch { $locks = 0 }

  $jobs = 0
  $jobsDir = Join-Path $runtime 'jobs'
  try {
    if (Test-Path -LiteralPath $jobsDir) {
      $jobs = @((Get-ChildItem -LiteralPath $jobsDir -Recurse -File -ErrorAction SilentlyContinue)).Count
    }
  } catch { $jobs = 0 }

  $restartsHour = 0
  $restartsPath = Join-Path $runtime 'restarts.jsonl'
  if (Test-Path -LiteralPath $restartsPath) {
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-1)
    try {
      foreach ($line in [System.IO.File]::ReadLines($restartsPath)) {
        $s = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        try {
          $e = $s | ConvertFrom-Json
          if ($e -and $e.ts) {
            $ts = [DateTimeOffset]::Parse([string]$e.ts)
            if ($ts.UtcDateTime -ge $cutoff.UtcDateTime) { $restartsHour++ }
          }
        } catch {}
      }
    } catch {}
  }

  return [pscustomobject]@{
    channels     = [int]$channelNames.Count
    stateKb      = [int][Math]::Ceiling([double]$stateBytes / 1024.0)
    locks        = [int]$locks
    jobs         = [int]$jobs
    restartsHour = [int]$restartsHour
  }
}

function Get-ProbeTimeoutDefaults {
  return [pscustomobject]@{
    minMs   = 120000
    baseMs  = 180000
    maxMs   = 900000
    metrics = [pscustomobject]@{
      channels     = [pscustomobject]@{ weight = 10000; capMs = 90000 }
      stateKb      = [pscustomobject]@{ weight = 120;   capMs = 180000 }
      locks        = [pscustomobject]@{ weight = 15000; capMs = 120000 }
      jobs         = [pscustomobject]@{ weight = 5000;  capMs = 180000 }
      restartsHour = [pscustomobject]@{ weight = 45000; capMs = 270000 }
    }
  }
}

function Get-ConfigIntValue {
  param($Object, [string]$Name, [int]$Default)
  try {
    if ($Object -and ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name) {
      $v = [int]$Object.$Name
      if ($v -ge 0) { return $v }
    }
  } catch {}
  return $Default
}

function Get-AdaptiveProbeTimeoutMs {
  param($Metrics = $null, [int]$CoderTimeoutMs = 0, $ProbeTimeoutConfig = $null)
  if ($null -eq $Metrics) { $Metrics = Get-RuntimeStateMetrics }

  $defaults = Get-ProbeTimeoutDefaults
  $cfg = $null
  try { $cfg = Get-BridgeConfig } catch {}
  $pt = $ProbeTimeoutConfig
  if ($null -eq $pt -and $cfg -and ($cfg.PSObject.Properties.Name -contains 'probeTimeout')) { $pt = $cfg.probeTimeout }

  $minMs = Get-ConfigIntValue -Object $pt -Name 'minMs' -Default ([int]$defaults.minMs)
  $baseMs = Get-ConfigIntValue -Object $pt -Name 'baseMs' -Default ([int]$defaults.baseMs)
  $maxMs = Get-ConfigIntValue -Object $pt -Name 'maxMs' -Default ([int]$defaults.maxMs)

  if ($CoderTimeoutMs -le 0) {
    $CoderTimeoutMs = Get-ConfigIntValue -Object $cfg -Name 'coderTimeoutMs' -Default 900000
  }
  if ($CoderTimeoutMs -gt 0) { $maxMs = [Math]::Min($maxMs, $CoderTimeoutMs) }
  if ($maxMs -lt 1) { $maxMs = [int]$defaults.maxMs }
  if ($minMs -lt 1) { $minMs = [int]$defaults.minMs }
  if ($minMs -gt $maxMs) { $minMs = $maxMs }
  if ($baseMs -lt 0) { $baseMs = [int]$defaults.baseMs }

  $score = [double]$baseMs
  $metricCfg = $null
  if ($pt -and ($pt.PSObject.Properties.Name -contains 'metrics')) { $metricCfg = $pt.metrics }
  foreach ($name in @('channels','stateKb','locks','jobs','restartsHour')) {
    $def = $defaults.metrics.$name
    $mc = $null
    if ($metricCfg -and ($metricCfg.PSObject.Properties.Name -contains $name)) { $mc = $metricCfg.$name }
    $weight = Get-ConfigIntValue -Object $mc -Name 'weight' -Default ([int]$def.weight)
    $capMs = Get-ConfigIntValue -Object $mc -Name 'capMs' -Default ([int]$def.capMs)
    $value = 0
    try {
      if ($Metrics -and ($Metrics.PSObject.Properties.Name -contains $name) -and $null -ne $Metrics.$name) {
        $value = [double]$Metrics.$name
      }
    } catch { $value = 0 }
    if ($value -lt 0) { $value = 0 }
    $score += [Math]::Min(([double]$weight * $value), [double]$capMs)
  }

  $clamped = [Math]::Max([double]$minMs, [Math]::Min($score, [double]$maxMs))
  return [int][Math]::Round($clamped)
}

function Test-IsProbeTask {
  param([string]$Prompt = '', [string]$Command = '', [string[]]$Tags = @())
  foreach ($tag in @($Tags)) {
    $t = ([string]$tag).Trim().ToLowerInvariant()
    if ($t -eq 'probe' -or $t -eq 'diag') { return $true }
  }

  $promptScope = [string]$Prompt
  try {
    $m = [regex]::Match(
      $promptScope,
      '(?s)(?:ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:|ЗАДАЧА ОТ ОПЕРАТОРА:)\s*(.*?)(?:\r?\n(?:ОБЛАСТЬ|РОЛИ:|ПРАВИЛА:|ДИАЛОГ:|===|ПЛАН ЗАДАЧИ:)|\z)'
    )
    if ($m.Success) { $promptScope = [string]$m.Groups[1].Value }
  } catch {}

  $hay = ($promptScope + "`n" + ([string]$Command)).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($hay)) { return $false }
  if ($hay -match '(?i)(^|[^\p{L}\p{N}_-])probe(?:\s+|[-‑–—])(?:task|tasks|job|jobs|задач|провер|диаг|diag|health)\b') { return $true }
  if ($hay -match '(?i)\bproof-probe\b') { return $true }
  if ($hay -match '(?i)tools[\\/]+diag[\\/]+[^\s''"]*-probe\.ps1\b') { return $true }
  if (-not [string]::IsNullOrWhiteSpace($Command) -and ([string]$Command).ToLowerInvariant() -match '(?i)(^|[\\/])[^\\/]*-probe\.ps1\b') { return $true }
  return $false
}

function Write-ProbeDuration {
  param(
    [int]$ComputedTimeoutMs,
    [int]$ActualDurationMs,
    $Metrics,
    [string]$Exit = 'unknown',
    [string]$Verdict = ''
  )
  $runtime = Get-RuntimeRoot
  if (-not (Test-Path -LiteralPath $runtime)) { New-Item -ItemType Directory -Path $runtime -Force | Out-Null }
  $path = Join-Path $runtime 'probe-durations.jsonl'
  $rec = [pscustomobject]@{
    ts                  = (Get-Date).ToUniversalTime().ToString('o')
    computed_timeout_ms = [int]$ComputedTimeoutMs
    actual_duration_ms  = [int]$ActualDurationMs
    metrics             = $Metrics
    exit                = [string]$Exit
    verdict             = [string]$Verdict
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 8)
  Use-BridgeLock {
    try {
      [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      $old = ''
      if (Test-Path -LiteralPath $path) {
        try { $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { $old = '' }
      }
      if (-not [string]::IsNullOrEmpty($old) -and -not $old.EndsWith("`n")) { $old += "`n" }
      Write-AtomicFile -Path $path -Content ($old + $line + "`n")
    }
  }
}

function Update-State {
  # Mutate state safely under the shared lock. $Mutator receives the state object and modifies it.
  param([scriptblock]$Mutator)
  Use-BridgeLock {
    $state = Read-State
    if ($null -eq $state) { throw 'state.json missing; run init first' }
    & $Mutator $state
    Write-State -State $state
    return $state
  }
}

function Update-TaskPhaseTiming {
  param([string]$Phase, [long]$Ms)
  if ($Ms -le 0 -or [string]::IsNullOrWhiteSpace($Phase)) { return }
  $keyCapture = "task_timing_${Phase}"
  $msCapture  = [long]$Ms
  try {
    Update-State ({
      param($s)
      $cur = 0L
      if ($s.PSObject.Properties.Name -contains $keyCapture) {
        try { $cur = [long]($s.$keyCapture) } catch { $cur = 0L }
      }
      $s | Add-Member -NotePropertyName $keyCapture -NotePropertyValue ($cur + $msCapture) -Force
      if ([string]::IsNullOrWhiteSpace([string]$s.task_timing_start_at)) {
        $s | Add-Member -NotePropertyName 'task_timing_start_at' -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
      }
    }.GetNewClosure())
  } catch {}
}

function Clear-AuditorSuppressedHashes {
  param($State)
  if (-not $State) { return }
  $node = $null
  try {
    if ($State -is [System.Collections.IDictionary]) {
      if (-not $State.Contains('auditor') -or $null -eq $State['auditor']) {
        $State['auditor'] = [ordered]@{ suppressed_hashes = @() }
        return
      }
      $node = $State['auditor']
    } else {
      if (-not ($State.PSObject.Properties.Name -contains 'auditor') -or $null -eq $State.auditor) {
        $State | Add-Member -NotePropertyName auditor -NotePropertyValue ([ordered]@{ suppressed_hashes = @() }) -Force
        return
      }
      $node = $State.auditor
    }

    if ($node -is [System.Collections.IDictionary]) {
      $node['suppressed_hashes'] = @()
    } else {
      if ($node.PSObject.Properties.Name -contains 'suppressed_hashes') {
        $node.suppressed_hashes = @()
      } else {
        $node | Add-Member -NotePropertyName suppressed_hashes -NotePropertyValue @() -Force
      }
    }
  } catch {}
}

function Set-TaskLastFailure {
  param(
    [Parameter(Mandatory)]
    [ValidateSet(
      'action_evidence_error',
      'bridge_guard',
      'critic_rejected',
      'doctor_timeout',
      'gate_regression_failed',
      'gate_regression_runtime_error',
      'no_action_evidence',
      'preflight_blocked',
      'qa_failed',
      'smoke_failed',
      'test_failed'
    )]
    [string]$Kind,
    [Parameter(Mandatory)][string]$Text
  )

  $cleanText = ([string]$Text -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($cleanText)) { return }
  if ($cleanText.Length -gt 300) { $cleanText = $cleanText.Substring(0, 300) + '...' }
  $ts = (Get-Date).ToString('o')
  Update-State ({
    param($s)
    $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue ([pscustomobject]@{
      kind = $Kind
      text = $cleanText
      ts   = $ts
    }) -Force
  }.GetNewClosure()) | Out-Null
}

function Clear-TaskLastFailureKind {
  param([string]$Kind = '')
  Update-State ({
    param($s)
    if (-not ($s.PSObject.Properties.Name -contains 'task_last_failure') -or $null -eq $s.task_last_failure) { return }
    if ([string]::IsNullOrWhiteSpace($Kind)) {
      $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue $null -Force
      return
    }
    $curKind = ''
    try { $curKind = [string]$s.task_last_failure.kind } catch { $curKind = '' }
    if ($curKind -eq [string]$Kind) {
      $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue $null -Force
    }
  }.GetNewClosure()) | Out-Null
}

function Add-SessionDecisionEvent {
  param(
    [string]$EventType,
    [hashtable]$Meta = @{},
    [string]$Channel = ''
  )
  try {
    if (@('task_start','convergence','verified_commit','doctor_fix','post_mortem') -notcontains $EventType) { return }
    $ch = $Channel
    if ([string]::IsNullOrWhiteSpace($ch)) {
      $s = Read-State -ErrorAction SilentlyContinue
      if ($s -and $s.current_channel) { $ch = [string]$s.current_channel } else { $ch = 'main' }
    }
    $dir = Get-DecisionsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ledger = Join-Path $dir 'session-ledger.jsonl'
    $entry = [ordered]@{ ts=(Get-Date).ToString('o'); event=$EventType; channel=$ch }
    if ($Meta) {
      foreach ($k in $Meta.Keys) { $entry[$k] = $Meta[$k] }
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($ledger, ($line + [Environment]::NewLine), $u8NoBom)
  } catch {}
}

function Get-SessionLedgerBlock {
  param([string]$Channel='main', [int]$LastN=5)
  try {
    if ($LastN -le 0) { return '' }
    $ledger = Join-Path (Get-DecisionsPath) 'session-ledger.jsonl'
    if (-not (Test-Path $ledger)) { return '' }
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    $all = [System.IO.File]::ReadAllLines($ledger, $u8NoBom)
    if (-not $all -or $all.Count -eq 0) { return '' }
    $items = @()
    foreach ($rawLine in ($all | Select-Object -Last ([Math]::Max($LastN * 4, 1)))) {
      try {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -gt 0 -and [int][char]$line[0] -eq 0xFEFF) { $line = $line.Substring(1) }
        $e = $line | ConvertFrom-Json
        if ($e.PSObject.Properties.Name -contains 'channel' -and -not [string]::IsNullOrWhiteSpace([string]$Channel) -and [string]$e.channel -ne [string]$Channel) { continue }
        $taskText = if ($e.PSObject.Properties.Name -contains 'task' -and $null -ne $e.task) { [string]$e.task } else { '' }
        $suffix = if ($taskText.Length -gt 0) { ': ' + $taskText.Substring(0,[Math]::Min(60,$taskText.Length)) } else { '' }
        $tsText = if ($e.PSObject.Properties.Name -contains 'ts' -and $null -ne $e.ts) { [string]$e.ts } else { '' }
        $tsShort = if ($tsText.Length -gt 16) { $tsText.Substring(0,16) } else { $tsText }
        $items += "$($e.event) @ $tsShort$suffix"
      } catch { $items += [string]$line }
    }
    $items = @($items | Select-Object -Last $LastN)
    if (-not $items -or $items.Count -eq 0) { return '' }
    return ($items -join ' | ')
  } catch { return '' }
}

function Save-StateSnapshot {
  param([string]$Reason = 'risky', [string]$Channel = '')
  try {
    $ch = $Channel
    $s = $null
    if (-not [string]::IsNullOrWhiteSpace($ch)) {
      $statePath = Join-Path (Get-BridgeRoot) "channels\$ch\state.json"
      if (Test-Path -LiteralPath $statePath) {
        try { $s = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
      }
    }
    if ($null -eq $s) { $s = Read-State -ErrorAction SilentlyContinue }
    if ($null -eq $s) { return $null }
    if ([string]::IsNullOrWhiteSpace($ch)) {
      if ($s.current_channel) { $ch = [string]$s.current_channel } else { $ch = 'main' }
    }
    $taskId = ''
    if ($s.PSObject.Properties.Name -contains 'task_id') { $taskId = [string]$s.task_id }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'current_backlog_id') { $taskId = [string]$s.current_backlog_id }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'task_start_seq') {
      $seq = [string]$s.task_start_seq
      if (-not [string]::IsNullOrWhiteSpace($seq) -and $seq -ne '0') { $taskId = "seq:${ch}:$seq" }
    }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'current_task') {
      $taskText = [string]$s.current_task
      if (-not [string]::IsNullOrWhiteSpace($taskText)) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
          $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($taskText))
          $taskId = "task:${ch}:" + (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0,12)
        } finally {
          try { $sha.Dispose() } catch {}
        }
      }
    }
    try {
      $s | Add-Member -NotePropertyName 'snapshot_meta' -NotePropertyValue ([ordered]@{
        ts      = (Get-Date).ToString('o')
        reason  = $Reason
        channel = $ch
        task_id = $taskId
      }) -Force
    } catch {}
    $dir = Join-Path (Get-BridgeRoot) "channels\$ch\snapshots"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Dedup: skip if a recent snapshot with the same Reason already exists
    try {
      $dedupMin = 15
      try { $cfg2 = Get-BridgeConfig; if ($cfg2.PSObject.Properties.Name -contains 'snapshotDedupMinutes') { $dedupMin = [int]$cfg2.snapshotDedupMinutes } } catch {}
      $cutoff = (Get-Date).AddMinutes(-[Math]::Max(1, $dedupMin))
      $recent = Get-ChildItem $dir -Filter "state.*.$Reason.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($recent -and $recent.LastWriteTime -ge $cutoff) { return $recent.FullName }
    } catch {}
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $snapPath = Join-Path $dir "state.${ts}.${Reason}.json"
    $json = $s | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($snapPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $all = Get-ChildItem $dir -Filter 'state.*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($all -and $all.Count -gt 10) { $all | Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue }
    return $snapPath
  } catch { return $null }
}

function Get-LastSnapshot {
  param([string]$Channel = 'main')
  try {
    $dir = Join-Path (Get-BridgeRoot) "channels\$Channel\snapshots"
    if (-not (Test-Path $dir)) { return $null }
    $snap = Get-ChildItem $dir -Filter 'state.*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($snap) { return $snap.FullName } else { return $null }
  } catch { return $null }
}

function Get-CoderRuntimeContextBlock {
  [CmdletBinding()]
  param([string]$RepoRoot = '')

  $bridgeRoot = Get-BridgeRoot
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    try {
      if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        $RepoRoot = [string](Get-EffectiveProjectRoot)
      }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $bridgeRoot }
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('=== RUNTIME CONTEXT (только чтение, для ориентации) ===')
  [void]$lines.Add("repo: $RepoRoot")

  $st = $null
  try {
    $st = Read-State
    $ch = ''
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $ch = [string](Get-EffectiveChannel) }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($ch)) { $ch = if ($st.current_channel) { [string]$st.current_channel } else { 'main' } }
    [void]$lines.Add("channel: $ch")
  } catch {
    [void]$lines.Add('channel: n/a')
  }

  try {
    $sha = (& git -C $RepoRoot log -1 --format='%h' 2>$null).Trim()
    $sub = (& git -C $RepoRoot log -1 --format='%s' 2>$null).Trim()
    if ($sha) {
      if ($sub.Length -gt 80) { $sub = $sub.Substring(0, 80) + '…' }
      [void]$lines.Add("last_commit: $sha $sub")
    } else {
      [void]$lines.Add('last_commit: n/a')
    }
  } catch {
    [void]$lines.Add('last_commit: n/a')
  }

  try {
    $dirty = @(& git -C $RepoRoot status --short 2>$null) | Where-Object {
      $_ -and ($_ -notmatch '(secrets\.json|\.env|auth\.json)')
    }
    if ($dirty.Count -eq 0) {
      [void]$lines.Add('dirty: clean')
    } else {
      $first3 = ($dirty | Select-Object -First 3) -join '; '
      $extra = if ($dirty.Count -gt 3) { " (+$($dirty.Count - 3) more)" } else { '' }
      [void]$lines.Add("dirty: $($dirty.Count) files | $first3$extra")
    }
  } catch {
    [void]$lines.Add('dirty: n/a')
  }

  try {
    $lockPath = Join-Path $bridgeRoot 'runtime\codex.lock'
    if (Test-Path $lockPath) {
      $lockInfo = (Get-Content $lockPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim()
      if ($lockInfo) {
        if ($lockInfo.Length -gt 80) { $lockInfo = $lockInfo.Substring(0, 80) + '…' }
        [void]$lines.Add("agent_lock: HELD | $lockInfo")
      } else {
        [void]$lines.Add('agent_lock: HELD (no owner info)')
      }
    } else {
      [void]$lines.Add('agent_lock: free')
    }
  } catch {
    [void]$lines.Add('agent_lock: n/a')
  }

  try {
    if ($st -and $st.task_last_failure) {
      $f = $st.task_last_failure
      $failOne = $null
      if ($f -is [string]) {
        $failOne = $f
      } else {
        foreach ($k in @('reason', 'message', 'type', 'text')) {
          if ($f.PSObject.Properties[$k] -and $f.$k) {
            $failOne = [string]$f.$k
            break
          }
        }
        if (-not $failOne) {
          try { $failOne = ($f | ConvertTo-Json -Compress -Depth 3) } catch { $failOne = '' }
        }
      }
      $failOne = ($failOne -replace '\s+', ' ').Trim()
      if ($failOne.Length -gt 100) { $failOne = $failOne.Substring(0, 100) + '…' }
      if ($failOne) {
        [void]$lines.Add("last_failure: $failOne")
      } else {
        [void]$lines.Add('last_failure: none')
      }
    } else {
      [void]$lines.Add('last_failure: none')
    }
  } catch {
    [void]$lines.Add('last_failure: n/a')
  }

  # current_decisions: last events from session ledger
  try {
    $_ch = if ($st -and $st.current_channel) { [string]$st.current_channel } else { 'main' }
    $_decBlock = Get-SessionLedgerBlock -Channel $_ch -LastN 5
    if (-not [string]::IsNullOrWhiteSpace($_decBlock)) {
      [void]$lines.Add('')
      [void]$lines.Add('## current_decisions')
      [void]$lines.Add($_decBlock)
    }
  } catch {}

  [void]$lines.Add('=== END RUNTIME CONTEXT ===')
  return ($lines -join "`n")
}

function Get-OtherChannelsAgentsImpl {
  # Returns @{channelSlug = 'claude'|'codex'} for channels other than the current one
  # whose state.current_agent points to a live driver process. PID start ticks protect
  # against PID reuse; entries older than the agent timeout are treated as stale.
  $result = @{}
  try {
    $currentChannel = ''
    try { $currentChannel = [string]$Channel } catch {}
    if ([string]::IsNullOrWhiteSpace($currentChannel)) {
      try { $currentChannel = [string](Get-EffectiveChannel) } catch {}
    }

    $channelsRoot = Join-Path (Get-BridgeRoot) 'channels'
    if (-not (Test-Path -LiteralPath $channelsRoot)) { return $result }

    foreach ($dir in @(Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue)) {
      $slug = [string]$dir.Name
      if (-not [string]::IsNullOrWhiteSpace($currentChannel) -and $slug -eq $currentChannel) { continue }

      $stateF = Join-Path $dir.FullName 'state.json'
      if (-not (Test-Path -LiteralPath $stateF)) { continue }

      try {
        $st = Get-Content -LiteralPath $stateF -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $agent = ([string]$st.current_agent).ToLowerInvariant()
        if ($agent -ne 'claude' -and $agent -ne 'codex') { continue }

        $apid = 0
        try { $apid = [int]$st.current_agent_pid } catch { $apid = 0 }
        $aTicks = [long]0
        try { $aTicks = [long]$st.current_agent_ticks } catch { $aTicks = [long]0 }
        $aSince = $null
        try {
          $sinceRaw = [string]$st.current_agent_since
          if (-not [string]::IsNullOrWhiteSpace($sinceRaw)) { $aSince = [datetime]$sinceRaw }
        } catch { $aSince = $null }

        $live = $false
        if ($apid -gt 0 -and $aTicks -gt 0 -and $aSince) {
          $ageSec = [math]::Max(0, [int](((Get-Date) - $aSince).TotalSeconds))
          if ($ageSec -le 920) {
            $proc = Get-Process -Id $apid -ErrorAction SilentlyContinue
            if ($proc) {
              try {
                if ($proc.StartTime.Ticks -eq $aTicks) { $live = $true }
              } catch {
                $live = $false
              }
            }
          }
        }

        if ($live) { $result[$slug] = $agent }
      } catch {
        continue
      }
    }
  } catch {}
  return $result
}

function Set-CurrentAgentImpl {
  param([string]$Agent)
  # Mark this channel's driver as running the given agent so parallel channel drivers can
  # route around a busy Claude/Codex pair. Cleared in each Invoke-* finally block.
  try {
    if ([string]::IsNullOrWhiteSpace($Agent)) {
      Update-State {
        param($s)
        $s | Add-Member -NotePropertyName current_agent -NotePropertyValue $null -Force
        $s | Add-Member -NotePropertyName current_agent_pid -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName current_agent_ticks -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName current_agent_since -NotePropertyValue $null -Force
      } | Out-Null
      return
    }

    $normAgent = ([string]$Agent).ToLowerInvariant()
    if ($normAgent -ne 'claude' -and $normAgent -ne 'codex') { return }

    $pidValue = [int]$PID
    $ticks = [long]0
    try { $ticks = (Get-Process -Id $pidValue -ErrorAction Stop).StartTime.Ticks } catch { $ticks = [long]0 }
    $nowIso = (Get-Date).ToString('o')
    Update-State ({
      param($s)
      $s | Add-Member -NotePropertyName current_agent -NotePropertyValue $normAgent -Force
      $s | Add-Member -NotePropertyName current_agent_pid -NotePropertyValue $pidValue -Force
      $s | Add-Member -NotePropertyName current_agent_ticks -NotePropertyValue $ticks -Force
      $s | Add-Member -NotePropertyName current_agent_since -NotePropertyValue $nowIso -Force
    }.GetNewClosure()) | Out-Null
  } catch {}
}

function Get-OtherChannelsAgents { Get-OtherChannelsAgentsImpl }
function Set-CurrentAgent {
  param([string]$Agent)
  Set-CurrentAgentImpl -Agent $Agent
}

function Get-PreflightBlockers {
  param([string]$Channel = '', [string]$ProjectRoot = '')

  $hard = New-Object 'System.Collections.Generic.List[string]'
  $soft = New-Object 'System.Collections.Generic.List[string]'
  $root = Get-BridgeRoot

  if ([string]::IsNullOrWhiteSpace($Channel)) {
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $Channel = [string](Get-EffectiveChannel) }
    } catch {
      [void]$soft.Add("не удалось определить текущий канал: $($_.Exception.Message)")
    }
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $channelSlug = $Channel
  try {
    if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $channelSlug = Normalize-ChannelSlug $Channel }
  } catch {}

  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    try {
      if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
        $binding = Get-ChannelProjectBinding -Slug $channelSlug
        if ($binding -and [bool]$binding.ok) {
          $ProjectRoot = [string]$binding.project_root
        } elseif ($channelSlug -ne 'main') {
          $berr = if ($binding) { [string]$binding.error } else { "Канал '$channelSlug' не привязан к проекту" }
          if ([string]::IsNullOrWhiteSpace($berr)) { $berr = "Канал '$channelSlug' не привязан к проекту" }
          [void]$hard.Add($berr)
        }
      } elseif (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        $ProjectRoot = [string](Get-EffectiveProjectRoot -Slug $channelSlug)
      }
    } catch {
      [void]$soft.Add("не удалось определить проект канала '$channelSlug': $($_.Exception.Message)")
    }
  }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = $root }

  $channelState = $null
  try {
    if (Get-Command Get-ChannelStatePath -ErrorAction SilentlyContinue) {
      $statePath = Get-ChannelStatePath -Slug $Channel
      if (Test-Path -LiteralPath $statePath) {
        $channelState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      }
    }
    if ($null -eq $channelState) { $channelState = Read-State }
  } catch {
    [void]$soft.Add("не удалось прочитать state канала '$Channel': $($_.Exception.Message)")
  }

  # Codex MSIX supports one exec session per machine. Treat only a live, verified lock as hard.
  $lockPath = Join-Path $root 'runtime\codex.lock'
  if (Test-Path -LiteralPath $lockPath) {
    try {
      $raw = ([string](Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 -ErrorAction Stop)).Trim()
      $parts = @($raw -split '\|')
      $lockPid = 0
      $lockTicks = [long]0
      if ($parts.Count -ge 1) { [int]::TryParse($parts[0], [ref]$lockPid) | Out-Null }
      if ($parts.Count -ge 2) { [long]::TryParse($parts[1], [ref]$lockTicks) | Out-Null }

      if ($lockPid -gt 0) {
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
          $sameProcess = $true
          if ($lockTicks -gt 0) {
            try {
              $sameProcess = ($proc.StartTime.Ticks -eq $lockTicks)
            } catch {
              $sameProcess = $false
              [void]$soft.Add("codex.lock PID $lockPid найден, но start-time не проверен: $($_.Exception.Message)")
            }
          }
          if ($sameProcess) {
            $lockAgeSec = 0
            try { $lockAgeSec = [math]::Max(0, [int](((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalSeconds)) } catch { $lockAgeSec = 0 }
            if ($lockAgeSec -le 920) {
              $sameChannelActiveCodex = $false
              try {
                if ($channelState -and ([string]$channelState.current_agent).ToLowerInvariant() -eq 'codex' -and [int]$channelState.current_agent_pid -eq $lockPid) {
                  $sameChannelActiveCodex = $true
                }
              } catch {
                [void]$soft.Add("не удалось сверить codex.lock с current_agent канала '$Channel': $($_.Exception.Message)")
              }
              if (-not $sameChannelActiveCodex) {
                [void]$hard.Add("codex.lock активен (PID $lockPid) - другая coder-сессия в работе")
              }
            } else {
              [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid, age ${lockAgeSec}s)")
            }
          } else {
            [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не совпал по start-time)")
          }
        } else {
          [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не найден)")
        }
      } elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$soft.Add("codex.lock имеет неожиданный формат")
      }
    } catch {
      [void]$soft.Add("не удалось проверить codex.lock: $($_.Exception.Message)")
    }
  }

  try {
    $st = $channelState
    if ($st -and [bool]$st.doctor_active) {
      $curTask = [string]$st.current_task
      $isDoctorTask = ($curTask -match '^\s*🩺\s*ДОКТОР' -or $curTask -match 'ДОКТОР\s+.\s+задача саморемонта моста')
      if (-not $isDoctorTask) {
        [void]$hard.Add("Doctor активен на канале '$Channel'")
      }
    }
  } catch {
    [void]$soft.Add("не удалось проверить Doctor на канале '$Channel': $($_.Exception.Message)")
  }

  $gitDir = Join-Path $ProjectRoot '.git'
  try {
    $gitDirRaw = @(& git -C $ProjectRoot rev-parse --git-dir 2>$null | Select-Object -First 1)
    if ($gitDirRaw -and -not [string]::IsNullOrWhiteSpace([string]$gitDirRaw[0])) {
      $gd = [string]$gitDirRaw[0]
      if ([System.IO.Path]::IsPathRooted($gd)) { $gitDir = $gd } else { $gitDir = Join-Path $ProjectRoot $gd }
    }
  } catch {
    [void]$soft.Add("не удалось определить .git каталог: $($_.Exception.Message)")
  }

  foreach ($m in @('MERGE_HEAD','CHERRY_PICK_HEAD','REBASE_HEAD')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $m)) { [void]$hard.Add("git mid-op: .git/$m") }
  }
  # 2026-06-10: index.lock handled specially. A STALE lock (no live git process, age > 20s) is
  # AUTO-REMOVED instead of hard-blocking. Root: a coder/sandbox git op (CodexSandboxUsers has write
  # on the gitdir) dies leaving index.lock; Get-PreflightBlockers then treated it as a hard blocker,
  # so the driver could not proceed, hung 5 min, the sentinel force-restarted it, it resumed, was
  # still blocked -> a hang/restart loop (observed 5 restarts, 0 throughput). The driver owns the
  # gitdir (FullControl) so it can clear the foreign lock. A FRESH lock (<20s) or one held by a LIVE
  # git process still blocks (a real in-flight commit must not be stomped).
  $idxLock = Join-Path $gitDir 'index.lock'
  if (Test-Path -LiteralPath $idxLock) {
    $idxLiveGit = $false
    try { $idxLiveGit = (@(Get-Process git -ErrorAction SilentlyContinue)).Count -gt 0 } catch { $idxLiveGit = $false }
    $idxAgeSec = 999
    try { $idxAgeSec = ((Get-Date) - (Get-Item -LiteralPath $idxLock -Force).LastWriteTime).TotalSeconds } catch {}
    if ($idxLiveGit -or $idxAgeSec -lt 20) {
      [void]$hard.Add("git mid-op: .git/index.lock")
    } else {
      try { Remove-Item -LiteralPath $idxLock -Force -ErrorAction Stop; [void]$soft.Add("auto-cleared stale .git/index.lock (age $([int]$idxAgeSec)s, no live git)") }
      catch { [void]$hard.Add("git mid-op: .git/index.lock (stale, remove failed: $($_.Exception.Message))") }
    }
  }
  foreach ($d in @('rebase-merge','rebase-apply')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $d) -PathType Container) { [void]$hard.Add("git mid-op: .git/$d/") }
  }

  try {
    $dirty = @(& git -C $ProjectRoot status --porcelain 2>$null)
    $dirtyCount = @($dirty | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    if ($dirtyCount -gt 0) { [void]$soft.Add("worktree dirty: $dirtyCount изменённых/untracked файлов") }
  } catch {
    [void]$soft.Add("не удалось проверить git status: $($_.Exception.Message)")
  }

  return [pscustomobject]@{
    Hard = @($hard.ToArray())
    Soft = @($soft.ToArray())
  }
}

function Is-TestChannel {
  param([Parameter(Mandatory)][string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ($Name -match '[\\/]') { return $false }
  return ($Name -match '^(smoke|test)[-_]')
}

function Get-TestChannelDriverProcessIds {
  param([Parameter(Mandatory)][string]$Name)

  $ids = New-Object 'System.Collections.Generic.List[int]'
  if (-not (Is-TestChannel -Name $Name)) { return @() }
  $pattern = "(?i)(^|\s)-Channel\s+[`"']?" + [regex]::Escape($Name) + "[`"']?(\s|$)"
  try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
      $cmd = [string]$p.CommandLine
      if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
      if ($cmd -notmatch '\\driver\.ps1\b') { continue }
      if ($cmd -match $pattern) { [void]$ids.Add([int]$p.ProcessId) }
    }
  } catch {}
  return @($ids.ToArray())
}

function Set-TestChannelArchivedFlag {
  param([Parameter(Mandatory)][string]$Name)

  if (-not (Is-TestChannel -Name $Name)) { return $false }
  $cfgPath = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Name) 'channel.json'
  try {
    if (Test-Path -LiteralPath $cfgPath) {
      $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
      $cfg = [pscustomobject]@{ slug=$Name; name=$Name }
    }
    $cfg | Add-Member -NotePropertyName archived -NotePropertyValue $true -Force
    $cfg | Add-Member -NotePropertyName archived_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    return $false
  }
}

function Archive-TestChannelIfIdle {
  param(
    [Parameter(Mandatory)][string]$Name,
    [int]$GraceMinutes = 10
  )

  if (-not (Is-TestChannel -Name $Name)) { return $null }
  if ($Name -ne [System.IO.Path]::GetFileName($Name)) { return $null }
  if ($GraceMinutes -lt 0) { $GraceMinutes = 0 }

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  $chDir = Join-Path $chRoot $Name
  if (-not (Test-Path -LiteralPath $chDir -PathType Container)) { return $null }

  $current = ''
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $current = [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace($current) -and $current -eq $Name) { return $null }
  try {
    $active = [string](Get-ActiveChannel)
    if (-not [string]::IsNullOrWhiteSpace($active) -and $active -eq $Name) { return $null }
  } catch {}

  $locks = @(Get-ChildItem -LiteralPath $chDir -Filter '*.lock' -File -ErrorAction SilentlyContinue)
  if ($locks.Count -gt 0) { return $null }

  $statePath = Join-Path $chDir 'state.json'
  if (Test-Path -LiteralPath $statePath) {
    try {
      $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $status = ([string]$st.status).ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notin @('idle','done')) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_task)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.active_agent)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_agent)) { return $null }
      if ([bool]$st.doctor_active) { return $null }
      if ($st.active_jobs -and @($st.active_jobs).Count -gt 0) { return $null }
      if ($st.PSObject.Properties.Name -contains 'task_id') {
        if (-not [string]::IsNullOrWhiteSpace([string]$st.task_id) -and -not [bool]$st.task_archived) { return $null }
      }
    } catch {
      return [pscustomobject]@{ Name=$Name; Archived=$null; Error=("state read failed: " + $_.Exception.Message) }
    }
  }

  $lastTouch = (Get-Date).AddYears(-1)
  $sawActivityFile = $false
  foreach ($f in @('conversation.jsonl','turns.jsonl','channel.json','plan.jsonl','backlog.jsonl')) {
    $fp = Join-Path $chDir $f
    if (Test-Path -LiteralPath $fp) {
      $mt = (Get-Item -LiteralPath $fp).LastWriteTime
      $sawActivityFile = $true
      if ($mt -gt $lastTouch) { $lastTouch = $mt }
    }
  }
  if (-not $sawActivityFile) { $lastTouch = (Get-Item -LiteralPath $chDir).LastWriteTime }
  $ageMin = ((Get-Date) - $lastTouch).TotalMinutes
  if ($ageMin -lt $GraceMinutes) { return $null }

  $driverPids = @(Get-TestChannelDriverProcessIds -Name $Name)
  if ($driverPids.Count -gt 0) {
    if (Set-TestChannelArchivedFlag -Name $Name) {
      return [pscustomobject]@{ Name=$Name; Archived=$null; PendingStop=$true; DriverPids=$driverPids; AgeMinutes=[int]$ageMin }
    }
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error='failed to mark channel archived before driver stop' }
  }

  $archRoot = Join-Path $chRoot '_archive'
  if (-not (Test-Path -LiteralPath $archRoot)) { New-Item -ItemType Directory -Path $archRoot -Force | Out-Null }
  $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
  $dest = Join-Path $archRoot ($stamp + '_' + $Name)
  $n = 1
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $archRoot ($stamp + '_' + $Name + '_' + $n)
    $n++
  }

  try {
    Move-Item -LiteralPath $chDir -Destination $dest -ErrorAction Stop
    try {
      $purged = Purge-MemoryForChannel -Slug $Name
      if ($purged -gt 0) {
        try { Add-Message -From system -Kind event -Text ("Auto-purge: удалено " + $purged + " memory-записей архивированного канала " + $Name) | Out-Null } catch {}
      }
    } catch {}
    return [pscustomobject]@{ Name=$Name; Archived=$dest; AgeMinutes=[int]$ageMin }
  } catch {
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error=$_.Exception.Message }
  }
}

function Invoke-TestChannelCleanup {
  param([int]$GraceMinutes = 10)

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $chRoot -PathType Container)) { return @() }

  $results = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ch in @(Get-ChildItem -LiteralPath $chRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($ch.Name -eq '_archive') { continue }
    if (-not (Is-TestChannel -Name $ch.Name)) { continue }
    $r = Archive-TestChannelIfIdle -Name $ch.Name -GraceMinutes $GraceMinutes
    if ($r -and ($r.Archived -or $r.PendingStop)) {
      try {
        if ($r.PendingStop) {
          Add-Message -From system -Kind event -Text ("test_channel_archive_pending: " + $r.Name + " marked archived; waiting for driver stop (pid " + ((@($r.DriverPids) | ForEach-Object { [string]$_ }) -join ',') + ", age " + $r.AgeMinutes + " min)") | Out-Null
        } else {
          Add-Message -From system -Kind event -Text ("test_channel_archived: " + $r.Name + " -> " + $r.Archived + " (age " + $r.AgeMinutes + " min)") | Out-Null
        }
      } catch {}
      [void]$results.Add($r)
    }
  }
  return @($results.ToArray())
}

function Add-Message {
  param(
    [ValidateSet('claude','codex','user','system')] [string]$From,
    [string]$Text,
    [string]$Kind = 'message',
    [object[]]$Attachments = @(),
    [string]$Model = ''
  )
  Use-BridgeLock {
    $state = Read-State
    if ($null -eq $state) { throw 'state.json missing; run init first' }
    $seq = [int]$state.lastSeq + 1
    # 2026-05-30: dedup identical system events. A recycle mid-task replays a step
    # (claim / compaction), so the SAME "Беру задачу" / "История свёрнута" event
    # gets posted twice. Skip if the previous message is an identical system event
    # from the last 3 minutes. Only applies to system events (user/agent repeats
    # can be legitimate).
    if ($From -eq 'system') {
      try {
        $cpDedup = Get-ConversationPath
        $lastLn = Get-Content -LiteralPath $cpDedup -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLn) {
          $lm = $lastLn | ConvertFrom-Json
          if ((([string]$lm.from) -eq 'system') -and (([string]$lm.text) -eq ([string]$Text))) {
            $ageSec = ((Get-Date).ToUniversalTime() - ([datetimeoffset]$lm.ts).UtcDateTime).TotalSeconds
            if ($ageSec -lt 180) { return }
          }
        }
      } catch {}
    }
    $msg = [ordered]@{
      seq  = $seq
      ts   = (Get-Date).ToUniversalTime().ToString('o')
      from = $From
      kind = $Kind
      text = $Text
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $msg.model = $Model }
    if ($Attachments -and @($Attachments).Count -gt 0) {
      $msg.attachments = @($Attachments)
    }
    $line = ($msg | ConvertTo-Json -Compress -Depth 10)
    # FIX 2026-05-27: Add-Content fails when another process briefly holds an exclusive write
    # handle on conversation.jsonl (OneDrive sync, parallel driver writes). Retry with backoff
    # because losing a message is far worse than waiting 300ms. After max retries, append via
    # FileStream with FileShare.ReadWrite as last resort.
    $convPath = Get-ConversationPath
    $appended = $false
    $attempts = 0
    while (-not $appended -and $attempts -lt 6) {
      try {
        Add-Content -LiteralPath $convPath -Value $line -Encoding UTF8 -ErrorAction Stop
        $appended = $true
      } catch {
        $attempts++
        Start-Sleep -Milliseconds (50 * $attempts)
      }
    }
    if (-not $appended) {
      # Fallback: use FileStream with FileShare.ReadWrite (more forgiving than Add-Content).
      try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
        $fs = [System.IO.File]::Open($convPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length); $appended = $true } finally { $fs.Dispose() }
      } catch {
        # Last resort: write to a sidecar so the line isn't lost; recovery script can merge later.
        try {
          $sidecar = "$convPath.unflushed"
          [System.IO.File]::AppendAllText($sidecar, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
      }
    }
    $state.lastSeq = $seq
    Write-State -State $state
    return $seq
  }
}


function Invoke-ConversationArchive {
  # User-triggered chat cleanup: move all but the last $Keep messages from the live conversation.jsonl
  # into conversation.archive.jsonl. The bridge does NOT read the archive, so it never affects the
  # mind of the agents. lastSeq in state is untouched (seq continuity preserved) and summary.txt is
  # left intact (Format-Transcript still has its compressed history + the kept tail), so the agents
  # keep full context. Runs under the same Use-BridgeLock as Add-Message so a concurrent write can't
  # race. Returns @{ ok; archived; kept }.
  param([int]$Keep = 30)
  if ($Keep -lt 5) { $Keep = 5 }
  return (Use-BridgeLock {
    $convPath = Get-ConversationPath
    if (-not (Test-Path -LiteralPath $convPath)) { return [pscustomobject]@{ ok=$true; archived=0; kept=0 } }
    $lines = @(Get-Content -LiteralPath $convPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le $Keep) { return [pscustomobject]@{ ok=$true; archived=0; kept=$lines.Count } }
    $cut = $lines.Count - $Keep
    $toArchive = $lines[0..($cut-1)]
    $toKeep    = $lines[$cut..($lines.Count-1)]
    $u8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText((Get-ConversationArchivePath), (($toArchive -join "`n") + "`n"), $u8)
    [System.IO.File]::WriteAllText($convPath, (($toKeep -join "`n") + "`n"), $u8)
    return [pscustomobject]@{ ok=$true; archived=$toArchive.Count; kept=$toKeep.Count }
  })
}

function Invoke-ConversationArchivePrune {
  # Permanently drop archive lines older than $MaxAgeDays. The live conversation + summary are never
  # touched; only the archive sidecar (which the bridge doesn't read) is trimmed. Safe to run weekly.
  # Lines whose ts can't be parsed are KEPT (fail-safe). Returns count removed.
  param([int]$MaxAgeDays = 7)
  $archPath = Get-ConversationArchivePath
  if (-not (Test-Path -LiteralPath $archPath)) { return 0 }
  $cut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($MaxAgeDays))
  $all  = @(Get-Content -LiteralPath $archPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($all.Count -eq 0) { return 0 }
  $keep = @($all | Where-Object {
    $ok = $true
    try { $o = $_ | ConvertFrom-Json; $ts = [datetime]::Parse([string]$o.ts).ToUniversalTime(); $ok = ($ts -ge $cut) } catch { $ok = $true }
    $ok
  })
  $removed = $all.Count - $keep.Count
  if ($removed -gt 0) {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $body = if ($keep.Count -gt 0) { ($keep -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($archPath, $body, $u8)
  }
  return $removed
}


function Get-Messages {
  param([int]$Since = 0)
  $p = Get-ConversationPath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    if ([int]$m.seq -gt $Since) { [void]$out.Add($m) }
  }
  return @($out.ToArray())
}

function Initialize-Bridge {
  param([switch]$Reset)
  $root = Get-BridgeRoot
  foreach ($d in @('lib','web','sandbox','files','decisions','memory')) {
    $dp = Join-Path $root $d
    if (-not (Test-Path $dp)) { New-Item -ItemType Directory -Path $dp -Force | Out-Null }
  }
  $convo = Get-ConversationPath
  if ($Reset -or -not (Test-Path $convo)) {
    [System.IO.File]::WriteAllText($convo, '', (New-Object System.Text.UTF8Encoding($false)))
  }
  if ($Reset) {
    [System.IO.File]::WriteAllText((Get-SummaryPath), '', (New-Object System.Text.UTF8Encoding($false)))
  }
  $state = Read-State
  if ($Reset -or $null -eq $state) {
    # Phase 3 (full): when creating a fresh per-channel state.json, scan the channel's
    # existing conversation.jsonl and seed lastSeq from the max seq there. Otherwise UI
    # polling with ?since=<oldChannelSeq> would never see new sub-1 messages.
    $initialLastSeq = 0
    try {
      $convoPath = Get-ConversationPath
      if (Test-Path -LiteralPath $convoPath) {
        foreach ($line in (Get-Content -LiteralPath $convoPath -Encoding UTF8)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          try {
            $obj = $line | ConvertFrom-Json
            $s = [int]$obj.seq
            if ($s -gt $initialLastSeq) { $initialLastSeq = $s }
          } catch {}
        }
      }
    } catch {}
    $state = [ordered]@{
      status         = 'idle'
      paused         = $false
      stop           = $false
      abort          = $false
      active_agent   = $null
      active_model   = $null
      status_text    = $null
      agent_pid      = $null
      current_task   = $null
      current_task_id = $null
      task_turn      = 0
      task_mode      = 'normal'
      discuss_turn     = 0
      discuss_snapshot = ''
      study_phase      = ''
      study_subtype    = ''
      study_snapshot   = ''
      research_count   = 0
      task_start_seq = 0
      no_progress_count = 0
      timeout_retry_count = 0
      task_did_actions   = $false
      verify_retry_count = 0
      force_planner      = $false
      last_user_seq  = 0
      summarized_seq = 0
      turn           = 0
      lastSeq        = $initialLastSeq
      heartbeat      = $null
      driver_started = $null
      claimed_at     = $null
      current_backlog_id = $null
      autonomous_day   = $null
      autonomous_count = 0
      active_jobs      = @()
      task_base_commit = ''
      chunk_progress    = ''
      chunk_base_commit = ''
      force_coder       = $false
      critic_retry_count = 0
      current_agent      = $null
      current_agent_pid  = 0
      current_agent_ticks = 0
      current_agent_since = $null
      coder_fired        = $false
      coder_bypass_retry_count = 0
      held_task          = $null
      doctor_active      = $false
      doctor_attempts    = 0
      doctor_repair_attempts = 0
      doctor_restart_count   = 0
      doctor_reason      = ''
      doctor_started_at  = $null
      auditor            = @{ suppressed_hashes = @() }
      task_last_failure  = $null
      agent_telemetry    = $null
      session_mission    = $null
      task_timing_planner_ms = 0
      task_timing_worker_ms  = 0
      task_timing_critic_ms  = 0
      task_timing_verify_ms  = 0
      task_timing_smoke_ms   = 0
      task_timing_restart_ms = 0
      task_timing_memory_ms  = 0
      task_timing_start_at   = ''
    }
    Write-State -State $state -AllowPartial   # initial create; guard skip OK
  } else {
    # migrate older state.json: add any fields introduced later
    $defaults = @{
      status='idle'; paused=$false; stop=$false; abort=$false
      active_agent=$null; active_model=$null; status_text=$null; agent_pid=$null
      current_task=$null; current_task_id=$null; task_turn=0; task_mode='normal'; discuss_turn=0; discuss_snapshot=''; study_phase=''; study_subtype=''; study_snapshot=''; research_count=0; task_start_seq=0
      no_progress_count=0; timeout_retry_count=0; task_did_actions=$false; verify_retry_count=0; force_planner=$false
      last_user_seq=0; summarized_seq=0; turn=0; lastSeq=0
      heartbeat=$null; driver_started=$null; claimed_at=$null
      current_backlog_id=$null
      autonomous_day=$null; autonomous_count=0
      active_jobs=@(); task_base_commit=''; chunk_progress=''; chunk_base_commit=''; force_coder=$false; critic_retry_count=0
      current_agent=$null; current_agent_pid=0; current_agent_ticks=0; current_agent_since=$null
      coder_fired=$false; coder_bypass_retry_count=0
      held_task=$null; doctor_active=$false; doctor_attempts=0; doctor_repair_attempts=0; doctor_restart_count=0; doctor_reason=''; doctor_started_at=$null
      auditor=@{ suppressed_hashes=@() }
      task_last_failure=$null
      agent_telemetry=$null
      session_mission=$null
      task_timing_planner_ms=0; task_timing_worker_ms=0; task_timing_critic_ms=0; task_timing_verify_ms=0; task_timing_smoke_ms=0; task_timing_restart_ms=0; task_timing_memory_ms=0; task_timing_start_at=''
    }
    $changed = $false
    foreach ($k in $defaults.Keys) {
      if (-not ($state.PSObject.Properties.Name -contains $k)) {
        $state | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        $changed = $true
      }
    }
    if ($changed) { Write-State -State $state }
  }
  # Sanity-check: abort dead parallel streams on startup
  if ($state.PSObject.Properties['parallel_streams'] -and $state.parallel_streams.Count -gt 0) {
    $allAborted = $true
    $streamsChanged = $false
    foreach ($stream in $state.parallel_streams) {
      $proc = Get-Process -Id $stream.pid -ErrorAction SilentlyContinue
      $isDead = (-not $proc)
      if (-not $isDead -and $stream.PSObject.Properties['pidTicks'] -and $stream.pidTicks -gt 0) {
        $isDead = ($proc.StartTime.Ticks -ne $stream.pidTicks)
      }
      if ($isDead) {
        if ($stream.status -ne 'aborted') {
          $stream.status = 'aborted'
          $streamsChanged = $true
        }
      } else {
        $allAborted = $false
      }
    }
    if ($allAborted) {
      $state.parallel_streams = @()
      $streamsChanged = $true
    }
    if ($streamsChanged) { Write-State -State $state }
  }
  return (Read-State)
}


# Replay capture is loaded before memory/LLM helpers so background chat calls can
# write records when a task is active. Best-effort and non-fatal.
try { . (Join-Path $PSScriptRoot 'replay.ps1') } catch { Write-Warning "replay.ps1 failed to load: $($_.Exception.Message)" }
# Long-term vector memory (Gemini embeddings + Flash librarian). Best-effort: if this
# layer fails to load or Gemini is unreachable, the engine keeps running unchanged.
try { . (Join-Path $PSScriptRoot 'memory.ps1') } catch { Write-Warning "memory.ps1 failed to load: $($_.Exception.Message)" }
# Per-project semantic code memory, stored separately from ordinary long-term memory.
try { . (Join-Path $PSScriptRoot 'codemem.ps1') } catch { Write-Warning "codemem.ps1 failed to load: $($_.Exception.Message)" }
# LLM router (DeepSeek/Gemini for cheap background thinking) -- load AFTER memory.ps1.
try { . (Join-Path $PSScriptRoot 'llm.ps1') } catch { Write-Warning "llm.ps1 failed to load: $($_.Exception.Message)" }
# Usage accounting (prepaid agent turns + paid API calls). Best-effort and non-fatal.
try { . (Join-Path $PSScriptRoot 'usage.ps1') } catch { Write-Warning "usage.ps1 failed to load: $($_.Exception.Message)" }
# Planner model router layered on top of Get-PlannerModel; learns from turns.jsonl outcomes.
try { . (Join-Path $PSScriptRoot 'router.ps1') } catch { Write-Warning "router.ps1 failed to load: $($_.Exception.Message)" }
# Channel layout helpers must load before backlog.ps1 because Get-BacklogPath
# delegates to Get-ChannelBacklogPath when channels are available.
try { . (Join-Path $PSScriptRoot 'channels.ps1') } catch { Write-Warning "channels.ps1 failed to load: $($_.Exception.Message)" }
# Run channel migration once — moves legacy bridge-root files into channels/main/ if needed.
# Idempotent; safe to call on every Initialize-Bridge.
try { Initialize-Channels } catch { Write-Warning "Initialize-Channels failed: $($_.Exception.Message)" }
# Self-improvement backlog (ideas the agents raise themselves).
try { . (Join-Path $PSScriptRoot 'backlog.ps1') } catch { Write-Warning "backlog.ps1 failed to load: $($_.Exception.Message)" }
# User-tunable settings (gitignored overrides: idle-quiet, autonomy scope, etc.).
try { . (Join-Path $PSScriptRoot 'settings.ps1') } catch { Write-Warning "settings.ps1 failed to load: $($_.Exception.Message)" }
# Background job manager (long-running commands -- e.g. hour-long project runs).
try { . (Join-Path $PSScriptRoot 'jobs.ps1') } catch { Write-Warning "jobs.ps1 failed to load: $($_.Exception.Message)" }
# Worktree isolation primitives (foundation for parallel workers + sandbox).
try { . (Join-Path $PSScriptRoot 'worktrees.ps1') } catch { Write-Warning "worktrees.ps1 failed to load: $($_.Exception.Message)" }
# Tool Foundry (Фаза 1): registry + loader for tools the bridge synthesizes on the fly.
try { . (Join-Path $PSScriptRoot 'toolforge.ps1') } catch { Write-Warning "toolforge.ps1 failed to load: $($_.Exception.Message)" }
# Parallel worker orchestration (run sub-tasks concurrently in worktrees, merge back).
try { . (Join-Path $PSScriptRoot 'parallel.ps1') } catch { Write-Warning "parallel.ps1 failed to load: $($_.Exception.Message)" }
try { . (Join-Path $PSScriptRoot 'doctor.ps1') } catch { Write-Warning "doctor.ps1 failed to load: $($_.Exception.Message)" }
try { . (Join-Path $PSScriptRoot 'architect.ps1') } catch { Write-Warning "architect.ps1 failed to load: $($_.Exception.Message)" }
# Evidence-backed per-project memory layer (typed memory + context pack) on top
# of memory.ps1/codemem.ps1/channels.ps1. Best-effort and non-fatal.
try { . (Join-Path $PSScriptRoot 'project-context.ps1') } catch { Write-Warning "project-context.ps1 failed to load: $($_.Exception.Message)" }
# Telegram push notifications (best-effort, non-fatal).
try { . (Join-Path $PSScriptRoot 'notify.ps1') } catch { Write-Warning "notify.ps1 failed to load: $($_.Exception.Message)" }
# Study-mode detection (single source of truth; bounded command-verb gate).
try { . (Join-Path $PSScriptRoot 'study.ps1') } catch { Write-Warning "study.ps1 failed to load: $($_.Exception.Message)" }
# LLM intent classifier — replaces hardcoded [[DEEP-THINK]] regex with semantic
# task understanding (gemini-flash-lite, cheap). Must load AFTER llm.ps1.
try { . (Join-Path $PSScriptRoot 'intent.ps1') } catch { Write-Warning "intent.ps1 failed to load: $($_.Exception.Message)" }
# Radar (RSS digest collector) + Scholar (autonomous deep-reader: reads FULL article text + links,
# verdicts idea/knowledge/skip against bridge gaps -- replaces radar's title-only judging). Scholar
# depends on radar (candidates) + llm + backlog (all loaded above).
try { . (Join-Path $PSScriptRoot 'radar.ps1') } catch { Write-Warning "radar.ps1 failed to load: $($_.Exception.Message)" }
# 2026-06-03 slimming rank1: scholar.ps1 (autonomous deep-reader oracle) removed — a modern model
# does article-study / gap-analysis inline when a task needs it; the background scholar agent was scaffolding.
# 2026-06-03 slimming Atom 1: Model Decision Layer (SHADOW). Contract + deterministic validator + shadow
# logger. Behavior-neutral until promoted; legacy heuristics still decide. See SLIMMING_PLAN.md.
try { . (Join-Path $PSScriptRoot 'decision-contract.ps1') } catch { Write-Warning "decision-contract.ps1 failed to load: $($_.Exception.Message)" }
