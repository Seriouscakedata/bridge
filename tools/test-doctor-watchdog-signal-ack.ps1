#Requires -Version 5.1
# test-doctor-watchdog-signal-ack.ps1 -- duplicate watchdog repair.signal suppression.

param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0
$script:TestRoot = ''

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

function Assert-Eq {
  param($Actual, $Expected, [string]$Label)
  if ($Actual -eq $Expected) {
    $script:PassCount++
    Write-Host "PASS: $Label"
  } else {
    $script:FailCount++
    Write-Host "FAIL: $Label : got '$Actual' expected '$Expected'"
  }
}

function Get-BridgeRoot { return $script:TestRoot }
function Read-State { return $script:State }
function Update-State {
  param([scriptblock]$Updater)
  & $Updater $script:State | Out-Null
  return $script:State
}
function Add-Message { param([string]$From, [string]$Text, [string]$Kind) return $true }
function Append-DoctorEvent { param([string]$Event, [string]$Reason = '') return $true }
function Clear-AuditorSuppressedHashes { param($State) return }

. (Join-Path $BridgeRoot 'lib\doctor.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('doctor-signal-ack-' + [guid]::NewGuid().ToString('N'))
try {
  $script:TestRoot = $tmp
  New-Item -ItemType Directory -Path (Join-Path $tmp 'control') -Force | Out-Null
  $watchdogLog = Join-Path $tmp 'control\watchdog.log'
  $signalPath = Join-Path $tmp 'control\repair.signal'

  [System.IO.File]::WriteAllText($watchdogLog, @"
2026-07-02 19:27:05  API STILL down after restart -> server code likely broken -> ROLLBACK (safety branch) + restart
2026-07-02 19:27:06  reset --hard stable
2026-07-02 19:27:33  rollback applied (api-stuck)
"@, [System.Text.Encoding]::UTF8)

  [System.IO.File]::WriteAllText($signalPath, 'watchdog_rollback_api_stuck', [System.Text.Encoding]::UTF8)
  Assert-Eq (Test-DoctorSignal) 'watchdog_rollback_api_stuck' 'first watchdog signal is admitted'
  Assert-True (-not (Test-Path -LiteralPath $signalPath)) 'first signal is consumed'

  $script:State = [pscustomobject][ordered]@{
    current_task = 'doctor prompt'
    held_task = ''
    current_backlog_id = ''
    doctor_active = $true
    doctor_reason = 'watchdog_rollback_api_stuck'
    doctor_started_at = (Get-Date).ToUniversalTime().ToString('o')
    doctor_attempts = 1
    doctor_repair_attempts = 1
    doctor_restart_count = 0
    doctor_repair_task_id = ''
    doctor_hold_head = ''
    doctor_held_base_commit = ''
    task_turn = 1
    task_mode = 'normal'
    no_progress_count = 0
    timeout_retry_count = 0
    task_did_actions = $true
    coder_fired = $true
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
  Complete-Doctor
  Assert-True (Test-Path -LiteralPath (Get-DoctorSignalAckPath)) 'Complete-Doctor writes ack for completed watchdog signal'
  [System.IO.File]::WriteAllText($signalPath, 'watchdog_rollback_api_stuck', [System.Text.Encoding]::UTF8)
  Assert-True ($null -eq (Test-DoctorSignal)) 'duplicate watchdog signal for same rollback is ignored'
  Assert-True (-not (Test-Path -LiteralPath $signalPath)) 'duplicate signal is consumed'

  Add-Content -LiteralPath $watchdogLog -Value '2026-07-02 20:00:00  rollback applied (api-stuck)' -Encoding UTF8
  [System.IO.File]::WriteAllText($signalPath, 'watchdog_rollback_api_stuck', [System.Text.Encoding]::UTF8)
  Assert-Eq (Test-DoctorSignal) 'watchdog_rollback_api_stuck' 'new rollback marker is admitted despite previous ack'

  Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
  if ($script:FailCount -gt 0) { exit 1 }
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($tmp)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
