#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$script:Messages = New-Object 'System.Collections.Generic.List[object]'
$script:State = $null
$script:MockHasActions = $false

function Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    $script:Passed++
    Write-Output ("PASS {0}" -f $Name)
  } else {
    $script:Failed++
    if ([string]::IsNullOrWhiteSpace($Detail)) { $Detail = 'failed' }
    Write-Output ("FAIL {0}: {1}" -f $Name, $Detail)
  }
}

function New-TestState {
  param([string]$BacklogId = 'task-a', [string]$TaskId = 'task-a')
  [pscustomobject]@{
    current_backlog_id = $BacklogId
    current_task_id = $TaskId
    current_task = 'relocation regression task'
    task_base_commit = ''
    base_dirty_paths = @()
    task_did_actions = $false
    force_coder = $false
    force_planner = $false
    verify_retry_count = 0
    coder_bypass_retry_count = 0
    coder_fired = $true
    no_progress_count = 0
    timeout_retry_count = 0
    critic_retry_count = 0
    codex_evidence_retry_count = 0
    task_mode = 'normal'
    task_turn = 0
    turn = 0
    discuss_turn = 0
    discuss_snapshot = ''
    study_phase = ''
    study_subtype = ''
    study_snapshot = ''
    research_count = 0
    chunk_progress = ''
    chunk_base_commit = ''
    completion_coder_empty_attempts = 0
    completion_coder_result = ''
    workpack_batch_active = $false
    workpack_batch_dispatched = $false
    workpack_batch_mode = ''
    done_gate_pass_sha = ''
    done_gate_pass_task = ''
    claimed_at = ''
    active_agent = $null
    active_model = $null
    status_text = $null
    agent_pid = $null
    status = 'running'
    heartbeat = (Get-Date).ToString('o')
  }
}

function Reset-Harness {
  param([string]$BacklogId = 'task-a', [string]$TaskId = 'task-a')
  $script:State = New-TestState -BacklogId $BacklogId -TaskId $TaskId
  $script:Messages.Clear()
}

function Read-State { return $script:State }
function Update-State {
  param([scriptblock]$Mutator)
  if ($null -ne $Mutator) { & $Mutator $script:State }
  return $script:State
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = '')
  [void]$script:Messages.Add([pscustomobject]@{ from=$From; text=$Text; kind=$Kind })
  return $true
}

function Set-CommonLoopVars {
  $script:bridgeRoot = $root
  $script:BridgeRoot = $root
  $script:Channel = 'main'
  $script:speaker = 'codex'
  $script:mode = 'normal'
  $script:modeBeforeIncrement = 'normal'
  $script:task = 'relocation regression task'
  $script:reply = "STATUS: DONE"
  $script:fastLaneActiveForTurn = $true
  $script:fastLaneDone = $false
  $script:plannerStatus = 'CONTINUE'
  $script:attachmentMetas = @()
  $script:fileMarkerPaths = @()
  $script:evidenceSources = @()
  $script:projectBacklogCreated = 0
  $script:studyMaxTurns = 4
  $script:researchMaxTurns = 2
  $script:discussMinTurns = 2
  $script:discussMaxTurns = 6
}

function Get-TaskRepoRoot { return $root }
function Get-ChunkingSettings { return [pscustomobject]@{ enabled=$false; maxChunksPerTask=10 } }
function Test-CoderClaims { return [pscustomobject]@{ violations=@(); checks=@() } }
function Test-PlannerDecomposed { return [pscustomobject]@{ IsDecomposed=$false } }
function Invoke-DriverDecomposedMarker {}
function Test-CanParallelize { return @() }
function Add-SessionDecisionEvent {}
function Set-TaskLastFailure {}
function Clear-TaskLastFailureKind {}
function Test-CoveredAfterRestart { return [pscustomobject]@{ Covered=$false; Sha='' } }
function Write-BridgeLog {}
function Get-EffectiveChannel { return 'main' }
function Get-ActiveProjectBinding { return [pscustomobject]@{ slug='main' } }
function Add-Idea { return 'idea-test' }
function Send-PushEvent {}
function Get-PushSnippet { param([string]$Text) return $Text }
function Clear-AuditorSuppressedHashes {}
function Clear-FastLaneFlags {}
function Clear-ChunkingState {}
function Complete-TaskAgentDuration {}
function Close-ReplayForStateTask {}

. (Join-Path $root 'lib\task-action-evidence.ps1')
. (Join-Path $root 'driver\86-loop-completion-checks.ps1')

function Get-TaskActionEvidenceContext {
  param([object]$State, [string]$DefaultRepoRoot, [string]$BridgeRoot)
  return [pscustomobject]@{ repo_root=$DefaultRepoRoot; base_commit=''; base_dirty_paths=@() }
}
function Get-TaskActionEvidence {
  param(
    [string]$RepoRoot,
    [string]$BaseCommit,
    [string]$BridgeRoot,
    [object[]]$BaseDirtyPaths = @()
  )
  return [pscustomobject]@{ has_actions=$script:MockHasActions; head_changed=$script:MockHasActions; committed_worthy=@(); dirty_worthy=@(); dirty_all=@(); head='' }
}

function Invoke-InitialBlock {
  $ok = $true
  $err = ''
  $status = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopCompletionInitialChecksBlock
      break
    }
    $status = [string]$plannerStatus
  } catch {
    $ok = $false
    $err = $_.Exception.Message
  }
  return [pscustomobject]@{ ok=$ok; error=$err; status=$status }
}

$file85 = Get-Content -LiteralPath (Join-Path $root 'driver\85-loop-mode-transitions.ps1') -Raw
$file86 = Get-Content -LiteralPath (Join-Path $root 'driver\86-loop-completion-checks.ps1') -Raw

Check '85 keeps PARALLEL handler' ($file85 -match '\[\[PARALLEL:')
Check '85 keeps stagnation detector' ($file85 -match 'Stagnation detector')
Check '85 no longer calls action-evidence helper' ($file85 -notmatch 'Get-TaskActionEvidence')
Check '85 no longer mutates task_did_actions' ($file85 -notmatch 'task_did_actions')

$statusAnchor = $file86.IndexOf('$statusHits = [regex]::Matches')
$guardAnchor = $file86.IndexOf('$noopHasBacklogId = $true')
$doneGateAnchor = $file86.IndexOf('$didActions = [bool](Read-State).task_did_actions')
Check '86 guard is after planner status parse' ($statusAnchor -ge 0 -and $guardAnchor -gt $statusAnchor) "status=$statusAnchor guard=$guardAnchor"
Check '86 guard is before DONE verify gate' ($doneGateAnchor -ge 0 -and $guardAnchor -gt 0 -and $guardAnchor -lt $doneGateAnchor) "guard=$guardAnchor doneGate=$doneGateAnchor"

Reset-Harness -BacklogId 'task-a' -TaskId 'task-a'
Set-CommonLoopVars
$script:MockHasActions = $false
$r1 = Invoke-InitialBlock
$reject1 = @($script:Messages | Where-Object { [string]$_.text -match 'DONE отклон' }).Count -gt 0
Check 'missing evidence rejects without StrictMode throw' ($r1.ok -and $r1.status -eq 'CONTINUE' -and $reject1) $r1.error
Check 'matching active backlog sets force_coder' ([bool]$script:State.force_coder)

Reset-Harness -BacklogId 'task-a' -TaskId 'other-task'
Set-CommonLoopVars
$script:MockHasActions = $false
$r2 = Invoke-InitialBlock
Check 'mismatched task identity does not set force_coder' ($r2.ok -and -not [bool]$script:State.force_coder) $r2.error

Reset-Harness -BacklogId 'task-a' -TaskId 'task-a'
Set-CommonLoopVars
$script:State.force_coder = $true
$script:MockHasActions = $true
$script:reply = "[[VERIFIED: action-evidence accepted | result=mock]]`nSTATUS: DONE"
$r3 = Invoke-InitialBlock
$reject3 = @($script:Messages | Where-Object { [string]$_.text -match 'DONE отклон' }).Count -gt 0
$r3Detail = ("ok={0}; err={1}; plannerStatus={2}; force_coder={3}; reject={4}" -f $r3.ok,$r3.error,$r3.status,[bool]$script:State.force_coder,$reject3)
Check 'accepted DONE clears stale force_coder without rejection' ($r3.ok -and $r3.status -eq 'DONE' -and -not [bool]$script:State.force_coder -and -not $reject3) $r3Detail

Write-Output ("RESULT passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
