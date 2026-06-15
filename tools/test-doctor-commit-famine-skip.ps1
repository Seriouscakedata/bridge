#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-doctor-famine-" + [guid]::NewGuid().ToString('N'))
$script:DoctorLogPath = Join-Path $script:TestBridgeRoot 'control\doctor.log'

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

function New-CommitFamineSnapshot {
  param([string]$LastCommitMsg)

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
        working_tree_lines = 1
        last_commit_age_min = 45
        last_commit_msg = $LastCommitMsg
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

  Write-Host '--- Scenario 1: doctor_last_commit_with_qa_pass ---'
  $recent = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss')
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  Assert-True (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath) 'Scenario 1: fresh repaired log returns true'
  Assert-True (-not (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg 'ДОКТОР: repaired bridge'))) 'Scenario 1: commit_famine suppressed'

  Write-Host '--- Scenario 2: doctor_last_commit_no_qa_pass ---'
  $old = (Get-Date).AddMinutes(-400).ToString('yyyy-MM-dd HH:mm:ss')
  Write-DoctorLogLines @("[${old}] Doctor complete: repaired")
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath)) 'Scenario 2: stale repaired log returns false'
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg 'ДОКТОР: repaired bridge')) 'Scenario 2: commit_famine remains active'

  Write-Host '--- Scenario 3: non_doctor_last_commit ---'
  Write-DoctorLogLines @("[${recent}] Doctor complete: repaired")
  Assert-True (Has-CommitFamineTrigger -Snapshot (New-CommitFamineSnapshot -LastCommitMsg 'fix: ordinary change')) 'Scenario 3: non-doctor commit does not suppress'

  Write-Host '--- Scenario 4: doctor_log_missing ---'
  Clear-DoctorLog
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath)) 'Scenario 4: missing doctor.log returns false'

  Write-Host '--- Scenario 5: doctor_log_only_activate ---'
  Write-DoctorLogLines @("[${recent}] Doctor activate: commit_famine")
  Assert-True (-not (Test-AuditorDoctorQaPass -MaxMinutes 360 -LogPath $script:DoctorLogPath)) 'Scenario 5: activate without complete returns false'
} finally {
  try {
    if (Test-Path -LiteralPath $script:TestBridgeRoot) {
      Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force
    }
  } catch {}
}

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
