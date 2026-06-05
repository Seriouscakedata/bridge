# backlog-dedup.ps1 -- idea deduplication, learning, relevance, and queue hygiene helpers.
#region Idea deduplication, learning, relevance, and queue hygiene
if (-not (Get-Command Normalize-BacklogGovernorTouchSet -ErrorAction SilentlyContinue)) {
  $script:BacklogDedupGovernorPath = Join-Path $PSScriptRoot 'backlog-governor.ps1'
  if (Test-Path -LiteralPath $script:BacklogDedupGovernorPath) {
    . $script:BacklogDedupGovernorPath
  }
}
function Test-IdeaShouldKeep {
  param([string]$Text)
  $ok = [pscustomobject]@{ action = 'ok'; matched_id = $null; similarity = 0.0; similar_to = @() }
  try {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $ok }
    Ensure-BacklogMemoryLoaded
    if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) { return $ok }
    if (-not (Get-Command Get-CosineSimilarity -ErrorAction SilentlyContinue)) { return $ok }

    $qvec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_QUERY'
    if (-not $qvec) { return $ok }

    $items = @(Get-Backlog)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-30)
    $dropDays = 30
    try { $dropDays = [int](Get-AutonomySettings).dedupDroppedDays } catch {}
    $dropCut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($dropDays))
    $dropNoise = '(?i)(mojibake|cleanup|a/b[- ]?test|rerun|pre-[a-z0-9]|encoding fix|scenario|\btest\b|времен)'
    $dirty = $false
    $bestId = $null
    $bestSim = 0.0
    $bestDropId = $null
    $bestDropSim = 0.0
    $similarIds = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in $items) {
      $status = [string]$item.status
      $eligible = ($status -in @('new', 'approved', 'held'))
      if (-not $eligible -and $status -eq 'done') {
        try {
          $its = [datetime]::Parse([string]$item.ts).ToUniversalTime()
          $eligible = ($its -ge $cutoff)
        } catch { $eligible = $false }
      }
      # SUBSTANTIVE recent curator rejections — tracked separately so we refuse to re-propose junk
      # the curator already refused. Housekeeping/manual/noise drops do NOT count (the idea was valid,
      # only the encoding/test-run was bad), so they never block a legitimate re-proposal.
      $isDrop = $false
      if (-not $eligible -and ($status -in @('auto-dropped','rejected')) -and $dropDays -gt 0) {
        $ac = $item.auto_curator
        if ($ac -and -not [string]::IsNullOrWhiteSpace([string]$ac.model) -and ([string]$ac.model -ne 'manual') -and (([string]$ac.reason) -notmatch $dropNoise)) {
          try { if ([datetime]::Parse([string]$item.ts).ToUniversalTime() -ge $dropCut) { $isDrop = $true } } catch {}
        }
      }
      if (-not $eligible -and -not $isDrop) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$item.text)) { continue }

      $ivec = $null
      try {
        if ($item.PSObject.Properties.Name -contains 'embedding' -and $item.embedding) { $ivec = @($item.embedding) }
      } catch {}
      if (-not $ivec -or $ivec.Count -eq 0) {
        $ivec = Get-Embedding -Text ([string]$item.text) -TaskType 'RETRIEVAL_DOCUMENT'
        if (-not $ivec) { continue }
        $item | Add-Member -NotePropertyName embedding -NotePropertyValue (@($ivec)) -Force
        $dirty = $true
      }
      $sim = [double](Get-CosineSimilarity -A $qvec -B $ivec)
      if ($isDrop) {
        if ($sim -gt $bestDropSim) { $bestDropSim = $sim; $bestDropId = [string]$item.id }
      } else {
        if ($sim -gt $bestSim) { $bestSim = $sim; $bestId = [string]$item.id }
        if ($sim -ge 0.70 -and $sim -lt 0.88) { [void]$similarIds.Add([string]$item.id) }
      }
    }
    if ($dirty) { Save-Backlog $items }

    if ($bestId -and $bestSim -ge 0.88) {
      return [pscustomobject]@{ action = 'dedup'; matched_id = $bestId; similarity = $bestSim; similar_to = @() }
    }
    if ($bestDropId -and $bestDropSim -ge 0.85) {
      return [pscustomobject]@{ action = 'rejected-recently'; matched_id = $bestDropId; similarity = $bestDropSim; similar_to = @() }
    }
    if ($similarIds.Count -gt 0) {
      return [pscustomobject]@{ action = 'similar'; matched_id = $bestId; similarity = $bestSim; similar_to = @($similarIds.ToArray()) }
    }
    return $ok
  } catch {
    return $ok
  }
}

#region Deterministic backlog supersede helpers
function Get-BacklogDedupObjectValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null
  )
  if (Get-Command Get-BacklogGovernorObjectValue -ErrorAction SilentlyContinue) {
    return (Get-BacklogGovernorObjectValue -Object $Object -Names $Names -Default $Default)
  }
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($name in $Names) {
      foreach ($key in @($Object.Keys)) {
        if ([string]::Equals([string]$key, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
          return $Object[$key]
        }
      }
    }
    return $Default
  }
  foreach ($name in $Names) {
    $prop = @($Object.PSObject.Properties | Where-Object {
      [string]::Equals([string]$_.Name, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($prop.Count -gt 0) { return $prop[0].Value }
  }
  return $Default
}

function Set-BacklogDedupObjectValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$false)]$Value
  )
  if ($null -eq $Object) { return }
  if ($Object -is [System.Collections.IDictionary]) {
    $Object[$Name] = $Value
    return
  }
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function ConvertTo-BacklogDedupStringArray {
  param([Parameter(Mandatory=$false)]$Value)
  if (Get-Command ConvertTo-BacklogGovernorStringArray -ErrorAction SilentlyContinue) {
    return @(ConvertTo-BacklogGovernorStringArray -Value $Value)
  }
  if ($null -eq $Value) { return @() }
  $items = @()
  if ($Value -is [string]) {
    $items = @($Value)
  } elseif ($Value -is [System.Collections.IEnumerable]) {
    $items = @($Value)
  } else {
    $items = @($Value)
  }
  return @($items | ForEach-Object { [string]$_ } | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_)
  })
}

function Normalize-BacklogDedupSlug {
  param([Parameter(Mandatory=$false)][string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return '' }
  $s = ([string]$Slug).Trim().ToLowerInvariant()
  $s = $s -replace '[\s_]+','-'
  $s = $s -replace '-+','-'
  return $s.Trim('-')
}

function Normalize-BacklogDedupRootCauseKey {
  param([Parameter(Mandatory=$false)][string]$RootCauseKey)
  if ([string]::IsNullOrWhiteSpace($RootCauseKey)) { return '' }
  return (([string]$RootCauseKey) -replace '\s+',' ').Trim().ToLowerInvariant()
}

function Get-BacklogDedupItemId {
  param([Parameter(Mandatory=$false)]$Item)
  return [string](Get-BacklogDedupObjectValue -Object $Item -Names @('id') -Default '')
}

function Get-BacklogDedupItemSlug {
  param([Parameter(Mandatory=$false)]$Item)
  return (Normalize-BacklogDedupSlug -Slug ([string](Get-BacklogDedupObjectValue -Object $Item -Names @('slug') -Default '')))
}

function Get-BacklogDedupItemRootCauseKey {
  param([Parameter(Mandatory=$false)]$Item)
  $root = [string](Get-BacklogDedupObjectValue -Object $Item -Names @('root_cause_key','lease_root_cause_key','workpack_root_cause_key') -Default '')
  return (Normalize-BacklogDedupRootCauseKey -RootCauseKey $root)
}

function Get-BacklogDedupItemTouchSet {
  param([Parameter(Mandatory=$false)]$Item)
  $touch = @()
  foreach ($name in @('touch_set','files','lease_touch_set','workpack_touch_set')) {
    $touch += @(ConvertTo-BacklogDedupStringArray -Value (Get-BacklogDedupObjectValue -Object $Item -Names @($name)))
  }
  return @($touch | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Normalize-BacklogDedupTouchSet {
  param(
    [Parameter(Mandatory=$false)]$TouchSet,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  if (Get-Command Normalize-BacklogGovernorTouchSet -ErrorAction SilentlyContinue) {
    return @(Normalize-BacklogGovernorTouchSet -TouchSet $TouchSet -Root $Root)
  }
  return @((ConvertTo-BacklogDedupStringArray -Value $TouchSet) | ForEach-Object {
    ([string]$_).Trim().Trim('"').Trim("'").Replace('\','/').ToLowerInvariant() -replace '/+','/'
  } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Test-BacklogDedupTouchSetOverlap {
  param(
    [Parameter(Mandatory=$false)]$Left,
    [Parameter(Mandatory=$false)]$Right,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  if (Get-Command Test-BacklogGovernorTouchSetOverlap -ErrorAction SilentlyContinue) {
    return [bool](Test-BacklogGovernorTouchSetOverlap -Left $Left -Right $Right -Root $Root)
  }
  $leftSet = @(Normalize-BacklogDedupTouchSet -TouchSet $Left -Root $Root)
  $rightSet = @(Normalize-BacklogDedupTouchSet -TouchSet $Right -Root $Root)
  foreach ($leftPath in $leftSet) {
    foreach ($rightPath in $rightSet) {
      if ([string]::Equals($leftPath, $rightPath, [System.StringComparison]::OrdinalIgnoreCase) -or
          $rightPath.StartsWith($leftPath.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
          $leftPath.StartsWith($rightPath.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
  }
  return $false
}

function Get-BacklogDedupItemTimestamp {
  param([Parameter(Mandatory=$false)]$Item)
  $best = $null
  foreach ($name in @('approved_at','created_at','ts')) {
    $raw = [string](Get-BacklogDedupObjectValue -Object $Item -Names @($name) -Default '')
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    try {
      $parsed = [datetime]::Parse($raw).ToUniversalTime()
      if ($null -eq $best -or $parsed -gt $best) { $best = $parsed }
    } catch {}
  }
  return $best
}

function New-BacklogDedupRecord {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$true)][int]$Index,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $ts = Get-BacklogDedupItemTimestamp -Item $Item
  $ticks = if ($null -ne $ts) { $ts.Ticks } else { [datetime]::MinValue.Ticks + $Index }
  return [pscustomobject][ordered]@{
    item = $Item
    index = $Index
    id = Get-BacklogDedupItemId -Item $Item
    status = ([string](Get-BacklogDedupObjectValue -Object $Item -Names @('status') -Default '')).ToLowerInvariant()
    slug = Get-BacklogDedupItemSlug -Item $Item
    root_cause_key = Get-BacklogDedupItemRootCauseKey -Item $Item
    touch_set = @(Get-BacklogDedupItemTouchSet -Item $Item)
    normalized_touch_set = @(Normalize-BacklogDedupTouchSet -TouchSet (Get-BacklogDedupItemTouchSet -Item $Item) -Root $Root)
    timestamp = $ts
    sort_ticks = $ticks
  }
}

function Test-BacklogDeterministicDuplicate {
  param(
    [Parameter(Mandatory=$false)]$Left,
    [Parameter(Mandatory=$false)]$Right,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $leftSlug = Get-BacklogDedupItemSlug -Item $Left
  $rightSlug = Get-BacklogDedupItemSlug -Item $Right
  if (-not [string]::IsNullOrWhiteSpace($leftSlug) -and
      [string]::Equals($leftSlug, $rightSlug, [System.StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject][ordered]@{
      duplicate = $true
      reason = 'slug'
      detail = "slug '$leftSlug' matches"
      evidence = [pscustomobject][ordered]@{ matched_on = 'slug'; value = $leftSlug }
    }
  }

  $leftRoot = Get-BacklogDedupItemRootCauseKey -Item $Left
  $rightRoot = Get-BacklogDedupItemRootCauseKey -Item $Right
  if (-not [string]::IsNullOrWhiteSpace($leftRoot) -and
      [string]::Equals($leftRoot, $rightRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject][ordered]@{
      duplicate = $true
      reason = 'root_cause_key'
      detail = "root_cause_key '$leftRoot' matches"
      evidence = [pscustomobject][ordered]@{ matched_on = 'root_cause_key'; value = $leftRoot }
    }
  }

  $leftTouch = @(Get-BacklogDedupItemTouchSet -Item $Left)
  $rightTouch = @(Get-BacklogDedupItemTouchSet -Item $Right)
  if (Test-BacklogDedupTouchSetOverlap -Left $leftTouch -Right $rightTouch -Root $Root) {
    return [pscustomobject][ordered]@{
      duplicate = $true
      reason = 'touch_set'
      detail = 'normalized touch_set overlaps'
      evidence = [pscustomobject][ordered]@{
        matched_on = 'touch_set'
        left = @(Normalize-BacklogDedupTouchSet -TouchSet $leftTouch -Root $Root)
        right = @(Normalize-BacklogDedupTouchSet -TouchSet $rightTouch -Root $Root)
      }
    }
  }

  return [pscustomobject][ordered]@{
    duplicate = $false
    reason = 'none'
    detail = ''
    evidence = [pscustomobject][ordered]@{ matched_on = ''; value = '' }
  }
}

function Set-BacklogDeterministicSupersededItem {
  param(
    [Parameter(Mandatory=$false)]$OlderItem,
    [Parameter(Mandatory=$true)][string]$NewerId,
    [Parameter(Mandatory=$true)][string]$Reason,
    [Parameter(Mandatory=$false)]$Evidence
  )
  Set-BacklogDedupObjectValue -Object $OlderItem -Name 'status' -Value 'auto-dropped'
  Set-BacklogDedupObjectValue -Object $OlderItem -Name 'superseded_by' -Value $NewerId
  Set-BacklogDedupObjectValue -Object $OlderItem -Name 'superseded_reason' -Value $Reason
  Set-BacklogDedupObjectValue -Object $OlderItem -Name 'superseded_evidence' -Value $Evidence
}

function Invoke-BacklogDeterministicSupersede {
  param(
    [Parameter(Mandatory=$false)]$Items,
    [Parameter(Mandatory=$false)][string[]]$CandidateStatuses = @('new','approved','held'),
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $allItems = @($Items)
  $candidateSet = @{}
  foreach ($status in @($CandidateStatuses)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$status)) {
      $candidateSet[([string]$status).ToLowerInvariant()] = $true
    }
  }

  $records = New-Object 'System.Collections.Generic.List[object]'
  for ($i = 0; $i -lt $allItems.Count; $i++) {
    $record = New-BacklogDedupRecord -Item $allItems[$i] -Index $i -Root $Root
    if ($candidateSet.ContainsKey([string]$record.status)) {
      [void]$records.Add($record)
    }
  }

  $survivors = New-Object 'System.Collections.Generic.List[object]'
  $dropped = New-Object 'System.Collections.Generic.List[object]'
  $pairs = New-Object 'System.Collections.Generic.List[object]'

  foreach ($record in @($records.ToArray() | Sort-Object -Property @{Expression='sort_ticks';Descending=$false}, @{Expression='index';Descending=$false})) {
    $matched = @()
    foreach ($survivor in @($survivors.ToArray())) {
      $dup = Test-BacklogDeterministicDuplicate -Left $survivor.item -Right $record.item -Root $Root
      if ([bool]$dup.duplicate) {
        $matched += [pscustomobject][ordered]@{ survivor = $survivor; duplicate = $dup }
      }
    }

    foreach ($match in $matched) {
      $older = $match.survivor
      $reason = [string]$match.duplicate.reason
      $evidence = [pscustomobject][ordered]@{
        older_id = [string]$older.id
        newer_id = [string]$record.id
        reason = $reason
        detail = [string]$match.duplicate.detail
        deterministic = $true
        match = $match.duplicate.evidence
      }
      Set-BacklogDeterministicSupersededItem -OlderItem $older.item -NewerId ([string]$record.id) -Reason $reason -Evidence $evidence
      [void]$dropped.Add($older.item)
      [void]$pairs.Add($evidence)
      [void]$survivors.Remove($older)
    }

    [void]$survivors.Add($record)
  }

  $approved = @($allItems | Where-Object { [string](Get-BacklogDedupObjectValue -Object $_ -Names @('status') -Default '') -eq 'approved' })
  return [pscustomobject][ordered]@{
    items = @($allItems)
    approved = @($approved)
    dropped = @($dropped.ToArray())
    duplicate_pairs = @($pairs.ToArray())
    evidence = [pscustomobject][ordered]@{
      deterministic = $true
      candidate_statuses = @($CandidateStatuses)
      duplicate_rules = @('slug','root_cause_key','touch_set')
      advisory_metadata = @('semantic_similarity')
    }
  }
}
#endregion Deterministic backlog supersede helpers

function Get-IdeaOutcomeStats {
  # Learning-loop aggregate: distills the FATE of past ideas so a generator (Architect/reflect)
  # can calibrate -- propose more of what survives, less of what the curator rejects. Read-only.
  # Sources: backlog (status/from/auto_curator/self_exec_commit) + metrics verdicts. Housekeeping
  # drops (manual cleanup, mojibake, A/B reruns) are filtered out so only SUBSTANTIVE curator
  # rejections inform the generator. Returns a pscustomobject; safe on empty/cold data.
  param([int]$RecentWinDays = 30, [int]$MaxDropReasons = 6, [int]$MaxWins = 6)
  $bl = @(Get-Backlog)
  $doneSt = @('done','auto-resolved')
  $dropSt = @('auto-dropped','rejected')
  $noise  = '(?i)(mojibake|cleanup|a/b[- ]?test|rerun|pre-[a-z0-9]|encoding fix|scenario|\btest\b|времен)'
  $moji   = '[�]|[À-ÿ]{3,}'   # broken-encoding artifacts (pre-7163c88 UTF-8/CP1251 mojibake)

  $perSource = [ordered]@{}
  foreach ($g in ($bl | Group-Object { [string]$_.from })) {
    $grp = $g.Group
    $done = @($grp | Where-Object { $doneSt -contains [string]$_.status }).Count
    $drop = @($grp | Where-Object { $dropSt -contains [string]$_.status }).Count
    $perSource[[string]$g.Name] = [pscustomobject]@{
      total = $g.Count; done = $done; dropped = $drop
      drop_rate = if ($g.Count -gt 0) { [Math]::Round($drop / [double]$g.Count, 2) } else { 0 }
    }
  }

  $reasons = New-Object 'System.Collections.Generic.List[string]'
  foreach ($i in $bl) {
    if ($dropSt -notcontains [string]$i.status) { continue }
    $ac = $i.auto_curator
    if (-not $ac) { continue }
    $model = [string]$ac.model
    if ($model -eq 'manual' -or [string]::IsNullOrWhiteSpace($model)) { continue }   # housekeeping, not a judgment
    $r = ([string]$ac.reason).Trim()
    if ([string]::IsNullOrWhiteSpace($r) -or ($r -match $noise) -or ($r -match $moji)) { continue }
    $r = ($r -replace '\s*\(low confidence\)\s*$','').Trim()
    if ($r.Length -gt 90) { $r = $r.Substring(0,90) + '…' }
    [void]$reasons.Add($r)
  }
  $topDrop = @($reasons | Group-Object | Sort-Object Count -Descending | Select-Object -First $MaxDropReasons |
              ForEach-Object { [pscustomobject]@{ reason = $_.Name; count = $_.Count } })

  $wins = New-Object 'System.Collections.Generic.List[string]'
  foreach ($i in ($bl | Where-Object { [string]$_.status -eq 'done' } | Sort-Object { [string]$_.ts } -Descending)) {
    $t = ([string]$i.text -replace '\s+',' ').Trim()
    if ($t -match $noise -or $t -match $moji) { continue }
    if ($t.Length -gt 90) { $t = $t.Substring(0,90) + '…' }
    [void]$wins.Add($t)
    if ($wins.Count -ge $MaxWins) { break }
  }

  $worked = 0; $worse = 0
  try {
    $sc = @{}
    foreach ($i in $bl) { $c = [string]$i.self_exec_commit; if ($c) { $sc[$c] = $true; if ($c.Length -ge 7) { $sc[$c.Substring(0,7)] = $true } } }
    if ($sc.Count -gt 0 -and (Get-Command Read-MetricsJsonl -ErrorAction SilentlyContinue)) {
      foreach ($r in @(Read-MetricsJsonl)) {
        if ([string]$r.type -ne 'verdict') { continue }
        $vc = [string]$r.commit; if (-not $vc) { continue }
        if (-not ($sc.ContainsKey($vc) -or ($vc.Length -ge 7 -and $sc.ContainsKey($vc.Substring(0,7))))) { continue }
        if ([string]$r.verdict -eq 'worked') { $worked++ } elseif ([string]$r.verdict -eq 'worse') { $worse++ }
      }
    }
  } catch {}

  return [pscustomobject]@{
    perSource      = $perSource
    topDropReasons = $topDrop
    recentWins     = @($wins.ToArray())
    selfExec       = [pscustomobject]@{ worked = $worked; worse = $worse }
  }
}

function Format-IdeaLearningGuidance {
  # Render Get-IdeaOutcomeStats into a compact prompt block so a generator LEARNS from the fate of
  # past ideas. Returns '' when there's nothing useful yet (cold start) so callers can skip it.
  param([int]$RecentWinDays = 30, [int]$MinSourceVolume = 3)
  $st = $null
  try { $st = Get-IdeaOutcomeStats -RecentWinDays $RecentWinDays } catch { return '' }
  if (-not $st) { return '' }
  $sb = New-Object System.Text.StringBuilder
  $had = $false
  $srcLines = @()
  foreach ($k in $st.perSource.Keys) {
    $v = $st.perSource[$k]
    if ([int]$v.total -lt $MinSourceVolume) { continue }
    $srcLines += ("- {0}: предложено {1}, done {2}, отклонено {3} (drop-rate {4})" -f $k, $v.total, $v.done, $v.dropped, $v.drop_rate)
  }
  if ($srcLines.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Источники идей по исходам (высокий drop-rate = источник генерит много мусора):')
    foreach ($l in $srcLines) { [void]$sb.AppendLine($l) }
  }
  if ($st.topDropReasons.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Частые СОДЕРЖАТЕЛЬНЫЕ причины отказа куратора (НЕ предлагай идеи с такими свойствами):')
    foreach ($d in $st.topDropReasons) { [void]$sb.AppendLine(("- «{0}» ×{1}" -f $d.reason, $d.count)) }
  }
  if ($st.recentWins.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Недавно принятые и сделанные идеи (вот формат/масштаб, который заходит):')
    foreach ($w in $st.recentWins) { [void]$sb.AppendLine("- $w") }
  }
  if (([int]$st.selfExec.worked + [int]$st.selfExec.worse) -gt 0) {
    $had = $true
    [void]$sb.AppendLine(("Авто-исполненные идеи по 24ч-вердикту: сработали {0}, ухудшили {1}." -f $st.selfExec.worked, $st.selfExec.worse))
  }
  if (-not $had) { return '' }
  return ('=== СУДЬБА ПРОШЛЫХ ИДЕЙ (учись на ней) ===' + "`n" + $sb.ToString().Trim())
}

function Get-OpenIdeaCount {
  # Count of ideas still "in flight" — proposed but not yet resolved/dropped/archived. Drives the
  # WIP budget so proactive generators don't pile on while the queue is already full.
  return @(Get-Backlog | Where-Object { [string]$_.status -in @('new','approved','running','inprogress') }).Count
}

function Test-BacklogHasCapacity {
  # WIP gate for PROACTIVE generators (reflect/architect). $true if open ideas are under maxOpenIdeas
  # (so the generator may add more); $false means "drain the queue first". Reactive generators
  # (deep-audit filing real bugs) must NOT call this. Fail-open on any error.
  $cap = 12
  try { $cap = [int](Get-AutonomySettings).maxOpenIdeas } catch {}
  if ($cap -le 0) { return $true }   # 0 / unset = unlimited
  try { return ((Get-OpenIdeaCount) -lt $cap) } catch { return $true }
}

function Invoke-BacklogStaleSweep {
  # Anti-junk hygiene: archive 'new' ideas nobody ever claimed. A 'new' idea older than ideaStaleDays
  # (not approved/running, and not external/radar — those await manual review) -> status 'auto-stale'.
  # Caller throttles cadence. Returns count archived.
  param([int]$MaxAgeDays = 0)
  $days = $MaxAgeDays
  if ($days -le 0) { try { $days = [int](Get-AutonomySettings).ideaStaleDays } catch { $days = 14 } }
  if ($days -le 0) { return 0 }
  $cut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($days))
  $items = @(Get-Backlog)
  $n = 0
  foreach ($i in $items) {
    if ([string]$i.status -ne 'new') { continue }
    try { if (Test-IdeaExternal $i) { continue } } catch {}   # radar/web await human review by design
    $ts = $null
    try { $ts = [datetime]::Parse([string]$i.ts).ToUniversalTime() } catch { continue }
    if ($ts -ge $cut) { continue }
    $i | Add-Member -NotePropertyName status   -NotePropertyValue 'auto-stale' -Force
    $i | Add-Member -NotePropertyName stale_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $n++
  }
  if ($n -gt 0) {
    Save-Backlog $items
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='stale-sweep'; archived=$n; older_than_days=$days }) } catch {}
  }
  return $n
}

function Get-BacklogIdeaKeywords {
  param([string]$Text)
  $stop = @{
    'the'=$true; 'a'=$true; 'of'=$true;
    'and'=$true; 'with'=$true; 'this'=$true; 'that'=$true; 'from'=$true;
  }
  $counts = @{}
  foreach ($m in [regex]::Matches([string]$Text, '[\p{L}\p{Nd}_-]{4,}')) {
    $w = $m.Value.ToLowerInvariant()
    if ($stop.ContainsKey($w)) { continue }
    if ($counts.ContainsKey($w)) { $counts[$w] = [int]$counts[$w] + 1 } else { $counts[$w] = 1 }
  }
  return @($counts.GetEnumerator() | Sort-Object -Property @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false} | Select-Object -First 10 | ForEach-Object { [string]$_.Key })
}

function Get-BacklogMentionedFiles {
  param([string]$Text)
  $set = @{}
  $patterns = @(
    # 2026-05-31 (Foundation #4 scale): added web/project extensions (ts/tsx/jsx/prisma/sql/scss/vue...)
    # and project dirs (src/app/components/pages/api/prisma...) so PROJECT-channel tasks get their
    # touched files extracted -> per-file conflict groups -> independent tasks batch in PARALLEL.
    # Bridge extensions/dirs preserved, so bridge classification is unchanged.
    '(?i)(?:[\w.-]+[\\/])*[\w.-]+\.(?:jsonl|json|psm1|ps1|html|css|scss|sass|less|js|jsx|ts|tsx|mjs|cjs|vue|svelte|prisma|sql|yaml|yml|md|txt|env)',
    '(?i)(?:lib|web|memory|control|tools|docs|channels|src|app|components|pages|api|prisma|config|content|public|styles|server|hooks|utils)[\\/][\w.\\/:-]*'
  )
  foreach ($pat in $patterns) {
    foreach ($m in [regex]::Matches([string]$Text, $pat)) {
      $v = $m.Value.Replace('\', '/').Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($v)) { $set[$v] = $true }
    }
  }
  return @($set.Keys)
}

function Get-BacklogForbiddenMentionPattern {
  return "(?i)(?:не\s+трогать|не\s+трогай|do\s+not\s+touch|don't\s+touch|forbidden|запрещено)"
}

function Get-BacklogTextOutsideForbiddenContexts {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $rx = Get-BacklogForbiddenMentionPattern
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in [regex]::Split([string]$Text, "\r?\n")) {
    $m = [regex]::Match([string]$line, $rx)
    if ($m.Success) {
      $safe = ([string]$line).Substring(0, $m.Index)
      if (-not [string]::IsNullOrWhiteSpace($safe)) { [void]$out.Add($safe) }
      continue
    }
    [void]$out.Add([string]$line)
  }
  return (($out.ToArray()) -join "`n")
}

function Test-IdeaStillRelevant {
  param([string]$ItemId)
  $failOpen = [pscustomobject]@{ done = $false; sha = $null; reason = 'check-failed' }
  try {
    if ([string]::IsNullOrWhiteSpace($ItemId)) { return $failOpen }
    $item = Get-IdeaById -Id $ItemId
    if (-not $item) { return [pscustomobject]@{ done = $false; sha = $null; reason = 'not-found' } }

    $logArgs = @()
    $approvedSha = ''
    try {
      if ($item.PSObject.Properties.Name -contains 'approved_at_sha') { $approvedSha = [string]$item.approved_at_sha }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($approvedSha)) {
      $logArgs = @('log', "$approvedSha..HEAD", '--oneline', '-50')
    } else {
      $since = [string]$item.ts
      if ([string]::IsNullOrWhiteSpace($since)) { $since = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o') }
      $logArgs = @('log', "--since=$since", '--oneline', '-50')
    }
    $gitLog = Get-BacklogGitOutput -GitArgs $logArgs
    if ([string]::IsNullOrWhiteSpace($gitLog)) {
      return [pscustomobject]@{ done = $false; sha = $null; reason = 'no-commits' }
    }

    $lowerLog = $gitLog.ToLowerInvariant()
    $keywords = @(Get-BacklogIdeaKeywords -Text ([string]$item.text))
    $keywordHits = 0
    foreach ($kw in $keywords) {
      if ($lowerLog.Contains($kw.ToLowerInvariant())) { $keywordHits++ }
    }
    $files = @(Get-BacklogMentionedFiles -Text ([string]$item.text))
    $fileHit = $false
    foreach ($f in $files) {
      if (-not [string]::IsNullOrWhiteSpace($f) -and $lowerLog.Contains($f.ToLowerInvariant())) { $fileHit = $true; break }
      $leaf = Split-Path -Leaf $f
      if (-not [string]::IsNullOrWhiteSpace($leaf) -and $lowerLog.Contains($leaf.ToLowerInvariant())) { $fileHit = $true; break }
    }
    if ($keywordHits -lt 2 -and -not $fileHit) {
      return [pscustomobject]@{ done = $false; sha = $null; reason = 'no-quick-signal' }
    }

    Ensure-BacklogLLMLoaded
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) { return $failOpen }
    $prompt = @"
Item беклога: $([string]$item.text)
Commits с момента создания/одобрения:
$gitLog

Сделано ли это уже одним из коммитов?

Жёсткие правила:
- Коммит считается реализующим item ТОЛЬКО если в commit message явно упоминается конкретный элемент из item.text: имя функции, файла, класса, эндпоинта, точная фича или чёткая концепция.
- Recency сама по себе НЕ сигнал. Самый свежий или последний коммит нельзя считать доказательством выполнения.
- Если есть только пересечение общих слов вроде "backlog", "driver", "fix", "task", "agent", "bridge" без специфики item.text — верни done=false.
- При сомнении — done=false.
- Если done=true, sha должен быть SHA конкретного коммита из списка выше, а reason должен быть не короче 30 символов и цитировать связанную фразу из commit message.

Верни СТРОГО JSON:
{"done": true|false, "sha": "<sha если done>" или null, "reason": "фраза >=30 символов с цитатой commit message"}
"@
    $raw = Invoke-LLM -Purpose 'backlog-freshness' -Model $script:BacklogCuratorModel -Prompt $prompt -TimeoutSec 60 -Temperature 0.1
    $obj = ConvertFrom-BacklogStrictJson -Text ([string]$raw)
    if (-not $obj) { return $failOpen }
    $done = $false
    try { $done = [bool]$obj.done } catch { $done = $false }
    $sha = $null
    if ($obj.PSObject.Properties.Name -contains 'sha' -and $null -ne $obj.sha) { $sha = [string]$obj.sha }
    $reason = ([string]$obj.reason).Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = if ($done) { 'done' } else { 'not done' } }
    if ($done) {
      if ([string]::IsNullOrWhiteSpace($sha) -or -not $lowerLog.Contains(([string]$sha).ToLowerInvariant()) -or $reason.Length -lt 30) {
        return [pscustomobject]@{ done = $false; sha = $null; reason = 'freshness LLM returned weak done evidence' }
      }
    }
    return [pscustomobject]@{ done = $done; sha = $sha; reason = $reason }
  } catch {
    return $failOpen
  }
}

#endregion Idea deduplication, learning, relevance, and queue hygiene
