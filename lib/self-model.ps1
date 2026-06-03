# lib/self-model.ps1 -- read-only compact Bridge self-model generator

$ErrorActionPreference = 'Stop'

function Get-SelfModelBridgeRoot {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Split-Path -Parent $PSScriptRoot)
    }
    return (Get-Location).Path
}

function Read-SelfModelJson {
    param([string]$Path)

    $result = [ordered]@{
        Ok = $false
        Value = $null
        Error = ''
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Error = 'missing'
        return [pscustomobject]$result
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $result.Error = 'empty'
            return [pscustomobject]$result
        }
        $result.Value = $raw | ConvertFrom-Json
        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function ConvertTo-SelfModelArray {
    param($Value)

    $items = @($Value)
    if ($items.Count -eq 1 -and $items[0] -is [array]) {
        $items = @($items[0])
    }
    return @($items)
}

function Get-SelfModelFeatureId {
    param($Feature)
    if ($null -eq $Feature -or -not $Feature.PSObject -or -not $Feature.PSObject.Properties['id']) {
        return ''
    }
    return [string]$Feature.id
}

function Select-SelfModelTopFeatures {
    param(
        [object[]]$Features,
        [string[]]$PreferredIds,
        [int]$Limit = 8
    )

    $rank = @{}
    for ($i = 0; $i -lt $PreferredIds.Count; $i++) {
        $rank[$PreferredIds[$i]] = $i
    }
    return @($Features |
        Sort-Object @{ Expression = {
                $id = Get-SelfModelFeatureId $_
                if ($rank.ContainsKey($id)) { return [int]$rank[$id] }
                return 1000
            } }, @{ Expression = {
                if ($_.PSObject.Properties['layer']) { return [string]$_.layer }
                return ''
            } }, @{ Expression = { Get-SelfModelFeatureId $_ } } |
        Select-Object -First $Limit)
}

function Format-SelfModelFeatureList {
    param(
        [object[]]$Features,
        [string]$EmptyText
    )

    if ($Features.Count -eq 0) { return $EmptyText }
    $parts = @()
    foreach ($f in $Features) {
        $id = Get-SelfModelFeatureId $f
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $layer = ''
        if ($f.PSObject.Properties['layer'] -and -not [string]::IsNullOrWhiteSpace([string]$f.layer)) {
            $layer = '/' + [string]$f.layer
        }
        $fn = ''
        if ($f.PSObject.Properties['owner_function'] -and -not [string]::IsNullOrWhiteSpace([string]$f.owner_function)) {
            $fn = ':' + [string]$f.owner_function
        }
        $parts += ($id + $layer + $fn)
    }
    if ($parts.Count -eq 0) { return $EmptyText }
    return ($parts -join '; ')
}

function Get-SelfModelPack {
    [CmdletBinding()]
    param(
        [string]$BridgeRoot = $null
    )

    if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
        $BridgeRoot = Get-SelfModelBridgeRoot
    }

    $registryPath = Join-Path $BridgeRoot 'features\registry.json'
    $statePath = Join-Path $BridgeRoot 'features\state.json'
    $registryRead = Read-SelfModelJson -Path $registryPath
    $stateRead = Read-SelfModelJson -Path $statePath

    $features = @()
    if ($registryRead.Ok) {
        $features = ConvertTo-SelfModelArray -Value $registryRead.Value
    }
    $active = @($features | Where-Object { ([string]$_.status).ToLowerInvariant() -eq 'active' })
    $dormant = @($features | Where-Object { ([string]$_.status).ToLowerInvariant() -ne 'active' })

    $preferred = @(
        'intent-classifier',
        'fast-lane',
        'critic',
        'decision-contract',
        'project-autopilot',
        'worker-pool',
        'memory-recall',
        'semantic-code-memory',
        'auditor',
        'doctor'
    )
    $activeTop = Select-SelfModelTopFeatures -Features $active -PreferredIds $preferred -Limit 8
    $dormantTop = Select-SelfModelTopFeatures -Features $dormant -PreferredIds @() -Limit 5

    $registryNote = 'registry ok'
    if (-not $registryRead.Ok) {
        $registryNote = 'registry unreadable: ' + $registryRead.Error
    }
    $stateNote = 'state ok'
    if (-not $stateRead.Ok) {
        $stateNote = 'state unreadable: ' + $stateRead.Error
    }

    $activeSummary = Format-SelfModelFeatureList -Features $activeTop -EmptyText 'none detected'
    $dormantSummary = Format-SelfModelFeatureList -Features $dormantTop -EmptyText 'none in registry'

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('=== BRIDGE SELF-MODEL PACK v1/base ===')
    [void]$lines.Add('ARCH:')
    [void]$lines.Add('- scheduler/Task Scheduler starts supervisor; supervisor keeps server and channel drivers alive.')
    [void]$lines.Add('- server.ps1 exposes local UI/API; driver.ps1 runs task turns and calls planner/coder/critic.')
    [void]$lines.Add('- channel = project binding; channels/main is bridge-self work, external channels are user projects.')
    [void]$lines.Add('- watchdog/ensure scripts are recovery rails; they verify smoke and can roll back after bad commits.')
    [void]$lines.Add('- features registry describes capabilities; state is runtime evidence and may be stale/corrupt.')
    [void]$lines.Add('- self-model v1 is read-only text generated from registry/state plus fixed safety/arch facts.')
    [void]$lines.Add('')
    [void]$lines.Add('CRITICAL:')
    [void]$lines.Add('- Core path: scheduler -> supervisor -> server + drivers -> watchdog; keep prompt path fast and non-mutating.')
    [void]$lines.Add('- Critical modules: driver loop/prompt, lib/common/channels/memory/project-context/features, server API, supervisor/watchdog.')
    [void]$lines.Add('- main channel is bridge development; changes to bridge PS1 require BOM, ParseFile, smoke, and commit before DONE.')
    [void]$lines.Add('')
    [void]$lines.Add('FEATURES active:')
    [void]$lines.Add(('- top: ' + $activeSummary))
    [void]$lines.Add(('- counts: active=' + $active.Count + ', dormant_or_other=' + $dormant.Count + '; ' + $registryNote + '; ' + $stateNote))
    [void]$lines.Add('')
    [void]$lines.Add('FEATURES dormant:')
    [void]$lines.Add(('- top: ' + $dormantSummary))
    [void]$lines.Add('- Treat dormant/broken entries as risk signals, not authority; verify against code/tests before changing behavior.')
    [void]$lines.Add('')
    [void]$lines.Add('SAFETY:')
    [void]$lines.Add('- Do not autonomously edit control plane: supervisor.ps1, watchdog.ps1, circuit-breaker, restart-limit, script-integrity, or core driver loop.')
    [void]$lines.Add('- Never expose secrets; preserve memory recall; do not create a parallel memory store for self-model.')
    [void]$lines.Add('- PowerShell engine files must be UTF-8 BOM and pass Parser.ParseFile before use.')
    [void]$lines.Add('- Create control/restart.flag only after a verified PS1 diff; never for HTML/docs-only changes.')
    [void]$lines.Add('- Read-only generator must not write registry, state, runtime cache, memory, or project files.')
    [void]$lines.Add('')
    [void]$lines.Add('TESTS:')
    [void]$lines.Add('- Minimum gates: Parser.ParseFile for touched PS1, tools/self_model_smoke.ps1, then smoke.ps1.')
    [void]$lines.Add('- Self-model smoke checks size cap, required sections, compact feature summary, and no source writes.')

    return (($lines.ToArray()) -join "`r`n")
}
