#Requires -Version 5.1
# test-task-management-shadow.ps1 -- fixtures for task management claim snapshots.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\task-management.ps1')

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
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 8) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Check-SnapshotShape {
  param([string]$Name, $Snapshot)
  $schema = Get-TaskManagementSchema
  foreach ($key in $schema.Keys) {
    Check "$Name has $key" ($null -ne $Snapshot.PSObject.Properties[$key]) $Snapshot
  }
  Check "$Name warnings is array" ($Snapshot.warnings -is [array]) $Snapshot
  Check "$Name blockers is array" ($Snapshot.blockers -is [array]) $Snapshot
}

$single = New-TaskManagementSnapshot `
  -TaskId 't1' `
  -TaskText 'Update one docs page with a short note.' `
  -Channel 'main' `
  -TouchedFiles @('docs/operator.md') `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='backlog'; IsBacklog=$true }
Check-SnapshotShape 'single docs' $single
Check 'single docs path' ([string]$single.execution_path -eq 'single') $single
Check 'single docs mode' ([string]$single.delivery_mode.mode -eq 'small') $single
Check 'single docs not parallel' (-not [bool]$single.parallel_applied) $single
Check 'single docs no warnings' (@($single.warnings).Count -eq 0) $single

$frontier = [pscustomobject]@{
  reason = 'batch-available'
  batch_available = $true
  parallel_required = $true
  approved_count = 4
  eligible_count = 4
  ready_count = 4
  selected_count = 3
  min_items = 2
  selected_ids = @('a','b','c')
  selected_groups = @('lib:a','tools:b','docs:c')
}
$parallel = New-TaskManagementSnapshot `
  -TaskId 'a' `
  -TaskText 'Execute independent workpack batch.' `
  -Channel 'main' `
  -TouchedFiles @('lib/a.ps1','tools/b.ps1','docs/c.md') `
  -BatchIds @('a','b','c') `
  -WorkpackFrontier $frontier `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='workpack_batch'; IsBacklog=$true }
Check-SnapshotShape 'parallel batch' $parallel
Check 'parallel batch path' ([string]$parallel.execution_path -eq 'workpack_parallel') $parallel
Check 'parallel batch applied' ([bool]$parallel.parallel_applied) $parallel
Check 'parallel batch selected' ([int]$parallel.frontier.selected -eq 3) $parallel
Check 'parallel batch no unsatisfied warning' (@($parallel.warnings) -notcontains 'parallel_obligation_unsatisfied') $parallel

$serial = New-TaskManagementSnapshot `
  -TaskId 's1' `
  -TaskText 'Execute protected bridge-self findings sequentially.' `
  -Channel 'main' `
  -TouchedFiles @('watchdog.ps1','supervisor.ps1') `
  -BatchIds @('s1','s2') `
  -WorkpackBatchMode 'serial' `
  -WorkpackFrontier ([pscustomobject]@{ reason='serial-batch-available'; batch_available=$true; parallel_required=$false; selected=2; min_items=2 }) `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='workpack_batch'; IsBacklog=$true }
Check-SnapshotShape 'protected serial' $serial
Check 'protected serial path' ([string]$serial.execution_path -eq 'protected_serial') $serial
Check 'protected serial not parallel' (-not [bool]$serial.parallel_applied) $serial
Check 'protected serial has reason' (-not [string]::IsNullOrWhiteSpace([string]$serial.serial_reason)) $serial

$unsatisfied = New-TaskManagementSnapshot `
  -TaskId 'u1' `
  -TaskText 'Fix one backlog item while a larger ready frontier exists.' `
  -Channel 'main' `
  -TouchedFiles @('docs/one.md') `
  -WorkpackFrontier ([pscustomobject]@{ reason='batch-ready'; batch_available=$true; parallel_required=$true; eligible=3; selected=1; min_items=2 }) `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='backlog'; IsBacklog=$true }
Check 'unsatisfied warning present' (@($unsatisfied.warnings) -contains 'parallel_obligation_unsatisfied') $unsatisfied
Check 'unsatisfied missing serial reason' ([string]$unsatisfied.serial_reason -eq 'missing_serial_reason') $unsatisfied

$conflicts = New-TaskManagementSnapshot `
  -TaskId 'c1' `
  -TaskText 'Fix one of several conflicting backlog items.' `
  -Channel 'main' `
  -TouchedFiles @('lib/shared.ps1') `
  -WorkpackFrontier ([pscustomobject]@{ reason='conflicts-or-touch-overlap'; batch_available=$false; parallel_required=$false; eligible=2; selected=1; min_items=2 }) `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='backlog'; IsBacklog=$true }
Check 'conflict frontier warning' (@($conflicts.warnings) -contains 'frontier_no_batch:conflicts-or-touch-overlap') $conflicts
Check 'conflict no blocker' (@($conflicts.blockers).Count -eq 0) $conflicts

$dependencyWait = New-TaskManagementSnapshot `
  -TaskId 'd1' `
  -TaskText 'Continue after prerequisite backlog atoms finish.' `
  -Channel 'main' `
  -TouchedFiles @('docs/waiting.md') `
  -WorkpackFrontier ([pscustomobject]@{ reason='dependency-wait'; batch_available=$false; parallel_required=$true; eligible=3; ready=1; selected=1; min_items=2 }) `
  -ChannelFacts @{ Channel='main'; ChannelType='bridge' } `
  -Context @{ Kind='backlog'; IsBacklog=$true }
Check 'dependency wait is explicit' (@($dependencyWait.warnings) -contains 'frontier_waiting_on_dependencies') $dependencyWait
Check 'dependency wait no parallel obligation warning' (@($dependencyWait.warnings) -notcontains 'parallel_obligation_unsatisfied') $dependencyWait
Check 'dependency wait no delivery required warning' (@($dependencyWait.warnings) -notcontains 'delivery_parallel_required_not_applied') $dependencyWait

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-task-management-test-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\main') -Force | Out-Null
  $write = Write-TaskManagementShadowRecord -BridgeRoot $tmpRoot -Channel 'main' -TaskId 't1' -Snapshot $single -Note 'unit'
  Check 'writer ok' ([bool]$write.ok) $write
  Check 'writer file exists' (Test-Path -LiteralPath (Join-Path $tmpRoot 'channels\main\task-management-shadow.jsonl')) $write
  $bad = Write-TaskManagementShadowRecord -BridgeRoot $tmpRoot -Channel '..\bad' -TaskId 'x' -Snapshot $single -Note 'bad'
  Check 'writer rejects invalid channel' (-not [bool]$bad.ok) $bad
} finally {
  try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$summary = Format-TaskManagementSummary -Snapshot $parallel
Check 'summary contains path' ($summary -match 'path=workpack_parallel') $summary

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
