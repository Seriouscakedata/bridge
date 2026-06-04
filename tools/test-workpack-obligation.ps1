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
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 10) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function New-Atom {
  param(
    [Parameter(Mandatory)][string]$Slug,
    [string[]]$DependsOn = @(),
    [Parameter(Mandatory)][string[]]$Files,
    [Parameter(Mandatory)][string]$ParallelGroup,
    [Parameter(Mandatory)][string[]]$TouchSet,
    [string]$Lane = 'project',
    [string]$SerialReason = '',
    [string[]]$Checks = @('parser_parsefile'),
    [object]$Acceptance = @('targeted test'),
    [string]$Risk = 'normal'
  )

  return [ordered]@{
    slug           = $Slug
    title          = ('Title for ' + $Slug)
    task           = ('Task for ' + $Slug)
    files          = @($Files)
    touch_set      = @($TouchSet)
    depends_on     = @($DependsOn)
    lane           = $Lane
    parallel_group = $ParallelGroup
    acceptance     = $Acceptance
    checks         = @($Checks)
    risk           = $Risk
    serial_reason  = $SerialReason
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

$mixedAtoms = @(
  (New-Atom -Slug 'alpha-ui' -Files @('src/ui/alpha.ts') -ParallelGroup 'pg-ui' -TouchSet @('src/ui/alpha.ts')),
  (New-Atom -Slug 'beta-api' -Files @('src/api/beta.ts') -ParallelGroup 'pg-api' -TouchSet @('src/api/beta.ts')),
  (New-Atom -Slug 'delta-touch' -Files @('src/ui/delta.ts') -ParallelGroup 'pg-delta' -TouchSet @('src/ui/alpha.ts')),
  (New-Atom -Slug 'epsilon-group-a' -Files @('lib/shared-a.ps1') -ParallelGroup 'pg-shared' -TouchSet @('lib/shared-a.ps1')),
  (New-Atom -Slug 'eta-child' -DependsOn @('alpha-ui') -Files @('src/child/eta.ts') -ParallelGroup 'pg-eta' -TouchSet @('src/child/eta.ts')),
  (New-Atom -Slug 'gamma-docs' -Files @('docs/gamma.md') -ParallelGroup 'pg-docs' -TouchSet @('docs/gamma.md')),
  (New-Atom -Slug 'iota-project' -Files @('project/config.json') -ParallelGroup 'pg-config' -TouchSet @('project/config.json') -Lane 'project'),
  (New-Atom -Slug 'kappa-control' -Files @('lib/driver.ps1') -ParallelGroup 'pg-control' -TouchSet @('lib/driver.ps1') -Lane 'control-plane' -SerialReason 'control_plane'),
  (New-Atom -Slug 'lambda-integration' -Files @('lib/integration.ps1') -ParallelGroup 'pg-integration' -TouchSet @('lib/integration.ps1') -SerialReason 'integration'),
  (New-Atom -Slug 'mu-schema' -Files @('schemas/mu.json') -ParallelGroup 'pg-schema' -TouchSet @('schemas/mu.json') -SerialReason 'shared_schema'),
  (New-Atom -Slug 'plan-foundation' -Files @('lib/foundation.ps1') -ParallelGroup 'pg-foundation' -TouchSet @('lib/foundation.ps1') -Lane 'control-plane' -SerialReason 'foundation'),
  (New-Atom -Slug 'theta-child-met' -DependsOn @('done-base') -Files @('src/child/theta.ts') -ParallelGroup 'pg-theta' -TouchSet @('src/child/theta.ts')),
  (New-Atom -Slug 'xi-legacy-aliases' -Files @('src/legacy/xi.ts') -ParallelGroup 'pg-xi' -TouchSet @('src/legacy/xi.ts')),
  (New-Atom -Slug 'zeta-group-b' -Files @('lib/shared-b.ps1') -ParallelGroup 'pg-shared' -TouchSet @('lib/shared-b.ps1'))
)

$mixedAtoms[12].Remove('parallel_group')
$mixedAtoms[12].Remove('touch_set')
$mixedAtoms[12]['workpack_conflict_group'] = 'pg-xi'
$mixedAtoms[12]['workpack_touch_set'] = @('src/legacy/xi.ts')

$mixedReport = Get-WorkpackEligibilityReport -Atoms $mixedAtoms -Context @{ CompletedSlugs = @('done-base') }
Check-ReportShape 'mixed report' $mixedReport
Check 'mixed selected independent alpha' ($mixedReport.selected -contains 'alpha-ui') $mixedReport
Check 'mixed selected independent beta' ($mixedReport.selected -contains 'beta-api') $mixedReport
Check 'mixed selected met dependency' ($mixedReport.selected -contains 'theta-child-met') $mixedReport
Check 'mixed parallel required' ([bool]$mixedReport.parallel_required) $mixedReport
Check 'mixed touch overlap blocked' ($mixedReport.blocked_by_touch -contains 'delta-touch') $mixedReport
Check 'mixed touch reason present' (@($mixedReport.blocked_reasons['delta-touch']) -contains 'touch_overlap:src/ui/alpha.ts') $mixedReport
Check 'mixed group conflict blocked' ($mixedReport.blocked_by_conflict -contains 'zeta-group-b') $mixedReport
Check 'mixed group reason present' (@($mixedReport.blocked_reasons['zeta-group-b']) -contains 'parallel_group:pg-shared') $mixedReport
Check 'mixed deps blocked' ($mixedReport.blocked_by_deps -contains 'eta-child') $mixedReport
Check 'mixed deps reason present' (@($mixedReport.blocked_reasons['eta-child']) -contains 'deps:alpha-ui') $mixedReport
Check 'mixed control plane barrier' ($mixedReport.serial_barriers -contains 'kappa-control') $mixedReport
Check 'mixed foundation barrier' ($mixedReport.serial_barriers -contains 'plan-foundation') $mixedReport
Check 'mixed integration barrier' ($mixedReport.serial_barriers -contains 'lambda-integration') $mixedReport
Check 'mixed control not selected' (-not ($mixedReport.selected -contains 'kappa-control')) $mixedReport
Check 'mixed runnable selected reason' (@($mixedReport.runnable_reasons['alpha-ui']) -contains 'selected_frontier') $mixedReport
Check 'mixed legacy aliases selected' ($mixedReport.selected -contains 'xi-legacy-aliases') $mixedReport

$metadata = Test-WorkpackAtomMetadata -Atom $mixedAtoms[0]
Check-MetadataShape 'atom metadata' $metadata
Check 'metadata normalized files' ($metadata.files -contains 'src/ui/alpha.ts') $metadata
Check 'metadata normalized touch_set' ($metadata.touch_set -contains 'src/ui/alpha.ts') $metadata
Check 'metadata includes lane' ($metadata.lane -eq 'project') $metadata
Check 'metadata includes parallel_group' ($metadata.parallel_group -eq 'pg-ui') $metadata
Check 'metadata runnable reason' ($metadata.runnable_reasons -contains 'metadata_ok') $metadata

$legacyMetadata = Test-WorkpackAtomMetadata -Atom $mixedAtoms[12]
Check 'legacy conflict alias accepted' ($legacyMetadata.parallel_group -eq 'pg-xi') $legacyMetadata
Check 'legacy touch alias accepted' ($legacyMetadata.touch_set -contains 'src/legacy/xi.ts') $legacyMetadata

$missingAcceptance = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug           = 'missing-acceptance'
  title          = 'Missing acceptance'
  task           = 'Test acceptance'
  files          = @('lib/missing-acceptance.ps1')
  touch_set      = @('lib/missing-acceptance.ps1')
  depends_on     = @()
  lane           = 'project'
  parallel_group = 'pg-missing-acceptance'
  checks         = @('parser')
  risk           = 'normal'
  serial_reason  = ''
})
Check 'missing acceptance not ok' (-not [bool]$missingAcceptance.ok) $missingAcceptance
Check 'missing acceptance key present' ($missingAcceptance.missing -contains 'acceptance') $missingAcceptance
Check 'missing acceptance blocked reason' ($missingAcceptance.blocked_reasons -contains 'metadata:acceptance') $missingAcceptance

$missingChecks = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug           = 'missing-checks'
  title          = 'Missing checks'
  task           = 'Test checks'
  files          = @('lib/missing-checks.ps1')
  touch_set      = @('lib/missing-checks.ps1')
  depends_on     = @()
  lane           = 'project'
  parallel_group = 'pg-missing-checks'
  acceptance     = @('acceptance')
  risk           = 'normal'
  serial_reason  = ''
})
Check 'missing checks not ok' (-not [bool]$missingChecks.ok) $missingChecks
Check 'missing checks key present' ($missingChecks.missing -contains 'checks') $missingChecks
Check 'missing checks blocked reason' ($missingChecks.blocked_reasons -contains 'metadata:checks') $missingChecks

$missingLane = Test-WorkpackAtomMetadata -Atom ([ordered]@{
  slug           = 'missing-lane'
  title          = 'Missing lane'
  task           = 'Test lane'
  files          = @('lib/missing-lane.ps1')
  touch_set      = @('lib/missing-lane.ps1')
  depends_on     = @()
  parallel_group = 'pg-missing-lane'
  acceptance     = @('acceptance')
  checks         = @('parser')
  risk           = 'normal'
  serial_reason  = ''
})
Check 'missing lane not ok' (-not [bool]$missingLane.ok) $missingLane
Check 'missing lane key present' ($missingLane.missing -contains 'lane') $missingLane

$serialRequiredAtoms = @(
  (New-Atom -Slug 'first' -Files @('lib/first.ps1') -ParallelGroup 'pg-first' -TouchSet @('lib/first.ps1')),
  (New-Atom -Slug 'second' -Files @('lib/second.ps1') -ParallelGroup 'pg-second' -TouchSet @('lib/second.ps1'))
)
$serialRequiredReport = Get-WorkpackEligibilityReport -Atoms $serialRequiredAtoms -Context @{ SelectedSlugs = @('first') }
Check 'selected one while parallel possible' ($serialRequiredReport.selected.Count -eq 1) $serialRequiredReport
Check 'serial reason required when selected one without reason' ([bool]$serialRequiredReport.serial_reason_required) $serialRequiredReport

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
