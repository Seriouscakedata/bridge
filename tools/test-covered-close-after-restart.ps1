#Requires -Version 5.1
<#
.SYNOPSIS
  Acceptance test: Test-CoveredAfterRestart covered-close logic.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0

# Load the function under test
. (Join-Path $BridgeRoot 'driver\86-loop-completion-checks.ps1')

function Invoke-TestGit {
  param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
  )

  & git -c "safe.directory=$BridgeRoot" -C $BridgeRoot @Args 2>$null
}

# Helper to get a real recent commit SHA
$headSha = (& { Invoke-TestGit log --oneline -1 } | Select-Object -First 1).Split(' ')[0].Trim()
$headMsg = (& { Invoke-TestGit log --format=%s -1 } | Out-String).Trim()

function Assert-True([bool]$cond, [string]$label) {
  if ($cond) { Write-Host "  PASS: $label"; $script:passed++ }
  else        { Write-Host "  FAIL: $label"; $script:failed++ }
}

Write-Host "=== Test-CoveredAfterRestart: scenario 1 (covered - restart + clean tree + real commit) ==="
# Use a real existing commit (HEAD) and match by its short message text (first 60 chars)
$claimedAt = (& { Invoke-TestGit log --format=%aI -1 } | Out-String).Trim()
# Set claimed_at slightly before HEAD commit
$claimedAtDt = ([datetime]::Parse($claimedAt)).AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:sszzz')
$fakeState1 = @{
  task_apply_restart_count = 1
  task_hard_restart_count  = 0
  critic_verdict_cache     = @{ verdict = 'OK' }
  claimed_at               = $claimedAtDt
  current_backlog_id       = ''
  current_task             = $headMsg
}
$r1 = Test-CoveredAfterRestart -BridgeRoot $BridgeRoot -ClaimedAt $fakeState1.claimed_at `
  -BacklogId $fakeState1.current_backlog_id -TaskText $fakeState1.current_task -StateObj $fakeState1

Assert-True ($r1.Covered -eq $true) "Covered=true when restart+clean+commit exists"
Assert-True (-not [string]::IsNullOrWhiteSpace($r1.Sha)) "Sha is non-empty"
Write-Host "  Sha returned: $($r1.Sha)"

Write-Host ""
Write-Host "=== Test-CoveredAfterRestart: scenario 2 (not covered - no matching commit) ==="
$fakeState2 = @{
  task_apply_restart_count = 1
  task_hard_restart_count  = 0
  critic_verdict_cache     = @{ verdict = 'OK' }
  claimed_at               = (Get-Date).AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:sszzz')
  current_backlog_id       = ''
  current_task             = 'XNOMATCH_unique_task_text_that_will_never_be_in_any_commit_xyz987'
}
$r2 = Test-CoveredAfterRestart -BridgeRoot $BridgeRoot -ClaimedAt $fakeState2.claimed_at `
  -BacklogId $fakeState2.current_backlog_id -TaskText $fakeState2.current_task -StateObj $fakeState2

Assert-True ($r2.Covered -eq $false) "Covered=false when no matching commit"
Assert-True ([string]::IsNullOrWhiteSpace($r2.Sha)) "Sha is empty when not covered"

Write-Host ""
Write-Host "=== Test-CoveredAfterRestart: scenario 3 (not covered - no restart) ==="
$fakeState3 = @{
  task_apply_restart_count = 0
  task_hard_restart_count  = 0
  critic_verdict_cache     = @{ verdict = 'OK' }
  claimed_at               = $claimedAtDt
  current_backlog_id       = ''
  current_task             = $headMsg
}
$r3 = Test-CoveredAfterRestart -BridgeRoot $BridgeRoot -ClaimedAt $fakeState3.claimed_at `
  -BacklogId $fakeState3.current_backlog_id -TaskText $fakeState3.current_task -StateObj $fakeState3

Assert-True ($r3.Covered -eq $false) "Covered=false when restart_count=0 (no restart)"

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 } else { exit 0 }
