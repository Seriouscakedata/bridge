[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
try {
  . (Join-Path $root 'lib\channels.ps1')
} catch {}
. (Join-Path $root 'lib\canary.ps1')

if ($DryRun) {
  $gate = Test-CanaryIdleGate
  Write-Output ("idle={0} reason={1}" -f $gate.idle, $gate.reason)
  exit 0
}

if ($Force) {
  $cycle = Invoke-CanaryCycle -Force -NoStateUpdate
} else {
  $cycle = Invoke-CanaryCycle
}

Write-Output ($cycle | ConvertTo-Json -Depth 10 -Compress)
