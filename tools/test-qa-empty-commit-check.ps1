#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$passed = 0
$failed = 0
$script:ScenarioCalls = 0

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Name,
    [string]$Detail = ''
  )
  if ($Condition) {
    $script:passed++
    Write-Host ("PASS: " + $Name)
    return
  }
  $script:failed++
  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host ("FAIL: " + $Name)
  } else {
    Write-Host ("FAIL: " + $Name + " - " + $Detail)
  }
}

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\qa-agent.ps1')

function Get-QAAgentConfig {
  param([string]$BridgeRoot)
  return [pscustomobject]@{
    RunUnsafeScenarios = $false
    ScenarioTimeoutSec = 1
    ScenarioUrl = 'http://127.0.0.1:1'
  }
}

function Get-QAAgentChannel {
  param([string]$Channel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { return 'main' }
  return $Channel
}

function Invoke-QAAgentScenarioSuite {
  param(
    [string]$BridgeRoot,
    [string]$Url,
    [int]$TimeoutSec,
    [switch]$IncludeUnsafe
  )
  $script:ScenarioCalls++
  return [pscustomobject]@{
    Ran = $true
    Ok = $true
    Summary = 'mock scenario pass'
    Bugs = @()
  }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-qa-empty-' + [guid]::NewGuid().ToString('N'))
$tmpEmptyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-qa-empty-root-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  & git -C $tmp init | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
  & git -C $tmp config user.email 'qa-empty@example.invalid'
  if ($LASTEXITCODE -ne 0) { throw 'git config user.email failed' }
  & git -C $tmp config user.name 'QA Empty Commit Test'
  if ($LASTEXITCODE -ne 0) { throw 'git config user.name failed' }

  $fixturePath = Join-Path $tmp 'fixture.txt'
  [System.IO.File]::WriteAllText($fixturePath, "initial`n", [System.Text.Encoding]::UTF8)
  & git -C $tmp add fixture.txt
  if ($LASTEXITCODE -ne 0) { throw 'git add initial failed' }
  & git -C $tmp commit -m 'initial fixture' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git commit initial failed' }
  $rootCommit = (& git -C $tmp rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'git rev-parse root commit failed' }

  $script:ScenarioCalls = 0
  $rootResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $rootCommit -TaskId 'qa-empty-root-real' -TaskTitle 'root real commit' -Channel 'main'
  Assert-True ($rootResult.Verdict -eq 'PASS') 'root real commit returns PASS' ('verdict=' + [string]$rootResult.Verdict + '; summary=' + [string]$rootResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 1) 'root real commit runs scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  [System.IO.File]::AppendAllText($fixturePath, "real change`n", [System.Text.Encoding]::UTF8)
  & git -C $tmp add fixture.txt
  if ($LASTEXITCODE -ne 0) { throw 'git add real change failed' }
  & git -C $tmp commit -m 'real change' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git commit real change failed' }
  $realCommit = (& git -C $tmp rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'git rev-parse real commit failed' }

  $script:ScenarioCalls = 0
  $realResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $realCommit -TaskId 'qa-empty-real' -TaskTitle 'real commit' -Channel 'main'
  Assert-True ($realResult.Verdict -eq 'PASS') 'real commit returns PASS' ('verdict=' + [string]$realResult.Verdict + '; summary=' + [string]$realResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 1) 'real commit runs scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  & git -C $tmp commit --allow-empty -m 'empty change' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git commit empty failed' }
  $emptyCommit = (& git -C $tmp rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'git rev-parse empty commit failed' }

  $script:ScenarioCalls = 0
  $staleHeadRealResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $realCommit -TaskId 'qa-empty-stale-head' -TaskTitle 'real commit after head advanced' -Channel 'main'
  Assert-True ($staleHeadRealResult.Verdict -eq 'PASS') 'real commit sha returns PASS after HEAD advanced' ('verdict=' + [string]$staleHeadRealResult.Verdict + '; summary=' + [string]$staleHeadRealResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 1) 'real commit sha after HEAD advanced runs scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  $script:ScenarioCalls = 0
  $emptyResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $emptyCommit -TaskId 'qa-empty-empty' -TaskTitle 'empty commit' -Channel 'main'
  Assert-True ($emptyResult.Verdict -eq 'FAIL') 'empty commit returns FAIL' ('verdict=' + [string]$emptyResult.Verdict + '; summary=' + [string]$emptyResult.Summary)
  Assert-True ($emptyResult.Summary -like '*EMPTY COMMIT*') 'empty commit summary names EMPTY COMMIT' ([string]$emptyResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 0) 'empty commit skips scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  $script:ScenarioCalls = 0
  $projectRealResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $realCommit -TaskId 'qa-empty-project-real' -TaskTitle 'project real commit' -Channel 'oko'
  Assert-True ($projectRealResult.Verdict -eq 'PASS') 'project real commit returns PASS' ('verdict=' + [string]$projectRealResult.Verdict + '; summary=' + [string]$projectRealResult.Summary)
  Assert-True ($projectRealResult.Summary -like '*bridge QA scenarios skipped*') 'project real commit skips bridge scenarios' ([string]$projectRealResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 0) 'project real commit does not run scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  $script:ScenarioCalls = 0
  $projectEmptyResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha $emptyCommit -TaskId 'qa-empty-project-empty' -TaskTitle 'project empty commit' -Channel 'oko'
  Assert-True ($projectEmptyResult.Verdict -eq 'FAIL') 'project empty commit returns FAIL' ('verdict=' + [string]$projectEmptyResult.Verdict + '; summary=' + [string]$projectEmptyResult.Summary)
  Assert-True ($projectEmptyResult.Summary -like '*EMPTY COMMIT*') 'project empty commit summary names EMPTY COMMIT' ([string]$projectEmptyResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 0) 'project empty commit does not run scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  $script:ScenarioCalls = 0
  $badRefResult = Invoke-QAAgentPostCommit -BridgeRoot $tmp -CommitSha 'not-a-commit' -TaskId 'qa-empty-bad-ref' -TaskTitle 'bad commit ref' -Channel 'main'
  Assert-True ($badRefResult.Verdict -eq 'FAIL') 'bad commit ref returns FAIL' ('verdict=' + [string]$badRefResult.Verdict + '; summary=' + [string]$badRefResult.Summary)
  Assert-True ($badRefResult.Summary -like '*GIT DIFF CHECK FAILED*') 'bad commit ref summary names git inspection failure' ([string]$badRefResult.Summary)
  Assert-True ($badRefResult.Summary -notlike '*EMPTY COMMIT*') 'bad commit ref is not reported as EMPTY COMMIT' ([string]$badRefResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 0) 'bad commit ref skips scenario suite' ('calls=' + [string]$script:ScenarioCalls)

  New-Item -ItemType Directory -Force -Path $tmpEmptyRoot | Out-Null
  & git -C $tmpEmptyRoot init | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init empty root failed' }
  & git -C $tmpEmptyRoot config user.email 'qa-empty@example.invalid'
  if ($LASTEXITCODE -ne 0) { throw 'git config empty root user.email failed' }
  & git -C $tmpEmptyRoot config user.name 'QA Empty Commit Test'
  if ($LASTEXITCODE -ne 0) { throw 'git config empty root user.name failed' }
  & git -C $tmpEmptyRoot commit --allow-empty -m 'empty root' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git commit empty root failed' }
  $emptyRootCommit = (& git -C $tmpEmptyRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'git rev-parse empty root failed' }

  $script:ScenarioCalls = 0
  $emptyRootResult = Invoke-QAAgentPostCommit -BridgeRoot $tmpEmptyRoot -CommitSha $emptyRootCommit -TaskId 'qa-empty-root-empty' -TaskTitle 'empty root commit' -Channel 'main'
  Assert-True ($emptyRootResult.Verdict -eq 'FAIL') 'empty root commit returns FAIL' ('verdict=' + [string]$emptyRootResult.Verdict + '; summary=' + [string]$emptyRootResult.Summary)
  Assert-True ($emptyRootResult.Summary -like '*EMPTY COMMIT*') 'empty root commit summary names EMPTY COMMIT' ([string]$emptyRootResult.Summary)
  Assert-True ($script:ScenarioCalls -eq 0) 'empty root commit skips scenario suite' ('calls=' + [string]$script:ScenarioCalls)
} catch {
  $failed++
  Write-Host ("FAIL: unexpected exception - " + $_.Exception.Message)
} finally {
  if (Test-Path -LiteralPath $tmp) {
    Remove-Item -LiteralPath $tmp -Recurse -Force
  }
  if (Test-Path -LiteralPath $tmpEmptyRoot) {
    Remove-Item -LiteralPath $tmpEmptyRoot -Recurse -Force
  }
}

Write-Host ("RESULT: passed=" + [string]$passed + " failed=" + [string]$failed)
if ($failed -gt 0) { exit 1 }
exit 0
