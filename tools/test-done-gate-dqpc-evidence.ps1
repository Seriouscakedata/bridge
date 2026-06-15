#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Tests for the driver/85 mode-transition DONE evidence gate done_qa_pass_commit path.
# Exercises the real production helpers from lib/task-action-evidence.ps1:
#   - Test-TaskDoneQaPassCommitEvidence : backlog lookup + git SHA verification (Get-Backlog mocked)
#   - Get-TaskDoneEvidenceDecision      : pure allow/reason decision chain
# Git is used for real (HEAD = valid SHA, 40 zeros = invalid SHA); only Get-Backlog is mocked.

$root = Split-Path -Parent $PSScriptRoot
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

# --- sanity: helpers loaded ---
Check 'Helper Test-TaskDoneQaPassCommitEvidence is defined' ([bool](Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue))
Check 'Helper Get-TaskDoneEvidenceDecision is defined' ([bool](Get-Command Get-TaskDoneEvidenceDecision -ErrorAction SilentlyContinue))

# --- real git SHAs from the bridge repo ---
$realSha = ([string](& git -C $root rev-parse HEAD 2>$null | Out-String)).Trim()
Check 'Setup: real HEAD sha resolved' (-not [string]::IsNullOrWhiteSpace($realSha)) $realSha
$badSha = '0000000000000000000000000000000000000000'  # valid hex shape, not a real commit

# ===== Test 1: valid done_qa_pass_commit SHA -> evidence true, decision allows with dqpc reason =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-1'; done_qa_pass_commit = $realSha })
$ev1 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-1' -BridgeRoot $root)
Check 'T1: valid SHA -> evidence true' ($ev1 -eq $true) $ev1
$d1 = Get-TaskDoneEvidenceDecision -HasBacklogId $true -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $true -HasEvidence $false -HasCoveredVerifiedEvidence $false -HasDoneQaPassCommit $ev1
Check 'T1: decision allows DONE' ([bool]$d1.allow -eq $true) $d1
Check 'T1: reason = done_qa_pass_commit_evidence' ([string]$d1.reason -eq 'done_qa_pass_commit_evidence') $d1

# ===== Test 2: invalid SHA (not a real commit) -> evidence false, DONE not allowed =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-2'; done_qa_pass_commit = $badSha })
$ev2 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-2' -BridgeRoot $root)
Check 'T2: invalid SHA -> evidence false' ($ev2 -eq $false) $ev2
$d2 = Get-TaskDoneEvidenceDecision -HasBacklogId $true -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $true -HasEvidence $false -HasCoveredVerifiedEvidence $false -HasDoneQaPassCommit $ev2
Check 'T2: decision does NOT allow DONE' ([bool]$d2.allow -eq $false) $d2
Check 'T2: reason = missing_action_evidence' ([string]$d2.reason -eq 'missing_action_evidence') $d2

# ===== Test 3: empty-string done_qa_pass_commit -> treated as missing =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-3'; done_qa_pass_commit = '' })
$ev3 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-3' -BridgeRoot $root)
Check 'T3: empty SHA -> evidence false' ($ev3 -eq $false) $ev3

# ===== Test 3b: whitespace-only done_qa_pass_commit -> treated as missing =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-3b'; done_qa_pass_commit = "   " })
$ev3b = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-3b' -BridgeRoot $root)
Check 'T3b: whitespace SHA -> evidence false' ($ev3b -eq $false) $ev3b

# ===== Test 4: done_qa_pass_commit field absent -> evidence false =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-4'; status = 'done' })
$ev4 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-4' -BridgeRoot $root)
Check 'T4: missing field -> evidence false' ($ev4 -eq $false) $ev4

# ===== Test 5: no backlog id -> helper false (early guard) AND gate not applied (not_backlog_task) =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-1'; done_qa_pass_commit = $realSha })
$ev5 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId '' -BridgeRoot $root)
Check 'T5: empty backlog id -> evidence false' ($ev5 -eq $false) $ev5
$d5 = Get-TaskDoneEvidenceDecision -HasBacklogId $false -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $true -HasEvidence $false -HasCoveredVerifiedEvidence $false -HasDoneQaPassCommit $false
Check 'T5: no backlog -> decision allow (gate not applied)' ([bool]$d5.allow -eq $true) $d5
Check 'T5: reason = not_backlog_task' ([string]$d5.reason -eq 'not_backlog_task') $d5

# ===== Test 6: real action evidence wins over dqpc (precedence) =====
$d6 = Get-TaskDoneEvidenceDecision -HasBacklogId $true -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $true -HasEvidence $true -HasCoveredVerifiedEvidence $false -HasDoneQaPassCommit $true
Check 'T6: action_evidence takes precedence over dqpc' ([string]$d6.reason -eq 'action_evidence') $d6
Check 'T6: decision allows DONE' ([bool]$d6.allow -eq $true) $d6

# ===== Test 7: evidence_check_failed gates dqpc (fail-closed placement) =====
$d7 = Get-TaskDoneEvidenceDecision -HasBacklogId $true -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $false -HasEvidence $false -HasCoveredVerifiedEvidence $false -HasDoneQaPassCommit $true
Check 'T7: evidence_check_failed precedes dqpc' ([string]$d7.reason -eq 'evidence_check_failed') $d7
Check 'T7: decision does NOT allow DONE' ([bool]$d7.allow -eq $false) $d7

# ===== Test 8: covered_verified_evidence wins over dqpc (precedence) =====
$d8 = Get-TaskDoneEvidenceDecision -HasBacklogId $true -ProjectAutopilot $false -ProjectBacklogCreated 0 -EvidenceChecked $true -HasEvidence $false -HasCoveredVerifiedEvidence $true -HasDoneQaPassCommit $true
Check 'T8: covered_verified takes precedence over dqpc' ([string]$d8.reason -eq 'covered_verified_evidence') $d8

# ===== Test 9: backlog id with no matching item -> evidence false =====
$script:MockBacklog = @([pscustomobject]@{ id = 'other-id'; done_qa_pass_commit = $realSha })
$ev9 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-1' -BridgeRoot $root)
Check 'T9: id mismatch -> evidence false' ($ev9 -eq $false) $ev9

# ===== Test 10: empty BridgeRoot -> evidence false (guard) =====
$script:MockBacklog = @([pscustomobject]@{ id = 'task-1'; done_qa_pass_commit = $realSha })
$ev10 = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId 'task-1' -BridgeRoot '')
Check 'T10: empty BridgeRoot -> evidence false' ($ev10 -eq $false) $ev10

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
