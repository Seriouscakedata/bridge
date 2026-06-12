#Requires -Version 5.1
# Test: Invoke-BatchWithPerTaskTimeout
param([switch]$Quiet)
$bridgeRoot = Split-Path $PSScriptRoot -Parent
. "$bridgeRoot\lib\batch-timeout.ps1"
$pass = Test-BatchTimeoutSelfTest
if ($pass) { Write-Host "PASS: batch-timeout selftest OK" } else { Write-Host "FAIL: batch-timeout selftest FAILED"; exit 1 }
exit 0