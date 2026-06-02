param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-project-autopilot-stop-test-' + [guid]::NewGuid().ToString('N'))
$script:TestChannel = 'project-alpha'
$script:Messages = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:TestChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:TestChannel }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Get-ChannelProjectBinding {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:TestChannel }
  return [pscustomobject]@{
    ok = $true
    slug = $Slug
    project_root = (Join-Path $script:TestBridgeRoot 'project')
  }
}
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    projectAutopilotEnabled = $true
    projectAutopilotCooldownMinutes = 1
    projectAutopilotMaxTasksPerBatch = 4
    projectAutopilotEmptyCoordinatorLimit = 2
  }
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = 'message')
  [void]$script:Messages.Add($Text)
  return [pscustomobject]@{ ok = $true }
}

try {
  $channelDir = Get-ChannelDir -Slug $script:TestChannel
  New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $script:TestBridgeRoot 'project') -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:TestChannel), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $cfg = Get-ProjectAutopilotConfig
  Assert-True ([int]$cfg.emptyCoordinatorLimit -eq 2) 'expected emptyCoordinatorLimit from autonomy settings'
  $prefixedCoordinatorText = "[autonomous backlog task] " + (New-ProjectAutopilotCoordinatorTaskText -Slug $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -MaxTasks 4)
  Assert-True (Test-ProjectAutopilotCoordinatorText -Text $prefixedCoordinatorText) 'coordinator detector should allow driver task prefixes'

  $r1 = Record-ProjectAutopilotCoordinatorOutcome -Channel $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -CoordinatorId 'coord-1' -Created 0
  Assert-True ([bool]$r1.recorded) 'first empty outcome should be recorded'
  Assert-True (-not [bool]$r1.paused) 'first empty outcome should not pause when limit=2'
  Assert-True ([int]$r1.empty_coordinator_streak -eq 1) 'first empty outcome should set streak=1'

  $r2 = Record-ProjectAutopilotCoordinatorOutcome -Channel $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -CoordinatorId 'coord-2' -Created 0
  Assert-True ([bool]$r2.paused) 'second empty outcome should pause'
  Assert-True ([int]$r2.empty_coordinator_streak -eq 2) 'second empty outcome should set streak=2'

  $start = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
  Assert-True (-not [bool]$start.queued) 'paused autopilot must not queue a coordinator'
  Assert-True ([string]$start.reason -eq 'paused-empty-scope') ("expected paused-empty-scope, got " + [string]$start.reason)
  Assert-True ($script:Messages.Count -ge 1) 'pause should be visible in chat messages'

  $dup = Record-ProjectAutopilotCoordinatorOutcome -Channel $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -CoordinatorId 'coord-2' -Created 0
  Assert-True (-not [bool]$dup.recorded) 'duplicate coordinator outcome should be idempotent'

  $r3 = Record-ProjectAutopilotCoordinatorOutcome -Channel $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -CoordinatorId 'coord-3' -Created 3
  Assert-True (-not [bool]$r3.paused) 'created atoms should resume autopilot'
  Assert-True ([int]$r3.empty_coordinator_streak -eq 0) 'created atoms should reset empty streak'

  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:TestChannel), '', (New-Object System.Text.UTF8Encoding($false)))
  $coordinatorText = New-ProjectAutopilotCoordinatorTaskText -Slug $script:TestChannel -ProjectRoot (Join-Path $script:TestBridgeRoot 'project') -MaxTasks 4
  Add-Idea -Text $coordinatorText -From 'project-autopilot' -Tags @('project-autopilot','auto-generated') -Status 'done' -Severity 'critical' -Project $script:TestChannel -Scope 'project' -SkipCurator | Out-Null
  Add-Idea -Text $coordinatorText -From 'project-autopilot' -Tags @('project-autopilot','auto-generated') -Status 'done' -Severity 'critical' -Project $script:TestChannel -Scope 'project' -SkipCurator | Out-Null
  Write-ProjectAutopilotState ([pscustomobject]@{
    ts = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
    channel = $script:TestChannel
    project_root = (Join-Path $script:TestBridgeRoot 'project')
    queued_id = 'legacy-coord'
    reason = 'idle-empty-backlog'
    empty_coordinator_streak = 0
    paused = $false
    paused_at = ''
    pause_reason = ''
    recent_outcomes = @()
  })
  $legacyStart = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
  Assert-True (-not [bool]$legacyStart.queued) 'legacy empty coordinator streak must not queue a coordinator'
  Assert-True ([string]$legacyStart.reason -eq 'paused-empty-scope') ("expected legacy paused-empty-scope, got " + [string]$legacyStart.reason)

  Write-Output 'PROJECT AUTOPILOT STOP TEST OK'
} finally {
  try { Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
