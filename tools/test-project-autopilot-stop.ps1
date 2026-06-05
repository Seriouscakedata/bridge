param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-project-autopilot-stop-test-' + [guid]::NewGuid().ToString('N'))
$script:TestChannel = 'project-alpha'
$script:Messages = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Copy-OrderedMap {
  param([Parameter(Mandatory)]$Map)
  $copy = [ordered]@{}
  foreach ($entry in $Map.GetEnumerator()) {
    $copy[[string]$entry.Key] = $entry.Value
  }
  return $copy
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
    scope = 'The fixture covers authenticated user dashboards, administrative moderation, backlog readiness, and acceptance traceability for the project autopilot gate.'
    non_goals = 'The fixture does not implement product features, bypass operator approval, or infer missing scope boundaries from requirements alone.'
    personas = @(
      'Authenticated product users who manage dashboard content and expect clear acceptance coverage.',
      'Administrative reviewers who moderate content and need traceable project risk boundaries.'
    )
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
    backend = 'The fixture backend contract covers persisted auth state, content moderation records, admin review APIs, and audit-safe storage boundaries.'
    acceptance_scenarios = @('build passes','auth journey passes','admin journey passes')
    checks = @(
      'Run parser validation for touched scripts before approval.',
      'Run focused project autopilot and acceptance contract harnesses.',
      'Run smoke.ps1 before committing bridge-self contract gate changes.'
    )
    risk = 'A shallow contract can queue implementation atoms without checks, risk handling, or parallel ownership policy.'
    parallel_policy = 'Coordinator atoms must declare independent touch sets and serial_reason when work cannot run in parallel.'
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

  $contractPath = Join-Path (Join-Path $projectRoot '.bridge') 'project-contract.json'
  $missingChecksContract = Copy-OrderedMap -Map $contract
  $missingChecksContract.Remove('checks')
  [System.IO.File]::WriteAllText($contractPath, (($missingChecksContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $missingChecksGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True (-not [bool]$missingChecksGate.ready) 'missing checks must make project plan contract not ready'
  Assert-True ((@($missingChecksGate.issues) | Where-Object { $_ -match 'checks' }).Count -gt 0) ('missing checks must be reported by project plan contract gate; issues=' + ((@($missingChecksGate.issues) -join ' | ')))
  $missingChecksThrow = $false
  try { Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null } catch { $missingChecksThrow = $true }
  Assert-True $missingChecksThrow 'approval must throw when checks are missing from delivery contract'

  $missingRiskContract = Copy-OrderedMap -Map $contract
  $missingRiskContract.Remove('risk')
  [System.IO.File]::WriteAllText($contractPath, (($missingRiskContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $missingRiskGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True (-not [bool]$missingRiskGate.ready) 'missing risk must make project plan contract not ready'
  Assert-True ((@($missingRiskGate.issues) | Where-Object { $_ -match 'risk' }).Count -gt 0) ('missing risk must be reported by project plan contract gate; issues=' + ((@($missingRiskGate.issues) -join ' | ')))
  $missingRiskThrow = $false
  try { Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null } catch { $missingRiskThrow = $true }
  Assert-True $missingRiskThrow 'approval must throw when risk is missing from delivery contract'

  $missingParallelContract = Copy-OrderedMap -Map $contract
  $missingParallelContract.Remove('parallel_policy')
  [System.IO.File]::WriteAllText($contractPath, (($missingParallelContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $missingParallelGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True (-not [bool]$missingParallelGate.ready) 'missing parallel_policy must make strict project plan contract not ready'
  Assert-True (@($missingParallelGate.delivery_contract_blockers) -contains 'parallel_policy') 'strict project gate must block on missing parallel_policy'
  $stateForStrictStart = [System.IO.File]::ReadAllText((Join-Path $channelDir 'channel.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $stateForStrictStart | Add-Member -NotePropertyName plan_approved -NotePropertyValue $true -Force
  $stateForStrictStart | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue ([string](Get-ProjectAutopilotPlanSignature -ProjectRoot $projectRoot)) -Force
  [System.IO.File]::WriteAllText((Join-Path $channelDir 'channel.json'), (($stateForStrictStart | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $strictStart = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
  Assert-True (-not [bool]$strictStart.queued) 'strict missing parallel_policy must not queue coordinator'
  Assert-True ([string]$strictStart.reason -eq 'plan-contract-not-ready') ("expected plan-contract-not-ready, got " + [string]$strictStart.reason)
  Assert-True (@($strictStart.delivery_contract_blockers) -contains 'parallel_policy') 'autopilot result must expose delivery contract blockers'

  $legacyAliasOnlyContract = Copy-OrderedMap -Map $contract
  $legacyAliasOnlyContract.Remove('scope')
  $legacyAliasOnlyContract.Remove('non_goals')
  $legacyAliasOnlyContract.Remove('personas')
  [System.IO.File]::WriteAllText($contractPath, (($legacyAliasOnlyContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $legacyAliasOnlyGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True ([bool]$legacyAliasOnlyGate.ready) 'legacy aliases must remain ready unless explicit project sections are opted in'
  Assert-True (-not (@($legacyAliasOnlyGate.delivery_contract_blockers) -contains 'scope/non_goals')) 'default project gate must not block legacy scope aliases'
  Assert-True (-not (@($legacyAliasOnlyGate.delivery_contract_blockers) -contains 'users/roles')) 'default project gate must not block legacy user journey aliases'
  Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null

  $legacyAliasOnlyContract['require_explicit_project_sections'] = $true
  [System.IO.File]::WriteAllText($contractPath, (($legacyAliasOnlyContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $legacyAliasOnlyGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True (-not [bool]$legacyAliasOnlyGate.ready) 'opt-in explicit project sections must reject requirements and user_journeys as replacements'
  Assert-True (@($legacyAliasOnlyGate.delivery_contract_blockers) -contains 'scope/non_goals') 'opt-in project gate must block on missing explicit scope/non_goals'
  Assert-True (@($legacyAliasOnlyGate.delivery_contract_blockers) -contains 'users/roles') 'opt-in project gate must block on missing explicit users/roles'
  $legacyAliasOnlyThrow = $false
  try { Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null } catch { $legacyAliasOnlyThrow = $true }
  Assert-True $legacyAliasOnlyThrow 'approval must throw when explicit semantic sections are opted in but absent'

  [System.IO.File]::WriteAllText($contractPath, (($contract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  & git -C $projectRoot add . | Out-Null
  & git -C $projectRoot commit --allow-empty -m 'restore valid planning contract' | Out-Null
  Set-ProjectPlanApproved -Channel $script:TestChannel | Out-Null
  Assert-True (Test-ProjectPlanApproved -Channel $script:TestChannel -ProjectRoot $projectRoot) 'approved plan must pass exact signature gate'
  $approvedStatePath = Join-Path $channelDir 'channel.json'
  $approvedState = [System.IO.File]::ReadAllText($approvedStatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$approvedState.plan_approved_git_head)) 'approval should record project git head'
  Assert-True ([int]$approvedState.plan_contract_score -ge 80) 'approval should record delivery contract score'
  Assert-True (@($approvedState.plan_contract_required_sections).Count -gt 0) 'approval should record delivery contract required sections'
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
