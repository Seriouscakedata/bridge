#Requires -Version 5.1
# operator-delegate.ps1 -- the conductor (Claude) hands the bridge a batch of well-specified tasks.
# They enter the queue tagged 'operator' (claimed FIRST, ahead of audit/auto ideas), pre-approved,
# with a shared batch id so the pulse can track them. This is how hundreds of tasks reach the worker
# pool under my orchestration with a single handle to watch them by.
#   -Tasks @('task1','task2')           inline tasks
#   -TasksFile path                     one task per line (UTF-8)
#   -Label 'refactor-auth'              human label, prefixed as [Label i/N]
param([string[]]$Tasks = @(), [string]$TasksJson = '', [string]$TasksFile = '', [string]$Label = '', [string]$Project = '', [string]$Scope = 'bridge')
$ErrorActionPreference = 'Stop'
# Load the engine library from THIS script's location (tools/ -> bridge/), so the code is always
# found; the DATA root (where the backlog is written) is resolved by Get-BridgeRoot.
$libRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $libRoot 'lib\common.ps1')
# -TasksJson is the robust way to pass an ARRAY across the CLI boundary (`powershell -File` mangles
# `-Tasks @('a','b')` into one arg). Pass a JSON array of strings.
if ($TasksJson) { try { $Tasks += @([object[]]($TasksJson | ConvertFrom-Json) | ForEach-Object { [string]$_ }) } catch { Write-Host ("operator-delegate: bad -TasksJson: " + $_.Exception.Message); exit 1 } }
if ($TasksFile -and (Test-Path $TasksFile)) {
  $Tasks += @(Get-Content -LiteralPath $TasksFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$Tasks = @($Tasks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($Tasks.Count -eq 0) { Write-Host 'operator-delegate: no tasks given'; exit 1 }
$r = Add-OperatorBatch -Tasks $Tasks -BatchLabel $Label -Project $Project -Scope $Scope
if ($r) { Write-Host ("operator-delegate: queued batch " + $r.batchId + " -- " + $r.count + " task(s) at operator priority.") }
else { Write-Host 'operator-delegate: delegation failed'; exit 1 }
