[CmdletBinding()]
param(
    [string]$BridgeRoot = $null,
    [string]$RuntimeRoot = $null,
    [switch]$NoOutput
)

$ErrorActionPreference = 'Stop'

function Get-RefreshSelfModelBridgeRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:BridgeRoot)) {
        return (Resolve-Path -LiteralPath $script:BridgeRoot).Path
    }
    $root = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Split-Path -Parent $PSScriptRoot
    } elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    } else {
        (Get-Location).Path
    }
    return (Resolve-Path -LiteralPath $root).Path
}

function Import-RefreshSelfModelDependencies {
    param([string]$Root)

    # Kept for compatibility if the tool is dot-sourced by another script.
    $commonPath = Join-Path $Root 'lib\common.ps1'
    if ([string]::IsNullOrWhiteSpace($script:RuntimeRoot) -and (Test-Path -LiteralPath $commonPath) -and -not (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue)) {
        . $commonPath
    }
    $generatorPath = Join-Path $Root 'lib\self-model.ps1'
    if (Test-Path -LiteralPath $generatorPath) {
        . $generatorPath
    }
}

function Get-RefreshSelfModelRuntimeRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($script:RuntimeRoot)) {
        return $script:RuntimeRoot
    }
    if (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue) {
        return (Get-RuntimeRoot)
    }
    $base = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($base)) {
        return (Join-Path $Root 'control')
    }
    return (Join-Path $base '.bridge-runtime')
}

function Get-RefreshSelfModelHash {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RefreshSelfModelSourceHashes {
    param([string]$Root)

    $relativePaths = @(
        'features\registry.json',
        'features\state.json',
        'SELF_MODEL_PLAN.md',
        'PROJECT_MAP.md',
        'BRIDGE_STATUS.md',
        'PROJECT_WORKFLOW.md',
        'OPERATOR_GUIDE.md'
    )
    $hashes = [ordered]@{}
    foreach ($rel in $relativePaths) {
        $key = $rel -replace '\\', '/'
        $hashes[$key] = Get-RefreshSelfModelHash -Path (Join-Path $Root $rel)
    }
    return $hashes
}

function Write-RefreshSelfModelAtomicText {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = $Path + '.tmp.' + [guid]::NewGuid().ToString('N')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Text, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-RefreshSelfModelJson {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 8)
}

function Read-RefreshSelfModelPack {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-RefreshSelfModelSameSourceHashes {
    param($Left, $Right)

    if ($null -eq $Left -or $null -eq $Right) { return $false }
    foreach ($name in $Left.Keys) {
        if (-not $Right.PSObject.Properties[$name]) { return $false }
        if ([string]$Left[$name] -ne [string]$Right.PSObject.Properties[$name].Value) { return $false }
    }
    foreach ($prop in $Right.PSObject.Properties.Name) {
        if (-not $Left.Contains($prop)) { return $false }
    }
    return $true
}

function Write-RefreshSelfModelPack {
    param(
        [string]$PackPath,
        [string]$PromptPath,
        [object]$Pack
    )

    $json = ConvertTo-RefreshSelfModelJson -Value $Pack
    Write-RefreshSelfModelAtomicText -Path $PackPath -Text $json
    Write-RefreshSelfModelAtomicText -Path $PromptPath -Text ([string]$Pack.prompt_text)
}

function Write-RefreshSelfModelStalePack {
    param(
        [string]$PackPath,
        [string]$PromptPath,
        [object]$SourceHashes,
        [string]$Reason
    )

    $existing = Read-RefreshSelfModelPack -Path $PackPath
    if ($null -ne $existing) {
        if (-not $existing.PSObject.Properties['version']) {
            $existing | Add-Member -NotePropertyName version -NotePropertyValue 'self-model-pack/v1' -Force
        }
        if (-not $existing.PSObject.Properties['generated_at']) {
            $existing | Add-Member -NotePropertyName generated_at -NotePropertyValue (Get-Date).ToString('o') -Force
        }
        if (-not $existing.PSObject.Properties['source_hashes']) {
            $existing | Add-Member -NotePropertyName source_hashes -NotePropertyValue ([pscustomobject]$SourceHashes) -Force
        }
        if (-not $existing.PSObject.Properties['prompt_text']) {
            $prompt = ''
            if (Test-Path -LiteralPath $PromptPath) {
                $prompt = [System.IO.File]::ReadAllText($PromptPath, [System.Text.Encoding]::UTF8)
            }
            $existing | Add-Member -NotePropertyName prompt_text -NotePropertyValue $prompt -Force
        }
        $existing | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
        $existing | Add-Member -NotePropertyName stale_reason -NotePropertyValue $Reason -Force
        Write-RefreshSelfModelPack -PackPath $PackPath -PromptPath $PromptPath -Pack $existing
        return [pscustomobject]@{ ok = $false; stale = $true; wrote_minimal = $false; reason = $Reason }
    }

    $promptText = "=== BRIDGE SELF-MODEL PACK v1 ===`r`nstale=true`r`nGenerator failed; no previous pack is available."
    $pack = [ordered]@{
        version = 'self-model-pack/v1'
        generated_at = (Get-Date).ToString('o')
        source_hashes = [pscustomobject]$SourceHashes
        stale = $true
        stale_reason = $Reason
        prompt_text = $promptText
    }
    Write-RefreshSelfModelPack -PackPath $PackPath -PromptPath $PromptPath -Pack ([pscustomobject]$pack)
    return [pscustomobject]@{ ok = $false; stale = $true; wrote_minimal = $true; reason = $Reason }
}

function Invoke-RefreshSelfModel {
    try {
        $root = Get-RefreshSelfModelBridgeRoot
        $commonPath = Join-Path $root 'lib\common.ps1'
        if ([string]::IsNullOrWhiteSpace($script:RuntimeRoot) -and (Test-Path -LiteralPath $commonPath) -and -not (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue)) {
            . $commonPath
        }
        $generatorPath = Join-Path $root 'lib\self-model.ps1'
        if (Test-Path -LiteralPath $generatorPath) {
            . $generatorPath
        }
        $runtime = Get-RefreshSelfModelRuntimeRoot -Root $root
        $cacheDir = Join-Path $runtime 'self-model'
        $packPath = Join-Path $cacheDir 'main.pack.json'
        $promptPath = Join-Path $cacheDir 'main.prompt.txt'
        $sourceHashes = Get-RefreshSelfModelSourceHashes -Root $root

        if (-not (Get-Command Get-SelfModelPack -ErrorAction SilentlyContinue)) {
            return Write-RefreshSelfModelStalePack -PackPath $packPath -PromptPath $promptPath -SourceHashes $sourceHashes -Reason 'Get-SelfModelPack is not available'
        }

        try {
            $promptText = Get-SelfModelPack -BridgeRoot $root
        } catch {
            return Write-RefreshSelfModelStalePack -PackPath $packPath -PromptPath $promptPath -SourceHashes $sourceHashes -Reason $_.Exception.Message
        }
        if ([string]::IsNullOrWhiteSpace($promptText)) {
            return Write-RefreshSelfModelStalePack -PackPath $packPath -PromptPath $promptPath -SourceHashes $sourceHashes -Reason 'Get-SelfModelPack returned empty text'
        }

        $existing = Read-RefreshSelfModelPack -Path $packPath
        if ($null -ne $existing -and
            $existing.PSObject.Properties['prompt_text'] -and
            $existing.PSObject.Properties['source_hashes'] -and
            [string]$existing.prompt_text -eq [string]$promptText -and
            (Test-RefreshSelfModelSameSourceHashes -Left $sourceHashes -Right $existing.source_hashes) -and
            $existing.PSObject.Properties['stale'] -and
            -not [bool]$existing.stale) {
            return [pscustomobject]@{
                ok = $true
                stale = $false
                no_op = $true
                pack_path = $packPath
                prompt_path = $promptPath
                generated_at = [string]$existing.generated_at
                source_hashes = [pscustomobject]$sourceHashes
            }
        }

        $pack = [ordered]@{
            version = 'self-model-pack/v1'
            generated_at = (Get-Date).ToString('o')
            source_hashes = [pscustomobject]$sourceHashes
            stale = $false
            prompt_text = $promptText
        }
        Write-RefreshSelfModelPack -PackPath $packPath -PromptPath $promptPath -Pack ([pscustomobject]$pack)
        return [pscustomobject]@{
            ok = $true
            stale = $false
            no_op = $false
            pack_path = $packPath
            prompt_path = $promptPath
            generated_at = [string]$pack.generated_at
            source_hashes = [pscustomobject]$sourceHashes
        }
    } catch {
        try {
            $root = if ([string]::IsNullOrWhiteSpace($script:BridgeRoot)) { (Get-Location).Path } else { $script:BridgeRoot }
            $runtime = if ([string]::IsNullOrWhiteSpace($script:RuntimeRoot)) { Join-Path ([string]$env:USERPROFILE) '.bridge-runtime' } else { $script:RuntimeRoot }
            $cacheDir = Join-Path $runtime 'self-model'
            $sourceHashes = Get-RefreshSelfModelSourceHashes -Root $root
            return Write-RefreshSelfModelStalePack -PackPath (Join-Path $cacheDir 'main.pack.json') -PromptPath (Join-Path $cacheDir 'main.prompt.txt') -SourceHashes $sourceHashes -Reason $_.Exception.Message
        } catch {
            return [pscustomobject]@{ ok = $false; stale = $true; no_write = $true; reason = $_.Exception.Message }
        }
    }
}

$result = Invoke-RefreshSelfModel
if (-not $NoOutput) {
    $result | ConvertTo-Json -Depth 8
}
