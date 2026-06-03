[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}
$bridgeRoot = Split-Path -Parent $scriptRoot
$refreshPath = Join-Path $bridgeRoot 'tools\refresh-self-model.ps1'

function Write-SmokeUtf8Bom {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Write-SmokeUtf8NoBom {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-SmokeFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-SmokeHasUtf8Bom {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Read-SmokeJson {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-refresh-self-model-smoke-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $tempRoot 'fixture'
$runtimeRoot = Join-Path $tempRoot 'runtime'

try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'lib') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'features') -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $bridgeRoot 'lib\self-model.ps1') -Destination (Join-Path $fixtureRoot 'lib\self-model.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $bridgeRoot 'lib\common.ps1') -Destination (Join-Path $fixtureRoot 'lib\common.ps1') -Force

    $registry = @'
[
  {
    "id": "intent-classifier",
    "owner_files": ["lib/intent.ps1"],
    "owner_function": "Invoke-IntentClassifier",
    "layer": "L2",
    "status": "active"
  },
  {
    "id": "worker-pool",
    "owner_files": ["lib/parallel.ps1"],
    "owner_function": "Invoke-ParallelDispatch",
    "layer": "L2",
    "status": "active"
  },
  {
    "id": "old-feature",
    "owner_files": ["lib/old.ps1"],
    "owner_function": "Invoke-OldFeature",
    "layer": "L1",
    "status": "dormant"
  }
]
'@
    $state = '{"fixture":true,"updated":1}'
    Write-SmokeUtf8NoBom -Path (Join-Path $fixtureRoot 'features\registry.json') -Text $registry
    Write-SmokeUtf8NoBom -Path (Join-Path $fixtureRoot 'features\state.json') -Text $state
    foreach ($doc in @('SELF_MODEL_PLAN.md', 'PROJECT_MAP.md', 'BRIDGE_STATUS.md', 'PROJECT_WORKFLOW.md', 'OPERATOR_GUIDE.md')) {
        Write-SmokeUtf8NoBom -Path (Join-Path $fixtureRoot $doc) -Text ("fixture " + $doc)
    }

    $realCacheDir = Join-Path (Join-Path ([string]$env:USERPROFILE) '.bridge-runtime') 'self-model'
    $realPackPath = Join-Path $realCacheDir 'main.pack.json'
    $realPromptPath = Join-Path $realCacheDir 'main.prompt.txt'
    $realPackBefore = Get-SmokeFileHash -Path $realPackPath
    $realPromptBefore = Get-SmokeFileHash -Path $realPromptPath

    $first = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshPath -BridgeRoot $fixtureRoot -RuntimeRoot $runtimeRoot | ConvertFrom-Json
    if (-not $first.ok -or $first.stale) {
        throw ('first refresh did not create a fresh cache: ' + ($first | ConvertTo-Json -Depth 8 -Compress))
    }

    $packPath = Join-Path $runtimeRoot 'self-model\main.pack.json'
    $promptPath = Join-Path $runtimeRoot 'self-model\main.prompt.txt'
    if (-not (Test-Path -LiteralPath $packPath)) { throw 'main.pack.json was not created' }
    if (-not (Test-Path -LiteralPath $promptPath)) { throw 'main.prompt.txt was not created' }
    if (Test-SmokeHasUtf8Bom -Path $packPath) { throw 'main.pack.json has UTF-8 BOM' }
    if (Test-SmokeHasUtf8Bom -Path $promptPath) { throw 'main.prompt.txt has UTF-8 BOM' }

    $pack1 = Read-SmokeJson -Path $packPath
    $prompt1 = [System.IO.File]::ReadAllText($promptPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($pack1.prompt_text)) { throw 'pack prompt_text is empty' }
    if ($prompt1 -ne [string]$pack1.prompt_text) { throw 'prompt txt does not match pack prompt_text' }
    if ($pack1.stale) { throw 'created pack is stale' }
    if (-not $pack1.source_hashes.PSObject.Properties['features/registry.json']) { throw 'registry hash missing' }
    if (-not $pack1.source_hashes.PSObject.Properties['features/state.json']) { throw 'state hash missing' }

    $packFileHash1 = Get-SmokeFileHash -Path $packPath
    $sourceHashes1 = ($pack1.source_hashes | ConvertTo-Json -Depth 8 -Compress)
    Start-Sleep -Milliseconds 1100
    $second = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshPath -BridgeRoot $fixtureRoot -RuntimeRoot $runtimeRoot | ConvertFrom-Json
    if (-not $second.ok -or $second.stale -or -not $second.no_op) { throw 'second refresh was not a no-op' }
    $pack2 = Read-SmokeJson -Path $packPath
    $packFileHash2 = Get-SmokeFileHash -Path $packPath
    $sourceHashes2 = ($pack2.source_hashes | ConvertTo-Json -Depth 8 -Compress)
    if ($packFileHash1 -ne $packFileHash2) { throw 'pack file hash changed on no-op refresh' }
    if ($sourceHashes1 -ne $sourceHashes2) { throw 'source_hashes changed without source changes' }

    $statePath = Join-Path $fixtureRoot 'features\state.json'
    Write-SmokeUtf8NoBom -Path $statePath -Text '{"fixture":true,"updated":2}'
    $third = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshPath -BridgeRoot $fixtureRoot -RuntimeRoot $runtimeRoot | ConvertFrom-Json
    if (-not $third.ok -or $third.stale -or $third.no_op) { throw 'third refresh did not update after source change' }
    $pack3 = Read-SmokeJson -Path $packPath
    if ([string]$pack1.source_hashes.'features/state.json' -eq [string]$pack3.source_hashes.'features/state.json') {
        throw 'state source hash did not change after fixture edit'
    }
    if ([string]$pack1.source_hashes.'features/registry.json' -ne [string]$pack3.source_hashes.'features/registry.json') {
        throw 'registry source hash changed unexpectedly'
    }

    Write-SmokeUtf8Bom -Path (Join-Path $fixtureRoot 'lib\self-model.ps1') -Text @'
function Get-SelfModelPack {
    param([string]$BridgeRoot = $null)
    throw 'fixture generator failure'
}
'@
    $failed = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshPath -BridgeRoot $fixtureRoot -RuntimeRoot $runtimeRoot | ConvertFrom-Json
    if ($failed.ok -or -not $failed.stale) { throw 'failed generator did not fail-open as stale' }
    $stalePack = Read-SmokeJson -Path $packPath
    if (-not $stalePack.stale) { throw 'existing pack was not marked stale after generator failure' }
    if ([string]::IsNullOrWhiteSpace([string]$stalePack.prompt_text)) { throw 'stale existing pack lost prompt_text' }

    $realPackAfter = Get-SmokeFileHash -Path $realPackPath
    $realPromptAfter = Get-SmokeFileHash -Path $realPromptPath
    if ($realPackBefore -ne $realPackAfter -or $realPromptBefore -ne $realPromptAfter) {
        throw 'real runtime self-model cache changed during fixture smoke'
    }

    [pscustomobject]@{
        testPassed = $true
        cacheCreated = $true
        secondRunNoOp = [bool]$second.no_op
        noOpPackHashStable = ($packFileHash1 -eq $packFileHash2)
        sourceHashChanged = ([string]$pack1.source_hashes.'features/state.json' -ne [string]$pack3.source_hashes.'features/state.json')
        failOpenStale = [bool]$stalePack.stale
        cacheUtf8NoBom = $true
        realRuntimeCacheUnchanged = $true
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
