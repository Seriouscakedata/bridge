#Requires -Version 5.1
# Regression for project-autopilot control-plane claim gating.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script:EffectiveChannel = 'main'

function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-EffectiveScope { return [pscustomobject]@{ is_bridge = $true; project_root = '' } }

. (Join-Path $root 'lib\backlog.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 8) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

$validAdmission = [pscustomobject]@{
  admitted = $true
  mode = 'bridge_self_canary'
  canary_required = $true
  checks = @(
    'powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest',
    'powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1',
    'Invoke-CanaryCycle -Force'
  )
  rollback_plan = 'Revert the atom commit and rerun selftest, smoke, and canary before resuming dependent atoms.'
}

$blockedAtom = [pscustomobject]@{
  id = 'autopilot-cp-no-admission'
  status = 'approved'
  text = '[project-autopilot harden-driver] Harden driver loop.'
  tags = @('project-autopilot','auto-generated','atom','bridge-self')
  scope = 'project'
  files = @('driver.ps1')
}
$blockedClaim = Test-BacklogApprovedItemClaimable -Item $blockedAtom -ProjectScopeAllowed $true
Check 'project-autopilot control-plane atom without admission blocked' ((-not [bool]$blockedClaim.claimable) -and [string]$blockedClaim.reason -eq 'control-plane-blocked') $blockedClaim

$admittedAtom = [pscustomobject]@{
  id = 'autopilot-cp-with-admission'
  status = 'approved'
  text = '[project-autopilot harden-driver] Harden driver loop.'
  tags = @('project-autopilot','auto-generated','atom','bridge-self')
  scope = 'project'
  files = @('driver.ps1')
  bridge_self_admission = $validAdmission
}
$admittedClaim = Test-BacklogApprovedItemClaimable -Item $admittedAtom -ProjectScopeAllowed $true
Check 'project-autopilot control-plane atom with valid admission claimable' ([bool]$admittedClaim.claimable -and [string]$admittedClaim.reason -eq 'bridge-self-admission') $admittedClaim

$projectAtom = [pscustomobject]@{
  id = 'autopilot-non-control'
  status = 'approved'
  text = '[project-autopilot docs] Update project docs.'
  tags = @('project-autopilot','auto-generated','atom')
  scope = 'project'
  files = @('docs/readme.md')
}
$projectClaim = Test-BacklogApprovedItemClaimable -Item $projectAtom -ProjectScopeAllowed $true
Check 'project-autopilot non-control atom stays claimable' ([bool]$projectClaim.claimable) $projectClaim

$coordinator = [pscustomobject]@{
  id = 'autopilot-coordinator'
  status = 'approved'
  text = 'Project Autopilot coordinator: emit atoms and require bridge_self_admission for driver.ps1, server.ps1, supervisor.ps1, watchdog.ps1, and lib/backlog*.ps1.'
  tags = @('project-autopilot','coordinator')
  scope = 'project'
}
$coordinatorClaim = Test-BacklogApprovedItemClaimable -Item $coordinator -ProjectScopeAllowed $true
Check 'project-autopilot coordinator remains claimable despite instructional control-plane text' ([bool]$coordinatorClaim.claimable) $coordinatorClaim

Check 'driver shard path is control-plane' (Test-BridgeControlPlanePath -Path 'driver/81-loop-idle-claim.ps1')
Check 'backlog path is control-plane' (Test-BridgeControlPlanePath -Path 'lib/backlog-core.ps1')
Check 'docs path is not control-plane' (-not (Test-BridgeControlPlanePath -Path 'docs/readme.md'))

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
