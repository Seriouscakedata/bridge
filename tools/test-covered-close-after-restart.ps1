#Requires -Version 5.1
<#
.SYNOPSIS
  Acceptance test: covered-after-restart closes only on exact task marker with commit-relative QA/critic evidence.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0

. (Join-Path $BridgeRoot 'lib\task-action-evidence.ps1')
. (Join-Path $BridgeRoot 'driver\86-loop-completion-checks.ps1')

function Invoke-TestGit {
  param(
    [string]$RepoRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
  )
  & git -C $RepoRoot @Args 2>$null
}

function Assert-True([bool]$cond, [string]$label, [object]$actual = $null) {
  if ($cond) {
    Write-Host "  PASS: $label"
    $script:passed++
    return
  }
  $suffix = if ($null -ne $actual) { ' actual=' + ($actual | ConvertTo-Json -Compress -Depth 5) } else { '' }
  Write-Host "  FAIL: $label$suffix"
  $script:failed++
}

function New-CoveredState {
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
    current_task             = 'Template task text that must not be used for recovery matching'
    task_started_at          = $startedMap
    qa_verdict_cache         = [pscustomobject]@{ head = $Head; verdict = 'PASS'; source = 'post_commit'; ts = $CriticTs }
    critic_verdict_cache     = [pscustomobject]@{ verdict = 'OK'; severity = 'none'; ts = $CriticTs }
  }
}

$tmpParent = Join-Path $BridgeRoot 'tmp'
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
$fixtureRoot = Join-Path $tmpParent ("bridge-covered-close-test-" + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
  Invoke-TestGit -RepoRoot $fixtureRoot init -q
  Invoke-TestGit -RepoRoot $fixtureRoot config user.email 'bridge-test@example.invalid'
  Invoke-TestGit -RepoRoot $fixtureRoot config user.name 'Bridge Test'
  Invoke-TestGit -RepoRoot $fixtureRoot config commit.gpgsign false

  Set-Content -LiteralPath (Join-Path $fixtureRoot 'fixture.ps1') -Value "'covered'" -Encoding UTF8
  Invoke-TestGit -RepoRoot $fixtureRoot add fixture.ps1
  $longTask = 'x' * 240
  $msg = ('[task:task-covered] auto-commit (driver): ' + $longTask)
  if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) }
  Invoke-TestGit -RepoRoot $fixtureRoot commit -q --no-gpg-sign -m $msg

  $headSha = ([string](Invoke-TestGit -RepoRoot $fixtureRoot rev-parse HEAD | Select-Object -First 1)).Trim()
  $subject = ([string](Invoke-TestGit -RepoRoot $fixtureRoot log -1 --format=%s HEAD | Select-Object -First 1)).Trim()
  $commitTs = [int64](([string](Invoke-TestGit -RepoRoot $fixtureRoot log -1 --format=%ct HEAD | Select-Object -First 1)).Trim())
  $startedAt = [datetimeoffset]::FromUnixTimeSeconds($commitTs - 60).ToString('o')
  $criticAfter = [datetimeoffset]::FromUnixTimeSeconds($commitTs + 1).ToString('o')
  $criticBefore = [datetimeoffset]::FromUnixTimeSeconds($commitTs - 1).ToString('o')

  Write-Host "=== Test-CoveredAfterRestart: marker survives truncation ==="
  Assert-True ($subject.StartsWith('[task:task-covered] ')) 'marker is prepended before truncation' $subject

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 1 (covered) ==="
  $state1 = New-CoveredState -TaskId 'task-covered' -StartedAt $startedAt -Head $headSha -CriticTs $criticAfter
  $r1 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt 'ignored' -BacklogId 'task-covered' -TaskText $state1.current_task -StateObj $state1
  Assert-True ($r1.Covered -eq $true) 'Covered=true with exact marker, QA HEAD, critic after commit' $r1
  Assert-True ($r1.Sha -eq $headSha) 'Sha matches HEAD' $r1

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 2 (no text fallback) ==="
  $state2 = New-CoveredState -TaskId 'task-template-prefix' -StartedAt $startedAt -Head $headSha -CriticTs $criticAfter
  $r2 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt 'ignored' -BacklogId 'task-template-prefix' -TaskText '[task:task-covered] same visible text should not matter' -StateObj $state2
  Assert-True ($r2.Covered -eq $false) 'Covered=false for id mismatch even when task text resembles commit subject' $r2

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 3 (critic stale) ==="
  $state3 = New-CoveredState -TaskId 'task-covered' -StartedAt $startedAt -Head $headSha -CriticTs $criticBefore
  $r3 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt 'ignored' -BacklogId 'task-covered' -TaskText $state3.current_task -StateObj $state3
  Assert-True ($r3.Covered -eq $false) 'Covered=false when critic OK predates commit' $r3

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 4 (no restart) ==="
  $state4 = New-CoveredState -TaskId 'task-covered' -StartedAt $startedAt -Head $headSha -CriticTs $criticAfter
  $state4.task_apply_restart_count = 0
  $r4 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt 'ignored' -BacklogId 'task-covered' -TaskText $state4.current_task -StateObj $state4
  Assert-True ($r4.Covered -eq $false) 'Covered=false when restart_count=0' $r4

  Write-Host ""
  Write-Host "=== Test-CoveredAfterRestart: scenario 5 (QA head mismatch) ==="
  $state5 = New-CoveredState -TaskId 'task-covered' -StartedAt $startedAt -Head ('0' * 40) -CriticTs $criticAfter
  $r5 = Test-CoveredAfterRestart -BridgeRoot $fixtureRoot -ClaimedAt 'ignored' -BacklogId 'task-covered' -TaskText $state5.current_task -StateObj $state5
  Assert-True ($r5.Covered -eq $false) 'Covered=false when qa_verdict_cache.head != HEAD' $r5
} finally {
  if ($fixtureRoot -like (Join-Path $tmpParent 'bridge-covered-close-test-*')) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 } else { exit 0 }
