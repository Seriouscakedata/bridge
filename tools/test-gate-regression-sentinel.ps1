#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$diag = Join-Path $repoRoot 'tools\diag\gate-regression-sentinel-selftest.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $diag
exit $LASTEXITCODE
