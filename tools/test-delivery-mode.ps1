#Requires -Version 5.1
# test-delivery-mode.ps1 -- fixtures for the isolated Delivery Mode classifier.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\delivery-mode.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Check-DecisionShape {
  param([string]$Name, $Decision)
  $schema = Get-DeliveryModeSchema
  foreach ($key in $schema.Keys) {
    Check "$Name has $key" ($null -ne $Decision.PSObject.Properties[$key]) $Decision
  }
  Check "$Name checks is array" ($Decision.checks -is [array]) $Decision
}

function Check-Decision {
  param(
    [string]$Name,
    $Decision,
    [string]$Mode,
    [string]$Flow,
    [string]$ParallelPolicy,
    [Nullable[bool]]$RequiresContract = $null,
    [Nullable[bool]]$NeedsOperator = $null,
    [string]$SerialReason = $null
  )
  Check-DecisionShape $Name $Decision
  Check "$Name mode" ([string]$Decision.mode -eq $Mode) $Decision
  Check "$Name flow" ([string]$Decision.flow -eq $Flow) $Decision
  Check "$Name parallel_policy" ([string]$Decision.parallel_policy -eq $ParallelPolicy) $Decision
  if ($null -ne $RequiresContract) { Check "$Name requires_contract" ([bool]$Decision.requires_contract -eq [bool]$RequiresContract) $Decision }
  if ($null -ne $NeedsOperator) { Check "$Name needs_operator" ([bool]$Decision.needs_operator -eq [bool]$NeedsOperator) $Decision }
  if ($null -ne $SerialReason) { Check "$Name serial_reason" ([string]$Decision.serial_reason -eq $SerialReason) $Decision }
}

$tiny = Get-DeliveryModeDecision `
  -TaskText 'What does this task mean? Read-only question.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @()
Check-Decision 'tiny read-only question' $tiny 'tiny' 'fast_atom' 'not_needed' $false $false ''
Check 'tiny risk low' ([string]$tiny.risk -eq 'low') $tiny

$doc = Get-DeliveryModeDecision `
  -TaskText 'Update one docs page with a short note.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('docs/operatorless.md')
Check-Decision 'one-file doc edit' $doc 'small' 'normal_atom' 'not_needed' $false $false ''
Check 'one-file doc risk low' ([string]$doc.risk -eq 'low') $doc

$medium = Get-DeliveryModeDecision `
  -TaskText 'Implement classifier fixtures across independent files.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('lib/new-router.ps1','tools/test-new-router.ps1','docs/new-router.md')
Check-Decision 'three independent files' $medium 'medium' 'mini_contract' 'evaluate' $true $false ''
Check 'medium risk normal' ([string]$medium.risk -eq 'normal') $medium

$external = Get-DeliveryModeDecision `
  -TaskText 'Build a new external project feature with UI and API.' `
  -ChannelFacts @{ Channel = 'client-app'; ChannelType = 'external_project'; IsExternalProject = $true } `
  -TouchedFiles @('app/page.tsx','app/api/route.ts','components/widget.tsx')
Check-Decision 'new external project feature' $external 'external_project' 'full_project_contract' 'evaluate' $true $false ''
Check 'external risk normal' ([string]$external.risk -eq 'normal') $external

$criticalDriver = Get-DeliveryModeDecision `
  -TaskText 'Adjust prompt agent state.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('driver/30-prompt-agent-state.ps1')
Check-Decision 'critical driver path' $criticalDriver 'critical_bridge_self' 'bridge_self_canary' 'forbidden' $true $false 'critical_bridge_self'
Check 'critical driver risk critical' ([string]$criticalDriver.risk -eq 'critical') $criticalDriver

$criticalBacklog = Get-DeliveryModeDecision `
  -TaskText 'Change backlog scheduler.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('lib/backlog.ps1')
Check-Decision 'critical backlog path' $criticalBacklog 'critical_bridge_self' 'bridge_self_canary' 'forbidden' $true $false 'critical_bridge_self'

$audit = Get-DeliveryModeDecision `
  -TaskText 'Process audit finding batch into backlog atoms.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('audit/findings.json','docs/audit.md') `
  -Context @{ Kind = 'finding_batch' }
Check-Decision 'audit finding batch' $audit 'audit_backlog' 'audit_pack' 'not_needed' $false $false ''
Check 'audit never full project' ([string]$audit.flow -ne 'full_project_contract') $audit

$blocked = Get-DeliveryModeDecision `
  -TaskText 'Change claimed slimming files.' `
  -ChannelFacts @{ Channel = 'main'; ChannelType = 'bridge' } `
  -TouchedFiles @('lib/intent.ps1') `
  -Context @{ ActiveClaimConflict = $true }
Check-Decision 'active claim conflict' $blocked 'blocked' 'blocked' 'forbidden' $false $true 'active_claim_conflict'
Check 'blocked risk high' ([string]$blocked.risk -eq 'high') $blocked

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
