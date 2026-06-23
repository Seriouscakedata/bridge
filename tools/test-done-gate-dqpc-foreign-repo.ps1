#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Tests for DONE-gate done_qa_pass_commit SHA verification when the SHA lives in
# a foreign repository rather than the bridge repo. Get-Backlog is mocked; git is
# used for real against a temporary repository.

$root = Split-Path -Parent $PSScriptRoot

$previousGitConfigCount = $env:GIT_CONFIG_COUNT
$previousGitConfigKey0 = $env:GIT_CONFIG_KEY_0
$previousGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'safe.directory'
$env:GIT_CONFIG_VALUE_0 = $root

. (Join-Path $root 'lib\task-action-evidence.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Check {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }
  $script:FailCount++
  $suffix = ''
  if ($null -ne $Actual) {
    $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 8)
  }
  Write-Host ("FAIL: {0}{1}" -f $Name, $suffix)
}

# --- mock Get-Backlog (lib/task-action-evidence.ps1 does not define it) ---
$script:MockBacklog = @()
function Get-Backlog { return $script:MockBacklog }

$tmpDir = $null
try {
  # --- sanity: helper loaded ---
  Check 'Helper Test-TaskDoneQaPassCommitEvidence is defined' ([bool](Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue))

  # --- real foreign git repo SHA ---
  $tmpDir = Join-Path $env:TEMP "bridge-test-foreign-repo-$([System.IO.Path]::GetRandomFileName())"
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  & git -C $tmpDir init --quiet 2>$null | Out-Null
  & git -C $tmpDir config user.email "test@test.com" 2>$null | Out-Null
  & git -C $tmpDir config user.name "Test" 2>$null | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmpDir 'seed.txt'), 'seed')
  & git -C $tmpDir add seed.txt 2>$null | Out-Null
  & git -C $tmpDir commit --quiet -m "seed" 2>$null | Out-Null
  $foreignSha = ([string](& git -C $tmpDir rev-parse HEAD 2>$null | Out-String)).Trim()
  Check 'Setup: foreign repo sha resolved' (-not [string]::IsNullOrWhiteSpace($foreignSha)) $foreignSha

  # Ensure the test SHA is not present in the bridge repo; otherwise the negative
  # case would not prove foreign-repo lookup behavior.
  $bridgeOut = ([string](& git -C $root rev-parse --verify --quiet ($foreignSha + '^{commit}') 2>$null | Out-String)).Trim()
  Check 'Setup: foreign sha is absent from bridge repo' ([string]::IsNullOrWhiteSpace($bridgeOut)) $bridgeOut

  # ===== T1: explicit done_qa_pass_repo resolves the foreign SHA =====
  $script:MockBacklog = @([pscustomobject]@{
    id = 'task-foreign-repo'
    done_qa_pass_repo = $tmpDir
    done_qa_pass_commit = $foreignSha
    files = @('tools/some-relative-file.ps1')
  })
  $ev1 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-foreign-repo' -BridgeRoot $root)
  Check 'T1: done_qa_pass_repo foreign SHA -> evidence true' ($ev1 -eq $true) $ev1

  # ===== T2: without a repo hint and only relative files, bridge lookup fails =====
  $script:MockBacklog = @([pscustomobject]@{
    id = 'task-no-repo-hint'
    done_qa_pass_commit = $foreignSha
    files = @('tools/some-relative-file.ps1')
  })
  $ev2 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-no-repo-hint' -BridgeRoot $root)
  Check 'T2: no repo hint foreign SHA -> evidence false' ($ev2 -eq $false) $ev2

  # ===== T3: declared_repo also resolves the foreign SHA =====
  $script:MockBacklog = @([pscustomobject]@{
    id = 'task-declared-repo'
    declared_repo = $tmpDir
    done_qa_pass_commit = $foreignSha
    files = @('tools/some-relative-file.ps1')
  })
  $ev3 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-declared-repo' -BridgeRoot $root)
  Check 'T3: declared_repo foreign SHA -> evidence true' ($ev3 -eq $true) $ev3

  # ===== T4: absolute files path inside foreign repo infers the repo =====
  $script:MockBacklog = @([pscustomobject]@{
    id = 'task-files-path-inference'
    done_qa_pass_commit = $foreignSha
    files = @((Join-Path $tmpDir 'somefile.ps1'))
  })
  $ev4 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-files-path-inference' -BridgeRoot $root)
  Check 'T4: absolute file path infers foreign repo -> evidence true' ($ev4 -eq $true) $ev4
} finally {
  if (-not [string]::IsNullOrWhiteSpace($tmpDir) -and (Test-Path -LiteralPath $tmpDir)) {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force
  }
  $env:GIT_CONFIG_COUNT = $previousGitConfigCount
  $env:GIT_CONFIG_KEY_0 = $previousGitConfigKey0
  $env:GIT_CONFIG_VALUE_0 = $previousGitConfigValue0
}

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
