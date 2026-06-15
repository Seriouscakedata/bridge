# test-reflect-selfmodel-smoke.ps1 - verify reflect.ps1 runs self_model_smoke fail-open
param([string]$BridgeRoot = $null)

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:pass = 0

function Assert-ReflectSmoke {
  param(
    [string]$Name,
    [bool]$Condition
  )
  if ($Condition) {
    $script:pass++
    Write-Host "PASS: $Name"
  } else {
    $script:fail++
    Write-Host "FAIL: $Name" -ForegroundColor Red
  }
}

$reflect = Join-Path $BridgeRoot 'reflect.ps1'
$realSmoke = Join-Path $BridgeRoot 'tools\self_model_smoke.ps1'
if (-not (Test-Path -LiteralPath $reflect -PathType Leaf)) {
  Write-Error 'reflect.ps1 not found'
  exit 1
}
if (-not (Test-Path -LiteralPath $realSmoke -PathType Leaf)) {
  Write-Error 'self_model_smoke.ps1 not found'
  exit 1
}

$realOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $realSmoke -BridgeRoot $BridgeRoot 2>&1 | Out-String).Trim()
$realParsed = $null
try { $realParsed = $realOut | ConvertFrom-Json } catch { $realParsed = $null }
Assert-ReflectSmoke 'real self_model_smoke returns parseable JSON' ($null -ne $realParsed)
Assert-ReflectSmoke 'real self_model_smoke reports testPassed' ($realParsed -and [bool]$realParsed.testPassed)

$tmpDir = Join-Path $BridgeRoot '.bridge-runtime\test-reflect-selfmodel-smoke'
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$okSmoke = Join-Path $tmpDir 'fake-smoke-ok.ps1'
$failSmoke = Join-Path $tmpDir 'fake-smoke-fail.ps1'
$bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($okSmoke, "param([string]`$BridgeRoot)`n[pscustomobject]@{ testPassed = `$true } | ConvertTo-Json -Compress`nexit 0`n", $bom)
[System.IO.File]::WriteAllText($failSmoke, "param([string]`$BridgeRoot)`nWrite-Output 'forced smoke failure'`nexit 7`n", $bom)

$beforeWarnings = @()
$decisionsDir = Join-Path $BridgeRoot 'decisions'
if (Test-Path -LiteralPath $decisionsDir -PathType Container) {
  $beforeWarnings = @(Get-ChildItem -LiteralPath $decisionsDir -Filter 'reflect-smoke-*.json' -File | Select-Object -ExpandProperty FullName)
}

$okOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $reflect -SelfModelSmokeSelfTest -SelfModelSmokeScript $okSmoke 2>&1 | Out-String).Trim()
$okExit = $LASTEXITCODE
$okParsed = $null
try { $okParsed = $okOut | ConvertFrom-Json } catch { $okParsed = $null }
$afterOkWarnings = @()
if (Test-Path -LiteralPath $decisionsDir -PathType Container) {
  $afterOkWarnings = @(Get-ChildItem -LiteralPath $decisionsDir -Filter 'reflect-smoke-*.json' -File | Select-Object -ExpandProperty FullName)
}

Assert-ReflectSmoke 'smoke ok self-test exits normally' ($okExit -eq 0)
Assert-ReflectSmoke 'smoke ok is marked passed' ($okParsed -and [bool]$okParsed.passed)
Assert-ReflectSmoke 'smoke ok does not create warning decision' (@($afterOkWarnings).Count -eq @($beforeWarnings).Count)
Assert-ReflectSmoke 'critical modules driver/tools/core are present' ($okParsed -and @($okParsed.missing_modules).Count -eq 0)

$failOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $reflect -SelfModelSmokeSelfTest -SelfModelSmokeScript $failSmoke 2>&1 | Out-String).Trim()
$failExit = $LASTEXITCODE
$failParsed = $null
try { $failParsed = $failOut | ConvertFrom-Json } catch { $failParsed = $null }
$afterFailWarnings = @()
if (Test-Path -LiteralPath $decisionsDir -PathType Container) {
  $afterFailWarnings = @(Get-ChildItem -LiteralPath $decisionsDir -Filter 'reflect-smoke-*.json' -File | Sort-Object LastWriteTimeUtc)
}
$newWarnings = @($afterFailWarnings | Where-Object { $beforeWarnings -notcontains $_.FullName })
$warning = $null
if ($newWarnings.Count -gt 0) {
  $warning = Get-Content -LiteralPath $newWarnings[-1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}

Assert-ReflectSmoke 'smoke fail remains fail-open' ($failExit -eq 0)
Assert-ReflectSmoke 'smoke fail is marked failed' ($failParsed -and -not [bool]$failParsed.passed)
Assert-ReflectSmoke 'smoke fail creates warning decision' ($null -ne $warning)
Assert-ReflectSmoke 'warning records smoke exit code' ($warning -and [int]$warning.smoke_exit_code -eq 7)
Assert-ReflectSmoke 'subsystem count did not decrease' ($warning -and [int]$warning.subsystem_count_after -ge [int]$warning.subsystem_count_before)
Assert-ReflectSmoke 'warning contains missing_modules array' ($warning -and ($warning.PSObject.Properties.Name -contains 'missing_modules'))

if ($script:fail -gt 0) {
  Write-Error "test-reflect-selfmodel-smoke failed: $($script:fail) failed, $($script:pass) passed"
  exit 1
}

Write-Host "PASS: $($script:pass) checks"
