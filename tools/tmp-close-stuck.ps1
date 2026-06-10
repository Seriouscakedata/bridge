# tmp: mark the 2 genuinely-done stuck batch tasks 'done' (both work committed+verified).
# NO restart. Next natural supervisor-restart's resume-validation will abort the batch
# (done is in the abort list) -> driver claims 86e18028 fresh. ASCII-only -> no BOM.
$ErrorActionPreference = 'Stop'
$env:BRIDGE_CHANNEL = 'main'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog.ps1')

$C = 'c8180bf418e4496a8b3e4d5bc9b9c4b5'  # batch-finalize-partial: verified 38/0, committed e504c50, ACTIVE
$M = '11e8402945cf48e6981eb37ae0bb7589'  # marker task: committed 8efa23c, bridge checks passed
[void](Set-Idea -Id $C -Status 'done' -Reason 'operator: verified done - parse 0 / test 38-0 / SelfTest OK, committed e504c50 and ACTIVE in HEAD; batch could not flip status (resume-close loop). NO restart - letting natural supervisor-restart resume-validation abort the batch.')
[void](Set-Idea -Id $M -Status 'done' -Reason 'operator: verified done - committed 8efa23c, bridge gate-check+critic+DONE-gate all passed (COVERED); batch could not flip status. NO restart.')
$bl = @(Get-Backlog)
foreach ($id in @($C,$M)) { $it = $bl | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1; if ($it) { Write-Host ($id.Substring(0,8) + ' -> ' + $it.status) } }
