# test-backlog-governor.ps1 -- read-only Queue Governor foundation tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog-governor.ps1')

$script:pass = 0
$script:fail = 0

function Assert-BacklogGovernor {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function New-GovernorItem {
  param(
    [string]$Id = 'item-a',
    [string]$Status = 'approved',
    [string]$Title = 'Queue Governor item',
    [string]$Text = 'Implement a focused Queue Governor test item.',
    [object[]]$TouchSet = @('lib/backlog-governor.ps1'),
    [string]$RootCauseKey = 'queue-governor:foundation'
  )
  return [pscustomobject][ordered]@{
    id = $Id
    status = $Status
    title = $Title
    text = $Text
    touch_set = @($TouchSet)
    root_cause_key = $RootCauseKey
  }
}

try {
  $normal = Normalize-BacklogGovernorPath -Path '.\LIB//Backlog-Governor.ps1' -Root $bridgeRoot
  Assert-BacklogGovernor 'path normalization slash and case' ($normal -eq 'lib/backlog-governor.ps1') $normal

  Assert-BacklogGovernor 'directory prefix overlap positive' (
    Test-BacklogGovernorPathOverlap -Left 'lib/foo' -Right 'LIB\foo\bar.ps1' -Root $bridgeRoot
  )
  Assert-BacklogGovernor 'directory prefix overlap negative' (-not (
    Test-BacklogGovernorPathOverlap -Left 'lib/foo' -Right 'lib/foobar.ps1' -Root $bridgeRoot
  ))

  # Invalid = missing IDENTITY under the corrected shape: id + (title|text). touch_set/root_cause_key
  # are intentionally OPTIONAL (b4eec87 — requiring them on intake wedged operator + project-autopilot
  # atoms, since workpack fields are assigned at claim time). So an item is dropped only when it lacks
  # an id, or lacks BOTH title and text -- not merely because it omits workpack metadata.
  $invalidApproved = New-GovernorItem -Id 'invalid-approved'
  $invalidApproved.PSObject.Properties.Remove('title')
  $invalidApproved.PSObject.Properties.Remove('text')
  $approvedVerdict = Test-BacklogGovernorClaimable -Item $invalidApproved
  Assert-BacklogGovernor 'invalid approved is not claimable' (-not [bool]$approvedVerdict.claimable) ($approvedVerdict | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogGovernor 'invalid approved action drop' ([string]$approvedVerdict.action -eq 'drop') $approvedVerdict.action
  Assert-BacklogGovernor 'invalid approved reason' ([string]$approvedVerdict.reason -eq 'invalid-shape') $approvedVerdict.reason

  $invalidRunning = New-GovernorItem -Id 'invalid-running' -Status 'running'
  $invalidRunning.PSObject.Properties.Remove('id')
  $runningVerdict = Test-BacklogGovernorClaimable -Item $invalidRunning
  Assert-BacklogGovernor 'invalid running is not claimable' (-not [bool]$runningVerdict.claimable) ($runningVerdict | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogGovernor 'invalid running action drop' ([string]$runningVerdict.action -eq 'drop') $runningVerdict.action

  # Regression guard for b4eec87: an identity-only item (id + title, NO touch_set / root_cause_key)
  # MUST stay claimable. If this flips to non-claimable again, operator and project-autopilot atoms
  # get wedged as 'invalid-shape' on intake -- the exact regression that broke autonomy before.
  $identityOnly = New-GovernorItem -Id 'identity-only'
  $identityOnly.PSObject.Properties.Remove('touch_set')
  $identityOnly.PSObject.Properties.Remove('root_cause_key')
  $identityVerdict = Test-BacklogGovernorClaimable -Item $identityOnly
  Assert-BacklogGovernor 'identity-only item stays claimable (workpack fields optional)' ([bool]$identityVerdict.claimable) ($identityVerdict | ConvertTo-Json -Compress -Depth 8)

  $scenarioMarker = New-GovernorItem -Id 'scenario-marker' -Text 'Run backlog-flow-123 bridge backlog add list delete verification scenario.' -TouchSet @('lib/foo/bar.ps1') -RootCauseKey 'queue-governor:scenario-marker'
  $markerActive = New-GovernorItem -Id 'scenario-active' -Status 'working' -TouchSet @('LIB\foo') -RootCauseKey 'queue-governor:scenario-other'
  $markerVerdict = Test-BacklogGovernorClaimable -Item $scenarioMarker -ActiveItems @($markerActive)
  Assert-BacklogGovernor 'scenario marker is not claimable' (-not [bool]$markerVerdict.claimable) ($markerVerdict | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogGovernor 'scenario marker action drop' ([string]$markerVerdict.action -eq 'drop') $markerVerdict.action
  Assert-BacklogGovernor 'scenario marker reason' ([string]$markerVerdict.reason -eq 'scenario-marker') $markerVerdict.reason
  Assert-BacklogGovernor 'scenario marker checked before lease conflict' ([string]$markerVerdict.evidence.conflict -eq '' -and @($markerVerdict.evidence.scenario_marker.matches).Count -gt 0) ($markerVerdict | ConvertTo-Json -Compress -Depth 8)

  $incidentSamples = @(
    (New-GovernorItem -Id '1f4053fe' -Text 'backlog-flow-e8061e8f51a0 bridge backlog add list delete verification violet signal quartz canyon lantern ember ribbon orchard' -TouchSet @('backlog') -RootCauseKey 'queue-governor:incident-marker'),
    (New-GovernorItem -Id '2a67959e' -Text 'Functional verifier backlog add flow marker backlog-flow-2a67959e bridge backlog add list delete verification' -TouchSet @('backlog') -RootCauseKey 'queue-governor:incident-marker'),
    (New-GovernorItem -Id '677931e9' -Text 'Temporary browser verifier token backlog-flow-677931e9 bridge backlog add list delete verification' -TouchSet @('backlog') -RootCauseKey 'queue-governor:incident-marker'),
    (New-GovernorItem -Id 'e492b629' -Text 'backlog crud proof marker backlog-flow-e492b629 bridge backlog add list delete verification' -TouchSet @('backlog') -RootCauseKey 'queue-governor:incident-marker')
  )
  foreach ($incidentSample in $incidentSamples) {
    $incidentVerdict = Test-BacklogGovernorClaimable -Item $incidentSample
    Assert-BacklogGovernor ('incident marker ' + [string]$incidentSample.id + ' is not claimable') (-not [bool]$incidentVerdict.claimable -and [string]$incidentVerdict.action -eq 'drop' -and [string]$incidentVerdict.reason -eq 'scenario-marker') ($incidentVerdict | ConvertTo-Json -Compress -Depth 8)
  }

  $hardeningTaskText = 'HARDEN backlog hygiene: feature-verifier scenario markers must NOT enter claimable backlog. Incident evidence mentions backlog-flow-123 and bridge backlog add list delete verification, but this is the real remediation task with deliverables and tests.'
  $hardeningTask = New-GovernorItem -Id 'scenario-hardening-task' -Text $hardeningTaskText -TouchSet @('lib/backlog-governor.ps1') -RootCauseKey 'queue-governor:scenario-hardening'
  $hardeningVerdict = Test-BacklogGovernorClaimable -Item $hardeningTask
  Assert-BacklogGovernor 'hardening task mentioning marker stays claimable' ([bool]$hardeningVerdict.claimable) ($hardeningVerdict | ConvertTo-Json -Compress -Depth 8)

  $candidateTouch = New-GovernorItem -Id 'candidate-touch' -TouchSet @('lib/foo/bar.ps1') -RootCauseKey 'queue-governor:touch'
  $activeTouch = New-GovernorItem -Id 'active-touch' -Status 'working' -TouchSet @('LIB\foo') -RootCauseKey 'queue-governor:other'
  $leaseTouchVerdict = Test-BacklogGovernorClaimable -Item $candidateTouch -ActiveItems @($activeTouch)
  Assert-BacklogGovernor 'active lease blocks overlapping touch_set' (
    -not [bool]$leaseTouchVerdict.claimable -and [string]$leaseTouchVerdict.action -eq 'defer' -and [string]$leaseTouchVerdict.reason -eq 'lease-conflict'
  ) ($leaseTouchVerdict | ConvertTo-Json -Compress -Depth 8)

  $candidateRoot = New-GovernorItem -Id 'candidate-root' -TouchSet @('lib/root-a.ps1') -RootCauseKey 'Queue-Governor:Same-Root'
  $activeRoot = New-GovernorItem -Id 'active-root' -Status 'running' -TouchSet @('lib/root-b.ps1') -RootCauseKey 'queue-governor:same-root'
  $leaseRootVerdict = Test-BacklogGovernorClaimable -Item $candidateRoot -ActiveItems @($activeRoot)
  Assert-BacklogGovernor 'active lease blocks same root_cause_key' (
    -not [bool]$leaseRootVerdict.claimable -and [string]$leaseRootVerdict.reason -eq 'lease-conflict' -and [string]$leaseRootVerdict.evidence.conflict.conflict_on -eq 'root_cause_key'
  ) ($leaseRootVerdict | ConvertTo-Json -Compress -Depth 8)

  $manualTouchLock = [pscustomobject][ordered]@{
    id = 'manual-touch'
    active = $true
    touch_set = @('tools/tests')
    root_cause_key = 'queue-governor:manual-other'
  }
  $manualTouchItem = New-GovernorItem -Id 'manual-touch-item' -TouchSet @('TOOLS\tests\case.ps1') -RootCauseKey 'queue-governor:manual-touch'
  $manualTouchVerdict = Test-BacklogGovernorClaimable -Item $manualTouchItem -ManualLocks @($manualTouchLock)
  Assert-BacklogGovernor 'manual lock blocks overlapping touch_set' (
    -not [bool]$manualTouchVerdict.claimable -and [string]$manualTouchVerdict.action -eq 'defer' -and [string]$manualTouchVerdict.reason -eq 'manual-lock-conflict'
  ) ($manualTouchVerdict | ConvertTo-Json -Compress -Depth 8)

  $manualRootLock = [pscustomobject][ordered]@{
    id = 'manual-root'
    active = $true
    touch_set = @('docs/manual.md')
    root_cause_key = 'queue-governor:manual-root'
  }
  $manualRootItem = New-GovernorItem -Id 'manual-root-item' -TouchSet @('lib/manual-root.ps1') -RootCauseKey 'QUEUE-GOVERNOR:MANUAL-ROOT'
  $manualRootVerdict = Test-BacklogGovernorClaimable -Item $manualRootItem -ManualLocks @($manualRootLock)
  Assert-BacklogGovernor 'manual lock blocks same root_cause_key' (
    -not [bool]$manualRootVerdict.claimable -and [string]$manualRootVerdict.reason -eq 'manual-lock-conflict' -and [string]$manualRootVerdict.evidence.conflict.conflict_on -eq 'root_cause_key'
  ) ($manualRootVerdict | ConvertTo-Json -Compress -Depth 8)

  $valid = New-GovernorItem -Id 'valid-open' -TouchSet @('lib/open.ps1') -RootCauseKey 'queue-governor:open'
  $nonOverlapLease = New-GovernorItem -Id 'active-other' -Status 'working' -TouchSet @('tools/other.ps1') -RootCauseKey 'queue-governor:other'
  $nonOverlapLock = [pscustomobject][ordered]@{ id = 'manual-other'; active = $true; touch_set = @('docs/other.md'); root_cause_key = 'queue-governor:manual-other' }
  $validVerdict = Test-BacklogGovernorClaimable -Item $valid -ActiveItems @($nonOverlapLease) -ManualLocks @($nonOverlapLock)
  Assert-BacklogGovernor 'non-overlapping valid item is claimable' (
    [bool]$validVerdict.claimable -and [string]$validVerdict.action -eq 'allow' -and [string]$validVerdict.reason -eq 'claimable'
  ) ($validVerdict | ConvertTo-Json -Compress -Depth 8)

  $moduleText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\backlog-governor.ps1') -Raw -Encoding UTF8
  $forbiddenTokens = @(
    'Write-BacklogJsonLine',
    'Set-Content',
    'Add-Content',
    'Out-File',
    'New-Item',
    'Remove-Item',
    'Start-Process',
    'Get-NextRunnableIdea',
    'Get-NextApprovedIdea',
    'Get-BacklogWorkpackExecEligibility',
    'driver/81-loop-idle-claim.ps1',
    'lib/backlog-workpack.ps1'
  )
  $foundForbidden = @($forbiddenTokens | Where-Object { $moduleText -like ('*' + $_ + '*') })
  Assert-BacklogGovernor 'module has no forbidden write or hot-path tokens' ($foundForbidden.Count -eq 0) ($foundForbidden -join ', ')
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
}

Write-Host ("Backlog Governor tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
