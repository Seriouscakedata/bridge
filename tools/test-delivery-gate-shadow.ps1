#Requires -Version 5.1
# test-delivery-gate-shadow.ps1 -- focused tests for Delivery Gate shadow JSONL wiring.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\delivery-gate-shadow.ps1')

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
    # Hang-proof diff: WinPS 5.1 ConvertTo-Json -Depth N hangs (exponential) on multiline strings, so
    # render a string Actual plainly (objects still serialize at low depth) and cap length. A failing
    # check must print a fast, readable diff -- never freeze the whole gate-regression suite on timeout.
    $suffix = ''
    if ($null -ne $Actual) {
      $actualText = if ($Actual -is [string]) { [string]$Actual } else { ($Actual | ConvertTo-Json -Compress -Depth 6) }
      if ($actualText.Length -gt 400) { $actualText = $actualText.Substring(0, 400) + '...(truncated)' }
      $suffix = " actual=" + $actualText
    }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Test-FileHasUtf8Bom {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-FileHasNoUtf8Bom {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function New-TestRoot {
  $path = Join-Path $root ('tmp\delivery-gate-shadow-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Remove-TestRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $resolved) { return }
  $tmpRoot = Join-Path $root 'tmp'
  $resolvedTmp = Resolve-Path -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
  if ($null -eq $resolvedTmp) { return }
  if ($resolved.Path.StartsWith($resolvedTmp.Path)) {
    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
  }
}

$tempRoot = $null

try {
  $tempRoot = New-TestRoot
  $facts = New-DeliveryGateInputFacts `
    -BridgeRoot $tempRoot `
    -TaskText 'bridge-self acceptance evidence: ParseFile, tests, smoke verified' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('src/app.js'); text = 'verified' }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  $result = Get-DeliveryGateResult -InputFacts $facts
  $write = Write-DeliveryGateShadowRecord `
    -BridgeRoot $tempRoot `
    -Channel 'main' `
    -TaskId 'task-shadow-test' `
    -TaskText 'shadow writer test' `
    -BaseCommit 'base123' `
    -HeadCommit 'head456' `
    -Facts $facts `
    -Result $result `
    -Note 'test note'

  Check 'writer returns ok=true' ([bool]$write.ok) $write
  Check 'writer returns shadow path' (-not [string]::IsNullOrWhiteSpace([string]$write.path) -and (Test-Path -LiteralPath ([string]$write.path))) $write
  Check 'shadow JSONL is UTF-8 without BOM' (Test-FileHasNoUtf8Bom -Path ([string]$write.path)) $write.path

  $lines = [System.IO.File]::ReadAllLines([string]$write.path, (New-Object System.Text.UTF8Encoding($false)))
  Check 'writer writes one JSONL line' ($lines.Count -eq 1) $lines
  $record = $lines[0] | ConvertFrom-Json
  Check 'JSON has channel' ([string]$record.channel -eq 'main') $record
  Check 'JSON has task id' ([string]$record.task_id -eq 'task-shadow-test') $record
  Check 'JSON has facts object' ($null -ne $record.facts -and $null -ne $record.facts.repo_clean) $record
  Check 'JSON has valid result' ($null -ne $record.result -and [bool]$record.result.ok -and [bool]$record.result.release_allowed) $record

  $badThrew = $false
  $badWrite = $null
  try {
    $badWrite = Write-DeliveryGateShadowRecord -BridgeRoot '' -Channel 'main' -TaskId 'bad' -TaskText 'bad' -BaseCommit '' -HeadCommit '' -Facts $facts -Result $result -Note 'bad input'
  } catch {
    $badThrew = $true
  }
  Check 'writer fail-open invalid input does not throw' (-not $badThrew)
  Check 'writer fail-open invalid input returns ok=false' ($null -ne $badWrite -and -not [bool]$badWrite.ok -and -not [string]::IsNullOrWhiteSpace([string]$badWrite.error)) $badWrite

  $driver = Get-Content -LiteralPath (Join-Path $root 'driver.ps1') -Raw
  # The loop-completion subsystem was split into 86-loop-completion*.ps1 (a thin dispatcher that dot-
  # sources -checks / -actions / -cleanup). Read the whole subsystem so these wiring assertions track
  # the delivery-gate-shadow block wherever the refactor places it, not the now-thin monolith path.
  $completion = ((Get-ChildItem -LiteralPath (Join-Path $root 'driver') -Filter '86-loop-completion*.ps1' -File | Sort-Object Name) | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
  Check 'driver loads delivery-gate-shadow writer' ($driver -match 'delivery-gate-shadow\.ps1') $driver
  Check 'completion builds delivery gate facts' ($completion -match 'New-DeliveryGateInputFacts') $completion
  Check 'completion binds delivery gate acceptance fact' ($completion -match 'Get-DeliveryGateAcceptanceFact') $completion
  Check 'completion evaluates delivery gate result' ($completion -match 'Get-DeliveryGateResult') $completion
  Check 'completion writes delivery gate shadow record' ($completion -match 'Write-DeliveryGateShadowRecord') $completion

  $start = $completion.IndexOf('# Delivery gate shadow:')
  $end = if ($start -ge 0) { $completion.IndexOf('# Delivery gate shadow end.', $start) } else { -1 }
  $block = if ($start -ge 0 -and $end -gt $start) { $completion.Substring($start, $end - $start) } else { '' }
  Check 'shadow safety block marker present' (-not [string]::IsNullOrWhiteSpace($block))
  Check 'shadow block does not set plannerStatus' ($block -notmatch '\$plannerStatus\s*=')
  Check 'shadow block does not set task failure' ($block -notmatch '\bSet-TaskLastFailure\b')
  Check 'shadow block does not continue' ($block -notmatch '\bcontinue\b')
  Check 'shadow block preserves dynamic acceptance binding for final facts' ($block -match '-AcceptancePassed\s+\$dgAcceptancePassed')
  # B16-1: 86-loop-completion must reference Invoke-CanaryCycle
  Check 'B16-1 completion references Invoke-CanaryCycle' ($completion -match 'Invoke-CanaryCycle') $completion
  # B16-2: completion must pass -CanaryPassed to New-DeliveryGateInputFacts
  Check 'B16-2 completion passes -CanaryPassed' ($completion -match '-CanaryPassed') $completion
  # B16-3: canary in shadow must not affect plannerStatus or task failure
  Check 'B16-3 canary result is shadow-only, no plannerStatus coupling' ($completion -notmatch 'plannerStatus.*canary|canary.*plannerStatus') $completion

  Check 'writer ps1 has UTF-8 BOM' (Test-FileHasUtf8Bom -Path (Join-Path $root 'lib\delivery-gate-shadow.ps1'))
  Check 'test ps1 has UTF-8 BOM' (Test-FileHasUtf8Bom -Path (Join-Path $root 'tools\test-delivery-gate-shadow.ps1'))
} finally {
  if ($null -ne $tempRoot) { Remove-TestRoot -Path $tempRoot }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
