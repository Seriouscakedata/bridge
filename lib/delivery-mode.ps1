# delivery-mode.ps1 -- pure read-only task delivery mode classifier.
#
# This file is intentionally isolated from the live driver. It does not write
# files, mutate runtime state, call models/APIs, or authorize execution. It only
# turns task facts into a deterministic routing object for tests and future
# shadow integration.

$script:DeliveryModeEnum = @(
  'tiny',
  'small',
  'medium',
  'large',
  'critical_bridge_self',
  'external_project',
  'audit_backlog',
  'blocked'
)

$script:DeliveryRiskEnum = @('low','normal','high','critical')

$script:DeliveryFlowEnum = @(
  'fast_atom',
  'normal_atom',
  'mini_contract',
  'full_project_contract',
  'bridge_self_canary',
  'audit_pack',
  'blocked'
)

$script:DeliveryParallelPolicyEnum = @('not_needed','evaluate','required','forbidden')

$script:DeliverySerialReasonEnum = @(
  '',
  'foundation',
  'integration',
  'shared_file',
  'shared_schema',
  'critical_bridge_self',
  'active_claim_conflict',
  'readiness_red',
  'dirty_repo',
  'worker_capacity',
  'previous_parallel_conflict',
  'acceptance_release'
)

function Get-DeliveryModeSchema {
  return [ordered]@{
    mode              = ($script:DeliveryModeEnum -join '|')
    risk              = ($script:DeliveryRiskEnum -join '|')
    flow              = ($script:DeliveryFlowEnum -join '|')
    requires_contract = 'bool'
    parallel_policy   = ($script:DeliveryParallelPolicyEnum -join '|')
    needs_operator    = 'bool'
    reason            = 'short string'
    serial_reason     = ($script:DeliverySerialReasonEnum -join '|')
    checks            = 'string[]'
  }
}

function Normalize-DeliveryPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $p = ([string]$Path).Trim().Trim('"').Trim("'") -replace '\\','/'
  $p = $p -replace '^[A-Za-z]:/Users/[^/]+/OneDrive/Documents/bridge/',''
  $p = $p -replace '^\./',''
  while ($p.StartsWith('/')) { $p = $p.Substring(1) }
  return $p.ToLowerInvariant()
}

function Get-DeliveryFactValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) { return $null }
  foreach ($name in $Names) {
    if ($Object -is [hashtable] -and $Object.ContainsKey($name)) { return $Object[$name] }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) { return $prop.Value }
  }
  return $null
}

function Test-DeliveryTruthy {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [string]) {
    return (@('1','true','yes','y','on') -contains $Value.Trim().ToLowerInvariant())
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return ([double]$Value -ne 0) }
  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) { return $true }
    }
  }
  return $false
}

function Test-DeliveryActiveClaimConflict {
  param($ChannelFacts, $Context)
  $names = @(
    'active_claim_conflict',
    'ActiveClaimConflict',
    'HasActiveClaimConflict',
    'ClaimConflict',
    'ConflictWithActiveClaim'
  )
  foreach ($source in @($Context, $ChannelFacts)) {
    if (Test-DeliveryTruthy (Get-DeliveryFactValue -Object $source -Names $names)) { return $true }
    if (Test-DeliveryTruthy (Get-DeliveryFactValue -Object $source -Names @('conflicts','Conflicts','claim_conflicts','ClaimConflicts'))) { return $true }
  }
  return $false
}

function Test-DeliveryCriticalBridgePath {
  param([string]$Path)
  $p = Normalize-DeliveryPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }

  if ($p -match '^driver/(30|81|84|86)-[^/]*\.ps1$') { return $true }
  if (@(
      'lib/memory.ps1',
      'lib/project-context.ps1',
      'lib/backlog.ps1',
      'lib/parallel.ps1',
      'lib/decision-contract.ps1',
      'lib/circuit-breaker.ps1',
      'server.ps1',
      'supervisor.ps1',
      'watchdog.ps1',
      'config.json'
    ) -contains $p) { return $true }
  if ($p -match '^(config|settings|security)(/|$)') { return $true }
  if ($p -match '(^|/)(settings|security)\.(json|ps1|yaml|yml|toml)$') { return $true }

  return $false
}

function Test-DeliveryExternalProject {
  param($ChannelFacts)
  if ($null -eq $ChannelFacts) { return $false }
  if (Test-DeliveryTruthy (Get-DeliveryFactValue -Object $ChannelFacts -Names @('IsExternalProject','ExternalProject','external_project'))) { return $true }
  $kind = [string](Get-DeliveryFactValue -Object $ChannelFacts -Names @('ChannelType','ProjectType','Kind','type'))
  if ($kind.Trim().ToLowerInvariant() -in @('external','external_project','project')) { return $true }
  $channel = [string](Get-DeliveryFactValue -Object $ChannelFacts -Names @('Channel','channel','Name','name'))
  if (-not [string]::IsNullOrWhiteSpace($channel) -and $channel.Trim().ToLowerInvariant() -ne 'main') { return $true }
  return $false
}

function Test-DeliveryReadOnlyTiny {
  param([string]$TaskText, [string[]]$Files)
  $text = if ($null -eq $TaskText) { '' } else { $TaskText.Trim().ToLowerInvariant() }
  if ([string]::IsNullOrWhiteSpace($text)) { return $true }

  $hasWriteVerb = ($text -match '(?i)(add|create|edit|change|fix|implement|delete|remove|write|commit|touch|modify|update|refactor|добав|созда|измени|исправ|реализ|удали|запиши|закоммит|правк)')
  $hasReadSignal = ($text -match '(?i)(read-only|readonly|question|explain|show|inspect|look|status|what|why|how|покажи|объясн|вопрос|статус|прочитай|посмотри|что|почему|как)')
  $fileCount = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

  if ($hasWriteVerb) { return $false }
  if ($hasReadSignal -and $fileCount -le 1) { return $true }
  if ($text.Length -le 80 -and $fileCount -eq 0 -and -not $hasWriteVerb) { return $true }
  return $false
}

function Test-DeliveryAuditBacklog {
  param([string]$TaskText, $Context)
  if (Test-DeliveryTruthy (Get-DeliveryFactValue -Object $Context -Names @('AuditBacklog','IsAuditBacklog','audit_backlog'))) { return $true }
  $kind = [string](Get-DeliveryFactValue -Object $Context -Names @('Kind','kind','TaskKind','task_kind'))
  if ($kind.Trim().ToLowerInvariant() -in @('audit','audit_backlog','finding_batch','findings')) { return $true }
  $text = if ($null -eq $TaskText) { '' } else { $TaskText.ToLowerInvariant() }
  # 2026-06-06 (operator hotfix): removed backlog|workpack|бэклог — the driver wraps EVERY autonomous
  # task with "[Автозадача из бэклога]" / "[Автозадача из workpack-batch]", so these words matched on
  # EVERY coding atom, misrouting it to audit_pack flow (analysis, not implementation) → false-green
  # done with zero code. Real audit tasks still match via audit|finding|auditor + Context Kind flag.
  return ($text -match '(?i)\b(audit|auditor|finding|findings)\b' -or $text -match '(?i)(аудит|находк)')
}

function Get-DeliveryFileGroups {
  param([string[]]$Files)
  $groups = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($file in @($Files)) {
    $p = Normalize-DeliveryPath -Path $file
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $parts = $p.Split('/')
    $group = if ($parts.Count -ge 2) { $parts[0] } else { ('root:' + $parts[0]) }
    [void]$groups.Add($group)
  }
  return @($groups)
}

function Get-DeliveryIndependentGroupCount {
  param([string[]]$Files, $Context)
  $explicit = Get-DeliveryFactValue -Object $Context -Names @('IndependentGroups','independent_groups','ParallelGroups','parallel_groups')
  if ($explicit -is [int] -or $explicit -is [long]) { return [int]$explicit }
  if ($explicit -is [System.Collections.IEnumerable] -and $explicit -isnot [string]) {
    $count = 0
    foreach ($item in $explicit) { if ($null -ne $item) { $count++ } }
    if ($count -gt 0) { return $count }
  }
  return @(Get-DeliveryFileGroups -Files $Files).Count
}

function New-DeliveryModeDecision {
  param(
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$Risk,
    [Parameter(Mandatory)][string]$Flow,
    [Parameter(Mandatory)][bool]$RequiresContract,
    [Parameter(Mandatory)][string]$ParallelPolicy,
    [Parameter(Mandatory)][bool]$NeedsOperator,
    [Parameter(Mandatory)][string]$Reason,
    [string]$SerialReason = '',
    [string[]]$Checks = @()
  )

  if ($script:DeliveryModeEnum -notcontains $Mode) { throw "Invalid delivery mode: $Mode" }
  if ($script:DeliveryRiskEnum -notcontains $Risk) { throw "Invalid delivery risk: $Risk" }
  if ($script:DeliveryFlowEnum -notcontains $Flow) { throw "Invalid delivery flow: $Flow" }
  if ($script:DeliveryParallelPolicyEnum -notcontains $ParallelPolicy) { throw "Invalid delivery parallel policy: $ParallelPolicy" }
  if ($script:DeliverySerialReasonEnum -notcontains $SerialReason) { throw "Invalid delivery serial reason: $SerialReason" }

  return [pscustomobject][ordered]@{
    mode              = $Mode
    risk              = $Risk
    flow              = $Flow
    requires_contract = $RequiresContract
    parallel_policy   = $ParallelPolicy
    needs_operator    = $NeedsOperator
    reason            = $Reason
    serial_reason     = $SerialReason
    checks            = @($Checks)
  }
}

function Get-DeliveryModeDecision {
  param(
    [string]$TaskText = '',
    $ChannelFacts = $null,
    [string[]]$TouchedFiles = @(),
    $Context = $null
  )

  $files = @($TouchedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $fileCount = $files.Count
  $groupCount = Get-DeliveryIndependentGroupCount -Files $files -Context $Context
  $text = if ($null -eq $TaskText) { '' } else { [string]$TaskText }
  $lower = $text.ToLowerInvariant()

  if (Test-DeliveryActiveClaimConflict -ChannelFacts $ChannelFacts -Context $Context) {
    return New-DeliveryModeDecision `
      -Mode 'blocked' `
      -Risk 'high' `
      -Flow 'blocked' `
      -RequiresContract $false `
      -ParallelPolicy 'forbidden' `
      -NeedsOperator $true `
      -Reason 'active claim conflict' `
      -SerialReason 'active_claim_conflict' `
      -Checks @('resolve_active_claim')
  }

  if (Test-DeliveryReadOnlyTiny -TaskText $text -Files $files) {
    return New-DeliveryModeDecision `
      -Mode 'tiny' `
      -Risk 'low' `
      -Flow 'fast_atom' `
      -RequiresContract $false `
      -ParallelPolicy 'not_needed' `
      -NeedsOperator $false `
      -Reason 'tiny read-only task' `
      -Checks @()
  }

  $criticalFiles = @($files | Where-Object { Test-DeliveryCriticalBridgePath -Path $_ })
  if ($criticalFiles.Count -gt 0) {
    return New-DeliveryModeDecision `
      -Mode 'critical_bridge_self' `
      -Risk 'critical' `
      -Flow 'bridge_self_canary' `
      -RequiresContract $true `
      -ParallelPolicy 'forbidden' `
      -NeedsOperator $false `
      -Reason 'critical bridge-self path' `
      -SerialReason 'critical_bridge_self' `
      -Checks @('parser_parsefile','targeted_test','smoke','bridge_self_canary')
  }

  if (Test-DeliveryAuditBacklog -TaskText $text -Context $Context) {
    $policy = if ($groupCount -ge 3 -or $fileCount -ge 3) { 'evaluate' } else { 'not_needed' }
    return New-DeliveryModeDecision `
      -Mode 'audit_backlog' `
      -Risk 'normal' `
      -Flow 'audit_pack' `
      -RequiresContract $false `
      -ParallelPolicy $policy `
      -NeedsOperator $false `
      -Reason 'audit backlog task' `
      -Checks @('dedupe_findings','scope_atoms')
  }

  if (Test-DeliveryExternalProject -ChannelFacts $ChannelFacts) {
    $policy = if ($groupCount -ge 3 -or $fileCount -ge 5) { 'required' } else { 'evaluate' }
    return New-DeliveryModeDecision `
      -Mode 'external_project' `
      -Risk 'normal' `
      -Flow 'full_project_contract' `
      -RequiresContract $true `
      -ParallelPolicy $policy `
      -NeedsOperator $false `
      -Reason 'external project delivery' `
      -Checks @('project_contract','repo_checks','acceptance')
  }

  $largeText = ($lower -match '(?i)(full project|project contract|chapter|phase|large|operatorless|end-to-end|e2e|new feature pack|проект|глава|фаза|крупн)')
  $mediumText = ($lower -match '(?i)(multiple|several|fixture|schema|classifier|medium|нескольк|схем|классификатор)')

  if ($largeText -or $fileCount -ge 6) {
    $policy = if ($groupCount -ge 3 -or $fileCount -ge 6) { 'required' } else { 'evaluate' }
    return New-DeliveryModeDecision `
      -Mode 'large' `
      -Risk 'high' `
      -Flow 'full_project_contract' `
      -RequiresContract $true `
      -ParallelPolicy $policy `
      -NeedsOperator $false `
      -Reason 'large scoped task' `
      -Checks @('project_contract','decomposition','acceptance')
  }

  if ($mediumText -or $fileCount -ge 3 -or $groupCount -ge 3) {
    $policy = if ($groupCount -ge 3 -or $fileCount -ge 3) { 'evaluate' } else { 'not_needed' }
    return New-DeliveryModeDecision `
      -Mode 'medium' `
      -Risk 'normal' `
      -Flow 'mini_contract' `
      -RequiresContract $true `
      -ParallelPolicy $policy `
      -NeedsOperator $false `
      -Reason 'medium multi-file task' `
      -Checks @('mini_contract','targeted_tests')
  }

  return New-DeliveryModeDecision `
    -Mode 'small' `
    -Risk 'low' `
    -Flow 'normal_atom' `
    -RequiresContract $false `
    -ParallelPolicy 'not_needed' `
    -NeedsOperator $false `
    -Reason 'small atom task' `
    -Checks @('targeted_check')
}
