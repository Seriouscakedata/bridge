# test-queue-governor-claim-hooks.ps1 -- Queue Governor claim path integration tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog.ps1')

$script:pass = 0
$script:fail = 0
$script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-qgov-hooks-' + [guid]::NewGuid().ToString('N'))
$script:testBacklogPath = Join-Path $script:tmpRoot 'backlog.jsonl'
$script:testControlDir = Join-Path $script:tmpRoot 'control'
$script:GovernorCalls = 0
$script:OriginalGovernorClaimable = ${function:Test-BacklogGovernorClaimable}

function Test-BacklogGovernorClaimable {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$ActiveItems = @(),
    [Parameter(Mandatory=$false)]$ManualLocks = @(),
    [Parameter(Mandatory=$false)][string]$Root = $bridgeRoot
  )
  $script:GovernorCalls++
  return (& $script:OriginalGovernorClaimable -Item $Item -ActiveItems $ActiveItems -ManualLocks $ManualLocks -Root $Root)
}

function Get-ChannelBacklogPath { return $script:testBacklogPath }
function Get-BacklogControlDir { return $script:testControlDir }
function Test-ProjectScopedApprovedBacklogAllowed { return $true }

function Assert-QueueGovernorHook {
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

function Reset-TestBacklog {
  if (Test-Path -LiteralPath $script:tmpRoot) { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force }
  New-Item -ItemType Directory -Path $script:testControlDir -Force | Out-Null
  $script:GovernorCalls = 0
}

function New-QGovItem {
  param(
    [string]$Id,
    [string]$Status = 'approved',
    [string[]]$TouchSet = @('lib/example.ps1'),
    [string]$RootCauseKey = '',
    [string]$WorkpackId = '',
    [string]$Group = 'ui'
  )
  if ([string]::IsNullOrWhiteSpace($RootCauseKey)) { $RootCauseKey = 'queue-governor:test:' + $Id }
  $item = [pscustomobject][ordered]@{
    id = $Id
    ts = '2026-06-06T00:00:00Z'
    from = 'test'
    status = $Status
    tags = @()
    attempts = 0
    score = 1.0
    project = ''
    scope = 'bridge'
    title = 'Queue Governor hook ' + $Id
    text = 'Implement Queue Governor hook case ' + $Id
    touch_set = @($TouchSet)
    root_cause_key = $RootCauseKey
  }
  if (-not [string]::IsNullOrWhiteSpace($WorkpackId)) {
    $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue $WorkpackId -Force
    $item | Add-Member -NotePropertyName workpack_status -NotePropertyValue 'packed' -Force
    $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue $Group -Force
    $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($TouchSet) -Force
    $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue $RootCauseKey -Force
    $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue $Group -Force
  }
  return $item
}

function Get-TestItem {
  param([string]$Id)
  return @((Get-Backlog) | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

try {
  Reset-TestBacklog
  $invalidId = Add-Idea -Text 'approved without governor lease metadata' -Status 'approved' -SkipCurator
  $invalid = Get-TestItem -Id $invalidId
  Assert-QueueGovernorHook 'intake invalid approved auto-dropped' ([string]$invalid.status -eq 'auto-dropped') ($invalid | ConvertTo-Json -Compress -Depth 8)
  Assert-QueueGovernorHook 'intake auto-drop evidence includes missing fields' (
    [string]$invalid.auto_curator.verdict -eq 'drop' -and
    [string]$invalid.auto_curator.reason -like 'queue-governor:*' -and
    @($invalid.governor_drop_evidence.shape.missing).Count -gt 0
  ) ($invalid | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  Save-Backlog @((New-QGovItem -Id 'valid-single' -TouchSet @('lib/valid-single.ps1')))
  $picked = Get-NextApprovedIdea
  $pickedStored = Get-TestItem -Id 'valid-single'
  Assert-QueueGovernorHook 'valid single approved item is claimable' ([string]$picked.id -eq 'valid-single') ($picked | ConvertTo-Json -Compress -Depth 8)
  Assert-QueueGovernorHook 'single approved claim records governor evidence' (
    [string]$pickedStored.governor_claim.action -eq 'allow' -and
    [string]$pickedStored.governor_claim.reason -eq 'claimable' -and
    $script:GovernorCalls -gt 0
  ) ($pickedStored | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  Save-Backlog @(
    (New-QGovItem -Id 'active-touch' -Status 'running' -TouchSet @('lib/shared')),
    (New-QGovItem -Id 'candidate-touch' -TouchSet @('lib/shared/file.ps1') -RootCauseKey 'queue-governor:test:touch-candidate')
  )
  $touchPick = Get-NextApprovedIdea
  $touchCandidate = Get-TestItem -Id 'candidate-touch'
  Assert-QueueGovernorHook 'running touch_set conflict blocks single claim' (
    $null -eq $touchPick -and [string]$touchCandidate.governor_deferred_reason -eq 'lease-conflict' -and [string]$touchCandidate.governor_deferred_evidence.conflict.conflict_on -eq 'touch_set'
  ) ($touchCandidate | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  Save-Backlog @(
    (New-QGovItem -Id 'active-root' -Status 'working' -TouchSet @('lib/active-root.ps1') -RootCauseKey 'queue-governor:test:same-root'),
    (New-QGovItem -Id 'candidate-root' -TouchSet @('lib/candidate-root.ps1') -RootCauseKey 'QUEUE-GOVERNOR:TEST:SAME-ROOT')
  )
  $rootPick = Get-NextApprovedIdea
  $rootCandidate = Get-TestItem -Id 'candidate-root'
  Assert-QueueGovernorHook 'working root_cause_key conflict blocks single claim' (
    $null -eq $rootPick -and [string]$rootCandidate.governor_deferred_reason -eq 'lease-conflict' -and [string]$rootCandidate.governor_deferred_evidence.conflict.conflict_on -eq 'root_cause_key'
  ) ($rootCandidate | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  $manualTouchLock = [pscustomobject][ordered]@{ id='manual-touch'; active=$true; touch_set=@('tools/manual-lock'); root_cause_key='queue-governor:test:manual-other' }
  [System.IO.File]::WriteAllText((Join-Path $script:testControlDir 'manual-locks.json'), (@($manualTouchLock) | ConvertTo-Json -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  Save-Backlog @((New-QGovItem -Id 'manual-touch-candidate' -TouchSet @('tools/manual-lock/case.ps1') -RootCauseKey 'queue-governor:test:manual-touch-candidate'))
  $manualTouchPick = Get-NextApprovedIdea
  $manualTouchCandidate = Get-TestItem -Id 'manual-touch-candidate'
  $manualLog = Get-Content -LiteralPath (Join-Path $script:testControlDir 'curator-decisions.jsonl') -Raw -Encoding UTF8
  Assert-QueueGovernorHook 'manual touch_set lock defers single claim visibly' (
    $null -eq $manualTouchPick -and [string]$manualTouchCandidate.governor_deferred_reason -eq 'manual-lock-conflict' -and $manualLog -like '*governor-deferred*manual-lock-conflict*'
  ) ($manualTouchCandidate | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  $manualRootLock = [pscustomobject][ordered]@{ id='manual-root'; active=$true; touch_set=@('docs/manual.md'); root_cause_key='queue-governor:test:manual-root' }
  [System.IO.File]::WriteAllText((Join-Path $script:testControlDir 'manual-locks.json'), (@($manualRootLock) | ConvertTo-Json -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  Save-Backlog @((New-QGovItem -Id 'manual-root-candidate' -TouchSet @('lib/manual-root.ps1') -RootCauseKey 'QUEUE-GOVERNOR:TEST:MANUAL-ROOT'))
  $manualRootPick = Get-NextApprovedIdea
  $manualRootCandidate = Get-TestItem -Id 'manual-root-candidate'
  Assert-QueueGovernorHook 'manual root_cause_key lock defers single claim visibly' (
    $null -eq $manualRootPick -and [string]$manualRootCandidate.governor_deferred_reason -eq 'manual-lock-conflict' -and [string]$manualRootCandidate.governor_deferred_evidence.conflict.conflict_on -eq 'root_cause_key'
  ) ($manualRootCandidate | ConvertTo-Json -Compress -Depth 8)

  Reset-TestBacklog
  Save-Backlog @(
    (New-QGovItem -Id 'active-wp' -Status 'running' -TouchSet @('web/shared.tsx') -RootCauseKey 'queue-governor:test:wp-active'),
    (New-QGovItem -Id 'wp-conflict' -TouchSet @('web/shared.tsx') -RootCauseKey 'queue-governor:test:wp-conflict' -WorkpackId 'wp-conflict' -Group 'ui-a'),
    (New-QGovItem -Id 'wp-ok' -TouchSet @('web/ok.tsx') -RootCauseKey 'queue-governor:test:wp-ok' -WorkpackId 'wp-ok' -Group 'ui-b')
  )
  $cfg = [pscustomobject]@{
    enabled = $true
    minItems = 2
    maxItems = 6
    includeProtected = $true
    serialProtectedEnabled = $true
    serialProtectedMinItems = 2
    serialProtectedMaxItems = 6
  }
  $frontier = Get-BacklogWorkpackFrontierReport -Config $cfg
  $wpConflict = Get-TestItem -Id 'wp-conflict'
  Assert-QueueGovernorHook 'workpack frontier calls governor predicate and excludes conflict' (
    $script:GovernorCalls -gt 0 -and @($frontier.selected_ids) -notcontains 'wp-conflict' -and [string]$wpConflict.governor_deferred_reason -eq 'lease-conflict'
  ) ($frontier | ConvertTo-Json -Compress -Depth 8)
  Assert-QueueGovernorHook 'workpack frontier report contains governor_deferred detail' (
    [int]$frontier.governor_deferred_count -gt 0 -and @($frontier.reason_details.governor_deferred).Count -gt 0 -and [string]$frontier.reason_detail -like '*governor_deferred*'
  ) ($frontier | ConvertTo-Json -Compress -Depth 8)
  Assert-QueueGovernorHook 'approved conflict candidate cannot be claimed through runnable picker' (
    [string](Get-NextRunnableIdea -IncludeNew $false).id -ne 'wp-conflict'
  ) ((Get-Backlog) | ConvertTo-Json -Compress -Depth 8)

  $coreText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\backlog-core.ps1') -Raw -Encoding UTF8
  $workpackText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\backlog-workpack.ps1') -Raw -Encoding UTF8
  Assert-QueueGovernorHook 'claim hooks use shared governor predicate' (
    $coreText -like '*Invoke-BacklogGovernorFilterApprovedItems*' -and
    $coreText -like '*Test-BacklogGovernorClaimable*' -and
    $workpackText -like '*Test-BacklogGovernorClaimable*' -and
    $workpackText -like '*governor-deferred*'
  )
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  $script:fail++
} finally {
  try { if (Test-Path -LiteralPath $script:tmpRoot) { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force } } catch {}
}

Write-Host ("Queue Governor claim hook tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
