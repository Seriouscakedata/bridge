[CmdletBinding()]
param(
    [string]$BridgeRoot = $null
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
    $BridgeRoot = Split-Path -Parent $scriptRoot
}

$selfModelPath = Join-Path $BridgeRoot 'lib\self-model.ps1'
. $selfModelPath

function Get-FileProbe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Hash = ''; LastWriteTimeUtc = $null; Length = -1 }
    }
    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return [pscustomobject]@{
        Exists = $true
        Hash = $hash
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length = $item.Length
    }
}

function Assert-ProbeUnchanged {
    param(
        [string]$Name,
        $Before,
        $After
    )
    if ($Before.Exists -ne $After.Exists -or $Before.Hash -ne $After.Hash -or $Before.LastWriteTimeUtc -ne $After.LastWriteTimeUtc -or $Before.Length -ne $After.Length) {
        throw "$Name changed during Get-SelfModelPack"
    }
}

$registryPath = Join-Path $BridgeRoot 'features\registry.json'
$statePath = Join-Path $BridgeRoot 'features\state.json'
$runtimeCachePath = Join-Path $BridgeRoot '.bridge-runtime\self-model\main.prompt.txt'
$memoryMapPath = Join-Path $BridgeRoot 'memory\map.md'

$beforeRegistry = Get-FileProbe -Path $registryPath
$beforeState = Get-FileProbe -Path $statePath
$beforeRuntimeCache = Get-FileProbe -Path $runtimeCachePath
$beforeMemoryMap = Get-FileProbe -Path $memoryMapPath

$pack = Get-SelfModelPack -BridgeRoot $BridgeRoot

$afterRegistry = Get-FileProbe -Path $registryPath
$afterState = Get-FileProbe -Path $statePath
$afterRuntimeCache = Get-FileProbe -Path $runtimeCachePath
$afterMemoryMap = Get-FileProbe -Path $memoryMapPath

Assert-ProbeUnchanged -Name 'features/registry.json' -Before $beforeRegistry -After $afterRegistry
Assert-ProbeUnchanged -Name 'features/state.json' -Before $beforeState -After $afterState
Assert-ProbeUnchanged -Name '.bridge-runtime/self-model/main.prompt.txt' -Before $beforeRuntimeCache -After $afterRuntimeCache
Assert-ProbeUnchanged -Name 'memory/map.md' -Before $beforeMemoryMap -After $afterMemoryMap

if ([string]::IsNullOrWhiteSpace($pack)) { throw 'pack is empty' }
$byteCount = [System.Text.Encoding]::UTF8.GetByteCount($pack)
if ($byteCount -lt 1536 -or $byteCount -gt 2560) {
    throw "pack size out of base range: $byteCount bytes"
}

foreach ($section in @('ARCH:', 'CRITICAL:', 'FEATURES active:', 'FEATURES dormant:', 'MODULES (scanned, not in registry):', 'SAFETY:', 'TESTS:')) {
    if ($pack -notmatch ("(?m)^" + [regex]::Escape($section))) {
        throw "missing required section $section"
    }
}
$packLines = @($pack -split "`r?`n")
$deliveryModuleLine = @($packLines | Where-Object { $_ -match '^- delivery-mode:' } | Select-Object -First 1)
if ($deliveryModuleLine.Count -eq 0) {
    throw 'missing unregistered module delivery-mode'
}
if ($deliveryModuleLine[0] -notmatch 'task delivery mode classifier') {
    throw 'delivery-mode purpose missing from module scan'
}
if ($deliveryModuleLine[0] -notmatch '\(fns:\s*[^)]*Get-DeliveryModeSchema') {
    throw 'delivery-mode functions missing Get-DeliveryModeSchema'
}
$selfModelModuleLine = @($packLines | Where-Object { $_ -match '^- self-model:' } | Select-Object -First 1)
if ($selfModelModuleLine.Count -eq 0) {
    throw 'missing unregistered module self-model'
}
if ($pack -match 'owner_files') {
    throw 'pack contains owner_files label; looks like registry dump'
}
if ($pack -notmatch 'dispatcher flow: staged planning -> atoms -> frontier') {
    throw 'dispatcher frontier rule missing'
}

$registry = [System.IO.File]::ReadAllText($registryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$features = @($registry)
if ($features.Count -eq 1 -and $features[0] -is [array]) {
    $features = @($features[0])
}
$ownerFiles = @()
foreach ($feature in $features) {
    foreach ($owner in @($feature.owner_files)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$owner)) {
            $ownerFiles += [string]$owner
        }
    }
}
$ownerFiles = @($ownerFiles | Sort-Object -Unique)
$ownerHits = 0
foreach ($owner in $ownerFiles) {
    if ($pack.Contains($owner)) { $ownerHits++ }
}
if ($ownerFiles.Count -gt 0 -and $ownerHits -ge [Math]::Min(10, $ownerFiles.Count)) {
    throw "pack contains too many owner file paths: $ownerHits"
}

[pscustomobject]@{
    testPassed = $true
    packBytes = $byteCount
    registryUnchanged = $true
    stateUnchanged = $true
    runtimeCacheUnchanged = $true
    memoryMapUnchanged = $true
    modulesSection = $true
    deliveryModeScanned = $true
    selfModelScanned = $true
    ownerFileHits = $ownerHits
} | ConvertTo-Json -Compress
