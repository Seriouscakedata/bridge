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
$driver30Path = Join-Path $bridgeRoot 'driver\30-prompt-agent-state.ps1'

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

function Get-SmokeFileSnapshot {
    param([string]$Path)
    $items = @()
    if (Test-Path -LiteralPath $Path) {
        $items = Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName | ForEach-Object {
            [pscustomobject]@{
                path = $_.FullName.Substring($Path.Length).TrimStart('\')
                hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }
    }
    return ($items | ConvertTo-Json -Depth 5 -Compress)
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-self-model-inject-smoke-' + [guid]::NewGuid().ToString('N'))
$runtimeRoot = Join-Path $tempRoot 'runtime'
$cacheDir = Join-Path $runtimeRoot 'self-model'
$cachePath = Join-Path $cacheDir 'main.prompt.txt'
$sentinel = 'SELF_MODEL_INJECT_SMOKE_SENTINEL_20260603'

try {
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    Write-SmokeUtf8NoBom -Path $cachePath -Text @"
=== BRIDGE SELF-MODEL PACK v1 ===
$sentinel
ARCH fixture
"@

    $script:SmokeBinding = $null
    $script:GetSelfModelPackCalls = 0
    $script:RefreshSelfModelCalls = 0
    $global:bridgeRoot = $bridgeRoot
    $global:workRoot = Split-Path -Parent $bridgeRoot
    $global:Channel = 'main'
    $global:discussMinTurns = 2
    $global:discussMaxTurns = 6
    $global:studyMaxTurns = 6
    $global:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    function Set-SmokeChannel {
        param([string]$Slug)
        $global:Channel = $Slug
        $script:SmokeBinding = [pscustomobject]@{
            ok = $true
            slug = $Slug
            project_root = if ($Slug -eq 'main') { $bridgeRoot } else { Join-Path $tempRoot $Slug }
            project_type = if ($Slug -eq 'main') { 'bridge' } else { 'external' }
            project_description = 'self model inject smoke'
            source = 'smoke'
        }
    }

    function Get-ActiveProjectBinding { return $script:SmokeBinding }
    function Get-ProjectFocusPromptBlock { return "ACTIVE-PROJECT-BLOCK-$($script:SmokeBinding.slug)" }
    function Get-RuntimeRoot { return $runtimeRoot }
    function Get-AutoToolsPromptBlock { return '' }
    function Get-SkillRecall { param([string]$TaskText) return '' }
    function Get-AutonomySettings { return [pscustomobject]@{ scope = 'bridge' } }
    function Read-State {
        return [pscustomobject]@{
            discuss_turn = 0
            task_turn = 0
            current_backlog_id = ''
            study_subtype = ''
            study_phase = ''
            study_snapshot = ''
            discuss_snapshot = ''
            chunk_progress = ''
            chunk_base_commit = ''
        }
    }
    function Format-Transcript { return 'DIALOG-SMOKE' }
    function Format-PlanForPrompt { return '' }
    function Get-TaskCheckpointBlock { return '' }
    function Get-DecisionShadowPromptHint { return '' }
    function Get-OtherChannelsAgentsImpl { return @() }
    function Set-CurrentAgentImpl { param([string]$Agent) }
    function Update-State { param([scriptblock]$Mutation) return $null }
    function Get-SelfModelPack {
        $script:GetSelfModelPackCalls++
        throw 'Get-SelfModelPack must not be called from Build-Prompt'
    }
    function Invoke-RefreshSelfModel {
        $script:RefreshSelfModelCalls++
        throw 'Invoke-RefreshSelfModel must not be called from Build-Prompt'
    }

    . $driver30Path

    Set-SmokeChannel -Slug 'main'
    $beforeSnapshot = Get-SmokeFileSnapshot -Path $cacheDir
    $normalPrompt = Build-Prompt -Role 'codex' -Task 'normal smoke task' -Mode 'normal'
    $fastPrompt = Build-Prompt -Role 'codex' -Task 'fast smoke task' -Mode 'normal' -FastLane
    $afterSnapshot = Get-SmokeFileSnapshot -Path $cacheDir

    if ($normalPrompt -notlike "*$sentinel*") { throw 'main normal prompt does not contain self-model sentinel' }
    if ($fastPrompt -notlike "*$sentinel*") { throw 'main fast-lane prompt does not contain self-model sentinel' }
    if (-not $normalPrompt.Contains('[[REMEMBER:') -or -not $normalPrompt.Contains('ПАМЯТЬ')) {
        throw 'memory recall markers are missing from normal prompt'
    }
    if ($script:GetSelfModelPackCalls -ne 0 -or $script:RefreshSelfModelCalls -ne 0) {
        throw 'Build-Prompt called self-model generator or refresh'
    }
    if ($beforeSnapshot -ne $afterSnapshot) {
        throw 'self-model cache changed during Build-Prompt'
    }

    Set-SmokeChannel -Slug 'private-community'
    $externalPrompt = Build-Prompt -Role 'codex' -Task 'external smoke task' -Mode 'normal'
    if ($externalPrompt -like "*$sentinel*") { throw 'external channel prompt contains main self-model sentinel' }

    Set-SmokeChannel -Slug 'main'
    Remove-Item -LiteralPath $cachePath -Force
    $missingPrompt = Build-Prompt -Role 'codex' -Task 'missing cache task' -Mode 'normal'
    if ($missingPrompt -like "*$sentinel*") { throw 'missing cache prompt still contains sentinel' }

    Write-SmokeUtf8NoBom -Path $cachePath -Text ''
    $emptyPrompt = Build-Prompt -Role 'codex' -Task 'empty cache task' -Mode 'normal'
    if ($emptyPrompt -like "*$sentinel*") { throw 'empty cache prompt contains sentinel' }

    [pscustomobject]@{
        testPassed = $true
        mainNormalContainsSelfModel = ($normalPrompt -like "*$sentinel*")
        mainFastLaneContainsSelfModel = ($fastPrompt -like "*$sentinel*")
        memoryMarkersPresent = ($normalPrompt.Contains('[[REMEMBER:') -and $normalPrompt.Contains('ПАМЯТЬ'))
        generatorCalls = $script:GetSelfModelPackCalls
        refreshCalls = $script:RefreshSelfModelCalls
        cacheUnchangedDuringPromptBuild = ($beforeSnapshot -eq $afterSnapshot)
        missingCacheFailOpen = ($missingPrompt -notlike "*$sentinel*")
        emptyCacheFailOpen = ($emptyPrompt -notlike "*$sentinel*")
        externalChannelSkipped = ($externalPrompt -notlike "*$sentinel*")
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
