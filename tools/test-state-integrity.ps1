#Requires -Version 5.1
[CmdletBinding()]
param([string]$BridgeRoot = '')

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
  $BridgeRoot = Split-Path -Parent $PSScriptRoot
}

function Fail-Integrity {
  param([Parameter(Mandatory=$true)][string]$Reason)
  Write-Host ("INTEGRITY FAIL: {0}" -f $Reason)
  exit 1
}

function Test-IntegrityPs1Parse {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Name
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail-Integrity ("{0} not found: {1}" -f $Name, $Path)
  }

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    $first = $errors[0]
    Fail-Integrity ("{0} parse failed at line {1}: {2}" -f $Name, $first.Extent.StartLineNumber, $first.Message)
  }
  Write-Host ("OK: {0} parses" -f $Name)
}

if (-not (Test-Path -LiteralPath $BridgeRoot -PathType Container)) {
  Fail-Integrity ("BridgeRoot not found: {0}" -f $BridgeRoot)
}

$commonPath = Join-Path $BridgeRoot 'lib\common.ps1'
Test-IntegrityPs1Parse -Path $commonPath -Name 'lib\common.ps1'

$statePath = ''
try {
  . $commonPath
  $statePath = [string](Get-StatePath)
} catch {
  $statePath = ''
}
if ([string]::IsNullOrWhiteSpace($statePath)) {
  $statePath = Join-Path $BridgeRoot 'channels\main\state.json'
}
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  Fail-Integrity ("state.json not found: {0}" -f $statePath)
}
try {
  $stateText = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop
  [void]($stateText | ConvertFrom-Json -ErrorAction Stop)
  Write-Host 'OK: state.json is valid JSON'
} catch {
  Fail-Integrity ("state.json invalid JSON: {0}" -f (($_.Exception.Message -replace '\s+',' ').Trim()))
}

$driverPath = Join-Path $BridgeRoot 'driver.ps1'
Test-IntegrityPs1Parse -Path $driverPath -Name 'driver.ps1'

Write-Host 'INTEGRITY OK'
exit 0
