$ErrorActionPreference = 'Stop'
Set-Location 'C:\Users\rafie\OneDrive\Documents\bridge'
. .\lib\common.ps1
. .\lib\channels.ps1
. .\lib\features.ps1
. .\lib\memory.ps1

function Show-Header($t) { Write-Host ("`n=== $t ===") }

Show-Header 'A1: scope main'
$m = Get-EffectiveScope -Slug main
[pscustomobject]@{
    is_bridge        = $m.is_bridge
    features_registry= $m.features_registry
    memory_store     = $m.memory_store
    features_exists  = $m.features_exists
    project_root     = $m.project_root
} | Format-List

Show-Header 'A2: scope travel'
$t = Get-EffectiveScope -Slug travel
[pscustomobject]@{
    is_bridge        = $t.is_bridge
    features_registry= $t.features_registry
    memory_store     = $t.memory_store
    features_exists  = $t.features_exists
    project_root     = $t.project_root
} | Format-List

Show-Header 'A3/A4: invalid/ghost slug throws'
try { Get-EffectiveScope -Slug '..\..' | Out-Null; Write-Host 'FAIL' } catch { Write-Host "OK throw: $($_.Exception.Message)" }
try { Get-EffectiveScope -Slug 'ghost-channel' | Out-Null; Write-Host 'FAIL' } catch { Write-Host "OK throw: $($_.Exception.Message)" }

Show-Header 'A5/A6/A7: ENV pass-through'
$env:BRIDGE_CHANNEL = 'travel'
Write-Host "BRIDGE_CHANNEL=travel        -> $(Get-EffectiveChannel)"
$env:BRIDGE_CHANNEL = '../../../etc'
Write-Host "BRIDGE_CHANNEL=../../../etc  -> $(Get-EffectiveChannel)"
$env:BRIDGE_CHANNEL = 'ghost'
Write-Host "BRIDGE_CHANNEL=ghost         -> $(Get-EffectiveChannel)"
$env:BRIDGE_CHANNEL = $null

Show-Header 'A8: features fail-closed in travel scope'
$env:BRIDGE_CHANNEL = 'travel'
$scope = Get-FeatureScope
Write-Host "scope.slug=$($scope.slug) features_exists=$($scope.features_exists)"
$reg = Get-FeatureRegistry
Write-Host "Get-FeatureRegistry travel.count = $($reg.Count) (expect 0)"
try {
    Add-Feature -Id 'verify-fail-closed' -Name 'verify' -Description 'should throw' | Out-Null
    Write-Host 'FAIL: Add-Feature did not throw'
} catch {
    Write-Host "OK throw: $($_.Exception.Message)"
}
Write-Host "channels/travel/features exists after attempt: $(Test-Path channels\travel\features)"
$env:BRIDGE_CHANNEL = $null

Show-Header 'A9: memory write guard in travel scope'
$env:BRIDGE_CHANNEL = 'travel'
Write-Host "current memory channel: $(Get-CurrentMemoryChannel)"
try {
    Assert-MemoryWriteAllowed -TargetSlug 'main'
    Write-Host 'FAIL: Assert-MemoryWriteAllowed did not throw'
} catch {
    Write-Host "OK throw: $($_.Exception.Message)"
}
$env:BRIDGE_CHANNEL = $null

Show-Header 'A10: features registry stays main when env empty'
$env:BRIDGE_CHANNEL = $null
$s = Get-FeatureScope
Write-Host "scope.slug=$($s.slug) features_registry=$($s.features_registry)"
$mainCount = (Get-FeatureRegistry).Count
Write-Host "main registry count = $mainCount (existing, sanity)"

Show-Header 'A11: parser OK on changed files'
$files = @(
    'lib\channels.ps1',
    'lib\features.ps1',
    'lib\memory.ps1',
    'lib\auditor.ps1',
    'lib\architect.ps1',
    'tools\deep-audit.ps1',
    'tools\audit.ps1',
    'tools\feature-verifier.ps1',
    'tools\audit-functional.ps1',
    'driver.ps1',
    'server.ps1',
    'lib\backlog.ps1',
    'lib\jobs.ps1',
    'lib\parallel.ps1'
)
foreach ($f in $files) {
    $errs = $null; $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs) | Out-Null
    if ($errs.Count) { Write-Host "ERR  $f"; $errs | ForEach-Object { Write-Host "    $($_.Message)" } } else { Write-Host "OK   $f" }
}
