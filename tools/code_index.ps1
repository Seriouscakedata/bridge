param([string]$ProjectRoot = '')

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Get-BridgeRoot }

$slug = Get-ProjectSlug -Root $ProjectRoot
$result = Index-CodeBase -ProjectRoot $ProjectRoot -Slug $slug
$stats = Get-CodeStats -Slug $slug

Write-Output ("project={0}" -f $result.project)
Write-Output ("files={0}" -f $result.files)
Write-Output ("symbols={0}" -f $result.symbols)
Write-Output ("embedded={0}" -f $result.embedded)
Write-Output ("skipped={0}" -f $result.skipped)
Write-Output ("failed={0}" -f $result.failed)
Write-Output ("records={0}" -f $stats.count)
