#Requires -Version 5.1
param(
  [string]$Channel = '',
  [string]$ProjectRoot = '',
  [switch]$Force,
  [switch]$CreateFixTask
)

$ErrorActionPreference = 'Stop'
$bridgeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $bridgeRoot 'lib\common.ps1')
. (Join-Path $bridgeRoot 'lib\project-acceptance.ps1')

$env:PROJECT_ACCEPTANCE_TRACE_STDERR = '1'

try {
  if ($Force) {
    $result = Invoke-ProjectAcceptance -Channel $Channel -ProjectRoot $ProjectRoot -Trigger 'manual-force' -CreateFixTask:$CreateFixTask
  } else {
    $result = Start-ProjectAcceptanceIfDue -Channel $Channel -Trigger 'manual' -Force:$Force
  }

  $result | ConvertTo-Json -Depth 10
  if ($result -and $result.ran -and -not $result.ok) { exit 1 }
  exit 0
} catch {
  [pscustomobject]@{
    ran = $true
    ok = $false
    status = 'FAIL'
    reason = 'project-acceptance-tool-exception'
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 6
  exit 1
}
