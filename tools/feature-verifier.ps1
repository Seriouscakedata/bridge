[CmdletBinding()]
param(
  [string]$BridgePath = $null,
  [int]$ScenarioTimeoutSec = 60,
  [switch]$Force,
  [switch]$NoChat
)

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

# tools\feature-verifier.ps1 -- Phase 4 of the feature-registry initiative.
#
# Walks the effective channel's features/registry.json. For each feature with non-empty `scenarios`,
# runs every named scenario via tools/scenario.ps1 (headless Chrome). Collects
# pass/fail, updates features/state.json with last_verified_at + last_health
# per feature, writes a digest markdown to audit/feature-verifier-YYYY-MM-DD.md.
#
# Health states:
#   passing    -- all linked scenarios passed
#   broken     -- at least one scenario failed (immediate chat alert)
#   untested   -- feature has no scenarios in registry yet
#   inconclusive -- scenario errored before producing a result

$ErrorActionPreference = 'Stop'
try {
  $commonLib = Join-Path $BridgePath 'lib\common.ps1'
  if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
} catch {}
try {
  $channelsLib = Join-Path $BridgePath 'lib\channels.ps1'
  if (-not (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $channelsLib -PathType Leaf)) { . $channelsLib }
} catch {}

function Get-AuthHeaders {
  # auth.json lives in the protected store outside the bridge (Ф0.4); fall back to legacy in-bridge path.
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authPath = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $BridgePath 'auth.json' }
  if (-not (Test-Path -LiteralPath $authPath)) { return @{} }
  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $auth.user) { return @{} }
    $pair = "$($auth.user):$($auth.password)"
    return @{ Authorization = ('Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))) }
  } catch { return @{} }
}

function Send-VerifierChatAlert {
  param([string]$Text)
  if ($NoChat) { return }
  try {
    $h = Get-AuthHeaders
    $body = @{ text = $Text } | ConvertTo-Json -Compress -Depth 4
    Invoke-RestMethod -Uri 'http://localhost:8787/api/say' -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $h -TimeoutSec 10 | Out-Null
  } catch {}
}

function ConvertTo-FeatureVerifierRegistryList {
  param($Value)
  $items = New-Object 'System.Collections.Generic.List[object]'

  function Add-RegistryValue {
    param($Item)
    if ($null -eq $Item) { return }
    if ($Item -is [System.Array]) {
      foreach ($child in @($Item)) { Add-RegistryValue -Item $child }
      return
    }
    if ($Item.PSObject -and $Item.PSObject.Properties['value']) {
      Add-RegistryValue -Item $Item.value
      return
    }
    if ($Item.PSObject -and $Item.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$Item.id)) {
      [void]$items.Add($Item)
    }
  }

  Add-RegistryValue -Item $Value
  return @($items.ToArray())
}

function Repair-FeatureVerifierState {
  param(
    [hashtable]$State,
    [object[]]$Registry
  )
  if (-not $State) { return 0 }

  $scenarioOwners = @{}
  foreach ($f in @($Registry)) {
    $id = [string]$f.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $scenarios = @()
    try {
      if ($f.scenarios) { $scenarios = @($f.scenarios) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } }
    } catch {}
    foreach ($scn in $scenarios) {
      $scenarioName = [System.IO.Path]::GetFileNameWithoutExtension([string]$scn)
      if (-not [string]::IsNullOrWhiteSpace($scenarioName)) { $scenarioOwners[$scenarioName] = $id }
    }
  }

  $removed = 0
  foreach ($key in @($State.Keys)) {
    if ([string]$key -notmatch '\s') { continue }
    $entry = $State[$key]
    $scenarioResults = @()
    try {
      if ($entry -and $entry.PSObject -and $entry.PSObject.Properties['scenario_results'] -and $entry.scenario_results) {
        $scenarioResults = @($entry.scenario_results)
      }
    } catch {}

    foreach ($sr in $scenarioResults) {
      $scenarioName = [string]$sr.scenario
      if ([string]::IsNullOrWhiteSpace($scenarioName) -or -not $scenarioOwners.ContainsKey($scenarioName)) { continue }
      $ownerId = [string]$scenarioOwners[$scenarioName]
      $target = $State[$ownerId]
      if (-not $target -or -not $target.PSObject) { $target = [pscustomobject]@{} }

      $verifiedAt = $null
      $aggregateHealth = $null
      try {
        if ($entry.PSObject.Properties['last_verified_at']) { $verifiedAt = $entry.last_verified_at }
        if ($entry.PSObject.Properties['last_health']) { $aggregateHealth = $entry.last_health }
      } catch {}
      if ($verifiedAt) { Add-Member -InputObject $target -MemberType NoteProperty -Name 'last_verified_at' -Value $verifiedAt -Force }
      $health = if ($null -ne $sr.ok -and -not [bool]$sr.ok) { 'broken' } elseif ($aggregateHealth) { [string]$aggregateHealth } else { 'passing' }
      Add-Member -InputObject $target -MemberType NoteProperty -Name 'last_health' -Value $health -Force

      $existingResults = @()
      try {
        if ($target.PSObject.Properties['scenario_results'] -and $target.scenario_results) {
          $existingResults = @($target.scenario_results) | Where-Object { [string]$_.scenario -ne $scenarioName }
        }
      } catch {}
      Add-Member -InputObject $target -MemberType NoteProperty -Name 'scenario_results' -Value @($existingResults + $sr) -Force
      $State[$ownerId] = $target
    }

    $State.Remove($key)
    $removed++
  }
  return $removed
}

$scope = $null
try {
  if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { $scope = Get-EffectiveScope }
} catch {}
if (-not $scope) {
  $featuresRoot = Join-Path $BridgePath 'features'
  $scope = [pscustomobject]@{
    slug = 'main'
    features_root = $featuresRoot
    features_registry = (Join-Path $featuresRoot 'registry.json')
    features_state = (Join-Path $featuresRoot 'state.json')
  }
}

$registryPath = [string]$scope.features_registry
if (-not (Test-Path -LiteralPath $registryPath)) {
  $summary = [ordered]@{
    ts = (Get-Date).ToString('o')
    channel = [string]$scope.slug
    skipped = $true
    reason = 'no_registry'
    registry = $registryPath
  }
  $summary | ConvertTo-Json -Depth 10 -Compress
  exit 0
}
$registry = @(Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$registry = @(ConvertTo-FeatureVerifierRegistryList -Value $registry)

$statePath = [string]$scope.features_state
$state = @{}
if (Test-Path -LiteralPath $statePath) {
  try {
    $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $loaded = $raw | ConvertFrom-Json
      if ($loaded -and $loaded.PSObject) {
        foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
      }
    }
  } catch {}
}
[void](Repair-FeatureVerifierState -State $state -Registry $registry)

$now = (Get-Date).ToString('o')
$results = New-Object 'System.Collections.Generic.List[object]'
$brokenCount = 0
$passingCount = 0
$untestedCount = 0

foreach ($f in $registry) {
  $id = [string]$f.id
  if (-not $id) { continue }
  $scenarios = @()
  try {
    if ($f.scenarios) { $scenarios = @($f.scenarios) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } }
  } catch {}

  if ($scenarios.Count -eq 0) {
    $untestedCount++
    [void]$results.Add([pscustomobject]@{
      id = $id; name = [string]$f.name; health = 'untested'; scenario_results = @(); verified_at = $now
    })
    continue
  }

  $scenarioResults = New-Object 'System.Collections.Generic.List[object]'
  $anyFailed = $false
  $anyInconclusive = $false
  foreach ($scn in $scenarios) {
    $scenarioName = [System.IO.Path]::GetFileNameWithoutExtension([string]$scn)
    if ([string]::IsNullOrWhiteSpace($scenarioName)) { continue }
    Write-Host "[verifier] running scenario: $scenarioName (feature: $id)"
    $runnerPath = Join-Path $BridgePath 'tools\scenario.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath)) {
      $anyInconclusive = $true
      [void]$scenarioResults.Add([pscustomobject]@{ scenario = $scenarioName; ok = $false; error = 'scenario.ps1 missing' })
      continue
    }
    $stdout = $null
    try {
      if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
        $stdout = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
          & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Name $scenarioName -TimeoutSec $ScenarioTimeoutSec 2>&1 | Out-String
        }
      } else {
        $stdout = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Name $scenarioName -TimeoutSec $ScenarioTimeoutSec 2>&1 | Out-String
      }
      $exitCode = $LASTEXITCODE
    } catch {
      $stdout = $_.Exception.Message
      $exitCode = 99
    }
    $resultJson = $null
    foreach ($ln in (([string]$stdout) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
      $trimmed = $ln.Trim()
      if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) { $resultJson = $trimmed }
    }
    $okResult = $false; $err = ''
    if ($resultJson) {
      try {
        $parsed = $resultJson | ConvertFrom-Json
        if ($null -ne $parsed.ok) { $okResult = [bool]$parsed.ok }
        if ($parsed.errors) { $err = ([string]::Join('; ', @($parsed.errors))) }
      } catch { $err = 'unparseable result json' }
    } elseif ($exitCode -ne 0) {
      $err = "exit=$exitCode, no JSON in stdout"
    }
    if (-not $okResult -and -not $err) { $err = 'scenario reported not-ok without errors' }
    [void]$scenarioResults.Add([pscustomobject]@{ scenario = $scenarioName; ok = $okResult; error = $err })
    if (-not $okResult) {
      if ($err -match 'timeout|exit=') { $anyInconclusive = $true } else { $anyFailed = $true }
    }
  }

  $health = if ($anyFailed) { 'broken' } elseif ($anyInconclusive) { 'inconclusive' } else { 'passing' }
  if ($health -eq 'broken') { $brokenCount++ }
  elseif ($health -eq 'passing') { $passingCount++ }
  [void]$results.Add([pscustomobject]@{
    id = $id; name = [string]$f.name; health = $health
    scenario_results = @($scenarioResults.ToArray()); verified_at = $now
  })
}

# Update features/state.json
foreach ($r in $results) {
  $entry = $state[$r.id]
  if (-not $entry -or -not $entry.PSObject) { $entry = [pscustomobject]@{} }
  Add-Member -InputObject $entry -MemberType NoteProperty -Name 'last_verified_at' -Value $r.verified_at -Force
  Add-Member -InputObject $entry -MemberType NoteProperty -Name 'last_health' -Value $r.health -Force
  Add-Member -InputObject $entry -MemberType NoteProperty -Name 'scenario_results' -Value $r.scenario_results -Force
  $state[$r.id] = $entry
}
$stateObj = [pscustomobject]@{}
foreach ($k in $state.Keys) { Add-Member -InputObject $stateObj -MemberType NoteProperty -Name $k -Value $state[$k] -Force }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($statePath, ($stateObj | ConvertTo-Json -Depth 8 -Compress), $utf8NoBom)

# Markdown digest
$auditDir = Join-Path $BridgePath 'audit'
if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
$digestPath = Join-Path $auditDir ("feature-verifier-" + (Get-Date -Format 'yyyy-MM-dd') + ".md")
$md = New-Object 'System.Text.StringBuilder'
$header = "# Feature Verifier -- " + (Get-Date -Format 'yyyy-MM-dd HH:mm')
[void]$md.AppendLine($header)
[void]$md.AppendLine('')
[void]$md.AppendLine("## Summary")
[void]$md.AppendLine("- Passing: $passingCount")
[void]$md.AppendLine("- Broken: $brokenCount")
[void]$md.AppendLine("- Untested: $untestedCount")
[void]$md.AppendLine("- Total: $($results.Count)")
[void]$md.AppendLine('')

if ($brokenCount -gt 0) {
  [void]$md.AppendLine("## Broken features (scenarios failed)")
  foreach ($r in ($results | Where-Object { $_.health -eq 'broken' })) {
    [void]$md.AppendLine("### " + $r.id + " -- " + $r.name)
    foreach ($sr in $r.scenario_results) {
      $mark = if ($sr.ok) { 'OK' } else { 'FAIL' }
      $errStr = if ($sr.error) { " -- " + $sr.error } else { '' }
      [void]$md.AppendLine("- [$mark] " + $sr.scenario + $errStr)
    }
    [void]$md.AppendLine('')
  }
}

[void]$md.AppendLine("## Passing features")
foreach ($r in ($results | Where-Object { $_.health -eq 'passing' })) {
  $scnList = ($r.scenario_results | ForEach-Object { $_.scenario }) -join ', '
  [void]$md.AppendLine("- " + $r.id + " (" + $scnList + ")")
}

if ($untestedCount -gt 0) {
  [void]$md.AppendLine('')
  [void]$md.AppendLine("## Untested features (no scenarios linked)")
  foreach ($r in ($results | Where-Object { $_.health -eq 'untested' })) {
    [void]$md.AppendLine("- " + $r.id + " -- " + $r.name)
  }
}

[System.IO.File]::WriteAllText($digestPath, $md.ToString(), $utf8NoBom)
Write-Host "[verifier] digest written: $digestPath"

if ($brokenCount -gt 0) {
  $brokenNames = @($results | Where-Object { $_.health -eq 'broken' } | ForEach-Object { $_.id }) -join ', '
  $alertText = "Feature verifier: $brokenCount feature(s) BROKEN -- $brokenNames. Details: $digestPath. Scenarios failed, users see broken behavior."
  Send-VerifierChatAlert -Text $alertText
}

$summary = [ordered]@{
  ts = $now; channel = [string]$scope.slug; total = $results.Count; passing = $passingCount; broken = $brokenCount; untested = $untestedCount; digest = $digestPath
}
$summary | ConvertTo-Json -Depth 10 -Compress
if ($brokenCount -gt 0) { exit 1 } else { exit 0 }
