$ErrorActionPreference = 'Stop'
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1'
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\channels.ps1'
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\features.ps1'

Write-Host '== PHASE 2: Features fail-closed in travel without dir =='
$travelFeaturesDir = 'C:\Users\rafie\OneDrive\Documents\bridge\channels\travel\features'
Write-Host ('travel features dir exists BEFORE: ' + (Test-Path -LiteralPath $travelFeaturesDir))
$env:BRIDGE_CHANNEL = 'travel'
try {
    Add-Feature -Id 'phase-verify-noop' -Title 'should fail' -ConfirmTrigger 'manual' 2>&1 | Out-Null
    Write-Host 'FAIL: Add-Feature succeeded but should throw no_registry'
} catch {
    Write-Host ('OK throw: ' + $_.Exception.Message)
}
Write-Host ('travel features dir exists AFTER: ' + (Test-Path -LiteralPath $travelFeaturesDir))

Write-Host ''
Write-Host '== PHASE 3: Memory write-guard from project channel =='
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\memory.ps1'
$env:BRIDGE_CHANNEL = 'travel'
try {
    Add-Memory -Role 'system' -Text 'phase-verify-bridge-write-test' -Channel 'main' 2>&1 | Out-Null
    Write-Host 'FAIL: write to bridge should throw'
} catch {
    Write-Host ('OK throw: ' + $_.Exception.Message)
}

Write-Host ''
Write-Host '== PHASE 3: Memory write to travel store works =='
$env:BRIDGE_CHANNEL = 'travel'
$travelStore = 'C:\Users\rafie\OneDrive\Documents\bridge\channels\travel\memory\memory.jsonl'
$beforeCount = if (Test-Path -LiteralPath $travelStore) { (Get-Content -LiteralPath $travelStore).Count } else { 0 }
$id = Add-Memory -Role 'system' -Text 'phase-verify-travel-write-test' -Tags @('phase-verify')
$afterCount = if (Test-Path -LiteralPath $travelStore) { (Get-Content -LiteralPath $travelStore).Count } else { 0 }
Write-Host ('id=' + $id + ' before=' + $beforeCount + ' after=' + $afterCount)

Write-Host ''
Write-Host '== PHASE 3: Recall = travel + bridge readonly cap=2 =='
$res = Search-Memory -Query 'feature memory' -TopK 5
$ch = @($res | Where-Object { -not $_.PSObject.Properties.Match('readonly_source').Count -or -not $_.readonly_source }).Count
$br = @($res | Where-Object { $_.PSObject.Properties.Match('readonly_source').Count -and $_.readonly_source -eq 'bridge' }).Count
Write-Host ('total=' + $res.Count + ' channel=' + $ch + ' bridge=' + $br)

Write-Host ''
Write-Host '== PHASE 4: feature-verifier in travel skips with no_registry =='
$env:BRIDGE_CHANNEL = 'travel'
$verifierOut = & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\rafie\OneDrive\Documents\bridge\tools\feature-verifier.ps1' 2>&1 | Out-String
Write-Host $verifierOut

$env:BRIDGE_CHANNEL = $null
