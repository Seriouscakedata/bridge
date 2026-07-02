# StrictMode regression coverage for driver loop blocks 83/85/86.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:BridgeRoot = Split-Path -Parent $PSScriptRoot
$script:Passed = 0
$script:Failed = 0
$script:State = $null
$script:Messages = New-Object 'System.Collections.Generic.List[object]'
$script:Updates = New-Object 'System.Collections.Generic.List[object]'

function Write-TestResult {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) {
    $script:Passed++
    Write-Output ("PASS {0}" -f $Name)
  } else {
    $script:Failed++
    if ([string]::IsNullOrWhiteSpace($Detail)) { $Detail = 'failed' }
    Write-Output ("FAIL {0}: {1}" -f $Name, $Detail)
  }
}

function Assert-True {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  Write-TestResult -Name $Name -Ok:$Condition -Detail $Detail
}

function New-TestState {
  param([string]$BacklogId = '')
  return [pscustomobject]@{
    abort                            = $false
    current_backlog_id               = $BacklogId
    current_task_id                  = $BacklogId
    current_task                     = 'strictmode regression task'
    task_base_commit                 = ''
    base_dirty_paths                 = @()
    task_did_actions                 = $false
    coder_fired                      = $false
    timeout_retry_count              = 0
    doctor_active                    = $false
    no_progress_count                = 0
    verify_retry_count               = 0
    coder_bypass_retry_count         = 0
    critic_retry_count               = 0
    codex_evidence_retry_count       = 0
    force_planner                    = $false
    force_coder                      = $false
    task_mode                        = 'normal'
    task_turn                        = 0
    turn                             = 0
    discuss_turn                     = 0
    discuss_snapshot                 = ''
    study_phase                      = ''
    study_subtype                    = ''
    study_snapshot                   = ''
    research_count                   = 0
    chunk_progress                   = ''
    chunk_base_commit                = ''
    done_gate_pass_sha               = ''
    done_gate_pass_task              = ''
    completion_coder_empty_attempts  = 0
    completion_coder_result          = ''
    workpack_batch_active            = $false
    workpack_batch_dispatched        = $false
    workpack_batch_mode              = ''
    claimed_at                       = ''
    active_agent                     = $null
    active_model                     = $null
    status_text                      = $null
    agent_pid                        = $null
    status                           = 'running'
    heartbeat                        = (Get-Date).ToString('o')
  }
}

function Reset-Harness {
  param([string]$BacklogId = '')
  $script:State = New-TestState -BacklogId $BacklogId
  $script:Messages.Clear()
  $script:Updates.Clear()
}

function Read-State { return $script:State }
function Update-State {
  param([scriptblock]$Mutator)
  if ($null -ne $Mutator) { & $Mutator $script:State }
  [void]$script:Updates.Add([pscustomobject]@{
    state = ($script:State | ConvertTo-Json -Depth 8 -Compress)
  })
  return $script:State
}

function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = '')
  [void]$script:Messages.Add([pscustomobject]@{ from=$From; text=$Text; kind=$Kind })
  return $true
}

function Write-TurnLog {}
function Normalize-ChannelSlug { param([string]$Slug) return $Slug }
function Set-BridgeStatusText {}
function Get-AgentPhaseStatusText { return 'test' }
function Get-EffectiveProjectRoot { return $script:BridgeRoot }
function Get-TaskRepoRoot { return $script:BridgeRoot }
function Set-TaskLastFailure {}
function Clear-TaskLastFailureKind {}
function Add-SessionDecisionEvent {}
function Send-PushEvent {}
function Get-PushSnippet { param([string]$Text) return $Text }
function Invoke-PostMortem {}
function Activate-Doctor {}
function Abort-Doctor {}
function Complete-TaskAgentDuration {}
function Close-ReplayForStateTask {}
function Clear-AuditorSuppressedHashes {}
function Clear-FastLaneFlags {}
function Clear-ChunkingState {}
function Invoke-AutoPush {}
function Invoke-GitAddPaths { return [pscustomobject]@{ ExitCode=0; Output=@() } }
function Invoke-GitCommitMessage { return [pscustomobject]@{ ExitCode=0; Output=@() } }
function Invoke-GitNative { return [pscustomobject]@{ ExitCode=0; Output=@() } }
function Invoke-QAAgentPostCommit { return [pscustomobject]@{ Verdict='PASS'; Summary='test' } }
function Get-ChunkingSettings { return [pscustomobject]@{ enabled=$false; maxChunksPerTask=10 } }
function Test-CoderClaims { return [pscustomobject]@{ violations=@(); checks=@() } }
function Test-PlannerDecomposed { return [pscustomobject]@{ IsDecomposed=$false } }
function Invoke-DriverDecomposedMarker {}
function Test-CanParallelize { return @() }
function Test-CoveredAfterRestart { return [pscustomobject]@{ Covered=$false; Sha='' } }
function Save-Decision {}
function Get-ActiveProjectBinding { return [pscustomobject]@{ channel='main' } }
function Add-BacklogIdea { return $null }
function Get-Backlog { return @() }
function Test-BridgeAutoCommitWorthPath { return $true }
function Invoke-Planner { return [pscustomobject]@{ status='ok'; text='STATUS: CONTINUE' } }
function Invoke-SynthesisDriverTurn { return [pscustomobject]@{ status='ok'; text='STATUS: CONTINUE' } }

function Set-CommonLoopVars {
  $script:bridgeRoot = $script:BridgeRoot
  $script:BridgeRoot = $script:BridgeRoot
  $script:Channel = 'main'
  $script:speaker = 'claude'
  $script:mode = 'normal'
  $script:task = 'strictmode regression task'
  $script:prompt = 'prompt'
  $script:plannerModel = 'test'
  $script:activeModel = 'test'
  $script:turnStart = Get-Date
  $script:fastLaneTurn = $false
  $script:fastLaneActiveForTurn = $false
  $script:reply = 'STATUS: CONTINUE'
  $script:dirtyBeforeTurn = @()
  $script:headBeforeTurn = ''
  $script:attachmentMetas = @()
  $script:evidenceSources = @()
  $script:fileMarkerPaths = @()
  $script:projectBacklogCreated = 0
  $script:studyMaxTurns = 4
  $script:researchMaxTurns = 2
  $script:discussMinTurns = 2
  $script:discussMaxTurns = 6
}

try {
  . (Join-Path $script:BridgeRoot 'lib\task-action-evidence.ps1')
  . (Join-Path $script:BridgeRoot 'driver\83-loop-agent-turn.ps1')
  . (Join-Path $script:BridgeRoot 'driver\85-loop-mode-transitions.ps1')
  . (Join-Path $script:BridgeRoot 'driver\86-loop-completion-checks.ps1')

  Reset-Harness
  Set-CommonLoopVars
  $script:speaker = 'codex'
  $script:mode = 'normal'
  function Invoke-Coder { return [pscustomobject]@{ text='STATUS: CONTINUE' } }
  $case83Ok = $true
  $case83Err = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopAgentTurnBlock
      break
    }
  } catch {
    $case83Ok = $false
    $case83Err = $_.Exception.Message
  }
  Assert-True -Name '83 incomplete turnResult no throw' -Condition $case83Ok -Detail $case83Err
  Assert-True -Name '83 normalized preflightBlocked' -Condition ($script:turnResult.PSObject.Properties.Name -contains 'preflightBlocked' -and -not [bool]$script:turnResult.preflightBlocked) -Detail 'missing or true preflightBlocked'

  Reset-Harness
  Set-CommonLoopVars
  Remove-Variable -Name plannerStatus -Scope Script -ErrorAction SilentlyContinue
  Remove-Variable -Name fastLaneDone -Scope Script -ErrorAction SilentlyContinue
  Remove-Variable -Name modeBeforeIncrement -Scope Script -ErrorAction SilentlyContinue
  $case85Ok = $true
  $case85Err = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopModeTransitionBlock
      break
    }
  } catch {
    $case85Ok = $false
    $case85Err = $_.Exception.Message
  }
  Assert-True -Name '85 unset loop vars no throw' -Condition $case85Ok -Detail $case85Err

  function Get-TaskActionEvidenceContext {
    param([object]$State, [string]$DefaultRepoRoot, [string]$BridgeRoot)
    return [pscustomobject]@{ repo_root=$DefaultRepoRoot; base_commit=''; base_dirty_paths=@() }
  }
  function Get-TaskActionEvidence {
    return [pscustomobject]@{ has_actions=$false; head_changed=$false; committed_worthy=@(); dirty_worthy=@(); dirty_all=@(); head='' }
  }

  Reset-Harness -BacklogId 'strictmode-backlog'
  Set-CommonLoopVars
  $script:reply = "STATUS: CONTINUE"
  $script:plannerStatus = 'DONE'
  $script:fastLaneDone = $true
  $script:modeBeforeIncrement = 'normal'
  $case86ContinueOk = $true
  $case86ContinueErr = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopCompletionInitialChecksBlock
      break
    }
  } catch {
    $case86ContinueOk = $false
    $case86ContinueErr = $_.Exception.Message
  }
  $staleReject = @($script:Messages | Where-Object { [string]$_.text -match 'DONE отклон' }).Count -gt 0
  Assert-True -Name '86 stale DONE ignored for current CONTINUE' -Condition ($case86ContinueOk -and -not $staleReject -and $script:plannerStatus -eq 'CONTINUE') -Detail $case86ContinueErr

  Reset-Harness -BacklogId 'strictmode-backlog'
  Set-CommonLoopVars
  $script:reply = "STATUS: DONE"
  $script:modeBeforeIncrement = 'normal'
  $case86DoneOk = $true
  $case86DoneErr = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopCompletionInitialChecksBlock
      break
    }
  } catch {
    $case86DoneOk = $false
    $case86DoneErr = $_.Exception.Message
  }
  $currentReject = @($script:Messages | Where-Object { [string]$_.text -match 'DONE отклон' }).Count -gt 0
  Assert-True -Name '86 current DONE action-evidence guard fires' -Condition ($case86DoneOk -and $currentReject -and $script:plannerStatus -eq 'CONTINUE') -Detail $case86DoneErr

  Reset-Harness -BacklogId 'strictmode-backlog'
  Set-CommonLoopVars
  $script:speaker = 'codex'
  $script:fastLaneActiveForTurn = $true
  $script:reply = "STATUS: DONE"
  $script:modeBeforeIncrement = 'normal'
  $case86FastLaneOk = $true
  $case86FastLaneErr = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopCompletionInitialChecksBlock
      break
    }
  } catch {
    $case86FastLaneOk = $false
    $case86FastLaneErr = $_.Exception.Message
  }
  $fastLaneReject = @($script:Messages | Where-Object { [string]$_.text -match 'DONE отклон' }).Count -gt 0
  Assert-True -Name '86 fast-lane DONE action-evidence guard fires' -Condition ($case86FastLaneOk -and $fastLaneReject -and $script:plannerStatus -eq 'CONTINUE') -Detail $case86FastLaneErr

  Reset-Harness
  Set-CommonLoopVars
  $script:speaker = 'codex'
  $script:State.doctor_active = $true
  $script:State.task_did_actions = $true
  $script:reply = "STATUS: DONE [[VERIFIED: smoke.ps1 OK]]"
  $script:modeBeforeIncrement = 'normal'
  $case86DoctorCodexOk = $true
  $case86DoctorCodexErr = ''
  try {
    :mainDriverLoop while ($true) {
      . $script:DriverLoopCompletionInitialChecksBlock
      break
    }
  } catch {
    $case86DoctorCodexOk = $false
    $case86DoctorCodexErr = $_.Exception.Message
  }
  $doctorVerifyLoop = @($script:Messages | Where-Object { [string]$_.text -match 'Фаза верификации' }).Count -gt 0
  Assert-True -Name '86 doctor Codex DONE closes with inline VERIFIED' -Condition ($case86DoctorCodexOk -and -not $doctorVerifyLoop -and $script:plannerStatus -eq 'DONE' -and [bool]$script:fastLaneDone) -Detail $case86DoctorCodexErr
} catch {
  Write-TestResult -Name 'harness exception' -Ok:$false -Detail $_.Exception.Message
}

Write-Output ("RESULT passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
