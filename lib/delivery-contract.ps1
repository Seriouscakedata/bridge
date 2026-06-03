# delivery-contract.ps1 -- pure read-only delivery contract validator.
#
# This file is intentionally isolated from the live driver. It does not write
# files, mutate runtime state, call models/APIs, or authorize execution. It only
# validates a delivery contract object and returns a deterministic strict result.

$script:DeliveryContractResultFieldEnum = @(
  'ok',
  'score',
  'missing',
  'warnings',
  'blockers',
  'required_sections'
)

$script:DeliveryContractRequiredSectionEnum = @(
  'goal',
  'scope/non_goals',
  'users/roles',
  'surfaces/routes/screens',
  'data/backend',
  'acceptance_scenarios',
  'checks',
  'risk',
  'parallel_policy'
)

$script:DeliveryContractBridgeSelfSectionEnum = @(
  'critical_paths',
  'canary'
)

$script:DeliveryContractShallowMinChars = 12

function Get-DeliveryContractSchema {
  return [ordered]@{
    ok                = 'bool'
    score             = 'int 0..100'
    missing           = 'string[]'
    warnings          = 'string[]'
    blockers          = 'string[]'
    required_sections = 'string[]'
  }
}

function Get-DeliveryContractValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    if ($Object -is [hashtable] -and $Object.ContainsKey($name)) { return $Object[$name] }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return $Object[$name] }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) { return $prop.Value }
  }
  return $null
}

function Find-DeliveryContractValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) {
    return [pscustomobject][ordered]@{
      found = $false
      name  = ''
      value = $null
    }
  }

  foreach ($name in $Names) {
    if ($Object -is [hashtable] -and $Object.ContainsKey($name)) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $Object[$name]
      }
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $Object[$name]
      }
    }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $prop.Value
      }
    }
  }

  return [pscustomobject][ordered]@{
    found = $false
    name  = ''
    value = $null
  }
}

function Test-DeliveryContractTruthy {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [string]) {
    return (@('1','true','yes','y','on') -contains $Value.Trim().ToLowerInvariant())
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    return ([double]$Value -ne 0)
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    foreach ($item in $Value) {
      if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) { return $true }
    }
  }
  return $false
}

function Add-DeliveryContractListItem {
  param(
    [Parameter(Mandatory)]$List,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

function Get-DeliveryContractSectionNames {
  param([Parameter(Mandatory)][string]$Section)
  switch ($Section) {
    'goal' { return @('goal','Goal','project_goal','projectGoal','mission','Mission','outcome','Outcome') }
    'scope/non_goals' { return @('scope','Scope','non_goals','NonGoals','nonGoals','non-goals','requirements','Requirements','capabilities','Capabilities','features','Features','functional_requirements','functionalRequirements') }
    'users/roles' { return @('users','Users','roles','Roles','personas','Personas','actors','Actors','user_journeys','userJourneys','journeys','Journeys','flows','Flows','workflows','Workflows') }
    'surfaces/routes/screens' { return @('surfaces','Surfaces','routes','Routes','screens','Screens') }
    'data/backend' { return @('data','Data','backend','Backend','storage','Storage','api','API','apis','APIs','endpoints','Endpoints','modules','Modules') }
    'acceptance_scenarios' { return @('acceptance_scenarios','AcceptanceScenarios','acceptanceScenarios','acceptance-scenarios') }
    'checks' { return @('checks','Checks') }
    'risk' { return @('risk','Risk','risks','Risks') }
    'parallel_policy' { return @('parallel_policy','ParallelPolicy','parallelPolicy','parallel-policy') }
    'critical_paths' { return @('critical_paths','CriticalPaths','criticalPaths','critical-paths','critical paths') }
    'canary' { return @('canary','Canary') }
    default { throw "Unknown delivery contract section: $Section" }
  }
}

function Get-DeliveryContractSignalLength {
  param($Value)
  if ($null -eq $Value) { return 0 }

  if ($Value -is [string]) {
    return (($Value -replace '\s','').Length)
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $sum = 0
    foreach ($entry in $Value.GetEnumerator()) {
      $sum += Get-DeliveryContractSignalLength -Value $entry.Value
    }
    return $sum
  }

  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    $sum = 0
    foreach ($item in $Value) {
      $sum += Get-DeliveryContractSignalLength -Value $item
    }
    return $sum
  }

  $props = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty') })
  if ($props.Count -gt 0) {
    $sum = 0
    foreach ($prop in $props) {
      $sum += Get-DeliveryContractSignalLength -Value $prop.Value
    }
    return $sum
  }

  return (([string]$Value -replace '\s','').Length)
}

function Get-DeliveryContractSectionState {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string]$Section
  )
  $slot = Find-DeliveryContractValue -Object $Contract -Names (Get-DeliveryContractSectionNames -Section $Section)
  $length = if ($slot.found) { Get-DeliveryContractSignalLength -Value $slot.value } else { 0 }
  return [pscustomobject][ordered]@{
    section = $Section
    found   = [bool]$slot.found
    name    = [string]$slot.name
    value   = $slot.value
    length  = [int]$length
    shallow = [bool]($slot.found -and $length -lt $script:DeliveryContractShallowMinChars)
  }
}

function Get-DeliveryContractExplicitSignalState {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][string[]]$Names
  )
  $foundAny = $false
  $nonShallowAny = $false
  $foundNames = New-Object 'System.Collections.Generic.List[string]'
  $shallowNames = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in $Names) {
    $slot = Find-DeliveryContractValue -Object $Contract -Names @($name)
    if (-not $slot.found) { continue }
    $foundAny = $true
    Add-DeliveryContractListItem -List $foundNames -Value ([string]$slot.name)
    $length = Get-DeliveryContractSignalLength -Value $slot.value
    if ($length -ge $script:DeliveryContractShallowMinChars) {
      $nonShallowAny = $true
    } else {
      Add-DeliveryContractListItem -List $shallowNames -Value ([string]$slot.name)
    }
  }
  return [pscustomobject][ordered]@{
    found       = [bool]$foundAny
    non_shallow = [bool]$nonShallowAny
    shallow     = [bool]($foundAny -and -not $nonShallowAny)
    names       = @($foundNames.ToArray())
    shallow_names = @($shallowNames.ToArray())
  }
}

function Get-DeliveryContractExplicitProjectSectionState {
  param(
    [Parameter(Mandatory)]$Contract,
    [Parameter(Mandatory)][ValidateSet('scope/non_goals','users/roles')][string]$Section
  )

  if ($Section -eq 'scope/non_goals') {
    $scope = Get-DeliveryContractExplicitSignalState -Contract $Contract -Names @('scope','Scope')
    $nonGoals = Get-DeliveryContractExplicitSignalState -Contract $Contract -Names @('non_goals','NonGoals','nonGoals','non-goals')
    $missingSignals = New-Object 'System.Collections.Generic.List[string]'
    $shallowSignals = New-Object 'System.Collections.Generic.List[string]'
    if (-not $scope.found) { Add-DeliveryContractListItem -List $missingSignals -Value 'scope' }
    elseif (-not $scope.non_shallow) { Add-DeliveryContractListItem -List $shallowSignals -Value 'scope' }
    if (-not $nonGoals.found) { Add-DeliveryContractListItem -List $missingSignals -Value 'non_goals' }
    elseif (-not $nonGoals.non_shallow) { Add-DeliveryContractListItem -List $shallowSignals -Value 'non_goals' }
    return [pscustomobject][ordered]@{
      section = $Section
      found = [bool]($scope.found -and $nonGoals.found)
      non_shallow = [bool]($scope.non_shallow -and $nonGoals.non_shallow)
      missing_signals = @($missingSignals.ToArray())
      shallow_signals = @($shallowSignals.ToArray())
    }
  }

  $users = Get-DeliveryContractExplicitSignalState -Contract $Contract -Names @('users','Users','roles','Roles','personas','Personas','actors','Actors')
  return [pscustomobject][ordered]@{
    section = $Section
    found = [bool]$users.found
    non_shallow = [bool]$users.non_shallow
    missing_signals = $(if ($users.found) { @() } else { @('users/roles/personas/actors') })
    shallow_signals = $(if ($users.found -and -not $users.non_shallow) { @('users/roles/personas/actors') } else { @() })
  }
}

function Test-DeliveryContractEmpty {
  param($Contract)
  if ($null -eq $Contract) { return $true }
  if ($Contract -is [hashtable]) { return ($Contract.Count -eq 0) }
  if ($Contract -is [System.Collections.IDictionary]) { return ($Contract.Count -eq 0) }
  $props = @($Contract.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty') })
  return ($props.Count -eq 0)
}

function Get-DeliveryContractPenalty {
  param(
    [Parameter(Mandatory)][string]$Section,
    [Parameter(Mandatory)][ValidateSet('missing','shallow')][string]$Kind
  )

  switch ($Kind + ':' + $Section) {
    'missing:acceptance_scenarios' { return 32 }
    'shallow:acceptance_scenarios' { return 24 }
    'missing:checks' { return 20 }
    'shallow:checks' { return 22 }
    'missing:surfaces/routes/screens' { return 14 }
    'shallow:surfaces/routes/screens' { return 12 }
    'missing:critical_paths' { return 18 }
    'shallow:critical_paths' { return 16 }
    'missing:canary' { return 18 }
    'shallow:canary' { return 16 }
    'missing:parallel_policy' { return 6 }
    'shallow:parallel_policy' { return 4 }
    default {
      if ($Kind -eq 'missing') { return 10 }
      return 8
    }
  }
}

function New-DeliveryContractResult {
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][int]$Score,
    [string[]]$Missing = @(),
    [string[]]$Warnings = @(),
    [string[]]$Blockers = @(),
    [string[]]$RequiredSections = @()
  )

  if ($Score -lt 0 -or $Score -gt 100) { throw "Delivery contract score out of range: $Score" }
  foreach ($entry in @(
      @{ Name = 'missing'; Value = $Missing },
      @{ Name = 'warnings'; Value = $Warnings },
      @{ Name = 'blockers'; Value = $Blockers },
      @{ Name = 'required_sections'; Value = $RequiredSections }
    )) {
    if ($null -eq $entry.Value) { continue }
    foreach ($item in @($entry.Value)) {
      if ($item -isnot [string]) { throw "Delivery contract $($entry.Name) must contain only strings" }
    }
  }

  return [pscustomobject][ordered]@{
    ok                = $Ok
    score             = $Score
    missing           = @($Missing)
    warnings          = @($Warnings)
    blockers          = @($Blockers)
    required_sections = @($RequiredSections)
  }
}

function Test-DeliveryContract {
  param(
    $Contract,
    $Context = $null
  )

  if (Test-DeliveryContractEmpty -Contract $Contract) {
    return New-DeliveryContractResult `
      -Ok $false `
      -Score 0 `
      -Missing @() `
      -Warnings @() `
      -Blockers @('empty_contract') `
      -RequiredSections @($script:DeliveryContractRequiredSectionEnum)
  }

  $score = 100
  $missing = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $blockers = New-Object 'System.Collections.Generic.List[string]'
  $requiredSections = New-Object 'System.Collections.Generic.List[string]'

  foreach ($section in $script:DeliveryContractRequiredSectionEnum) {
    Add-DeliveryContractListItem -List $requiredSections -Value $section
  }

  $states = @{}
  foreach ($section in @($script:DeliveryContractRequiredSectionEnum + $script:DeliveryContractBridgeSelfSectionEnum)) {
    $states[$section] = Get-DeliveryContractSectionState -Contract $Contract -Section $section
  }

  $bridgeSelfSignal = (
    Test-DeliveryContractTruthy (Get-DeliveryContractValue -Object $Context -Names @('IsBridgeSelf','isBridgeSelf','bridge_self','BridgeSelf'))
  ) -or $states['critical_paths'].found -or $states['canary'].found
  $requireParallelPolicy = Test-DeliveryContractTruthy (Get-DeliveryContractValue -Object $Context -Names @('RequireParallelPolicy','require_parallel_policy','RequireParallel','requireParallel'))
  $requireExplicitProjectSections = Test-DeliveryContractTruthy (Get-DeliveryContractValue -Object $Context -Names @('RequireExplicitProjectSections','require_explicit_project_sections','RequireExplicitSections','requireExplicitSections'))

  $bridgeSelfRouteOmission = ($bridgeSelfSignal -and -not $states['surfaces/routes/screens'].found)
  if ($bridgeSelfRouteOmission) {
    foreach ($section in $script:DeliveryContractBridgeSelfSectionEnum) {
      Add-DeliveryContractListItem -List $requiredSections -Value $section
    }
  }

  $fatalMissing = $false
  $bridgeSelfStrictFailure = $false

  foreach ($section in @('goal','scope/non_goals','users/roles','data/backend','acceptance_scenarios','checks','risk','parallel_policy')) {
    $state = $states[$section]
    if (-not $state.found) {
      Add-DeliveryContractListItem -List $missing -Value $section
      $score -= Get-DeliveryContractPenalty -Section $section -Kind 'missing'
      if ($section -eq 'acceptance_scenarios') {
        Add-DeliveryContractListItem -List $blockers -Value 'acceptance_scenarios'
      } elseif ($section -eq 'parallel_policy') {
        Add-DeliveryContractListItem -List $warnings -Value 'soft_missing:parallel_policy'
        if ($requireParallelPolicy) {
          Add-DeliveryContractListItem -List $blockers -Value 'parallel_policy'
        }
      } else {
        $fatalMissing = $true
      }
      continue
    }

    if ($state.shallow) {
      Add-DeliveryContractListItem -List $warnings -Value ('shallow:' + $section)
      $score -= Get-DeliveryContractPenalty -Section $section -Kind 'shallow'
      if ($requireParallelPolicy -and $section -eq 'parallel_policy') {
        Add-DeliveryContractListItem -List $blockers -Value 'parallel_policy'
      }
      if ($bridgeSelfRouteOmission -and $section -eq 'checks') { $bridgeSelfStrictFailure = $true }
    }
  }

  if ($requireExplicitProjectSections) {
    $explicitScope = Get-DeliveryContractExplicitProjectSectionState -Contract $Contract -Section 'scope/non_goals'
    if (-not $explicitScope.found) {
      Add-DeliveryContractListItem -List $missing -Value 'scope/non_goals'
      Add-DeliveryContractListItem -List $blockers -Value 'scope/non_goals'
      Add-DeliveryContractListItem -List $warnings -Value ('explicit_missing:scope/non_goals requires explicit scope and non_goals; requirements/capabilities/features do not count')
      $score -= Get-DeliveryContractPenalty -Section 'scope/non_goals' -Kind 'missing'
    } elseif (-not $explicitScope.non_shallow) {
      Add-DeliveryContractListItem -List $blockers -Value 'scope/non_goals'
      Add-DeliveryContractListItem -List $warnings -Value ('explicit_shallow:scope/non_goals requires non-shallow scope and non_goals')
      $score -= Get-DeliveryContractPenalty -Section 'scope/non_goals' -Kind 'shallow'
    }

    $explicitUsers = Get-DeliveryContractExplicitProjectSectionState -Contract $Contract -Section 'users/roles'
    if (-not $explicitUsers.found) {
      Add-DeliveryContractListItem -List $missing -Value 'users/roles'
      Add-DeliveryContractListItem -List $blockers -Value 'users/roles'
      Add-DeliveryContractListItem -List $warnings -Value ('explicit_missing:users/roles requires explicit users, roles, personas, or actors; user_journeys/journeys/flows/workflows do not count')
      $score -= Get-DeliveryContractPenalty -Section 'users/roles' -Kind 'missing'
    } elseif (-not $explicitUsers.non_shallow) {
      Add-DeliveryContractListItem -List $blockers -Value 'users/roles'
      Add-DeliveryContractListItem -List $warnings -Value ('explicit_shallow:users/roles requires non-shallow users, roles, personas, or actors')
      $score -= Get-DeliveryContractPenalty -Section 'users/roles' -Kind 'shallow'
    }
  }

  $surfaceState = $states['surfaces/routes/screens']
  if ($bridgeSelfRouteOmission) {
    foreach ($section in @('critical_paths','canary')) {
      $state = $states[$section]
      if (-not $state.found) {
        Add-DeliveryContractListItem -List $missing -Value $section
        Add-DeliveryContractListItem -List $blockers -Value $section
        $score -= Get-DeliveryContractPenalty -Section $section -Kind 'missing'
        $fatalMissing = $true
        $bridgeSelfStrictFailure = $true
        continue
      }

      if ($state.shallow) {
        Add-DeliveryContractListItem -List $warnings -Value ('shallow:' + $section)
        $score -= Get-DeliveryContractPenalty -Section $section -Kind 'shallow'
        $bridgeSelfStrictFailure = $true
      }
    }
  } else {
    if (-not $surfaceState.found) {
      Add-DeliveryContractListItem -List $missing -Value 'surfaces/routes/screens'
      $score -= Get-DeliveryContractPenalty -Section 'surfaces/routes/screens' -Kind 'missing'
      $fatalMissing = $true
    } elseif ($surfaceState.shallow) {
      Add-DeliveryContractListItem -List $warnings -Value 'shallow:surfaces/routes/screens'
      $score -= Get-DeliveryContractPenalty -Section 'surfaces/routes/screens' -Kind 'shallow'
    }
  }

  if ($score -lt 0) { $score = 0 }

  $ok = ($blockers.Count -eq 0 -and -not $fatalMissing -and -not $bridgeSelfStrictFailure -and $score -ge 80)

  return New-DeliveryContractResult `
    -Ok $ok `
    -Score $score `
    -Missing @($missing.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -Blockers @($blockers.ToArray()) `
    -RequiredSections @($requiredSections.ToArray())
}
