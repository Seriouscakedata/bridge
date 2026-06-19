#Requires -Version 5.1

param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
. (Join-Path $BridgeRoot 'lib\task-action-evidence.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Assert-Case {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Name"
    return
  }
  $script:FailCount++
  $suffix = if ($null -ne $Actual) { ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 5) } else { '' }
  Write-Host "FAIL: $Name$suffix"
}

function Invoke-TestGit {
  param(
    [string]$RepoRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
  )
  & git -C $RepoRoot @Args 2>$null
}

function New-RecoverState {
  param(
    [string]$TaskId,
    [string]$StartedAt,
    [string]$Head,
    [string]$CriticTs
  )
  $startedMap = [ordered]@{}
  if (-not [string]::IsNullOrWhiteSpace($StartedAt)) { $startedMap[$TaskId] = $StartedAt }
  return [pscustomobject]@{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    current_backlog_id       = $TaskId
    task_started_at          = $startedMap
    qa_verdict_cache         = [pscustomobject]@{ head = $Head; verdict = 'PASS'; source = 'post_commit'; ts = $CriticTs }
    critic_verdict_cache     = [pscustomobject]@{ verdict = 'OK'; severity = 'none'; ts = $CriticTs }
  }
}

$tmpParent = Join-Path $BridgeRoot 'tmp'
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
$repo = Join-Path $tmpParent ("task-completion-recoverable-" + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  Invoke-TestGit -RepoRoot $repo init -q
  Invoke-TestGit -RepoRoot $repo config user.email 'bridge-test@example.invalid'
  Invoke-TestGit -RepoRoot $repo config user.name 'Bridge Test'
  Invoke-TestGit -RepoRoot $repo config commit.gpgsign false

  Set-Content -LiteralPath (Join-Path $repo 'code.ps1') -Value "'ok'" -Encoding UTF8
  Invoke-TestGit -RepoRoot $repo add code.ps1
  Invoke-TestGit -RepoRoot $repo commit -q --no-gpg-sign -m '[task:task-a] auto-commit (driver): very long task subject that keeps the exact marker at the head'
  $head = ([string](Invoke-TestGit -RepoRoot $repo rev-parse HEAD | Select-Object -First 1)).Trim()
  $commitTs = [int64](([string](Invoke-TestGit -RepoRoot $repo log -1 --format=%ct HEAD | Select-Object -First 1)).Trim())
  $startedAt = [datetimeoffset]::FromUnixTimeSeconds($commitTs - 60).ToString('o')
  $criticAfter = [datetimeoffset]::FromUnixTimeSeconds($commitTs + 1).ToString('o')
  $criticBefore = [datetimeoffset]::FromUnixTimeSeconds($commitTs - 1).ToString('o')

  $stateOk = New-RecoverState -TaskId 'task-a' -StartedAt $startedAt -Head $head -CriticTs $criticAfter
  $r1 = Test-TaskCompletionRecoverable -State $stateOk -BacklogId 'task-a' -BridgeRoot $repo
  Assert-Case 'valid exact marker + QA HEAD + critic after commit -> RECOVER_DONE' ([string]$r1.verdict -eq 'RECOVER_DONE') $r1

  $r2 = Test-TaskCompletionRecoverable -State $stateOk -BacklogId 'task-template-prefix' -BridgeRoot $repo
  Assert-Case 'id mismatch does not recover via task text/prefix fallback' ([string]$r2.verdict -ne 'RECOVER_DONE') $r2

  $stateStaleCritic = New-RecoverState -TaskId 'task-a' -StartedAt $startedAt -Head $head -CriticTs $criticBefore
  $r3 = Test-TaskCompletionRecoverable -State $stateStaleCritic -BacklogId 'task-a' -BridgeRoot $repo
  Assert-Case 'critic before commit is not recoverable' ([string]$r3.reason -eq 'critic_before_commit' -and [string]$r3.verdict -ne 'RECOVER_DONE') $r3

  $stateQaMismatch = New-RecoverState -TaskId 'task-a' -StartedAt $startedAt -Head ('0' * 40) -CriticTs $criticAfter
  $r4 = Test-TaskCompletionRecoverable -State $stateQaMismatch -BacklogId 'task-a' -BridgeRoot $repo
  Assert-Case 'qa head mismatch is not recoverable' ([string]$r4.reason -eq 'qa_head_mismatch' -and [string]$r4.verdict -ne 'RECOVER_DONE') $r4

  $stateMissingStarted = New-RecoverState -TaskId 'task-a' -StartedAt '' -Head $head -CriticTs $criticAfter
  $r5 = Test-TaskCompletionRecoverable -State $stateMissingStarted -BacklogId 'task-a' -BridgeRoot $repo
  Assert-Case 'missing identity-keyed task_started_at is insufficient evidence' ([string]$r5.reason -eq 'missing_task_started_at' -and [string]$r5.verdict -eq 'INSUFFICIENT_EVIDENCE') $r5
} finally {
  if ($repo -like (Join-Path $tmpParent 'task-completion-recoverable-*')) {
    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ''
if ($script:FailCount -eq 0) {
  Write-Host "Results: $($script:PassCount)/5 PASS"
  exit 0
}

Write-Host "Results: $($script:PassCount)/5 PASS, $($script:FailCount) FAIL"
exit 1