$ErrorActionPreference = 'Stop'
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1'
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\channels.ps1'

Write-Host '== Scope main =='
$m = Get-EffectiveScope -Slug 'main'
$m | Format-List slug, is_bridge, project_root, features_registry, features_exists, memory_store, memory_exists

Write-Host '== Scope travel =='
$t = Get-EffectiveScope -Slug 'travel'
$t | Format-List slug, is_bridge, project_root, features_registry, features_exists, memory_store, memory_exists

Write-Host '== Throw on invalid slug =='
try { Get-EffectiveScope -Slug '..\..' | Out-Null; Write-Host 'FAIL: should throw' }
catch { Write-Host ('OK throw: ' + $_.Exception.Message) }

Write-Host '== Throw on ghost =='
try { Get-EffectiveScope -Slug 'ghost-xyz' | Out-Null; Write-Host 'FAIL: should throw' }
catch { Write-Host ('OK throw: ' + $_.Exception.Message) }

Write-Host '== ENV pass-through (valid) =='
$env:BRIDGE_CHANNEL = 'travel'
$slug = Get-EffectiveChannel
Write-Host ('ENV=travel -> ' + $slug)

Write-Host '== ENV pass-through (traversal) =='
$env:BRIDGE_CHANNEL = '../../../etc'
$slug = Get-EffectiveChannel
Write-Host ('ENV=traversal -> ' + $slug)

Write-Host '== ENV ghost =='
$env:BRIDGE_CHANNEL = 'ghost'
$slug = Get-EffectiveChannel
Write-Host ('ENV=ghost -> ' + $slug)

$env:BRIDGE_CHANNEL = $null
Write-Host '== ENV empty =='
$slug = Get-EffectiveChannel
Write-Host ('ENV=empty -> ' + $slug)
