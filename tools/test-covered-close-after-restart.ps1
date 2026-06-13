#Requires -Version 5.1
<#
.SYNOPSIS
  Acceptance test: Test-CoveredAfterRestart covered-close logic.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0
$existingGetTaskRepoRoot = Get-Command Get-TaskRepoRoot -ErrorAction SilentlyContinue
$script:CoveredCloseProjectRepoRoot = ''

# Load the function under test
. (Join-Path $BridgeRoot 'driver\86-loop-completion-checks.ps1')

function Invoke-TestGit {
  param(
    [string]$RepoRoot = $BridgeRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
  )

  & git -c "safe.directory=$RepoRoot" -C $RepoRoot @Args 2>$null
}

function Assert-True([bool]$cond, [string]$label) {
  if ($cond) { Write-Host "  PASS: $label"; $script:passed++ }
  else        { Write-Host "  FAIL: $label"; $script:failed++ }
}

$tmpParent = Join-Path $BridgeRoot 'tmp'
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
$fixtureRoot = Join-Path $tmpParent ("bridge-covered-close-test-" + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $tmpParent ("bridge-covered-close-project-" + [guid]::NewGuid().ToString('N'))
$missingProjectRoot = Join-Path $tmpParent ("bridge-covered-close-missing-" + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
  & git -C $fixtureRoot init -q
  & git -C $fixtureRoot config user.email 'bridge-test@example.invalid'
  & git -C $fixtureRoot config user.name 'Bridge Test'
  & git -C $fixtureRoot config commit.gpgsign false
  Set-Content -LiteralPath (Join-Path $fixtureRoot 'fixture.txt') -Value 'covered-close fixture' -Encoding UTF8
  $headMsg = 'covered-close plus+ [literal] (ok) fixture commit'
  & git -C $fixtureRoot add fixture.txt
  & git -C $fixtureRoot commit -q --no-gpg-sign -m $headMsg

  $headSha = (& { Invoke-TestGit -RepoRoot $fixtureRoot log --oneline -1 } | Select-Object -First 1).Split(' ')[0].Trim()
  $claimedAt = (& { Invoke-TestGit -RepoRoot $fixtureRoot log --format=%aI -1 } | Out-String).Trim()
  $commitAt = [datetimeoffset]::Parse($claimedAt)
  $claimedAtDt = $commitAt.AddSeconds(-5).ToString('o')
  $criticOkCache = @{ verdict = 'OK'; severity = 'none'; ts = $commitAt.AddSeconds(5).ToString('o') }
  $criticStaleCache = @{ verdict = 'OK'; severity = 'none'; ts = $commitAt.AddSeconds(-30).ToString('o') }

  Write-Host "=== Test-CoveredAfterRestart: scenario 1 (covered - restart + clean tree + real literal commit) ==="
  $fakeState1 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = $criticOkCache
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r1 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState1.claimed_at `
    -BacklogId $fakeState1.current_backlog_id -TaskText $fakeState1.current_task -StateObj $fakeState1

  Assert-True ($r1.Covered -eq $true) "Covered=true when restart+clean+commit exists"
  Assert-True ($r1.Sha -eq $headSha) "Sha matches fixture HEAD"
  Write-Host "  Sha returned: $($r1.Sha)"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 2 (not covered - no matching commit) ==="
  $fakeState2 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = $criticOkCache
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = 'XNOMATCH_unique_task_text_that_will_never_be_in_any_commit_xyz987'
  }
  $r2 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState2.claimed_at `
    -BacklogId $fakeState2.current_backlog_id -TaskText $fakeState2.current_task -StateObj $fakeState2

  Assert-True ($r2.Covered -eq $false) "Covered=false when no matching commit"
  Assert-True ([string]::IsNullOrWhiteSpace($r2.Sha)) "Sha is empty when not covered"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 3 (not covered - no restart) ==="
  $fakeState3 = @{
    task_apply_restart_count = 0
    task_hard_restart_count  = 0
    critic_verdict_cache     = $criticOkCache
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r3 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState3.claimed_at `
    -BacklogId $fakeState3.current_backlog_id -TaskText $fakeState3.current_task -StateObj $fakeState3

  Assert-True ($r3.Covered -eq $false) "Covered=false when restart_count=0 (no restart)"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 4 (not covered - critic missing) ==="
  $fakeState4 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r4 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState4.claimed_at `
    -BacklogId $fakeState4.current_backlog_id -TaskText $fakeState4.current_task -StateObj $fakeState4

  Assert-True ($r4.Covered -eq $false) "Covered=false when critic verdict is missing"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 5 (not covered - critic not OK) ==="
  $fakeState5 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = @{ verdict = 'WARN'; severity = 'serious'; ts = $commitAt.AddSeconds(5).ToString('o') }
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r5 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState5.claimed_at `
    -BacklogId $fakeState5.current_backlog_id -TaskText $fakeState5.current_task -StateObj $fakeState5

  Assert-True ($r5.Covered -eq $false) "Covered=false when critic verdict is not OK"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 6 (not covered - critic OK is stale) ==="
  $fakeState6 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = $criticStaleCache
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r6 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState6.claimed_at `
    -BacklogId $fakeState6.current_backlog_id -TaskText $fakeState6.current_task -StateObj $fakeState6

  Assert-True ($r6.Covered -eq $false) "Covered=false when critic OK predates claimed_at"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 7 (not covered - critic timestamp missing) ==="
  $fakeState7 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = @{ verdict = 'OK'; severity = 'none' }
    claimed_at               = $claimedAtDt
    current_backlog_id       = ''
    current_task             = $headMsg
  }
  $r7 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState7.claimed_at `
    -BacklogId $fakeState7.current_backlog_id -TaskText $fakeState7.current_task -StateObj $fakeState7

  Assert-True ($r7.Covered -eq $false) "Covered=false when critic timestamp is missing"

  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
  & git -C $projectRoot init -q
  & git -C $projectRoot config user.email 'bridge-test@example.invalid'
  & git -C $projectRoot config user.name 'Bridge Test'
  & git -C $projectRoot config commit.gpgsign false
  Set-Content -LiteralPath (Join-Path $projectRoot 'project-fixture.txt') -Value 'covered-close project fixture' -Encoding UTF8
  $projectMsg = 'covered-close project repo matching fixture commit'
  & git -C $projectRoot add project-fixture.txt
  & git -C $projectRoot commit -q --no-gpg-sign -m $projectMsg
  $projectSha = (& { Invoke-TestGit -RepoRoot $projectRoot log --oneline -1 } | Select-Object -First 1).Split(' ')[0].Trim()
  $projectClaimedAt = (& { Invoke-TestGit -RepoRoot $projectRoot log --format=%aI -1 } | Out-String).Trim()
  $projectCommitAt = [datetimeoffset]::Parse($projectClaimedAt)
  $script:CoveredCloseProjectRepoRoot = $projectRoot
  Set-Item -Path Function:\Get-TaskRepoRoot -Value { return $script:CoveredCloseProjectRepoRoot }

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 8 (covered - matching commit in project repo) ==="
  $fakeState8 = @{
    task_apply_restart_count = 1
    task_hard_restart_count  = 0
    critic_verdict_cache     = @{ verdict = 'OK'; severity = 'none'; ts = $projectCommitAt.AddSeconds(5).ToString('o') }
    claimed_at               = $projectCommitAt.AddSeconds(-5).ToString('o')
    current_backlog_id       = ''
    current_task             = $projectMsg
  }
  $r8 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState8.claimed_at `
    -BacklogId $fakeState8.current_backlog_id -TaskText $fakeState8.current_task -StateObj $fakeState8

  Assert-True ($r8.Covered -eq $true) "Covered=true when matching commit is in project repo"
  Assert-True ($r8.Sha -eq $projectSha) "Sha matches project repo HEAD"
  Assert-True ($r8.Repo -eq (Resolve-Path -LiteralPath $projectRoot).ProviderPath) "Repo points to normalized project repo"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 9 (not covered - project repo dirty) ==="
  Set-Content -LiteralPath (Join-Path $projectRoot 'dirty.txt') -Value 'dirty project worktree' -Encoding UTF8
  $r9 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState8.claimed_at `
    -BacklogId $fakeState8.current_backlog_id -TaskText $fakeState8.current_task -StateObj $fakeState8

  Assert-True ($r9.Covered -eq $false) "Covered=false when any candidate repo is dirty"
  Assert-True ([string]::IsNullOrWhiteSpace($r9.Sha)) "Sha is empty when project repo is dirty"

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 10 (not covered - task repo cannot be resolved) ==="
  Set-Item -Path Function:\Get-TaskRepoRoot -Value { return $script:CoveredCloseMissingProjectRepoRoot }
  $script:CoveredCloseMissingProjectRepoRoot = $missingProjectRoot
  $r10 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt $fakeState1.claimed_at `
    -BacklogId $fakeState1.current_backlog_id -TaskText $fakeState1.current_task -StateObj $fakeState1

  Assert-True ($r10.Covered -eq $false) "Covered=false when task repo helper returns a missing repo"
  Assert-True ([string]::IsNullOrWhiteSpace($r10.Sha)) "Sha is empty when task repo is missing"
} finally {
  if ($fixtureRoot -like (Join-Path $tmpParent 'bridge-covered-close-test-*')) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($projectRoot -like (Join-Path $tmpParent 'bridge-covered-close-project-*')) {
    Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($existingGetTaskRepoRoot -and $existingGetTaskRepoRoot.CommandType -eq 'Function') {
    Set-Item -Path Function:\Get-TaskRepoRoot -Value $existingGetTaskRepoRoot.ScriptBlock
  } else {
    Remove-Item -Path Function:\Get-TaskRepoRoot -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 } else { exit 0 }
