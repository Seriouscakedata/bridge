# lib/features.ps1 -- feature registry helpers

$ErrorActionPreference = 'Stop'

function Get-BridgeRootFeat {
    Split-Path -Parent $PSScriptRoot
}

function Get-RegistryPath {
    Join-Path (Get-BridgeRootFeat) 'features\registry.json'
}

function Get-StatePath {
    Join-Path (Get-BridgeRootFeat) 'features\state.json'
}

function Get-FeatureRegistry {
    # Returns raw registry array
    $p = Get-RegistryPath
    if (-not (Test-Path $p)) { return @() }
    $json = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return @($json)
}

function Get-FeatureState {
    $p = Get-StatePath
    if (-not (Test-Path $p)) { return @{} }
    $json = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    return $json | ConvertFrom-Json
}

function Save-FeatureState {
    param($State)
    $p = Get-StatePath
    $dir = Split-Path $p
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $State | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($p, $json, [System.Text.Encoding]::UTF8)
}

function Save-FeatureRegistry {
    param($Registry)
    $p = Get-RegistryPath
    $dir = Split-Path $p
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Registry) -Depth 8
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-Feature {
    param([string]$Id)
    $all = Get-FeatureRegistry
    return $all | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-AllFeatures {
    # Returns features merged with runtime state
    $registry = Get-FeatureRegistry
    $state = Get-FeatureState
    $stateDict = @{}
    if ($state -and $state.PSObject) {
        $state.PSObject.Properties | ForEach-Object { $stateDict[$_.Name] = $_.Value }
    }
    $result = @()
    foreach ($f in $registry) {
        $entry = [ordered]@{}
        $f.PSObject.Properties | ForEach-Object { $entry[$_.Name] = $_.Value }
        $s = $stateDict[$f.id]
        if ($s) {
            $entry['last_activated_at'] = if ($s.PSObject -and $s.last_activated_at) { $s.last_activated_at } else { $null }
            $entry['last_verified_at'] = if ($s.PSObject -and $s.last_verified_at) { $s.last_verified_at } else { $null }
            $entry['last_health'] = if ($s.PSObject -and $s.last_health) { $s.last_health } else { $null }
            $entry['last_signal_match'] = if ($s.PSObject -and $s.last_signal_match) { $s.last_signal_match } else { $null }
        }
        $result += [pscustomobject]$entry
    }
    return $result
}

function Update-FeatureActivations {
    # Walk all features with activation_signal, check signals, update state.json
    $root = Get-BridgeRootFeat
    $registry = Get-FeatureRegistry
    $state = Get-FeatureState
    $stateDict = @{}
    if ($state -and $state.PSObject) {
        $state.PSObject.Properties | ForEach-Object { $stateDict[$_.Name] = $_.Value }
    }
    $now = (Get-Date).ToString('o')
    foreach ($f in $registry) {
        if (-not $f.activation_signal) { continue }
        $sig = $f.activation_signal
        $kind = [string]$sig.kind
        $matched = $false
        if ($kind -eq 'log-pattern') {
            $logPath = Join-Path $root ([string]$sig.path)
            if (Test-Path $logPath) {
                try {
                    $tail = Get-Content $logPath -Tail 50 -Encoding UTF8
                    $rx = [string]$sig.regex
                    foreach ($line in $tail) {
                        if ($line -match $rx) { $matched = $true; break }
                    }
                } catch {}
            }
        } elseif ($kind -eq 'state-path') {
            $statePath = Join-Path $root 'state.json'
            if (Test-Path $statePath) {
                try {
                    $s = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    $key = [string]$sig.path
                    $val = $s.$key
                    if ($null -ne $val -and $val -ne '') { $matched = $true }
                } catch {}
            }
        }
        if ($matched) {
            if (-not $stateDict.ContainsKey($f.id)) { $stateDict[$f.id] = [pscustomobject]@{} }
            $entry = $stateDict[$f.id]
            if ($null -eq $entry -or -not $entry.PSObject) {
                $stateDict[$f.id] = [pscustomobject]@{ last_signal_match = $now; last_activated_at = $now }
            } else {
                Add-Member -InputObject $entry -MemberType NoteProperty -Name 'last_signal_match' -Value $now -Force
                Add-Member -InputObject $entry -MemberType NoteProperty -Name 'last_activated_at' -Value $now -Force
            }
        }
    }
    $newState = [pscustomobject]$stateDict
    Save-FeatureState $newState
    return $stateDict.Count
}

function Add-Feature {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Description,
        [string[]]$OwnerFiles = @(),
        [string]$OwnerFunction = $null,
        [string]$Trigger = 'on-demand',
        [string]$ExpectedFrequency = 'on-demand',
        [hashtable]$ActivationSignal = $null,
        [string[]]$Dependencies = @(),
        [string]$Layer = 'L2',
        [string]$Status = 'active'
    )
    $registry = @(Get-FeatureRegistry)
    if ($registry | Where-Object { $_.id -eq $Id }) {
        throw "Feature '$Id' already exists"
    }
    $sig = if ($ActivationSignal) { [pscustomobject]$ActivationSignal } else { [pscustomobject]@{ kind = 'none' } }
    $entry = [pscustomobject][ordered]@{
        id                   = $Id
        name                 = $Name
        description          = $Description
        owner_files          = $OwnerFiles
        owner_function       = $OwnerFunction
        trigger              = $Trigger
        expected_frequency   = $ExpectedFrequency
        activation_signal    = $sig
        scenarios            = @()
        dependencies         = $Dependencies
        layer                = $Layer
        status               = $Status
        scenario_recommended = $false
        created_at           = (Get-Date).ToString('yyyy-MM-dd')
        last_activated_at    = $null
        embedding            = $null
    }
    $registry += $entry
    Save-FeatureRegistry $registry
    return $entry
}

function Update-FeatureStatus {
    param(
        [string]$Id,
        [ValidateSet('active','dormant','broken','under_review')]
        [string]$Status
    )
    $registry = @(Get-FeatureRegistry)
    $found = $false
    foreach ($f in $registry) {
        if ($f.id -eq $Id) {
            Add-Member -InputObject $f -MemberType NoteProperty -Name 'status' -Value $Status -Force
            $found = $true; break
        }
    }
    if (-not $found) { throw "Feature '$Id' not found" }
    Save-FeatureRegistry $registry
}
