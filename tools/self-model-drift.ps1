[CmdletBinding()]
param(
    [string]$BridgeRoot = $null,
    [string]$RuntimeRoot = $null,
    [int]$StaleHours = 0,
    [switch]$NoOutput
)

$ErrorActionPreference = 'Stop'

function Get-SelfModelDriftBridgeRoot {
    if (-not [string]::IsNullOrWhiteSpace($script:BridgeRoot)) {
        return (Resolve-Path -LiteralPath $script:BridgeRoot).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent (Split-Path -Parent $PSCommandPath))).Path
    }
    return (Get-Location).Path
}

function Get-SelfModelDriftRuntimeRoot {
    param([string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($script:RuntimeRoot)) {
        return $script:RuntimeRoot
    }
    $commonPath = Join-Path $Root 'lib\common.ps1'
    try {
        if ((Test-Path -LiteralPath $commonPath) -and -not (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue)) {
            . $commonPath
        }
        if (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue) {
            return (Get-RuntimeRoot)
        }
    } catch {
        # Fail open to the conventional runtime root; this audit must not break on dependency load.
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
        return (Join-Path ([string]$env:USERPROFILE) '.bridge-runtime')
    }
    return (Join-Path $Root '.bridge-runtime')
}

function Read-SelfModelDriftJson {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function ConvertTo-SelfModelDriftArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    $items = @($Value)
    if ($items.Count -eq 1 -and $items[0] -is [array]) {
        $items = @($items[0])
    }
    return @($items)
}

function Add-SelfModelDriftFinding {
    param(
        [System.Collections.Generic.List[object]]$Findings,
        [hashtable]$Fields
    )

    [void]$Findings.Add([pscustomobject]$Fields)
}

function Get-SelfModelDriftRelativePath {
    param([string]$Path)

    return ([string]$Path -replace '/', '\')
}

function Get-SelfModelDriftThresholdHours {
    param(
        [string]$Root,
        [int]$ExplicitStaleHours
    )

    if ($ExplicitStaleHours -gt 0) {
        return $ExplicitStaleHours
    }
    $configPath = Join-Path $Root 'config.json'
    try {
        $cfg = Read-SelfModelDriftJson -Path $configPath
        if ($null -ne $cfg -and
            $cfg.PSObject.Properties['selfModel'] -and
            $cfg.selfModel.PSObject.Properties['staleHours']) {
            $configured = [int]$cfg.selfModel.staleHours
            if ($configured -gt 0) { return $configured }
        }
    } catch {
        return 24
    }
    return 24
}

function New-SelfModelDriftReport {
    param(
        $Pack,
        [System.Collections.Generic.List[object]]$Findings,
        $AgeHours
    )

    $generatedAt = ''
    $packStale = $null
    if ($null -ne $Pack) {
        if ($Pack.PSObject.Properties['generated_at']) { $generatedAt = [string]$Pack.generated_at }
        if ($Pack.PSObject.Properties['stale']) { $packStale = [bool]$Pack.stale }
    }
    $roundedAge = $null
    if ($null -ne $AgeHours) {
        $roundedAge = [math]::Round([double]$AgeHours, 2)
    }
    return [pscustomobject]@{
        generated_at    = $generatedAt
        pack_stale_flag = $packStale
        age_hours       = $roundedAge
        findings        = @($Findings.ToArray())
        findings_count  = $Findings.Count
        ok              = ($Findings.Count -eq 0)
    }
}

$findings = New-Object 'System.Collections.Generic.List[object]'
$root = Get-SelfModelDriftBridgeRoot
$runtime = Get-SelfModelDriftRuntimeRoot -Root $root
$packPath = Join-Path $runtime 'self-model\main.pack.json'

$pack = $null
try {
    $pack = Read-SelfModelDriftJson -Path $packPath
} catch {
    Add-SelfModelDriftFinding -Findings $findings -Fields @{
        check = 'pack_unreadable'
        severity = 'critical'
        detail = $_.Exception.Message
        file = $packPath
    }
}

if ($null -eq $pack -and $findings.Count -eq 0) {
    Add-SelfModelDriftFinding -Findings $findings -Fields @{
        check = 'pack_missing'
        severity = 'critical'
        detail = 'self-model pack is missing or empty'
        file = $packPath
    }
}

if ($null -eq $pack) {
    $report = New-SelfModelDriftReport -Pack $null -Findings $findings -AgeHours $null
    if (-not $NoOutput) { Write-Host ($report | ConvertTo-Json -Depth 8) }
    return $report
}

$_volatileSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[void]$_volatileSources.Add('features/state.json')

if ($pack.PSObject.Properties['source_hashes'] -and $null -ne $pack.source_hashes) {
    foreach ($prop in @($pack.source_hashes.PSObject.Properties)) {
        $key = [string]$prop.Name
        $stored = [string]$prop.Value
        $sourcePath = Join-Path $root (Get-SelfModelDriftRelativePath -Path $key)
        $keyNorm = $key -replace '\\', '/'
        if ($_volatileSources.Contains($keyNorm)) {
            if (-not (Test-Path -LiteralPath $sourcePath)) {
                Add-SelfModelDriftFinding -Findings $findings -Fields @{
                    check = 'volatile_source_missing'
                    severity = 'medium'
                    file = $key
                }
                continue
            }
            try {
                $raw = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $raw | ConvertFrom-Json | Out-Null
                }
            } catch {
                Add-SelfModelDriftFinding -Findings $findings -Fields @{
                    check = 'volatile_source_corrupt'
                    severity = 'medium'
                    file = $key
                    detail = $_.Exception.Message
                }
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'source_missing'
                severity = 'high'
                file = $key
                stored = $stored
            }
            continue
        }
        $actual = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stored.ToLowerInvariant() -ne $actual) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'source_hash_drift'
                severity = 'medium'
                file = $key
                stored = $stored
                actual = $actual
            }
        }
    }
}

$features = @()
$registryPath = Join-Path $root 'features\registry.json'
try {
    $registry = Read-SelfModelDriftJson -Path $registryPath
    $features = @(ConvertTo-SelfModelDriftArray -Value $registry)
} catch {
    Add-SelfModelDriftFinding -Findings $findings -Fields @{
        check = 'registry_unreadable'
        severity = 'high'
        file = 'features/registry.json'
        detail = $_.Exception.Message
    }
}

foreach ($feature in $features) {
    $id = ''
    if ($null -ne $feature -and $feature.PSObject.Properties['id']) {
        $id = [string]$feature.id
    }
    if ($null -eq $feature -or -not $feature.PSObject.Properties['owner_files']) {
        continue
    }
    foreach ($owner in @($feature.owner_files)) {
        $ownerText = [string]$owner
        if ([string]::IsNullOrWhiteSpace($ownerText)) { continue }
        $ownerPath = Join-Path $root (Get-SelfModelDriftRelativePath -Path $ownerText)
        if (-not (Test-Path -LiteralPath $ownerPath)) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'owner_file_missing'
                severity = 'medium'
                feature = $id
                file = $ownerText
            }
        }
    }
}

$promptText = ''
if ($pack.PSObject.Properties['prompt_text']) {
    $promptText = [string]$pack.prompt_text
}

if ($features.Count -gt 0 -or (Test-Path -LiteralPath $registryPath)) {
    $realActive = @($features | Where-Object { [string]$_.status -eq 'active' }).Count
    $realOther = $features.Count - $realActive
    $activeMatch = [regex]::Match($promptText, 'active=(\d+)')
    $otherMatch = [regex]::Match($promptText, 'dormant_or_other=(\d+)')
    if (-not $activeMatch.Success -or -not $otherMatch.Success) {
        Add-SelfModelDriftFinding -Findings $findings -Fields @{
            check = 'counts_unparseable'
            severity = 'low'
        }
    } else {
        $packedActive = [int]$activeMatch.Groups[1].Value
        $packedOther = [int]$otherMatch.Groups[1].Value
        if ($packedActive -ne $realActive -or $packedOther -ne $realOther) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'status_counts_drift'
                severity = 'medium'
                packed_active = $packedActive
                real_active = $realActive
                packed_dormant_or_other = $packedOther
                real_dormant_or_other = $realOther
            }
        }
    }
}

$ageHours = $null
$thresholdHours = Get-SelfModelDriftThresholdHours -Root $root -ExplicitStaleHours $StaleHours
try {
    if ($pack.PSObject.Properties['generated_at'] -and -not [string]::IsNullOrWhiteSpace([string]$pack.generated_at)) {
        $generated = [datetime]::Parse([string]$pack.generated_at)
        $ageHours = ((Get-Date) - $generated).TotalHours
        if ($ageHours -gt $thresholdHours) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'stale_age'
                severity = 'medium'
                age_hours = [math]::Round($ageHours, 2)
                threshold_hours = $thresholdHours
            }
        }
    } else {
        Add-SelfModelDriftFinding -Findings $findings -Fields @{
            check = 'generated_at_missing'
            severity = 'medium'
        }
    }
} catch {
    Add-SelfModelDriftFinding -Findings $findings -Fields @{
        check = 'generated_at_unparseable'
        severity = 'medium'
        detail = $_.Exception.Message
    }
}

$promptBytes = [System.Text.Encoding]::UTF8.GetByteCount($promptText)
if ($promptBytes -gt 2560) {
    Add-SelfModelDriftFinding -Findings $findings -Fields @{
        check = 'size_cap_exceeded'
        severity = 'low'
        bytes = $promptBytes
        cap_bytes = 2560
    }
}

# Check: lib/*.ps1 without purpose header line
$libDir = Join-Path $root 'lib'
if (Test-Path -LiteralPath $libDir) {
    foreach ($psFile in @(Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File)) {
        $moduleName = $psFile.BaseName
        $headerPattern = '^#\s*(lib/)?' + [regex]::Escape($moduleName) + '\.ps1\s+--\s+'
        $firstLines = @(Get-Content -LiteralPath $psFile.FullName -TotalCount 5 -ErrorAction SilentlyContinue)
        $hasHeader = $false
        foreach ($line in $firstLines) {
            if ([string]$line -match $headerPattern) { $hasHeader = $true; break }
        }
        if (-not $hasHeader) {
            Add-SelfModelDriftFinding -Findings $findings -Fields @{
                check = 'undocumented_module'
                severity = 'info'
                file = 'lib/' + $psFile.Name
            }
        }
    }
}

$report = New-SelfModelDriftReport -Pack $pack -Findings $findings -AgeHours $ageHours
if (-not $NoOutput) {
    Write-Host ($report | ConvertTo-Json -Depth 8)
}
return $report
