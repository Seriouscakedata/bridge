#Requires -Version 5.1
# test-backlog-claimability.ps1 -- approved backlog runnable-vs-blocked report.

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

$items = @(
  [pscustomobject]@{ id='cp1'; status='approved'; text='Change driver.ps1 restart logic'; tags=@(); scope='bridge'; workpack_status='planned'; workpack_conflict_group='file:driver.ps1' },
  [pscustomobject]@{ id='op1'; status='approved'; text='Change driver.ps1 with operator approval'; tags=@('operator'); scope='bridge' },
  [pscustomobject]@{ id='doc1'; status='approved'; text='Update docs page'; tags=@(); scope='bridge' },
  [pscustomobject]@{ id='pr1'; status='approved'; text='Project task'; tags=@(); scope='project' },
  [pscustomobject]@{ id='done1'; status='done'; text='Done task'; tags=@(); scope='bridge' }
)

$report = Get-ApprovedBacklogClaimabilityReport -Items $items
Check 'mixed approved count' ([int]$report.approved_count -eq 4) $report
Check 'mixed runnable count' ([int]$report.runnable_count -eq 2) $report
Check 'mixed control plane blocked' ([int]$report.control_plane_blocked -eq 1) $report
Check 'mixed project scope blocked' ([int]$report.project_scope_blocked -eq 1) $report
Check 'mixed runnable ids include operator' (@($report.runnable_ids) -contains 'op1') $report
Check 'mixed runnable ids include docs' (@($report.runnable_ids) -contains 'doc1') $report
Check 'mixed control ids include cp1' (@($report.control_plane_ids) -contains 'cp1') $report
Check 'mixed project ids include pr1' (@($report.project_scope_ids) -contains 'pr1') $report

$blockedOnly = Get-ApprovedBacklogClaimabilityReport -Items @(
  [pscustomobject]@{ id='cp2'; status='approved'; text='Investigate supervisor.ps1 process supervision'; tags=@(); scope='bridge' },
  [pscustomobject]@{ id='cp3'; status='approved'; text='Fix watchdog restart-limit behavior'; tags=@(); scope='bridge' }
)
Check 'blocked only approved count' ([int]$blockedOnly.approved_count -eq 2) $blockedOnly
Check 'blocked only runnable zero' ([int]$blockedOnly.runnable_count -eq 0) $blockedOnly
Check 'blocked only control count' ([int]$blockedOnly.control_plane_blocked -eq 2) $blockedOnly

$none = Get-ApprovedBacklogClaimabilityReport -Items @(
  [pscustomobject]@{ id='n1'; status='new'; text='New task'; tags=@(); scope='bridge' }
)
Check 'no approved count zero' ([int]$none.approved_count -eq 0) $none
Check 'no approved runnable zero' ([int]$none.runnable_count -eq 0) $none

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
