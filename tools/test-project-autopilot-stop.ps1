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
  $projectRoot = Join-Path $script:TestBridgeRoot 'project'
  New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $projectRoot '.bridge') -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:TestChannel), '', (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $channelDir 'channel.json'), (@{
    slug = $script:TestChannel
    project_root = $projectRoot
  } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

  $mapText = ((1..80 | ForEach-Object { "Project map line $($_): routes, workflows, interfaces, storage, risks, and acceptance traceability are documented for the fixture." }) -join "`n")
  $planText = ((1..100 | ForEach-Object { "Project plan line $($_): chapter, dependency, done criteria, verification, and UX contract traceability are documented for the fixture." }) -join "`n")
  [System.IO.File]::WriteAllText((Join-Path $projectRoot 'PROJECT_MAP.md'), $mapText, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $projectRoot 'PROJECT_PLAN.md'), $planText, (New-Object System.Text.UTF8Encoding($false)))
  $stageDefs = @(
    @{ id='brief'; path='PROJECT_BRIEF.md'; title='Project brief'; deps=@() },
    @{ id='product'; path='DISCUSS_PRODUCT.md'; title='Product discussion'; deps=@('brief') },
    @{ id='ux'; path='DISCUSS_UX.md'; title='UX discussion'; deps=@('brief','product') },
    @{ id='ui'; path='DISCUSS_UI.md'; title='UI discussion'; deps=@('brief','product','ux') },
    @{ id='backend'; path='DISCUSS_BACKEND.md'; title='Backend discussion'; deps=@('brief','product','ux') },
    @{ id='qa'; path='DISCUSS_QA.md'; title='QA discussion'; deps=@('brief','product','ux','ui','backend') },
    @{ id='integration'; path='DISCUSS_INTEGRATION.md'; title='Integration discussion'; deps=@('brief','product','ux','ui','backend','qa') }
  )
  foreach ($sd in $stageDefs) {
    $stageText = ((1..45 | ForEach-Object { "$($sd.title) line $($_): this fixture records durable decisions, previous-stage inputs, risks, open questions, and acceptance traceability for the staged planning flow." }) -join "`n")
    [System.IO.File]::WriteAllText((Join-Path $projectRoot ([string]$sd.path)), $stageText, (New-Object System.Text.UTF8Encoding($false)))
  }
  $contract = [ordered]@{
    project_goal = 'Build a test project with enough durable planning detail for autopilot contract approval and acceptance traceability.'
    planning_flow = [ordered]@{
      stages = @($stageDefs | ForEach-Object {
        [ordered]@{
          id = [string]$_.id
          status = 'complete'
          doc = [string]$_.path
          depends_on = @($_.deps)
          summary = ('Completed staged planning fixture for ' + [string]$_.id + ', using prior decisions and preserving traceability into the final contract.')
        }
      })
    }
    requirements = @('auth requirement','content requirement','admin requirement')
    screens = @(
      [ordered]@{ id='home'; path='/'; expected_status=200; must_contain=@('Home') },
      [ordered]@{ id='settings'; path='/settings'; expected_status=200; must_contain=@('Settings') }
    )
    user_journeys = @(
      [ordered]@{ id='register'; steps=@('open app','register','see dashboard') },
      [ordered]@{ id='admin-review'; steps=@('open admin','review content','remove item') }
    )
    ux_contract = [ordered]@{ navigation='Every primary user role has a clear first action and persistent navigation.' }
    acceptance_scenarios = @('build passes','auth journey passes','admin journey passes')
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $projectRoot '.bridge') 'project-contract.json'), (($contract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

  & git -C $projectRoot init | Out-Null
  & git -C $projectRoot config user.email 'bridge-test@example.invalid' | Out-Null
  & git -C $projectRoot config user.name 'Bridge Test' | Out-Null
  & git -C $projectRoot add . | Out-Null
  & git -C $projectRoot commit -m 'fixture planning docs' | Out-Null

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $cfg = Get-ProjectAutopilotConfig
  Assert-True ([int]$cfg.emptyCoordinatorLimit -eq 2) 'expected emptyCoordinatorLimit from autonomy settings'
  $gateStart = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
  Assert-True (-not [bool]$gateStart.queued) 'unapproved plan must not queue a coordinator'
  Assert-True ([string]$gateStart.reason -eq 'plan-not-approved') ("expected plan-not-approved, got " + [string]$gateStart.reason)
  Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null
  Assert-True (Test-ProjectPlanApproved -Channel $script:TestChannel -ProjectRoot $projectRoot) 'approved plan must pass exact signature gate'
  $approvedStatePath = Join-Path $channelDir 'channel.json'
  $approvedState = [System.IO.File]::ReadAllText($approvedStatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$approvedState.plan_approved_git_head)) 'approval should record project git head'
  $approvedState.plan_approved_signature = 'stale-signature-for-test'
  [System.IO.File]::WriteAllText($approvedStatePath, (($approvedState | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Assert-True (Test-ProjectPlanApproved -Channel $script:TestChannel -ProjectRoot $projectRoot) 'stale signature should pass when approved planning files are unchanged at git head'
  [System.IO.File]::AppendAllText((Join-Path $projectRoot 'PROJECT_PLAN.md'), "`nUnapproved planning drift for gate test.`n", (New-Object System.Text.UTF8Encoding($false)))
  Assert-True (-not (Test-ProjectPlanApproved -Channel $script:TestChannel -ProjectRoot $projectRoot)) 'planning file drift after approved git head must fail the gate'
  [System.IO.File]::WriteAllText((Join-Path $projectRoot 'PROJECT_PLAN.md'), $planText, (New-Object System.Text.UTF8Encoding($false)))
  Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null
  Assert-True (Test-ProjectPlanApproved -Channel $script:TestChannel -ProjectRoot $projectRoot) 'restored planning docs should pass after re-approval'
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
