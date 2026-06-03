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
$driftScript = Join-Path $scriptRoot 'self-model-drift.ps1'
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("drift-smoke-" + [guid]::NewGuid().ToString('N'))

function Write-SmokeUtf8NoBom {
    param(
        [string]$Path,
        [AllowEmptyString()][string]$Text
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function New-SmokeRootPair {
    param([string]$Name)

    $caseRoot = Join-Path $fixtureRoot $Name
    $br = Join-Path $caseRoot 'bridge'
    $rr = Join-Path $caseRoot 'runtime'
    New-Item -ItemType Directory -Path (Join-Path $br 'features') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rr 'self-model') -Force | Out-Null
    return [pscustomobject]@{
        BridgeRoot = $br
        RuntimeRoot = $rr
        PackPath = Join-Path $rr 'self-model\main.pack.json'
    }
}

function New-FixturePack {
    param(
        [string]$RuntimeRoot,
        [datetime]$GeneratedAt = (Get-Date),
        [hashtable]$SourceHashes = @{},
        [string]$PromptText = 'active=0, dormant_or_other=0',
        [bool]$Stale = $false
    )

    $packDir = Join-Path $RuntimeRoot 'self-model'
    New-Item -ItemType Directory -Path $packDir -Force | Out-Null
    $pack = [ordered]@{
        version = 'self-model-pack/v1'
        generated_at = $GeneratedAt.ToString('o')
        source_hashes = [pscustomobject]$SourceHashes
        stale = $Stale
        prompt_text = $PromptText
    }
    Write-SmokeUtf8NoBom -Path (Join-Path $packDir 'main.pack.json') -Text ($pack | ConvertTo-Json -Depth 8)
}

function Test-SmokeFinding {
    param(
        $Result,
        [string]$Check
    )

    foreach ($finding in @($Result.findings)) {
        if ([string]$finding.check -eq $Check) {
            return $true
        }
    }
    return $false
}

function Invoke-DriftSmoke {
    param(
        [string]$BridgeRoot,
        [string]$RuntimeRoot,
        [int]$StaleHours = 24
    )

    return (& $driftScript -BridgeRoot $BridgeRoot -RuntimeRoot $RuntimeRoot -StaleHours $StaleHours -NoOutput)
}

function Update-FeatureActivations {
    $script:UpdateFeatureActivationsCalls++
    throw 'Update-FeatureActivations must not be called by self-model drift audit'
}

$tests = [ordered]@{
    missingOwnerFile = $false
    staleSourceHash = $false
    packNormNoFindings = $false
    updateFeatureActivationsNotCalled = $false
}
$script:UpdateFeatureActivationsCalls = 0

try {
    $case1 = New-SmokeRootPair -Name 'missing-owner-file'
    Write-SmokeUtf8NoBom -Path (Join-Path $case1.BridgeRoot 'features\registry.json') -Text @'
[
  {
    "id": "test-feat",
    "status": "active",
    "owner_files": ["lib/missing-file.ps1"]
  }
]
'@
    New-FixturePack -RuntimeRoot $case1.RuntimeRoot -PromptText 'active=1, dormant_or_other=0'
    $result1 = Invoke-DriftSmoke -BridgeRoot $case1.BridgeRoot -RuntimeRoot $case1.RuntimeRoot
    $tests.missingOwnerFile = Test-SmokeFinding -Result $result1 -Check 'owner_file_missing'
    if (-not $tests.missingOwnerFile) { throw 'missing owner_file did not produce owner_file_missing finding' }

    $case2 = New-SmokeRootPair -Name 'stale-source-hash'
    Write-SmokeUtf8NoBom -Path (Join-Path $case2.BridgeRoot 'features\registry.json') -Text '[]'
    Write-SmokeUtf8NoBom -Path (Join-Path $case2.BridgeRoot 'features\state.json') -Text '{}'
    New-FixturePack -RuntimeRoot $case2.RuntimeRoot -SourceHashes @{ 'features/registry.json' = ('deadbeef' * 8) } -PromptText 'active=0, dormant_or_other=0'
    $result2 = Invoke-DriftSmoke -BridgeRoot $case2.BridgeRoot -RuntimeRoot $case2.RuntimeRoot
    $tests.staleSourceHash = Test-SmokeFinding -Result $result2 -Check 'source_hash_drift'
    if (-not $tests.staleSourceHash) { throw 'stale source hash did not produce source_hash_drift finding' }

    $case3 = New-SmokeRootPair -Name 'pack-norm'
    New-Item -ItemType Directory -Path (Join-Path $case3.BridgeRoot 'lib') -Force | Out-Null
    Write-SmokeUtf8NoBom -Path (Join-Path $case3.BridgeRoot 'lib\t.ps1') -Text ''
    $registry3Path = Join-Path $case3.BridgeRoot 'features\registry.json'
    Write-SmokeUtf8NoBom -Path $registry3Path -Text @'
[
  {
    "id": "t",
    "status": "active",
    "owner_files": ["lib/t.ps1"]
  }
]
'@
    $registry3Hash = (Get-FileHash -LiteralPath $registry3Path -Algorithm SHA256).Hash.ToLowerInvariant()
    New-FixturePack -RuntimeRoot $case3.RuntimeRoot -SourceHashes @{ 'features/registry.json' = $registry3Hash } -PromptText 'active=1, dormant_or_other=0'
    $result3 = Invoke-DriftSmoke -BridgeRoot $case3.BridgeRoot -RuntimeRoot $case3.RuntimeRoot
    $tests.packNormNoFindings = ([bool]$result3.ok -and @($result3.findings).Count -eq 0)
    if (-not $tests.packNormNoFindings) {
        throw ('normal pack produced findings: ' + (($result3.findings | ConvertTo-Json -Depth 5 -Compress)))
    }
    $tests.updateFeatureActivationsNotCalled = ($script:UpdateFeatureActivationsCalls -eq 0)
    if (-not $tests.updateFeatureActivationsNotCalled) {
        throw 'Update-FeatureActivations was called'
    }

    [pscustomobject]@{
        testPassed = ($tests.missingOwnerFile -and $tests.staleSourceHash -and $tests.packNormNoFindings -and $tests.updateFeatureActivationsNotCalled)
        tests = [pscustomobject]$tests
    } | ConvertTo-Json -Depth 5 -Compress
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
