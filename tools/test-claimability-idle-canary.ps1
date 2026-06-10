#Requires -Version 5.1
# test-claimability-idle-canary.ps1 -- idle claimability state, canary child dedup, force-reflect trigger.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:TestRoot = Join-Path $repoRoot ('tmp\claimability-idle-canary-' + [guid]::NewGuid().ToString('N'))
$script:State = [pscustomobject]@{
  status = 'idle'
  lastSeq = 0
  paused = $false
  stop = $false
  abort = $false
  heartbeat = $null
}

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
    id = 'parent-control-plane'
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = 'test'
    status = 'approved'
    tags = @('control-plane')
    attempts = 0
    score = 0
    project = 'main'
    scope = 'bridge'
    text = 'Modify driver.ps1 idle claimability loop.'
  }
  Save-Backlog @($parent)

  $report = Get-ApprovedBacklogClaimabilityReport
  Check 'synthetic report approved=1' ([int]$report.approved_count -eq 1) $report
  Check 'synthetic report runnable=0' ([int]$report.runnable_count -eq 0) $report
  Check 'synthetic report control_plane_blocked=1' ([int]$report.control_plane_blocked -eq 1) $report

  $sig = Get-BacklogClaimabilitySignature -Claimability $report -Channel 'main'
  $transition = $null
  for ($i = 1; $i -le 4; $i++) {
    $transition = Update-BacklogClaimabilityIdleState -Claimability $report -Channel 'main' -Signature $sig -BackoffSeconds 300 -ForceReflectAfter 3
  }
  Check 'state lastIdleCheck set' (-not [string]::IsNullOrWhiteSpace([string]$script:State.lastIdleCheck)) $script:State
  Check 'state idleClaimabilityStreak is 4' ([int]$script:State.idleClaimabilityStreak -eq 4) $script:State
  Check 'state backoff records 300-second mode' ([string]$script:State.idleClaimabilityBackoffUntil -match '^\d{4}-' -and [int]$transition.backoff_seconds -eq 300) $transition
  Check 'streak over threshold marks forced reflect path due' ([bool]$transition.forced_reflect_due -and -not [string]::IsNullOrWhiteSpace([string]$script:State.lastIdleForcedReflectAt)) $transition
  $cooldownTransition = Update-BacklogClaimabilityIdleState -Claimability $report -Channel 'main' -Signature $sig -BackoffSeconds 300 -ForceReflectAfter 3
  Check 'forced reflect path is cooldown-throttled' ((-not [bool]$cooldownTransition.forced_reflect_due) -and [int]$script:State.idleClaimabilityStreak -eq 5) $cooldownTransition

  $gate1 = Ensure-BridgeSelfCanaryGateTasks -ParentIds @('parent-control-plane') -Channel 'main'
  $itemsAfterFirst = @(Get-Backlog)
  $childrenAfterFirst = @($itemsAfterFirst | Where-Object { @($_.tags) -contains 'bridge-self-canary-gate' })
  Check 'canary gate child created once' ([int]$gate1.created_count -eq 1 -and $childrenAfterFirst.Count -eq 1) $gate1
  Check 'canary gate child has operator tag' (@($childrenAfterFirst[0].tags) -contains 'operator') $childrenAfterFirst[0]
  Check 'canary gate child has parent relation' ([string]$childrenAfterFirst[0].parent_id -eq 'parent-control-plane' -and [string]$childrenAfterFirst[0].canary_gate_parent_id -eq 'parent-control-plane') $childrenAfterFirst[0]

  $gate2 = Ensure-BridgeSelfCanaryGateTasks -ParentIds @('parent-control-plane') -Channel 'main'
  $childrenAfterSecond = @((Get-Backlog) | Where-Object { @($_.tags) -contains 'bridge-self-canary-gate' })
  Check 'canary gate child not duplicated' ([int]$gate2.created_count -eq 0 -and [int]$gate2.existing_count -eq 1 -and $childrenAfterSecond.Count -eq 1) $gate2

  $reportWithChild = Get-ApprovedBacklogClaimabilityReport
  Check 'operator child is runnable' (@($reportWithChild.runnable_ids) -contains [string]$childrenAfterSecond[0].id) $reportWithChild

  Update-BacklogClaimabilityIdleState -Claimability $null -Channel 'main' | Out-Null
  Check 'idle state resets when runnable work appears' ([int]$script:State.idleClaimabilityStreak -eq 0 -and [string]::IsNullOrWhiteSpace([string]$script:State.idleClaimabilitySignature)) $script:State
} finally {
  if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
