#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Direct cap-hit DQPC reconciliation branch test with script-scope mocks.

$script:PassCount = 0
$script:FailCount = 0
$script:MockBacklog = @()
$script:SetIdeaCalls = [System.Collections.ArrayList]::new()
$script:MockDqpcResult = $false
$script:MockRecoverVerdict = 'NOT_RECOVERABLE'
$script:BridgeRoot = Split-Path -Parent $PSScriptRoot

function Get-BridgeRoot { return $script:BridgeRoot }
function Get-BridgeConfig { return [pscustomobject]@{ recover_covered_after_restart = $script:MockRecoverFlag } }
function Get-Backlog { return $script:MockBacklog }
function Set-Idea {
  param([string]$Id, [string]$Status, [string]$Reason)
  $null = $script:SetIdeaCalls.Add([pscustomobject]@{
    Id = $Id
    Status = $Status
    Reason = $Reason
  })
}

function Set-DqpcHelperMock {
  param([bool]$Result)
  $script:MockDqpcResult = [bool]$Result
  function script:Test-TaskDoneQaPassCommitEvidence {
    param([AllowNull()][string]$BacklogId = '', [string]$BridgeRoot = '')
    return [bool]$script:MockDqpcResult
  }
}

function Clear-DqpcHelperMock {
  Remove-Item -LiteralPath Function:\Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue
}

function Set-RecoverHelperMock {
  param([string]$Verdict = 'NOT_RECOVERABLE', [bool]$Flag = $true)
  $script:MockRecoverVerdict = [string]$Verdict
  $script:MockRecoverFlag = [bool]$Flag
  function script:Test-TaskCompletionRecoverable {
    param([object]$State, [string]$BacklogId, [string]$BridgeRoot = '')
    return [pscustomobject]@{
      verdict   = [string]$script:MockRecoverVerdict
      reason    = 'mock'
      task_id   = [string]$BacklogId
      head      = 'abc1234567890'
      qa_head   = 'abc1234567890'
      commit_ts = 100
      critic_ts = 101
      repo      = [string]$BridgeRoot
    }
  }
  function script:Write-TaskCompletionRecoveryAudit {
    param([string]$BridgeRoot = '', [string]$TaskId = '', [string]$Decision = '', [object]$Verdict = $null, [bool]$FlagState = $false, [string]$Site = '')
  }
}

function Clear-RecoverHelperMock {
  Remove-Item -LiteralPath Function:\Test-TaskCompletionRecoverable -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath Function:\Write-TaskCompletionRecoveryAudit -ErrorAction SilentlyContinue
  $script:MockRecoverFlag = $false
}

function Invoke-CapHitDqpcBranch {
  param(
    [string]$StuckBacklogId,
    [string]$RestartCapHit = 'hard',
    [int]$NewTotalRestartCount = 3
  )

  $script:SetIdeaCalls.Clear()
  $dqpcMarkedDone = $false
  $boot = [pscustomobject]@{ task_apply_restart_count = 9; task_hard_restart_count = 0 }

  if (Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue) {
    try {
      if (Test-TaskDoneQaPassCommitEvidence -BacklogId $StuckBacklogId -BridgeRoot (Get-BridgeRoot)) {
        $dqpcEntry = @(Get-Backlog) | Where-Object { [string]$_.id -eq $StuckBacklogId } | Select-Object -First 1
        $dqpcSha = ([string]$dqpcEntry.done_qa_pass_commit).Trim()
        try { Set-Idea -Id $StuckBacklogId -Status 'done' -Reason ("restart_cap_reconciled_done_qa_pass_commit_" + $dqpcSha) | Out-Null } catch {}
        $dqpcMarkedDone = $true
      }
    } catch {}
  }
  if (-not $dqpcMarkedDone) {
    $recoverFlag = $false
    try {
      $cfgRecover = Get-BridgeConfig
      if ($cfgRecover.PSObject.Properties.Name -contains 'recover_covered_after_restart') { $recoverFlag = [bool]$cfgRecover.recover_covered_after_restart }
    } catch { $recoverFlag = $false }
    if ($recoverFlag -and (Get-Command Test-TaskCompletionRecoverable -ErrorAction SilentlyContinue)) {
      try {
        $recoverResult = Test-TaskCompletionRecoverable -State $boot -BacklogId $StuckBacklogId -BridgeRoot (Get-BridgeRoot)
        if ([string]$recoverResult.verdict -eq 'RECOVER_DONE') {
          try { Set-Idea -Id $StuckBacklogId -Status 'done' -Reason ("restart_cap_recovered_covered_after_restart_" + ([string]$recoverResult.head).Substring(0,[Math]::Min(7,([string]$recoverResult.head).Length))) | Out-Null } catch {}
          $dqpcMarkedDone = $true
        }
      } catch {}
    }
  }

  if (-not $dqpcMarkedDone) {
    try { Set-Idea -Id $StuckBacklogId -Status 'failed' -Reason ("task_restart_loop_" + $RestartCapHit + "_" + $NewTotalRestartCount) | Out-Null } catch {}
  }
}

function Assert-Case {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Name"
    return
  }

  $script:FailCount++
  $suffix = if ($null -ne $Actual) { ' actual=' + ($Actual | ConvertTo-Json -Compress) } else { '' }
  Write-Host "FAIL: $Name$suffix"
}

Clear-DqpcHelperMock
Clear-RecoverHelperMock
Set-DqpcHelperMock -Result $true
$script:MockBacklog = @([pscustomobject]@{ id = 'task-a'; done_qa_pass_commit = 'abc1234' })
Invoke-CapHitDqpcBranch -StuckBacklogId 'task-a'
$aStatuses = @($script:SetIdeaCalls | ForEach-Object { [string]$_.Status })
Assert-Case 'A: DQPC=true -> Set-Idea done, not failed' (($aStatuses.Count -eq 1) -and ($aStatuses[0] -eq 'done') -and ($aStatuses -notcontains 'failed')) $aStatuses

Clear-DqpcHelperMock
Clear-RecoverHelperMock
Set-DqpcHelperMock -Result $false
$script:MockBacklog = @([pscustomobject]@{ id = 'task-b'; done_qa_pass_commit = 'abc1234' })
Invoke-CapHitDqpcBranch -StuckBacklogId 'task-b'
$bStatuses = @($script:SetIdeaCalls | ForEach-Object { [string]$_.Status })
Assert-Case 'B: DQPC=false -> Set-Idea failed' (($bStatuses.Count -eq 1) -and ($bStatuses[0] -eq 'failed')) $bStatuses

Clear-DqpcHelperMock
Clear-RecoverHelperMock
$script:MockBacklog = @([pscustomobject]@{ id = 'task-c'; done_qa_pass_commit = 'abc1234' })
$helperMissing = -not [bool](Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue)
Invoke-CapHitDqpcBranch -StuckBacklogId 'task-c'
$cStatuses = @($script:SetIdeaCalls | ForEach-Object { [string]$_.Status })
Assert-Case 'C: helper missing -> Set-Idea failed' ($helperMissing -and ($cStatuses.Count -eq 1) -and ($cStatuses[0] -eq 'failed')) $cStatuses

Clear-DqpcHelperMock
Clear-RecoverHelperMock
Set-DqpcHelperMock -Result $false
Set-RecoverHelperMock -Verdict 'RECOVER_DONE' -Flag $true
$script:MockBacklog = @([pscustomobject]@{ id = 'task-d'; done_qa_pass_commit = '' })
Invoke-CapHitDqpcBranch -StuckBacklogId 'task-d'
$dStatuses = @($script:SetIdeaCalls | ForEach-Object { [string]$_.Status })
Assert-Case 'D: DQPC=false + recovery RECOVER_DONE -> Set-Idea done, not failed' (($dStatuses.Count -eq 1) -and ($dStatuses[0] -eq 'done') -and ($dStatuses -notcontains 'failed')) $dStatuses

Write-Host ''
if ($script:FailCount -eq 0) {
  Write-Host "Results: $($script:PassCount)/4 PASS"
  exit 0
}

Write-Host "Results: $($script:PassCount)/4 PASS, $($script:FailCount) FAIL"
exit 1
