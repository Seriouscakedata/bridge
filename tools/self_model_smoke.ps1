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
    if (Test-ProbeChanged -Before $Before -After $After) {
        throw "$Name changed during Get-SelfModelPack"
    }
}

function Test-ProbeChanged {
    param(
        $Before,
        $After
    )
    return ($Before.Exists -ne $After.Exists -or $Before.Hash -ne $After.Hash -or $Before.LastWriteTimeUtc -ne $After.LastWriteTimeUtc -or $Before.Length -ne $After.Length)
}

function Get-SelfModelSmokeRuntimeRoot {
    param([string]$Root)

    $base = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) {
        return (Join-Path $Root 'control')
    }
    return (Join-Path $base '.bridge-runtime')
}

function Copy-SelfModelSmokeFile {
    param(
        [string]$Source,
        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-SelfModelSmokeFixtureBase {
    param([string]$Root)

    $candidates = @()
    if (Test-Path -LiteralPath 'C:\tmp' -PathType Container) {
        $candidates += 'C:\tmp'
    }
    $systemTemp = [System.IO.Path]::GetTempPath()
    if (-not [string]::IsNullOrWhiteSpace($systemTemp)) {
        $candidates += $systemTemp
    }
    $candidates += (Join-Path $Root '.bridge-runtime')

    foreach ($candidate in $candidates) {
        try {
            $base = Join-Path $candidate 'bridge-self-model-smoke-fixtures'
            if (-not (Test-Path -LiteralPath $base -PathType Container)) {
                New-Item -ItemType Directory -Path $base -Force | Out-Null
            }
            return $base
        } catch {}
    }
    throw 'unable to create self-model smoke fixture directory'
}

function Invoke-SelfModelFixtureReadOnlyProbe {
    param([string]$Root)

    $fixtureBase = Get-SelfModelSmokeFixtureBase -Root $Root
    $fixtureRoot = Join-Path $fixtureBase ([guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        Copy-SelfModelSmokeFile -Source (Join-Path $Root 'features\registry.json') -Destination (Join-Path $fixtureRoot 'features\registry.json')
        Copy-SelfModelSmokeFile -Source (Join-Path $Root 'features\state.json') -Destination (Join-Path $fixtureRoot 'features\state.json')
        Copy-SelfModelSmokeFile -Source (Join-Path $Root 'control\active_channel') -Destination (Join-Path $fixtureRoot 'control\active_channel')
        $slug = Get-SelfModelCurrentChannel -BridgeRoot $Root
        Copy-SelfModelSmokeFile -Source (Get-SelfModelBacklogPath -BridgeRoot $Root -Channel $slug) -Destination (Join-Path $fixtureRoot ('channels\' + $slug + '\backlog.jsonl'))

        $fixtureLib = Join-Path $fixtureRoot 'lib'
        New-Item -ItemType Directory -Path $fixtureLib -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter '*.ps1' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $fixtureLib $_.Name) -Force
        }

        $fixtureRegistryPath = Join-Path $fixtureRoot 'features\registry.json'
        $fixtureStatePath = Join-Path $fixtureRoot 'features\state.json'
        $fixtureRuntimeCachePath = Join-Path $fixtureRoot '.bridge-runtime\self-model\main.prompt.txt'
        $fixtureActiveChannelPath = Join-Path $fixtureRoot 'control\active_channel'
        $fixtureBacklogPath = Get-SelfModelBacklogPath -BridgeRoot $fixtureRoot -Channel $slug

        $beforeFixtureRegistry = Get-FileProbe -Path $fixtureRegistryPath
        $beforeFixtureState = Get-FileProbe -Path $fixtureStatePath
        $beforeFixtureRuntimeCache = Get-FileProbe -Path $fixtureRuntimeCachePath
        $beforeFixtureActiveChannel = Get-FileProbe -Path $fixtureActiveChannelPath
        $beforeFixtureBacklog = Get-FileProbe -Path $fixtureBacklogPath

        $fixturePack = Get-SelfModelPack -BridgeRoot $fixtureRoot

        $afterFixtureRegistry = Get-FileProbe -Path $fixtureRegistryPath
        $afterFixtureState = Get-FileProbe -Path $fixtureStatePath
        $afterFixtureRuntimeCache = Get-FileProbe -Path $fixtureRuntimeCachePath
        $afterFixtureActiveChannel = Get-FileProbe -Path $fixtureActiveChannelPath
        $afterFixtureBacklog = Get-FileProbe -Path $fixtureBacklogPath

        Assert-ProbeUnchanged -Name 'fixture features/registry.json' -Before $beforeFixtureRegistry -After $afterFixtureRegistry
        Assert-ProbeUnchanged -Name 'fixture features/state.json' -Before $beforeFixtureState -After $afterFixtureState
        Assert-ProbeUnchanged -Name 'fixture .bridge-runtime/self-model/main.prompt.txt' -Before $beforeFixtureRuntimeCache -After $afterFixtureRuntimeCache
        Assert-ProbeUnchanged -Name 'fixture control/active_channel' -Before $beforeFixtureActiveChannel -After $afterFixtureActiveChannel
        Assert-ProbeUnchanged -Name $fixtureBacklogPath -Before $beforeFixtureBacklog -After $afterFixtureBacklog
        if ([string]::IsNullOrWhiteSpace($fixturePack)) { throw 'fixture pack is empty' }
        return $true
    } finally {
        try { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$registryPath = Join-Path $BridgeRoot 'features\registry.json'
$statePath = Join-Path $BridgeRoot 'features\state.json'
$runtimeCachePath = Join-Path (Join-Path (Get-SelfModelSmokeRuntimeRoot -Root $BridgeRoot) 'self-model') 'main.prompt.txt'
$memoryMapPath = Join-Path $BridgeRoot 'memory\map.md'
$activeChannelPath = Join-Path $BridgeRoot 'control\active_channel'
$channelSlug = Get-SelfModelCurrentChannel -BridgeRoot $BridgeRoot
$channelBacklogPath = Get-SelfModelBacklogPath -BridgeRoot $BridgeRoot -Channel $channelSlug

$fixtureReadOnly = Invoke-SelfModelFixtureReadOnlyProbe -Root $BridgeRoot

$beforeRegistry = Get-FileProbe -Path $registryPath
$beforeState = Get-FileProbe -Path $statePath
$beforeRuntimeCache = Get-FileProbe -Path $runtimeCachePath
$beforeMemoryMap = Get-FileProbe -Path $memoryMapPath
$beforeActiveChannel = Get-FileProbe -Path $activeChannelPath
$beforeChannelBacklog = Get-FileProbe -Path $channelBacklogPath

$ideaSourceStatsBefore = Get-SelfModelIdeaSourceStats -BridgeRoot $BridgeRoot
if ([string]$ideaSourceStatsBefore.backlog_path -ne [string]$channelBacklogPath) {
    throw 'idea source stats resolved an unexpected backlog path'
}
$pack = Get-SelfModelPack -BridgeRoot $BridgeRoot

$afterRegistry = Get-FileProbe -Path $registryPath
$afterState = Get-FileProbe -Path $statePath
$afterRuntimeCache = Get-FileProbe -Path $runtimeCachePath
$afterMemoryMap = Get-FileProbe -Path $memoryMapPath
$afterActiveChannel = Get-FileProbe -Path $activeChannelPath
$afterChannelBacklog = Get-FileProbe -Path $channelBacklogPath

Assert-ProbeUnchanged -Name 'features/registry.json' -Before $beforeRegistry -After $afterRegistry
Assert-ProbeUnchanged -Name '.bridge-runtime/self-model/main.prompt.txt' -Before $beforeRuntimeCache -After $afterRuntimeCache
Assert-ProbeUnchanged -Name 'memory/map.md' -Before $beforeMemoryMap -After $afterMemoryMap
Assert-ProbeUnchanged -Name 'control/active_channel' -Before $beforeActiveChannel -After $afterActiveChannel
Assert-ProbeUnchanged -Name $channelBacklogPath -Before $beforeChannelBacklog -After $afterChannelBacklog
$stateChangedDuringPack = Test-ProbeChanged -Before $beforeState -After $afterState

if ([string]::IsNullOrWhiteSpace($pack)) { throw 'pack is empty' }
$byteCount = [System.Text.Encoding]::UTF8.GetByteCount($pack)
if ($byteCount -lt 1536 -or $byteCount -gt 4096) {
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
if ($pack -notmatch '(?m)^IDEA SOURCES:\s+') {
    throw 'missing compact idea source metric'
}
if ($pack -match 'backlog\.jsonl') {
    throw 'pack leaked backlog path'
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
    stateUnchanged = (-not [bool]$stateChangedDuringPack)
    stateVolatile = $true
    stateVolatileChanged = [bool]$stateChangedDuringPack
    runtimeCacheUnchanged = $true
    memoryMapUnchanged = $true
    activeChannelUnchanged = $true
    channelBacklogUnchanged = $true
    fixtureReadOnly = [bool]$fixtureReadOnly
    modulesSection = $true
    ideaSourcesSection = $true
    deliveryModeScanned = $true
    selfModelScanned = $true
    ownerFileHits = $ownerHits
} | ConvertTo-Json -Compress
