# metrics.ps1 -- Learning Loop pt1: health metrics, hypotheses, reflection.

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
    $terminal    = @('reverted','cement','revert_disabled','revert_failed','revert_skipped')
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
  # Operator kill-switch for verdict actuation. Default ON (roadmap mandate:
  # auto-revert regressions). config.json -> { "learningLoop": { "autoRevert": false } }
  # disables auto-revert without a code change. Every git op stays fail-closed.
  $cfg = @{ autoRevert = $true }
  try {
    $cf = Join-Path (Get-BridgeRoot) 'config.json'
    if (Test-Path -LiteralPath $cf) {
      $j = [System.IO.File]::ReadAllText($cf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($j -and $j.PSObject.Properties['learningLoop']) {
        $ll = $j.learningLoop
        if ($ll.PSObject -and $ll.PSObject.Properties['autoRevert']) { $cfg.autoRevert = [bool]$ll.autoRevert }
      }
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
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_disabled' }
      $result.action = 'revert_disabled'; return $result
    }
    if (-not (Test-GitCommitExists -Root $root -Commit $Commit)) {
      Append-MetricsRecord @{ type='actuation'; hypothesis_ts=$HypothesisTs; commit=$Commit; verdict=$Verdict; action='revert_skipped'; reason='commit not found' }
      $result.action = 'revert_skipped'; return $result
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
  $prompt = @"
Ты анализируешь сбой задачи в системе AI-агентов (мост Claude+Codex).
Тип сбоя: $FailureType
Задача: $shortTask
Контекст: $Context

Ответь ТОЛЬКО в таком формате (без пояснений):
УРОК: <одно-два предложения — почему упало и что делать иначе в будущем>
ИДЕЯ: <одна строка — конкретная идея в бэклог для устранения причины, или NONE>
НЕ_ПОВТОРЯТЬ: <КОНТЕКСТ: что и при каких условиях пробовали | ПРОВАЛ: что именно пошло не так> или NONE
"@
  $raw = try { Invoke-LLM -Purpose 'postmortem' -Prompt $prompt -TimeoutSec 45 -Temperature 0.3 } catch { $null }
  if ([string]::IsNullOrWhiteSpace($raw)) { return }

  $lessonM = [regex]::Match($raw, '(?im)^УРОК:\s*(.+)$')
  $ideaM   = [regex]::Match($raw, '(?im)^ИДЕЯ:\s*(.+)$')
  $negativeM = [regex]::Match($raw, '(?im)^НЕ_ПОВТОРЯТЬ:\s*(.+)$')

  if ($lessonM.Success) {
    $lesson  = $lessonM.Groups[1].Value.Trim()
    $memText = "[$FailureType] Задача: $shortTask — Урок: $lesson"
    try { Add-Memory -Channel $Channel -Text $memText -Tags @('lesson', $FailureType) -Source 'postmortem' -Importance 0.7 | Out-Null } catch {}
    try { Add-Message -From system -Text "🧠 Post-mortem ($FailureType): $lesson" -Kind event | Out-Null } catch {}
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
  try { Add-FailureRecord -Class $FailureType -Task $shortTask -Context $Context -Channel $Channel } catch {}
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
