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

$validAdmission = [pscustomobject]@{
  admitted = $true
  mode = 'bridge_self_canary'
  canary_required = $true
  checks = @(
    'powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest',
    'powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1',
    'Invoke-CanaryCycle -Force'
  )
  rollback_plan = 'Use stable ref + watchdog rollback if health/smoke/canary fails.'
}

$items = @(
  [pscustomobject]@{ id='cp1'; status='approved'; text='Change driver.ps1 restart logic'; tags=@(); scope='bridge'; workpack_status='planned'; workpack_conflict_group='file:driver.ps1' },
  [pscustomobject]@{ id='op1'; status='approved'; text='Change driver.ps1 with operator approval'; tags=@('operator'); scope='bridge' },
  [pscustomobject]@{ id='adm1'; status='approved'; text='Change driver.ps1 with bridge self admission'; tags=@('bridge-self'); scope='bridge'; files=@('driver.ps1'); bridge_self_admission=$validAdmission },
  [pscustomobject]@{ id='ext1'; status='approved'; text='Change driver.ps1 from external source'; tags=@('external'); scope='bridge'; files=@('driver.ps1'); bridge_self_admission=$validAdmission },
  [pscustomobject]@{ id='doc1'; status='approved'; text='Update docs page'; tags=@(); scope='bridge' },
  [pscustomobject]@{ id='tries1'; status='approved'; text='Exhausted retry item'; tags=@(); scope='bridge'; attempts=5 },
  [pscustomobject]@{ id='pr1'; status='approved'; text='Project task'; tags=@(); scope='project' },
  [pscustomobject]@{ id='done1'; status='done'; text='Done task'; tags=@(); scope='bridge' },
  [pscustomobject]@{ id='scn1'; status='approved'; text='Run backlog-flow-claimability bridge backlog add list delete verification scenario'; tags=@('operator','scenario'); scope='bridge' }
)

$report = Get-ApprovedBacklogClaimabilityReport -Items $items
Check 'mixed approved count' ([int]$report.approved_count -eq 8) $report
Check 'mixed runnable count' ([int]$report.runnable_count -eq 3) $report
Check 'mixed control plane blocked' ([int]$report.control_plane_blocked -eq 2) $report
Check 'mixed admitted control count' ([int]$report.admitted_control_plane -eq 1) $report
Check 'mixed project scope blocked' ([int]$report.project_scope_blocked -eq 1) $report
Check 'mixed governor dropped count' ([int]$report.governor_dropped_count -eq 1) $report
Check 'attempts exhausted moved to needs-review' ([string]$items[5].status -eq 'needs-review' -and [string]$items[5].needs_review_reason -eq 'attempts-exhausted') $items[5]
Check 'mixed runnable ids include operator' (@($report.runnable_ids) -contains 'op1') $report
Check 'mixed runnable ids include admitted bridge self' (@($report.runnable_ids) -contains 'adm1') $report
Check 'mixed runnable ids include docs' (@($report.runnable_ids) -contains 'doc1') $report
Check 'scenario marker auto-dropped' ([string]$items[8].status -eq 'auto-dropped' -and [string]$items[8].governor_drop_reason -eq 'queue-governor:scenario-marker') $items[8]
Check 'scenario marker not runnable' (-not (@($report.runnable_ids) -contains 'scn1')) $report
Check 'scenario marker listed as governor drop' (@($report.governor_dropped | Where-Object { [string]$_.id -eq 'scn1' -and [string]$_.reason -eq 'scenario-marker' }).Count -eq 1) $report
Check 'mixed control ids include cp1' (@($report.control_plane_ids) -contains 'cp1') $report
Check 'mixed control ids include external despite admission' (@($report.control_plane_ids) -contains 'ext1') $report
Check 'mixed project ids include pr1' (@($report.project_scope_ids) -contains 'pr1') $report

$incidentItems = @(
  [pscustomobject]@{ id='1f4053fe'; status='approved'; text='backlog-flow-e8061e8f51a0 bridge backlog add list delete verification violet signal quartz canyon lantern ember ribbon orchard'; tags=@('scenario'); scope='bridge' },
  [pscustomobject]@{ id='2a67959e'; status='approved'; text='Functional verifier backlog add flow marker backlog-flow-2a67959e bridge backlog add list delete verification'; tags=@('scenario'); scope='bridge' },
  [pscustomobject]@{ id='677931e9'; status='approved'; text='Temporary browser verifier token backlog-flow-677931e9 bridge backlog add list delete verification'; tags=@('scenario'); scope='bridge' },
  [pscustomobject]@{ id='e492b629'; status='approved'; text='backlog crud proof marker backlog-flow-e492b629 bridge backlog add list delete verification'; tags=@('scenario'); scope='bridge' }
)
$incidentReport = Get-ApprovedBacklogClaimabilityReport -Items $incidentItems
Check 'incident marker approved count' ([int]$incidentReport.approved_count -eq 4) $incidentReport
Check 'incident marker runnable zero' ([int]$incidentReport.runnable_count -eq 0) $incidentReport
Check 'incident marker governor dropped count' ([int]$incidentReport.governor_dropped_count -eq 4) $incidentReport
Check 'incident marker ids all dropped' (@($incidentItems | Where-Object { [string]$_.status -eq 'auto-dropped' -and [string]$_.governor_drop_reason -eq 'queue-governor:scenario-marker' }).Count -eq 4) $incidentItems

$admit = Test-IdeaBridgeSelfAdmitted -Idea $items[2]
Check 'valid admission ok' ([bool]$admit.ok) $admit
$externalAdmit = Test-IdeaBridgeSelfAdmitted -Idea $items[3]
Check 'external admission rejected' (-not [bool]$externalAdmit.ok) $externalAdmit
$missingCanary = [pscustomobject]@{ id='bad1'; status='approved'; text='Change driver.ps1 without canary'; tags=@('bridge-self'); scope='bridge'; files=@('driver.ps1'); bridge_self_admission=[pscustomobject]@{ admitted=$true; mode='bridge_self_canary'; canary_required=$false; checks=@('driver.ps1 -SelfTest','smoke.ps1'); rollback_plan='rollback' } }
$badAdmit = Test-IdeaBridgeSelfAdmitted -Idea $missingCanary
Check 'missing canary admission rejected' (-not [bool]$badAdmit.ok -and (@($badAdmit.missing) -contains 'canary_required=true')) $badAdmit

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
