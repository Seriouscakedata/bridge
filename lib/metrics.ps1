# metrics.ps1 -- Learning Loop pt1: health metrics, hypotheses, reflection.

if (-not (Get-Command Get-BridgeObjectValue -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'primitives.ps1') } catch {}
}

function Get-TurnsStats {
  param([object[]]$Entries)

  if (-not $Entries -or $Entries.Count -eq 0) {
    return [pscustomobject]@{
      total       = 0
      timeout_pct = 0.0
      avg_sec     = 0.0
      success_pct = 0.0
      window_from = $null
      window_to   = $null
    }
  }

  $total = $Entries.Count
  $timeouts = @($Entries | Where-Object { $_.status -eq 'timeout' }).Count
  $successes = @($Entries | Where-Object { $_.status -eq 'ok' }).Count
  $secs = @($Entries | Where-Object { $_.sec -ne $null } | ForEach-Object { [double]$_.sec })
  $avgSec = if ($secs.Count -gt 0) { [Math]::Round(($secs | Measure-Object -Average).Average, 2) } else { 0.0 }
  $wFrom = ($Entries | Sort-Object ts | Select-Object -First 1).ts
  $wTo = ($Entries | Sort-Object ts | Select-Object -Last 1).ts

  [pscustomobject]@{
    total       = $total
    timeout_pct = [Math]::Round($timeouts / $total, 4)
    avg_sec     = $avgSec
    success_pct = [Math]::Round($successes / $total, 4)
    window_from = $wFrom
    window_to   = $wTo
  }
}

function Get-FastLaneLatencyStats {
  param([int]$Limit = 500)

  $entries = @(Read-RecentTurns -Limit $Limit)
  $codex = @($entries | Where-Object { [string]$_.speaker -eq 'codex' -and $null -ne $_.sec })
  $fast = @($codex | Where-Object { $_.fast_lane -eq $true })
  $normal = @($codex | Where-Object { $_.fast_lane -ne $true })

  function _GetFastLanePctl {
    param([double[]]$Values, [double]$Percentile)
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $idx = [int][Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [Math]::Round($sorted[$idx], 2)
  }

  function _GetFastLaneSummary {
    param([object[]]$Rows)
    $secs = @($Rows | ForEach-Object { [double]$_.sec })
    $avgSec = 0.0
    $minSec = 0.0
    $maxSec = 0.0
    if ($secs.Count -gt 0) {
      $avgSec = [Math]::Round(($secs | Measure-Object -Average).Average, 2)
      $minSec = [Math]::Round(($secs | Measure-Object -Minimum).Minimum, 2)
      $maxSec = [Math]::Round(($secs | Measure-Object -Maximum).Maximum, 2)
    }

    return [pscustomobject]@{
      count   = $Rows.Count
      avg_sec = $avgSec
      p50_sec = _GetFastLanePctl $secs 50
      p90_sec = _GetFastLanePctl $secs 90
      min_sec = $minSec
      max_sec = $maxSec
    }
  }

  return [pscustomobject]@{
    fast_lane    = (_GetFastLaneSummary $fast)
    normal_codex = (_GetFastLaneSummary $normal)
    window_turns = $codex.Count
  }
}

function Read-MetricsJsonl {
  $mf = Join-Path (Get-BridgeRoot) 'metrics.jsonl'
  if (-not (Test-Path $mf)) { return @() }

  Get-Content $mf -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch {}
  }
}

function Append-MetricsRecord {
  param([hashtable]$Record)

  $mf = Join-Path (Get-BridgeRoot) 'metrics.jsonl'
  $Record['ts'] = [DateTime]::UtcNow.ToString('o')
  $line = $Record | ConvertTo-Json -Compress -Depth 5
  Add-Content -LiteralPath $mf -Value $line -Encoding UTF8
}

function Append-TaskLatencyRecord {
  param(
    [string]$TaskId = '',
    [string]$TaskTextShort = '',
    [long]$TotalMs = 0,
    [hashtable]$PhaseTimings = @{}
  )
  $top3 = @($PhaseTimings.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object { $_.Value } -Descending | Select-Object -First 3 | ForEach-Object {
    [ordered]@{ phase=[string]$_.Key; ms=[long]$_.Value }
  })
  Append-MetricsRecord @{
    type            = 'task-latency'
    task_id         = [string]$TaskId
    task_text_short = [string]$TaskTextShort
    total_ms        = [long]$TotalMs
    phase_timings   = $PhaseTimings
    top3            = @($top3)
  }
}

function Get-TaskLatencyRecords {
  param([int]$Limit = 20)
  @(Read-MetricsJsonl | Where-Object { [string]$_.type -eq 'task-latency' } | Select-Object -Last $Limit)
}

function Read-RecentTurns {
  param([int]$Limit = 200)

  $tf = Join-Path (Get-BridgeRoot) 'turns.jsonl'
  $entries = @()
  if (Test-Path $tf) {
    $entries = @(Get-Content $tf -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
      try { $_ | ConvertFrom-Json } catch {}
    } | Where-Object { $_ })
    if ($entries.Count -gt $Limit) { $entries = $entries[-$Limit..-1] }
  }

  return @($entries)
}

function Write-MetricsSnapshot {
  $entries = @(Read-RecentTurns -Limit 200)
  $stats = Get-TurnsStats -Entries $entries

  Append-MetricsRecord @{
    type        = 'snapshot'
    total_turns = $stats.total
    timeout_pct = $stats.timeout_pct
    avg_sec     = $stats.avg_sec
    success_pct = $stats.success_pct
    window_from = $stats.window_from
    window_to   = $stats.window_to
  }
}

function Get-MetricsForApi {
  $currentStats = Get-TurnsStats -Entries @(Read-RecentTurns -Limit 200)
  $series = New-Object 'System.Collections.Generic.List[object]'
  $mf = Join-Path (Get-BridgeRoot) 'metrics.jsonl'
  if (Test-Path -LiteralPath $mf) {
    foreach ($line in (Get-Content -LiteralPath $mf -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $rec = $line | ConvertFrom-Json } catch { continue }
      if ([string]$rec.type -ne 'snapshot') { continue }
      [void]$series.Add([pscustomobject]@{
        ts          = [string]$rec.ts
        timeout_pct = [double]$rec.timeout_pct
        avg_sec     = [double]$rec.avg_sec
        success_pct = [double]$rec.success_pct
        total_turns = [int]$rec.total_turns
      })
    }
  }

  $items = @($series.ToArray() | Sort-Object ts)
  if ($items.Count -gt 100) { $items = @($items[($items.Count - 100)..($items.Count - 1)]) }

  $drStats = $null
  try { $drStats = Get-DoctorStats -WindowHours 168 } catch {}

  return [pscustomobject]@{
    current = [pscustomobject]@{
      total_turns = [int]$currentStats.total
      timeout_pct = [double]$currentStats.timeout_pct
      avg_sec     = [double]$currentStats.avg_sec
      success_pct = [double]$currentStats.success_pct
      window_from = $currentStats.window_from
      window_to   = $currentStats.window_to
    }
    series       = @($items)
    series_count = [int]$items.Count
    doctor       = $drStats
  }
}

function Get-MetricsObjectValue {
  # Delegate preserves original metrics semantics: present-but-null is returned.
  param($Obj, [string]$Name)
  if ($null -eq $Obj -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  try { return Get-BridgeObjectValue -Object $Obj -Names @($Name) -Default $null } catch { return $null }
}

function ConvertTo-MetricsUtcDateTime {
  param($Value)
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $dto = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($text, [ref]$dto)) { return $dto.UtcDateTime }
  $dt = [DateTime]::MinValue
  if ([DateTime]::TryParse($text, [ref]$dt)) { return $dt.ToUniversalTime() }
  return $null
}

function Get-BacklogAutonomyTerminalTimeUtc {
  param($Item)
  if ($null -eq $Item) { return $null }

  $status = ([string](Get-MetricsObjectValue $Item 'status')).ToLowerInvariant()
  $fields = switch ($status) {
    'done'          { @('done_at','completed_at','closed_at','updated_at','ts') }
    'auto-resolved' { @('resolved_at','auto_resolved_at','completed_at','closed_at','updated_at','ts') }
    'failed'        { @('failed_at','completed_at','closed_at','updated_at','ts') }
    'held'          { @('held_at','updated_at','ts') }
    'rejected'      { @('rejected_at','duplicate_rejected_at','updated_at','ts') }
    'auto-dropped'  { @('dropped_at','auto_dropped_at','updated_at','ts') }
    default         { @('updated_at','ts') }
  }

  foreach ($field in $fields) {
    $dt = ConvertTo-MetricsUtcDateTime (Get-MetricsObjectValue $Item $field)
    if ($dt) { return $dt }
  }

  $curator = Get-MetricsObjectValue $Item 'auto_curator'
  if ($curator) {
    $dt = ConvertTo-MetricsUtcDateTime (Get-MetricsObjectValue $curator 'ts')
    if ($dt) { return $dt }
  }
  return $null
}

function Get-BacklogAutonomyWindow {
  param([object[]]$Items, [DateTime]$NowUtc, [int]$Hours)

  $terminal = @{ done = $true; 'auto-resolved' = $true; failed = $true; held = $true; rejected = $true; 'auto-dropped' = $true }
  $autonomous = @{ done = $true; 'auto-resolved' = $true }
  $cutoff = $NowUtc.AddHours(-1 * [Math]::Abs($Hours))
  $total = 0
  $auto = 0

  foreach ($item in @($Items)) {
    $status = ([string](Get-MetricsObjectValue $item 'status')).ToLowerInvariant()
    if (-not $terminal.ContainsKey($status)) { continue }
    $terminalAt = Get-BacklogAutonomyTerminalTimeUtc -Item $item
    if (-not $terminalAt -or $terminalAt -lt $cutoff) { continue }
    $total++
    if ($autonomous.ContainsKey($status)) { $auto++ }
  }

  $pct = if ($total -gt 0) { [Math]::Round(100.0 * $auto / $total, 1) } else { 0.0 }
  return [pscustomobject]@{
    hours      = [int]$Hours
    autonomous = [int]$auto
    terminal   = [int]$total
    pct        = [double]$pct
  }
}

function Get-ChannelAutonomyMetric {
  param(
    [string]$Channel = 'main',
    [string]$Root = $null,
    [DateTime]$NowUtc = ([DateTime]::UtcNow)
  )

  if ([string]::IsNullOrWhiteSpace($Root)) {
    if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { $Root = Get-BridgeRoot }
    else { $Root = Split-Path -Parent $PSScriptRoot }
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }

  $backlogPath = Join-Path $Root ("channels\" + $Channel + "\backlog.jsonl")
  $byId = @{}
  $readErrors = 0
  if (Test-Path -LiteralPath $backlogPath) {
    foreach ($line in [System.IO.File]::ReadLines($backlogPath, [System.Text.Encoding]::UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $item = $line | ConvertFrom-Json } catch { $readErrors++; continue }
      $id = [string](Get-MetricsObjectValue $item 'id')
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      $byId[$id] = $item
    }
  }

  $items = @($byId.Values)
  $w24 = Get-BacklogAutonomyWindow -Items $items -NowUtc $NowUtc -Hours 24
  $w7d = Get-BacklogAutonomyWindow -Items $items -NowUtc $NowUtc -Hours (24 * 7)
  return [pscustomobject]@{
    channel      = [string]$Channel
    generated_at = $NowUtc.ToString('o')
    source       = $backlogPath
    read_errors  = [int]$readErrors
    h24          = $w24
    d7           = $w7d
  }
}

function Get-LastMetricsSnapshot {
  $records = Read-MetricsJsonl
  $snaps = $records | Where-Object { $_.type -eq 'snapshot' }
  if (-not $snaps) { return $null }
  $snaps | Sort-Object ts | Select-Object -Last 1
}

function Write-Hypothesis {
  param([string]$CommitHash, [string]$TaskText)

  Write-MetricsSnapshot
  $entries = @(Read-RecentTurns -Limit 200)
  $stats = Get-TurnsStats -Entries $entries

  Append-MetricsRecord @{
    type     = 'hypothesis'
    commit   = $CommitHash
    task     = $TaskText
    baseline = @{
      timeout_pct = $stats.timeout_pct
      avg_sec     = $stats.avg_sec
      success_pct = $stats.success_pct
    }
  }
}

function Invoke-MetricsReflection {
  $records = Read-MetricsJsonl
  $hyps = $records | Where-Object { $_.type -eq 'hypothesis' }
  $verdicts = $records | Where-Object { $_.type -eq 'verdict' }
  if (-not $hyps) { return }

  $tf = Join-Path (Get-BridgeRoot) 'turns.jsonl'
  $allTurns = @()
  if (Test-Path $tf) {
    $allTurns = @(Get-Content $tf -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
      try { $_ | ConvertFrom-Json } catch {}
    } | Where-Object { $_ })
  }

  foreach ($hyp in $hyps) {
    $hypTs = [DateTime]$hyp.ts
    if (([DateTime]::UtcNow - $hypTs).TotalHours -lt 24) { continue }

    $already = $verdicts | Where-Object { $_.hypothesis_ts -eq $hyp.ts }
    if ($already) { continue }

    $afterTurns = @($allTurns | Where-Object { [DateTime]$_.ts -gt $hypTs })
    if ($afterTurns.Count -lt 10) { continue }

    $afterStats = Get-TurnsStats -Entries $afterTurns
    $bl = $hyp.baseline

    $dPct  = $afterStats.timeout_pct - [double]$bl.timeout_pct                 # timeout rate change (lower = better)
    $dSucc = $afterStats.success_pct - [double]$bl.success_pct                 # success rate change (higher = better)
    $dSec  = if ([double]$bl.avg_sec -gt 0) { ($afterStats.avg_sec - [double]$bl.avg_sec) / [double]$bl.avg_sec } else { 0 }  # avg turn time, relative (lower = better)

    # Symmetric, regression-sensitive verdict. The old logic OR-checked 'worked'
    # first, so a mixed result (one axis better, one worse) was mislabeled
    # 'worked' -> the 33/33-'worked' bias that made the loop blind to regressions.
    # Now: a clear regression on ANY axis with no offsetting improvement => 'worse';
    # a clear improvement with no regression => 'worked'; conflicting/flat => 'no_effect'.
    $improved  = ($dPct -le -0.05) -or ($dSucc -ge 0.05) -or ($dSec -le -0.15)
    $regressed = ($dPct -ge 0.05)  -or ($dSucc -le -0.05) -or ($dSec -ge 0.15)

    $verdict = 'no_effect'
    if     ($regressed -and -not $improved)  { $verdict = 'worse' }
    elseif ($improved  -and -not $regressed) { $verdict = 'worked' }

    Append-MetricsRecord @{
      type          = 'verdict'
      hypothesis_ts = $hyp.ts
      commit        = $hyp.commit
      task          = $hyp.task
      verdict       = $verdict
      after_turns   = $afterTurns.Count
      delta         = @{
        timeout_pct = [Math]::Round($dPct, 4)
        avg_sec     = [Math]::Round($afterStats.avg_sec - [double]$bl.avg_sec, 2)
        success_pct = [Math]::Round($afterStats.success_pct - [double]$bl.success_pct, 4)
      }
      after         = @{
        timeout_pct = $afterStats.timeout_pct
        avg_sec     = $afterStats.avg_sec
        success_pct = $afterStats.success_pct
      }
    }

    try {
      $bPct = [Math]::Round([double]$bl.timeout_pct * 100, 1)
      $aPct = [Math]::Round($afterStats.timeout_pct * 100, 1)
      $bAvg = [Math]::Round([double]$bl.avg_sec, 1)
      $aAvg = [Math]::Round($afterStats.avg_sec, 1)
      $memText = "Гипотеза '$($hyp.task)' (коммит $($hyp.commit)): вердикт $verdict. Таймауты: $bPct% -> $aPct%. Среднее время хода: $bAvg -> $aAvg сек. ($($afterTurns.Count) ходов после улучшения)"
      Add-Memory -Text $memText -Tags @('learning-loop','hypothesis','verdict') -Importance 0.8 | Out-Null
    } catch {}
  }

  # === Actuation pass — close the loop on settled verdicts ===
  # Walks ALL verdicts (not just ones minted this cycle) so transient deferrals
  # (one-revert-per-cycle cap, dirty tree) retry on a later cycle. 'worse' -> a
  # SAFE `git revert` (inverse commit; never reset --hard / push --force);
  # 'worked' -> cement the win into durable memory. Fail-closed throughout.
  try {
    $allRec      = Read-MetricsJsonl
    $allVerdicts = @($allRec | Where-Object { $_.type -eq 'verdict' })
    $allActs     = @($allRec | Where-Object { $_.type -eq 'actuation' })
    $terminal    = @('reverted','cement','revert_disabled','revert_shadow','revert_guard_blocked','revert_failed','revert_skipped')
    $revertedThisCycle = $false
    foreach ($v in ($allVerdicts | Sort-Object ts)) {
      $vv = [string]$v.verdict
      if ($vv -ne 'worked' -and $vv -ne 'worse') { continue }   # no_effect: nothing to actuate
      $hts = [string]$v.hypothesis_ts
      $settled = $allActs | Where-Object { ([string]$_.hypothesis_ts -eq $hts) -and ($terminal -contains [string]$_.action) }
      if ($settled) { continue }
      $aTurns = 0; try { $aTurns = [int]$v.after_turns } catch {}
      $act = $null
      try { $act = Invoke-VerdictActuation -Verdict $vv -Commit ([string]$v.commit) -Task ([string]$v.task) -HypothesisTs $hts -AfterTurns $aTurns -AllowRevert (-not $revertedThisCycle) } catch {}
      if ($act -and $act.reverted) { $revertedThisCycle = $true }
    }
  } catch {}
}

function Get-LearningLoopConfig {
  # Operator kill-switch for verdict actuation. Default is OFF + shadow evidence:
  # models/metrics may say "worse", but the bridge only records what it would do.
  # Real auto-revert must pass Test-LearningLoopAutoRevertGuard. Every git op stays fail-closed.
  $cfg = @{
    autoRevert = $false
    autoRevertShadow = $true
    autoRevertMaxHypothesisAgeHours = 30.0
    autoRevertMaxCommitsBehindHead = 0
    autoRevertRequireUnhealthy = $true
    autoRevertRequireCleanWorktree = $true
  }
  try {
    $j = $null
    if (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue) {
      $j = Get-BridgeConfig
    } else {
      $cf = Join-Path (Get-BridgeRoot) 'config.json'
      if (Test-Path -LiteralPath $cf) {
        $j = [System.IO.File]::ReadAllText($cf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      }
    }
    if ($j -and $j.PSObject.Properties['learningLoop']) {
      $ll = $j.learningLoop
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevert']) { $cfg.autoRevert = [bool]$ll.autoRevert }
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevertShadow']) { $cfg.autoRevertShadow = [bool]$ll.autoRevertShadow }
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevertMaxHypothesisAgeHours']) { try { $cfg.autoRevertMaxHypothesisAgeHours = [double]$ll.autoRevertMaxHypothesisAgeHours } catch {} }
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevertMaxCommitsBehindHead']) { try { $cfg.autoRevertMaxCommitsBehindHead = [int]$ll.autoRevertMaxCommitsBehindHead } catch {} }
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevertRequireUnhealthy']) { $cfg.autoRevertRequireUnhealthy = [bool]$ll.autoRevertRequireUnhealthy }
      if ($ll.PSObject -and $ll.PSObject.Properties['autoRevertRequireCleanWorktree']) { $cfg.autoRevertRequireCleanWorktree = [bool]$ll.autoRevertRequireCleanWorktree }
    }
  } catch {}
  return $cfg
}

function Test-GitCommitExists {
  param([string]$Root, [string]$Commit)
  if ([string]::IsNullOrWhiteSpace($Commit)) { return $false }
  try {
    $arg = $Commit + '^{commit}'
    & git -C $Root rev-parse --verify --quiet $arg 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Get-LearningLoopGitText {
  param([string]$Root, [string[]]$ArgsList)
  if ([string]::IsNullOrWhiteSpace($Root) -or -not $ArgsList -or $ArgsList.Count -eq 0) { return '' }
  try {
    $out = & git -C $Root @ArgsList 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ((@($out) | Select-Object -First 1) -join "`n").Trim()
  } catch {
    return ''
  }
}

function Test-LearningLoopGitCleanTracked {
  param([string]$Root)
  try {
    & git -C $Root diff --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ clean = $false; reason = 'dirty_worktree' } }
    & git -C $Root diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ clean = $false; reason = 'dirty_index' } }
    return [pscustomobject]@{ clean = $true; reason = 'clean' }
  } catch {
    return [pscustomobject]@{ clean = $false; reason = 'git_clean_check_failed' }
  }
}

function Test-LearningLoopCommitAlreadyReverted {
  param([string]$Root, [string]$Commit)
  $full = Get-LearningLoopGitText -Root $Root -ArgsList @('rev-parse', $Commit)
  if ([string]::IsNullOrWhiteSpace($full)) { return $false }
  $needle = 'This reverts commit ' + $full
  $hit = Get-LearningLoopGitText -Root $Root -ArgsList @('log', '--all', '--fixed-strings', '--grep', $needle, '--format=%H', '-n', '1')
  return (-not [string]::IsNullOrWhiteSpace($hit))
}

function Get-LearningLoopHealthRed {
  param([string]$Root)
  $port = 8787
  try {
    if (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue) {
      $bc = Get-BridgeConfig
      if ($bc -and $bc.PSObject.Properties.Name -contains 'port') { $port = [int]$bc.port }
    }
  } catch {}
  try {
    $uri = 'http://127.0.0.1:' + $port + '/api/health'
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $body = $resp.Content | ConvertFrom-Json
    $ok = $false
    try { $ok = [bool]$body.ok } catch { $ok = $false }
    return [pscustomobject]@{ known = $true; red = (-not $ok); reason = ('health_ok=' + $ok) }
  } catch {
    return [pscustomobject]@{ known = $false; red = $false; reason = ('health_probe_failed: ' + $_.Exception.Message) }
  }
}

function Test-LearningLoopAutoRevertGuard {
  param(
    [string]$Root,
    [string]$Commit,
    [string]$HypothesisTs = '',
    $Config = $null,
    [Nullable[bool]]$HealthRed = $null,
    [DateTime]$NowUtc = ([DateTime]::UtcNow)
  )
  if ($null -eq $Config) { $Config = Get-LearningLoopConfig }
  $detail = [ordered]@{
    commit = [string]$Commit
    hypothesis_ts = [string]$HypothesisTs
  }
  function Deny-LearningLoopAutoRevert([string]$Reason) {
    return [pscustomobject][ordered]@{ allowed = $false; reason = $Reason; detail = [pscustomobject]$detail }
  }
  function Allow-LearningLoopAutoRevert {
    return [pscustomobject][ordered]@{ allowed = $true; reason = 'guard_passed'; detail = [pscustomobject]$detail }
  }

  if ([string]::IsNullOrWhiteSpace($Root)) { return (Deny-LearningLoopAutoRevert 'missing_root') }
  if ([string]::IsNullOrWhiteSpace($Commit)) { return (Deny-LearningLoopAutoRevert 'missing_commit') }

  $fullCommit = Get-LearningLoopGitText -Root $Root -ArgsList @('rev-parse', $Commit)
  if ([string]::IsNullOrWhiteSpace($fullCommit)) { return (Deny-LearningLoopAutoRevert 'commit_not_found') }
  $detail.full_commit = $fullCommit

  $maxAgeHours = 0.0
  try { $maxAgeHours = [double]$Config.autoRevertMaxHypothesisAgeHours } catch { $maxAgeHours = 0.0 }
  if ($maxAgeHours -gt 0) {
    $hypDto = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$HypothesisTs, [ref]$hypDto)) { return (Deny-LearningLoopAutoRevert 'invalid_hypothesis_ts') }
    $ageHours = ($NowUtc.ToUniversalTime() - $hypDto.UtcDateTime).TotalHours
    $detail.age_hours = [Math]::Round($ageHours, 3)
    $detail.max_age_hours = $maxAgeHours
    if ($ageHours -gt $maxAgeHours) { return (Deny-LearningLoopAutoRevert 'stale_hypothesis') }
  }

  try {
    & git -C $Root merge-base --is-ancestor $fullCommit HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return (Deny-LearningLoopAutoRevert 'commit_not_in_head_lineage') }
  } catch {
    return (Deny-LearningLoopAutoRevert 'lineage_check_failed')
  }

  $maxBehind = 0
  try { $maxBehind = [int]$Config.autoRevertMaxCommitsBehindHead } catch { $maxBehind = 0 }
  if ($maxBehind -ge 0) {
    $behindText = Get-LearningLoopGitText -Root $Root -ArgsList @('rev-list', '--count', ($fullCommit + '..HEAD'))
    $behind = -1
    try { $behind = [int]$behindText } catch { $behind = -1 }
    if ($behind -lt 0) { return (Deny-LearningLoopAutoRevert 'distance_unknown') }
    $detail.commits_behind_head = $behind
    $detail.max_commits_behind_head = $maxBehind
    if ($behind -gt $maxBehind) { return (Deny-LearningLoopAutoRevert 'commit_too_far_behind_head') }
  }

  if (Test-LearningLoopCommitAlreadyReverted -Root $Root -Commit $fullCommit) {
    return (Deny-LearningLoopAutoRevert 'already_reverted')
  }

  $requireClean = $true
  try { $requireClean = [bool]$Config.autoRevertRequireCleanWorktree } catch { $requireClean = $true }
  if ($requireClean) {
    $clean = Test-LearningLoopGitCleanTracked -Root $Root
    $detail.clean_reason = [string]$clean.reason
    if (-not [bool]$clean.clean) { return (Deny-LearningLoopAutoRevert ([string]$clean.reason)) }
  }

  $requireUnhealthy = $true
  try { $requireUnhealthy = [bool]$Config.autoRevertRequireUnhealthy } catch { $requireUnhealthy = $true }
  if ($requireUnhealthy) {
    $health = $null
    if ($HealthRed.HasValue) {
      $health = [pscustomobject]@{ known = $true; red = [bool]$HealthRed.Value; reason = ('test_health_red=' + [bool]$HealthRed.Value) }
    } else {
      $health = Get-LearningLoopHealthRed -Root $Root
    }
    $detail.health_reason = [string]$health.reason
    if (-not [bool]$health.known) { return (Deny-LearningLoopAutoRevert 'health_unknown') }
    if (-not [bool]$health.red) { return (Deny-LearningLoopAutoRevert 'health_not_red') }
  }

  return (Allow-LearningLoopAutoRevert)
}

function Test-LearningLoopRegressionFixIdeaFiled {
  param(
    [string]$HypothesisTs = '',
    [string]$Commit = '',
    [string]$Action = ''
  )
  if ([string]::IsNullOrWhiteSpace($HypothesisTs) -or [string]::IsNullOrWhiteSpace($Commit) -or [string]::IsNullOrWhiteSpace($Action)) {
    return $false
  }

  foreach ($rec in @(Read-MetricsJsonl)) {
    if ([string]$rec.type -ne 'regression_fix_backlog') { continue }
    if ([string]$rec.hypothesis_ts -ne $HypothesisTs) { continue }
    if ([string]$rec.commit -ne $Commit) { continue }
    if ([string]$rec.action -ne $Action) { continue }
    return $true
  }

  return $false
}

function Test-LearningLoopRegressionFixCommitWorth {
  param(
    [string]$Root = '',
    [string]$Commit = ''
  )
  if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Commit)) { return $false }
  if (-not (Get-Command Test-BridgeAutoCommitWorthPath -ErrorAction SilentlyContinue)) { return $true }

  $paths = @()
  try {
    $paths = @(& git -C $Root diff-tree --no-commit-id --name-only -r $Commit 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($LASTEXITCODE -ne 0) { return $true }
  } catch {
    return $true
  }
  if ($paths.Count -eq 0) { return $true }

  foreach ($path in @($paths)) {
    if (Test-BridgeAutoCommitWorthPath -Path ([string]$path)) { return $true }
  }
  return $false
}
function Add-LearningLoopRegressionFixIdea {
  param(
    [string]$Commit = '',
    [string]$Task = '',
    [string]$HypothesisTs = '',
    [string]$Action = ''
  )

  $supported = @{
    revert_shadow        = $true
    revert_disabled      = $true
    revert_guard_blocked = $true
    revert_failed        = $true
  }
  if ([string]::IsNullOrWhiteSpace($Commit) -or [string]::IsNullOrWhiteSpace($HypothesisTs) -or -not $supported.ContainsKey($Action)) {
    return $false
  }
  if (-not (Test-LearningLoopRegressionFixCommitWorth -Root (Get-BridgeRoot) -Commit $Commit)) {
    return $false
  }
  if (Test-LearningLoopRegressionFixIdeaFiled -HypothesisTs $HypothesisTs -Commit $Commit -Action $Action) {
    return $false
  }

  $shortTask = if ([string]::IsNullOrWhiteSpace($Task)) { 'без описания' } elseif ($Task.Length -gt 80) { $Task.Substring(0, 80) + '...' } else { $Task }
  $ideaId = $null
  try {
    $ideaId = Add-Idea -Text ("Изоляция и фикс регресса: коммит $Commit ('$shortTask'), hypothesis_ts=$HypothesisTs, причина действия=$Action. Требуется изолировать регресс, доказать root cause, внести фикс или подтвердить false positive.") -From 'learning-loop' -Tags @('learning-loop','regression','fix',$Action) -Severity 'warning'
  } catch {
    return $false
  }
  if ($null -eq $ideaId -or [string]::IsNullOrWhiteSpace([string]$ideaId)) {
    return $false
  }

  Append-MetricsRecord @{
    type          = 'regression_fix_backlog'
    hypothesis_ts = $HypothesisTs
    commit        = $Commit
    action        = $Action
    backlog_id    = [string]$ideaId
  }
  return $true
}

function Invoke-VerdictActuation {
  # Closes the learning loop. 'worse' -> auto-revert the commit with a SAFE
  # `git revert` (creates an inverse commit; never reset --hard / push --force).
  # 'worked' -> cement the win into durable memory. Fail-closed: any git problem
  # aborts the revert cleanly and is logged; this never throws.
  # Returns @{ reverted=<bool>; action=<string> }.
  param(
    [string]$Verdict,
    [string]$Commit,
    [string]$Task = '',
    [string]$HypothesisTs = '',
    [int]$AfterTurns = 0,
    [bool]$AllowRevert = $true
  )
  $result = @{ reverted = $false; action = 'none' }
  if ([string]::IsNullOrWhiteSpace($Verdict)) { return $result }
  $root = Get-BridgeRoot
  $shortTask = if ($Task.Length -gt 80) { $Task.Substring(0, 80) + '...' } else { $Task }

  if ($Verdict -eq 'worked') {
    Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='cement' }
    try { Add-Memory -Text ("Закреплено (worked): '$shortTask' (коммит $Commit) подтверждено как улучшение за $AfterTurns ходов. Не откатывать; развивать этот подход.") -Tags @('learning-loop','cemented','worked') -Importance 0.85 | Out-Null } catch {}
    $result.action = 'cement'
    return $result
  }

  if ($Verdict -eq 'worse') {
    $cfg = Get-LearningLoopConfig
    if (-not $cfg.autoRevert) {
      if ([bool]$cfg.autoRevertShadow) {
        $shadowGuard = Test-LearningLoopAutoRevertGuard -Root $root -Commit $Commit -HypothesisTs $HypothesisTs -Config $cfg
        Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_shadow'; would_revert=[bool]$shadowGuard.allowed; reason=[string]$shadowGuard.reason; guard=$shadowGuard.detail }
        if ([bool]$shadowGuard.allowed) {
          try { Add-LearningLoopRegressionFixIdea -Commit $Commit -Task $Task -HypothesisTs $HypothesisTs -Action 'revert_shadow' | Out-Null } catch {}
        }
        $result.action = 'revert_shadow'; return $result
      }
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_disabled' }
      try { Add-LearningLoopRegressionFixIdea -Commit $Commit -Task $Task -HypothesisTs $HypothesisTs -Action 'revert_disabled' | Out-Null } catch {}
      $result.action = 'revert_disabled'; return $result
    }
    if (-not (Test-GitCommitExists -Root $root -Commit $Commit)) {
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_skipped'; reason='commit not found' }
      $result.action = 'revert_skipped'; return $result
    }
    $guard = Test-LearningLoopAutoRevertGuard -Root $root -Commit $Commit -HypothesisTs $HypothesisTs -Config $cfg
    if (-not [bool]$guard.allowed) {
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_guard_blocked'; reason=[string]$guard.reason; guard=$guard.detail }
      try { Add-LearningLoopRegressionFixIdea -Commit $Commit -Task $Task -HypothesisTs $HypothesisTs -Action 'revert_guard_blocked' | Out-Null } catch {}
      $result.action = 'revert_guard_blocked'; return $result
    }
    if (-not $AllowRevert) { $result.action = 'revert_deferred_cap'; return $result }   # transient: retry next cycle
    # Precondition: clean INDEX (no staged changes). The bridge repo perpetually
    # carries unstaged/untracked runtime files (turns.jsonl, metrics.jsonl, channel
    # state) — those do NOT block a surgical `git revert` of a code commit and must
    # not veto actuation (a global dirty-tree check would disable auto-revert
    # forever in production). Only a dirty index risks clobbering a mid-commit, so
    # we defer on that (transient). git revert itself fail-closes on path conflicts.
    $indexDirty = $true
    try { & git -C $root diff --cached --quiet 2>$null; $indexDirty = ($LASTEXITCODE -ne 0) } catch { $indexDirty = $true }
    if ($indexDirty) { $result.action = 'revert_skipped_dirty'; return $result }         # transient: retry next cycle
    # Safe revert: inverse commit. On any conflict, abort and leave tree clean.
    $ok = $false; $why = ''
    try {
      & git -C $root revert --no-edit $Commit 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { $ok = $true } else { $why = "git revert exit $LASTEXITCODE" }
    } catch { $why = $_.Exception.Message }
    if (-not $ok) {
      try { & git -C $root revert --abort 2>$null | Out-Null } catch {}
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_failed'; reason=$why }
      try { Add-Memory -Text ("Авто-откат регресса '$shortTask' (коммит $Commit) не прошёл: $why. Откат отменён, дерево чистое. Нужен ручной разбор.") -Tags @('learning-loop','worse','revert-failed') -Importance 0.8 | Out-Null } catch {}
      try { Add-Idea -Text ("Ручной разбор регресса: коммит $Commit ('$shortTask') ухудшил метрики, авто-откат не прошёл ($why).") -Tags @('learning-loop','regression') -Severity 'warning' | Out-Null } catch {}
      try { Add-LearningLoopRegressionFixIdea -Commit $Commit -Task $Task -HypothesisTs $HypothesisTs -Action 'revert_failed' | Out-Null } catch {}
      $result.action = 'revert_failed'; return $result
    }
    $revHead = try { (& git -C $root log -1 --format='%H' 2>$null).Trim() } catch { '' }
    Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='reverted'; revert_commit=$revHead }
    try { Add-Memory -Text ("Авто-откат (worse): коммит $Commit ('$shortTask') ухудшил метрики за $AfterTurns ходов — откат выполнен ($revHead). Подход не повторять без изменений.") -Tags @('learning-loop','worse','reverted') -Importance 0.85 | Out-Null } catch {}
    $result.reverted = $true; $result.action = 'reverted'
    return $result
  }

  return $result
}

function Invoke-PostMortem {
  # Cheap DeepSeek post-mortem on timeout/safety/rollback. Saves lesson to memory + optional idea.
  param([string]$FailureType, [string]$Task = '', [string]$Context = '', [string]$Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Task)) { return }
  $shortTask = if ($Task.Length -gt 120) { $Task.Substring(0, 120) + '...' } else { $Task }
  $failureHint = ''
  if ($FailureType -in @('safety', 'rollback')) {
    $failureHint = "ВНИМАНИЕ: тип сбоя '$FailureType' требует ОБЯЗАТЕЛЬНОГО заполнения СЦЕНАРИЙ_АТАКИ_ИЛИ_СБОЯ. Security-вердикт без временной цепочки entry→damage и списка модулей будет отклонён."
  }
  $prompt = @"
Ты анализируешь сбой задачи в системе AI-агентов (мост Claude+Codex).
Тип сбоя: $FailureType
Задача: $shortTask
Контекст: $Context
$failureHint

Ответь ТОЛЬКО в таком формате (без пояснений):
СЦЕНАРИЙ_АТАКИ_ИЛИ_СБОЯ: <обязательная временная цепочка — шаги с относительными временными метками, например T+0с, T+5с, ...: entry(что запустило цепочку) → propagation(как распространялось) → impact(на что повлияло) → damage(итоговый ущерб). ОБЯЗАТЕЛЬНО укажи конкретные модули/функции на каждом шаге. Для типа сбоя 'safety' или 'rollback': этот раздел ДОЛЖЕН быть заполнен содержательно — статический паттерн-матчинг по именам файлов или строкам кода НЕ является достаточным основанием для security-вердикта без этой цепочки. Если восстановить цепочку невозможно — напиши UNKNOWN_CHAIN.>
ЗАТРОНУТЫ_МОДУЛИ: <через запятую — все модули/файлы/функции, затронутые в цепочке выше, или NONE>
УРОК: <одно-два предложения — почему упало и что делать иначе в будущем>
ИДЕЯ: <одна строка — конкретная идея в бэклог для устранения причины, или NONE>
НЕ_ПОВТОРЯТЬ: <КОНТЕКСТ: что и при каких условиях пробовали | ПРОВАЛ: что именно пошло не так> или NONE
"@
  $raw = try { Invoke-LLM -Purpose 'postmortem' -Prompt $prompt -TimeoutSec 45 -Temperature 0.3 } catch { $null }
  if ([string]::IsNullOrWhiteSpace($raw)) { return }

  $lessonM = [regex]::Match($raw, '(?im)^УРОК:\s*(.+)$')
  $ideaM   = [regex]::Match($raw, '(?im)^ИДЕЯ:\s*(.+)$')
  $negativeM = [regex]::Match($raw, '(?im)^НЕ_ПОВТОРЯТЬ:\s*(.+)$')
  $scenarioM = [regex]::Match($raw, '(?ims)^СЦЕНАРИЙ_АТАКИ_ИЛИ_СБОЯ:\s*(.+?)(?=^[А-Я_]+:|\z)')
  $touchedM  = [regex]::Match($raw, '(?im)^ЗАТРОНУТЫ_МОДУЛИ:\s*(.+)$')

  if ($lessonM.Success) {
    $lesson  = $lessonM.Groups[1].Value.Trim()
    $memText = "[$FailureType] Задача: $shortTask — Урок: $lesson"
    try { Add-Memory -Channel $Channel -Text $memText -Tags @('lesson', $FailureType) -Source 'postmortem' -Importance 0.7 | Out-Null } catch {}
    try { Add-Message -From system -Text "🧠 Post-mortem ($FailureType): $lesson" -Kind event | Out-Null } catch {}
  }
  if ($scenarioM.Success) {
    $scenario = $scenarioM.Groups[1].Value.Trim()
    if ($scenario -and $scenario -notmatch '(?i)^(NONE|UNKNOWN_CHAIN|нет|N/A)$') {
      $memScenario = "[$FailureType] Сценарий: $scenario"
      if ($memScenario.Length -gt 700) { $memScenario = $memScenario.Substring(0, 700).Trim() }
      try { Add-Memory -Channel $Channel -Text $memScenario -Tags @('postmortem-scenario', $FailureType) -Source 'postmortem-scenario-replay' -Importance 0.75 | Out-Null } catch {}
    }
  }
  $touchedList = ''
  if ($touchedM.Success) {
    $touchedList = $touchedM.Groups[1].Value.Trim()
  }
  if ($FailureType -in @('safety', 'rollback')) {
    $hasChain = $scenarioM.Success -and $scenarioM.Groups[1].Value.Trim() -notmatch '(?i)^(NONE|UNKNOWN_CHAIN|нет|N/A)$'
    if (-not $hasChain) {
      try { Add-Message -From system -Text "⚠ Post-mortem ($FailureType): СЦЕНАРИЙ_АТАКИ_ИЛИ_СБОЯ отсутствует — security-вердикт не подтверждён (только статический паттерн)." -Kind event | Out-Null } catch {}
    }
  }
  if ($ideaM.Success) {
    $ideaText = $ideaM.Groups[1].Value.Trim()
    if ($ideaText -and $ideaText -notmatch '(?i)^none$') {
      try { Add-Idea -Text $ideaText -From 'postmortem' -Tags @('lesson','postmortem') -Status 'new' | Out-Null } catch {}
    }
  }
  if ($negativeM.Success) {
    $negative = $negativeM.Groups[1].Value.Trim()
    if ($negative -and $negative -notmatch '(?i)^none$' -and $negative -match 'КОНТЕКСТ:' -and $negative -match 'ПРОВАЛ:') {
      $negative = ($negative -replace '[\x00-\x1F\x7F]', ' ' -replace '\s+', ' ').Trim()
      if ($negative.Length -gt 700) { $negative = $negative.Substring(0, 700).Trim() }
      try { Add-Memory -Channel $Channel -Text $negative -Tags @('skill-rejected', $FailureType) -Source 'postmortem-negative' -Importance 0.65 | Out-Null } catch {}
    }
  }
  # Append a structured failure record for the Architect's meta-pattern detection.
  $failureContext = $Context
  if ($touchedList) { $failureContext = "$Context | touched_modules: $touchedList" }
  try { Add-FailureRecord -Class $FailureType -Task $shortTask -Context $failureContext -Channel $Channel } catch {}
}

# --- Failures catalogue (meta-pattern source for Architect) ---
function Get-FailuresPath { Join-Path (Get-BridgeRoot) 'memory\failures.jsonl' }

function Add-FailureRecord {
  # Append a structured failure entry. Class examples: timeout, rollback, safety, oom,
  # coder_bypass, verify_fail, doctor_abort. Used by Get-FailurePatterns to spot recurrences.
  param([string]$Class, [string]$Task = '', [string]$Context = '', [string]$Signature = '', [string]$Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Class)) { return }
  $dir = Split-Path (Get-FailuresPath) -Parent
  if (-not (Test-Path $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
  if ([string]::IsNullOrWhiteSpace($Channel)) {
    try { $Channel = Get-CurrentMemoryChannel } catch { $Channel = '' }
  }
  # Signature defaults to class + short task hash so dedup / count can group recurrences.
  if ([string]::IsNullOrWhiteSpace($Signature)) {
    $src = ($Class + '|' + ([string]$Task)).Trim()
    try {
      $sha = [System.Security.Cryptography.SHA1]::Create()
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($src)
      $h = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
      $sha.Dispose()
      $Signature = $Class + ':' + $h.Substring(0,8)
    } catch { $Signature = $Class }
  }
  $rec = [ordered]@{
    ts        = [DateTime]::UtcNow.ToString('o')
    class     = $Class
    signature = $Signature
    channel   = ([string]$Channel)
    task      = ([string]$Task)
    context   = ([string]$Context)
  }
  $line = $rec | ConvertTo-Json -Compress -Depth 4
  try { Add-Content -LiteralPath (Get-FailuresPath) -Value $line -Encoding UTF8 } catch {}
}

function Get-FailurePatterns {
  # Return top recurring failure classes/signatures over the recent window. Used by Architect
  # to detect "this class of bug keeps happening; we're missing capability X".
  param([int]$WindowHours = 168, [int]$TopN = 8)
  $p = Get-FailuresPath
  if (-not (Test-Path $p)) { return @() }
  $cutoff = [DateTime]::UtcNow.AddHours(-[Math]::Abs($WindowHours))
  $recs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $r = $line | ConvertFrom-Json } catch { continue }
    try { $ts = [DateTime]$r.ts } catch { continue }
    if ($ts -lt $cutoff) { continue }
    [void]$recs.Add($r)
  }
  if ($recs.Count -eq 0) { return @() }
  # Group by class, count, list 1-line samples (most recent 2).
  $groups = $recs | Group-Object class
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($g in $groups) {
    $samples = @($g.Group | Sort-Object ts -Descending | Select-Object -First 2 | ForEach-Object {
      $t = [string]$_.task; if ($t.Length -gt 80) { $t = $t.Substring(0,80) + '...' }
      "  [$([DateTime]$_.ts | ForEach-Object { $_.ToString('MM-dd HH:mm') })] $t"
    })
    [void]$out.Add([pscustomobject]@{
      class   = [string]$g.Name
      count   = [int]$g.Count
      samples = ($samples -join "`n")
    })
  }
  return @($out | Sort-Object -Property count -Descending | Select-Object -First $TopN)
}

function Append-DoctorEvent {
  param([string]$Event, [string]$Reason = '')
  Append-MetricsRecord @{ type='doctor_event'; event=$Event; reason=$Reason }
}

function Get-DoctorStats {
  param([int]$WindowHours = 168)
  $cutoff = [DateTime]::UtcNow.AddHours(-[Math]::Abs($WindowHours))
  $recs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($rec in @(Read-MetricsJsonl)) {
    if ([string]$rec.type -ne 'doctor_event') { continue }
    $inWindow = $false
    try { $inWindow = ([DateTime]$rec.ts).ToUniversalTime() -ge $cutoff } catch {}
    if ($inWindow) { [void]$recs.Add($rec) }
  }
  $activations   = @($recs | Where-Object { [string]$_.event -eq 'activate' })
  $rlActivations = @($activations | Where-Object { [string]$_.reason -imatch 'restart_loop' })
  $aborts        = @($recs | Where-Object { [string]$_.event -eq 'abort' })
  $completes     = @($recs | Where-Object { [string]$_.event -eq 'complete' })
  $falsePosCount = @($recs | Where-Object { [string]$_.event -eq 'false_positive' }).Count
  [pscustomobject]@{
    activations_total        = $activations.Count
    restart_loop_activations = $rlActivations.Count
    completions              = $completes.Count
    aborts                   = $aborts.Count
    false_positives          = $falsePosCount
    window_hours             = $WindowHours
  }
}
