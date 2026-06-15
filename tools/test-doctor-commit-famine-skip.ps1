#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-doctor-famine-" + [guid]::NewGuid().ToString('N'))
$script:DoctorLogPath = Join-Path $script:TestBridgeRoot 'control\doctor.log'
$script:HeadSha = 'abcdef1234567890abcdef1234567890abcdef12'

function Get-BridgeRoot { return $script:TestBridgeRoot }

function Get-BridgeConfig {
  return [pscustomobject]@{
    criticMaxRetries = 2
    auditor = [pscustomobject]@{
      enabled = $true
      intervalMin = 15
      cooldownMin = 30
      model = 'gemini-2.5-flash-lite'
      doctorRecidivismHours = 24
      doctorRecidivismMax = 99
    }
  }
}

function Recover-ZombieJobs {
  param([string]$Slug)
  return [pscustomobject]@{ recovered = 0 }
}

. (Join-Path $BridgeRoot 'lib\auditor.ps1')

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Label"
    return
  }

  $script:FailCount++
  Write-Host "FAIL: $Label"
}

function Write-DoctorLogLines {
  param([string[]]$Lines)
  $dir = Split-Path -Parent $script:DoctorLogPath
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllLines($script:DoctorLogPath, $Lines, (New-Object System.Text.UTF8Encoding($true)))
}

function Clear-DoctorLog {
  if (Test-Path -LiteralPath $script:DoctorLogPath) {
    Remove-Item -LiteralPath $script:DoctorLogPath -Force
  }
}

function New-QaVerdictCache {
  param(
    [string]$Head = $script:HeadSha,
    [string]$Verdict = 'PASS',
    [string]$Source = 'post_commit',
    [int]$MinutesAgo = 10
  )

  return [pscustomobject]@{
    head = $Head
    verdict = $Verdict
    source = $Source
    ts = (Get-Date).AddMinutes(-[Math]::Abs($MinutesAgo)).ToUniversalTime().ToString('o')
  }
}

function New-CommitFamineSnapshot {
  param(
    [string]$LastCommitMsg,
    $QaVerdictCache = $null,
    [string]$Head = $script:HeadSha
  )

  return [pscustomobject]@{
    channels = [ordered]@{
      main = [pscustomobject]@{
        status = 'working'
        doctor_active = $false
        agent_pid_alive = $false
        hb_age_sec = 120
        task_turn = 1
        task_mode = 'normal'
        discuss_turn = 0
        task_id = 'test-task'
        task_start_seq = 1
        critic_retry_count = 0
        current_task_short = 'test task'
        restart_events_20min = 0
        head = $Head.Substring(0, 7)
        head_full = $Head
        working_tree_lines = 1
        last_commit_age_min = 45
        last_commit_msg = $LastCommitMsg
        qa_verdict_cache = $QaVerdictCache
        empty_reply_streak = 0
        progress_fingerprint_repeats = 0
        task_age_min = 45
        last_seq = 1
        last_seq_age_min = 0
        status_text = ''
        active_jobs_count = 0
        active_agent = 'codex'
      }
    }
    git = [pscustomobject]@{
      working_tree_lines = 0
    }
    supervisor_restarts_20min = 0
    doctor_activations_24h = 0
  }
}

function Has-CommitFamineTrigger {
  param($Snapshot)

  $triggers = @(Test-AuditorTriggers -Snapshot $Snapshot)
  foreach ($trigger in $triggers) {
    if ([string]$trigger.name -eq 'commit_famine') { return $true }
  }
  return $false
}

try {
  New-Item -ItemType Directory -Path (Join-Path $script:TestBridgeRoot 'control') -Force | Out-Null

  Write-Host '=== doctor commit_famine skip ==='
  $doctorCommitMsg = 'auto-commit (driver; coder sandbox cannot reach .git): ДОКТОР — задача саморемонта моста'
  $ordinaryMentionsMarker = 'auto-commit (driver; coder sandbox cannot reach .git): [Автозадача] проверить маркер «ДОКТОР» в auditor'

  Write-Host '--- Scenario 1: doctor_last_commit_with_qa_pass ---'
  $recent = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss')
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  $freshQaCache = New-QaVerdictCache
  Assert-True (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $freshQaCache -CommitSha $script:HeadSha) 'Scenario 1: fresh repaired log and post-commit QA cache return true'
  Assert-True (-not (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg $doctorCommitMsg -QaVerdictCache $freshQaCache))) 'Scenario 1: commit_famine suppressed'

  Write-Host '--- Scenario 2: doctor_last_commit_no_qa_pass ---'
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $null -CommitSha $script:HeadSha)) 'Scenario 2: missing post-commit QA cache returns false'
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg $doctorCommitMsg -QaVerdictCache $null)) 'Scenario 2: commit_famine remains active'

  Write-Host '--- Scenario 3: non_doctor_last_commit ---'
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg 'fix: ordinary change' -QaVerdictCache $freshQaCache)) 'Scenario 3: non-doctor commit does not suppress'

  Write-Host '--- Scenario 4: doctor_log_missing ---'
  Clear-DoctorLog
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $freshQaCache -CommitSha $script:HeadSha)) 'Scenario 4: missing doctor.log returns false'

  Write-Host '--- Scenario 5: doctor_log_only_activate ---'
  Write-DoctorLogLines @("[${recent}] Doctor activate: commit_famine")
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $freshQaCache -CommitSha $script:HeadSha)) 'Scenario 5: activate without complete returns false'

  Write-Host '--- Scenario 6: doctor_last_commit_stale_repair ---'
  $old = (Get-Date).AddMinutes(-400).ToString('yyyy-MM-dd HH:mm:ss')
  Write-DoctorLogLines @("[${old}] Doctor complete: repaired")
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $freshQaCache -CommitSha $script:HeadSha)) 'Scenario 6: stale repaired log returns false'
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg $doctorCommitMsg -QaVerdictCache $freshQaCache)) 'Scenario 6: commit_famine remains active'

  Write-Host '--- Scenario 7: ordinary_task_mentions_doctor_marker ---'
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  Assert-True (-not (Test-AuditorDoctorCommitMessage -Message $ordinaryMentionsMarker)) 'Scenario 7: ordinary task title is not treated as Doctor commit'
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg $ordinaryMentionsMarker -QaVerdictCache $freshQaCache)) 'Scenario 7: marker mention does not suppress'

  Write-Host '--- Scenario 8: qa_cache_wrong_source_or_head ---'
  $wrongSourceCache = New-QaVerdictCache -Source 'done_gate'
  $wrongHeadCache = New-QaVerdictCache -Head '1111111234567890abcdef1234567890abcdef12'
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $wrongSourceCache -CommitSha $script:HeadSha)) 'Scenario 8: non-post_commit QA cache returns false'
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath -QaVerdictCache $wrongHeadCache -CommitSha $script:HeadSha)) 'Scenario 8: QA cache for another head returns false'
} finally {
  try {
    if (Test-Path -LiteralPath $script:TestBridgeRoot) {
      Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force
    }
  } catch {}
}

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
