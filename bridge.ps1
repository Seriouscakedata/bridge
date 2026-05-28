$ErrorActionPreference = 'Stop'

$BridgeArgs = @($args)

if ($BridgeArgs.Count -gt 0 -and [string]::Equals($BridgeArgs[0], 'replay', [System.StringComparison]::OrdinalIgnoreCase)) {
  $rest = @()
  if ($BridgeArgs.Count -gt 1) {
    $rest = @($BridgeArgs[1..($BridgeArgs.Count - 1)])
  }
  & (Join-Path $PSScriptRoot 'tools\replay-cli.ps1') @rest
  exit 0
}

$cmd = ''
if ($BridgeArgs.Count -gt 0) { $cmd = [string]$BridgeArgs[0] }
Write-Host "Unknown subcommand: $cmd"
Write-Host "Available: replay"
exit 1
