# 20-store.ps1 -- Backlog append-log storage: add/read/save ideas.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function Add-Idea {
  # Append a backlog idea. Returns a string id. On dedup returns the matched existing id.
  param(
    [string]$Text,
    [string]$From = 'agent',
    [string[]]$Tags = @(),
    [string]$Status = 'new',
    [double]$Score = 0.0,
    [string]$Project = '',
    [string]$Scope = 'bridge',
    # 2026-05-28: severity ('critical' | 'warning' | 'info' | '') -- used by the picker
    # so audit findings outrank regular ideas (critical before warning before info before plain).
    [ValidateSet('critical','warning','info','')]
    [string]$Severity = '',
    [switch]$SkipCurator
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $now = (Get-Date).ToUniversalTime().ToString('o')

  $keep = [pscustomobject]@{ action = 'ok'; matched_id = $null; similarity = 0.0; similar_to = @() }
  if (-not $SkipCurator) {
    try { $keep = Test-IdeaShouldKeep -Text $Text } catch {}
  }

  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'dedup' -and -not [string]::IsNullOrWhiteSpace([string]$keep.matched_id)) {
    $items = @(Get-Backlog)
    $matched = $null
    foreach ($i in $items) {
      if ([string]$i.id -eq [string]$keep.matched_id) { $matched = $i; break }
    }
    if ($matched) {
      $matched | Add-Member -NotePropertyName ts -NotePropertyValue $now -Force
      $count = 0
      try {
        if ($matched.PSObject.Properties.Name -contains 'seen_again_count' -and $null -ne $matched.seen_again_count) {
          $count = [int]$matched.seen_again_count
        }
      } catch { $count = 0 }
      $matched | Add-Member -NotePropertyName seen_again_count -NotePropertyValue ($count + 1) -Force
      Save-Backlog $items
    }
    Write-BacklogJsonLine ([ordered]@{
      ts = $now; action = 'dedup'; new_text = [string]$Text; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity
    })
    Write-LastAddIdeaMarker ([ordered]@{
      ts = $now; deduped = $true; id = [string]$keep.matched_id; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity
    })
    return [string]$keep.matched_id
  }

  # Anti-junk: refuse to re-file an idea near-identical to one the curator SUBSTANTIVELY rejected
  # within dedupDroppedDays — this kills the propose->drop->propose loop. Logged, not stored.
  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'rejected-recently') {
    Write-BacklogJsonLine ([ordered]@{ ts = $now; action = 'rejected-recently'; new_text = [string]$Text; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity })
    Write-LastAddIdeaMarker ([ordered]@{ ts = $now; rejected_recently = $true; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity })
    return $null
  }

  $rec = [ordered]@{
    id       = [guid]::NewGuid().ToString('N')
    ts       = $now
    from     = $From
    status   = $Status
    tags     = @($Tags)
    attempts = 0
    score    = $Score
    project  = $Project
    scope    = $Scope
    text     = [string]$Text
  }
  if (-not [string]::IsNullOrWhiteSpace($Severity)) {
    $rec.severity = ([string]$Severity).ToLowerInvariant()
  }
  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'similar') {
    $rec.similar_to = @($keep.similar_to)
  }
  # 2026-05-27: critic-flagged fix. Same BOM issue as in Write-BacklogJsonLine
  # plus a real risk: $rec is a hashtable here (fresh, not from ConvertFrom-Json
  # so no ETS-graph), but consumers re-read via Get-Backlog → PSCustomObject;
  # downstream Save-Backlog also uses Depth 10 — both lowered to 6.
  $line = ($rec | ConvertTo-Json -Compress -Depth 6)
  $u8NoBomA = New-Object System.Text.UTF8Encoding($false)
  # 2026-05-28: resolve the backlog path BEFORE building the closure. .GetNewClosure()
  # captures variables from the enclosing scope but NOT functions — when the
  # closure is later invoked via `& $ScriptBlock` from Invoke-BacklogLocked
  # (which runs in a child scope), Get-BacklogPath isn't visible there. Audit
  # findings dropped silently with "Get-BacklogPath not recognized" every time
  # the helper was loaded via inline dot-source (audit.ps1, curator launcher).
  # Resolving up-front captures the path as a value and sidesteps the lookup.
  $backlogPathForAppend = Get-BacklogPath
  Invoke-BacklogLocked ({ [System.IO.File]::AppendAllText($backlogPathForAppend, ($line + "`n"), $u8NoBomA) }.GetNewClosure()) | Out-Null

  $curatorStarted = $false
  if (-not $SkipCurator) {
    $curatorStarted = Start-BacklogCuratorJob -ItemId ([string]$rec.id)
  }
  Write-LastAddIdeaMarker ([ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    deduped = $false
    id = [string]$rec.id
    similar_to = @($rec.similar_to)
    curator_started = [bool]$curatorStarted
  })
  try { Request-BacklogPackIfNeeded -NewItemId ([string]$rec.id) | Out-Null } catch {}
  return [string]$rec.id
}

function Get-Backlog {
  # 2026-06-01 ROOT FIX (re-claim loop): backlog.jsonl is an append-log, so a task can have MULTIPLE
  # lines with the same id (status transitions: running -> approved -> done, plus operator re-adds /
  # concurrent writes from 3 drivers + curator + packer on the OneDrive-hosted file). The old reader
  # returned EVERY line as a separate item, so a stale 'approved' duplicate survived next to a fresh
  # 'done' line — the claim picker saw the 'approved' copy and re-ran an already-finished task forever
  # (observed: redesign-rest 16/18 delivered + closed, yet re-claimed every cycle; 23 duplicate ids in
  # the file). Fold by id with LAST-line-wins so each id collapses to its newest status. Save-Backlog
  # then rewrites the folded set, healing the duplicates on the next mutation.
  $p = Get-BacklogPath
  if (-not (Test-Path $p)) { return @() }
  $byId = New-Object 'System.Collections.Specialized.OrderedDictionary'
  $noId = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $i = $line | ConvertFrom-Json } catch { continue }
    $iid = ''
    try { $iid = [string]$i.id } catch { $iid = '' }
    if ([string]::IsNullOrWhiteSpace($iid)) { [void]$noId.Add($i); continue }
    # last line for this id wins; keep first-seen ORDER so the picker's ordering is stable
    if ($byId.Contains($iid)) { $byId[$iid] = $i } else { $byId.Add($iid, $i) }
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in $byId.Keys) { [void]$out.Add($byId[$k]) }
  foreach ($v in $noId) { [void]$out.Add($v) }
  return @($out.ToArray())
}

function Save-Backlog {
  # 2026-05-27: Depth 10 → 6. Items here come from Get-Backlog (PSCustomObject
  # from ConvertFrom-Json) — depth 10 on PSCO can recurse into ETS graph. Item
  # schema actual depth ≤ 3 (id/text/status/auto_curator{verdict/reason/...}),
  # so 6 is safe and gives margin.
  param($Items)
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  # 2026-05-28: resolve path before closure (see Add-Idea note about scope).
  $backlogPathForSave = Get-BacklogPath
  Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path $backlogPathForSave -Content $content }.GetNewClosure()) | Out-Null
}
