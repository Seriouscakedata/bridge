#Requires -Version 5.1
# test-workpack-scope-contract.ps1 -- explicit scope contract coverage for backlog workpack planning.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\backlog.ps1')

$script:pass = 0
$script:fail = 0

function Assert-True {
  param([bool]$Condition, [string]$Message, $Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Message) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = ''
    if ($null -ne $Actual) { $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 8) }
    Write-Host ("FAIL " + $Message + $suffix) -ForegroundColor Red
  }
}

function New-TestItem {
  param(
    [string]$Text = '',
    [string]$Task = '',
    $ExpectedFiles = $null,
    $ForbiddenFiles = $null,
    $ReadOnlyContext = $null,
    $RiskArea = $null
  )
  $item = [pscustomobject]@{
    id = [guid]::NewGuid().ToString('N')
    text = $Text
    task = $Task
    status = 'approved'
  }
  if ($null -ne $ExpectedFiles) { $item | Add-Member -NotePropertyName expected_files -NotePropertyValue $ExpectedFiles -Force }
  if ($null -ne $ForbiddenFiles) { $item | Add-Member -NotePropertyName forbidden_files -NotePropertyValue $ForbiddenFiles -Force }
  if ($null -ne $ReadOnlyContext) { $item | Add-Member -NotePropertyName read_only_context -NotePropertyValue $ReadOnlyContext -Force }
  if ($null -ne $RiskArea) { $item | Add-Member -NotePropertyName risk_area -NotePropertyValue $RiskArea -Force }
  return $item
}

$metadataItem = New-TestItem `
  -Text 'Mention supervisor.ps1, watchdog.ps1, server.ps1, driver.ps1 and control/restart.flag only as forbidden context.' `
  -ExpectedFiles @('lib/backlog-workpack.ps1', 'tools/test-workpack-scope-contract.ps1') `
  -ForbiddenFiles @('supervisor.ps1', 'watchdog.ps1', 'server.ps1', 'driver.ps1', 'control/*') `
  -ReadOnlyContext @('docs/reference.md') `
  -RiskArea 'backlog'
$metadataScope = Get-BacklogTaskScopeContract -Item $metadataItem
$metadataClass = Get-BacklogWorkpackClassification -Item $metadataItem
$metadataTouches = Get-BacklogWorkpackItemTouches -Item $metadataItem
Assert-True ($metadataScope.has_explicit_expected) 'metadata expected_files marked explicit' $metadataScope
Assert-True (@($metadataScope.expected_files) -contains 'lib/backlog-workpack.ps1') 'metadata expected_files parsed lib path' $metadataScope
Assert-True (@($metadataClass.touch_set) -contains 'lib/backlog-workpack.ps1') 'metadata expected_files enters classification touch_set' $metadataClass
Assert-True (@($metadataTouches) -contains 'tools/test-workpack-scope-contract.ps1') 'metadata expected_files enters item touches' $metadataTouches
foreach ($protected in @('supervisor.ps1','watchdog.ps1','server.ps1','driver.ps1','control/restart.flag')) {
  Assert-True (-not (@($metadataClass.touch_set) -contains $protected)) ("metadata protected mention excluded from touch_set: {0}" -f $protected) $metadataClass
  Assert-True (-not (@($metadataTouches) -contains $protected)) ("metadata protected mention excluded from item touches: {0}" -f $protected) $metadataTouches
}
Assert-True ([string]$metadataClass.conflict_group -ne 'safety') 'metadata protected body mentions do not force safety conflict group' $metadataClass

$sectionText = @'
Task body mentions supervisor.ps1 and server.ps1 as examples only.
EXPECTED_FILES:
- lib/backlog-workpack.ps1
- tools/test-workpack-scope-contract.ps1
FORBIDDEN_FILES:
- supervisor.ps1
- watchdog.ps1
- server.ps1
- driver.ps1
- control/*
READ_ONLY_CONTEXT:
- docs/design.md
- memory/context.md
RISK_AREA:
- backlog
Acceptance:
- protected paths stay excluded
'@
$sectionItem = New-TestItem -Text $sectionText
$sectionScope = Get-BacklogTaskScopeContract -Item $sectionItem
$sectionClass = Get-BacklogWorkpackClassification -Item $sectionItem
$sectionTouches = Get-BacklogWorkpackItemTouches -Item $sectionItem
Assert-True ($sectionScope.has_explicit_expected) 'text section expected_files marked explicit' $sectionScope
Assert-True (@($sectionScope.expected_files) -contains 'tools/test-workpack-scope-contract.ps1') 'text section expected_files parsed bullet path' $sectionScope
Assert-True (@($sectionScope.forbidden_files) -contains 'control/*') 'text section forbidden glob parsed' $sectionScope
Assert-True (@($sectionScope.read_only_context) -contains 'docs/design.md') 'text section read_only_context parsed' $sectionScope
Assert-True (@($sectionScope.risk_area) -contains 'backlog') 'text section risk_area parsed' $sectionScope
Assert-True (@($sectionClass.touch_set) -contains 'lib/backlog-workpack.ps1') 'text section expected_files enters classification touch_set' $sectionClass
foreach ($protected in @('supervisor.ps1','watchdog.ps1','server.ps1','driver.ps1','control/restart.flag','docs/design.md')) {
  Assert-True (-not (@($sectionClass.touch_set) -contains $protected)) ("text section forbidden/read-only excluded from touch_set: {0}" -f $protected) $sectionClass
  Assert-True (-not (@($sectionTouches) -contains $protected)) ("text section forbidden/read-only excluded from item touches: {0}" -f $protected) $sectionTouches
}
Assert-True ([string]$sectionClass.conflict_group -ne 'safety') 'text section protected body mentions do not force safety conflict group' $sectionClass

$forbiddenOnlyItem = New-TestItem `
  -Text 'Update docs/scope-contract.md while referencing supervisor.ps1 and control/restart.flag as forbidden examples.' `
  -ForbiddenFiles @('supervisor.ps1', 'control/*') `
  -ReadOnlyContext @('server.ps1')
$forbiddenOnlyClass = Get-BacklogWorkpackClassification -Item $forbiddenOnlyItem
$forbiddenOnlyTouches = Get-BacklogWorkpackItemTouches -Item $forbiddenOnlyItem
Assert-True (-not (@($forbiddenOnlyClass.touch_set) -contains 'supervisor.ps1')) 'forbidden-only metadata excluded from inferred touch_set' $forbiddenOnlyClass
Assert-True (-not (@($forbiddenOnlyClass.touch_set) -contains 'control/restart.flag')) 'forbidden glob excluded from inferred touch_set' $forbiddenOnlyClass
Assert-True (-not (@($forbiddenOnlyTouches) -contains 'server.ps1')) 'read_only_context excluded from item touches' $forbiddenOnlyTouches
Assert-True ([string]$forbiddenOnlyClass.conflict_group -ne 'safety') 'forbidden-only protected paths do not force safety conflict group' $forbiddenOnlyClass

$negativeGuardText = @'
Update tools/deep-audit-agent.ps1 to improve audit tooling.
Do not edit supervisor.ps1, watchdog.ps1, server.ps1, driver.ps1, or control/restart.flag.
Forbidden examples / exclusions: supervisor.ps1, watchdog.ps1, server.ps1, driver.ps1, control/restart.flag.
Read-only context control/restart.flag and watchdog.ps1.
Only examples / exclusions: supervisor.ps1, watchdog.ps1, server.ps1, driver.ps1, control/restart.flag.
'@
$negativeGuardItem = New-TestItem -Text $negativeGuardText
$negativeGuardClass = Get-BacklogWorkpackClassification -Item $negativeGuardItem
$negativeGuardTouches = Get-BacklogWorkpackItemTouches -Item $negativeGuardItem
$negativeGuardItem | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-negative-guard' -Force
$negativeGuardItem | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$negativeGuardClass.conflict_group) -Force
$negativeGuardItem | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($negativeGuardClass.touch_set) -Force
$negativeGuardEligibility = Get-BacklogWorkpackExecEligibility -Item $negativeGuardItem -Config ([pscustomobject]@{ enabled = $true; includeProtected = $false })
Assert-True (@($negativeGuardClass.touch_set) -contains 'tools/deep-audit-agent.ps1') 'negative guard keeps the editable audit tools target' $negativeGuardClass
Assert-True ([string]$negativeGuardClass.conflict_group -eq 'audit') ("negative guard should classify as audit, got {0}" -f [string]$negativeGuardClass.conflict_group) $negativeGuardClass
Assert-True ([string]$negativeGuardClass.lane_hint -ne 'serial:safety') 'negative guard should not use safety lane' $negativeGuardClass
Assert-True ([string]$negativeGuardClass.conflict_group -notin @('core','safety')) 'negative guard should not be protected-dominant class' $negativeGuardClass
foreach ($protected in @('supervisor.ps1','watchdog.ps1','server.ps1','driver.ps1','control/restart.flag')) {
  Assert-True (-not (@($negativeGuardClass.touch_set) -contains $protected)) ("negative guard excludes protected touch_set path: {0}" -f $protected) $negativeGuardClass
  Assert-True (-not (@($negativeGuardTouches) -contains $protected)) ("negative guard excludes protected item touch path: {0}" -f $protected) $negativeGuardTouches
}
Assert-True (-not (Test-BacklogWorkpackTouchesBridgeControlPlane -Item $negativeGuardItem)) 'negative guard should not require control-plane admission' $negativeGuardItem
Assert-True ([bool]$negativeGuardEligibility.eligible) ("negative guard should be eligible, got {0}" -f [string]$negativeGuardEligibility.reason) $negativeGuardEligibility
Assert-True ([string]$negativeGuardEligibility.reason -ne 'protected-dominant') 'negative guard should not be blocked as protected-dominant' $negativeGuardEligibility

$positiveProtectedItem = New-TestItem -Text 'Edit driver.ps1, server.ps1, and control/restart.flag to update bridge control-plane startup behavior.'
$positiveProtectedClass = Get-BacklogWorkpackClassification -Item $positiveProtectedItem
$positiveProtectedItem | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-positive-protected' -Force
$positiveProtectedItem | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$positiveProtectedClass.conflict_group) -Force
$positiveProtectedItem | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($positiveProtectedClass.touch_set) -Force
$positiveProtectedEligibility = Get-BacklogWorkpackExecEligibility -Item $positiveProtectedItem -Config ([pscustomobject]@{ enabled = $true; includeProtected = $false })
Assert-True (@($positiveProtectedClass.touch_set) -contains 'driver.ps1') 'positive protected request keeps driver.ps1 touch' $positiveProtectedClass
Assert-True (@($positiveProtectedClass.touch_set) -contains 'server.ps1') 'positive protected request keeps server.ps1 touch' $positiveProtectedClass
Assert-True (@($positiveProtectedClass.touch_set) -contains 'control/restart.flag') 'positive protected request keeps control path touch' $positiveProtectedClass
Assert-True (@('core','safety') -contains [string]$positiveProtectedClass.conflict_group) 'positive protected request stays protected class' $positiveProtectedClass
Assert-True (Test-BacklogWorkpackTouchesBridgeControlPlane -Item $positiveProtectedItem) 'positive protected request requires control-plane admission' $positiveProtectedItem
Assert-True ([string]$positiveProtectedEligibility.reason -eq 'control-plane-admission-required') ("positive protected request should be admission-blocked, got {0}" -f [string]$positiveProtectedEligibility.reason) $positiveProtectedEligibility

$fallbackItem = New-TestItem -Text 'Update tools/audit.ps1 to improve audit scenario logging.'
$fallbackScope = Get-BacklogTaskScopeContract -Item $fallbackItem
$fallbackClass = Get-BacklogWorkpackClassification -Item $fallbackItem
$fallbackTouches = Get-BacklogWorkpackItemTouches -Item $fallbackItem
Assert-True (-not $fallbackScope.has_explicit_expected) 'fallback item has no explicit expected_files' $fallbackScope
Assert-True (@($fallbackClass.touch_set).Count -gt 0) 'fallback inference still produces classification touch_set' $fallbackClass
Assert-True (@($fallbackClass.touch_set) -contains 'tools/audit.ps1') 'fallback inference keeps mentioned file' $fallbackClass
Assert-True (@($fallbackTouches).Count -gt 0) 'fallback inference still produces item touches' $fallbackTouches

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
