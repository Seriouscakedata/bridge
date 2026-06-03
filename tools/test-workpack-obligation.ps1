#Requires -Version 5.1
# test-workpack-obligation.ps1 -- fixtures for isolated workpack metadata and eligibility checks.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\workpack-obligation.ps1')

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

function New-Atom {
  param(
    [Parameter(Mandatory)][string]$Slug,
    [string[]]$DependsOn = @(),
    [Parameter(Mandatory)][string[]]$Files,
    [Parameter(Mandatory)][string]$ConflictGroup,
    [Parameter(Mandatory)][string[]]$TouchSet,
    [string]$SerialReason = '',
    [string[]]$Checks = @('parser_parsefile'),
    [object]$Acceptance = @('targeted test'),
    [string]$Risk = 'normal'
  )

  return [ordered]@{
    slug                    = $Slug
    title                   = ('Title for ' + $Slug)
    task                    = ('Task for ' + $Slug)
    files                   = @($Files)
    depends_on              = @($DependsOn)
    workpack_conflict_group = $ConflictGroup
    workpack_touch_set      = @($TouchSet)
    acceptance              = $Acceptance
    checks                  = @($Checks)
    risk                    = $Risk
    serial_reason           = $SerialReason
  }
}

function Check-MetadataShape {
  param([string]$Name, $Metadata)
  $schema = Get-WorkpackAtomMetadataSchema
  foreach ($key in $schema.Keys) {
    Check "$Name has $key" ($null -ne $Metadata.PSObject.Properties[$key]) $Metadata
  }
}

function Check-ReportShape {
  param([string]$Name, $Report)
  $schema = Get-WorkpackEligibilityReportSchema
  foreach ($key in $schema.Keys) {
    Check "$Name has $key" ($null -ne $Report.PSObject.Properties[$key]) $Report
  }
}

$independentAtoms = @(
  (New-Atom -Slug 'alpha' -Files @('lib/alpha.ps1') -ConflictGroup 'grp-alpha' -TouchSet @('lib/alpha.ps1')),
  (New-Atom -Slug 'beta' -Files @('tools/beta.ps1') -ConflictGroup 'grp-beta' -TouchSet @('tools/beta.ps1')),
  (New-Atom -Slug 'gamma' -Files @('docs/gamma.md') -ConflictGroup 'grp-gamma' -TouchSet @('docs/gamma.md'))
)
$independentReport = Get-WorkpackEligibilityReport -Atoms $independentAtoms -Context @{ CompletedSlugs = @() }
Check-ReportShape 'independent report' $independentReport
Check '3 independent ready count' ($independentReport.ready.Count -eq 3) $independentReport
Check '3 independent parallel required' ([bool]$independentReport.parallel_required) $independentReport
Check '3 independent selected count' ($independentReport.selected.Count -ge 2) $independentReport

$overlapAtoms = @(
  (New-Atom -Slug 'touch-a' -Files @('lib/shared.ps1') -ConflictGroup 'grp-a' -TouchSet @('lib/shared.ps1')),
  (New-Atom -Slug 'touch-b' -Files @('tools/shared.ps1') -ConflictGroup 'grp-b' -TouchSet @('lib/shared.ps1'))
)
$overlapReport = Get-WorkpackEligibilityReport -Atoms $overlapAtoms
Check-ReportShape 'overlap report' $overlapReport
Check 'overlap blocked by touch' ($overlapReport.blocked_by_touch -contains 'touch-b') $overlapReport
Check 'overlap not both selected' (-not (($overlapReport.selected -contains 'touch-a') -and ($overlapReport.selected -contains 'touch-b'))) $overlapReport

$groupAtoms = @(
  (New-Atom -Slug 'group-a' -Files @('lib/group-a.ps1') -ConflictGroup 'shared-group' -TouchSet @('lib/group-a.ps1')),
  (New-Atom -Slug 'group-b' -Files @('lib/group-b.ps1') -ConflictGroup 'shared-group' -TouchSet @('lib/group-b.ps1'))
)
$groupReport = Get-WorkpackEligibilityReport -Atoms $groupAtoms
Check 'same conflict group blocked' ($groupReport.blocked_by_conflict -contains 'group-b') $groupReport

$unmetDepAtoms = @(
  (New-Atom -Slug 'base' -Files @('lib/base.ps1') -ConflictGroup 'grp-base' -TouchSet @('lib/base.ps1')),
  (New-Atom -Slug 'child' -DependsOn @('base') -Files @('lib/child.ps1') -ConflictGroup 'grp-child' -TouchSet @('lib/child.ps1'))
)
$unmetDepReport = Get-WorkpackEligibilityReport -Atoms $unmetDepAtoms -Context @{ CompletedSlugs = @() }
Check 'unmet deps blocked' ($unmetDepReport.blocked_by_deps -contains 'child') $unmetDepReport
Check 'unmet deps child not ready' (-not ($unmetDepReport.ready -contains 'child')) $unmetDepReport

$metDepReport = Get-WorkpackEligibilityReport -Atoms $unmetDepAtoms -Context @{ CompletedSlugs = @('base') }
Check 'met deps child ready' ($metDepReport.ready -contains 'child') $metDepReport

$missingFiles = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug                    = 'missing-files'
  title                   = 'Missing files'
  task                    = 'Test files'
  depends_on              = @()
  workpack_conflict_group = 'grp-missing-files'
  workpack_touch_set      = @('lib/missing-files.ps1')
  acceptance              = @('acceptance')
  checks                  = @('parser')
  risk                    = 'normal'
  serial_reason           = ''
})
Check-MetadataShape 'missing files metadata' $missingFiles
Check 'missing files not ok' (-not [bool]$missingFiles.ok) $missingFiles
Check 'missing files key present' ($missingFiles.missing -contains 'files') $missingFiles
Check 'missing files blocker present' ($missingFiles.blockers -contains 'files') $missingFiles

$missingChecks = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug                    = 'missing-checks'
  title                   = 'Missing checks'
  task                    = 'Test checks'
  files                   = @('lib/missing-checks.ps1')
  depends_on              = @()
  workpack_conflict_group = 'grp-missing-checks'
  workpack_touch_set      = @('lib/missing-checks.ps1')
  acceptance              = @('acceptance')
  risk                    = 'normal'
  serial_reason           = ''
})
Check 'missing checks not ok' (-not [bool]$missingChecks.ok) $missingChecks
Check 'missing checks key present' ($missingChecks.missing -contains 'checks') $missingChecks
Check 'missing checks blocker present' ($missingChecks.blockers -contains 'checks') $missingChecks

$missingAcceptance = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug                    = 'missing-acceptance'
  title                   = 'Missing acceptance'
  task                    = 'Test acceptance'
  files                   = @('lib/missing-acceptance.ps1')
  depends_on              = @()
  workpack_conflict_group = 'grp-missing-acceptance'
  workpack_touch_set      = @('lib/missing-acceptance.ps1')
  checks                  = @('parser')
  risk                    = 'normal'
  serial_reason           = ''
})
Check 'missing acceptance not ok' (-not [bool]$missingAcceptance.ok) $missingAcceptance
Check 'missing acceptance key present' ($missingAcceptance.missing -contains 'acceptance') $missingAcceptance
Check 'missing acceptance blocker present' ($missingAcceptance.blockers -contains 'acceptance') $missingAcceptance

$serialBarrierAtoms = @(
  (New-Atom -Slug 'foundation' -Files @('lib/foundation.ps1') -ConflictGroup 'grp-foundation' -TouchSet @('lib/foundation.ps1') -SerialReason 'foundation'),
  (New-Atom -Slug 'parallel' -Files @('lib/parallel.ps1') -ConflictGroup 'grp-parallel' -TouchSet @('lib/parallel.ps1'))
)
$serialBarrierReport = Get-WorkpackEligibilityReport -Atoms $serialBarrierAtoms
Check 'critical serial barrier listed' ($serialBarrierReport.serial_barriers -contains 'foundation') $serialBarrierReport
Check 'critical serial barrier not selected' (-not ($serialBarrierReport.selected -contains 'foundation')) $serialBarrierReport

$serialRequiredAtoms = @(
  (New-Atom -Slug 'first' -Files @('lib/first.ps1') -ConflictGroup 'grp-first' -TouchSet @('lib/first.ps1')),
  (New-Atom -Slug 'second' -Files @('lib/second.ps1') -ConflictGroup 'grp-second' -TouchSet @('lib/second.ps1'))
)
$serialRequiredReport = Get-WorkpackEligibilityReport -Atoms $serialRequiredAtoms -Context @{ SelectedSlugs = @('first') }
Check 'selected one while parallel possible' ($serialRequiredReport.selected.Count -eq 1) $serialRequiredReport
Check 'serial reason required when selected one without reason' ([bool]$serialRequiredReport.serial_reason_required) $serialRequiredReport

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
