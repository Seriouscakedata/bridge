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
$repoRoot = Split-Path -Parent $scriptRoot

. (Join-Path $repoRoot 'lib\self-model.ps1')

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Get-SourceRow {
    param(
        [object[]]$Rows,
        [string]$Source
    )
    $match = @($Rows | Where-Object { [string]$_.source -eq $Source })
    if ($match.Count -ne 1) {
        throw "source row not found: $Source"
    }
    return $match[0]
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-self-model-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    foreach ($dir in @(
            'channels\main',
            'control',
            'features'
        )) {
        New-Item -ItemType Directory -Path (Join-Path $tempRoot $dir) -Force | Out-Null
    }

    [System.IO.File]::WriteAllText((Join-Path $tempRoot 'control\active_channel'), 'main', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $tempRoot 'features\registry.json'), '[]', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $tempRoot 'features\state.json'), '{}', [System.Text.Encoding]::UTF8)

    $backlogLines = @(
        '{"id":"r1","from":"reflect","status":"new","text":"r1"}',
        '{"id":"r1","from":"reflect","status":"rejected","text":"r1","auto_curator":{"verdict":"drop","model":"curator-v1"}}',
        '{"id":"r2","from":"reflect","status":"approved","text":"r2"}',
        '{"id":"r3","from":"reflect","status":"done","text":"r3"}',
        '{"id":"a1","from":"audit-deep-codex","status":"done","text":"a1"}',
        '{"id":"a2","from":"audit-deep-codex","status":"new","text":"a2"}',
        '{"id":"a2","from":"audit-deep-codex","status":"auto-dropped","text":"a2"}',
        '{"id":"a3","from":"audit-deep-codex","status":"held","text":"a3","auto_curator":{"verdict":"drop","model":"queue-governor-v1"}}',
        '{"id":"t1","from":"tiny-source","status":"auto-dropped","text":"t1"}'
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $tempRoot 'channels\main\backlog.jsonl'),
        (($backlogLines -join "`n") + "`n"),
        [System.Text.Encoding]::UTF8
    )

    $stats = Get-SelfModelIdeaSourceStats -BridgeRoot $tempRoot -MinTerminalSample 2 -MaxSources 4
    Assert-True ($stats.total_items -eq 7) 'last-line-wins fold failed'
    Assert-True ($stats.channel -eq 'main') 'wrong channel resolved'

    $reflect = Get-SourceRow -Rows $stats.sources -Source 'reflect'
    $audit = Get-SourceRow -Rows $stats.sources -Source 'audit-deep-codex'
    $tiny = Get-SourceRow -Rows $stats.sources -Source 'tiny-source'

    Assert-True ($reflect.total -eq 3) 'reflect total mismatch'
    Assert-True ($reflect.terminal -eq 2) 'reflect terminal mismatch'
    Assert-True ($reflect.open -eq 1) 'reflect open mismatch'
    Assert-True ($reflect.done -eq 1) 'reflect done mismatch'
    Assert-True ($reflect.dropped -eq 1) 'reflect dropped mismatch'
    Assert-True ([Math]::Abs([double]$reflect.drop_rate - 0.5) -lt 0.001) 'reflect drop rate mismatch'

    Assert-True ($audit.total -eq 3) 'audit total mismatch'
    Assert-True ($audit.terminal -eq 3) 'audit terminal mismatch'
    Assert-True ($audit.open -eq 0) 'audit open mismatch'
    Assert-True ($audit.done -eq 1) 'audit done mismatch'
    Assert-True ($audit.dropped -eq 2) 'audit dropped mismatch'
    Assert-True ([Math]::Abs([double]$audit.drop_rate - 0.67) -lt 0.001) 'audit drop rate mismatch'

    Assert-True ($tiny.total -eq 1) 'tiny-source total mismatch'
    Assert-True (-not [bool]$tiny.eligible_for_risk) 'min sample threshold not enforced'

    $risky = @($stats.risky_sources)
    Assert-True ($risky.Count -eq 2) 'unexpected risky source count'
    Assert-True ([string]$risky[0].source -eq 'audit-deep-codex') 'risky source ordering mismatch'
    Assert-True ([string]$risky[1].source -eq 'reflect') 'second risky source mismatch'

    $summary = Format-SelfModelIdeaSourceSummary -Stats $stats -MaxSources 2
    Assert-True ($summary -match '^IDEA SOURCES:\s+') 'summary prefix missing'
    Assert-True ($summary.Contains('audit-deep-codex')) 'summary missing audit source'
    Assert-True ($summary.Contains('reflect')) 'summary missing reflect source'
    Assert-True (-not $summary.Contains('tiny-source')) 'summary should omit low-sample source'

    $guidance = Get-SelfModelIdeaSourceGuidance -BridgeRoot $tempRoot -MinTerminalSample 2 -MaxSources 2
    Assert-True ($guidance.Contains('audit-deep-codex')) 'guidance missing audit source'
    Assert-True ($guidance.Contains('reflect')) 'guidance missing reflect source'
    Assert-True ($guidance -match 'terminal.+2') 'guidance missing threshold'

    $pack = Get-SelfModelPack -BridgeRoot $tempRoot
    Assert-True ($pack -match '(?m)^IDEA SOURCES:\s+') 'pack missing idea sources line'
    Assert-True ($pack.Contains('audit-deep-codex')) 'pack missing top risky source'
    Assert-True (-not $pack.Contains('backlog.jsonl')) 'pack leaked backlog path'

    $reflectScript = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'reflect.ps1'), [System.Text.Encoding]::UTF8)
    Assert-True ($reflectScript -match 'drop-rate;.+evidence') 'reflect prompt guidance missing'

    [pscustomobject]@{
        ok = $true
        total_items = $stats.total_items
        risky_sources = @($risky | ForEach-Object { [string]$_.source })
        pack_has_metric = $true
        prompt_has_guidance = $true
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
