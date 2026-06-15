# test-reflect-selfmodel-smoke.ps1 - verify self_model_smoke.ps1 returns testPassed
param([string]$BridgeRoot = $null)

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Split-Path -Parent $PSScriptRoot }

$script = Join-Path $BridgeRoot 'tools\self_model_smoke.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
  Write-Error 'self_model_smoke.ps1 not found'
  exit 1
}

$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $script -BridgeRoot $BridgeRoot 2>&1 | Out-String).Trim()
$parsed = $null
try { $parsed = $out | ConvertFrom-Json } catch { $parsed = $null }
if (-not $parsed) {
  Write-Error "smoke parse failed: $out"
  exit 1
}
if (-not [bool]$parsed.testPassed) {
  Write-Error "smoke testPassed=false: $out"
  exit 1
}

foreach ($field in @('registryUnchanged','stateUnchanged','modulesSection')) {
  if ($parsed.PSObject.Properties.Name -notcontains $field) {
    Write-Error "missing field $field"
    exit 1
  }
}

Write-Host "self_model_smoke OK: packBytes=$($parsed.packBytes)"
Write-Host 'PASS: 4 checks'
