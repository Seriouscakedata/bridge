# test-feature-verifier.ps1 -- contract tests for tools/feature-verifier.ps1.

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$verifierPath = Join-Path $bridgeRoot 'tools\feature-verifier.ps1'

$script:pass = 0
$script:fail = 0
function Assert-FeatureVerifier {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-feature-verifier-test-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path (Join-Path $tmp 'features') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'tools') -Force | Out-Null

  $registry = @(
    [ordered]@{ id = 'good-feature'; name = 'Good Feature'; scenarios = @('good-assert-log') },
    [ordered]@{ id = 'infra-feature'; name = 'Infra Feature'; scenarios = @('browser-fail') }
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $tmp 'features\registry.json'),
    ($registry | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding($false))
  )
  [System.IO.File]::WriteAllText((Join-Path $tmp 'features\state.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))

  $fakeScenario = @'
param([string]$Name, [int]$TimeoutSec = 60)
if ($Name -eq 'good-assert-log') {
  Write-Host 'PASS: POST returned ok=true'
  Write-Host 'PASS: POST returned an id'
  Write-Host 'PASS: item with marker found in backlog'
  [ordered]@{ ok = $true; name = $Name; errors = @(); log = @('OK: POST returned ok=true', 'OK: item with marker found in backlog') } | ConvertTo-Json -Compress
  exit 0
}
if ($Name -eq 'browser-fail') {
  [ordered]@{ ok = $false; name = $Name; error = 'browser failed before DOM/debug marker: chrome.exe headless exit -36863; stderr: crashpad access is denied'; debug_marker_seen = $false } | ConvertTo-Json -Compress
  exit 1
}
[ordered]@{ ok = $false; name = $Name; errors = @('unknown scenario') } | ConvertTo-Json -Compress
exit 1
'@
  [System.IO.File]::WriteAllText((Join-Path $tmp 'tools\scenario.ps1'), $fakeScenario, (New-Object System.Text.UTF8Encoding($true)))

  $stdout = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifierPath -BridgePath $tmp -NoChat -ScenarioTimeoutSec 5 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
  $jsonLine = $null
  foreach ($line in ($stdout -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) { $jsonLine = $trimmed }
  }
  $summary = $jsonLine | ConvertFrom-Json
  $state = Get-Content -LiteralPath (Join-Path $tmp 'features\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $digest = Get-Content -LiteralPath ([string]$summary.digest) -Raw -Encoding UTF8
  $backlogAddScenario = Get-Content -LiteralPath (Join-Path $bridgeRoot 'tools\scenarios\backlog-add.js') -Raw -Encoding UTF8
  $scenarioRunner = Get-Content -LiteralPath (Join-Path $bridgeRoot 'tools\scenario.ps1') -Raw -Encoding UTF8

  Assert-FeatureVerifier 'successful scenario assert-log is passing' ($state.'good-feature'.last_health -eq 'passing') ("health=$($state.'good-feature'.last_health)")
  Assert-FeatureVerifier 'successful scenario assert-log is not copied into error' ([string]$state.'good-feature'.scenario_results[0].error -eq '') ("error=$($state.'good-feature'.scenario_results[0].error)")
  Assert-FeatureVerifier 'single error field is preserved' ([string]$state.'infra-feature'.scenario_results[0].error -match 'browser failed before DOM/debug marker') ("error=$($state.'infra-feature'.scenario_results[0].error)")
  Assert-FeatureVerifier 'browser infrastructure failure is inconclusive' ($state.'infra-feature'.last_health -eq 'inconclusive') ("health=$($state.'infra-feature'.last_health)")
  Assert-FeatureVerifier 'inconclusive run does not exit as broken' ($exitCode -eq 0) ("exit=$exitCode stdout=$stdout")
  Assert-FeatureVerifier 'digest includes inconclusive section' ($digest -match 'Inconclusive features') ''
  Assert-FeatureVerifier 'backlog-add fixture avoids stale dedup trigger wording' (($backlogAddScenario -match 'Functional verifier backlog add flow marker') -and ($scenarioRunner -match 'Functional verifier backlog add flow marker') -and ($backlogAddScenario -notmatch '\[scenario test\] please ignore') -and ($scenarioRunner -notmatch '\[scenario test\] please ignore')) ''
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Feature verifier tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
