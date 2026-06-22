#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$bridgeRoot = Split-Path -Parent $PSScriptRoot
$smoke = Join-Path $bridgeRoot 'smoke.ps1'

if (-not (Test-Path -LiteralPath $smoke)) {
  throw "Bridge smoke script not found: $smoke"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $smoke
exit $LASTEXITCODE
