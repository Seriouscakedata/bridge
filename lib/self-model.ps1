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

function ConvertTo-SelfModelRepoPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim() -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.ToLowerInvariant()
}

function Get-SelfModelOwnerFileSet {
    param([object[]]$Features)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($feature in $Features) {
        foreach ($owner in @($feature.owner_files)) {
            $path = ConvertTo-SelfModelRepoPath -Path ([string]$owner)
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                [void]$set.Add($path)
            }
        }
    }
    return $set
}

function Get-SelfModelFunctionNames {
    param(
        [string]$Path,
        [int]$Limit = 5
    )

    $tokens = $null
    $errors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast -or ($null -ne $errors -and $errors.Count -gt 0)) { return @() }
        return @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) |
                ForEach-Object { [string]$_.Name } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First $Limit)
    } catch {
        return @()
    }
}

function Get-SelfModelModulePurpose {
    param(
        [string]$Path,
        [string]$FileName
    )

    try {
        $line = [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8) | Select-Object -First 1
        if ($line -match ('^\s*#\s*(?:.+[\\/])?' + [regex]::Escape($FileName) + '\s+--\s*(.+?)\s*$')) {
            return $matches[1].Trim()
        }
    } catch {
        return '(no header)'
    }
    return '(no header)'
}

function Get-SelfModelUnregisteredModules {
    param(
        [string]$BridgeRoot,
        [object[]]$Features,
        [int]$Limit = 4
    )

    $ownerFiles = Get-SelfModelOwnerFileSet -Features $Features
    $libRoot = Join-Path $BridgeRoot 'lib'
    if (-not (Test-Path -LiteralPath $libRoot)) { return @() }

    $preferredRank = @{
        'delivery-mode' = 0
        'self-model' = 1
        'decision-contract' = 2
    }
    $modules = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $libRoot -Filter '*.ps1' -File | Sort-Object Name)) {
        $relative = ConvertTo-SelfModelRepoPath -Path ('lib/' + $file.Name)
        if ($ownerFiles.Contains($relative)) { continue }
        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $rank = 1000
        if ($preferredRank.ContainsKey($moduleName)) { $rank = [int]$preferredRank[$moduleName] }
        $modules += [pscustomobject]@{
            Name = $moduleName
            Purpose = Get-SelfModelModulePurpose -Path $file.FullName -FileName $file.Name
            Functions = @(Get-SelfModelFunctionNames -Path $file.FullName -Limit 3)
            Rank = $rank
        }
    }

    return @($modules |
        Sort-Object @{ Expression = { $_.Rank } }, @{ Expression = { $_.Name } } |
        Select-Object -First $Limit)
}

function Format-SelfModelModuleList {
    param(
        [object[]]$Modules,
        [int]$TotalCount
    )

    if ($TotalCount -eq 0) { return @('- none detected') }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($module in $Modules) {
        $fnText = ''
        if ($module.Functions.Count -gt 0) {
            $fnText = ' (fns: ' + (@($module.Functions) -join ', ') + ')'
        }
        [void]$lines.Add(('- ' + $module.Name + ': ' + $module.Purpose + $fnText))
    }
    $more = $TotalCount - $Modules.Count
    if ($more -gt 0) {
        [void]$lines.Add(('- (+' + $more + ' more)'))
    }
    return @($lines.ToArray())
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
    $activeTop = Select-SelfModelTopFeatures -Features $active -PreferredIds $preferred -Limit 6
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
    $allUnregisteredModules = @(Get-SelfModelUnregisteredModules -BridgeRoot $BridgeRoot -Features $features -Limit 1000)
    $moduleTop = @($allUnregisteredModules | Select-Object -First 3)
    $moduleLines = Format-SelfModelModuleList -Modules $moduleTop -TotalCount $allUnregisteredModules.Count

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('=== BRIDGE SELF-MODEL PACK v2.1/base ===')
    [void]$lines.Add('ARCH:')
    [void]$lines.Add('- scheduler starts supervisor; supervisor keeps server and channel drivers alive.')
    [void]$lines.Add('- server.ps1 exposes UI/API; driver.ps1 runs turns via planner/coder/critic.')
    [void]$lines.Add('- channel = project binding; main is bridge-self work, external channels are user projects.')
    [void]$lines.Add('- watchdog/ensure are recovery rails: smoke verify and rollback after bad commits.')
    [void]$lines.Add('- backlog claims project work; bridge control-plane needs operator tag or bridge_self_admission.')
    [void]$lines.Add('- self-model is read-only text from registry/state/code scan plus safety/arch facts.')
    [void]$lines.Add('')
    [void]$lines.Add('CRITICAL:')
    [void]$lines.Add('- Core path: scheduler -> supervisor -> server + drivers -> watchdog; keep prompt path fast and non-mutating.')
    [void]$lines.Add('- Critical modules: driver loop/prompt, memory/context/features, server API.')
    [void]$lines.Add('- main channel is bridge development; changes to bridge PS1 require BOM, ParseFile, smoke, and commit before DONE.')
    [void]$lines.Add('')
    [void]$lines.Add('FEATURES active:')
    [void]$lines.Add(('- top: ' + $activeSummary))
    [void]$lines.Add(('- counts: active=' + $active.Count + ', dormant_or_other=' + $dormant.Count + '; ' + $registryNote + '; ' + $stateNote))
    [void]$lines.Add('')
    [void]$lines.Add('FEATURES dormant:')
    [void]$lines.Add(('- top: ' + $dormantSummary))
    [void]$lines.Add('')
    [void]$lines.Add('MODULES (scanned, not in registry):')
    foreach ($moduleLine in $moduleLines) {
        [void]$lines.Add($moduleLine)
    }
    [void]$lines.Add('')
    [void]$lines.Add('SAFETY:')
    [void]$lines.Add('- Control plane edits are blocked unless operator-approved or admitted by bridge_self_canary gate.')
    [void]$lines.Add('- bridge_self_admission needs scope=bridge, non-external source, touch-set, canary, selftest+smoke, rollback.')
    [void]$lines.Add('- Never expose secrets; preserve memory recall; do not create a parallel memory store for self-model.')
    [void]$lines.Add('- PowerShell engine files must be UTF-8 BOM and pass Parser.ParseFile before use.')
    [void]$lines.Add('- Create control/restart.flag only after a verified PS1 diff; never for HTML/docs-only changes.')
    [void]$lines.Add('- Read-only generator must not write registry, state, runtime cache, memory, or project files.')
    [void]$lines.Add('')
    [void]$lines.Add('TESTS:')
    [void]$lines.Add('- Minimum gates: Parser.ParseFile for touched PS1, tools/self_model_smoke.ps1, then smoke.ps1.')
    [void]$lines.Add('- Self-model smoke checks size cap, sections, compact summary, and no source writes.')

    return (($lines.ToArray()) -join "`r`n")
}
