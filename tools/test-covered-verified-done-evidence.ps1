#Requires -Version 5.1
# test-covered-verified-done-evidence.ps1 -- regression guard for zero-diff covered DONE evidence.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\task-action-evidence.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-False {
  param([bool]$Condition, [string]$Message)
  if ($Condition) { throw $Message }
}

$coveredDone = @'
COVERED: задача уже закрыта verified commit 176ea77; новых изменений не требуется.
[[VERIFIED: covered by commit 176ea77; verify job 398d5b9d PASS; smoke OK]]
STATUS: DONE
'@

$plainDone = @'
Рабочая копия чистая, всё готово.
STATUS: DONE
'@

$coveredWithoutDone = @'
COVERED: задача уже закрыта commit 176ea77.
[[VERIFIED: covered by commit 176ea77; smoke OK]]
'@

$coveredWithoutVerified = @'
COVERED: задача уже закрыта commit 176ea77.
STATUS: DONE
'@

$coveredWithoutSha = @'
COVERED: задача уже закрыта существующим коммитом.
[[VERIFIED: smoke OK]]
STATUS: DONE
'@

$coveredWithoutSmokeOrCheck = @'
COVERED: задача уже закрыта commit 176ea77.
[[VERIFIED: covered by commit 176ea77]]
STATUS: DONE
'@

Assert-True (Test-TaskCoveredVerifiedDoneEvidence -Reply $coveredDone) 'covered DONE with commit SHA and smoke/check evidence must be accepted'
Assert-False (Test-TaskCoveredVerifiedDoneEvidence -Reply $plainDone) 'plain DONE without commit/diff evidence must stay fail-closed'
Assert-False (Test-TaskCoveredVerifiedDoneEvidence -Reply $coveredWithoutDone) 'COVERED VERIFIED without STATUS DONE must stay fail-closed'
Assert-False (Test-TaskCoveredVerifiedDoneEvidence -Reply $coveredWithoutVerified) 'COVERED without VERIFIED must stay fail-closed'
Assert-False (Test-TaskCoveredVerifiedDoneEvidence -Reply $coveredWithoutSha) 'COVERED without commit SHA must stay fail-closed'
Assert-False (Test-TaskCoveredVerifiedDoneEvidence -Reply $coveredWithoutSmokeOrCheck) 'COVERED without smoke/check result must stay fail-closed'

$driverPath = Join-Path $root 'driver\85-loop-mode-transitions.ps1'
$driverSource = Get-Content -LiteralPath $driverPath -Raw -Encoding UTF8
Assert-True ($driverSource -match 'Test-TaskCoveredVerifiedDoneEvidence\s+-Reply\s+\$reply') 'mode transition guard must consult covered verified evidence helper'
Assert-True ($driverSource -match '\$hasCoveredVerifiedEvidence(?s).*?\$hasChanges\s*=\s*\$true') 'covered verified evidence must reset no-progress detector on clean tree'

$agentTurnPath = Join-Path $root 'driver\83-loop-agent-turn.ps1'
$agentTurnSource = Get-Content -LiteralPath $agentTurnPath -Raw -Encoding UTF8
Assert-True ($agentTurnSource -match 'Test-TaskCoveredVerifiedDoneEvidence\s+-Reply\s+\$reply') 'coder retry guard must accept covered verified evidence before retrying for missing diff'
Assert-True ($agentTurnSource -match 'Test-TaskCoveredVerifiedDoneEvidence(?s).*?codex_evidence_retry_count\s+-NotePropertyValue\s+0') 'covered verified evidence must reset coder evidence retry counter'

Write-Output 'COVERED VERIFIED DONE EVIDENCE TEST OK'
