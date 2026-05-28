# lib/features.ps1 -- feature registry helpers

$ErrorActionPreference = 'Stop'

function Get-BridgeRootFeat {
    Split-Path -Parent $PSScriptRoot
}

function Get-RegistryPath {
    Join-Path (Get-BridgeRootFeat) 'features\registry.json'
}

function Get-FeatureStatePath {
    # 2026-05-28 fix: was Get-StatePath — name collision with lib/common.ps1's
    # Get-StatePath which resolves to channels/<slug>/state.json. Loading
    # features.ps1 silently shadowed the channel-aware function, so Read-State
    # in server began reading features/state.json instead of the real channel
    # state. Result: API returned status=idle / heartbeat=null / task_turn=0
    # while the actual driver was working — UI showed "Heartbeat устарел 494431ч"
    # because 0/null heartbeat parsed as 1970-epoch, 56 years from now.
    Join-Path (Get-BridgeRootFeat) 'features\state.json'
}

function Get-FeatureRegistry {
    # Returns raw registry array
    $p = Get-RegistryPath
    if (-not (Test-Path $p)) { return @() }
    $json = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (@($json).Count -eq 1 -and $json[0].PSObject -and $json[0].PSObject.Properties['value']) {
        return @($json[0].value)
    }
    if ($json.PSObject -and $json.PSObject.Properties['value']) {
        return @($json.value)
    }
    return @($json)
}

function ConvertTo-FeatureStateDictionary {
    param($State)
    $dict = @{}
    $skip = @(
        'Count', 'Length', 'LongLength', 'Rank', 'SyncRoot',
        'IsReadOnly', 'IsFixedSize', 'IsSynchronized', 'Keys', 'Values'
    )
    if ($null -eq $State) { return $dict }
    if ($State -is [System.Collections.IDictionary]) {
        foreach ($key in $State.Keys) {
            $name = [string]$key
            if ($skip -notcontains $name) { $dict[$name] = $State[$key] }
        }
        return $dict
    }
    if ($State.PSObject) {
        foreach ($prop in $State.PSObject.Properties) {
            if ($skip -notcontains $prop.Name) { $dict[$prop.Name] = $prop.Value }
        }
    }
    return $dict
}

function Get-FeatureDottedValue {
    param(
        $Object,
        [string]$Path
    )
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $null }
            $current = $current[$part]
        } elseif ($current.PSObject -and $current.PSObject.Properties[$part]) {
            $current = $current.PSObject.Properties[$part].Value
        } else {
            return $null
        }
    }
    return $current
}

function Get-FeatureState {
    $p = Get-FeatureStatePath
    if (-not (Test-Path $p)) { return @{} }
    $json = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    return $json | ConvertFrom-Json
}

function Save-FeatureState {
    param($State)
    $p = Get-FeatureStatePath
    $dir = Split-Path $p
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dict = ConvertTo-FeatureStateDictionary $State
    $ordered = [ordered]@{}
    foreach ($key in ($dict.Keys | Sort-Object)) { $ordered[$key] = $dict[$key] }
    $json = ([pscustomobject]$ordered) | ConvertTo-Json -Depth 6 -Compress
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
    $stateDict = ConvertTo-FeatureStateDictionary $state
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
    $stateDict = ConvertTo-FeatureStateDictionary $state
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
            # 2026-05-28 fix: was '$root\state.json' (root-level), but channel state
            # lives at channels/<slug>/state.json. Use channel-aware resolver.
            $slug = 'main'
            try { if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $slug = [string](Get-EffectiveChannel) } } catch {}
            $statePath = Join-Path $root (Join-Path 'channels' (Join-Path $slug 'state.json'))
            if (Test-Path $statePath) {
                try {
                    $s = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    $key = [string]$sig.path
                    $val = Get-FeatureDottedValue -Object $s -Path $key
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
    Save-FeatureState $stateDict
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


# === Phase 2: semantic anti-duplication gate ===
# Goal: when a new user task arrives with non-trivial length, compute its
# embedding and compare against the feature registry. Surface top matches
# (sim >= 0.85) to the planner via Build-PromptHistory so it can decide
# "extend feature X" vs "create new Y" with eyes open. Document vectors stay in
# the process-local Get-Embedding cache; registry.json must remain a compact
# declarative registry, not a persistence layer for 1536-dim vectors.
# Reuses Get-Embedding/Get-CosineSimilarity from lib/memory.ps1.

function Get-FeatureEmbedding {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        $Feature = $null
    )
    if (-not $Feature) { $Feature = Get-Feature -Id $Id }
    if (-not $Feature) { return $null }
    try {
        if (($Feature.PSObject.Properties.Name -contains 'embedding') -and $Feature.embedding -and @($Feature.embedding).Count -gt 0) {
            return @($Feature.embedding)
        }
    } catch {}
    if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) { return $null }
    $text = ([string]$Feature.name) + ': ' + ([string]$Feature.description)
    $vec = $null
    try { $vec = Get-Embedding -Text $text -TaskType 'RETRIEVAL_DOCUMENT' } catch { $vec = $null }
    if (-not $vec) { return $null }
    return @($vec)
}

function Test-FeatureSimilarity {
    param(
        [string]$TaskText,
        [int]$TopK = 3,
        [double]$Threshold = 0.7
    )
    if ([string]::IsNullOrWhiteSpace($TaskText)) { return @() }
    if ($TaskText.Trim().Length -lt 60) { return @() }
    if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) { return @() }
    if (-not (Get-Command Get-CosineSimilarity -ErrorAction SilentlyContinue)) { return @() }
    $qvec = $null
    try { $qvec = Get-Embedding -Text $TaskText -TaskType 'RETRIEVAL_QUERY' } catch { $qvec = $null }
    if (-not $qvec) { return @() }
    $registry = @(Get-FeatureRegistry)
    if ($registry.Count -eq 0) { return @() }
    $scored = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $registry) {
        $vec = Get-FeatureEmbedding -Id ([string]$f.id) -Feature $f
        if (-not $vec) { continue }
        $sim = 0.0
        try { $sim = [double](Get-CosineSimilarity -A $qvec -B $vec) } catch { $sim = 0.0 }
        if ($sim -ge $Threshold) {
            [void]$scored.Add([pscustomobject]@{ similarity = $sim; feature = $f })
        }
    }
    return @($scored | Sort-Object @{Expression='similarity';Descending=$true} | Select-Object -First $TopK)
}

function Format-FeatureSimilarityForPrompt {
    param($Matches)
    if (-not $Matches) { return '' }
    $arr = @($Matches)
    if ($arr.Count -eq 0) { return '' }
    $top = $arr[0]
    if ([double]$top.similarity -lt 0.85) { return '' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('РљРЎ АНТИ-ДУБЛИРОВАНИЕ (эмбеддинги нашли похожие фичи):')
    foreach ($m in $arr) {
        $sim = [double]$m.similarity
        $f = $m.feature
        $desc = ([string]$f.description)
        if ($desc.Length -gt 80) { $desc = $desc.Substring(0, 80) + '…' }
        $files = ''
        try { if ($f.owner_files) { $files = ' (' + ([string]::Join(', ', @($f.owner_files))) + ')' } } catch {}
        [void]$lines.Add(("  • {0,-22} sim={1:N2}  {2}{3}" -f $f.id, $sim, $desc, $files))
    }
    [void]$lines.Add('')
    [void]$lines.Add('ПРАВИЛО: оцени — задача является РАСШИРЕНИЕМ одной из перечисленных фич?')
    [void]$lines.Add('Если да — план «доработать feature_id», НЕ «создать новое». Если новая —')
    [void]$lines.Add('явно обоснуй чем отличается. Жалоба пользователя: «у нас 2 почти')
    [void]$lines.Add('одинаковых функционала, доработать старую эффективнее».')
    return ([string]::Join("`n", $lines.ToArray()))
}
