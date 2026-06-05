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
