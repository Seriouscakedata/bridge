#Requires -Version 5.1
# test-claimability-deadlock.ps1 -- control-plane-only approved backlog deadlock is canary-gated then held.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:TestRoot = Join-Path $repoRoot ('tmp\claimability-deadlock-' + [guid]::NewGuid().ToString('N'))

function Get-BridgeRoot { return $script:TestRoot }
function Get-EffectiveChannel { return 'main' }
function Get-EffectiveScope { return [pscustomobject]@{ is_bridge = $true; project_root = '' } }
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  $dir = Join-Path $script:TestRoot 'channels\main'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return (Join-Path $dir 'backlog.jsonl')
}
function Use-BridgeLock {
  param([scriptblock]$ScriptBlock)
  return (& $ScriptBlock)
}
function Update-State {
  param([scriptblock]$Mutator)
  if (-not $script:State) { $script:State = [pscustomobject]@{} }
  & $Mutator $script:State
  return $script:State
}

. (Join-Path $repoRoot 'lib\backlog.ps1')

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

try {
  New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'channels\main') -Force | Out-Null
  $parent = [pscustomobject][ordered]@{
    id = 'deadlock-parent'
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = 'test'
    status = 'approved'
    tags = @('control-plane')
    attempts = 0
    score = 0
    project = 'main'
    scope = 'bridge'
    text = 'Modify driver.ps1 control-plane logic.'
  }
  Save-Backlog @($parent)

  $report = Get-ApprovedBacklogClaimabilityReport
  Check 'pure detector recognizes control-plane-only deadlock' (Test-ApprovedBacklogClaimabilityDeadlock -Claimability $report) $report

  $prematureAdmission = Invoke-BacklogClaimabilityDeadlockAdmission -Claimability $report -Channel 'main'
  $prematureParent = @((Get-Backlog) | Where-Object { [string]$_.id -eq 'deadlock-parent' })[0]
  Check 'deadlock admission refuses hold before canary child exists' (([bool]$prematureAdmission.deadlock) -and [int]$prematureAdmission.held_count -eq 0 -and [string]$prematureAdmission.reason -eq 'missing-canary-gate' -and [string]$prematureParent.status -eq 'approved') $prematureAdmission

  $gate = Ensure-BridgeSelfCanaryGateTasks -ParentIds @('deadlock-parent') -Channel 'main'
  Check 'canary child is created before hold' ([int]$gate.created_count -eq 1) $gate

  $admission = Invoke-BacklogClaimabilityDeadlockAdmission -Claimability $report -Channel 'main'
  Check 'deadlock admission holds exactly one parent' ([bool]$admission.deadlock -and [int]$admission.held_count -eq 1 -and @($admission.held_ids) -contains 'deadlock-parent') $admission

  $items = @(Get-Backlog)
  $heldParent = @($items | Where-Object { [string]$_.id -eq 'deadlock-parent' })[0]
  $children = @($items | Where-Object { @($_.tags) -contains 'bridge-self-canary-gate' })
  Check 'parent moved approved to held' ([string]$heldParent.status -eq 'held' -and [string]$heldParent.held_by -eq 'claimability-deadlock' -and [bool]$heldParent.canary_gate_required) $heldParent
  Check 'operator canary child remains approved and runnable' ($children.Count -eq 1 -and [string]$children[0].status -eq 'approved' -and @($children[0].tags) -contains 'operator') $children

  $afterReport = Get-ApprovedBacklogClaimabilityReport
  Check 'held parent is removed from approved deadlock set' ([int]$afterReport.approved_count -eq 1 -and @($afterReport.runnable_ids) -contains [string]$children[0].id) $afterReport

  Save-Backlog @([pscustomobject][ordered]@{
    id = 'project-blocked'
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = 'test'
    status = 'approved'
    tags = @()
    attempts = 0
    score = 0
    project = 'external-project'
    scope = 'project'
    text = 'Project scoped task.'
  })
  $mixedReport = Get-ApprovedBacklogClaimabilityReport
  Check 'detector rejects non-control-plane-only blocked set' (-not (Test-ApprovedBacklogClaimabilityDeadlock -Claimability $mixedReport)) $mixedReport

  $manyParents = @()
  for ($i = 1; $i -le 10; $i++) {
    $manyParents += [pscustomobject][ordered]@{
      id = ('deadlock-parent-' + $i)
      ts = (Get-Date).ToUniversalTime().ToString('o')
      from = 'test'
      status = 'approved'
      tags = @('control-plane')
      attempts = 0
      score = 0
      project = 'main'
      scope = 'bridge'
      text = 'Modify bridge control-plane logic.'
    }
  }
  Save-Backlog $manyParents
  $manyReport = Get-ApprovedBacklogClaimabilityReport
  $manyIds = @($manyReport.control_plane_all_ids)
  Check 'report exposes all control-plane ids for deadlock admission' ($manyIds.Count -eq 10 -and @($manyIds) -contains 'deadlock-parent-10') $manyReport
  $manyGate = Ensure-BridgeSelfCanaryGateTasks -ParentIds $manyIds -Channel 'main'
  Check 'canary gate is created for every control-plane parent' ([int]$manyGate.created_count -eq 10) $manyGate
  $manyAdmission = Invoke-BacklogClaimabilityDeadlockAdmission -Claimability $manyReport -Channel 'main'
  $manyHeld = @((Get-Backlog) | Where-Object { [string]$_.status -eq 'held' -and [string]$_.held_by -eq 'claimability-deadlock' })
  Check 'deadlock admission holds all parents beyond display sample' ([int]$manyAdmission.held_count -eq 10 -and $manyHeld.Count -eq 10 -and @($manyAdmission.held_ids) -contains 'deadlock-parent-10') $manyAdmission
} finally {
  if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
