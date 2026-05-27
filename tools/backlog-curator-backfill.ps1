param(
  [switch]$DryRun,
  [int]$DedupThreshold = 88,
  [string]$Channel = 'main',
  [int]$FreshnessTimeoutSec = 8
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$LibDir = Join-Path $Root 'lib'

. (Join-Path $LibDir 'common.ps1')
. (Join-Path $LibDir 'channels.ps1')
. (Join-Path $LibDir 'backlog.ps1')
. (Join-Path $LibDir 'memory.ps1')

try { Set-PinnedChannel -Slug $Channel } catch {}

$Threshold = [double]$DedupThreshold / 100.0
$RunStarted = (Get-Date).ToUniversalTime()
$DecisionPath = Join-Path $Root 'control\curator-decisions.jsonl'
$ReportPath = Join-Path $Root 'control\curator-backfill-2026-05-27.log'

function Get-StatusCountsText {
  param($Items)
  $parts = @($Items | Group-Object status | Sort-Object Name | ForEach-Object {
    $name = if ([string]::IsNullOrWhiteSpace([string]$_.Name)) { '<empty>' } else { [string]$_.Name }
    "$name=$($_.Count)"
  })
  if ($parts.Count -eq 0) { return '<none>' }
  return ($parts -join ', ')
}

function Get-ExistingDecisionState {
  $state = @{
    Freshness = @{}
    FreshnessPostArgsFix = @{}
    DedupPairs = @{}
    RejudgedBrokenSha = @{}
    LegacyFreshnessChecked = 0
    LegacyFreshnessDone = 0
    LineCount = 0
  }
  if (-not (Test-Path -LiteralPath $DecisionPath)) { return $state }
  foreach ($line in (Get-Content -LiteralPath $DecisionPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $state.LineCount++
    try { $obj = $line | ConvertFrom-Json } catch { continue }
    $action = [string]$obj.action
    if ($action -in @('backfill-freshness-check', 'backfill-freshness-timeout') -and $obj.PSObject.Properties.Name -contains 'item_id') {
      $id = [string]$obj.item_id
      $state.Freshness[$id] = $true
      $isPostArgsFix = $false
      try { $isPostArgsFix = [bool]$obj.git_args_bugfix } catch { $isPostArgsFix = $false }
      if ($isPostArgsFix) {
        $state.FreshnessPostArgsFix[$id] = $true
      } else {
        $state.LegacyFreshnessChecked = [int]$state.LegacyFreshnessChecked + 1
        try {
          if ([bool]$obj.done) { $state.LegacyFreshnessDone = [int]$state.LegacyFreshnessDone + 1 }
        } catch {}
      }
    } elseif ($action -eq 'backfill-dedup-pair') {
      $a = [string]$obj.id_a
      $b = [string]$obj.id_b
      if (-not [string]::IsNullOrWhiteSpace($a) -and -not [string]::IsNullOrWhiteSpace($b)) {
        $ids = @($a, $b) | Sort-Object
        $state.DedupPairs[($ids -join '|')] = $true
      }
    } elseif ($action -eq 'backfill-rejudge-broken-sha' -and $obj.PSObject.Properties.Name -contains 'item_id') {
      $state.RejudgedBrokenSha[[string]$obj.item_id] = $true
    }
  }
  return $state
}

function Write-Decision {
  param($Record)
  if ($DryRun) {
    Write-Host ("DRYRUN decision: " + ($Record | ConvertTo-Json -Compress -Depth 10))
    return
  }
  Write-BacklogJsonLine $Record
}

function Get-TextPreview {
  param([string]$Text, [int]$Max = 120)
  $s = ([string]$Text -replace '\s+', ' ').Trim()
  if ($s.Length -le $Max) { return $s }
  return $s.Substring(0, $Max)
}

function Invoke-FreshnessWithTimeout {
  param([string]$ItemId, [int]$TimeoutSec)
  $job = $null
  try {
    $job = Start-Job -ArgumentList $Root, $Channel, $ItemId -ScriptBlock {
      param($JobRoot, $JobChannel, $JobItemId)
      $lib = Join-Path $JobRoot 'lib'
      . (Join-Path $lib 'common.ps1')
      . (Join-Path $lib 'channels.ps1')
      . (Join-Path $lib 'backlog.ps1')
      try { Set-PinnedChannel -Slug $JobChannel } catch {}
      Test-IdeaStillRelevant -ItemId $JobItemId
    }
    $completed = Wait-Job -Job $job -Timeout $TimeoutSec
    if (-not $completed) {
      Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
      return [pscustomobject]@{ timed_out = $true; done = $false; sha = $null; reason = "timeout after ${TimeoutSec}s" }
    }
    $result = Receive-Job -Job $job -ErrorAction Stop
    if ($result -is [array]) { $result = $result | Select-Object -Last 1 }
    if (-not $result) { return [pscustomobject]@{ timed_out = $false; done = $false; sha = $null; reason = 'empty-result' } }
    return [pscustomobject]@{
      timed_out = $false
      done = [bool]$result.done
      sha = if ($result.PSObject.Properties.Name -contains 'sha') { $result.sha } else { $null }
      reason = if ($result.PSObject.Properties.Name -contains 'reason') { [string]$result.reason } else { 'no reason' }
    }
  } catch {
    return [pscustomobject]@{ timed_out = $false; done = $false; sha = $null; reason = ('error: ' + [string]$_.Exception.Message) }
  } finally {
    if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
  }
}

function Set-ItemAutoResolved {
  param([string]$ItemId, [string]$Sha, [string]$Reason)
  if ($DryRun) { return $false }
  $itemsNow = @(Get-Backlog)
  $changed = $false
  foreach ($item in $itemsNow) {
    if ([string]$item.id -ne $ItemId) { continue }
    $item | Add-Member -NotePropertyName status -NotePropertyValue 'auto-resolved' -Force
    $item | Add-Member -NotePropertyName resolved_by_sha -NotePropertyValue $Sha -Force
    $item | Add-Member -NotePropertyName resolved_reason -NotePropertyValue $Reason -Force
    $changed = $true
    break
  }
  if ($changed) { Save-Backlog $itemsNow }
  return $changed
}

function Get-ItemByIdLocal {
  param([string]$ItemId)
  foreach ($item in @(Get-Backlog)) {
    if ([string]$item.id -eq $ItemId) { return $item }
  }
  return $null
}

function Test-ValidCuratorSha {
  param([string]$Sha)
  return (-not [string]::IsNullOrWhiteSpace($Sha) -and $Sha -match '^[0-9a-f]{7,40}$')
}

function Ensure-ItemEmbedding {
  param($Item)
  try {
    if ($Item.PSObject.Properties.Name -contains 'embedding' -and $Item.embedding -and @($Item.embedding).Count -gt 0) {
      return ,@($Item.embedding)
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace([string]$Item.text)) { return $null }
  $vec = Get-Embedding -Text ([string]$Item.text) -TaskType 'RETRIEVAL_DOCUMENT'
  if (-not $vec) { return $null }
  if (-not $DryRun) {
    $Item | Add-Member -NotePropertyName embedding -NotePropertyValue (@($vec)) -Force
    $script:EmbeddingsAdded++
  }
  return ,@($vec)
}

$existing = Get-ExistingDecisionState
$lineCountBefore = [int]$existing.LineCount
$items = @(Get-Backlog)
$beforeCounts = Get-StatusCountsText -Items $items

$freshnessTotal = 0
$freshnessSkippedAlreadyAudited = 0
$freshnessTimeouts = 0
$freshnessDone = New-Object 'System.Collections.Generic.List[object]'
$freshnessNotDone = New-Object 'System.Collections.Generic.List[object]'
$rejudgeTotal = 0
$rejudgeSkipped = 0
$rejudgeFixed = 0
$rejudgeFailed = 0

Write-Host "Backlog curator full backfill"
Write-Host "channel=$Channel dry_run=$DryRun threshold=$Threshold"
Write-Host "items_total=$($items.Count)"
Write-Host "status_counts_before={$beforeCounts}"
Write-Host "decision_lines_before=$lineCountBefore"

foreach ($item in @($items | Where-Object { [string]$_.status -eq 'approved' })) {
  $id = [string]$item.id
  if ([string]::IsNullOrWhiteSpace($id)) { continue }
  if ($item.PSObject.Properties.Name -contains 'resolved_by_sha' -and -not [string]::IsNullOrWhiteSpace([string]$item.resolved_by_sha)) {
    $freshnessSkippedAlreadyAudited++
    continue
  }
  if ($existing.FreshnessPostArgsFix.ContainsKey($id)) {
    $freshnessSkippedAlreadyAudited++
    continue
  }

  $freshnessTotal++
  Write-Host "freshness[$freshnessTotal]: $id"
  $result = Invoke-FreshnessWithTimeout -ItemId $id -TimeoutSec $FreshnessTimeoutSec
  $ts = (Get-Date).ToUniversalTime().ToString('o')
  if ([bool]$result.timed_out) {
    $freshnessTimeouts++
    Write-Decision ([ordered]@{
      ts = $ts
      action = 'backfill-freshness-timeout'
      item_id = $id
      done = $false
      sha = $null
      reason = [string]$result.reason
      git_args_bugfix = $true
    })
    [void]$freshnessNotDone.Add([pscustomobject]@{ id = $id; reason = [string]$result.reason })
    continue
  }

  $done = [bool]$result.done
  $sha = if ($null -ne $result.sha) { [string]$result.sha } else { $null }
  $reason = [string]$result.reason
  Write-Decision ([ordered]@{
    ts = $ts
    action = 'backfill-freshness-check'
    item_id = $id
    done = $done
    sha = $sha
    reason = $reason
    git_args_bugfix = $true
  })
  if ($done) {
    [void]$freshnessDone.Add([pscustomobject]@{ id = $id; sha = $sha; reason = $reason })
    [void](Set-ItemAutoResolved -ItemId $id -Sha $sha -Reason $reason)
  } else {
    [void]$freshnessNotDone.Add([pscustomobject]@{ id = $id; reason = $reason })
  }
}

$items = @(Get-Backlog)
foreach ($item in @($items | Where-Object { $_.PSObject.Properties.Name -contains 'auto_curator' -and $null -ne $_.auto_curator })) {
  $id = [string]$item.id
  if ([string]::IsNullOrWhiteSpace($id)) { continue }
  $oldSha = $null
  try {
    if ($item.auto_curator.PSObject.Properties.Name -contains 'judged_at_sha') { $oldSha = [string]$item.auto_curator.judged_at_sha }
  } catch {}
  if (Test-ValidCuratorSha -Sha $oldSha) { continue }
  if ($existing.RejudgedBrokenSha.ContainsKey($id)) {
    $rejudgeSkipped++
    continue
  }

  $rejudgeTotal++
  Write-Host "rejudge_broken_sha[$rejudgeTotal]: $id"
  if ($DryRun) {
    Write-Decision ([ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      action = 'backfill-rejudge-broken-sha'
      item_id = $id
      old_sha_preview = (Get-TextPreview -Text $oldSha -Max 80)
      dry_run = $true
    })
    continue
  }

  $result = Invoke-BacklogCurator -ItemId $id
  $updated = Get-ItemByIdLocal -ItemId $id
  $newSha = $null
  try {
    if ($updated -and $updated.auto_curator.PSObject.Properties.Name -contains 'judged_at_sha') {
      $newSha = [string]$updated.auto_curator.judged_at_sha
    }
  } catch {}
  $validNow = Test-ValidCuratorSha -Sha $newSha
  if ($validNow) { $rejudgeFixed++ } else { $rejudgeFailed++ }
  Write-Decision ([ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    action = 'backfill-rejudge-broken-sha'
    item_id = $id
    old_sha_preview = (Get-TextPreview -Text $oldSha -Max 80)
    new_sha = $newSha
    valid = $validNow
    verdict = if ($result -and $result.PSObject.Properties.Name -contains 'verdict') { [string]$result.verdict } else { $null }
    reason = if ($result -and $result.PSObject.Properties.Name -contains 'reason') { [string]$result.reason } else { $null }
  })
}

$items = @(Get-Backlog)
$script:EmbeddingsAdded = 0
$vectors = @{}
$embeddingErrors = New-Object 'System.Collections.Generic.List[string]'

foreach ($item in $items) {
  $id = [string]$item.id
  if ([string]::IsNullOrWhiteSpace($id)) { continue }
  $vec = Ensure-ItemEmbedding -Item $item
  if ($vec) { $vectors[$id] = $vec }
  else { [void]$embeddingErrors.Add($id) }
}

if (-not $DryRun -and $script:EmbeddingsAdded -gt 0) {
  Save-Backlog $items
}

$dedupPairs = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $items.Count; $i++) {
  $a = $items[$i]
  $idA = [string]$a.id
  if ([string]::IsNullOrWhiteSpace($idA) -or -not $vectors.ContainsKey($idA)) { continue }
  for ($j = $i + 1; $j -lt $items.Count; $j++) {
    $b = $items[$j]
    $idB = [string]$b.id
    if ([string]::IsNullOrWhiteSpace($idB) -or -not $vectors.ContainsKey($idB)) { continue }
    $similarity = [double](Get-CosineSimilarity -A $vectors[$idA] -B $vectors[$idB])
    if ($similarity -lt $Threshold) { continue }

    $ids = @($idA, $idB) | Sort-Object
    $pairKey = $ids -join '|'
    $pair = [pscustomobject]@{
      id_a = $idA
      id_b = $idB
      similarity = $similarity
      text_a_preview = Get-TextPreview -Text ([string]$a.text)
      text_b_preview = Get-TextPreview -Text ([string]$b.text)
    }
    [void]$dedupPairs.Add($pair)
    if (-not $existing.DedupPairs.ContainsKey($pairKey)) {
      Write-Decision ([ordered]@{
        ts = (Get-Date).ToUniversalTime().ToString('o')
        action = 'backfill-dedup-pair'
        id_a = $idA
        id_b = $idB
        similarity = $similarity
        text_a_preview = $pair.text_a_preview
        text_b_preview = $pair.text_b_preview
      })
      $existing.DedupPairs[$pairKey] = $true
    }
  }
}

$itemsFinal = @(Get-Backlog)
$finalCounts = Get-StatusCountsText -Items $itemsFinal
$lineCountAfter = $lineCountBefore
if (Test-Path -LiteralPath $DecisionPath) {
  $lineCountAfter = (Get-Content -LiteralPath $DecisionPath -Encoding UTF8 | Measure-Object).Count
}
$newDecisions = [int]$lineCountAfter - [int]$lineCountBefore

$reportLines = New-Object 'System.Collections.Generic.List[string]'
[void]$reportLines.Add("Backlog curator backfill 2026-05-27")
[void]$reportLines.Add("Started: $($RunStarted.ToString('o'))")
[void]$reportLines.Add("Finished: $((Get-Date).ToUniversalTime().ToString('o'))")
[void]$reportLines.Add("Channel: $Channel")
[void]$reportLines.Add("DryRun: $DryRun")
[void]$reportLines.Add("Before: $beforeCounts")
[void]$reportLines.Add("After: $finalCounts")
[void]$reportLines.Add("")
[void]$reportLines.Add('Re-run after $Args bugfix:')
[void]$reportLines.Add("- previous_broken_freshness_checked: $($existing.LegacyFreshnessChecked)")
[void]$reportLines.Add("- previous_broken_freshness_done: $($existing.LegacyFreshnessDone)")
[void]$reportLines.Add("- rerun_checked: $freshnessTotal")
[void]$reportLines.Add("- rerun_done: $($freshnessDone.Count)")
[void]$reportLines.Add("- rerun_not_done: $($freshnessNotDone.Count)")
[void]$reportLines.Add("- rerun_timeouts: $freshnessTimeouts")
[void]$reportLines.Add("- rejudged_broken_sha: $rejudgeTotal")
[void]$reportLines.Add("- rejudge_skipped_already_done: $rejudgeSkipped")
[void]$reportLines.Add("- rejudge_fixed: $rejudgeFixed")
[void]$reportLines.Add("- rejudge_failed: $rejudgeFailed")
[void]$reportLines.Add("")
[void]$reportLines.Add("Freshness pass 2:")
[void]$reportLines.Add("- checked: $freshnessTotal")
[void]$reportLines.Add("- skipped_already_audited_or_resolved: $freshnessSkippedAlreadyAudited")
[void]$reportLines.Add("- done: $($freshnessDone.Count)")
[void]$reportLines.Add("- not_done: $($freshnessNotDone.Count)")
[void]$reportLines.Add("- timeouts: $freshnessTimeouts")
foreach ($r in $freshnessDone) {
  [void]$reportLines.Add("- auto-resolved $($r.id): $($r.sha) - $($r.reason)")
}
[void]$reportLines.Add("")
[void]$reportLines.Add("Dedup pairs found:")
[void]$reportLines.Add("- threshold: $Threshold")
[void]$reportLines.Add("- pairs: $($dedupPairs.Count)")
foreach ($p in @($dedupPairs | Sort-Object -Property @{Expression='similarity';Descending=$true}, id_a, id_b)) {
  [void]$reportLines.Add(("- {0} <-> {1}: {2:N3} | {3} || {4}" -f $p.id_a, $p.id_b, [double]$p.similarity, $p.text_a_preview, $p.text_b_preview))
}
[void]$reportLines.Add("")
[void]$reportLines.Add("Embedding cache:")
[void]$reportLines.Add("- added_to_items: $script:EmbeddingsAdded")
[void]$reportLines.Add("- errors: $($embeddingErrors.Count)")
foreach ($id in $embeddingErrors) { [void]$reportLines.Add("- embedding-error: $id") }
[void]$reportLines.Add("")
[void]$reportLines.Add("Final status counts:")
[void]$reportLines.Add($finalCounts)
[void]$reportLines.Add("")
[void]$reportLines.Add("new_decisions_logged=$newDecisions")

if ($DryRun) {
  Write-Host "DRYRUN report path: $ReportPath"
  $reportLines | ForEach-Object { Write-Host $_ }
} else {
  $reportContent = ($reportLines -join "`r`n") + "`r`n"
  [System.IO.File]::WriteAllText($ReportPath, $reportContent, (New-Object System.Text.UTF8Encoding($true)))
}

Write-Host "freshness_checks_total=$freshnessTotal"
Write-Host "freshness_skipped_already_audited_or_resolved=$freshnessSkippedAlreadyAudited"
Write-Host "freshness_done=$($freshnessDone.Count)"
Write-Host "freshness_not_done=$($freshnessNotDone.Count)"
Write-Host "rejudged_broken_sha=$rejudgeTotal"
Write-Host "rejudge_fixed=$rejudgeFixed"
Write-Host "rejudge_failed=$rejudgeFailed"
Write-Host "dedup_pairs_found=$($dedupPairs.Count)"
Write-Host "embedding_errors=$($embeddingErrors.Count)"
Write-Host "new_decisions_logged=$newDecisions"
Write-Host "final_status_counts={$finalCounts}"
