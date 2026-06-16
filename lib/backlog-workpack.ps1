# backlog-workpack.ps1 -- workpack packing, batching, and frontier helpers.

#region Backlog workpack packing and batching

# 2026-06-09 shared primitives (lib/primitives.ps1, single source of truth). Guarded dot-source
# so standalone consumers get it too; the lib/backlog.ps1 aggregator loads it first.
if (-not (Get-Command Get-BridgeObjectValue -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'primitives.ps1') } catch {}
}

function Get-BacklogPackObjectValue {
  # Delegates to the canonical Get-BridgeObjectValue. Workpack semantics = present-but-null is
  # treated as MISSING (-NullAsMissing), preserving the original behavior exactly.
  param($Obj, [string]$Name, $Default = $null)
  return Get-BridgeObjectValue -Object $Obj -Names @($Name) -Default $Default -NullAsMissing
}

function ConvertTo-BacklogPackBool {
  param($Value, [bool]$Default = $true)
  return Test-BridgeTruthy -Value $Value -Default $Default
}

function ConvertTo-BacklogPackInt {
  param($Value, [int]$Default, [int]$Min = 0, [int]$Max = 1000000)
  $n = 0.0
  try {
    if ([double]::TryParse([string]$Value, [ref]$n)) {
      $i = [int][Math]::Round($n)
      if ($i -lt $Min) { return $Min }
      if ($i -gt $Max) { return $Max }
      return $i
    }
  } catch {}
  return $Default
}

function Invoke-BacklogClaimabilityDeadlockAdmission {
  param(
    [Parameter(Mandatory=$false)][object[]]$Items = $null,
    [Parameter(Mandatory=$false)]$Claimability = $null,
    [Parameter(Mandatory=$false)][string]$Channel = ''
  )

  if (-not (Get-Command Test-ApprovedBacklogClaimabilityDeadlock -ErrorAction SilentlyContinue)) {
    return [pscustomobject][ordered]@{ deadlock = $false; held_count = 0; held_ids = @(); reason = 'detector-unavailable' }
  }
  if ($null -eq $Items) { $Items = @(Get-Backlog) }
  if ($null -eq $Claimability) { $Claimability = Get-ApprovedBacklogClaimabilityReport -Items $Items }
  $deadlock = [bool](Test-ApprovedBacklogClaimabilityDeadlock -Claimability $Claimability)
  if (-not $deadlock) {
    return [pscustomobject][ordered]@{ deadlock = $false; held_count = 0; held_ids = @(); reason = 'not-deadlock' }
  }
  $controlPlaneParentIds = @()
  try { $controlPlaneParentIds = @($Claimability.control_plane_all_ids) } catch { $controlPlaneParentIds = @() }
  if ($controlPlaneParentIds.Count -eq 0) {
    try { $controlPlaneParentIds = @($Claimability.control_plane_ids) } catch { $controlPlaneParentIds = @() }
  }
  $missingCanary = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rawParentId in @($controlPlaneParentIds)) {
    $parentId = ([string]$rawParentId).Trim()
    if ([string]::IsNullOrWhiteSpace($parentId)) { continue }
    $parent = $null
    foreach ($candidateParent in @($Items)) {
      if ([string](Get-BacklogPackObjectValue -Obj $candidateParent -Name 'id' -Default '') -eq $parentId) {
        $parent = $candidateParent
        break
      }
    }

    $hasCanaryGate = $false
    if ($parent) {
      $routedChildId = [string](Get-BacklogPackObjectValue -Obj $parent -Name 'canary_gate_routed_to_main' -Default '')
      if (-not [string]::IsNullOrWhiteSpace($routedChildId)) { $hasCanaryGate = $true }
    }
    if (-not $hasCanaryGate) {
      foreach ($candidate in @($Items)) {
        $candidateTags = @()
        try { $candidateTags = @(ConvertTo-BacklogClaimStringArray (Get-BacklogPackObjectValue -Obj $candidate -Name 'tags' -Default @()) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }) } catch { $candidateTags = @() }
        if (-not (@($candidateTags) -contains 'bridge-self-canary-gate')) { continue }
        if (-not (@($candidateTags) -contains 'operator')) { continue }
        $candidateParent = [string](Get-BacklogPackObjectValue -Obj $candidate -Name 'parent_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($candidateParent)) { $candidateParent = [string](Get-BacklogPackObjectValue -Obj $candidate -Name 'canary_gate_parent_id' -Default '') }
        $candidateText = [string](Get-BacklogPackObjectValue -Obj $candidate -Name 'text' -Default '')
        if ([string]$candidateParent -eq $parentId -or $candidateText -match [regex]::Escape('[parent:' + $parentId + ']')) {
          $hasCanaryGate = $true
          break
        }
      }
    }
    if (-not $hasCanaryGate) { [void]$missingCanary.Add($parentId) }
  }
  if ($missingCanary.Count -gt 0) {
    return [pscustomobject][ordered]@{
      deadlock = $true
      changed = $false
      held_count = 0
      held_ids = @()
      reason = 'missing-canary-gate'
      missing_canary_parent_ids = @($missingCanary.ToArray())
    }
  }
  $held = Set-ApprovedBacklogClaimabilityDeadlockHeld -Items $Items -Claimability $Claimability -Channel $Channel
  return [pscustomobject][ordered]@{
    deadlock = $true
    changed = [bool]$held.changed
    held_count = [int]$held.held_count
    held_ids = @($held.held_ids)
    reason = [string]$held.reason
  }
}

function Get-BacklogPackConfig {
  $cfg = [ordered]@{
    enabled            = $true
    burstCount         = 5
    windowMinutes      = 60
    unpackedOpenCount  = 8
    auditBurstCount    = 3
    auditWindowMinutes = 30
    cooldownMinutes    = 30
    minItems           = 2
    dedupeEnabled      = $true
    dedupeMinGroupSize = 2
  }
  $dotted = @{
    'backlogPack.enabled'            = 'enabled'
    'backlogPack.burstCount'         = 'burstCount'
    'backlogPack.windowMinutes'      = 'windowMinutes'
    'backlogPack.unpackedOpenCount'  = 'unpackedOpenCount'
    'backlogPack.auditBurstCount'    = 'auditBurstCount'
    'backlogPack.auditWindowMinutes' = 'auditWindowMinutes'
    'backlogPack.cooldownMinutes'    = 'cooldownMinutes'
    'backlogPack.minItems'           = 'minItems'
    'backlogPack.dedupeEnabled'      = 'dedupeEnabled'
    'backlogPack.dedupeMinGroupSize' = 'dedupeMinGroupSize'
  }
  $flat = @{
    backlogPackEnabled            = 'enabled'
    backlogPackBurstCount         = 'burstCount'
    backlogPackWindowMinutes      = 'windowMinutes'
    backlogPackUnpackedOpenCount  = 'unpackedOpenCount'
    backlogPackAuditBurstCount    = 'auditBurstCount'
    backlogPackAuditWindowMinutes = 'auditWindowMinutes'
    backlogPackCooldownMinutes    = 'cooldownMinutes'
    backlogPackMinItems           = 'minItems'
    backlogPackDedupeEnabled      = 'dedupeEnabled'
    backlogPackDedupeMinGroupSize = 'dedupeMinGroupSize'
  }
  try {
    if (Get-Command Get-AdvancedSettings -ErrorAction SilentlyContinue) {
      $adv = Get-AdvancedSettings
      foreach ($k in $dotted.Keys) {
        if ($adv -and $adv.Contains($k) -and $null -ne $adv[$k]) { $cfg[$dotted[$k]] = $adv[$k] }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.burstCount = ConvertTo-BacklogPackInt -Value $cfg.burstCount -Default 5 -Min 2 -Max 1000
  $cfg.windowMinutes = ConvertTo-BacklogPackInt -Value $cfg.windowMinutes -Default 60 -Min 1 -Max 1440
  $cfg.unpackedOpenCount = ConvertTo-BacklogPackInt -Value $cfg.unpackedOpenCount -Default 8 -Min 2 -Max 1000
  $cfg.auditBurstCount = ConvertTo-BacklogPackInt -Value $cfg.auditBurstCount -Default 3 -Min 2 -Max 1000
  $cfg.auditWindowMinutes = ConvertTo-BacklogPackInt -Value $cfg.auditWindowMinutes -Default 30 -Min 1 -Max 1440
  $cfg.cooldownMinutes = ConvertTo-BacklogPackInt -Value $cfg.cooldownMinutes -Default 30 -Min 1 -Max 1440
  $cfg.minItems = ConvertTo-BacklogPackInt -Value $cfg.minItems -Default 2 -Min 1 -Max 50
  $cfg.dedupeEnabled = ConvertTo-BacklogPackBool -Value $cfg.dedupeEnabled -Default $true
  $cfg.dedupeMinGroupSize = ConvertTo-BacklogPackInt -Value $cfg.dedupeMinGroupSize -Default 2 -Min 2 -Max 1000
  return [pscustomobject]$cfg
}

function Get-BacklogPackChannel {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
      $slug = [string](Get-EffectiveChannel)
      if (-not [string]::IsNullOrWhiteSpace($slug)) { return $slug }
    }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-BacklogPackDir {
  $dir = $null
  try {
    if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
      $dir = Join-Path (Get-ChannelDir) 'workpacks'
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace([string]$dir)) {
    $dir = Join-Path (Get-BacklogControlDir) 'workpacks'
  }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Get-BacklogPackRequestPath { Join-Path (Get-BacklogPackDir) 'pack.request.json' }
function Get-BacklogPackLatestPath { Join-Path (Get-BacklogPackDir) 'latest.json' }
function Get-BacklogPackRunsPath { Join-Path (Get-BacklogPackDir) 'runs.jsonl' }

function Test-BacklogPackItemOpen {
  param($Item)
  $status = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')
  return ($status -in @('new','approved','held'))
}

function Test-BacklogPackItemUnpacked {
  param($Item)
  $packId = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default '')
  return [string]::IsNullOrWhiteSpace($packId)
}

function Test-BacklogPackItemAuditSource {
  param($Item)
  # 2026-06-16 (operator queue-fix): operator-seeded atoms are human-vetted; never route them
  # through audit gates (cross_file_causal_map hold / audit-burst rate-limit). The 'workflow-audit'
  # tag was substring-matching 'audit' below and orphaning operator atoms. Real audits use from=audit*.
  $from0 = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'from' -Default '')).ToLowerInvariant()
  if ($from0 -eq 'operator') { return $false }
  try { if (@(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @()) -contains 'operator') { return $false } } catch {}
  $from = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'from' -Default '')).ToLowerInvariant()
  if ($from -match 'audit') { return $true }
  $text = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')).ToLowerInvariant()
  if ($text -match '^\s*\[(deep-)?audit[/: -]') { return $true }
  try {
    $tags = @(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @() | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($tag in $tags) {
      if ($tag -match 'audit') { return $true }
    }
  } catch {}
  return $false
}

function Test-BacklogDuplicateCompactorCandidate {
  param($Item)
  $status = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')).ToLowerInvariant()
  if ($status -notin @('new','approved')) { return $false }
  if (-not (Test-BacklogPackItemAuditSource -Item $Item)) { return $false }
  $dupOf = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'duplicate_of' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($dupOf)) { return $false }
  return $true
}

function Get-BacklogDuplicateFindingType {
  param($Item)
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  if ([string]::IsNullOrWhiteSpace($text)) { return '' }
  $signal = (Get-BacklogWorkpackSignalText -Text $text)
  $signal = ([regex]::Replace([string]$signal, '\s+', ' ')).Trim()
  if ([string]::IsNullOrWhiteSpace($signal)) { return '' }

  $m = [regex]::Match($signal, '^(?<type>[A-Za-z0-9][A-Za-z0-9_-]{2,80})(?=\s*(?:--|\||:|\(|\p{Pd}|\b))')
  if (-not $m.Success) { return '' }
  $raw = ([string]$m.Groups['type'].Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

  $stop = @(
    'add','check','create','document','fix','harden','implement','improve','investigate',
    'review','run','surface','test','update','verify','write'
  )
  if ($stop -contains $raw) { return '' }

  $slug = ($raw -replace '_','-' -replace '[^a-z0-9-]+','-' -replace '-+','-').Trim('-')
  if ($slug.Length -lt 4) { return '' }

  # A typed audit finding normally carries a stable machine-ish token
  # (orphan-restart, process_supervision, hardcoded-credentials). Refuse broad prose.
  $singleTokenAllow = @('deadlock','mojibake','storm','zombie')
  if (($slug -notmatch '-') -and ($singleTokenAllow -notcontains $slug)) { return '' }
  return $slug
}

function Get-BacklogDuplicateRootKey {
  param($Item)
  $root = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_root_cause_key' -Default '')
  if ([string]::IsNullOrWhiteSpace($root)) {
    try {
      $class = Get-BacklogWorkpackClassification -Item $Item
      $root = [string]$class.key
    } catch { $root = '' }
  }
  $root = ([string]$root).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($root)) { return '' }
  if ($root -eq 'module:general') { return '' }
  return $root
}

function Get-BacklogDuplicateCompactorKey {
  param($Item)
  $root = Get-BacklogDuplicateRootKey -Item $Item
  if ([string]::IsNullOrWhiteSpace($root)) { return $null }
  $kind = Get-BacklogDuplicateFindingType -Item $Item
  if ([string]::IsNullOrWhiteSpace($kind)) { return $null }
  return [pscustomobject]@{
    key = ($root + '|' + $kind)
    root = $root
    finding_type = $kind
  }
}

function Get-BacklogDuplicateStatusRank {
  param($Item)
  $status = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')).ToLowerInvariant()
  if ($status -eq 'approved') { return 0 }
  if ($status -eq 'new') { return 1 }
  return 2
}

function Get-BacklogDuplicateRepresentative {
  param([object[]]$Items)
  $arr = @($Items | Where-Object { $null -ne $_ })
  if ($arr.Count -eq 0) { return $null }
  $sorted = @(
    $arr | Sort-Object `
      @{Expression={ Get-BacklogDuplicateStatusRank -Item $_ }} `
      ,@{Expression={ Get-IdeaSeverityRank -Idea $_ }} `
      ,@{Expression={ [string](Get-BacklogPackObjectValue -Obj $_ -Name 'ts' -Default '') }}
  )
  return $sorted[0]
}

function Invoke-BacklogDuplicateCompactor {
  param(
    $Config = $null,
    [string[]]$Reason = @('manual'),
    [switch]$DryRun
  )
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  if (-not [bool]$Config.dedupeEnabled) {
    return [pscustomobject]@{ ran=$false; reason='disabled'; duplicates_rejected=0; group_count=0 }
  }

  $minGroup = [int]$Config.dedupeMinGroupSize
  if ($minGroup -lt 2) { $minGroup = 2 }
  $now = (Get-Date).ToUniversalTime().ToString('o')
  $sha = Get-BacklogCurrentSha

  $result = Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    $groups = @{}
    $meta = @{}
    foreach ($item in $items) {
      if (-not (Test-BacklogDuplicateCompactorCandidate -Item $item)) { continue }
      $keyObj = Get-BacklogDuplicateCompactorKey -Item $item
      if (-not $keyObj) { continue }
      $key = [string]$keyObj.key
      if ([string]::IsNullOrWhiteSpace($key)) { continue }
      if (-not $groups.ContainsKey($key)) {
        $groups[$key] = New-Object 'System.Collections.Generic.List[object]'
        $meta[$key] = $keyObj
      }
      [void]$groups[$key].Add($item)
    }

    $summaries = New-Object 'System.Collections.Generic.List[object]'
    $changed = 0
    foreach ($key in @($groups.Keys | Sort-Object)) {
      $groupItems = @($groups[$key].ToArray())
      if ($groupItems.Count -lt $minGroup) { continue }
      $rep = Get-BacklogDuplicateRepresentative -Items $groupItems
      if (-not $rep) { continue }
      $repId = [string](Get-BacklogPackObjectValue -Obj $rep -Name 'id' -Default '')
      if ([string]::IsNullOrWhiteSpace($repId)) { continue }

      $dupIds = New-Object 'System.Collections.Generic.List[string]'
      foreach ($dup in $groupItems) {
        $dupId = [string](Get-BacklogPackObjectValue -Obj $dup -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($dupId) -or $dupId -eq $repId) { continue }
        [void]$dupIds.Add($dupId)
        if (-not $DryRun) {
          $dup | Add-Member -NotePropertyName status -NotePropertyValue 'rejected' -Force
          $dup | Add-Member -NotePropertyName rejected_at -NotePropertyValue $now -Force
          $dup | Add-Member -NotePropertyName duplicate_of -NotePropertyValue $repId -Force
          $dup | Add-Member -NotePropertyName duplicate_key -NotePropertyValue $key -Force
          $dup | Add-Member -NotePropertyName duplicate_rejected_at -NotePropertyValue $now -Force
          $dup | Add-Member -NotePropertyName resolved_reason -NotePropertyValue 'duplicate-of-root-cause' -Force
          $dup | Add-Member -NotePropertyName auto_curator -NotePropertyValue ([pscustomobject][ordered]@{
            verdict = 'drop'
            confidence = 1.0
            reason = ('backlog duplicate: same root-cause as ' + $repId)
            model = 'backlog-compactor'
            ts = $now
            judged_at_sha = $sha
          }) -Force
        }
        $changed++
      }
      if ($dupIds.Count -gt 0) {
        $keyMeta = $meta[$key]
        [void]$summaries.Add([ordered]@{
          key = $key
          root = [string]$keyMeta.root
          finding_type = [string]$keyMeta.finding_type
          representative_id = $repId
          duplicate_ids = @($dupIds.ToArray())
          duplicate_count = $dupIds.Count
        })
      }
    }

    if ($changed -gt 0 -and -not $DryRun) { Save-Backlog $items }
    return [pscustomobject]@{
      ran = $true
      dry_run = [bool]$DryRun
      duplicates_rejected = $changed
      group_count = $summaries.Count
      groups = @($summaries.ToArray())
    }
  }.GetNewClosure())

  if ($result -and [bool]$result.ran -and [int]$result.duplicates_rejected -gt 0 -and -not $DryRun) {
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $now
        action = 'backlog-duplicate-compact'
        channel = Get-BacklogPackChannel
        reason = @($Reason)
        duplicates_rejected = [int]$result.duplicates_rejected
        group_count = [int]$result.group_count
        groups = @($result.groups)
      })
    } catch {}
  }
  return $result
}

function Get-BacklogIntakeGateFileEvidence {
  param($Item)
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  $root = Get-BacklogFallbackBridgeRoot
  $candidates = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in @(Get-BacklogMentionedFiles -Text $text)) {
    Add-BacklogWorkpackFileCandidate -List $candidates -Path $f
  }
  try {
    $class = Get-BacklogWorkpackClassification -Item $Item
    foreach ($f in @($class.touch_set)) { Add-BacklogWorkpackFileCandidate -List $candidates -Path ([string]$f) }
  } catch {}

  $existing = New-Object 'System.Collections.Generic.List[string]'
  $missing = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rel in @($candidates.ToArray())) {
    $r = ([string]$rel).Trim()
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    if ($r -notmatch '\.[a-z0-9]{1,8}$') { continue }
    try {
      $full = Join-Path $root ($r -replace '/', '\')
      if (Test-Path -LiteralPath $full -PathType Leaf) { [void]$existing.Add($r) }
      else { [void]$missing.Add($r) }
    } catch { [void]$missing.Add($r) }
  }

  return [pscustomobject]@{
    existing = @($existing.ToArray() | Select-Object -Unique)
    missing = @($missing.ToArray() | Select-Object -Unique)
  }
}

function Get-BacklogIntakeReferencedLines {
  param($Item, [string[]]$ExistingFiles = @())
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  $root = Get-BacklogFallbackBridgeRoot
  $refs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in [regex]::Matches($text, '(?i)(?<file>(?:[\w.-]+[\\/])*[\w.-]+\.(?:ps1|psm1|js|jsx|ts|tsx|json|html|css|md|yml|yaml|env)):(?<line>\d{1,6})')) {
    $rel = ([string]$m.Groups['file'].Value).Replace('\','/').ToLowerInvariant()
    $lineNo = 0
    try { $lineNo = [int]$m.Groups['line'].Value } catch { $lineNo = 0 }
    if ($lineNo -le 0) { continue }
    try {
      $full = Join-Path $root ($rel -replace '/', '\')
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
      $idx = 0
      foreach ($line in [System.IO.File]::ReadLines($full, [System.Text.Encoding]::UTF8)) {
        $idx++
        if ($idx -eq $lineNo) {
          [void]$refs.Add([pscustomobject]@{ file=$rel; line=$lineNo; text=[string]$line })
          break
        }
        if ($idx -gt $lineNo) { break }
      }
    } catch {}
  }

  if ($refs.Count -eq 0) {
    foreach ($rel in @($ExistingFiles | Select-Object -First 3)) {
      try {
        $full = Join-Path $root (([string]$rel) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $full -ErrorAction Stop
        if ($info.Length -gt 262144) { continue }
        $raw = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        [void]$refs.Add([pscustomobject]@{ file=[string]$rel; line=0; text=$raw })
      } catch {}
    }
  }
  return @($refs.ToArray())
}

function Test-BacklogIntakeCommentOnlyLine {
  param([string]$Line)
  $s = ([string]$Line).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $true }
  if ($s -match '^(#|//|/\*|\*|<!--)') { return $true }
  return $false
}

function Test-BacklogIntakeSecurityEvidence {
  param($Item, [string[]]$ExistingFiles = @())
  $text = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')).ToLowerInvariant()
  $isSecurity = $false
  try {
    $tags = @(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @() | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($tag in $tags) { if ($tag -match 'security|auth|secret|credential|injection|unsafe') { $isSecurity = $true; break } }
  } catch {}
  if ($text -match 'security|command[_ -]?injection|unsafe[_ -]?dynamic|invoke-expression|\biex\b|hardcoded[_ -]?(secret|credential|password)|auth[_ -]?bypass|path[_ -]?traversal') {
    $isSecurity = $true
  }
  if (-not $isSecurity) { return [pscustomobject]@{ applies=$false; ok=$true; verdict='allow'; reason='not-security'; detail='' } }

  $refs = @(Get-BacklogIntakeReferencedLines -Item $Item -ExistingFiles $ExistingFiles)
  $joined = ((@($refs | ForEach-Object { [string]$_.text }) -join "`n"))
  $hasReadableEvidence = (-not [string]::IsNullOrWhiteSpace($joined))
  $hasCommentOnlyReferencedLine = $false
  if ($refs.Count -gt 0) {
    $realLineRefs = @($refs | Where-Object { [int]$_.line -gt 0 })
    if ($realLineRefs.Count -gt 0) {
      $hasCommentOnlyReferencedLine = $true
      foreach ($r in $realLineRefs) {
        if (-not (Test-BacklogIntakeCommentOnlyLine -Line ([string]$r.text))) { $hasCommentOnlyReferencedLine = $false; break }
      }
    }
  }

  if ($text -match 'hardcoded[_ -]?(secret|credential|password)|password|secret|token|api[_ -]?key|credential') {
    if ($hasCommentOnlyReferencedLine) {
      return [pscustomobject]@{ applies=$true; ok=$false; verdict='drop'; reason='security false-positive: referenced line is comment-only'; detail='comment-only-secret' }
    }
    $secretRx = '(?i)(password|passwd|secret|token|api[_-]?key|apikey|credential)[A-Za-z0-9_.'']*\s*[:=]\s*["''][^"'']{6,}["'']'
    if ($joined -match $secretRx) {
      return [pscustomobject]@{ applies=$true; ok=$true; verdict='allow'; reason='secret-like assignment exists in referenced code'; detail='secret-assignment' }
    }
    return [pscustomobject]@{ applies=$true; ok=$false; verdict='held'; reason='security finding lacks concrete secret assignment evidence'; detail='weak-secret-evidence' }
  }

  if ($text -match 'unsafe[_ -]?dynamic|invoke-expression|\biex\b|command[_ -]?injection') {
    if ($hasCommentOnlyReferencedLine) {
      return [pscustomobject]@{ applies=$true; ok=$false; verdict='drop'; reason='security false-positive: referenced line is comment-only'; detail='comment-only-dynamic' }
    }
    if (-not $hasReadableEvidence) {
      return [pscustomobject]@{ applies=$true; ok=$false; verdict='held'; reason='security finding has no readable dynamic-execution evidence'; detail='no-dynamic-lines' }
    }
    if ($joined -match '(?i)\bInvoke-Expression\b|(^|[;&|({\s])iex(\s|$)|\[scriptblock\]::Create') {
      return [pscustomobject]@{ applies=$true; ok=$true; verdict='allow'; reason='dynamic execution primitive exists in referenced code'; detail='dynamic-exec' }
    }
    return [pscustomobject]@{ applies=$true; ok=$false; verdict='drop'; reason='security false-positive: no dynamic execution primitive in referenced code'; detail='no-dynamic-exec' }
  }

  if ($refs.Count -eq 0) {
    return [pscustomobject]@{ applies=$true; ok=$false; verdict='held'; reason='security finding has no readable code evidence'; detail='no-security-lines' }
  }
  return [pscustomobject]@{ applies=$true; ok=$false; verdict='held'; reason='security finding needs stronger verifier evidence before approved'; detail='generic-security-held' }
}

function Invoke-BacklogIntakeGate {
  param($Record)
  $allow = [pscustomobject]@{ gated=$false; action='allow'; status=[string](Get-BacklogPackObjectValue -Obj $Record -Name 'status' -Default ''); reason='not gated'; matched_id=''; evidence=$null }
  try {
    if (-not $Record) { return $allow }
    $status = ([string](Get-BacklogPackObjectValue -Obj $Record -Name 'status' -Default '')).ToLowerInvariant()
    if ($status -ne 'approved') { return $allow }
    if (-not (Test-BacklogPackItemAuditSource -Item $Record)) { return $allow }

    $scope = ([string](Get-BacklogPackObjectValue -Obj $Record -Name 'scope' -Default '')).ToLowerInvariant()
    if ($scope -eq 'project') { return $allow }

    $dupKeyObj = $null
    try { $dupKeyObj = Get-BacklogDuplicateCompactorKey -Item $Record } catch { $dupKeyObj = $null }
    if ($dupKeyObj) {
      $key = [string]$dupKeyObj.key
      foreach ($item in @(Get-Backlog)) {
        $st = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).ToLowerInvariant()
        if ($st -notin @('new','approved','held','running')) { continue }
        if (-not (Test-BacklogPackItemAuditSource -Item $item)) { continue }
        $itemKeyObj = $null
        try { $itemKeyObj = Get-BacklogDuplicateCompactorKey -Item $item } catch { $itemKeyObj = $null }
        if (-not $itemKeyObj) { continue }
        if ([string]$itemKeyObj.key -eq $key) {
          $mid = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
          if (-not [string]::IsNullOrWhiteSpace($mid)) {
            return [pscustomobject]@{
              gated = $true
              action = 'dedup'
              status = 'deduped'
              reason = 'intake duplicate: same root-cause finding is already open'
              matched_id = $mid
              evidence = [pscustomobject]@{ duplicate_key=$key; root=[string]$dupKeyObj.root; finding_type=[string]$dupKeyObj.finding_type }
            }
          }
        }
      }
    }

    $files = Get-BacklogIntakeGateFileEvidence -Item $Record
    $existing = @($files.existing)
    $missing = @($files.missing)
    $sec = Test-BacklogIntakeSecurityEvidence -Item $Record -ExistingFiles $existing
    if ($sec -and [bool]$sec.applies) {
      $action = if ([string]$sec.verdict -eq 'drop') { 'drop' } elseif ([string]$sec.verdict -eq 'held') { 'hold' } else { 'allow' }
      return [pscustomobject]@{
        gated = $true
        action = $action
        status = if ($action -eq 'drop') { 'auto-dropped' } elseif ($action -eq 'hold') { 'held' } else { 'approved' }
        reason = [string]$sec.reason
        matched_id = ''
        evidence = [pscustomobject]@{ existing_files=$existing; missing_files=$missing; security_detail=[string]$sec.detail }
      }
    }

    if ($existing.Count -gt 0) {
      return [pscustomobject]@{
        gated=$true
        action='allow'
        status='approved'
        reason='code target exists'
        matched_id=''
        evidence=[pscustomobject]@{ existing_files=$existing; missing_files=$missing }
      }
    }

    return [pscustomobject]@{
      gated=$true
      action='hold'
      status='held'
      reason='audit finding lacks readable code target evidence'
      matched_id=''
      evidence=[pscustomobject]@{ existing_files=$existing; missing_files=$missing }
    }
  } catch {
    return [pscustomobject]@{ gated=$true; action='hold'; status='held'; reason=('intake gate failed closed: ' + [string]$_.Exception.Message); matched_id=''; evidence=$null }
  }
}

function Get-BacklogPackLastRun {
  $p = Get-BacklogPackLatestPath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-BacklogPackPressure {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  $now = (Get-Date).ToUniversalTime()
  $recentCut = $now.AddMinutes(-[Math]::Abs([int]$Config.windowMinutes))
  $auditCut = $now.AddMinutes(-[Math]::Abs([int]$Config.auditWindowMinutes))
  $recent = 0
  $auditRecent = 0
  $openUnpacked = 0
  $sample = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in @(Get-Backlog)) {
    if (-not (Test-BacklogPackItemOpen -Item $item)) { continue }
    if (-not (Test-BacklogPackItemUnpacked -Item $item)) { continue }
    $openUnpacked++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($id) -and $sample.Count -lt 10) { [void]$sample.Add($id) }
    $ts = $null
    try { $ts = [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $item -Name 'ts' -Default '')).ToUniversalTime() } catch { $ts = $null }
    if ($ts -and $ts -ge $recentCut) { $recent++ }
    if ($ts -and $ts -ge $auditCut -and (Test-BacklogPackItemAuditSource -Item $item)) { $auditRecent++ }
  }
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  if ($recent -ge [int]$Config.burstCount) { [void]$reasons.Add(("burst:{0}/{1}m" -f $recent, [int]$Config.windowMinutes)) }
  if ($openUnpacked -ge [int]$Config.unpackedOpenCount) { [void]$reasons.Add(("open-unpacked:{0}" -f $openUnpacked)) }
  if ($auditRecent -ge [int]$Config.auditBurstCount) { [void]$reasons.Add(("audit-burst:{0}/{1}m" -f $auditRecent, [int]$Config.auditWindowMinutes)) }
  return [pscustomobject]@{
    needed                = ($reasons.Count -gt 0)
    reasons               = @($reasons.ToArray())
    recent_unpacked_open  = $recent
    open_unpacked         = $openUnpacked
    recent_audit_unpacked = $auditRecent
    sample_ids            = @($sample.ToArray())
    channel               = Get-BacklogPackChannel
  }
}

function Request-BacklogPackIfNeeded {
  param([string]$NewItemId = '')
  try {
    $cfg = Get-BacklogPackConfig
    if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ requested=$false; reason='disabled' } }
    $pressure = Get-BacklogPackPressure -Config $cfg
    if (-not [bool]$pressure.needed) { return [pscustomobject]@{ requested=$false; reason='below-threshold'; pressure=$pressure } }
    $requestPath = Get-BacklogPackRequestPath
    if (Test-Path -LiteralPath $requestPath) {
      return [pscustomobject]@{ requested=$true; existing=$true; path=$requestPath; pressure=$pressure }
    }
    $last = Get-BacklogPackLastRun
    if ($last) {
      try {
        $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
        $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
        if ($ageMin -lt [int]$cfg.cooldownMinutes) {
          return [pscustomobject]@{ requested=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
        }
      } catch {}
    }
    $req = [ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      channel = [string]$pressure.channel
      reasons = @($pressure.reasons)
      counts = [ordered]@{
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        open_unpacked = [int]$pressure.open_unpacked
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
      }
      sample_ids = @($pressure.sample_ids)
      new_item_id = [string]$NewItemId
    }
    $json = ($req | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path $requestPath -Content $json
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $req.ts
        action = 'pack-request'
        channel = [string]$pressure.channel
        reasons = @($pressure.reasons)
        open_unpacked = [int]$pressure.open_unpacked
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
        new_item_id = [string]$NewItemId
      })
    } catch {}
    return [pscustomobject]@{ requested=$true; existing=$false; path=$requestPath; pressure=$pressure }
  } catch {
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='pack-request-error'; error=[string]$_.Exception.Message }) } catch {}
    return [pscustomobject]@{ requested=$false; reason='error'; error=[string]$_.Exception.Message }
  }
}

function Add-BacklogWorkpackFileCandidate {
  param([System.Collections.Generic.List[string]]$List, [string]$Path)
  if ($null -eq $List) { return }
  $v = ([string]$Path).Trim().Trim(" `t`r`n""'`.,;")
  if ([string]::IsNullOrWhiteSpace($v)) { return }
  if ($v.StartsWith('./') -or $v.StartsWith('.\')) { $v = $v.Substring(2) }
  $v = $v.Replace('\', '/').ToLowerInvariant()
  while ($v.StartsWith('/')) { $v = $v.Substring(1) }
  if ([string]::IsNullOrWhiteSpace($v)) { return }
  if (-not $List.Contains($v)) { [void]$List.Add($v) }
}

function Get-BacklogWorkpackSignalText {
  param([string]$Text)
  $v = [string]$Text
  return ([regex]::Replace($v, '^\s*(?:\[[^\]]+\]\s*)+', ''))
}

function Get-BacklogWorkpackEditableSignalText {
  param([string]$Text)
  $base = Get-BacklogTextOutsideForbiddenContexts -Text ([string]$Text)
  if ([string]::IsNullOrWhiteSpace($base)) { return '' }
  $negativeTail = '(?i)\b(?:do\s+not|don''t|dont|never)\s+(?:edit|touch|modify|change|update|alter|write\s+to)\b|\b(?:forbidden|read[-_\s]*only\s+context|exclude|excluded|exclusions?|ignore)\b|\bonly\s+(?:as\s+)?(?:examples?|exclusions?|references?)\b|\bexamples?\s*/\s*exclusions?\b'
  $protectedOnly = '(?i)(?:^|[\s''"`(])(?:supervisor|watchdog|driver|server)\.ps1\b|(?:^|[\s''"`(])lib[\\/]circuit-breaker\.ps1\b|(?:^|[\s''"`(])control[\\/]\S+|\b(?:supervisor|watchdog|control[_ -]?plane|restart\.flag)\b'
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in [regex]::Split([string]$base, "\r?\n")) {
    $clean = [string]$line
    $m = [regex]::Match($clean, $negativeTail)
    if ($m.Success) {
      if ($m.Index -eq 0) {
        $clean = ''
      } elseif ($m.Value -match '(?i)only|examples?|exclusions?|references?') {
        $clean = [regex]::Replace($clean, $protectedOnly, ' ')
      } else {
        $clean = $clean.Substring(0, $m.Index)
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($clean)) { [void]$out.Add($clean) }
  }
  return (($out.ToArray()) -join "`n")
}

function Get-BacklogRelativeWorkpackPath {
  param([string]$Path)
  try {
    $root = [System.IO.Path]::GetFullPath((Get-BacklogFallbackBridgeRoot)).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ($full.Substring($root.Length).Replace('\', '/').ToLowerInvariant())
    }
  } catch {}
  return ((Split-Path -Leaf $Path).ToLowerInvariant())
}

function Get-BacklogFunctionFileMap {
  if ($script:BacklogFunctionFileMap) { return $script:BacklogFunctionFileMap }
  $map = @{}
  try {
    $root = Get-BacklogFallbackBridgeRoot
    $dirs = @($root, (Join-Path $root 'lib'), (Join-Path $root 'tools'))
    foreach ($dir in $dirs) {
      if (-not (Test-Path -LiteralPath $dir)) { continue }
      foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
        foreach ($m in [regex]::Matches($raw, '(?im)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b')) {
          $fn = $m.Groups[1].Value.ToLowerInvariant()
          if (-not $map.ContainsKey($fn)) { $map[$fn] = New-Object 'System.Collections.Generic.List[string]' }
          Add-BacklogWorkpackFileCandidate -List $map[$fn] -Path (Get-BacklogRelativeWorkpackPath -Path $file.FullName)
        }
      }
    }
  } catch {}
  $script:BacklogFunctionFileMap = $map
  return $script:BacklogFunctionFileMap
}

function Get-BacklogInferredFiles {
  param([string]$Text)
  $files = New-Object 'System.Collections.Generic.List[string]'
  $textRaw = Get-BacklogWorkpackEditableSignalText -Text $Text
  $t = $textRaw.ToLowerInvariant()

  try {
    $fnMap = Get-BacklogFunctionFileMap
    foreach ($m in [regex]::Matches($textRaw, '\b[A-Z][A-Za-z0-9]+-[A-Za-z0-9][A-Za-z0-9-]*\b')) {
      $fn = $m.Value.ToLowerInvariant()
      if (-not $fnMap.ContainsKey($fn)) { continue }
      foreach ($p in @($fnMap[$fn].ToArray())) { Add-BacklogWorkpackFileCandidate -List $files -Path $p }
    }
  } catch {}

  if ($t -match '(start-srv|start-drv|reap-bloated|process[_ -]?supervision|private memory|tracked processes|redirect stdout|stderr|log file path|bloated pid)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '(supervisor|watchdog|restart\.flag|explicit-flag|recycle|circuit-breaker|cooldown)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '(orphan[- ]restart|restart attribution|restart mechanism|restarts? without associated task|without associated task activity|restarts\.jsonl|circuit-breaker|cb-loop)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/circuit-breaker.ps1'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match 'taskkill\s+/pid\s+\$_\.processid') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '\bchannels\.ps1\b') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/channels.ps1'
  }
  if ($t -match '(get-backlogpath|add-idea|backlog path|backlog-curator|curator)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/backlog.ps1'
  }
  if (($t -match '(get-backlogpath|add-idea|backlog path)') -and ($t -match '(audit|deep-audit|audit-self-diag|drift analysis)')) {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'tools/audit.ps1'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/common.ps1'
  }
  if ($t -match '(backlog-add\.js|/api/backlog/add|post /api/backlog/add)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'tools/scenarios/backlog-add.js'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'server.ps1'
  }
  if ($t -match '(memory\.html|/memory|settings cells|api\(\).*503|transient 503|transient 502|transient 504)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'web/memory.html'
  }
  if ($t -match '(librarian|embedding|recall|vector|cosine)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/memory.ps1'
  }
  if ($t -match '(parallel dispatch|parallel worker|trivial-fallback|\[\[parallel|worktree (cleanup|janitor|merge|isolation|lock)|\bworktrees?\b.*(parallel|worker|merge))') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/parallel.ps1'
  }
  if ($t -match '(fast-lane|fast lane|intent classifier|классификатор намерений|detect-study|task_mode|discuss-mode|discuss prompt|discuss-промпт|codex exec.*unexpected argument|stdin-редирект|лишний [`''"]?-|explicit-инструкц|без дебатов)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'driver.ps1'
  }
  if ($t -match '(hardcoded[_ -]?secrets?|hardcoded paths?|configuration file|config file|environment variables|tool discovery|well-known installation)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'config.json'
  }
  if ($t -match '(feature verifier|features[/\\]state|features[/\\]registry|feature states|feature id|scenario_results)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'features/state.js'
  }

  return @($files.ToArray())
}

function Get-BacklogPrimaryWorkpackFile {
  param([string[]]$Files)
  $arr = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($arr.Count -eq 0) { return '' }
  foreach ($preferred in @(
      'lib/circuit-breaker.ps1',
      'supervisor.ps1',
      'canary.ps1',
      'driver.ps1',
      'server.ps1',
      'watchdog.ps1',
      'lib/common.ps1',
      'lib/backlog.ps1',
      'lib/channels.ps1',
      'tools/audit.ps1',
      'lib/parallel.ps1',
      'lib/memory.ps1',
      'web/memory.html',
      'features/state.js',
      'tools/scenarios/backlog-add.js',
      'config.json'
    )) {
    if ($arr -contains $preferred) { return $preferred }
  }
  return [string]$arr[0]
}

function Get-BacklogWorkpackModule {
  param([string]$Text, [string[]]$Files = @())
  $t = (Get-BacklogWorkpackEditableSignalText -Text $Text).ToLowerInvariant()
  $all = ((@($Files) + @($t)) -join ' ').ToLowerInvariant()
  if ($all -match 'lib/circuit-breaker\.ps1|orphan[- ]restart|restart attribution|restart mechanism|restarts? without associated task|restarts\.jsonl|cb-loop') { return 'safety' }
  if ($all -match '(^|\s)control/') { return 'safety' }
  if ($all -match 'supervisor\.ps1|start-srv|start-drv|reap-bloated|process[_ -]?supervision|private memory|tracked processes|bloated pid') { return 'supervisor' }
  if ($all -match 'watchdog|circuit|sandbox|security|preflight|permission|command[_ -]?injection|hardcoded[_ -]?secrets?|unsafe[_ -]?dynamic[_ -]?execution|dynamic execution|invoke-expression|taskkill|shelling out|sanitize|sanitise|allowlist|защит') { return 'safety' }
  if ($all -match 'features/state\.(js|json)|features/registry|feature states|feature id|scenario_results|state|snapshot|restart|resume') { return 'state' }
  if ($all -match 'audit|deep-audit|finding|scenario|doctor|аудит') { return 'audit' }
  if ($all -match 'backlog|curator|idea|approve|approval|held|workpack|беклог|бэклог') { return 'backlog' }
  if ($all -match 'memory|librarian|embedding|recall|памят') { return 'memory' }
  if ($all -match 'web/index\.html|web/memory\.html|\bui\b|badge|status badge|frontend|интерфейс') { return 'ui' }
  if ($all -match 'llm|codex|claude|gemini|deepseek|timeout|model') { return 'llm' }
  if ($all -match 'parallel|lane|worktree|concurrent|паралл') { return 'parallel' }
  if ($all -match 'readme|docs|documentation|runbook|guide|докум') { return 'docs' }
  return 'general'
}

function Get-BacklogTaskTargetFile {
  # 2026-05-31 (Foundation #4): the file a task is meant to EDIT — the path right after the action
  # verb (Перепиши/Создай/реализуй <file>), NOT a reference/эталон path cited later in the prompt.
  # Without this, redesign tasks that all referenced the same эталон (HeroSection.tsx) collapsed into
  # ONE workpack and ran serial. Returns '' if no clear target file.
  param([string]$Text)
  $t = [string]$Text
  if ([string]::IsNullOrWhiteSpace($t)) { return '' }
  $rx = '(?im)(?:перепиши|создай|реализуй|оформлени[ея]|приведи|измени|изменить|исправь|исправить|обнови|обновить|добавь|добавить|доработай|доработать|change|modify|update|edit|fix)[^\n]{0,90}?((?:src|app|content|public|prisma|config|styles|components|pages|api|lib|driver)[\\/][\w./\-\[\]]+\.\w{1,5})'
  $m = [regex]::Match($t, $rx)
  if ($m.Success) { return ($m.Groups[1].Value -replace '\\', '/') }
  return ''
}

function Get-BacklogWorkpackConflictGroup {
  param([string]$Text, [string[]]$Files = @())
  $Text = Get-BacklogWorkpackEditableSignalText -Text $Text
  # 2026-05-31 (Foundation #4 scale): for a PROJECT channel, group by the TARGET file FIRST — BEFORE
  # the bridge-module patterns below, which falsely match project text ("UI", "DESIGN.md", "frontend")
  # and collapsed redesign tasks into one 'ui'/'docs' group => serial. Different target files =>
  # different groups => parallel; same target file => same group => serial (correct).
  $isProjectCh = $false
  try {
    if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
      $prc = Get-EffectiveProjectRoot
      $isProjectCh = (-not [string]::IsNullOrWhiteSpace([string]$prc) -and ([string]$prc -ne (Get-BridgeRoot)))
    }
  } catch {}
  if ($isProjectCh) {
    $tgt = Get-BacklogTaskTargetFile -Text $Text
    if ([string]::IsNullOrWhiteSpace($tgt) -and @($Files).Count -gt 0) { $tgt = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object | Select-Object -First 1) }
    if ($tgt) { $n = ([string]$tgt).ToLowerInvariant() -replace '\\', '/'; return ('file:' + ($n -replace '[^a-z0-9/._-]+', '-')) }
    return 'general'
  }
  $signalText = Get-BacklogWorkpackSignalText -Text $Text
  $all = ((@($Files) + @([string]$signalText)) -join ' ').ToLowerInvariant()
  if ($all -match '(^|/)(driver|server)\.ps1|lib/common\.ps1|lib/channels\.ps1') { return 'core' }
  if ($all -match '(^|\s)control/') { return 'safety' }
  if ($all -match 'supervisor\.ps1|lib/circuit-breaker\.ps1|watchdog|supervisor|start-srv|start-drv|reap-bloated|orphan[- ]restart|restart attribution|circuit|sandbox|security|preflight|permissions|command[_ -]?injection|hardcoded[_ -]?secrets?|unsafe[_ -]?dynamic[_ -]?execution|dynamic execution|invoke-expression|taskkill|shelling out|sanitize|sanitise|allowlist|защит') { return 'safety' }
  if ($all -match 'features/state\.(js|json)|features/registry|feature states|feature id|scenario_results|state|restart') { return 'state' }
  if ($all -match 'audit|doctor|scenario') { return 'audit' }
  if ($all -match 'backlog|curator|workpack') { return 'backlog' }
  if ($all -match 'memory|librarian|embedding') { return 'memory' }
  if ($all -match 'web/|\bui\b|badge|frontend') { return 'ui' }
  if ($all -match 'llm|codex|claude|gemini|deepseek') { return 'llm' }
  if ($all -match 'parallel|worktree|lane') { return 'parallel' }
  if ($all -match '\.md|docs/|readme|runbook|guide') { return 'docs' }
  return 'general'
}

function New-BacklogWorkpackId {
  param([string]$Key)
  $slug = ([string]$Key).ToLowerInvariant() -replace '[^a-z0-9]+','-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'general' }
  if ($slug.Length -gt 36) { $slug = $slug.Substring(0, 36).Trim('-') }
  return ('wp-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMddHHmmss'), $slug, ([guid]::NewGuid().ToString('N').Substring(0,6)))
}

function ConvertTo-BacklogScopeFileList {
  param($Value)
  $out = New-Object 'System.Collections.Generic.List[string]'
  if ($null -eq $Value) { return $out }
  foreach ($raw in @($Value)) {
    if ($null -eq $raw) { continue }
    $text = [string]$raw
    foreach ($line in ($text -split "`r?`n")) {
      $s = ([string]$line).Trim()
      if ([string]::IsNullOrWhiteSpace($s)) { continue }
      $s = $s -replace '^[-*]\s+', ''
      foreach ($part in ($s -split ',')) {
        $p = ([string]$part).Trim().Trim(" `t`r`n""'`.,;")
        if ($p.StartsWith('./') -or $p.StartsWith('.\')) { $p = $p.Substring(2) }
        $p = $p -replace '\\','/'
        while ($p.StartsWith('/')) { $p = $p.Substring(1) }
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$out.Add($p.ToLowerInvariant()) }
      }
    }
  }
  return $out
}

function Test-BacklogScopeContractForbidden {
  param([string]$Path, $Forbidden)
  $norm = ([string]$Path).Trim().ToLowerInvariant() -replace '\\','/'
  if ([string]::IsNullOrWhiteSpace($norm)) { return $false }
  foreach ($f in @($Forbidden)) {
    $fn = ([string]$f).Trim().ToLowerInvariant() -replace '\\','/'
    if ([string]::IsNullOrWhiteSpace($fn)) { continue }
    if ($fn -eq $norm) { return $true }
    if ($fn.EndsWith('/*')) {
      $prefix = $fn.Substring(0, $fn.Length - 1)
      if ($norm.StartsWith($prefix)) { return $true }
    }
  }
  return $false
}

function Remove-BacklogScopeContractReferences {
  param([string]$Text, $ScopeContract)
  $out = [string]$Text
  if ([string]::IsNullOrWhiteSpace($out) -or $null -eq $ScopeContract) { return $out }
  foreach ($raw in (@($ScopeContract.forbidden_files) + @($ScopeContract.read_only_context))) {
    $v = ([string]$raw).Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    $norm = $v -replace '\\','/'
    if ($norm.EndsWith('/*')) {
      $prefix = [regex]::Escape($norm.Substring(0, $norm.Length - 1)).Replace('/', '[\\/]')
      $out = [regex]::Replace($out, $prefix + '\S*', ' ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } else {
      $pattern = [regex]::Escape($norm).Replace('/', '[\\/]')
      $out = [regex]::Replace($out, $pattern, ' ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
  }
  return $out
}

function Add-BacklogScopeSectionValues {
  param(
    [System.Collections.Generic.List[string]]$Expected,
    [System.Collections.Generic.List[string]]$Forbidden,
    [System.Collections.Generic.List[string]]$ReadOnly,
    [System.Collections.Generic.List[string]]$RiskArea,
    [string]$Mode,
    $Value
  )
  foreach ($v in @(ConvertTo-BacklogScopeFileList $Value)) {
    switch ($Mode) {
      'expected'  { [void]$Expected.Add($v) }
      'forbidden' { [void]$Forbidden.Add($v) }
      'readonly'  { [void]$ReadOnly.Add($v) }
      'risk'      { [void]$RiskArea.Add($v) }
    }
  }
}

function Get-BacklogTaskScopeContract {
  param($Item)
  $expected = New-Object 'System.Collections.Generic.List[string]'
  $forbidden = New-Object 'System.Collections.Generic.List[string]'
  $readOnly = New-Object 'System.Collections.Generic.List[string]'
  $riskArea = New-Object 'System.Collections.Generic.List[string]'

  Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode 'expected' -Value (Get-BacklogPackObjectValue -Obj $Item -Name 'expected_files' -Default @())
  Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode 'forbidden' -Value (Get-BacklogPackObjectValue -Obj $Item -Name 'forbidden_files' -Default @())
  Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode 'readonly' -Value (Get-BacklogPackObjectValue -Obj $Item -Name 'read_only_context' -Default @())
  Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode 'risk' -Value (Get-BacklogPackObjectValue -Obj $Item -Name 'risk_area' -Default @())

  $bodyText = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  $taskText = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'task' -Default '')
  foreach ($src in @($bodyText, $taskText)) {
    if ([string]::IsNullOrWhiteSpace($src)) { continue }
    $mode = ''
    foreach ($line in ($src -split "`r?`n")) {
      $trimmed = ([string]$line).Trim()
      if ($trimmed -match '^(EXPECTED_FILES|FORBIDDEN_FILES|READ_ONLY_CONTEXT|RISK_AREA)\s*:\s*(.*)$') {
        $name = $Matches[1].ToUpperInvariant()
        $inline = [string]$Matches[2]
        switch ($name) {
          'EXPECTED_FILES' { $mode = 'expected' }
          'FORBIDDEN_FILES' { $mode = 'forbidden' }
          'READ_ONLY_CONTEXT' { $mode = 'readonly' }
          'RISK_AREA' { $mode = 'risk' }
        }
        if (-not [string]::IsNullOrWhiteSpace($inline)) {
          Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode $mode -Value $inline
          $mode = ''
        }
        continue
      }
      if ($trimmed -match '^[A-Z_]{3,}\s*:?\s*$' -or $trimmed -match '^[A-Za-z][A-Za-z0-9 _-]{1,40}:\s*$') { $mode = ''; continue }
      if ([string]::IsNullOrWhiteSpace($mode)) { continue }
      Add-BacklogScopeSectionValues -Expected $expected -Forbidden $forbidden -ReadOnly $readOnly -RiskArea $riskArea -Mode $mode -Value $trimmed
    }
  }

  return [pscustomobject]@{
    expected_files        = @($expected.ToArray() | Sort-Object -Unique)
    forbidden_files       = @($forbidden.ToArray() | Sort-Object -Unique)
    read_only_context     = @($readOnly.ToArray() | Sort-Object -Unique)
    risk_area             = @($riskArea.ToArray() | Sort-Object -Unique)
    has_explicit_expected = ($expected.Count -gt 0)
  }
}

function Get-BacklogWorkpackClassification {
  param($Item)
  $scopeContract = Get-BacklogTaskScopeContract -Item $Item
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  $signalText = Get-BacklogWorkpackEditableSignalText -Text $text
  $scopeSignalText = Remove-BacklogScopeContractReferences -Text $signalText -ScopeContract $scopeContract
  $fileList = New-Object 'System.Collections.Generic.List[string]'
  if ([bool]$scopeContract.has_explicit_expected) {
    foreach ($f in @($scopeContract.expected_files)) {
      if ((Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.forbidden_files) -or
          (Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.read_only_context)) { continue }
      Add-BacklogWorkpackFileCandidate -List $fileList -Path $f
    }
  } else {
    foreach ($f in @(Get-BacklogMentionedFiles -Text $scopeSignalText | Sort-Object)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
    foreach ($f in @(Get-BacklogInferredFiles -Text $scopeSignalText)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
    if ($scopeContract.forbidden_files.Count -gt 0 -or $scopeContract.read_only_context.Count -gt 0) {
      $filtered = New-Object 'System.Collections.Generic.List[string]'
      foreach ($f in @($fileList.ToArray())) {
        if ((Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.forbidden_files) -or
            (Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.read_only_context)) { continue }
        [void]$filtered.Add($f)
      }
      $fileList = $filtered
    }
  }
  $files = @($fileList.ToArray())
  $classificationText = $scopeSignalText
  if ([bool]$scopeContract.has_explicit_expected) {
    $classificationText = ((@($scopeContract.expected_files) + @($scopeContract.risk_area)) -join ' ')
  }
  $module = Get-BacklogWorkpackModule -Text $classificationText -Files $files
  $touch = @()
  $key = ''
  if ($files.Count -gt 0) {
    # 2026-05-31 (Foundation #4): prefer the task's TARGET file (after the action verb) over an
    # эталон/reference path, so independent tasks land in distinct workpacks and run in parallel.
    $primary = ''
    if (-not [bool]$scopeContract.has_explicit_expected) { $primary = Get-BacklogTaskTargetFile -Text $scopeSignalText }
    if ([string]::IsNullOrWhiteSpace($primary)) { $primary = Get-BacklogPrimaryWorkpackFile -Files $files }
    $touch = @((@($primary) + @($files)) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -First 8)
    # 2026-06-01 (Foundation #4 scale): for a PROJECT channel, key by the FULL file path so that N
    # tasks editing N different files form N workpacks (=> up to N parallel streams). Bridge keeps
    # dir-level-2 grouping (serial-by-module on a shared tree). Without this, e.g. docs/scale-test/*
    # all collapsed into ONE 'file:docs/scale-test' workpack and the batch took only ~2.
    $isProjectCh = $false
    try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $prk = Get-EffectiveProjectRoot; $isProjectCh = (-not [string]::IsNullOrWhiteSpace([string]$prk) -and ([string]$prk -ne (Get-BridgeRoot))) } } catch {}
    if ($isProjectCh) {
      $key = 'file:' + (([string]$primary).ToLowerInvariant())
    } elseif ($primary -match '^(lib|tools|web|memory|control|docs|channels)/') {
      $parts = $primary -split '/'
      if ($parts.Count -ge 2) { $key = 'file:' + $parts[0] + '/' + $parts[1] }
      else { $key = 'file:' + $primary }
    } else {
      $key = 'file:' + $primary
    }
  } else {
    $keywords = @(Get-BacklogIdeaKeywords -Text $text | Select-Object -First 2)
    if ($module -ne 'general') { $key = 'module:' + $module }
    elseif ($keywords.Count -gt 0) { $key = 'module:' + $module + ':' + (($keywords | ForEach-Object { [string]$_ }) -join '-') }
    else { $key = 'module:' + $module }
    $touch = @($module)
  }
  if ([string]::IsNullOrWhiteSpace($key)) { $key = 'module:general' }
  $conflict = Get-BacklogWorkpackConflictGroup -Text $classificationText -Files $files
  return [pscustomobject]@{
    key            = $key.ToLowerInvariant()
    touch_set      = @($touch)
    conflict_group = $conflict
    lane_hint      = ('serial:' + $conflict)
  }
}

function Invoke-BacklogPacker {
  param([string[]]$Reason = @('manual'), $Config = $null)
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  if (-not [bool]$Config.enabled) { return [pscustomobject]@{ ran=$false; reason='disabled'; packed_items=0; workpack_count=0 } }

  return (Invoke-BacklogLocked {
    $items = @(Get-Backlog)
    $candidates = @($items | Where-Object { (Test-BacklogPackItemOpen -Item $_) -and (Test-BacklogPackItemUnpacked -Item $_) })
    if ($candidates.Count -lt [int]$Config.minItems) {
      return [pscustomobject]@{ ran=$true; reason='not-enough-items'; packed_items=0; workpack_count=0; candidate_count=$candidates.Count }
    }

    $groups = @{}
    $classes = @{}
    foreach ($item in $candidates) {
      $class = Get-BacklogWorkpackClassification -Item $item
      $key = [string]$class.key
      if ([string]::IsNullOrWhiteSpace($key)) { $key = 'module:general' }
      if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object 'System.Collections.Generic.List[object]' }
      [void]$groups[$key].Add($item)
      $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
      if (-not [string]::IsNullOrWhiteSpace($id)) { $classes[$id] = $class }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $packSummaries = New-Object 'System.Collections.Generic.List[object]'
    $packed = 0
    foreach ($key in @($groups.Keys | Sort-Object)) {
      $groupItems = @($groups[$key].ToArray())
      if ($groupItems.Count -eq 0) { continue }
      $packId = New-BacklogWorkpackId -Key $key
      $firstClass = $null
      foreach ($g in $groupItems) {
        $gid = [string](Get-BacklogPackObjectValue -Obj $g -Name 'id' -Default '')
        if ($classes.ContainsKey($gid)) { $firstClass = $classes[$gid]; break }
      }
      if (-not $firstClass) { $firstClass = [pscustomobject]@{ touch_set=@('general'); conflict_group='general'; lane_hint='serial:general' } }
      $ids = @()
      foreach ($g in $groupItems) {
        $gid = [string](Get-BacklogPackObjectValue -Obj $g -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($gid)) { $ids += $gid }
        $g | Add-Member -NotePropertyName workpack_id -NotePropertyValue $packId -Force
        $g | Add-Member -NotePropertyName workpack_ts -NotePropertyValue $now -Force
        $g | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue $key -Force
        $g | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($firstClass.touch_set) -Force
        $g | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$firstClass.conflict_group) -Force
        $g | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ([string]$firstClass.lane_hint) -Force
        $g | Add-Member -NotePropertyName workpack_status -NotePropertyValue 'planned' -Force
        $g | Add-Member -NotePropertyName workpack_reason -NotePropertyValue ((@($Reason) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ',') -Force
        $g | Add-Member -NotePropertyName workpack_size -NotePropertyValue $groupItems.Count -Force
        $packed++
      }
      [void]$packSummaries.Add([ordered]@{
        id = $packId
        key = $key
        size = $groupItems.Count
        conflict_group = [string]$firstClass.conflict_group
        touch_set = @($firstClass.touch_set)
        item_ids = @($ids)
      })
    }

    if ($packed -gt 0) { Save-Backlog $items }
    $summary = [ordered]@{
      ts = $now
      channel = Get-BacklogPackChannel
      reason = @($Reason)
      packed_items = $packed
      workpack_count = $packSummaries.Count
      workpacks = @($packSummaries.ToArray())
    }
    $latestJson = ($summary | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path (Get-BacklogPackLatestPath) -Content $latestJson
    $line = $summary | ConvertTo-Json -Compress -Depth 6
    [System.IO.File]::AppendAllText((Get-BacklogPackRunsPath), ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $now
        action = 'pack-run'
        channel = [string]$summary.channel
        reason = @($Reason)
        packed_items = $packed
        workpack_count = $packSummaries.Count
      })
    } catch {}
    return [pscustomobject]@{
      ran = $true
      packed_items = $packed
      workpack_count = $packSummaries.Count
      workpacks = @($packSummaries.ToArray())
    }
  }.GetNewClosure())
}

function Invoke-BacklogPackerIfDue {
  $cfg = Get-BacklogPackConfig
  if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ ran=$false; reason='disabled'; packed_items=0; workpack_count=0 } }
  $requestPath = Get-BacklogPackRequestPath
  if (-not (Test-Path -LiteralPath $requestPath)) { return [pscustomobject]@{ ran=$false; reason='no-request'; packed_items=0; workpack_count=0 } }
  $req = $null
  try { $req = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  $last = Get-BacklogPackLastRun
  if ($last) {
    try {
      $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
      if ((((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes) -lt [int]$cfg.cooldownMinutes) {
        return [pscustomobject]@{ ran=$false; reason='cooldown'; packed_items=0; workpack_count=0 }
      }
    } catch {}
  }
  $reason = @('request')
  try {
    if ($req -and ($req.PSObject.Properties.Name -contains 'reasons')) { $reason = @($req.reasons | ForEach-Object { [string]$_ }) }
  } catch {}
  if ($reason.Count -eq 0) { $reason = @('request') }
  $result = Invoke-BacklogPacker -Reason $reason -Config $cfg
  $dedupeRun = $null
  if ($result -and [bool]$result.ran) {
    try { $dedupeRun = Invoke-BacklogDuplicateCompactor -Config $cfg -Reason (@($reason) + @('after-pack')) } catch { $dedupeRun = $null }
    if ($dedupeRun) {
      try {
        $result | Add-Member -NotePropertyName duplicate_compactor -NotePropertyValue $dedupeRun -Force
        $result | Add-Member -NotePropertyName duplicates_rejected -NotePropertyValue ([int]$dedupeRun.duplicates_rejected) -Force
      } catch {}
    }
  }
  if ($result -and [bool]$result.ran) {
    try { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue } catch {}
  }
  return $result
}

function Update-BacklogWorkpackClassifications {
  param([string[]]$Statuses = @('new','approved','held'))
  $allowed = @{}
  foreach ($s in @($Statuses)) {
    $v = ([string]$s).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($v)) { $allowed[$v] = $true }
  }
  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $getObjectValueFn = ${function:Get-BacklogPackObjectValue}
  $getClassificationFn = ${function:Get-BacklogWorkpackClassification}
  $writeBacklogJsonLineFn = ${function:Write-BacklogJsonLine}
  return (Invoke-BacklogLocked {
    $items = @(& $getBacklogFn)
    $updated = 0
    foreach ($item in $items) {
      $status = ([string](& $getObjectValueFn -Obj $item -Name 'status' -Default '')).ToLowerInvariant()
      if (-not $allowed.ContainsKey($status)) { continue }
      if ([string]::IsNullOrWhiteSpace([string](& $getObjectValueFn -Obj $item -Name 'workpack_id' -Default ''))) { continue }
      $class = & $getClassificationFn -Item $item
      $newTouch = @($class.touch_set | ForEach-Object { [string]$_ })
      $oldTouch = @(& $getObjectValueFn -Obj $item -Name 'workpack_touch_set' -Default @() | ForEach-Object { [string]$_ })
      $oldKey = [string](& $getObjectValueFn -Obj $item -Name 'workpack_root_cause_key' -Default '')
      $oldGroup = [string](& $getObjectValueFn -Obj $item -Name 'workpack_conflict_group' -Default '')
      $changed = $false
      if ($oldKey -ne [string]$class.key) { $changed = $true }
      if ($oldGroup -ne [string]$class.conflict_group) { $changed = $true }
      if ((@($oldTouch) -join '|') -ne ((@($newTouch)) -join '|')) { $changed = $true }
      if (-not $changed) { continue }
      $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue ([string]$class.key) -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($newTouch) -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$class.conflict_group) -Force
      $item | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ([string]$class.lane_hint) -Force
      $item | Add-Member -NotePropertyName workpack_reclassified_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $updated++
    }
    if ($updated -gt 0) {
      & $saveBacklogFn $items
      try { & $writeBacklogJsonLineFn ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='workpack-reclassify'; updated=$updated; statuses=@($Statuses) }) } catch {}
    }
    return $updated
  }.GetNewClosure())
}

function Get-BacklogWorkpackExecConfig {
  $cfg = [ordered]@{
    enabled          = $true
    minItems         = 2
    maxItems         = 6
    includeProtected = $false
    serialProtectedEnabled = $true
    serialProtectedMinItems = 3
    serialProtectedMaxItems = 8
  }
  $dotted = @{
    'workpackExec.enabled'          = 'enabled'
    'workpackExec.minItems'         = 'minItems'
    'workpackExec.maxItems'         = 'maxItems'
    'workpackExec.includeProtected' = 'includeProtected'
    'workpackExec.serialProtectedEnabled' = 'serialProtectedEnabled'
    'workpackExec.serialProtectedMinItems' = 'serialProtectedMinItems'
    'workpackExec.serialProtectedMaxItems' = 'serialProtectedMaxItems'
  }
  $flat = @{
    workpackExecEnabled          = 'enabled'
    workpackExecMinItems         = 'minItems'
    workpackExecMaxItems         = 'maxItems'
    workpackExecIncludeProtected = 'includeProtected'
    workpackExecSerialProtectedEnabled = 'serialProtectedEnabled'
    workpackExecSerialProtectedMinItems = 'serialProtectedMinItems'
    workpackExecSerialProtectedMaxItems = 'serialProtectedMaxItems'
  }
  try {
    if (Get-Command Get-AdvancedSettings -ErrorAction SilentlyContinue) {
      $adv = Get-AdvancedSettings
      foreach ($k in $dotted.Keys) {
        if ($adv -and $adv.Contains($k) -and $null -ne $adv[$k]) { $cfg[$dotted[$k]] = $adv[$k] }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.minItems = ConvertTo-BacklogPackInt -Value $cfg.minItems -Default 2 -Min 2 -Max 12
  $cfg.maxItems = ConvertTo-BacklogPackInt -Value $cfg.maxItems -Default 6 -Min 2 -Max 24
  $cfg.includeProtected = ConvertTo-BacklogPackBool -Value $cfg.includeProtected -Default $false
  $cfg.serialProtectedEnabled = ConvertTo-BacklogPackBool -Value $cfg.serialProtectedEnabled -Default $true
  $cfg.serialProtectedMinItems = ConvertTo-BacklogPackInt -Value $cfg.serialProtectedMinItems -Default 3 -Min 2 -Max 24
  $cfg.serialProtectedMaxItems = ConvertTo-BacklogPackInt -Value $cfg.serialProtectedMaxItems -Default 8 -Min 2 -Max 40
  if ([int]$cfg.maxItems -lt [int]$cfg.minItems) { $cfg.maxItems = [int]$cfg.minItems }
  if ([int]$cfg.serialProtectedMaxItems -lt [int]$cfg.serialProtectedMinItems) { $cfg.serialProtectedMaxItems = [int]$cfg.serialProtectedMinItems }
  return [pscustomobject]$cfg
}

function Get-BacklogWorkpackItemTouches {
  param($Item)
  $scopeContract = Get-BacklogTaskScopeContract -Item $Item
  $touches = New-Object 'System.Collections.Generic.List[string]'
  # 2026-06-01 ROOT FIX (parallelism / "bridge as a team"): prefer the SINGLE target file the task
  # actually EDITS (action verb + path), not every path it mentions. redesign tasks cite a shared
  # эталон (HeroSection.tsx) as a reference; the stored workpack_touch_set captured that эталон, so
  # EVERY task overlapped on herosection.ts and the packer treated 6 independent file edits as mutually
  # conflicting -> serial execution. The target file is the only path written, so overlap then reflects
  # REAL conflicts. Falls back to the stored touch_set / mentioned files when no clear target exists.
  $touchText = Get-BacklogWorkpackEditableSignalText -Text ([string]$Item.text)
  $touchText = Remove-BacklogScopeContractReferences -Text $touchText -ScopeContract $scopeContract
  if ([bool]$scopeContract.has_explicit_expected) {
    foreach ($f in @($scopeContract.expected_files)) {
      if ((Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.forbidden_files) -or
          (Test-BacklogScopeContractForbidden -Path $f -Forbidden $scopeContract.read_only_context)) { continue }
      $v = ([string]$f).Trim().ToLowerInvariant() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$touches.Add($v) }
    }
  }
  try {
    if ($touches.Count -eq 0 -and (Get-Command Get-BacklogTaskTargetFile -ErrorAction SilentlyContinue)) {
      $tgt = [string](Get-BacklogTaskTargetFile -Text $touchText)
      if (-not [string]::IsNullOrWhiteSpace($tgt)) {
        $tv = $tgt.Trim().ToLowerInvariant() -replace '\\','/'
        if (-not [string]::IsNullOrWhiteSpace($tv)) { [void]$touches.Add($tv) }
      }
    }
  } catch {}
  try {
    if ($touches.Count -eq 0) {
    foreach ($t in @(Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_touch_set' -Default @())) {
      $v = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$touches.Add($v) }
    }
    }
  } catch {}
  if ($touches.Count -eq 0) {
    try {
      foreach ($f in @(Get-BacklogMentionedFiles -Text $touchText)) {
        $v = ([string]$f).Trim().ToLowerInvariant() -replace '\\','/'
        if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$touches.Add($v) }
      }
    } catch {}
  }
  if ($touches.Count -eq 0) {
    $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($cg)) { [void]$touches.Add($cg) }
  }
  if ($scopeContract.forbidden_files.Count -gt 0 -or $scopeContract.read_only_context.Count -gt 0) {
    $allowed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in @($touches.ToArray())) {
      if ((Test-BacklogScopeContractForbidden -Path $t -Forbidden $scopeContract.forbidden_files) -or
          (Test-BacklogScopeContractForbidden -Path $t -Forbidden $scopeContract.read_only_context)) { continue }
      [void]$allowed.Add($t)
    }
    $touches = $allowed
  }
  return @($touches.ToArray() | Sort-Object -Unique)
}

function Test-BacklogWorkpackTouchesOverlap {
  param([string[]]$Left, [string[]]$Right)
  $seen = @{}
  foreach ($l in @($Left)) {
    $v = ([string]$l).Trim().ToLowerInvariant() -replace '\\','/'
    if (-not [string]::IsNullOrWhiteSpace($v)) { $seen[$v] = $true }
  }
  foreach ($r in @($Right)) {
    $v = ([string]$r).Trim().ToLowerInvariant() -replace '\\','/'
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    if ($seen.ContainsKey($v)) { return $true }
  }
  return $false
}

function Get-BacklogWorkpackTouchOverlap {
  param([string[]]$Left, [string[]]$Right)
  $seen = @{}
  foreach ($l in @($Left)) {
    $v = ([string]$l).Trim().ToLowerInvariant() -replace '\\','/'
    if (-not [string]::IsNullOrWhiteSpace($v)) { $seen[$v] = $true }
  }
  $overlap = New-Object 'System.Collections.Generic.List[string]'
  foreach ($r in @($Right)) {
    $v = ([string]$r).Trim().ToLowerInvariant() -replace '\\','/'
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    if ($seen.ContainsKey($v) -and -not $overlap.Contains($v)) { [void]$overlap.Add($v) }
  }
  return @($overlap.ToArray())
}

function Get-BacklogWorkpackItemEditTouches {
  param($Item)
  $scopeContract = Get-BacklogTaskScopeContract -Item $Item
  $touches = New-Object 'System.Collections.Generic.List[string]'
  foreach ($prop in @('edit_touches','files')) {
    foreach ($t in @(Get-BacklogPackObjectValue -Obj $Item -Name $prop -Default @())) {
      $v = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
      if ([string]::IsNullOrWhiteSpace($v)) { continue }
      if ((Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.forbidden_files) -or
          (Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.read_only_context)) { continue }
      if (-not $touches.Contains($v)) { [void]$touches.Add($v) }
    }
    if ($touches.Count -gt 0) { break }
  }
  if ($touches.Count -eq 0) {
    foreach ($prop in @('touch_set','workpack_touch_set')) {
      foreach ($t in @(Get-BacklogPackObjectValue -Obj $Item -Name $prop -Default @())) {
        $v = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        # 2026-06-12 W1b: the packer stamps the COARSE conflict group ('general', 'llm', 'core')
        # into workpack_touch_set — a bare word, not a file. Treating it as a touch pre-empted
        # the Files:-from-text parse below, so the batch [[PARALLEL]] blocks carried
        # "Files: general" and every worker stream got quarantined as outside-touch (the wasted
        # first wave, ~9 min). Only path-like values (a '/' or an extension dot) are touches.
        if ($v -notmatch '[./]') { continue }
        if ((Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.forbidden_files) -or
            (Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.read_only_context)) { continue }
        if (-not $touches.Contains($v)) { [void]$touches.Add($v) }
      }
      if ($touches.Count -gt 0) { break }
    }
  }
  if ($touches.Count -eq 0) {
    # 2026-06-11 W1 (width precondition): many atoms declare their files only as a "Files: a, b"
    # line INSIDE the task text, not in an edit_touches/files metadata field. Without this the
    # touch-set was empty and EVERY such atom fell through to the coarse conflict_group fallback
    # -> all got group 'general' -> the frontier serialized them (the benchmark's width=2-not-6).
    # This MUST run before Get-BacklogWorkpackItemTouches below, which returns the coarse group as
    # a touch and would otherwise pre-empt this. Parse path-like tokens from the Files: segment so
    # A3/A4 (touch-overlap as the parallelism authority) actually have a real touch-set to compare.
    $itemText = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($itemText)) {
      $filesMatch = [regex]::Match($itemText, '(?is)\bFiles?\s*:\s*(.+?)(?:\bAcceptance\b|\bChecks?\b|[\r\n]|$)')
      if ($filesMatch.Success) {
        foreach ($pathMatch in [regex]::Matches([string]$filesMatch.Groups[1].Value, '[A-Za-z0-9_/\\-]+\.[A-Za-z][A-Za-z0-9]{0,5}')) {
          $v = ([string]$pathMatch.Value).Trim().ToLowerInvariant() -replace '\\','/'
          if ([string]::IsNullOrWhiteSpace($v)) { continue }
          if ((Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.forbidden_files) -or
              (Test-BacklogScopeContractForbidden -Path $v -Forbidden $scopeContract.read_only_context)) { continue }
          if (-not $touches.Contains($v)) { [void]$touches.Add($v) }
        }
      }
    }
  }
  if ($touches.Count -eq 0) {
    foreach ($t in @(Get-BacklogWorkpackItemTouches -Item $Item)) {
      $v = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v) -and -not $touches.Contains($v)) { [void]$touches.Add($v) }
    }
  }
  if ($touches.Count -eq 0) {
    $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($cg)) { [void]$touches.Add($cg) }
  }
  return @($touches.ToArray() | Sort-Object -Unique)
}

function ConvertTo-BacklogWorkpackStringArray {
  param($Value)
  $items = New-Object 'System.Collections.Generic.List[string]'
  foreach ($v in @($Value)) {
    $s = ([string]$v).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    if (-not $items.Contains($s)) { [void]$items.Add($s) }
  }
  return @($items.ToArray())
}

function Get-BacklogWorkpackItemFileList {
  param($Item)
  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($prop in @('edit_touches','files','touch_set','workpack_touch_set')) {
    foreach ($f in @(ConvertTo-BacklogWorkpackStringArray (Get-BacklogPackObjectValue -Obj $Item -Name $prop -Default @()))) {
      $v = ([string]$f).Trim() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v) -and -not $files.Contains($v)) { [void]$files.Add($v) }
    }
  }
  if ($files.Count -eq 0) {
    foreach ($t in @(Get-BacklogWorkpackItemTouches -Item $Item)) {
      $v = ([string]$t).Trim() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v) -and -not $files.Contains($v)) { [void]$files.Add($v) }
    }
  }
  return @($files.ToArray())
}

function Test-BacklogWorkpackProjectScopeAllowed {
  try {
    if (Get-Command Test-ProjectScopedApprovedBacklogAllowed -ErrorAction SilentlyContinue) {
      return [bool](Test-ProjectScopedApprovedBacklogAllowed)
    }
  } catch {}
  try {
    $slug = Get-BacklogPackChannel
    if (-not [string]::IsNullOrWhiteSpace($slug) -and $slug -ne 'main') { return $true }
  } catch {}
  return $false
}

function Test-BacklogWorkpackProjectScopedItem {
  param($Item)
  $scope = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'scope' -Default '')).Trim().ToLowerInvariant()
  if ($scope -eq 'project') { return $true }
  $project = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'project' -Default '')
  return (-not [string]::IsNullOrWhiteSpace($project) -and $scope -ne 'bridge')
}

function Test-BacklogWorkpackOperatorTagged {
  param($Item)
  try {
    foreach ($tag in @(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @())) {
      if (([string]$tag).Trim().ToLowerInvariant() -eq 'operator') { return $true }
    }
  } catch {}
  return $false
}

function Test-BacklogWorkpackTouchesBridgeControlPlane {
  # 2026-06-09 unified policy: delegates to lib/policy.ps1 (edit-target-keyed; no text probe).
  # The old body ALSO text-probed the task description, which mislabeled tests/docs that merely
  # mention a protected component, and scanned the FULL touch set (verify deps included) -- both
  # were false-positive sources for the admission requirement below. Legacy path fallback kept
  # for the case where the policy module is unavailable.
  param($Item)
  try {
    if (Get-Command Test-PolicyItemTouchesControlPlane -ErrorAction SilentlyContinue) {
      return [bool](Test-PolicyItemTouchesControlPlane -Item $Item)
    }
  } catch {}
  $paths = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in @((Get-BacklogWorkpackItemFileList -Item $Item) + (Get-BacklogWorkpackItemTouches -Item $Item))) {
    $v = ([string]$p).Trim().ToLowerInvariant() -replace '\\','/'
    if (-not [string]::IsNullOrWhiteSpace($v) -and -not $paths.Contains($v)) { [void]$paths.Add($v) }
  }
  foreach ($p in @($paths.ToArray())) {
    if ($p -in @('driver.ps1','server.ps1','supervisor.ps1','watchdog.ps1','canary.ps1','lib/circuit-breaker.ps1','lib/parallel.ps1')) { return $true }
    if ($p -match '^lib/backlog.*\.ps1$') { return $true }
    if ($p -match '^control/') { return $true }
  }
  return $false
}

function Get-BacklogWorkpackBridgeAdmission {
  param($Item)
  if (Test-BacklogWorkpackOperatorTagged -Item $Item) {
    return [pscustomobject]@{ ok=$true; reason='operator'; missing=@() }
  }
  try {
    if (Get-Command Test-IdeaBridgeSelfAdmitted -ErrorAction SilentlyContinue) {
      $admission = Test-IdeaBridgeSelfAdmitted -Idea $Item
      if ($admission -and [bool]$admission.ok) { return $admission }
      return $admission
    }
  } catch {}
  return [pscustomobject]@{ ok=$false; reason='missing bridge_self_admission'; missing=@('bridge_self_admission') }
}

function Get-BacklogWorkpackExecEligibility {
  param(
    $Item,
    $Config = $null,
    [switch]$AllowProtected,
    [Nullable[bool]]$ProjectScopeAllowed = $null
  )
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }
  if ($null -eq $ProjectScopeAllowed) { $ProjectScopeAllowed = [bool](Test-BacklogWorkpackProjectScopeAllowed) }
  if (-not [bool]$Config.enabled) { return [pscustomobject]@{ eligible=$false; reason='disabled'; detail='workpack execution disabled'; admission=$null } }
  if (-not $Item) { return [pscustomobject]@{ eligible=$false; reason='missing-item'; detail='missing backlog item'; admission=$null } }
  if ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '') -ne 'approved') { return [pscustomobject]@{ eligible=$false; reason='not-approved'; detail='status is not approved'; admission=$null } }
  if ([string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default ''))) { return [pscustomobject]@{ eligible=$false; reason='missing-workpack'; detail='approved item has no workpack_id'; admission=$null } }
  try {
    if (Test-IdeaExternal $Item) { return [pscustomobject]@{ eligible=$false; reason='external-source'; detail='external/radar source is not auto-claimed by workpack frontier'; admission=$null } }
  } catch {}

  $isProjectScoped = Test-BacklogWorkpackProjectScopedItem -Item $Item
  if ($isProjectScoped -and -not [bool]$ProjectScopeAllowed) {
    return [pscustomobject]@{ eligible=$false; reason='project-scope-blocked'; detail='project-scoped approved item is not runnable in the bridge channel'; admission=$null }
  }

  if (-not ($isProjectScoped -and [bool]$ProjectScopeAllowed)) {
    if (Test-BacklogWorkpackTouchesBridgeControlPlane -Item $Item) {
      $admission = Get-BacklogWorkpackBridgeAdmission -Item $Item
      if (-not ($admission -and [bool]$admission.ok)) {
        $why = if ($admission) { [string]$admission.reason } else { 'missing bridge_self_admission' }
        $missing = @()
        try { $missing = @($admission.missing | ForEach-Object { [string]$_ }) } catch { $missing = @() }
        if ($missing.Count -gt 0) { $why += ' (' + (($missing | Sort-Object -Unique) -join ', ') + ')' }
        return [pscustomobject]@{
          eligible = $false
          reason = 'control-plane-admission-required'
          detail = 'bridge control-plane touch requires operator tag or bridge_self_admission with canary evidence: ' + $why
          admission = $admission
        }
      }
    }
  }

  $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
  # 2026-06-09: operator-tagged items are NOT excluded as protected-dominant. The exclusion exists
  # to keep risky core/safety work out of the PARALLEL frontier, but it also starved the serial
  # path: when ALL approved work was 'protected', selected=0 and nothing claimed (the wedge the
  # operator kept un-sticking). An operator-authorized item may run -- conflict groups still
  # serialize same-group items, so it executes alone, never in a risky parallel batch.
  if ((-not [bool]$Config.includeProtected) -and (-not $AllowProtected) -and ($cg -in @('core','safety')) -and -not (Test-BacklogWorkpackOperatorTagged -Item $Item)) {
    return [pscustomobject]@{ eligible=$false; reason='protected-dominant'; detail='protected core/safety candidate is excluded from parallel workpack frontier'; admission=$null }
  }

  return [pscustomobject]@{ eligible=$true; reason='eligible'; detail='approved workpack candidate is runnable'; admission=$null }
}

function Test-BacklogWorkpackExecEligible {
  param($Item, $Config = $null)
  $eligibility = Get-BacklogWorkpackExecEligibility -Item $Item -Config $Config
  return ($eligibility -and [bool]$eligibility.eligible)
}

function Get-BacklogTaskDepSignal {
  # 2026-06-01 ERR-002 (dependency-aware packing). Atoms carry no explicit depends_on, so this infers
  # from task text whether a task is a structural BARRIER (must be serialized) vs a NEUTRAL independent
  # edit (safe to parallelize). Returns 'foundation' (creates structure later tasks build on -> must
  # precede them), 'dependent' (explicitly relies on another task's artifact -> must follow it), or
  # 'neutral'. Consumed by Get-NextBacklogWorkpackBatch to force sequential waves for dependent chains
  # (scaffold -> Prisma/User model -> admin seed -> auth) that the touch-set packer wrongly saw as
  # independent because their files differ — which generated incompatible code (ERR-005).
  param([string]$Text)
  $t = Get-BacklogWorkpackSignalText -Text ([string]$Text)
  try { $t = Get-BacklogTextOutsideForbiddenContexts -Text $t } catch {}
  if ([string]::IsNullOrWhiteSpace($t)) { return 'neutral' }
  $t = $t.ToLowerInvariant()
  # Audit producers often prefix findings with tags such as
  # [deep-agent/runtime-incident-model/...]. Treating that source tag, or a bare "model/schema"
  # word in a finding, as a project-foundation dependency freezes the whole frontier. Keep the
  # barrier for explicit setup/schema work, but require a real foundation signal.
  $foundation = @(
    'scaffold','boilerplate','каркас проект','инициализ','init project','project setup','настрой проект',
    'prisma','schema\.prisma','миграци','migration','db schema','database','схему базы','схему бд',
    '\borm\b','create table','create\s+\w+\s+table','таблиц',
    'package\.json','next\.config','tsconfig','определи модель','define\s+\w+\s+model','create\s+\w+\s+model','add\s+\w+\s+model',
    '(?:define|create|design|add|set up)\s+.{0,25}(?:data model|entity|entities|schema)',
    '(?:создай|создать|добавь|добавить|определи|спроектируй)\s+.{0,25}(?:модель|сущност|схем)',
    'set up\s+.{0,20}(project|schema|database)'
  )
  $dependent = @(
    'после того как','после создани','на основе созданн','поверх созданн','использует модель','использует схему','на базе модел','на базе схем',
    '\bseed\b','seed script','using\s+.{0,25}(model|schema|table|api|prisma)','uses\s+.{0,25}(model|schema|table)','based on\s+.{0,25}(model|schema|table)','extends?\s+.{0,25}(model|schema)','подключ.{0,20}(модель|схему|бд)',
    'depends on','requires\s+.{0,30}(to exist|exist|first)','once\s+.{0,30}exist','after\s+.{0,30}(is created|created|exists|set up|scaffold)','building on\s+.{0,30}(model|schema|scaffold)','расширяет существующ','интегрир.{0,30}с созданн'
  )
  foreach ($rx in $foundation) { if ($t -match $rx) { return 'foundation' } }
  foreach ($rx in $dependent)  { if ($t -match $rx) { return 'dependent' } }
  return 'neutral'
}

function Get-BacklogTaskSlug {
  param($Item)
  $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'slug' -Default '')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'title' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($slug)) { return '' }
  try {
    if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) {
      return [string](ConvertTo-ProjectAutopilotSlug $slug)
    }
  } catch {}
  $v = $slug.Trim().ToLowerInvariant()
  $v = $v -replace '[^a-z0-9а-яё._-]+','-'
  return $v.Trim([char[]]@('-','_','.'))
}

function Get-BacklogTaskDependencySlugs {
  param($Item)
  $deps = New-Object 'System.Collections.Generic.List[string]'
  try {
    foreach ($d in @(Get-BacklogPackObjectValue -Obj $Item -Name 'depends_on' -Default @())) {
      $raw = [string]$d
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $slug = $raw
      try {
        if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) {
          $slug = [string](ConvertTo-ProjectAutopilotSlug $raw)
        } else {
          $slug = ($raw.Trim().ToLowerInvariant() -replace '[^a-z0-9а-яё._-]+','-').Trim([char[]]@('-','_','.'))
        }
      } catch {}
      if (-not [string]::IsNullOrWhiteSpace($slug)) { [void]$deps.Add($slug) }
    }
  } catch {}
  return @($deps.ToArray() | Sort-Object -Unique)
}

function New-BacklogWorkpackCandidateReport {
  param($Item)
  $id = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
  $slug = Get-BacklogTaskSlug -Item $Item
  $workpackId = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default '')
  $group = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($group)) { $group = 'general' }
  $touches = @(Get-BacklogWorkpackItemEditTouches -Item $Item)
  $files = @(Get-BacklogWorkpackItemFileList -Item $Item)
  $deps = @(Get-BacklogTaskDependencySlugs -Item $Item)
  $lane = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_lane_hint' -Default '')
  if ([string]::IsNullOrWhiteSpace($lane)) { $lane = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'lane' -Default '') }
  $parallelGroup = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'parallel_group' -Default '')
  if ([string]::IsNullOrWhiteSpace($lane)) {
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $lane = $parallelGroup }
    else { $lane = $group }
  }

  return [pscustomobject][ordered]@{
    id = $id
    slug = $slug
    workpack_id = $workpackId
    files = @($files)
    touch_set = @($touches)
    depends_on = @($deps)
    unmet_deps = @()
    lane = $lane
    parallel_group = $parallelGroup
    conflict_group = $group
    selected = $false
    selected_order = 0
    blocked = $false
    block_reason = ''
    block_detail = ''
    serial_reason = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'serial_reason' -Default '')
    conflict_with_ids = @()
    conflict_with_touches = @()
  }
}

function Set-BacklogWorkpackCandidateBlocked {
  param(
    $Candidate,
    [string]$Reason,
    [string]$Detail = '',
    [string[]]$UnmetDeps = @(),
    [string[]]$ConflictWithIds = @(),
    [string[]]$ConflictWithTouches = @()
  )
  if (-not $Candidate) { return }
  $Candidate.selected = $false
  $Candidate.blocked = $true
  $Candidate.block_reason = [string]$Reason
  $Candidate.block_detail = [string]$Detail
  $Candidate.unmet_deps = @($UnmetDeps)
  $Candidate.conflict_with_ids = @($ConflictWithIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  $Candidate.conflict_with_touches = @($ConflictWithTouches | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Set-BacklogWorkpackCandidateSelected {
  param($Candidate, [int]$Order)
  if (-not $Candidate) { return }
  $Candidate.selected = $true
  $Candidate.selected_order = [int]$Order
  $Candidate.blocked = $false
  $Candidate.block_reason = ''
  $Candidate.block_detail = ''
  $Candidate.conflict_with_ids = @()
  $Candidate.conflict_with_touches = @()
}

function Get-BacklogWorkpackCandidateReasonItems {
  param([object[]]$Candidates, [string]$Reason)
  return @($Candidates | Where-Object { [string]$_.block_reason -eq $Reason })
}

function New-BacklogWorkpackFrontierReasonDetails {
  param([object[]]$Candidates, [string[]]$SelectedIds = @())
  $blocked = @($Candidates | Where-Object { [bool]$_.blocked })
  return [pscustomobject][ordered]@{
    selected_ids = @($SelectedIds)
    skipped_ids = @($blocked | ForEach-Object { [string]$_.id })
    conflicts = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'conflicts-or-touch-overlap' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        conflict_group = [string]$_.conflict_group
        touch_set = @($_.touch_set)
        conflict_with_ids = @($_.conflict_with_ids)
        conflict_with_touches = @($_.conflict_with_touches)
        detail = [string]$_.block_detail
      }
    })
    dependency_wait = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'dependency-wait' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        depends_on = @($_.depends_on)
        unmet_deps = @($_.unmet_deps)
        detail = [string]$_.block_detail
      }
    })
    structural_barriers = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'structural-barrier' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        files = @($_.files)
        touch_set = @($_.touch_set)
        detail = [string]$_.block_detail
      }
    })
    protected = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'protected-dominant' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        conflict_group = [string]$_.conflict_group
        touch_set = @($_.touch_set)
        detail = [string]$_.block_detail
      }
    })
    control_plane = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'control-plane-admission-required' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        files = @($_.files)
        touch_set = @($_.touch_set)
        detail = [string]$_.block_detail
      }
    })
    project_scope = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'project-scope-blocked' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        detail = [string]$_.block_detail
      }
    })
    governor_deferred = @(Get-BacklogWorkpackCandidateReasonItems -Candidates $Candidates -Reason 'governor-deferred' | ForEach-Object {
      [pscustomobject][ordered]@{
        id = [string]$_.id
        slug = [string]$_.slug
        detail = [string]$_.block_detail
        touch_set = @($_.touch_set)
        evidence = (Get-BacklogPackObjectValue -Obj $_ -Name 'governor_evidence' -Default $null)
      }
    })
  }
}

function Format-BacklogWorkpackFrontierReasonDetail {
  param([string]$Reason, $Details)
  $selected = @()
  try { $selected = @($Details.selected_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch {}
  $selectedText = if ($selected.Count -gt 0) { 'selected: ' + (($selected | Select-Object -First 8) -join ', ') } else { 'selected: none' }
  switch ([string]$Reason) {
    'conflicts-or-touch-overlap' {
      $parts = @()
      foreach ($c in @($Details.conflicts | Select-Object -First 6)) {
        $with = (@($c.conflict_with_ids) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
        $touch = (@($c.conflict_with_touches) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
        $why = [string]$c.detail
        if ([string]::IsNullOrWhiteSpace($why)) { $why = 'conflicts with selected=' + $with + ' touch=' + $touch }
        $parts += (([string]$c.id) + ' -> ' + $why)
      }
      if ($parts.Count -eq 0) { return $selectedText + '; no explicit conflict detail captured' }
      return $selectedText + '; skipped: ' + ($parts -join '; ')
    }
    'dependency-wait' {
      $parts = @()
      foreach ($d in @($Details.dependency_wait | Select-Object -First 6)) {
        $wait = (@($d.unmet_deps) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', '
        if ([string]::IsNullOrWhiteSpace($wait)) { $wait = [string]$d.detail }
        $parts += (([string]$d.id) + ' waits for ' + $wait)
      }
      if ($parts.Count -eq 0) { return $selectedText + '; dependency wait without candidate detail' }
      return $selectedText + '; ' + ($parts -join '; ')
    }
    'structural-barrier' {
      $parts = @()
      foreach ($b in @($Details.structural_barriers | Select-Object -First 6)) {
        $files = (@($b.touch_set) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 4) -join ', '
        $parts += (([string]$b.id) + ' is a foundation/barrier touch=' + $files)
      }
      if ($parts.Count -eq 0) { return $selectedText + '; structural barrier without candidate detail' }
      return $selectedText + '; ' + ($parts -join '; ')
    }
    'protected-dominant' {
      $ids = @($Details.protected | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8)
      if ($ids.Count -eq 0) { return $selectedText + '; protected core/safety candidates dominate the frontier' }
      return $selectedText + '; protected skipped: ' + ($ids -join ', ') + ' (use protected serial/admitted bridge-self path)'
    }
    'governor-deferred' {
      $parts = @()
      foreach ($g in @($Details.governor_deferred | Select-Object -First 6)) {
        $parts += (([string]$g.id) + ' -> ' + [string]$g.detail)
      }
      if ($parts.Count -eq 0) { return $selectedText + '; queue governor deferred candidate(s)' }
      return $selectedText + '; governor_deferred: ' + ($parts -join '; ')
    }
    default {
      if ($Details -and @($Details.governor_deferred).Count -gt 0) {
        $parts = @($Details.governor_deferred | Select-Object -First 6 | ForEach-Object { ([string]$_.id) + ' -> ' + [string]$_.detail })
        return $selectedText + '; governor_deferred: ' + ($parts -join '; ')
      }
      if ($Details -and @($Details.control_plane).Count -gt 0) {
        $ids = @($Details.control_plane | ForEach-Object { [string]$_.id } | Select-Object -First 8)
        return $selectedText + '; control-plane blocked: ' + ($ids -join ', ')
      }
      return $selectedText
    }
  }
}

function Get-BacklogSlugStatusMap {
  param([object[]]$Items)
  $map = @{}
  foreach ($item in @($Items)) {
    $slug = Get-BacklogTaskSlug -Item $item
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    $map[$slug] = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).ToLowerInvariant()
  }
  return $map
}

function Test-BacklogTaskDependenciesReady {
  param($Item, $StatusBySlug)
  $deps = @(Get-BacklogTaskDependencySlugs -Item $Item)
  if ($deps.Count -eq 0) {
    return [pscustomobject]@{ ready=$true; deps=@(); unmet=@() }
  }
  $doneStatuses = @{ done=$true; 'auto-resolved'=$true }
  $unmet = New-Object 'System.Collections.Generic.List[string]'
  foreach ($dep in @($deps)) {
    $st = ''
    try { if ($StatusBySlug.ContainsKey($dep)) { $st = [string]$StatusBySlug[$dep] } } catch {}
    if ([string]::IsNullOrWhiteSpace($st) -or -not $doneStatuses.ContainsKey($st)) {
      $label = if ([string]::IsNullOrWhiteSpace($st)) { $dep + '(missing)' } else { $dep + '(' + $st + ')' }
      [void]$unmet.Add($label)
    }
  }
  return [pscustomobject]@{ ready=($unmet.Count -eq 0); deps=@($deps); unmet=@($unmet.ToArray()) }
}

function Resolve-BacklogWorkpackFrontier {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }

  $allItems = @(Get-Backlog)
  $approved = @(
    $allItems |
    Where-Object { [string](Get-BacklogPackObjectValue -Obj $_ -Name 'status' -Default '') -eq 'approved' }
  )
  $withWorkpack = @(
    $approved |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_id' -Default '')) }
  )
  $withoutWorkpack = @(
    $approved |
    Where-Object { [string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_id' -Default '')) }
  )
  $protected = @(
    $withWorkpack |
    Where-Object {
      $cg = ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
      ($cg -in @('core','safety'))
    }
  )
  $projectScopeAllowed = [bool](Test-BacklogWorkpackProjectScopeAllowed)
  $governorActiveItems = @(Get-BacklogGovernorActiveItems -Items $allItems)
  $governorManualLocks = @(Get-BacklogGovernorManualLocks)
  $governorDeferred = 0
  $governorDropped = 0
  $governorDirty = $false
  $candidateItems = @(
    $withWorkpack |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}}
  )
  $candidateReports = New-Object 'System.Collections.Generic.List[object]'
  $candidateById = @{}
  $eligibilityById = @{}
  foreach ($item in @($candidateItems)) {
    $candidate = New-BacklogWorkpackCandidateReport -Item $item
    [void]$candidateReports.Add($candidate)
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate.id)) { $candidateById[[string]$candidate.id] = $candidate }
    $governorVerdict = $null
    try { $governorVerdict = Test-BacklogGovernorClaimable -Item $item -ActiveItems $governorActiveItems -ManualLocks $governorManualLocks } catch { $governorVerdict = $null }
    if ($governorVerdict) {
      $candidate | Add-Member -NotePropertyName governor_evidence -NotePropertyValue $governorVerdict.evidence -Force
      Set-BacklogObjectProperty -Item $item -Name 'governor_claim_evidence' -Value $governorVerdict.evidence
      if ([string]$governorVerdict.action -eq 'drop') {
        Set-BacklogGovernorDrop -Item $item -Verdict $governorVerdict -Phase 'workpack-frontier'
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'governor-dropped' -Detail ([string]$governorVerdict.detail)
        $governorDropped++
        $governorDirty = $true
        continue
      } elseif ([string]$governorVerdict.action -eq 'defer') {
        Set-BacklogGovernorDeferred -Item $item -Verdict $governorVerdict -Phase 'workpack-frontier'
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'governor-deferred' -Detail ([string]$governorVerdict.reason + ': ' + [string]$governorVerdict.detail)
        $governorDeferred++
        $governorDirty = $true
        continue
      } else {
        # 2026-06-11 S5: an unchanged 'allow' restamp used to mark the backlog dirty on EVERY
        # frontier poll (several per minute) -> full backlog.jsonl rewrite under lock each tick
        # (OneDrive sync storm + lock contention). Stamp/save only when the verdict CHANGES;
        # readers of governor_claim see the same data either way.
        $prevGovernorAction = ''
        try {
          $prevGovernorClaim = Get-BacklogPackObjectValue -Obj $item -Name 'governor_claim' -Default $null
          if ($prevGovernorClaim) { $prevGovernorAction = [string]$prevGovernorClaim.action }
        } catch { $prevGovernorAction = '' }
        if ($prevGovernorAction -ne 'allow') {
          Set-BacklogObjectProperty -Item $item -Name 'governor_claim' -Value ([pscustomobject][ordered]@{
            action = 'allow'
            reason = [string]$governorVerdict.reason
            detail = [string]$governorVerdict.detail
            ts = (Get-Date).ToUniversalTime().ToString('o')
            evidence = $governorVerdict.evidence
          })
          $governorDirty = $true
        }
      }
    }
    $eligibility = Get-BacklogWorkpackExecEligibility -Item $item -Config $Config -ProjectScopeAllowed $projectScopeAllowed
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate.id)) { $eligibilityById[[string]$candidate.id] = $eligibility }
    if (-not ($eligibility -and [bool]$eligibility.eligible)) {
      $r = if ($eligibility) { [string]$eligibility.reason } else { 'not-eligible' }
      $d = if ($eligibility) { [string]$eligibility.detail } else { 'candidate is not eligible' }
      Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason $r -Detail $d
    }
  }
  $eligible = @(
    $candidateItems |
    Where-Object {
      $cid = [string](Get-BacklogPackObjectValue -Obj $_ -Name 'id' -Default '')
      $elig = if ($eligibilityById.ContainsKey($cid)) { $eligibilityById[$cid] } else { $null }
      $candidate = if ($candidateById.ContainsKey($cid)) { $candidateById[$cid] } else { $null }
      ($elig -and [bool]$elig.eligible -and -not ($candidate -and [bool]$candidate.blocked))
    }
  )
  if ($governorDirty) { Save-Backlog $allItems }

  $statusBySlug = Get-BacklogSlugStatusMap -Items $allItems
  $selected = New-Object 'System.Collections.Generic.List[object]'
  $usedGroups = @{}
  $usedTouches = New-Object 'System.Collections.Generic.List[string]'
  $usedTouchOwners = @{}
  $readyCount = 0
  $dependencyWait = 0
  $structuralWait = 0
  $conflictSkips = 0
  $touchSkips = 0
  if ([bool]$Config.enabled -and $eligible.Count -ge 1) {
    foreach ($item in $eligible) {
      $selectionFull = ($selected.Count -ge [int]$Config.maxItems)
      $itemId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
      $candidate = if ($candidateById.ContainsKey($itemId)) { $candidateById[$itemId] } else { $null }
      $txt = [string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '')
      $depCheck = Test-BacklogTaskDependenciesReady -Item $item -StatusBySlug $statusBySlug
      $explicitDeps = @($depCheck.deps)
      if (-not [bool]$depCheck.ready) {
        $dependencyWait++
        $unmet = @($depCheck.unmet | ForEach-Object { [string]$_ })
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'dependency-wait' -Detail ('waiting for dependency: ' + (($unmet | Select-Object -First 6) -join ', ')) -UnmetDeps $unmet
        continue
      }

      # Dependency-aware frontier: one blocked/dependent item must not freeze the whole team.
      # Explicit depends_on is authoritative. Heuristic "foundation" without explicit deps stays a
      # serial barrier; explicit, already-satisfied deps can join the frontier if touch sets do not
      # overlap. This keeps scaffold/schema steps safe while allowing later ready lanes to fan out.
      # 2026-06-11 S2: the text heuristic must NOT override the coordinator's explicit DAG.
      # Autopilot atoms embed "Files: package.json" etc INSIDE item text, so the foundation/
      # dependent regex misfired on them and froze whole chapters (empty depends_on on an
      # autopilot atom is a DELIBERATE "independent", not missing metadata).
      $isAutopilotAtom = $false
      try { $isAutopilotAtom = [bool](Get-BacklogPackObjectValue -Obj $item -Name 'autopilot_generated' -Default $false) } catch { $isAutopilotAtom = $false }
      $depSignal = if ($isAutopilotAtom) { '' } else { Get-BacklogTaskDepSignal -Text $txt }
      if ($depSignal -eq 'foundation' -and $explicitDeps.Count -eq 0) {
        $structuralWait++
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'structural-barrier' -Detail 'foundation/schema/setup task must run before parallel dependents'
        # 2026-06-11 S1: this used to `break` — one foundation-flavored item ABORTED selection of
        # the ENTIRE remaining frontier (selected=0, claim never happened, and the barrier itself
        # was never picked either => the queue wedged). Later candidates are safe to consider:
        # touch-overlap + conflict-group checks below still serialize anything genuinely related.
        continue
      }
      if ($depSignal -eq 'dependent' -and $explicitDeps.Count -eq 0) {
        $dependencyWait++
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'dependency-wait' -Detail 'dependent task has no explicit satisfied depends_on metadata'
        continue
      }

      $readyCount++
      if ($selectionFull) {
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'selection-limit' -Detail ('frontier already selected max_items=' + [int]$Config.maxItems)
        continue
      }
      $packId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default '')
      if ([string]::IsNullOrWhiteSpace($packId)) { continue }
      # 2026-06-01 ROOT FIX (parallelism / "bridge as a team"): do NOT dedupe by workpack_id. Truly
      # independent tasks (distinct conflict_group + non-overlapping touch-set) frequently share a STALE
      # workpack_id from an earlier packing pass — e.g. 5 redesign tasks for 5 different files all carried
      # one 'erosection-ts' pack id from when they were collapsed under a common эталон. Blocking by
      # workpack_id then capped real parallelism at 1-per-pack (6 independent file edits -> only 2
      # streams), so the bridge ran near-serial instead of as a team. Independence is fully decided by
      # conflict_group + touch overlap below; workpack_id is reporting-only.
      $group = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($group)) { $group = 'general' }
      # 2026-06-11 A4 (speed program): the 1-per-group rule capped wave width at "number of
      # DISTINCT groups" even when items had explicit non-overlapping touch-sets (10 same-zone
      # atoms => width 1; the fallback 'general' group glued unrelated atoms together). When BOTH
      # this item and the wave have real declared touches, the touch-overlap check below is the
      # authority — skip the coarse group gate. Keep the gate for core/safety (protected zones)
      # and for items with NO declared touches (nothing else guards their undeclared files).
      $touches = @(Get-BacklogWorkpackItemEditTouches -Item $item)
      $groupGateApplies = $usedGroups.ContainsKey($group) -and (
        (@('core','safety') -contains $group) -or ($touches.Count -eq 0)
      )
      if ($groupGateApplies) {
        $conflictSkips++
        $owner = [string]$usedGroups[$group]
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'conflicts-or-touch-overlap' -Detail ("conflict_group '" + $group + "' already selected by " + $owner) -ConflictWithIds @($owner)
        continue
      }

      $overlap = @(Get-BacklogWorkpackTouchOverlap -Left @($usedTouches.ToArray()) -Right $touches)
      if ($overlap.Count -gt 0) {
        $touchSkips++
        $owners = @($overlap | ForEach-Object { $k = [string]$_; if ($usedTouchOwners.ContainsKey($k)) { [string]$usedTouchOwners[$k] } } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'conflicts-or-touch-overlap' -Detail ('touch_set overlaps on ' + (($overlap | Select-Object -First 6) -join ', ') + ' with selected ' + (($owners | Select-Object -First 6) -join ', ')) -ConflictWithIds $owners -ConflictWithTouches $overlap
        continue
      }

      [void]$selected.Add($item)
      Set-BacklogWorkpackCandidateSelected -Candidate $candidate -Order $selected.Count
      $usedGroups[$group] = $itemId
      foreach ($t in $touches) {
        $tv = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
        if ([string]::IsNullOrWhiteSpace($tv)) { continue }
        [void]$usedTouches.Add($tv)
        if (-not $usedTouchOwners.ContainsKey($tv)) { $usedTouchOwners[$tv] = $itemId }
      }
    }
  }

  # 2026-06-11 S1: a structural-barrier (foundation) item must actually RUN, not just block.
  # If nothing else was selectable this wave, pick the FIRST barrier solo — selected==1 flows
  # into the existing serial-single-fallback path, so the barrier executes serially and the
  # chapter unfreezes on the next wave. Without this the barrier stayed blocked forever.
  if ($selected.Count -eq 0 -and $structuralWait -gt 0) {
    foreach ($candidate in @($candidateReports.ToArray())) {
      if ([string]$candidate.block_reason -ne 'structural-barrier') { continue }
      $barrierId = [string]$candidate.id
      $barrierItem = $null
      foreach ($it in $eligible) {
        if ([string](Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default '') -eq $barrierId) { $barrierItem = $it; break }
      }
      if ($null -eq $barrierItem) { continue }
      [void]$selected.Add($barrierItem)
      Set-BacklogWorkpackCandidateSelected -Candidate $candidate -Order 1
      $readyCount++
      break
    }
  }

  # 2026-06-14 (operator root-fix, user-approved): serial-single fallback for the touch-overlap WEDGE.
  # If nothing was selected this wave AND eligible atoms were blocked purely by mutual touch-overlap
  # (e.g. several atoms all writing one module file), pick the FIRST touch-overlap-blocked atom solo
  # -> selected==1 -> serial path. Without this the channel wedged idle on same-file atoms instead of
  # serializing them across waves. Mirrors the structural-barrier solo fallback above.
  if ($selected.Count -eq 0 -and $touchSkips -gt 0) {
    foreach ($candidate in @($candidateReports.ToArray())) {
      if ([string]$candidate.block_reason -ne 'conflicts-or-touch-overlap') { continue }
      $overlapId = [string]$candidate.id
      $overlapItem = $null
      foreach ($it in $eligible) {
        if ([string](Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default '') -eq $overlapId) { $overlapItem = $it; break }
      }
      if ($null -eq $overlapItem) { continue }
      [void]$selected.Add($overlapItem)
      Set-BacklogWorkpackCandidateSelected -Candidate $candidate -Order 1
      $readyCount++
      break
    }
  }

  $ids = @($selected.ToArray() | ForEach-Object { [string]$_.id })
  $packs = @($selected.ToArray() | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
  $groups = @($usedGroups.Keys | Sort-Object -Unique)
  $batchAvailable = ($selected.Count -ge [int]$Config.minItems)
  $serialAvailable = ((-not [bool]$batchAvailable) -and $selected.Count -eq 1 -and $readyCount -ge 1)
  $claimAvailable = ([bool]$batchAvailable -or [bool]$serialAvailable)
  $workpackBatchMode = if ($serialAvailable) { 'serial' } elseif ($batchAvailable) { 'parallel' } else { '' }
  $serialReason = if ($serialAvailable) { 'serial-single-fallback' } else { '' }

  # 2026-06-12 A6 (speed program, benchmark-proven): the close-tail (~19 min of planner turns +
  # critic + QA + gates) is paid PER TASK regardless of edit size. K small same-file atoms used
  # to run K separate full pipelines (~24 min each) because touch-overlap correctly serializes
  # them — but that serialization can happen INSIDE one task: chain the co-touch atoms into ONE
  # serial batch (the batch text generator, commit-per-atom CONTINUE-CHUNK protocol and the
  # single batch close already exist), so the tail is paid once per chain instead of per atom.
  # Cap 4 keeps a chain inside the commit-famine budget; protected core/safety items never reach
  # this path (excluded from this frontier upstream). 6-atom benchmark math: 6x(5 work + 19 tail)
  # = 144 min serially -> 2 chains x (4x5 + 19) ~= 78 min, ~8-13 min/atom.
  if ($serialAvailable -and $selected.Count -eq 1) {
    $chainAnchorId = [string](Get-BacklogPackObjectValue -Obj $selected[0] -Name 'id' -Default '')
    $serialChainCap = 4
    foreach ($candidate in @($candidateReports.ToArray())) {
      if ($selected.Count -ge $serialChainCap) { break }
      if (-not [bool]$candidate.blocked) { continue }
      if ([string]$candidate.block_reason -ne 'conflicts-or-touch-overlap') { continue }
      $chainConflicts = @($candidate.conflict_with_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      # Only atoms whose ONLY conflict is the chain anchor (same file, nothing else) qualify.
      if ($chainConflicts.Count -eq 0) { continue }
      if (@($chainConflicts | Where-Object { $_ -ne $chainAnchorId }).Count -gt 0) { continue }
      $chainItem = $null
      foreach ($it in $eligible) {
        if ([string](Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default '') -eq [string]$candidate.id) { $chainItem = $it; break }
      }
      if ($null -eq $chainItem) { continue }
      [void]$selected.Add($chainItem)
      Set-BacklogWorkpackCandidateSelected -Candidate $candidate -Order $selected.Count
    }
    if ($selected.Count -gt 1) {
      $ids = @($selected.ToArray() | ForEach-Object { [string]$_.id })
      $packs = @($selected.ToArray() | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
      $workpackBatchMode = 'serial'
      $serialReason = 'serial-chain-same-touch'
    }
  }
  $reason = 'unknown'
  if (-not [bool]$Config.enabled) {
    $reason = 'disabled'
  } elseif ($approved.Count -lt [int]$Config.minItems) {
    $reason = 'not-enough-approved'
  } elseif ($withWorkpack.Count -lt [int]$Config.minItems) {
    $reason = 'not-enough-workpack'
  } elseif ($eligible.Count -lt [int]$Config.minItems) {
    if ($governorDeferred -gt 0) {
      $reason = 'governor-deferred'
    } elseif (($protected.Count -ge [int]$Config.minItems) -and (-not [bool]$Config.includeProtected)) {
      $reason = 'protected-dominant'
    } else {
      $reason = 'not-enough-eligible'
    }
  } elseif ($batchAvailable) {
    $reason = 'batch-available'
  } elseif ($readyCount -lt [int]$Config.minItems) {
    if ($dependencyWait -gt 0) { $reason = 'dependency-wait' }
    elseif ($structuralWait -gt 0) { $reason = 'structural-barrier' }
    else { $reason = 'not-enough-eligible' }
  } elseif (($conflictSkips + $touchSkips) -gt 0) {
    $reason = 'conflicts-or-touch-overlap'
  } elseif ($dependencyWait -gt 0) {
    $reason = 'dependency-wait'
  } elseif ($structuralWait -gt 0) {
    $reason = 'structural-barrier'
  } elseif ($governorDeferred -gt 0) {
    $reason = 'governor-deferred'
  }

  foreach ($candidate in @($candidateReports.ToArray())) {
    if ([bool]$candidate.selected -or [bool]$candidate.blocked) { continue }
    $fallbackReason = [string]$reason
    $fallbackDetail = 'candidate was not selected for this frontier'
    if ($batchAvailable) {
      $fallbackReason = 'selection-limit'
      $fallbackDetail = 'batch is available; candidate remains for a later frontier'
    } elseif ([string]::IsNullOrWhiteSpace($fallbackReason) -or $fallbackReason -eq 'unknown') {
      $fallbackReason = 'not-selected'
    }
    Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason $fallbackReason -Detail $fallbackDetail
  }

  $candidateArr = @($candidateReports.ToArray())
  $blockedCandidates = @($candidateArr | Where-Object { [bool]$_.blocked })
  $selectedCandidates = @($candidateArr | Where-Object { [bool]$_.selected })
  $selectedLanes = @($selectedCandidates | ForEach-Object { [string]$_.lane } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $selectedParallelGroups = @($selectedCandidates | ForEach-Object { [string]$_.parallel_group } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $selectedTouches = @($selectedCandidates | ForEach-Object { @($_.touch_set) } | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $reasonDetails = New-BacklogWorkpackFrontierReasonDetails -Candidates $candidateArr -SelectedIds $ids
  $reasonDetail = Format-BacklogWorkpackFrontierReasonDetail -Reason $reason -Details $reasonDetails

  $report = [pscustomobject][ordered]@{
    enabled               = [bool]$Config.enabled
    approved_count        = [int]$approved.Count
    with_workpack_count   = [int]$withWorkpack.Count
    without_workpack_count = [int]$withoutWorkpack.Count
    candidate_count       = [int]$candidateArr.Count
    eligible_count        = [int]$eligible.Count
    protected_count       = [int]$protected.Count
    ready_count           = [int]$readyCount
    selected_count        = [int]$selected.Count
    blocked_count         = [int]$blockedCandidates.Count
    min_items             = [int]$Config.minItems
    max_items             = [int]$Config.maxItems
    dependency_wait_count = [int]$dependencyWait
    structural_wait_count = [int]$structuralWait
    conflict_skip_count   = [int]$conflictSkips
    touch_skip_count      = [int]$touchSkips
    governor_deferred_count = [int]$governorDeferred
    governor_dropped_count = [int]$governorDropped
    claim_available       = [bool]$claimAvailable
    batch_available       = [bool]$batchAvailable
    parallel_required     = [bool]$batchAvailable
    workpack_batch_mode   = [string]$workpackBatchMode
    reason                = [string]$reason
    reason_detail         = [string]$reasonDetail
    reason_details        = $reasonDetails
    selected_ids          = @($ids)
    selected_groups       = @($groups)
    selected_lanes        = @($selectedLanes)
    selected_parallel_groups = @($selectedParallelGroups)
    selected_touches      = @($selectedTouches)
    blocked_ids           = @($blockedCandidates | ForEach-Object { [string]$_.id })
    candidates            = @($candidateArr)
    frontier_candidates   = @($candidateArr)
    serial_required       = [bool]$serialAvailable
    serial_reason         = [string]$serialReason
  }

  return [pscustomobject][ordered]@{
    items = @($selected.ToArray())
    ids = @($ids)
    workpacks = @($packs)
    conflict_groups = @($groups)
    count = $selected.Count
    eligible_count = $eligible.Count
    ready_count = $readyCount
    dependency_wait_count = $dependencyWait
    structural_wait_count = $structuralWait
    conflict_skip_count = $conflictSkips
    touch_skip_count = $touchSkips
    governor_deferred_count = $governorDeferred
    governor_dropped_count = $governorDropped
    candidates = @($candidateArr)
    report = $report
  }
}

function Get-BacklogWorkpackFrontierReport {
  param($Config = $null)
  $frontier = Resolve-BacklogWorkpackFrontier -Config $Config
  return $frontier.report
}

function Get-NextBacklogWorkpackBatch {
  param($Config = $null)
  $frontier = Resolve-BacklogWorkpackFrontier -Config $Config
  if (-not $frontier -or -not $frontier.report -or -not [bool]$frontier.report.claim_available) { return $null }
  return [pscustomobject]@{
    items = @($frontier.items)
    ids = @($frontier.ids)
    workpacks = @($frontier.workpacks)
    conflict_groups = @($frontier.conflict_groups)
    count = [int]$frontier.count
    eligible_count = [int]$frontier.eligible_count
    ready_count = [int]$frontier.ready_count
    dependency_wait_count = [int]$frontier.dependency_wait_count
    structural_wait_count = [int]$frontier.structural_wait_count
    conflict_skip_count = [int]$frontier.conflict_skip_count
    touch_skip_count = [int]$frontier.touch_skip_count
    serial_required = [bool]$frontier.report.serial_required
    serial_reason = [string]$frontier.report.serial_reason
    workpack_batch_mode = [string]$frontier.report.workpack_batch_mode
    candidates = @($frontier.candidates)
    frontier_report = $frontier.report
  }
}

function Test-BacklogProtectedSerialCandidate {
  param($Item, $Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }
  if (-not [bool]$Config.serialProtectedEnabled) { return $false }
  if (-not $Item) { return $false }
  $projectScopeAllowed = [bool](Test-BacklogWorkpackProjectScopeAllowed)
  $eligibility = Get-BacklogWorkpackExecEligibility -Item $Item -Config $Config -AllowProtected -ProjectScopeAllowed $projectScopeAllowed
  if (-not ($eligibility -and [bool]$eligibility.eligible)) { return $false }
  $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
  return ($cg -in @('core','safety'))
}

function Get-BacklogProtectedSerialGroupKey {
  param($Item)
  $root = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_root_cause_key' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($root)) { return $root.Trim().ToLowerInvariant() }
  $touches = @(Get-BacklogWorkpackItemTouches -Item $Item)
  if ($touches.Count -gt 0) { return ('touch:' + ((@($touches) | Sort-Object -Unique) -join '+')) }
  $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($cg)) { $cg = 'protected' }
  return ('group:' + $cg)
}

function Resolve-BacklogProtectedSerialFrontier {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }

  $allItems = @(Get-Backlog)
  $approved = @(
    $allItems |
    Where-Object { [string](Get-BacklogPackObjectValue -Obj $_ -Name 'status' -Default '') -eq 'approved' }
  )
  $protected = @(
    $approved |
    Where-Object {
      $cg = ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
      ($cg -in @('core','safety'))
    }
  )
  $projectScopeAllowed = [bool](Test-BacklogWorkpackProjectScopeAllowed)
  $governorActiveItems = @(Get-BacklogGovernorActiveItems -Items $allItems)
  $governorManualLocks = @(Get-BacklogGovernorManualLocks)
  $governorDeferred = 0
  $governorDropped = 0
  $governorDirty = $false
  $candidateItems = @(
    $protected |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}}
  )
  $candidateReports = New-Object 'System.Collections.Generic.List[object]'
  $candidateById = @{}
  $eligibilityById = @{}
  foreach ($item in @($candidateItems)) {
    $candidate = New-BacklogWorkpackCandidateReport -Item $item
    [void]$candidateReports.Add($candidate)
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate.id)) { $candidateById[[string]$candidate.id] = $candidate }
    $governorVerdict = $null
    try { $governorVerdict = Test-BacklogGovernorClaimable -Item $item -ActiveItems $governorActiveItems -ManualLocks $governorManualLocks } catch { $governorVerdict = $null }
    if ($governorVerdict) {
      $candidate | Add-Member -NotePropertyName governor_evidence -NotePropertyValue $governorVerdict.evidence -Force
      Set-BacklogObjectProperty -Item $item -Name 'governor_claim_evidence' -Value $governorVerdict.evidence
      if ([string]$governorVerdict.action -eq 'drop') {
        Set-BacklogGovernorDrop -Item $item -Verdict $governorVerdict -Phase 'protected-serial-frontier'
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'governor-dropped' -Detail ([string]$governorVerdict.detail)
        $governorDropped++
        $governorDirty = $true
        continue
      } elseif ([string]$governorVerdict.action -eq 'defer') {
        Set-BacklogGovernorDeferred -Item $item -Verdict $governorVerdict -Phase 'protected-serial-frontier'
        Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'governor-deferred' -Detail ([string]$governorVerdict.reason + ': ' + [string]$governorVerdict.detail)
        $governorDeferred++
        $governorDirty = $true
        continue
      } else {
        # 2026-06-11 S5: an unchanged 'allow' restamp used to mark the backlog dirty on EVERY
        # frontier poll (several per minute) -> full backlog.jsonl rewrite under lock each tick
        # (OneDrive sync storm + lock contention). Stamp/save only when the verdict CHANGES;
        # readers of governor_claim see the same data either way.
        $prevGovernorAction = ''
        try {
          $prevGovernorClaim = Get-BacklogPackObjectValue -Obj $item -Name 'governor_claim' -Default $null
          if ($prevGovernorClaim) { $prevGovernorAction = [string]$prevGovernorClaim.action }
        } catch { $prevGovernorAction = '' }
        if ($prevGovernorAction -ne 'allow') {
          Set-BacklogObjectProperty -Item $item -Name 'governor_claim' -Value ([pscustomobject][ordered]@{
            action = 'allow'
            reason = [string]$governorVerdict.reason
            detail = [string]$governorVerdict.detail
            ts = (Get-Date).ToUniversalTime().ToString('o')
            evidence = $governorVerdict.evidence
          })
          $governorDirty = $true
        }
      }
    }
    $eligibility = Get-BacklogWorkpackExecEligibility -Item $item -Config $Config -AllowProtected -ProjectScopeAllowed $projectScopeAllowed
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate.id)) { $eligibilityById[[string]$candidate.id] = $eligibility }
    if (-not ($eligibility -and [bool]$eligibility.eligible)) {
      $r = if ($eligibility) { [string]$eligibility.reason } else { 'not-eligible' }
      $d = if ($eligibility) { [string]$eligibility.detail } else { 'candidate is not eligible' }
      Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason $r -Detail $d
    }
  }
  $eligible = New-Object 'System.Collections.Generic.List[object]'
  $dependencyWait = 0
  $structuralWait = 0
  $statusBySlug = Get-BacklogSlugStatusMap -Items $allItems
  foreach ($item in @($candidateItems)) {
    $itemId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    $candidate = if ($candidateById.ContainsKey($itemId)) { $candidateById[$itemId] } else { $null }
    $eligibility = if ($eligibilityById.ContainsKey($itemId)) { $eligibilityById[$itemId] } else { $null }
    if ($candidate -and [bool]$candidate.blocked) { continue }
    if (-not ($eligibility -and [bool]$eligibility.eligible)) { continue }
    if (-not (Test-BacklogProtectedSerialCandidate -Item $item -Config $Config)) { continue }
    $txt = [string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '')
    $depCheck = Test-BacklogTaskDependenciesReady -Item $item -StatusBySlug $statusBySlug
    if (-not [bool]$depCheck.ready) {
      $dependencyWait++
      $unmet = @($depCheck.unmet | ForEach-Object { [string]$_ })
      Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'dependency-wait' -Detail ('waiting for dependency: ' + (($unmet | Select-Object -First 6) -join ', ')) -UnmetDeps $unmet
      continue
    }
    $depSignal = Get-BacklogTaskDepSignal -Text $txt
    if ($depSignal -eq 'foundation') {
      $structuralWait++
      Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'structural-barrier' -Detail 'foundation/schema/setup task must run before protected serial batch'
      continue
    }
    if ($depSignal -eq 'dependent') {
      $dependencyWait++
      Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason 'dependency-wait' -Detail 'dependent task has no explicit satisfied depends_on metadata'
      continue
    }
    [void]$eligible.Add($item)
  }

  $groups = @{}
  foreach ($item in @($eligible.ToArray())) {
    $key = Get-BacklogProtectedSerialGroupKey -Item $item
    if ([string]::IsNullOrWhiteSpace($key)) { $key = 'protected' }
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object 'System.Collections.Generic.List[object]' }
    [void]$groups[$key].Add($item)
  }

  $summaries = New-Object 'System.Collections.Generic.List[object]'
  foreach ($key in @($groups.Keys)) {
    $arr = @($groups[$key].ToArray())
    if ($arr.Count -lt [int]$Config.serialProtectedMinItems) { continue }
    $rank = 999
    foreach ($i in $arr) {
      $r = Get-IdeaSeverityRank -Idea $i
      if ($r -lt $rank) { $rank = $r }
    }
    $score = 0.0
    try { $score = ($arr | ForEach-Object { try { [double]$_.score } catch { 0.0 } } | Measure-Object -Sum).Sum } catch { $score = 0.0 }
    [void]$summaries.Add([pscustomobject]@{ key=$key; count=$arr.Count; severity_rank=$rank; score=$score; items=$arr })
  }
  $best = @($summaries.ToArray() | Sort-Object @{Expression={ -[int]$_.count }}, @{Expression={ [int]$_.severity_rank }}, @{Expression={ -[double]$_.score }}, @{Expression={ [string]$_.key }} | Select-Object -First 1)
  $selectedKey = ''
  $selectedGroup = @()
  if ($best.Count -gt 0) {
    $selectedKey = [string]$best[0].key
    $selectedGroup = @($best[0].items)
  }

  $selected = @(
    $selectedGroup |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}} |
    Select-Object -First ([int]$Config.serialProtectedMaxItems)
  )
  $ids = @($selected | ForEach-Object { [string]$_.id })
  $packs = @($selected | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
  $groupsOut = @($selected | ForEach-Object { [string]$_.workpack_conflict_group } | Sort-Object -Unique)
  $touches = @()
  foreach ($item in @($selected)) { $touches += @(Get-BacklogWorkpackItemTouches -Item $item) }
  $touches = @($touches | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  $batchAvailable = ($selected.Count -ge [int]$Config.serialProtectedMinItems)
  $reason = 'unknown'
  if (-not [bool]$Config.serialProtectedEnabled) {
    $reason = 'disabled'
  } elseif ($protected.Count -lt [int]$Config.serialProtectedMinItems) {
    $reason = 'not-enough-protected'
  } elseif ($eligible.Count -lt [int]$Config.serialProtectedMinItems) {
    if ($dependencyWait -gt 0) { $reason = 'dependency-wait' }
    elseif ($structuralWait -gt 0) { $reason = 'structural-barrier' }
    elseif ($governorDeferred -gt 0) { $reason = 'governor-deferred' }
    else { $reason = 'not-enough-eligible' }
  } elseif ($batchAvailable) {
    $reason = 'serial-batch-available'
  } else {
    $reason = 'not-enough-same-root'
  }
  if ($governorDirty) { Save-Backlog $allItems }

  $serialOrder = 0
  foreach ($item in @($selected)) {
    $serialOrder++
    $sid = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    if ($candidateById.ContainsKey($sid)) { Set-BacklogWorkpackCandidateSelected -Candidate $candidateById[$sid] -Order $serialOrder }
  }
  foreach ($candidate in @($candidateReports.ToArray())) {
    if ([bool]$candidate.selected -or [bool]$candidate.blocked) { continue }
    $fallbackReason = [string]$reason
    $fallbackDetail = 'protected candidate was not selected for this serial frontier'
    if ($batchAvailable) {
      $fallbackReason = 'serial-root-not-selected'
      $fallbackDetail = 'another protected root was selected: ' + [string]$selectedKey
    } elseif ([string]::IsNullOrWhiteSpace($fallbackReason) -or $fallbackReason -eq 'unknown') {
      $fallbackReason = 'not-selected'
    }
    Set-BacklogWorkpackCandidateBlocked -Candidate $candidate -Reason $fallbackReason -Detail $fallbackDetail
  }

  $candidateArr = @($candidateReports.ToArray())
  $blockedCandidates = @($candidateArr | Where-Object { [bool]$_.blocked })
  $selectedCandidates = @($candidateArr | Where-Object { [bool]$_.selected })
  $selectedLanes = @($selectedCandidates | ForEach-Object { [string]$_.lane } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $selectedParallelGroups = @($selectedCandidates | ForEach-Object { [string]$_.parallel_group } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $reasonDetails = New-BacklogWorkpackFrontierReasonDetails -Candidates $candidateArr -SelectedIds $ids
  $reasonDetail = Format-BacklogWorkpackFrontierReasonDetail -Reason $reason -Details $reasonDetails

  $report = [pscustomobject][ordered]@{
    enabled = [bool]$Config.serialProtectedEnabled
    approved_count = [int]$approved.Count
    with_workpack_count = [int]$protected.Count
    without_workpack_count = 0
    candidate_count = [int]$candidateArr.Count
    eligible_count = [int]$eligible.Count
    protected_count = [int]$protected.Count
    ready_count = [int]$eligible.Count
    group_count = [int]$groups.Count
    selected_count = [int]$selected.Count
    blocked_count = [int]$blockedCandidates.Count
    min_items = [int]$Config.serialProtectedMinItems
    max_items = [int]$Config.serialProtectedMaxItems
    dependency_wait_count = [int]$dependencyWait
    structural_wait_count = [int]$structuralWait
    governor_deferred_count = [int]$governorDeferred
    governor_dropped_count = [int]$governorDropped
    conflict_skip_count = 0
    touch_skip_count = 0
    claim_available = [bool]$batchAvailable
    batch_available = [bool]$batchAvailable
    parallel_required = $false
    workpack_batch_mode = if ($batchAvailable) { 'serial' } else { '' }
    serial_required = [bool]$batchAvailable
    reason = [string]$reason
    reason_detail = [string]$reasonDetail
    reason_details = $reasonDetails
    selected_root = [string]$selectedKey
    selected_ids = @($ids)
    selected_groups = @($groupsOut)
    selected_lanes = @($selectedLanes)
    selected_parallel_groups = @($selectedParallelGroups)
    selected_touches = @($touches)
    blocked_ids = @($blockedCandidates | ForEach-Object { [string]$_.id })
    candidates = @($candidateArr)
    frontier_candidates = @($candidateArr)
    serial_reason = 'protected-serial'
  }

  return [pscustomobject][ordered]@{
    items = @($selected)
    ids = @($ids)
    workpacks = @($packs)
    conflict_groups = @($groupsOut)
    touches = @($touches)
    count = [int]$selected.Count
    eligible_count = [int]$eligible.Count
    protected_count = [int]$protected.Count
    dependency_wait_count = [int]$dependencyWait
    structural_wait_count = [int]$structuralWait
    governor_deferred_count = [int]$governorDeferred
    governor_dropped_count = [int]$governorDropped
    selected_root = [string]$selectedKey
    candidates = @($candidateArr)
    report = $report
  }
}

function Get-BacklogProtectedSerialFrontierReport {
  param($Config = $null)
  $frontier = Resolve-BacklogProtectedSerialFrontier -Config $Config
  return $frontier.report
}

function Get-NextBacklogProtectedSerialBatch {
  param($Config = $null)
  $frontier = Resolve-BacklogProtectedSerialFrontier -Config $Config
  if (-not $frontier -or -not $frontier.report -or -not [bool]$frontier.report.batch_available) { return $null }
  return [pscustomobject]@{
    items = @($frontier.items)
    ids = @($frontier.ids)
    workpacks = @($frontier.workpacks)
    conflict_groups = @($frontier.conflict_groups)
    touches = @($frontier.touches)
    count = [int]$frontier.count
    eligible_count = [int]$frontier.eligible_count
    protected_count = [int]$frontier.protected_count
    dependency_wait_count = [int]$frontier.dependency_wait_count
    structural_wait_count = [int]$frontier.structural_wait_count
    selected_root = [string]$frontier.selected_root
    candidates = @($frontier.candidates)
    frontier_report = $frontier.report
  }
}

function New-BacklogWorkpackBatchTaskText {
  param([object[]]$Items)
  $itemsArr = @($Items | Where-Object { $_ })
  $n = $itemsArr.Count
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("[Автозадача из workpack-batch] Выполни $n независимых approved задач бэклога одним проверяемым проходом.")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Цель слоя: не идти по очереди, а отдать независимые workpacks существующему parallel dispatcher.')
  [void]$sb.AppendLine('Правила:')
  [void]$sb.AppendLine('- Не обходи safety: если задача стала нерелевантной или опасной, явно скажи это в отчёте.')
  [void]$sb.AppendLine('- Для независимых пунктов в первом ходе выдай STATUS: CONTINUE и отдельные [[PARALLEL:<id>]] блоки.')
  [void]$sb.AppendLine('- В каждом [[PARALLEL]] блоке обязательно укажи Files: с разрешёнными файлами/touch set.')
  [void]$sb.AppendLine('- После merge обычные verify/critic/smoke gates должны подтвердить общий результат.')
  [void]$sb.AppendLine('- Каждый поток в конце должен оставить краткий итог и полезные PROJECT_* memory-маркеры, если появились новые решения/риски/проверки.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Шаблон первого ответа для planner-а: скопируй эти блоки, если задачи всё ещё независимы.')
  [void]$sb.AppendLine('')
  $idx = 0
  foreach ($item in $itemsArr) {
    $idx++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    $packId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default '')
    $group = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default 'general')
    $touches = @(Get-BacklogWorkpackItemEditTouches -Item $item)
    if ($touches.Count -eq 0) { $touches = @($group) }
    $files = ($touches | Select-Object -First 8) -join ', '
    $deps = @(Get-BacklogTaskDependencySlugs -Item $item)
    $chapter = [string](Get-BacklogPackObjectValue -Obj $item -Name 'chapter' -Default '')
    $wave = [string](Get-BacklogPackObjectValue -Obj $item -Name 'wave' -Default '')
    $parallelGroup = [string](Get-BacklogPackObjectValue -Obj $item -Name 'parallel_group' -Default '')
    $checks = @()
    try { $checks = @(Get-BacklogPackObjectValue -Obj $item -Name 'verification_checks' -Default @() | ForEach-Object { [string]$_ }) } catch { $checks = @() }
    $acceptance = @()
    try { $acceptance = @(Get-BacklogPackObjectValue -Obj $item -Name 'acceptance_checks' -Default @() | ForEach-Object { [string]$_ }) } catch { $acceptance = @() }
    $text = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '') -replace '\s+', ' ').Trim()
    [void]$sb.AppendLine(("ITEM {0}: backlog_id={1}" -f $idx, $id))
    [void]$sb.AppendLine(("workpack={0}; conflict_group={1}" -f $packId, $group))
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$sb.AppendLine(("Chapter: {0}" -f $chapter)) }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$sb.AppendLine(("Wave: {0}" -f $wave)) }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$sb.AppendLine(("Parallel group: {0}" -f $parallelGroup)) }
    if ($deps.Count -gt 0) { [void]$sb.AppendLine(("Depends on: {0}" -f (($deps | Select-Object -First 8) -join ', '))) }
    [void]$sb.AppendLine(("Files: {0}" -f $files))
    if ($acceptance.Count -gt 0) { [void]$sb.AppendLine(("Acceptance: {0}" -f (($acceptance | Select-Object -First 4) -join ' ; '))) }
    if ($checks.Count -gt 0) { [void]$sb.AppendLine(("Checks: {0}" -f (($checks | Select-Object -First 4) -join ' ; '))) }
    [void]$sb.AppendLine(("Task: {0}" -f $text))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("[[PARALLEL:wp{0}]]" -f $idx))
    [void]$sb.AppendLine(("Files: {0}" -f $files))
    if ($checks.Count -gt 0) { [void]$sb.AppendLine(("Checks: {0}" -f (($checks | Select-Object -First 4) -join ' ; '))) }
    if ($acceptance.Count -gt 0) { [void]$sb.AppendLine(("Acceptance: {0}" -f (($acceptance | Select-Object -First 4) -join ' ; '))) }
    # 2026-06-01 AUTONOMY: complexity now inferred per-task (was hardcoded 'moderate' for every
    # stream, which made the worker router blind to real task difficulty). Drives Select-WorkerForStream.
    $cx = 'moderate'
    try { if (Get-Command Get-TaskComplexityHeuristic -ErrorAction SilentlyContinue) { $cx = Get-TaskComplexityHeuristic -Text $text -TouchCount (@($touches).Count) } } catch {}
    [void]$sb.AppendLine(("Complexity: {0}" -f $cx))
    [void]$sb.AppendLine(("Task: {0}" -f $text))
    [void]$sb.AppendLine(("[[/PARALLEL:wp{0}]]" -f $idx))
    [void]$sb.AppendLine('')
  }
  [void]$sb.AppendLine('STATUS: CONTINUE')
  return $sb.ToString().Trim()
}

function New-BacklogProtectedSerialBatchTaskText {
  param([object[]]$Items, [string]$Root = '')
  $itemsArr = @($Items | Where-Object { $_ })
  $n = $itemsArr.Count
  $rootText = if ([string]::IsNullOrWhiteSpace($Root)) { 'protected/root-cause' } else { [string]$Root }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("[Автозадача из protected-serial-workpack] Выполни $n связанных protected approved задач бэклога одним ПОСЛЕДОВАТЕЛЬНЫМ проверяемым проходом.")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine(("Общий корень/зона: {0}" -f $rootText))
  [void]$sb.AppendLine('Цель слоя: не идти по одной audit-задаче, а закрыть связанный safety/core кластер одним root-cause фиксом или честным COVERED/duplicate отчётом.')
  [void]$sb.AppendLine('Правила:')
  [void]$sb.AppendLine('- НЕ эмить [[PARALLEL:*]] и НЕ запускать несколько воркеров: это protected serial batch.')
  [void]$sb.AppendLine('- Не обходи safety/guard/verify/rollback. Если пункт опасен или нерелевантен, явно пометь его COVERED/BLOCKED в отчёте.')
  [void]$sb.AppendLine('- Сначала сгруппируй повторы по смыслу, затем сделай минимальный общий фикс. Не правь unrelated-файлы.')
  [void]$sb.AppendLine('- Перед STATUS: DONE покажи проверку: ParseFile/smoke/релевантный selftest. Без проверки задача не закрывается.')
  [void]$sb.AppendLine('- В итоговом отчёте перечисли backlog_id, которые закрыты изменением или COVERED существующим кодом.')
  [void]$sb.AppendLine('')
  $idx = 0
  foreach ($item in $itemsArr) {
    $idx++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    $packId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default '')
    $group = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default 'protected')
    $rootKey = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_root_cause_key' -Default '')
    $touches = @(Get-BacklogWorkpackItemTouches -Item $item)
    if ($touches.Count -eq 0) { $touches = @($group) }
    $files = ($touches | Select-Object -First 8) -join ', '
    $text = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '') -replace '\s+', ' ').Trim()
    [void]$sb.AppendLine(("ITEM {0}: backlog_id={1}" -f $idx, $id))
    [void]$sb.AppendLine(("workpack={0}; conflict_group={1}; root={2}" -f $packId, $group, $rootKey))
    [void]$sb.AppendLine(("Files/touch: {0}" -f $files))
    [void]$sb.AppendLine(("Task: {0}" -f $text))
    [void]$sb.AppendLine('')
  }
  [void]$sb.AppendLine('Первый ход planner-а: если нужны правки, передай Codex ОДИН последовательный STATUS: CONTINUE с объединённым планом. Если всё уже покрыто, STATUS: DONE с COVERED-обоснованием и проверкой.')
  return $sb.ToString().Trim()
}

#endregion Backlog workpack packing and batching
