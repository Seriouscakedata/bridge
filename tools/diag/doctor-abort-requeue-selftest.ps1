#Requires -Version 5.1
# VERIFY-COVERS: lib/doctor.ps1
# Tests Abort-Doctor requeue (freeze-audit wave1 atom2): on Doctor exhaustion the suspended
# backlog item must be returned to the backlog as 'held' with a doctor-exhausted reason
# (queue stays free, task never lost) instead of parking held_task in a state dead-end.
# The 60-startup restart-loop guard mirror shares this exact pattern; it is inline driver
# code (not a function), covered by parse-check + smoke.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- mocks (defined BEFORE dot-sourcing doctor.ps1; doctor.ps1 does not define these) ---
$script:mockState = $null
$script:setIdeaCalls = @()
$script:setIdeaResult = $true
$script:setIdeaThrows = $false

function Read-State { return $script:mockState }
function Update-State { param($Block) & $Block $script:mockState | Out-Null; return $script:mockState }
function Add-Message { param($From, $Text, $Kind) return $null }
function Send-PushEvent { param($Kind, $Text) return $null }
function Append-DoctorEvent { param($Event, $Reason) return $null }
function Write-DoctorLog { param($Message) return $null }
function Clear-AuditorSuppressedHashes { param($State) return $null }
function Set-Idea {
  param([string]$Id, $Status = $null, $Text = $null, $IncrementAttempts = $false, [bool]$ClearAutoCurator = $false, [string]$Reason = $null, $FailureEvidence = $null)
  if ($script:setIdeaThrows) { throw 'backlog locked' }
  $script:setIdeaCalls += ,@{ id = $Id; status = [string]$Status; reason = [string]$Reason }
  return $script:setIdeaResult
}

. (Join-Path $root 'lib\doctor.ps1')

function New-MockState {
  param([string]$Held = 'original task text', [string]$Bid = 'bid-12345678')
  return [pscustomobject]@{
    held_task          = $Held
    current_backlog_id = $Bid
    doctor_active      = $true
    doctor_attempts    = 2
    doctor_reason      = 'commit_famine'
    doctor_started_at  = '2026-06-11T00:00:00Z'
    current_task       = 'doctor task text'
    task_turn          = 3
  }
}

$fails = 0
function Assert {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fails++ }
}

Write-Host "[DA1] exhausted Doctor with backlog id -> item requeued as held, state dead-end cleared"
$script:mockState = New-MockState
$script:setIdeaCalls = @(); $script:setIdeaResult = $true; $script:setIdeaThrows = $false
Abort-Doctor -Reason 'max repair attempts'
Assert 'DA1 Set-Idea called once' ($script:setIdeaCalls.Count -eq 1)
Assert 'DA1 requeued correct id' ($script:setIdeaCalls[0].id -eq 'bid-12345678')
Assert 'DA1 status held' ($script:setIdeaCalls[0].status -eq 'held')
Assert 'DA1 reason carries doctor-exhausted' ($script:setIdeaCalls[0].reason -like 'doctor-exhausted:*')
Assert 'DA1 held_task cleared' ([string]::IsNullOrEmpty([string]$script:mockState.held_task))
Assert 'DA1 backlog id cleared' ([string]::IsNullOrEmpty([string]$script:mockState.current_backlog_id))
Assert 'DA1 doctor off' (-not [bool]$script:mockState.doctor_active)
Assert 'DA1 current_task cleared' ($null -eq $script:mockState.current_task)

Write-Host "[DA2] no backlog id -> old behavior (held_task kept for operator), doctor still off"
$script:mockState = New-MockState -Bid ''
$script:setIdeaCalls = @()
Abort-Doctor -Reason 'setup error'
Assert 'DA2 Set-Idea not called' ($script:setIdeaCalls.Count -eq 0)
Assert 'DA2 held_task kept' ($script:mockState.held_task -eq 'original task text')
Assert 'DA2 doctor off' (-not [bool]$script:mockState.doctor_active)

Write-Host "[DA3] Set-Idea throws (backlog locked) -> fallback keeps held_task, loop not wedged"
$script:mockState = New-MockState
$script:setIdeaCalls = @(); $script:setIdeaThrows = $true
Abort-Doctor -Reason 'doctor timeout'
Assert 'DA3 held_task kept on requeue failure' ($script:mockState.held_task -eq 'original task text')
Assert 'DA3 doctor off (loop never wedges)' (-not [bool]$script:mockState.doctor_active)

Write-Host "[DA4] Set-Idea returns false -> treated as not requeued, held_task kept"
$script:mockState = New-MockState
$script:setIdeaCalls = @(); $script:setIdeaThrows = $false; $script:setIdeaResult = $false
Abort-Doctor -Reason 'attempts exhausted'
Assert 'DA4 held_task kept' ($script:mockState.held_task -eq 'original task text')
Assert 'DA4 doctor off' (-not [bool]$script:mockState.doctor_active)

Write-Host ''
if ($fails -eq 0) { Write-Host 'DOCTOR-ABORT-REQUEUE: PASS'; exit 0 }
else { Write-Host "DOCTOR-ABORT-REQUEUE: FAIL ($fails assertion(s))"; exit 1 }
