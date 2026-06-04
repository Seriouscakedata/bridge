# backlog-crud.ps1 -- public backlog CRUD helpers.
#region Public backlog CRUD API
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
  Ensure-BacklogPathFunction
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

  $intakeGate = $null
  try { $intakeGate = Invoke-BacklogIntakeGate -Record ([pscustomobject]$rec) } catch { $intakeGate = $null }
  $intakeGateApplies = $false
  try { $intakeGateApplies = [bool](Get-BacklogPackObjectValue -Obj $intakeGate -Name 'gated' -Default $false) } catch { $intakeGateApplies = $false }
  if ($intakeGateApplies -and [string]$intakeGate.action -eq 'dedup' -and -not [string]::IsNullOrWhiteSpace([string]$intakeGate.matched_id)) {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'intake-dedup'
      new_text = [string]$Text
      matched_id = [string]$intakeGate.matched_id
      reason = [string]$intakeGate.reason
      evidence = $intakeGate.evidence
    })
    Write-LastAddIdeaMarker ([ordered]@{
      ts = $now
      deduped = $true
      intake_gate = $true
      id = [string]$intakeGate.matched_id
      matched_id = [string]$intakeGate.matched_id
      reason = [string]$intakeGate.reason
    })
    return [string]$intakeGate.matched_id
  }
  if ($intakeGateApplies -and [string]$intakeGate.action -in @('allow','hold','drop')) {
    $finalStatus = [string]$intakeGate.status
    if (-not [string]::IsNullOrWhiteSpace($finalStatus)) { $rec['status'] = $finalStatus }
    $rec['intake_gate'] = [ordered]@{
      action = [string]$intakeGate.action
      requested_status = [string]$Status
      final_status = [string]$rec['status']
      reason = [string]$intakeGate.reason
      model = 'deterministic-intake-v1'
      ts = $now
      evidence = $intakeGate.evidence
    }
    if ([string]$intakeGate.action -eq 'hold') {
      $rec['held_reason'] = [string]$intakeGate.reason
    } elseif ([string]$intakeGate.action -eq 'drop') {
      $rec['auto_curator'] = [ordered]@{
        verdict = 'drop'
        confidence = 1.0
        reason = [string]$intakeGate.reason
        model = 'deterministic-intake-v1'
        ts = $now
        judged_at_sha = (Get-BacklogCurrentSha)
      }
    }
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
  $backlogPathForAppend = Resolve-BacklogPathValue
  Invoke-BacklogLocked ({ [System.IO.File]::AppendAllText($backlogPathForAppend, ($line + "`n"), $u8NoBomA) }.GetNewClosure()) | Out-Null

  $curatorStarted = $false
  $intakeStopsCurator = ($intakeGateApplies -and [string]$intakeGate.action -in @('hold','drop'))
  if ((-not $SkipCurator) -and (-not $intakeStopsCurator)) {
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
  Ensure-BacklogPathFunction
  $p = Resolve-BacklogPathValue
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
  Ensure-BacklogPathFunction
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  # 2026-05-28: resolve path before closure (see Add-Idea note about scope).
  $backlogPathForSave = Resolve-BacklogPathValue
  # Parser.ParseFile in caller scopes can leave command lookup brittle for
  # GetNewClosure(); capture the function explicitly like the RMW helpers below.
  $writeBacklogAtomicFileFn = ${function:Write-BacklogAtomicFile}
  Invoke-BacklogLocked ({ & $writeBacklogAtomicFileFn -Path $backlogPathForSave -Content $content }.GetNewClosure()) | Out-Null
}

function Set-Idea {
  # Edit a backlog item. Pass $null to leave a field unchanged.
  param([string]$Id, $Status = $null, $Text = $null, $IncrementAttempts = $false, [bool]$ClearAutoCurator = $false, [string]$Reason = $null)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  # H2 FIX (2026-05-31 load audit): the read-modify-write was NOT transactional. Get-Backlog (read)
  # and Save-Backlog (write) each took the lock independently, so a concurrent Set-Idea / curator /
  # packer landing between them caused a LOST UPDATE -- a status mutation (approved->running, or a
  # curator approval) silently overwritten, leaving a task re-claimed twice or stuck forever. Under
  # 100 queued items the rewrite window is large and collisions frequent. Hold the bridge lock across
  # the WHOLE RMW; the named mutex is thread-reentrant so Save-Backlog's nested lock is safe.
  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $currentShaFn = ${function:Get-BacklogCurrentSha}
  return (Invoke-BacklogLocked ({
  $items = @(& $getBacklogFn)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $found = $true
    if ($ClearAutoCurator) {
      foreach ($prop in @('auto_curator', 'resolved_by_sha', 'resolved_reason')) {
        try {
          if ($i.PSObject.Properties.Name -contains $prop) { $i.PSObject.Properties.Remove($prop) }
        } catch {}
      }
    }
    if ($null -ne $Status) {
      $statusText = [string]$Status
      $i | Add-Member -NotePropertyName status -NotePropertyValue $statusText -Force
      if ($statusText -eq 'approved') {
        $i | Add-Member -NotePropertyName approved_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $i | Add-Member -NotePropertyName approved_at_sha -NotePropertyValue (& $currentShaFn) -Force
      } elseif ($statusText -eq 'auto-dropped' -and -not [string]::IsNullOrWhiteSpace($Reason)) {
        $manual = [ordered]@{
          verdict = 'drop'
          confidence = 1.0
          reason = [string]$Reason
          model = 'manual'
          ts = (Get-Date).ToUniversalTime().ToString('o')
          judged_at_sha = (& $currentShaFn)
        }
        $i | Add-Member -NotePropertyName auto_curator -NotePropertyValue ([pscustomobject]$manual) -Force
      }
    }
    if ($null -ne $Text -and -not [string]::IsNullOrWhiteSpace([string]$Text)) { $i | Add-Member -NotePropertyName text -NotePropertyValue ([string]$Text) -Force }
    if ($IncrementAttempts) {
      $a = 0; try { $a = [int]$i.attempts } catch {}
      $i | Add-Member -NotePropertyName attempts -NotePropertyValue ($a + 1) -Force
    }
    break
  }
  if (-not $found) { return $false }
  & $saveBacklogFn $items
  return $true
  }.GetNewClosure()))
}

function Remove-Idea {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $i | Add-Member -NotePropertyName status -NotePropertyValue 'rejected' -Force
    $i | Add-Member -NotePropertyName rejected_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $found = $true
    break
  }
  if (-not $found) { return $false }
  Save-Backlog $items
  return $true
}

function Set-BacklogObjectProperty {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()]$Value
  )
  if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Name)) { return }
  if ($Item.PSObject.Properties.Name -contains $Name) {
    $Item.PSObject.Properties[$Name].Value = $Value
  } else {
    $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
  }
}

function Get-IdeaById {
  param([string]$Id)
  foreach ($i in @(Get-Backlog)) { if ([string]$i.id -eq $Id) { return $i } }
  return $null
}

#endregion Public backlog CRUD API
