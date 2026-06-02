[CmdletBinding()]
param(
  [string]$BridgePath = $null
)

$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
  Split-Path -Parent $PSCommandPath
} else {
  (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($BridgePath)) {
  $BridgePath = Split-Path -Parent $scriptRoot
}

$testRoot = Join-Path $BridgePath 'tmp\feature-state-structure-test'
if (Test-Path -LiteralPath $testRoot) {
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $testRoot 'features') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testRoot 'tools') -Force | Out-Null

$registry = @(
  [ordered]@{ id = 'audit-self-diag'; name = 'Audit'; scenarios = @('features-registry.js') },
  [ordered]@{ id = 'backlog-curator'; name = 'Backlog'; scenarios = @('backlog-add.js') },
  [ordered]@{ id = 'message-cache'; name = 'Messages'; scenarios = @('message-send.js') },
  [ordered]@{ id = 'channel-switch'; name = 'Channels'; scenarios = @('channel-switch.js') }
)
$registry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $testRoot 'features\registry.json') -Encoding UTF8

$badKey = 'audit-self-diag backlog-curator message-cache channel-switch'
$legacyState = [ordered]@{
  $badKey = [ordered]@{
    last_verified_at = '2026-05-28T22:14:22.7461689+03:00'
    last_health = 'passing'
    scenario_results = @(
      [ordered]@{ scenario = 'features-registry'; ok = $true; error = '' },
      [ordered]@{ scenario = 'backlog-add'; ok = $true; error = '' }
    )
  }
  'audit-self-diag' = [ordered]@{ last_signal_match = '2026-05-31T08:50:16.0403791+03:00' }
}
$legacyState | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath (Join-Path $testRoot 'features\state.json') -Encoding UTF8

$scenarioScript = @'
param([string]$Name, [int]$TimeoutSec = 60)
$result = @{ ok = $true; errors = @(); name = $Name }
$result | ConvertTo-Json -Compress -Depth 4
'@
Set-Content -LiteralPath (Join-Path $testRoot 'tools\scenario.ps1') -Value $scenarioScript -Encoding UTF8

$verifier = Join-Path $BridgePath 'tools\feature-verifier.ps1'
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier -BridgePath $testRoot -ScenarioTimeoutSec 5 -NoChat 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  throw "feature-verifier failed with exit=$exitCode output=$output"
}

$statePath = Join-Path $testRoot 'features\state.json'
$raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
$state = $raw | ConvertFrom-Json
$topKeys = @($state.PSObject.Properties | ForEach-Object { $_.Name })
$spaceKeys = @($topKeys | Where-Object { $_ -match '\s' })
if ($spaceKeys.Count -gt 0) {
  throw "top-level keys with whitespace remain: $($spaceKeys -join ', ')"
}
foreach ($id in @('audit-self-diag','backlog-curator','message-cache','channel-switch')) {
  if ($topKeys -notcontains $id) { throw "missing feature state for $id" }
}
if (-not $state.'audit-self-diag'.scenario_results) { throw 'audit-self-diag scenario_results missing' }
if (-not $state.'backlog-curator'.scenario_results) { throw 'backlog-curator scenario_results missing' }
if (-not $state.'message-cache'.scenario_results) { throw 'message-cache scenario_results missing' }
if (-not $state.'channel-switch'.scenario_results) { throw 'channel-switch scenario_results missing' }

[pscustomobject]@{
  testPassed = $true
  verifierExitCode = $exitCode
  statePath = $statePath
  topKeyCount = $topKeys.Count
  whitespaceTopKeyCount = $spaceKeys.Count
  auditScenarioResultsPath = 'audit-self-diag.scenario_results'
  backlogScenarioResultsPath = 'backlog-curator.scenario_results'
} | ConvertTo-Json -Depth 5 -Compress
