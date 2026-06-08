# backlog-governor.ps1 -- read-only Queue Governor foundation predicates

$script:BacklogGovernorBridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Get-BacklogGovernorObjectValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null
  )
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

function ConvertTo-BacklogGovernorStringArray {
  param([Parameter(Mandatory=$false)]$Value)
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

function Normalize-BacklogGovernorPath {
  param(
    [Parameter(Mandatory=$false)][string]$Path,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

  $raw = ([string]$Path).Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($raw)) { return '' }

  try {
    $base = if ([string]::IsNullOrWhiteSpace($Root)) {
      [System.IO.Directory]::GetCurrentDirectory()
    } else {
      [System.IO.Path]::GetFullPath([string]$Root)
    }
    $full = if ([System.IO.Path]::IsPathRooted($raw)) {
      [System.IO.Path]::GetFullPath($raw)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path $base $raw))
    }

    $baseWithSep = $base.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($baseWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
      $raw = $full.Substring($baseWithSep.Length)
    } elseif ([string]::Equals($full.TrimEnd('\','/'), $base.TrimEnd('\','/'), [System.StringComparison]::OrdinalIgnoreCase)) {
      $raw = '.'
    } else {
      $raw = $full
    }
  } catch {
    $raw = ([string]$Path).Trim().Trim('"').Trim("'")
  }

  $normalized = $raw -replace '\\','/'
  $normalized = $normalized -replace '/+','/'
  while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
  $normalized = $normalized.Trim()
  if ($normalized -ne '/') { $normalized = $normalized.TrimEnd('/') }
  if ($normalized -eq '.') { return '.' }
  return $normalized.ToLowerInvariant()
}

function Test-BacklogGovernorPathOverlap {
  param(
    [Parameter(Mandatory=$false)][string]$Left,
    [Parameter(Mandatory=$false)][string]$Right,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $a = Normalize-BacklogGovernorPath -Path $Left -Root $Root
  $b = Normalize-BacklogGovernorPath -Path $Right -Root $Root
  if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
  if ([string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  return ($b.StartsWith($a + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
          $a.StartsWith($b + '/', [System.StringComparison]::OrdinalIgnoreCase))
}

function Normalize-BacklogGovernorTouchSet {
  param(
    [Parameter(Mandatory=$false)]$TouchSet,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $normalized = @()
  foreach ($path in @(ConvertTo-BacklogGovernorStringArray -Value $TouchSet)) {
    $p = Normalize-BacklogGovernorPath -Path $path -Root $Root
    if (-not [string]::IsNullOrWhiteSpace($p)) { $normalized += $p }
  }
  return @($normalized | Sort-Object -Unique)
}

function Test-BacklogGovernorTouchSetOverlap {
  param(
    [Parameter(Mandatory=$false)]$Left,
    [Parameter(Mandatory=$false)]$Right,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $leftSet = @(Normalize-BacklogGovernorTouchSet -TouchSet $Left -Root $Root)
  $rightSet = @(Normalize-BacklogGovernorTouchSet -TouchSet $Right -Root $Root)
  foreach ($leftPath in $leftSet) {
    foreach ($rightPath in $rightSet) {
      if (Test-BacklogGovernorPathOverlap -Left $leftPath -Right $rightPath -Root $Root) { return $true }
    }
  }
  return $false
}

function Get-BacklogGovernorItemTouchSet {
  param([Parameter(Mandatory=$false)]$Item)
  $touch = @()
  foreach ($name in @('touch_set','files','lease_touch_set','workpack_touch_set')) {
    $touch += @(ConvertTo-BacklogGovernorStringArray -Value (Get-BacklogGovernorObjectValue -Object $Item -Names @($name)))
  }
  return @($touch | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Get-BacklogGovernorRootCauseKey {
  param([Parameter(Mandatory=$false)]$Item)
  $root = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('root_cause_key','lease_root_cause_key','workpack_root_cause_key') -Default '')
  if ([string]::IsNullOrWhiteSpace($root)) { return '' }
  return $root.Trim().ToLowerInvariant()
}

function Test-BacklogGovernorItemShape {
  param([Parameter(Mandatory=$false)]$Item)
  $status = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('status') -Default '')
  $governedStatus = @('approved','running','working') -contains $status.ToLowerInvariant()
  $missing = @()

  if ($governedStatus) {
    if ([string]::IsNullOrWhiteSpace([string](Get-BacklogGovernorObjectValue -Object $Item -Names @('id') -Default ''))) { $missing += 'id' }
    # 2026-06-06 (operator hotfix): shape requires only IDENTITY (id + title|text|task).
    # touch_set/root_cause_key are workpack-COORDINATION fields assigned at claim time, NOT
    # existence preconditions. Requiring them at intake dropped EVERY plain Add-Idea/operator
    # task as 'invalid-shape' (regression that wedged operator + project-autopilot atoms,
    # forced Codex to pause literary-slop-video). title is optional when text|task is present.
    $title = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('title') -Default '')
    $body = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('text','task') -Default '')
    if ([string]::IsNullOrWhiteSpace($title) -and [string]::IsNullOrWhiteSpace($body)) { $missing += 'title|text|task' }
  }

  $valid = ($missing.Count -eq 0)
  return [pscustomobject][ordered]@{
    valid = $valid
    reason = $(if ($valid) { 'valid' } else { 'invalid-shape' })
    detail = $(if ($valid) { '' } else { 'missing: ' + ($missing -join ', ') })
    missing = @($missing)
    status = $status
    governed_status = $governedStatus
    evidence = [pscustomobject][ordered]@{
      checked_fields = @('id','title','text|task','touch_set|files|lease_touch_set|workpack_touch_set','root_cause_key|lease_root_cause_key|workpack_root_cause_key')
      missing = @($missing)
      status = $status
    }
  }
}

function Test-BacklogGovernorActiveLeaseItem {
  param([Parameter(Mandatory=$false)]$Item)
  if ($null -eq $Item) { return $false }
  $status = ([string](Get-BacklogGovernorObjectValue -Object $Item -Names @('status') -Default '')).ToLowerInvariant()
  if (@('done','failed','rejected','auto-dropped','superseded','cancelled') -contains $status) { return $false }
  if (@('running','working') -contains $status) { return $true }
  foreach ($name in @('lease_id','lease_owner','lease_started_at')) {
    if (-not [string]::IsNullOrWhiteSpace([string](Get-BacklogGovernorObjectValue -Object $Item -Names @($name) -Default ''))) {
      return $true
    }
  }
  return $false
}

function New-BacklogGovernorNoConflictResult {
  param([Parameter(Mandatory=$true)][string]$Kind)
  return [pscustomobject][ordered]@{
    conflict = $false
    reason = 'no-' + $Kind
    detail = ''
    evidence = [pscustomobject][ordered]@{
      kind = $Kind
      conflict_with_id = ''
      conflict_on = ''
      conflict_value = ''
    }
  }
}

function Test-BacklogGovernorLeaseConflict {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$ActiveItems,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $itemId = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('id') -Default '')
  $itemTouch = @(Get-BacklogGovernorItemTouchSet -Item $Item)
  $itemRoot = Get-BacklogGovernorRootCauseKey -Item $Item

  foreach ($active in @($ActiveItems)) {
    if (-not (Test-BacklogGovernorActiveLeaseItem -Item $active)) { continue }
    $activeId = [string](Get-BacklogGovernorObjectValue -Object $active -Names @('id') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($itemId) -and
        [string]::Equals($itemId, $activeId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

    $activeRoot = Get-BacklogGovernorRootCauseKey -Item $active
    if (-not [string]::IsNullOrWhiteSpace($itemRoot) -and
        -not [string]::IsNullOrWhiteSpace($activeRoot) -and
        [string]::Equals($itemRoot, $activeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject][ordered]@{
        conflict = $true
        reason = 'lease-conflict'
        detail = "root_cause_key overlaps active lease $activeId"
        evidence = [pscustomobject][ordered]@{
          kind = 'lease'
          conflict_with_id = $activeId
          conflict_on = 'root_cause_key'
          conflict_value = $itemRoot
        }
      }
    }

    $activeTouch = @(Get-BacklogGovernorItemTouchSet -Item $active)
    if (Test-BacklogGovernorTouchSetOverlap -Left $itemTouch -Right $activeTouch -Root $Root) {
      return [pscustomobject][ordered]@{
        conflict = $true
        reason = 'lease-conflict'
        detail = "touch_set overlaps active lease $activeId"
        evidence = [pscustomobject][ordered]@{
          kind = 'lease'
          conflict_with_id = $activeId
          conflict_on = 'touch_set'
          conflict_value = (@(Normalize-BacklogGovernorTouchSet -TouchSet $activeTouch -Root $Root) -join ', ')
        }
      }
    }
  }

  return New-BacklogGovernorNoConflictResult -Kind 'lease-conflict'
}

function Test-BacklogGovernorManualLockActive {
  param([Parameter(Mandatory=$false)]$Lock)
  if ($null -eq $Lock) { return $false }
  $active = Get-BacklogGovernorObjectValue -Object $Lock -Names @('active','enabled') -Default $null
  if ($null -ne $active -and -not [bool]$active) { return $false }
  $status = ([string](Get-BacklogGovernorObjectValue -Object $Lock -Names @('status') -Default '')).ToLowerInvariant()
  if (@('released','expired','done','failed','rejected','inactive','cancelled') -contains $status) { return $false }
  return $true
}

function Test-BacklogGovernorManualLockConflict {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$ManualLocks,
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $itemTouch = @(Get-BacklogGovernorItemTouchSet -Item $Item)
  $itemRoot = Get-BacklogGovernorRootCauseKey -Item $Item

  foreach ($lock in @($ManualLocks)) {
    if (-not (Test-BacklogGovernorManualLockActive -Lock $lock)) { continue }
    $lockId = [string](Get-BacklogGovernorObjectValue -Object $lock -Names @('id','lock_id','backlog_id') -Default '')
    $lockRoot = Get-BacklogGovernorRootCauseKey -Item $lock
    if (-not [string]::IsNullOrWhiteSpace($itemRoot) -and
        -not [string]::IsNullOrWhiteSpace($lockRoot) -and
        [string]::Equals($itemRoot, $lockRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject][ordered]@{
        conflict = $true
        reason = 'manual-lock-conflict'
        detail = "root_cause_key overlaps manual lock $lockId"
        evidence = [pscustomobject][ordered]@{
          kind = 'manual-lock'
          conflict_with_id = $lockId
          conflict_on = 'root_cause_key'
          conflict_value = $itemRoot
        }
      }
    }

    $lockTouch = @(Get-BacklogGovernorItemTouchSet -Item $lock)
    if (Test-BacklogGovernorTouchSetOverlap -Left $itemTouch -Right $lockTouch -Root $Root) {
      return [pscustomobject][ordered]@{
        conflict = $true
        reason = 'manual-lock-conflict'
        detail = "touch_set overlaps manual lock $lockId"
        evidence = [pscustomobject][ordered]@{
          kind = 'manual-lock'
          conflict_with_id = $lockId
          conflict_on = 'touch_set'
          conflict_value = (@(Normalize-BacklogGovernorTouchSet -TouchSet $lockTouch -Root $Root) -join ', ')
        }
      }
    }
  }

  return New-BacklogGovernorNoConflictResult -Kind 'manual-lock-conflict'
}

function Test-BacklogGovernorClaimable {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$ActiveItems = @(),
    [Parameter(Mandatory=$false)]$ManualLocks = @(),
    [Parameter(Mandatory=$false)][string]$Root = $script:BacklogGovernorBridgeRoot
  )
  $shape = Test-BacklogGovernorItemShape -Item $Item
  $itemId = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('id') -Default '')
  $normalizedTouch = @(Normalize-BacklogGovernorTouchSet -TouchSet (Get-BacklogGovernorItemTouchSet -Item $Item) -Root $Root)
  $rootKey = Get-BacklogGovernorRootCauseKey -Item $Item

  if (-not [bool]$shape.valid) {
    return [pscustomobject][ordered]@{
      claimable = $false
      reason = 'invalid-shape'
      detail = [string]$shape.detail
      action = 'drop'
      evidence = [pscustomobject][ordered]@{
        item_id = $itemId
        touch_set = @($normalizedTouch)
        root_cause_key = $rootKey
        shape = $shape.evidence
        conflict = $null
      }
    }
  }

  $lease = Test-BacklogGovernorLeaseConflict -Item $Item -ActiveItems $ActiveItems -Root $Root
  if ([bool]$lease.conflict) {
    return [pscustomobject][ordered]@{
      claimable = $false
      reason = [string]$lease.reason
      detail = [string]$lease.detail
      action = 'defer'
      evidence = [pscustomobject][ordered]@{
        item_id = $itemId
        touch_set = @($normalizedTouch)
        root_cause_key = $rootKey
        shape = $shape.evidence
        conflict = $lease.evidence
      }
    }
  }

  $manual = Test-BacklogGovernorManualLockConflict -Item $Item -ManualLocks $ManualLocks -Root $Root
  if ([bool]$manual.conflict) {
    return [pscustomobject][ordered]@{
      claimable = $false
      reason = [string]$manual.reason
      detail = [string]$manual.detail
      action = 'defer'
      evidence = [pscustomobject][ordered]@{
        item_id = $itemId
        touch_set = @($normalizedTouch)
        root_cause_key = $rootKey
        shape = $shape.evidence
        conflict = $manual.evidence
      }
    }
  }

  return [pscustomobject][ordered]@{
    claimable = $true
    reason = 'claimable'
    detail = ''
    action = 'allow'
    evidence = [pscustomobject][ordered]@{
      item_id = $itemId
      touch_set = @($normalizedTouch)
      root_cause_key = $rootKey
      shape = $shape.evidence
      conflict = $null
    }
  }
}

function Test-BacklogGovernorDoneRegressionReopen {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$RegressionEvidence
  )

  $itemId = [string](Get-BacklogGovernorObjectValue -Object $Item -Names @('id') -Default '')
  $status = ([string](Get-BacklogGovernorObjectValue -Object $Item -Names @('status') -Default '')).Trim().ToLowerInvariant()
  if ($status -ne 'done') {
    return [pscustomobject][ordered]@{
      reopen = $false
      proposed_status = $status
      reason = 'status_not_done'
      evidence = [pscustomobject][ordered]@{ item_id = $itemId; status = $status }
    }
  }

  $reasonText = [string](Get-BacklogGovernorObjectValue -Object $RegressionEvidence -Names @('reason','kind','check','gate') -Default '')
  $detailText = [string](Get-BacklogGovernorObjectValue -Object $RegressionEvidence -Names @('detail','text','message','error') -Default '')
  $checks = @(ConvertTo-BacklogGovernorStringArray -Value (Get-BacklogGovernorObjectValue -Object $RegressionEvidence -Names @('checks','tests','failed_checks') -Default @()))
  $combined = (($reasonText, $detailText) + @($checks)) -join ' '
  $matchesRegression = [bool]($combined -match '(?i)(gate[-_ ]?regression|regression|test[_ -]?failed|smoke|qa[_ -]?failed|snapshot suite|run-tests)')
  if (-not $matchesRegression) {
    return [pscustomobject][ordered]@{
      reopen = $false
      proposed_status = 'done'
      reason = 'no_regression_evidence'
      evidence = [pscustomobject][ordered]@{ item_id = $itemId; status = $status; reason = $reasonText; detail = $detailText; checks = @($checks) }
    }
  }

  return [pscustomobject][ordered]@{
    reopen = $true
    proposed_status = 'approved'
    reason = 'done_regression_detected'
    evidence = [pscustomobject][ordered]@{
      item_id = $itemId
      previous_status = 'done'
      reason = $reasonText
      detail = $detailText
      checks = @($checks)
    }
  }
}
