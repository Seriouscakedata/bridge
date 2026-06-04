# workpack-obligation.ps1 -- pure read-only workpack metadata and eligibility checks.
#
# This file is intentionally isolated from the live driver. It does not write
# files, mutate runtime state, call models/APIs, or authorize execution. It only
# validates workpack atoms and derives a deterministic parallel eligibility
# report for tests and future shadow integration.

$script:WorkpackSerialReasonEnum = @(
  '',
  'foundation',
  'integration',
  'critical_bridge_self',
  'control_plane',
  'shared_file',
  'shared_schema',
  'active_claim_conflict',
  'readiness_red',
  'dirty_repo',
  'worker_capacity',
  'previous_parallel_conflict',
  'acceptance_release'
)

$script:WorkpackCriticalSerialReasonEnum = @(
  'foundation',
  'integration',
  'critical_bridge_self',
  'control_plane'
)

function Get-WorkpackAtomMetadataSchema {
  return [ordered]@{
    ok              = 'bool'
    slug            = 'string'
    files           = 'string[]'
    touch_set       = 'string[]'
    depends_on      = 'string[]'
    lane            = 'string'
    parallel_group  = 'string'
    serial_reason   = 'string'
    acceptance      = 'object'
    checks          = 'string[]'
    runnable_reasons = 'string[]'
    blocked_reasons  = 'string[]'
    missing         = 'string[]'
    warnings        = 'string[]'
    blockers        = 'string[]'
  }
}

function Get-WorkpackEligibilityReportSchema {
  return [ordered]@{
    ready                  = 'string[]'
    selected               = 'string[]'
    blocked_by_deps        = 'string[]'
    blocked_by_conflict    = 'string[]'
    blocked_by_touch       = 'string[]'
    serial_barriers        = 'string[]'
    parallel_required      = 'bool'
    serial_reason_required = 'bool'
    runnable_reasons       = 'object'
    blocked_reasons        = 'object'
    atom_metadata          = 'object[]'
    warnings               = 'string[]'
    blockers               = 'string[]'
  }
}

function Get-WorkpackValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return ,$Object[$name] }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) { return ,$prop.Value }
  }
  return $null
}

function ConvertTo-WorkpackUniqueStringArray {
  param([string[]]$Values)
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($value in @($Values)) {
    $text = if ($null -eq $value) { '' } else { [string]$value }
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $trimmed = $text.Trim()
    if ($seen.Add($trimmed)) {
      [void]$result.Add($trimmed)
    }
  }
  return @($result.ToArray())
}

function Normalize-WorkpackPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $p = ([string]$Path).Trim().Trim('"').Trim("'") -replace '\\','/'
  $p = $p -replace '^[A-Za-z]:/Users/[^/]+/OneDrive/Documents/bridge/',''
  $p = $p -replace '^\./',''
  while ($p.StartsWith('/')) { $p = $p.Substring(1) }
  return $p.ToLowerInvariant()
}

function ConvertTo-WorkpackNormalizedPathArray {
  param([string[]]$Values)
  $normalized = foreach ($value in @($Values)) {
    $path = Normalize-WorkpackPath -Path $value
    if (-not [string]::IsNullOrWhiteSpace($path)) { $path }
  }
  return ConvertTo-WorkpackUniqueStringArray -Values @($normalized)
}

function Test-WorkpackStringEnumerable {
  param(
    $Value,
    [bool]$AllowEmpty = $false
  )
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return $false }
  if ($Value -isnot [System.Collections.IEnumerable]) { return $false }

  $count = 0
  foreach ($item in $Value) {
    $count++
    if ($null -eq $item) { continue }
    if (-not [string]::IsNullOrWhiteSpace(([string]$item).Trim())) {
      if ($AllowEmpty) { return $true }
    }
  }

  if ($AllowEmpty) { return $true }
  return ($count -gt 0)
}

function ConvertTo-WorkpackStringArray {
  param($Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) {
    $text = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text)
  }

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Value) {
    if ($null -eq $item) { continue }
    $text = ([string]$item).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    [void]$items.Add($text)
  }
  return @($items.ToArray())
}

function Test-WorkpackNonEmptyValue {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if ($null -eq $item) { continue }
      if (-not [string]::IsNullOrWhiteSpace(([string]$item).Trim())) { return $true }
    }
  }
  return $true
}

function Get-WorkpackSlug {
  param($Atom)
  $slug = [string](Get-WorkpackValue -Object $Atom -Names @('slug','Slug'))
  return $slug.Trim()
}

function Get-WorkpackSerialReason {
  param($Atom)
  $value = Get-WorkpackValue -Object $Atom -Names @('serial_reason','SerialReason')
  if ($null -eq $value) { return $null }
  return ([string]$value).Trim()
}

function Get-WorkpackLane {
  param($Atom)
  $value = Get-WorkpackValue -Object $Atom -Names @('lane','Lane')
  if ($null -eq $value) { return '' }
  return ([string]$value).Trim()
}

function Test-WorkpackControlPlaneLane {
  param([string]$Lane)
  if ([string]::IsNullOrWhiteSpace($Lane)) { return $false }
  $normalized = $Lane.Trim().ToLowerInvariant() -replace '_','-'
  return ($normalized -eq 'control-plane')
}

function Test-WorkpackValidSerialReason {
  param(
    [string]$SerialReason,
    [bool]$AllowEmpty = $true
  )
  if ($null -eq $SerialReason) { return $false }
  $value = $SerialReason.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) { return $AllowEmpty }
  return ($script:WorkpackSerialReasonEnum -contains $value)
}

function Test-WorkpackCriticalSerialBarrier {
  param([string]$SerialReason)
  if ([string]::IsNullOrWhiteSpace($SerialReason)) { return $false }
  return ($script:WorkpackCriticalSerialReasonEnum -contains $SerialReason.Trim())
}

function Add-WorkpackIssue {
  param(
    [System.Collections.Generic.List[string]]$Target,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  if (-not $Target.Contains($Value)) {
    [void]$Target.Add($Value)
  }
}

function Add-WorkpackReason {
  param(
    [System.Collections.IDictionary]$Target,
    [string]$Slug,
    [string]$Reason
  )
  if ([string]::IsNullOrWhiteSpace($Slug) -or [string]::IsNullOrWhiteSpace($Reason)) { return }
  if (-not $Target.Contains($Slug)) {
    $Target[$Slug] = @()
  }
  $current = @($Target[$Slug])
  if ($current -notcontains $Reason) {
    $Target[$Slug] = @($current + $Reason)
  }
}

function Join-WorkpackReasonValues {
  param([string[]]$Values)
  $items = @(ConvertTo-WorkpackUniqueStringArray -Values $Values | Sort-Object)
  if ($items.Count -eq 0) { return '' }
  return ($items -join ',')
}

function New-WorkpackAtomMetadataResult {
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [string]$Slug = '',
    [string[]]$Files = @(),
    [string[]]$TouchSet = @(),
    [string[]]$DependsOn = @(),
    [string]$Lane = '',
    [string]$ParallelGroup = '',
    [string]$SerialReason = '',
    $Acceptance = $null,
    [string[]]$Checks = @(),
    [string[]]$RunnableReasons = @(),
    [string[]]$BlockedReasons = @(),
    [string[]]$Missing = @(),
    [string[]]$Warnings = @(),
    [string[]]$Blockers = @()
  )

  return [pscustomobject][ordered]@{
    ok               = $Ok
    slug             = $Slug
    files            = @(ConvertTo-WorkpackNormalizedPathArray -Values $Files)
    touch_set        = @(ConvertTo-WorkpackNormalizedPathArray -Values $TouchSet)
    depends_on       = @(ConvertTo-WorkpackUniqueStringArray -Values $DependsOn)
    lane             = $Lane
    parallel_group   = $ParallelGroup
    serial_reason    = $SerialReason
    acceptance       = $Acceptance
    checks           = @(ConvertTo-WorkpackUniqueStringArray -Values $Checks)
    runnable_reasons = @(ConvertTo-WorkpackUniqueStringArray -Values $RunnableReasons)
    blocked_reasons  = @(ConvertTo-WorkpackUniqueStringArray -Values $BlockedReasons)
    missing          = @(ConvertTo-WorkpackUniqueStringArray -Values $Missing)
    warnings         = @(ConvertTo-WorkpackUniqueStringArray -Values $Warnings)
    blockers         = @(ConvertTo-WorkpackUniqueStringArray -Values $Blockers)
  }
}

function New-WorkpackEligibilityReport {
  param(
    [string[]]$Ready = @(),
    [string[]]$Selected = @(),
    [string[]]$BlockedByDeps = @(),
    [string[]]$BlockedByConflict = @(),
    [string[]]$BlockedByTouch = @(),
    [string[]]$SerialBarriers = @(),
    [Parameter(Mandatory)][bool]$ParallelRequired,
    [Parameter(Mandatory)][bool]$SerialReasonRequired,
    [System.Collections.IDictionary]$RunnableReasons = @{},
    [System.Collections.IDictionary]$BlockedReasons = @{},
    [object[]]$AtomMetadata = @(),
    [string[]]$Warnings = @(),
    [string[]]$Blockers = @()
  )

  return [pscustomobject][ordered]@{
    ready                  = @(ConvertTo-WorkpackUniqueStringArray -Values $Ready)
    selected               = @(ConvertTo-WorkpackUniqueStringArray -Values $Selected)
    blocked_by_deps        = @(ConvertTo-WorkpackUniqueStringArray -Values $BlockedByDeps)
    blocked_by_conflict    = @(ConvertTo-WorkpackUniqueStringArray -Values $BlockedByConflict)
    blocked_by_touch       = @(ConvertTo-WorkpackUniqueStringArray -Values $BlockedByTouch)
    serial_barriers        = @(ConvertTo-WorkpackUniqueStringArray -Values $SerialBarriers)
    parallel_required      = $ParallelRequired
    serial_reason_required = $SerialReasonRequired
    runnable_reasons       = $RunnableReasons
    blocked_reasons        = $BlockedReasons
    atom_metadata          = @($AtomMetadata)
    warnings               = @(ConvertTo-WorkpackUniqueStringArray -Values $Warnings)
    blockers               = @(ConvertTo-WorkpackUniqueStringArray -Values $Blockers)
  }
}

function Get-WorkpackSelectionResult {
  param(
    [object[]]$Candidates = @(),
    [string[]]$PreferredSlugs = @(),
    [Nullable[int]]$Capacity = $null
  )

  $candidateMap = @{}
  foreach ($candidate in @($Candidates)) {
    $candidateMap[[string]$candidate.slug] = $candidate
  }

  $ordered = New-Object System.Collections.Generic.List[object]
  $preferredMode = (@($PreferredSlugs).Count -gt 0)

  if ($preferredMode) {
    foreach ($slug in @($PreferredSlugs)) {
      if ($candidateMap.ContainsKey($slug)) {
        [void]$ordered.Add($candidateMap[$slug])
      }
    }
  } else {
    foreach ($candidate in @($Candidates | Sort-Object slug)) {
      [void]$ordered.Add($candidate)
    }
  }

  $selected = New-Object System.Collections.Generic.List[string]
  $blockedByConflict = New-Object System.Collections.Generic.List[string]
  $blockedByTouch = New-Object System.Collections.Generic.List[string]
  $selectedGroups = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $selectedTouch = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $blockedReasons = [ordered]@{}
  $capacityReached = $false

  foreach ($candidate in $ordered.ToArray()) {
    if ($capacityReached) { break }
    if ($null -ne $Capacity -and $selected.Count -ge $Capacity.Value) {
      $capacityReached = $true
      break
    }

    $group = [string]$candidate.parallel_group
    $hasGroupConflict = (-not [string]::IsNullOrWhiteSpace($group) -and $selectedGroups.Contains($group))
    $hasTouchConflict = $false
    $touchConflict = ''
    foreach ($touch in @($candidate.workpack_touch_set)) {
      if ($selectedTouch.Contains([string]$touch)) {
        $hasTouchConflict = $true
        $touchConflict = [string]$touch
        break
      }
    }

    if ($hasGroupConflict) {
      Add-WorkpackIssue -Target $blockedByConflict -Value ([string]$candidate.slug)
      Add-WorkpackReason -Target $blockedReasons -Slug ([string]$candidate.slug) -Reason ('parallel_group:' + $group)
      continue
    }

    if ($hasTouchConflict) {
      Add-WorkpackIssue -Target $blockedByTouch -Value ([string]$candidate.slug)
      Add-WorkpackReason -Target $blockedReasons -Slug ([string]$candidate.slug) -Reason ('touch_overlap:' + $touchConflict)
      continue
    }

    [void]$selected.Add([string]$candidate.slug)
    if (-not [string]::IsNullOrWhiteSpace($group)) { [void]$selectedGroups.Add($group) }
    foreach ($touch in @($candidate.workpack_touch_set)) {
      [void]$selectedTouch.Add([string]$touch)
    }
  }

  return [pscustomobject][ordered]@{
    selected            = @($selected.ToArray())
    blocked_by_conflict = @($blockedByConflict.ToArray())
    blocked_by_touch    = @($blockedByTouch.ToArray())
    blocked_reasons     = $blockedReasons
  }
}

function Get-WorkpackContextSerialReason {
  param($Context)
  $value = Get-WorkpackValue -Object $Context -Names @(
    'serial_reason',
    'SerialReason',
    'required_serial_reason',
    'RequiredSerialReason'
  )
  if ($null -eq $value) { return '' }
  return ([string]$value).Trim()
}

function Get-WorkpackContextCapacity {
  param($Context)
  $value = Get-WorkpackValue -Object $Context -Names @('capacity','Capacity','parallel_capacity','ParallelCapacity')
  if ($null -eq $value) { return $null }
  if ($value -is [int] -or $value -is [long]) {
    if ([int]$value -ge 0) { return [int]$value }
  }
  $parsed = 0
  if ([int]::TryParse(([string]$value), [ref]$parsed) -and $parsed -ge 0) { return $parsed }
  return $null
}

function Test-WorkpackAtomMetadata {
  param($Atom)

  $missing = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $blockers = New-Object System.Collections.Generic.List[string]
  $runnableReasons = New-Object System.Collections.Generic.List[string]
  $blockedReasons = New-Object System.Collections.Generic.List[string]

  $slug = Get-WorkpackSlug -Atom $Atom
  if ([string]::IsNullOrWhiteSpace($slug)) {
    Add-WorkpackIssue -Target $missing -Value 'slug'
    Add-WorkpackIssue -Target $blockers -Value 'slug'
  }

  $title = [string](Get-WorkpackValue -Object $Atom -Names @('title','Title'))
  if ([string]::IsNullOrWhiteSpace($title)) {
    Add-WorkpackIssue -Target $missing -Value 'title'
    Add-WorkpackIssue -Target $blockers -Value 'title'
  }

  $task = [string](Get-WorkpackValue -Object $Atom -Names @('task','Task'))
  if ([string]::IsNullOrWhiteSpace($task)) {
    Add-WorkpackIssue -Target $missing -Value 'task'
    Add-WorkpackIssue -Target $blockers -Value 'task'
  }

  $filesValue = Get-WorkpackValue -Object $Atom -Names @('files','Files')
  $files = @()
  if (-not (Test-WorkpackStringEnumerable -Value $filesValue -AllowEmpty $false)) {
    Add-WorkpackIssue -Target $missing -Value 'files'
    Add-WorkpackIssue -Target $blockers -Value 'files'
  } else {
    $files = ConvertTo-WorkpackNormalizedPathArray -Values (ConvertTo-WorkpackStringArray -Value $filesValue)
    if (@($files).Count -eq 0) {
      Add-WorkpackIssue -Target $missing -Value 'files'
      Add-WorkpackIssue -Target $blockers -Value 'files'
    } elseif (@($files).Count -lt @(ConvertTo-WorkpackStringArray -Value $filesValue).Count) {
      Add-WorkpackIssue -Target $warnings -Value 'files_duplicates'
    }
  }

  $dependsValue = Get-WorkpackValue -Object $Atom -Names @('depends_on','DependsOn')
  $depends = @()
  if (-not (Test-WorkpackStringEnumerable -Value $dependsValue -AllowEmpty $true)) {
    Add-WorkpackIssue -Target $missing -Value 'depends_on'
    Add-WorkpackIssue -Target $blockers -Value 'depends_on'
  } else {
    $depends = ConvertTo-WorkpackUniqueStringArray -Values (ConvertTo-WorkpackStringArray -Value $dependsValue)
    if (@($depends).Count -lt @(ConvertTo-WorkpackStringArray -Value $dependsValue).Count) {
      Add-WorkpackIssue -Target $warnings -Value 'depends_on_duplicates'
    }
  }

  $lane = Get-WorkpackLane -Atom $Atom
  if ([string]::IsNullOrWhiteSpace($lane)) {
    Add-WorkpackIssue -Target $missing -Value 'lane'
    Add-WorkpackIssue -Target $blockers -Value 'lane'
  }

  $group = ([string](Get-WorkpackValue -Object $Atom -Names @('parallel_group','ParallelGroup','workpack_conflict_group','WorkpackConflictGroup'))).Trim()
  if ([string]::IsNullOrWhiteSpace($group)) {
    Add-WorkpackIssue -Target $missing -Value 'parallel_group'
    Add-WorkpackIssue -Target $blockers -Value 'parallel_group'
  }

  $touchValue = Get-WorkpackValue -Object $Atom -Names @('touch_set','TouchSet','workpack_touch_set','WorkpackTouchSet')
  $touches = @()
  if (-not (Test-WorkpackStringEnumerable -Value $touchValue -AllowEmpty $false)) {
    Add-WorkpackIssue -Target $missing -Value 'touch_set'
    Add-WorkpackIssue -Target $blockers -Value 'touch_set'
  } else {
    $touches = ConvertTo-WorkpackNormalizedPathArray -Values (ConvertTo-WorkpackStringArray -Value $touchValue)
    if (@($touches).Count -eq 0) {
      Add-WorkpackIssue -Target $missing -Value 'touch_set'
      Add-WorkpackIssue -Target $blockers -Value 'touch_set'
    } elseif (@($touches).Count -lt @(ConvertTo-WorkpackStringArray -Value $touchValue).Count) {
      Add-WorkpackIssue -Target $warnings -Value 'touch_set_duplicates'
    }
  }

  $acceptance = Get-WorkpackValue -Object $Atom -Names @('acceptance','Acceptance')
  if (-not (Test-WorkpackNonEmptyValue -Value $acceptance)) {
    Add-WorkpackIssue -Target $missing -Value 'acceptance'
    Add-WorkpackIssue -Target $blockers -Value 'acceptance'
  }

  $checksValue = Get-WorkpackValue -Object $Atom -Names @('checks','Checks')
  $checks = @()
  if (-not (Test-WorkpackStringEnumerable -Value $checksValue -AllowEmpty $false)) {
    Add-WorkpackIssue -Target $missing -Value 'checks'
    Add-WorkpackIssue -Target $blockers -Value 'checks'
  } else {
    $checks = ConvertTo-WorkpackUniqueStringArray -Values (ConvertTo-WorkpackStringArray -Value $checksValue)
    if (@($checks).Count -eq 0) {
      Add-WorkpackIssue -Target $missing -Value 'checks'
      Add-WorkpackIssue -Target $blockers -Value 'checks'
    } elseif (@($checks).Count -lt @(ConvertTo-WorkpackStringArray -Value $checksValue).Count) {
      Add-WorkpackIssue -Target $warnings -Value 'checks_duplicates'
    }
  }

  $risk = [string](Get-WorkpackValue -Object $Atom -Names @('risk','Risk'))
  if ([string]::IsNullOrWhiteSpace($risk)) {
    Add-WorkpackIssue -Target $missing -Value 'risk'
    Add-WorkpackIssue -Target $blockers -Value 'risk'
  }

  $serialReason = Get-WorkpackSerialReason -Atom $Atom
  if ($null -eq $serialReason) {
    Add-WorkpackIssue -Target $missing -Value 'serial_reason'
    Add-WorkpackIssue -Target $blockers -Value 'serial_reason'
  } elseif (-not (Test-WorkpackValidSerialReason -SerialReason $serialReason -AllowEmpty $true)) {
    Add-WorkpackIssue -Target $blockers -Value 'serial_reason'
  }

  if ($blockers.Count -eq 0) {
    Add-WorkpackIssue -Target $runnableReasons -Value 'metadata_ok'
  } else {
    foreach ($blocker in @($blockers.ToArray())) {
      Add-WorkpackIssue -Target $blockedReasons -Value ('metadata:' + $blocker)
    }
  }

  return New-WorkpackAtomMetadataResult `
    -Ok ($blockers.Count -eq 0) `
    -Slug $slug `
    -Files @($files) `
    -TouchSet @($touches) `
    -DependsOn @($depends) `
    -Lane $lane `
    -ParallelGroup $group `
    -SerialReason $serialReason `
    -Acceptance $acceptance `
    -Checks @($checks) `
    -RunnableReasons @($runnableReasons.ToArray()) `
    -BlockedReasons @($blockedReasons.ToArray()) `
    -Missing @($missing.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -Blockers @($blockers.ToArray())
}

function Get-WorkpackEligibilityReport {
  param(
    [object[]]$Atoms = @(),
    $Context = $null
  )

  $warnings = New-Object System.Collections.Generic.List[string]
  $blockers = New-Object System.Collections.Generic.List[string]
  $blockedByDeps = New-Object System.Collections.Generic.List[string]
  $serialBarriers = New-Object System.Collections.Generic.List[string]
  $validAtoms = New-Object System.Collections.Generic.List[object]
  $atomMetadata = New-Object System.Collections.Generic.List[object]
  $runnableReasons = [ordered]@{}
  $blockedReasons = [ordered]@{}
  $seenSlugs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  $completedSlugs = ConvertTo-WorkpackUniqueStringArray -Values (ConvertTo-WorkpackStringArray -Value (Get-WorkpackValue -Object $Context -Names @('CompletedSlugs','completed_slugs')))
  $preferredSelected = ConvertTo-WorkpackUniqueStringArray -Values (ConvertTo-WorkpackStringArray -Value (Get-WorkpackValue -Object $Context -Names @('SelectedSlugs','selected_slugs')))
  $capacity = Get-WorkpackContextCapacity -Context $Context

  $sortableAtoms = New-Object System.Collections.Generic.List[object]
  foreach ($atom in @($Atoms)) {
    [void]$sortableAtoms.Add([pscustomobject][ordered]@{
      slug = Get-WorkpackSlug -Atom $atom
      atom = $atom
    })
  }

  foreach ($entry in @($sortableAtoms.ToArray() | Sort-Object slug)) {
    $atom = $entry.atom
    $metadata = Test-WorkpackAtomMetadata -Atom $atom
    $slug = Get-WorkpackSlug -Atom $atom
    $label = if ([string]::IsNullOrWhiteSpace($slug)) { '(missing slug)' } else { $slug }

    foreach ($warning in @($metadata.warnings)) {
      Add-WorkpackIssue -Target $warnings -Value ($label + ': ' + $warning)
    }
    foreach ($issue in @($metadata.blockers)) {
      Add-WorkpackIssue -Target $blockers -Value ($label + ': ' + $issue)
    }
    [void]$atomMetadata.Add($metadata)

    if (-not $metadata.ok) { continue }

    if (-not $seenSlugs.Add($slug)) {
      Add-WorkpackIssue -Target $blockers -Value ($slug + ': duplicate_slug')
      continue
    }

    $depends = ConvertTo-WorkpackUniqueStringArray -Values (ConvertTo-WorkpackStringArray -Value (Get-WorkpackValue -Object $atom -Names @('depends_on','DependsOn')))
    $touches = ConvertTo-WorkpackNormalizedPathArray -Values (ConvertTo-WorkpackStringArray -Value (Get-WorkpackValue -Object $atom -Names @('touch_set','TouchSet','workpack_touch_set','WorkpackTouchSet')))
    $parallelGroup = ([string](Get-WorkpackValue -Object $atom -Names @('parallel_group','ParallelGroup','workpack_conflict_group','WorkpackConflictGroup'))).Trim()
    $candidate = [pscustomobject][ordered]@{
      slug                    = $slug
      depends_on              = @($depends)
      lane                    = (Get-WorkpackLane -Atom $atom)
      parallel_group          = $parallelGroup
      workpack_conflict_group = $parallelGroup
      workpack_touch_set      = @($touches)
      serial_reason           = (Get-WorkpackSerialReason -Atom $atom)
    }
    [void]$validAtoms.Add($candidate)
  }

  $readyCandidates = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($validAtoms | Sort-Object slug)) {
    $unmetDeps = @($candidate.depends_on | Where-Object { $completedSlugs -notcontains $_ })
    if ($unmetDeps.Count -gt 0) {
      Add-WorkpackIssue -Target $blockedByDeps -Value ([string]$candidate.slug)
      Add-WorkpackIssue -Target $warnings -Value (([string]$candidate.slug) + ': unmet_deps=' + (($unmetDeps | Sort-Object) -join ','))
      Add-WorkpackReason -Target $blockedReasons -Slug ([string]$candidate.slug) -Reason ('deps:' + (Join-WorkpackReasonValues -Values $unmetDeps))
      continue
    }
    Add-WorkpackReason -Target $runnableReasons -Slug ([string]$candidate.slug) -Reason 'deps_met'
    [void]$readyCandidates.Add($candidate)
  }

  $parallelCandidates = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($readyCandidates | Sort-Object slug)) {
    $serialReason = [string]$candidate.serial_reason
    if (Test-WorkpackCriticalSerialBarrier -SerialReason $serialReason) {
      Add-WorkpackIssue -Target $serialBarriers -Value ([string]$candidate.slug)
      Add-WorkpackReason -Target $blockedReasons -Slug ([string]$candidate.slug) -Reason ('serial_reason:' + $serialReason)
      continue
    }
    if (Test-WorkpackControlPlaneLane -Lane ([string]$candidate.lane)) {
      Add-WorkpackIssue -Target $serialBarriers -Value ([string]$candidate.slug)
      Add-WorkpackReason -Target $blockedReasons -Slug ([string]$candidate.slug) -Reason 'lane:control-plane'
      continue
    }
    Add-WorkpackReason -Target $runnableReasons -Slug ([string]$candidate.slug) -Reason 'parallel_candidate'
    [void]$parallelCandidates.Add($candidate)
  }

  $recommendedSelection = Get-WorkpackSelectionResult -Candidates @($parallelCandidates.ToArray())
  $actualSelection = if ($preferredSelected.Count -gt 0 -or $null -ne $capacity) {
    Get-WorkpackSelectionResult -Candidates @($parallelCandidates.ToArray()) -PreferredSlugs $preferredSelected -Capacity $capacity
  } else {
    $recommendedSelection
  }

  if ($preferredSelected.Count -gt 0) {
    foreach ($slug in $preferredSelected) {
      if (@($readyCandidates | Where-Object { $_.slug -eq $slug }).Count -eq 0) {
        Add-WorkpackIssue -Target $warnings -Value ($slug + ': selected_not_ready')
      } elseif ($serialBarriers.Count -gt 0 -and $serialBarriers -contains $slug) {
        Add-WorkpackIssue -Target $warnings -Value ($slug + ': selected_is_serial_barrier')
      }
    }
  }

  foreach ($slug in @($actualSelection.selected)) {
    Add-WorkpackReason -Target $runnableReasons -Slug $slug -Reason 'selected_frontier'
  }
  foreach ($slug in @($actualSelection.blocked_reasons.Keys)) {
    foreach ($reason in @($actualSelection.blocked_reasons[$slug])) {
      Add-WorkpackReason -Target $blockedReasons -Slug $slug -Reason $reason
    }
  }

  if ($null -ne $capacity -and $capacity -eq 0 -and $parallelCandidates.Count -gt 0) {
    Add-WorkpackIssue -Target $warnings -Value 'capacity_zero'
  }

  $parallelRequired = (@($recommendedSelection.selected).Count -ge 2)
  $contextSerialReason = Get-WorkpackContextSerialReason -Context $Context
  $hasExplicitSerialReason = Test-WorkpackValidSerialReason -SerialReason $contextSerialReason -AllowEmpty $false
  if (-not $hasExplicitSerialReason) {
    foreach ($candidate in $readyCandidates.ToArray()) {
      if (Test-WorkpackValidSerialReason -SerialReason ([string]$candidate.serial_reason) -AllowEmpty $false) {
        $hasExplicitSerialReason = $true
        break
      }
    }
  }

  $serialReasonRequired = ($parallelRequired -and @($actualSelection.selected).Count -eq 1 -and -not $hasExplicitSerialReason)

  return New-WorkpackEligibilityReport `
    -Ready @(($readyCandidates | Sort-Object slug | ForEach-Object { $_.slug })) `
    -Selected @($actualSelection.selected) `
    -BlockedByDeps @($blockedByDeps.ToArray()) `
    -BlockedByConflict @($actualSelection.blocked_by_conflict) `
    -BlockedByTouch @($actualSelection.blocked_by_touch) `
    -SerialBarriers @($serialBarriers.ToArray()) `
    -ParallelRequired $parallelRequired `
    -SerialReasonRequired $serialReasonRequired `
    -RunnableReasons $runnableReasons `
    -BlockedReasons $blockedReasons `
    -AtomMetadata @($atomMetadata.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -Blockers @($blockers.ToArray())
}
