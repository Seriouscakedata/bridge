# Smoke-test: supervisor max concurrent drivers limit
param()
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$root = Get-BridgeRoot
$cfg  = Get-BridgeConfig

$testPassed = $true
$results = @{}

# 1. Config has the key
$cfgVal = $cfg.supervisor.maxConcurrentDrivers
$results['configKeyPresent'] = ($null -ne $cfgVal)
if ($null -eq $cfgVal) { $testPassed = $false; Write-Host "FAIL: maxConcurrentDrivers missing from config" }

# 2. Config value is positive integer
$parsed = 0
$results['configValueValid'] = ([int]::TryParse(([string]$cfgVal), [ref]$parsed) -and $parsed -gt 0)
if (-not $results['configValueValid']) { $testPassed = $false; Write-Host "FAIL: maxConcurrentDrivers is not a positive integer: $cfgVal" }

# 3. supervisor.ps1 contains the limit-check code
$supPath = Join-Path $root 'supervisor.ps1'
$supContent = Get-Content -LiteralPath $supPath -Raw -Encoding UTF8
$results['limitCheckPresent'] = ($supContent -like '*maxConcurrentDrivers*')
if (-not $results['limitCheckPresent']) { $testPassed = $false; Write-Host "FAIL: maxConcurrentDrivers not found in supervisor.ps1" }

# 4. supervisor.ps1 contains the activeDriverCount counter
$results['counterPresent'] = ($supContent -like '*activeDriverCount*')
if (-not $results['counterPresent']) { $testPassed = $false; Write-Host "FAIL: activeDriverCount not found in supervisor.ps1" }

# 5. Parse check
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($supPath, [ref]$tokens, [ref]$errors) | Out-Null
$results['supervisorParseOk'] = ($errors.Count -eq 0)
if ($errors.Count -gt 0) { $testPassed = $false; Write-Host ("FAIL: supervisor.ps1 parse errors: " + ($errors | Select-Object -First 3 | Out-String)) }

$output = [ordered]@{
  testPassed         = $testPassed
  configKeyPresent   = $results['configKeyPresent']
  configValueValid   = $results['configValueValid']
  configValue        = $cfgVal
  limitCheckPresent  = $results['limitCheckPresent']
  counterPresent     = $results['counterPresent']
  supervisorParseOk  = $results['supervisorParseOk']
}
Write-Output ($output | ConvertTo-Json -Depth 3)
