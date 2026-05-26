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

function Get-LastSnapshot {
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

    $dPct = $afterStats.timeout_pct - [double]$bl.timeout_pct
    $dSec = if ([double]$bl.avg_sec -gt 0) { ($afterStats.avg_sec - [double]$bl.avg_sec) / [double]$bl.avg_sec } else { 0 }

    $verdict = 'no_effect'
    if ($dPct -lt -0.05 -or $dSec -lt -0.15) { $verdict = 'worked' }
    elseif ($dPct -gt 0.05 -or $dSec -gt 0.15) { $verdict = 'worse' }

    Append-MetricsRecord @{
      type          = 'verdict'
      hypothesis_ts = $hyp.ts
      commit        = $hyp.commit
      task          = $hyp.task
      verdict       = $verdict
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
