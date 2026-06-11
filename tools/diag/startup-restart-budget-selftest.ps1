#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:DecisionsDir = Join-Path $env:TEMP ('startup-restart-budget-' + [guid]::NewGuid().ToString('N'))
$script:State = $null
$script:Messages = New-Object 'System.Collections.Generic.List[string]'
$script:SetIdeaCalls = 0
$script:SalvageCalls = 0
$script:ReplayCalls = 0
$script:Failures = 0

function Get-DecisionsPath { return $script:DecisionsDir }
function Sweep-AgentOrphans {}
function Get-BridgeConfig { return [pscustomobject]@{ taskRestartCap = 3 } }
function Read-State { return $script:State }
function Update-State {
  param([scriptblock]$Block)
  & $Block $script:State
  return $script:State
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind)
  [void]$script:Messages.Add($Text)
}
function Set-Idea {
  param([string]$Id, [string]$Status, [string]$Reason)
  $script:SetIdeaCalls++
}
function Invoke-FailedTaskSalvage {
  param([string]$TaskText, [string]$BacklogId)
  $script:SalvageCalls++
}
function Start-ReplayForStateTask {
  param([object]$State, [string]$TaskText, [string]$ChannelName)
  $script:ReplayCalls++
}
function Write-DoctorLog { param([string]$Text) }
function Get-LastSnapshot { param([string]$Channel) return $null }
function Get-DoctorRestartCount { param([object]$State) return 0 }
function Get-DoctorMaxRestartResumes { return 99 }
function Get-DoctorRepairAttemptCount { param([object]$State) return 1 }
function Get-DoctorMaxRepairAttempts { return 3 }
function Close-ReplayForStateTask { param([object]$State, [string]$Status) }
function Clear-AuditorSuppressedHashes { param([object]$State) }
function Clear-FastLaneFlags { param([object]$State, [switch]$PreserveReflectSkip) }
function Clear-ChunkingState { param([object]$State) }

. (Join-Path $root 'driver\60-startup.ps1')

function Assert-StartupBudget {
  param([string]$Name, [bool]$Condition, $Actual = $null)
  if ($Condition) {
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:Failures++
    $detail = ''
    if ($null -ne $Actual) { $detail = ' actual=' + [string]$Actual }
    Write-Host ("FAIL " + $Name + $detail) -ForegroundColor Red
  }
}

function Write-Ledger {
  param([object[]]$Entries)
  if (Test-Path -LiteralPath $script:DecisionsDir) { Remove-Item -LiteralPath $script:DecisionsDir -Recurse -Force }
  New-Item -ItemType Directory -Path $script:DecisionsDir -Force | Out-Null
  $ledger = Join-Path $script:DecisionsDir 'session-ledger.jsonl'
  $u8NoBom = New-Object System.Text.UTF8Encoding($false)
  foreach ($entry in $Entries) {
    [System.IO.File]::AppendAllText($ledger, (($entry | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine), $u8NoBom)
  }
}

function Reset-Fixture {
  $script:State = [pscustomobject][ordered]@{
    current_task       = 'DOCTOR repair task'
    current_task_id    = 'doctor-task'
    current_backlog_id = 'backlog-1'
    task_restart_count = 3
    doctor_active      = $true
    held_task          = 'held task'
    status             = 'working'
    stop               = $false
    abort              = $false
    task_turn          = 0
    task_mode          = 'normal'
    task_did_actions   = $false
    coder_fired        = $false
    verify_retry_count = 0
    critic_retry_count = 0
    active_agent       = $null
    active_model       = $null
    status_text        = $null
    agent_pid          = $null
    current_agent      = $null
    current_agent_pid  = 0
    current_agent_ticks = 0
    current_agent_since = $null
    agent_telemetry    = $null
    driver_started     = $null
    heartbeat          = $null
    doctor_restart_count = 0
  }
  $script:Messages.Clear()
  $script:SetIdeaCalls = 0
  $script:SalvageCalls = 0
  $script:ReplayCalls = 0
}

try {
  Write-Host '[SRB1] exhausted restart budget + verified repair after task_start resumes instead of failing'
  Reset-Fixture
  Write-Ledger @(
    [ordered]@{ ts = '2026-06-11T01:57:51+03:00'; event = 'task_start'; channel = 'main'; task = 'parent' },
    [ordered]@{ ts = '2026-06-11T03:47:11+03:00'; event = 'verified_commit'; channel = 'main'; what = 'repair verified' }
  )
  Initialize-DriverStartup
  Assert-StartupBudget 'SRB1 did not fail backlog item' ($script:SetIdeaCalls -eq 0) $script:SetIdeaCalls
  Assert-StartupBudget 'SRB1 did not salvage as failed tail' ($script:SalvageCalls -eq 0) $script:SalvageCalls
  Assert-StartupBudget 'SRB1 resumed task replay' ($script:ReplayCalls -eq 1) $script:ReplayCalls
  Assert-StartupBudget 'SRB1 restart count reset then incremented' ([int]$script:State.task_restart_count -eq 1) $script:State.task_restart_count
  Assert-StartupBudget 'SRB1 reset message emitted' (@($script:Messages | Where-Object { $_ -match 'Restart-budget' }).Count -eq 1) ($script:Messages -join ' | ')

  Write-Host ''
  Write-Host '[SRB2] exhausted restart budget without verified marker still fails closed'
  Reset-Fixture
  Write-Ledger @(
    [ordered]@{ ts = '2026-06-11T01:57:51+03:00'; event = 'task_start'; channel = 'main'; task = 'parent' },
    [ordered]@{ ts = '2026-06-11T03:20:46+03:00'; event = 'doctor_fix'; channel = 'main'; what = 'doctor_activated' }
  )
  Initialize-DriverStartup
  Assert-StartupBudget 'SRB2 failed backlog item' ($script:SetIdeaCalls -eq 1) $script:SetIdeaCalls
  Assert-StartupBudget 'SRB2 salvage attempted' ($script:SalvageCalls -eq 1) $script:SalvageCalls
  Assert-StartupBudget 'SRB2 did not resume replay' ($script:ReplayCalls -eq 0) $script:ReplayCalls
  Assert-StartupBudget 'SRB2 task cleared' ([string]::IsNullOrWhiteSpace([string]$script:State.current_task)) $script:State.current_task
} finally {
  if (Test-Path -LiteralPath $script:DecisionsDir) { Remove-Item -LiteralPath $script:DecisionsDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -gt 0) {
  Write-Host ("STARTUP-RESTART-BUDGET: FAIL " + $script:Failures) -ForegroundColor Red
  exit 1
}

Write-Host 'STARTUP-RESTART-BUDGET: PASS'
