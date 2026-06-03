$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$driverPath = Join-Path $repoRoot 'driver\86-loop-completion.ps1'
. $driverPath

$fixtureRoot = Join-Path $env:TEMP ("self-model-hook-smoke-" + [guid]::NewGuid().ToString('N'))
$tests = [ordered]@{
  refreshAfterBacklogCompletion = $false
  refreshAfterNonBacklogCompletion = $false
  refreshFailureFailOpen = $false
  nonMainSkipped = $false
  completionPathWired = $false
}

function New-HookFixture {
  param([string]$Name)

  $root = Join-Path $fixtureRoot $Name
  $tools = Join-Path $root 'tools'
  New-Item -ItemType Directory -Path $tools -Force | Out-Null
  return $root
}

function Write-FakeRefreshTool {
  param(
    [string]$BridgeRoot,
    [string]$Body
  )

  $path = Join-Path $BridgeRoot 'tools\refresh-self-model.ps1'
  $scriptText = @"
param(
  [string]`$BridgeRoot,
  [switch]`$NoOutput
)
`$ErrorActionPreference = 'Stop'
$Body
"@
  [System.IO.File]::WriteAllText($path, $scriptText, (New-Object System.Text.UTF8Encoding($true)))
  return $path
}

function Invoke-MockCompletion {
  param(
    [string]$Channel,
    [string]$BridgeRoot,
    [string[]]$DoneIds = @()
  )

  try {
    if ($DoneIds.Count -gt 0) {
      foreach ($doneId in $DoneIds) {
        if ([string]::IsNullOrWhiteSpace($doneId)) { throw 'empty backlog id' }
      }
    }
    Invoke-PostTaskSelfModelRefresh -Channel $Channel -BridgeRoot $BridgeRoot | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Test-CompletionPathWired {
  param([string]$DriverText)

  $lines = @($DriverText -split "\r?\n")
  $hookCallIndexes = @()
  $doneIfIndex = -1
  $doctorIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Invoke-PostTaskSelfModelRefresh\s+-Channel\s+\$Channel\s+-BridgeRoot\s+\$bridgeRoot') {
      $hookCallIndexes += $i
    }
    if ($doneIfIndex -lt 0 -and $lines[$i] -match 'if\s*\(\$doneIds\.Count\s+-gt\s+0\)') {
      $doneIfIndex = $i
    }
    if ($doctorIndex -lt 0 -and $lines[$i] -match 'If Doctor just finished') {
      $doctorIndex = $i
    }
  }
  if ($hookCallIndexes.Count -ne 1 -or $doneIfIndex -lt 0 -or $doctorIndex -lt 0) { return $false }

  $hookIndex = [int]$hookCallIndexes[0]
  $depth = 0
  $doneBlockEnd = -1
  for ($i = $doneIfIndex; $i -lt $lines.Count; $i++) {
    $depth += ([regex]::Matches($lines[$i], '\{')).Count
    $depth -= ([regex]::Matches($lines[$i], '\}')).Count
    if ($i -gt $doneIfIndex -and $depth -le 0) {
      $doneBlockEnd = $i
      break
    }
  }

  if ($doneBlockEnd -lt 0) { return $false }
  return ($hookIndex -gt $doneBlockEnd -and $hookIndex -lt $doctorIndex)
}

try {
  New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

  $okRoot = New-HookFixture -Name 'ok'
  $marker = Join-Path $okRoot 'cache-marker.txt'
  Write-FakeRefreshTool -BridgeRoot $okRoot -Body @"
Set-Content -LiteralPath (Join-Path `$BridgeRoot 'cache-marker.txt') -Value ([datetime]::UtcNow.ToString('o')) -Encoding UTF8
"@ | Out-Null
  $completionOk = Invoke-MockCompletion -Channel 'main' -BridgeRoot $okRoot -DoneIds @('mock-backlog-id')
  $tests.refreshAfterBacklogCompletion = ($completionOk -and (Test-Path -LiteralPath $marker) -and -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $marker -Raw)))

  $nonBacklogRoot = New-HookFixture -Name 'non-backlog'
  $nonBacklogMarker = Join-Path $nonBacklogRoot 'cache-marker.txt'
  Write-FakeRefreshTool -BridgeRoot $nonBacklogRoot -Body @"
Set-Content -LiteralPath (Join-Path `$BridgeRoot 'cache-marker.txt') -Value 'non-backlog-called' -Encoding UTF8
"@ | Out-Null
  $nonBacklogCompletionOk = Invoke-MockCompletion -Channel 'main' -BridgeRoot $nonBacklogRoot -DoneIds @()
  $tests.refreshAfterNonBacklogCompletion = ($nonBacklogCompletionOk -and (Test-Path -LiteralPath $nonBacklogMarker) -and ((Get-Content -LiteralPath $nonBacklogMarker -Raw).Trim() -eq 'non-backlog-called'))

  $failRoot = New-HookFixture -Name 'fail'
  Write-FakeRefreshTool -BridgeRoot $failRoot -Body "throw 'mock refresh failure'" | Out-Null
  $failResult = Invoke-PostTaskSelfModelRefresh -Channel 'main' -BridgeRoot $failRoot
  $completionStillOk = Invoke-MockCompletion -Channel 'main' -BridgeRoot $failRoot
  $tests.refreshFailureFailOpen = ($completionStillOk -and [bool]$failResult.attempted -and -not [bool]$failResult.ok -and -not [string]::IsNullOrWhiteSpace([string]$failResult.error))

  $privateRoot = New-HookFixture -Name 'private'
  $privateMarker = Join-Path $privateRoot 'cache-marker.txt'
  Write-FakeRefreshTool -BridgeRoot $privateRoot -Body @"
Set-Content -LiteralPath (Join-Path `$BridgeRoot 'cache-marker.txt') -Value 'private-called' -Encoding UTF8
"@ | Out-Null
  $privateResult = Invoke-PostTaskSelfModelRefresh -Channel 'private-community' -BridgeRoot $privateRoot
  $tests.nonMainSkipped = ([bool]$privateResult.skipped -and -not [bool]$privateResult.attempted -and -not (Test-Path -LiteralPath $privateMarker))

  $driverText = Get-Content -LiteralPath $driverPath -Raw
  $tests.completionPathWired = Test-CompletionPathWired -DriverText $driverText

  $testPassed = $true
  foreach ($value in $tests.Values) {
    if (-not [bool]$value) { $testPassed = $false }
  }

  $report = [pscustomobject]@{
    testPassed = $testPassed
    tests = [pscustomobject]$tests
  }
  $report | ConvertTo-Json -Depth 5
  if (-not $testPassed) { exit 1 }
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
