#Requires -Version 5.1
# test-doctor-commit-famine-resolve.ps1 -- Doctor commit_famine ready-close and repair counter ownership.

param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0
$script:State = $null
$script:SetIdeaCalls = @()
$script:BacklogLines = @()

function New-TestState {
  param(
    [string]$BacklogId = 'task-ready',
    [int]$RepairAttempts = 0,
    [string]$RepairOwner = '',
    [string]$Reason = 'auditor:commit_famine'
  )

  if ([string]::IsNullOrWhiteSpace($RepairOwner) -and -not [string]::IsNullOrWhiteSpace($BacklogId)) {
    $RepairOwner = 'backlog:' + $BacklogId
  }

  return [pscustomobject][ordered]@{
    current_task = ''
    held_task = '[Автозадача] ready but uncommitted'
    current_backlog_id = $BacklogId
    current_task_id = ''
    task_id = ''
    doctor_active = $true
    doctor_reason = $Reason
    doctor_started_at = (Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o')
    doctor_attempts = $RepairAttempts
    doctor_repair_attempts = $RepairAttempts
    doctor_restart_count = 1
    doctor_repair_task_id = $RepairOwner
    doctor_hold_head = 'base0001'
    doctor_held_base_commit = 'base0001'
    qa_verdict_cache = [pscustomobject]@{ head = 'head0002'; verdict = 'PASS'; source = 'post_commit'; ts = (Get-Date).ToUniversalTime().ToString('o') }
    task_turn = 0
    task_mode = 'normal'
    task_start_seq = 0
    lastSeq = 10
    no_progress_count = 0
    timeout_retry_count = 0
    task_did_actions = $false
    coder_fired = $false
    coder_bypass_retry_count = 0
    verify_retry_count = 0
    critic_retry_count = 0
    force_planner = $false
    discuss_turn = 0
    discuss_snapshot = ''
    study_phase = ''
    study_subtype = ''
    study_snapshot = ''
    research_count = 0
    active_agent = $null
    active_model = $null
    status_text = $null
    agent_pid = $null
    status = 'working'
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Label)
  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Label"
  } else {
    $script:FailCount++
    Write-Host "FAIL: $Label"
  }
}

function Get-BridgeRoot { return $BridgeRoot }
function Get-BridgeConfig { return [pscustomobject]@{ doctor = [pscustomobject]@{ maxRepairAttempts = 3; maxRestartResumes = 3 } } }
function Read-State { return $script:State }
function Update-State {
  param([scriptblock]$Updater)
  & $Updater $script:State | Out-Null
  return $script:State
}
function Add-Message { param([string]$From, [string]$Text, [string]$Kind) return $true }
function Append-DoctorEvent { param([string]$Event, [string]$Reason = '') return $true }
function Write-DoctorLog { param([string]$Message) return $true }
function Save-StateSnapshot { param([string]$Reason) return $true }
function Clear-AuditorSuppressedHashes { param($State) return }
function Clear-FastLaneFlags { param($State) return }
function Close-ReplayForStateTask { param($State, [string]$Status) return }
function Send-PushEvent { param([string]$Kind, [string]$Text) return }
function Set-Idea {
  param([string]$Id, $Status = $null, [string]$Reason = $null)
  $script:SetIdeaCalls += [pscustomobject]@{ id = $Id; status = [string]$Status; reason = [string]$Reason }
  return $true
}
function Write-BacklogJsonLine {
  param($Record)
  $script:BacklogLines += $Record
}

. (Join-Path $BridgeRoot 'lib\doctor.ps1')

function Get-DoctorGitHead { param([string]$Root = '') return 'head0002' }
function Get-DoctorGitStatusText { param([string]$Root = '') return ' M lib/doctor.ps1' }
function Get-DoctorLastCommitMessage { param([string]$Root = '') return 'fix: completed held task' }

Write-Host '=== Doctor commit_famine resolve ==='

$script:State = New-TestState -BacklogId 'task-ready' -RepairAttempts 0
$script:SetIdeaCalls = @()
$script:BacklogLines = @()
Assert-True (Test-DoctorHeldWorkReady -State $script:State) 'ready dirty held task with QA PASS is detected under auditor:commit_famine'
$resolved = Complete-Doctor -ResolveHeldDone
Assert-True ([bool]$resolved) 'Complete-Doctor -ResolveHeldDone returns true'
Assert-True (@($script:SetIdeaCalls).Count -eq 1) 'ready held task is closed exactly once'
Assert-True ([string]$script:SetIdeaCalls[0].id -eq 'task-ready' -and [string]$script:SetIdeaCalls[0].status -eq 'done') 'ready held task is marked done'
Assert-True (-not [bool]$script:State.doctor_active -and [string]::IsNullOrWhiteSpace([string]$script:State.current_task) -and [string]::IsNullOrWhiteSpace([string]$script:State.held_task)) 'Doctor state is cleared to idle without restoring held task'
Assert-True ([int]$script:State.doctor_repair_attempts -eq 0) 'ready-close does not consume a repair attempt'
Assert-True (@($script:BacklogLines).Count -eq 1 -and [string]$script:BacklogLines[0].action -eq 'doctor-resolve-held-done') 'resolve close writes task outcome audit line'

Write-Host '=== Doctor repair counter owner survives same-task restart ==='

$script:State = New-TestState -BacklogId 'task-same' -RepairAttempts 2 -RepairOwner 'backlog:task-same'
$same = Sync-DoctorRepairCounterOwner -State $script:State
Assert-True ([int]$same.doctor_repair_attempts -eq 2 -and [string]$same.doctor_repair_task_id -eq 'backlog:task-same') 'same held task keeps repair attempts across simulated restart'

$script:State.current_backlog_id = 'task-other'
$different = Sync-DoctorRepairCounterOwner -State $script:State
Assert-True ([int]$different.doctor_repair_attempts -eq 0 -and [string]$different.doctor_repair_task_id -eq 'backlog:task-other') 'different held task resets repair attempts and owner'

$script:State = New-TestState -BacklogId 'task-same' -RepairAttempts 2 -RepairOwner 'backlog:task-same'
$script:State.current_task = '[Автозадача] ready but uncommitted'
$script:State.doctor_active = $false
$activated = Activate-Doctor -Reason 'auditor:commit_famine'
Assert-True ([bool]$activated) 'Activate-Doctor accepts same task'
Assert-True ([int]$script:State.doctor_repair_attempts -eq 2 -and [string]$script:State.doctor_repair_task_id -eq 'backlog:task-same') 'Activate-Doctor preserves repair attempts for same task owner'

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
