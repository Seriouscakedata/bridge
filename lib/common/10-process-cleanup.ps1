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

function Merge-UnflushedSidecars {
  # 2026-05-27v6: P3 audit finding -- Add-Message writes lost messages to
  # `$convPath.unflushed` when main append fails (OneDrive lock, fs error).
  # Previously there was no recovery on startup -- user never knew messages
  # were lost. Now we scan for *.unflushed sidecars next to channels'
  # conversation.jsonl files and merge them in (append + delete sidecar).
  # Safe to call multiple times; idempotent (sidecar deleted after merge).
  $root = Get-BridgeRoot
  $chanRoot = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $chanRoot)) { return @{ merged = 0 } }
  $totalLines = 0; $totalSidecars = 0
  try {
    $sidecars = Get-ChildItem -LiteralPath $chanRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'conversation.jsonl.unflushed' }
    foreach ($sc in $sidecars) {
      try {
        $convPath = $sc.FullName -replace '\.unflushed$', ''
        if (-not (Test-Path -LiteralPath $convPath)) { continue }
        $u8 = New-Object System.Text.UTF8Encoding($false)
        $content = [System.IO.File]::ReadAllText($sc.FullName, $u8)
        if ([string]::IsNullOrWhiteSpace($content)) { Remove-FileWithRetry -Path $sc.FullName -Reason 'unflushed-empty' | Out-Null; continue }
        # Append to main conversation
        $fs = [System.IO.File]::Open($convPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
          $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
          $fs.Write($bytes, 0, $bytes.Length)
          $totalLines += ($content -split "`n").Count
          $totalSidecars++
        } finally { $fs.Dispose() }
        # Only delete sidecar after successful merge
        Remove-FileWithRetry -Path $sc.FullName -Reason 'unflushed-merged' | Out-Null
      } catch {
        # If anything fails for this sidecar, leave it for next startup attempt.
        try {
          $logPath = Join-Path (Join-Path $root 'control') 'tmp-leak.log'
          $line = (Get-Date).ToString('o') + " | reason=unflushed-merge-fail | path=" + $sc.FullName + " | err=" + $_.Exception.Message + "`n"
          [System.IO.File]::AppendAllText($logPath, $line, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
      }
    }
  } catch {}
  return @{ merged = $totalLines; sidecars = $totalSidecars }
}

function Rotate-LogIfBig {
  # Rotates a log file when it exceeds $MaxKB. Keeps last $Keep rotated copies
  # as $Path.1, $Path.2, ... Older rotations are deleted. Idempotent.
  # 2026-05-27v6: P1 audit finding -- metrics.jsonl/usage.jsonl/bridge-lock.log
  # were growing without TTL. This is called from driver idle loop periodically.
  param([string]$Path, [int]$MaxKB = 2048, [int]$Keep = 3)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt ($MaxKB * 1024)) { return $false }
    # Rotate: $Path.3 -> delete, .2 -> .3, .1 -> .2, $Path -> .1
    for ($i = $Keep; $i -ge 1; $i--) {
      $src = "$Path.$i"
      $dst = "$Path.$($i + 1)"
      if ($i -eq $Keep -and (Test-Path -LiteralPath $src)) {
        Remove-FileWithRetry -Path $src -Reason 'log-rotate-drop' | Out-Null
        continue
      }
      if (Test-Path -LiteralPath $src) {
        try { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop } catch {}
      }
    }
    try { Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop } catch {}
    return $true
  } catch { return $false }
}

function Sweep-OrphanTmpFiles {
  # Periodic cleanup of *.tmp.* files older than 1 hour (rough heuristic: tmp files
  # actively in use are deleted within seconds; older ones are orphans from crashes
  # or silent-fail removals). Called once at driver startup.
  # SAFE: only touches files matching *.tmp.* pattern, skips files mid-write
  # (mtime within last 60 seconds).
  param([int]$MinAgeMin = 60)
  $root = Get-BridgeRoot
  $scanDirs = @(
    $root,
    (Join-Path $root 'channels'),
    (Join-Path $root 'memory')
  )
  $cutoff = (Get-Date).AddMinutes(-$MinAgeMin)
  $logDir = Join-Path $root 'control'
  if (-not (Test-Path -LiteralPath $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {} }
  $logPath = Join-Path $logDir 'tmp-sweep.log'
  $u8 = New-Object System.Text.UTF8Encoding($false)
  $cleaned = 0; $failed = 0
  foreach ($d in $scanDirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    try {
      $tmpFiles = Get-ChildItem -LiteralPath $d -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.tmp\.[a-f0-9]+$' -and $_.LastWriteTime -lt $cutoff }
      foreach ($f in $tmpFiles) {
        if (Remove-FileWithRetry -Path $f.FullName -Reason 'sweep-orphan') { $cleaned++ } else { $failed++ }
      }
    } catch {}
  }
  if ($cleaned -gt 0 -or $failed -gt 0) {
    try {
      $line = (Get-Date).ToString('o') + " | cleaned=$cleaned failed=$failed`n"
      [System.IO.File]::AppendAllText($logPath, $line, $u8)
    } catch {}
  }
  return @{ cleaned = $cleaned; failed = $failed }
}

