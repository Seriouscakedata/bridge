# VERIFY-COVERS: tools/wiring-audit.ps1
# test-wiring-audit.ps1 -- synthetic regression tests for tools/wiring-audit.ps1.

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'tools\wiring-audit.ps1')

$script:pass = 0
$script:fail = 0

function Assert-WiringAudit {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $false)]$Detail = ''
  )

  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function Write-FixtureFile {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $path = Join-Path $Root $RelativePath
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Path $dir -Force)
  }

  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function New-WiringFixtureRoot {
  param([Parameter(Mandatory = $true)][string]$Name)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-wiring-audit-{0}-{1}" -f $Name, [System.Guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $root -Force)
  return $root
}

function Get-LoadedFileClassification {
  param(
    [Parameter(Mandatory = $true)]$Graph,
    [Parameter(Mandatory = $true)][string]$File
  )

  return @($Graph.file_classifications | Where-Object { [string]$_.file -eq $File } | Select-Object -First 1)[0]
}

function Get-SyntheticWiringStatus {
  param(
    [Parameter(Mandatory = $true)]$Graph,
    [Parameter(Mandatory = $true)][string]$File
  )

  $classification = Get-LoadedFileClassification -Graph $Graph -File $File
  if ($null -ne $classification) {
    return [string]$classification.classification
  }

  $scanned = @($Graph.scanned_files | Where-Object { [string]$_ -eq $File }).Count -gt 0
  if (-not $scanned) {
    return 'MISSING'
  }

  if (@($Graph.dynamic_dispatch_sites).Count -gt 0) {
    return 'UNKNOWN_DYNAMIC'
  }

  return 'DEAD'
}

function Write-WiringAuditWarning {
  param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$Status
  )

  Write-Host ("WARN: real-code wiring candidate {0} => {1}" -f $File, $Status)
}

function Invoke-SyntheticWiringAudit {
  param([Parameter(Mandatory = $true)][string]$Root)

  return Build-WiringAstGraph -Root $Root -WarningOnly
}

$fixtureRoots = New-Object System.Collections.Generic.List[string]

try {
  $beforeRoot = New-WiringFixtureRoot -Name 'before'
  $fixtureRoots.Add($beforeRoot)
  Write-FixtureFile -Root $beforeRoot -RelativePath 'driver.ps1' -Content @'
. (Join-Path $PSScriptRoot 'lib\helper.ps1')
Invoke-WiringFixtureHelper
Write-Host 'driver without reaper wiring'
'@
  Write-FixtureFile -Root $beforeRoot -RelativePath 'lib\helper.ps1' -Content @'
function Invoke-WiringFixtureHelper {
  return 'helper'
}
'@
  Write-FixtureFile -Root $beforeRoot -RelativePath 'lib\backlog-state-reaper.ps1' -Content @'
function Invoke-BacklogStateReaper {
  return 'reaped'
}
'@
  $beforeGraph = Invoke-SyntheticWiringAudit -Root $beforeRoot
  $beforeStatus = Get-SyntheticWiringStatus -Graph $beforeGraph -File 'lib/backlog-state-reaper.ps1'
  Assert-WiringAudit 'reaper before wiring is reported as DEAD' ($beforeStatus -eq 'DEAD') ($beforeGraph | ConvertTo-Json -Compress -Depth 8)

  $afterRoot = New-WiringFixtureRoot -Name 'after'
  $fixtureRoots.Add($afterRoot)
  Write-FixtureFile -Root $afterRoot -RelativePath 'driver.ps1' -Content @'
. (Join-Path $PSScriptRoot 'lib\backlog-state-reaper.ps1')
Invoke-BacklogStateReaper
'@
  Write-FixtureFile -Root $afterRoot -RelativePath 'lib\backlog-state-reaper.ps1' -Content @'
function Invoke-BacklogStateReaper {
  return 'reaped'
}
'@
  $afterGraph = Invoke-SyntheticWiringAudit -Root $afterRoot
  $afterStatus = Get-SyntheticWiringStatus -Graph $afterGraph -File 'lib/backlog-state-reaper.ps1'
  Assert-WiringAudit 'reaper after wiring is not DEAD' ($afterStatus -ne 'DEAD') ($afterGraph | ConvertTo-Json -Compress -Depth 8)
  Assert-WiringAudit 'reaper after wiring is USED' ($afterStatus -eq 'USED') ($afterGraph | ConvertTo-Json -Compress -Depth 8)

  $loadedOnlyRoot = New-WiringFixtureRoot -Name 'loaded-only'
  $fixtureRoots.Add($loadedOnlyRoot)
  Write-FixtureFile -Root $loadedOnlyRoot -RelativePath 'driver.ps1' -Content @'
. (Join-Path $PSScriptRoot 'lib\helper.ps1')
. (Join-Path $PSScriptRoot 'lib\loaded-only.ps1')
Invoke-WiringFixtureHelper
Write-Host 'loaded but not called'
'@
  Write-FixtureFile -Root $loadedOnlyRoot -RelativePath 'lib\helper.ps1' -Content @'
function Invoke-WiringFixtureHelper {
  return 'helper'
}
'@
  Write-FixtureFile -Root $loadedOnlyRoot -RelativePath 'lib\loaded-only.ps1' -Content @'
function Invoke-LoadedOnlyFixture {
  return 'loaded'
}
'@
  $loadedOnlyGraph = Invoke-SyntheticWiringAudit -Root $loadedOnlyRoot
  $loadedOnlyStatus = Get-SyntheticWiringStatus -Graph $loadedOnlyGraph -File 'lib/loaded-only.ps1'
  Assert-WiringAudit 'loaded-only fixture is LOADED_ONLY' ($loadedOnlyStatus -eq 'LOADED_ONLY') ($loadedOnlyGraph | ConvertTo-Json -Compress -Depth 8)
  Assert-WiringAudit 'loaded-only fixture is not USED' ($loadedOnlyStatus -ne 'USED') ($loadedOnlyGraph | ConvertTo-Json -Compress -Depth 8)

  $dynamicRoot = New-WiringFixtureRoot -Name 'dynamic'
  $fixtureRoots.Add($dynamicRoot)
  Write-FixtureFile -Root $dynamicRoot -RelativePath 'driver.ps1' -Content @'
. (Join-Path $PSScriptRoot 'lib\helper.ps1')
Invoke-WiringFixtureHelper
$commandName = 'Invoke-DynamicFixture'
& $commandName
'@
  Write-FixtureFile -Root $dynamicRoot -RelativePath 'lib\helper.ps1' -Content @'
function Invoke-WiringFixtureHelper {
  return 'helper'
}
'@
  Write-FixtureFile -Root $dynamicRoot -RelativePath 'lib\dynamic.ps1' -Content @'
function Invoke-DynamicFixture {
  return 'dynamic'
}
'@
  $dynamicGraph = Invoke-SyntheticWiringAudit -Root $dynamicRoot
  $dynamicStatus = Get-SyntheticWiringStatus -Graph $dynamicGraph -File 'lib/dynamic.ps1'
  Assert-WiringAudit 'dynamic dispatch fixture is UNKNOWN_DYNAMIC' ($dynamicStatus -eq 'UNKNOWN_DYNAMIC') ($dynamicGraph | ConvertTo-Json -Compress -Depth 8)
  Assert-WiringAudit 'dynamic dispatch evidence is present' (@($dynamicGraph.dynamic_dispatch_sites).Count -gt 0) ($dynamicGraph | ConvertTo-Json -Compress -Depth 8)

  $realGraph = Build-WiringAstGraph -Root $repoRoot -WarningOnly
  $realCandidates = New-Object System.Collections.Generic.List[object]
  foreach ($file in @($realGraph.scanned_files | Sort-Object)) {
    if ($file -like 'tmp/*') { continue }

    $status = Get-SyntheticWiringStatus -Graph $realGraph -File $file
    if ($status -eq 'DEAD' -or $status -eq 'LOADED_ONLY') {
      $realCandidates.Add([pscustomobject][ordered]@{
        file = $file
        status = $status
      })
      Write-WiringAuditWarning -File $file -Status $status
    }
  }

  $reaperStatus = Get-SyntheticWiringStatus -Graph $realGraph -File 'lib/backlog-state-reaper.ps1'
  Assert-WiringAudit 'current backlog-state-reaper is not DEAD' ($reaperStatus -ne 'DEAD') ("status={0}" -f $reaperStatus)

  $verifyStatus = Get-SyntheticWiringStatus -Graph $realGraph -File 'lib/verify-selftest.ps1'
  if ($verifyStatus -eq 'DEAD' -or $verifyStatus -eq 'LOADED_ONLY') {
    Write-WiringAuditWarning -File 'lib/verify-selftest.ps1' -Status $verifyStatus
  } else {
    Write-Host ("WARN: current verify-selftest candidate expectation is not active; status={0}" -f $verifyStatus)
  }
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
} finally {
  foreach ($root in @($fixtureRoots.ToArray())) {
    if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root)) {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ("Wiring audit synthetic tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
