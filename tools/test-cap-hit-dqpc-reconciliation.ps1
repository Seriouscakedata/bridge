#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Tests for A'' cap-hit DQPC reconciliation guard in driver/60-startup.ps1.
# Mirrors the inserted guard logic; mocks Set-Idea / Get-Backlog.

$root = Split-Path -Parent $PSScriptRoot

# The sandbox user may not own the repo; make git calls inside the helper deterministic.
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'safe.directory'
$env:GIT_CONFIG_VALUE_0 = ($root -replace '\\','/')

. (Join-Path $root 'lib\task-action-evidence.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Check {
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

$script:MockBacklog = @()
$script:SetIdeaCalls = [System.Collections.ArrayList]::new()

function Get-Backlog { return $script:MockBacklog }
function Get-BridgeRoot { return $root }
function Set-Idea {
  param([string]$Id, [string]$Status, [string]$Reason)
  $null = $script:SetIdeaCalls.Add([pscustomobject]@{ Id = $Id; Status = $Status; Reason = $Reason })
}

function Invoke-CapHitDqpcGuard {
  param(
    [string]$stuckBacklogId,
    [bool]$ForceGuardError = $false
  )
  $script:SetIdeaCalls.Clear()
  $dqpcMarkedDone = $false
  try { . (Join-Path (Get-BridgeRoot) 'lib\task-action-evidence.ps1') } catch {}
  if ($ForceGuardError) {
    function Test-TaskDoneQaPassCommitEvidence {
      param([AllowNull()][string]$BacklogId = '', [string]$BridgeRoot = '')
      throw 'simulated guard error'
    }
  }
  if (Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue) {
    try {
      if (Test-TaskDoneQaPassCommitEvidence -BacklogId $stuckBacklogId -BridgeRoot (Get-BridgeRoot)) {
        $dqpcEntry = @(Get-Backlog) | Where-Object { [string]$_.id -eq $stuckBacklogId } | Select-Object -First 1
        $dqpcSha = ([string]$dqpcEntry.done_qa_pass_commit).Trim()
        try { Set-Idea -Id $stuckBacklogId -Status 'done' -Reason ("restart_cap_reconciled_done_qa_pass_commit_" + $dqpcSha) | Out-Null } catch {}
        $dqpcMarkedDone = $true
      }
    } catch {}
  }
  if (-not $dqpcMarkedDone) {
    try { Set-Idea -Id $stuckBacklogId -Status 'failed' -Reason 'task_restart_loop_hard_3' | Out-Null } catch {}
  }
}

$realSha = ([string](& git -C $root rev-parse HEAD 2>$null | Out-String)).Trim()
Check 'Setup: HEAD sha resolved' (-not [string]::IsNullOrWhiteSpace($realSha)) $realSha

$script:MockBacklog = @([pscustomobject]@{ id = 'task-a'; done_qa_pass_commit = $realSha })
Invoke-CapHitDqpcGuard -stuckBacklogId 'task-a'
Check 'A: valid DQPC -> one Set-Idea call' ($script:SetIdeaCalls.Count -eq 1) $script:SetIdeaCalls.Count
Check 'A: status=done' ($script:SetIdeaCalls[0].Status -eq 'done') $script:SetIdeaCalls[0].Status
Check 'A: reason contains SHA' ($script:SetIdeaCalls[0].Reason -like "*$realSha*") $script:SetIdeaCalls[0].Reason

$script:MockBacklog = @([pscustomobject]@{ id = 'task-b'; done_qa_pass_commit = '0000000000000000000000000000000000000000' })
Invoke-CapHitDqpcGuard -stuckBacklogId 'task-b'
Check 'B: bad SHA -> one Set-Idea call' ($script:SetIdeaCalls.Count -eq 1) $script:SetIdeaCalls.Count
Check 'B: bad SHA -> status=failed' ($script:SetIdeaCalls[0].Status -eq 'failed') $script:SetIdeaCalls[0].Status

$script:MockBacklog = @([pscustomobject]@{ id = 'task-c'; done_qa_pass_commit = $realSha })
Invoke-CapHitDqpcGuard -stuckBacklogId 'task-c' -ForceGuardError $true
Check 'C: guard error -> one Set-Idea call' ($script:SetIdeaCalls.Count -eq 1) $script:SetIdeaCalls.Count
Check 'C: guard error -> status=failed' ($script:SetIdeaCalls[0].Status -eq 'failed') $script:SetIdeaCalls[0].Status

Write-Host ""
Write-Host "Results: $($script:PassCount) passed, $($script:FailCount) failed"
if ($script:FailCount -gt 0) { exit 1 }
exit 0
