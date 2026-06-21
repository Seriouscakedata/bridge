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

  $genericProfileContract = Copy-OrderedMap -Map $contract
  $genericProfileContract['profile'] = 'consumer-facing-fixture'
  [System.IO.File]::WriteAllText($contractPath, (($genericProfileContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $genericProfileGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True ([bool]$genericProfileGate.ready) 'generic top-level profile must not opt old contracts into bridge spec layer'
  Assert-True ([string]$genericProfileGate.spec_profile -eq 'legacy') 'generic top-level profile must keep legacy spec profile'

  [System.IO.File]::WriteAllText($contractPath, (($contract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $specDir = Join-Path (Join-Path $projectRoot '.bridge') 'specs'
  New-Item -ItemType Directory -Path $specDir -Force | Out-Null
  $constitutionText = ((1..45 | ForEach-Object { "Constitution line $($_): preserve scope, acceptance evidence, parallel execution boundaries, rollback paths, and operator approval gates for this project." }) -join "`n")
  $acceptanceSpecText = ((1..45 | ForEach-Object { "Acceptance spec line $($_): every deliverable traces to contract requirements, checks, risk controls, and observable verification evidence." }) -join "`n")
  $productSpecText = ((1..45 | ForEach-Object { "Product spec line $($_): requirements, surfaces, workflows, non-goals, and release boundaries are explicit before implementation atoms." }) -join "`n")
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $projectRoot '.bridge') 'constitution.md'), $constitutionText, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $specDir 'acceptance.md'), $acceptanceSpecText, (New-Object System.Text.UTF8Encoding($false)))

  $liteContract = Copy-OrderedMap -Map $contract
  $liteContract['spec_profile'] = 'lite'
  $liteContract.Remove('planning_flow')
  $backendDoc = Join-Path $projectRoot 'DISCUSS_BACKEND.md'
  Remove-Item -LiteralPath $backendDoc -Force
  [System.IO.File]::WriteAllText($contractPath, (($liteContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $liteGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True ([bool]$liteGate.ready) ('lite spec profile must not require full staged DISCUSS docs; issues=' + ((@($liteGate.issues) -join ' | ')))
  Assert-True ([string]$liteGate.spec_profile -eq 'lite') 'lite gate must expose selected spec profile'
  $liteSignatureFiles = @(Get-ProjectAutopilotPlanSignatureFiles -ProjectRoot $projectRoot)
  Assert-True ($liteSignatureFiles -contains '.bridge\constitution.md') 'lite signature must include constitution'
  Assert-True ($liteSignatureFiles -contains '.bridge\specs\acceptance.md') 'lite signature must include acceptance spec'
  Assert-True (-not ($liteSignatureFiles -contains 'DISCUSS_BACKEND.md')) 'lite signature must not require backend DISCUSS doc'

  [System.IO.File]::WriteAllText($backendDoc, ((1..45 | ForEach-Object { "Backend discussion line $($_): this fixture records durable decisions, previous-stage inputs, risks, open questions, and acceptance traceability for the staged planning flow." }) -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $standardContract = Copy-OrderedMap -Map $contract
  $standardContract['spec_profile'] = 'standard'
  [System.IO.File]::WriteAllText($contractPath, (($standardContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $standardMissingSpecGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True (-not [bool]$standardMissingSpecGate.ready) 'standard spec profile must require product spec'
  Assert-True ((@($standardMissingSpecGate.issues) | Where-Object { $_ -match 'product\.md' }).Count -gt 0) ('standard missing product spec must be reported; issues=' + ((@($standardMissingSpecGate.issues) -join ' | ')))
  [System.IO.File]::WriteAllText((Join-Path $specDir 'product.md'), $productSpecText, (New-Object System.Text.UTF8Encoding($false)))
  $standardReadyGate = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
  Assert-True ([bool]$standardReadyGate.ready) ('standard spec profile should pass after required specs exist; issues=' + ((@($standardReadyGate.issues) -join ' | ')))

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

  # ============================================================
  # TEST A: PROJECT-channel Test-IsLargeTask uses text-length path, NOT scope-profile
  # Verifies AcceptanceCount/SubsystemCount/EstimatedTurns are ignored for non-main channels.
  # ============================================================
  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\prompt-builder.ps1')
  $testAText = 'Short bridge task for the myproject channel. No length trigger, no keyword.'
  $resultA_highCount = Test-IsLargeTask -TaskText $testAText -Channel 'myproject' -Scope 'feature' -AcceptanceCount 99 -SubsystemCount 10 -EstimatedTurns 20
  $resultA_zeroCount = Test-IsLargeTask -TaskText $testAText -Channel 'myproject' -Scope 'feature' -AcceptanceCount 0 -SubsystemCount 0 -EstimatedTurns 0
  Assert-True ([bool]$resultA_highCount -eq [bool]$resultA_zeroCount) 'TEST A: scope counters (AcceptanceCount/SubsystemCount/EstimatedTurns) must not change result for non-main channel'
  Assert-True (-not [bool]$resultA_zeroCount) 'TEST A: short non-regex text must return false for non-main channel (text-length path only)'
  Write-Host 'TEST A PASS: PROJECT-channel Test-IsLargeTask uses old text-length path (scope counters ignored)'

  # ============================================================
  # TEST B: crusher-04 gate (Invoke-BridgeSelfDecomposeGate) is noop for non-main channel
  # Verifies gate predicate at line 190 of 86-loop-completion-actions.ps1 short-circuits for channel != main.
  # ============================================================
  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'driver\86-loop-completion-actions.ps1')
  $script:GateNonMainStateCalls = 0
  $script:GateNonMainIdeaWrites = 0
  & {
    function Read-State {
      $script:GateNonMainStateCalls++
      return [pscustomobject]@{
        bridge_self_decompose_retry_count = 3
        bridge_self_decompose_retry_parent_id = 'noninterference-regression-id'
      }
    }
    function Update-State {
      param([scriptblock]$Mutator)
      $script:GateNonMainStateCalls++
      throw 'TEST B: non-main gate must not call Update-State'
    }
    function Set-Idea {
      param([string]$Id, [string]$Status, [string]$Reason)
      $script:GateNonMainIdeaWrites++
      throw 'TEST B: non-main gate must not call Set-Idea'
    }
    function Set-IdeaHoldReason {
      param([string]$Id, [string]$Reason)
      $script:GateNonMainIdeaWrites++
      throw 'TEST B: non-main gate must not call Set-IdeaHoldReason'
    }
    function Get-IdeaById {
      param([string]$Id)
      $script:GateNonMainStateCalls++
      throw 'TEST B: non-main gate must not read idea/state'
    }
    $resultB = Invoke-BridgeSelfDecomposeGate -Id 'noninterference-regression-id' -Channel 'myproject' -Scope 'bridge' -Tags @()
    Assert-True ([string]$resultB.action -eq 'noop') ('TEST B: gate action must be noop for non-main channel; got: ' + [string]$resultB.action)
    Assert-True (-not [bool]$resultB.suppressContinue) 'TEST B: gate must not suppress continue for non-main channel'
    Assert-True ([int]$script:GateNonMainStateCalls -eq 0) ('TEST B: non-main gate must not read/write state; calls=' + [string]$script:GateNonMainStateCalls)
    Assert-True ([int]$script:GateNonMainIdeaWrites -eq 0) ('TEST B: non-main gate must not hold/retry/update idea; writes=' + [string]$script:GateNonMainIdeaWrites)
  }
  foreach ($gateMockName in @('Read-State','Update-State','Set-Idea','Set-IdeaHoldReason','Get-IdeaById')) {
    $gateMockCommand = Get-Command $gateMockName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $gateMockCommand) {
      Assert-True ($gateMockCommand.ScriptBlock.ToString() -notmatch 'TEST B: non-main gate must not') ('TEST B: mock function leaked after local gate check: ' + $gateMockName)
    }
  }
  Write-Host 'TEST B PASS: Invoke-BridgeSelfDecomposeGate is noop (pass-through) for non-main channel; no state write, no hold/retry'

  # ============================================================
  # TEST C: Start-ProjectAutopilotIfNeeded for non-main channel without approved PROJECT_PLAN returns false
  # Verifies existing behavior is not changed by decomposer additions.
  # ============================================================
  $savedTestChannel = $script:TestChannel
  $script:TestChannel = 'myproject-noninterference'
  $testCChannelDir = Get-ChannelDir -Slug $script:TestChannel
  New-Item -ItemType Directory -Path $testCChannelDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:TestChannel), '', (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $testCChannelDir 'channel.json'), (@{
    slug = $script:TestChannel
    project_root = (Join-Path $script:TestBridgeRoot 'project')
  } | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  $resultC = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
  $script:TestChannel = $savedTestChannel
  Assert-True (-not [bool]$resultC.queued) 'TEST C: non-main channel without approved plan must not queue coordinator'
  Assert-True ([string]$resultC.reason -eq 'plan-not-approved') ('TEST C: expected plan-not-approved; got: ' + [string]$resultC.reason)
  Write-Host 'TEST C PASS: Start-ProjectAutopilotIfNeeded for non-main channel without plan returns false (behavior unchanged)'

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
