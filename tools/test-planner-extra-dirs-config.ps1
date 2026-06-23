#Requires -Version 5.1
# Verifies that planner.extraDirs grants Claude planner access to bridge-projects.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$settingsPath = Join-Path $root 'settings.json'
$driverPath = Join-Path $root 'driver\40-agent-invoke.ps1'
$expectedExtraDir = 'C:\Users\rafie\bridge-projects'
$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

try {
  Check 'settings.json exists' (Test-Path -LiteralPath $settingsPath) $settingsPath
  Check 'driver/40-agent-invoke.ps1 exists' (Test-Path -LiteralPath $driverPath) $driverPath

  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  $extraDirs = @($settings.'planner.extraDirs')
  Check 'planner.extraDirs contains bridge-projects' ($extraDirs -contains $expectedExtraDir) $extraDirs

  $driverText = Get-Content -Raw -LiteralPath $driverPath
  Check 'planner config reads extraDirs' ($driverText -match "\.planner\.extraDirs") $null
  Check 'planner appends extraDirs as add-dir args' ($driverText -match "foreach\s*\(\s*\`$ed\s+in\s+\`$plannerExtraDirs\s*\).*?\`$claudeArgs\s*\+=\s*@\(\s*'--add-dir'\s*,\s*\`$ed\s*\)") $null

  if ($script:fail -gt 0) { throw "$script:fail checks failed" }
  Write-Host ("OK planner extraDirs config checks passed: " + $script:pass)
  exit 0
} catch {
  Write-Host ("ERR " + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
