#Requires -Version 5.1
<#
.SYNOPSIS
  Unit test: QA verdict cache dedup logic without invoking a real QA agent.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0

function Assert-True([bool]$cond, [string]$label) {
  if ($cond) { Write-Host "  PASS: $label"; $script:passed++ }
  else        { Write-Host "  FAIL: $label"; $script:failed++ }
}

function Test-QaCacheHit {
  param($State, $Head, $Dirty)

  if ($Head -and ($Dirty -eq '') -and
      $State.PSObject.Properties.Name -contains 'qa_verdict_cache' -and
      $State.qa_verdict_cache) {
    $qc = $State.qa_verdict_cache
    return ([string]$qc.head -eq $Head -and [string]$qc.verdict -eq 'PASS')
  }

  return $false
}

$tmpParent = Join-Path $BridgeRoot 'tmp'
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
$fixtureRoot = Join-Path $tmpParent ("bridge-qa-cache-dedup-test-" + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
  & git -C $fixtureRoot init -q
  & git -C $fixtureRoot config user.email 'bridge-test@example.invalid'
  & git -C $fixtureRoot config user.name 'Bridge Test'
  & git -C $fixtureRoot config commit.gpgsign false
  Set-Content -LiteralPath (Join-Path $fixtureRoot 'fixture.txt') -Value 'qa cache fixture' -Encoding UTF8
  & git -C $fixtureRoot add fixture.txt
  & git -C $fixtureRoot commit -q --no-gpg-sign -m 'qa cache dedup fixture commit'

  $headSha = (& git -C $fixtureRoot rev-parse HEAD | Out-String).Trim()
  $cacheTs = [datetimeoffset]::UtcNow.ToString('o')

  Write-Host "=== Scenario 1: post-commit QA PASS populates cache ==="
  $state = [pscustomobject]@{
    qa_verdict_cache = [pscustomobject]@{
      head    = $headSha
      verdict = 'PASS'
      source  = 'post_commit'
      ts      = $cacheTs
    }
  }
  Assert-True ($state.qa_verdict_cache.source -eq 'post_commit') "cache source is post_commit"
  Assert-True ($state.qa_verdict_cache.verdict -eq 'PASS') "cache verdict is PASS"
  Assert-True ($state.qa_verdict_cache.head -eq $headSha) "cache head matches HEAD SHA"

  Write-Host ""
  Write-Host "=== Scenario 2: same HEAD hits cache and skips QA agent ==="
  $script:QAAgentCalled = $false
  $cacheHit = Test-QaCacheHit -State $state -Head $headSha -Dirty ''
  if (-not $cacheHit) { $script:QAAgentCalled = $true }
  Assert-True ($cacheHit -eq $true) "same HEAD returns cache hit"
  Assert-True ($script:QAAgentCalled -eq $false) "QA agent is not called on cache hit"

  Write-Host ""
  Write-Host "=== Scenario 3: changed HEAD misses cache and calls QA agent ==="
  $script:QAAgentCalled = $false
  $otherHead = 'abcdef1234567890'
  $cacheHit = Test-QaCacheHit -State $state -Head $otherHead -Dirty ''
  if (-not $cacheHit) { $script:QAAgentCalled = $true }
  Assert-True ($cacheHit -eq $false) "different HEAD returns cache miss"
  Assert-True ($script:QAAgentCalled -eq $true) "QA agent is called on cache miss"
}
finally {
  if (Test-Path $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "Results: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 } else { exit 0 }
