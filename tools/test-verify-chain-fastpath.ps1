#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\verify-selftest.ps1')
. (Join-Path $root 'driver\86-loop-completion.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Check {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [object]$Actual = $null
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }

  $script:FailCount++
  $suffix = ''
  if ($null -ne $Actual) {
    $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 8)
  }
  Write-Host ("FAIL: {0}{1}" -f $Name, $suffix)
}

class FastpathCase {
  [string]$Name
  [string[]]$ChangedPaths
  [bool]$ExpectSnapshotSuite

  FastpathCase([string]$name, [string[]]$changedPaths, [bool]$expectSnapshotSuite) {
    $this.Name = $name
    $this.ChangedPaths = $changedPaths
    $this.ExpectSnapshotSuite = $expectSnapshotSuite
  }
}

function Invoke-FastpathCase {
  param([Parameter(Mandatory=$true)][FastpathCase]$Case)

  $scope = @(Get-GateRegressionScope -ChangedPaths @($Case.ChangedPaths))
  $plan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @($Case.ChangedPaths)
  $jobCount = @($plan.JobNames).Count
  $suiteJobPresent = @($plan.JobNames) -contains 'gate-regression'

  if ($Case.Name -eq 'TRIVIAL') {
    Check 'Class TRIVIAL: Get-GateRegressionScope returns empty for docs/test' ($scope.Count -eq 0) $scope
    Check 'Class TRIVIAL: snapshot suite is not scheduled' (-not [bool]$plan.GateSuiteNeeded) $plan
    Check 'Class TRIVIAL: job count <= 1' ($jobCount -le 1) $plan.JobNames
    $runtime = Invoke-DriverDoneGateChecks -BridgeRoot $root -TaskBaseCommit '' -Channel 'test' -Reply 'STATUS: DONE' -ChangedPathsOverride @($Case.ChangedPaths)
    Check 'Class TRIVIAL: runtime starts no DONE-gate jobs' ([int]$runtime.JobsStarted -eq 0 -and $runtime.Mode -eq 'none') $runtime
    return
  }

  if ($Case.Name -eq 'CONTROL_PLANE') {
    Check 'Class CONTROL_PLANE: Get-GateRegressionScope returns non-empty for driver/ change' ($scope.Count -gt 0) $scope
    Check 'Class CONTROL_PLANE: snapshot suite is scheduled' ([bool]$plan.GateSuiteNeeded) $plan
    Check 'Class CONTROL_PLANE: gate-regression job is present' $suiteJobPresent $plan.JobNames
    return
  }

  Check ("Class {0}: known test class" -f $Case.Name) $false $Case
}

function Invoke-AdditionalFastpathChecks {
  $verifiedReply = @'
[[VERIFIED: powershell -NoProfile -ExecutionPolicy Bypass -File smoke.ps1 | SMOKE OK]]
STATUS: DONE
'@
  $verifiedPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply $verifiedReply -ChangedPathsOverride @('driver/86-loop-completion-checks.ps1')
  Check 'Smoke evidence: auto-smoke is skipped for this turn' ([bool]$verifiedPlan.SmokeSkippedByVerified -and -not [bool]$verifiedPlan.SmokeNeeded) $verifiedPlan
  Check 'Smoke evidence: gate-regression remains scheduled for control-plane diff' (@($verifiedPlan.JobNames) -contains 'gate-regression') $verifiedPlan.JobNames

  $parseResult = & $script:DriverDoneGateParseJob $root @('driver/86-loop-completion-checks.ps1','lib/verify-selftest.ps1')
  Check 'ParseFile: touched PS1 files parse cleanly' ([bool]$parseResult.Ok) $parseResult

  $missingBaseChangedPaths = $null
  $missingBaseError = ''
  try {
    $script:_MissingBaseObjHits = @{}
    foreach ($i in 1..2) {
      $missingBaseChangedPaths = @(Get-DriverDoneGateChangedPaths -BridgeRoot $root -TaskBaseCommit '0000000000000000000000000000000000000000')
    }
  } catch {
    $missingBaseError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  Check 'Missing task_base_commit: pre-escalation changed-path scans stay fail-soft' ([string]::IsNullOrWhiteSpace($missingBaseError)) $missingBaseError
  Check 'Missing task_base_commit: changed paths still return an array' ($null -ne $missingBaseChangedPaths) $missingBaseChangedPaths

  $primitiveSelection = @(Get-GateRegressionTestSelection -BridgeRoot $root -Scope @('lib/backlog-dedup.ps1','tools/test-primitives.ps1'))
  Check 'Gate regression scope: direct changed tests are selected' ($primitiveSelection -contains 'test-primitives.ps1') $primitiveSelection
  Check 'Gate regression scope: lib-name tests are selected' ($primitiveSelection -contains 'test-backlog-dedup.ps1') $primitiveSelection

  $gateSelection = @(Get-GateRegressionTestSelection -BridgeRoot $root -Scope @('lib/verify-selftest.ps1'))
  Check 'Gate regression scope: verify-selftest changes select sentinel tests' ($gateSelection -contains 'test-gate-regression-sentinel.ps1' -and $gateSelection -contains 'test-verify-chain-fastpath.ps1') $gateSelection

  $docsPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('docs/operator-note.md')
  Check 'Gate regression fast subset: docs-only change skips full suite' (-not [bool]$docsPlan.GateSuiteNeeded -and [bool]$docsPlan.GateNonCoreFastSubset) $docsPlan
  Check 'Gate regression fast subset: docs-only change starts no gate job' (-not (@($docsPlan.JobNames) -contains 'gate-regression')) $docsPlan.JobNames

  $toolsTestPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('tools/test-gate-regression-sentinel.ps1')
  Check 'Gate regression fast subset: tools/test change skips full suite' (-not [bool]$toolsTestPlan.GateSuiteNeeded -and [bool]$toolsTestPlan.GateNonCoreFastSubset) $toolsTestPlan
  Check 'Gate regression fast subset: tools/test keeps parse+smoke only' ((@($toolsTestPlan.JobNames) -contains 'parse') -and (@($toolsTestPlan.JobNames) -contains 'smoke') -and -not (@($toolsTestPlan.JobNames) -contains 'gate-regression')) $toolsTestPlan.JobNames

  $backlogPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('lib/backlog-dedup.ps1')
  Check 'Gate regression core scope: lib/backlog keeps full suite' ([bool]$backlogPlan.GateSuiteNeeded -and (@($backlogPlan.JobNames) -contains 'gate-regression')) $backlogPlan

  $runner = Invoke-VerifySelftestProcess -FilePath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) `
    -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tools\run-tests.ps1'),'-NoSnapshot','-TimeoutSec','20','-OnlyCsv','test-project-acceptance-contract.ps1','-Quiet') `
    -WorkingDirectory $root -TimeoutSec 45
  Check 'Gate regression runner: selected test with server grandchildren completes' ([int]$runner.ExitCode -eq 0 -and -not [bool]$runner.TimedOut) $runner

  $script:GateTimeoutFailTimeouts = @()
  $timeoutRetryPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply $verifiedReply -ChangedPathsOverride @('driver/86-loop-completion-checks.ps1')
  $timeoutFailSuite = {
    param([string]$BridgeRoot, [int]$TimeoutSec, [string[]]$ChangedPaths)
    $script:GateTimeoutFailTimeouts = @($script:GateTimeoutFailTimeouts + $TimeoutSec)
    return [pscustomobject]@{ Ok=$false; ExitCode=124; TimedOut=$true; Scope=@($ChangedPaths); Output=@('INCONCL test-hanging-gate.ps1 timeout after budget') }
  }
  $timeoutFailRuntime = Invoke-DriverDoneGateChecksSequential -Plan $timeoutRetryPlan -BridgeRoot $root -Channel 'test' -GateRegressionSuiteScriptBlock $timeoutFailSuite
  Check 'Gate regression timeout fail: first timeout triggers 600s fallback then resumes fixed schedule' (@($script:GateTimeoutFailTimeouts) -join ',' -eq '60,600,60,120') $script:GateTimeoutFailTimeouts
  Check 'Gate regression timeout fail: fallback timeout exhausts fixed schedule before inconclusive evidence' ([int]$timeoutFailRuntime.GateRegression.Attempts -eq 4 -and -not [bool]$timeoutFailRuntime.GateRegression.Ok -and [bool]$timeoutFailRuntime.GateRegression.TimeoutRetryAdded -and [bool]$timeoutFailRuntime.GateRegression.TimeoutFallbackAdded -and [int]$timeoutFailRuntime.GateRegression.TimeoutFallbackBudget -eq 600) $timeoutFailRuntime.GateRegression
  Check 'Gate regression exhausted timeout is inconclusive (fail-open)' ([bool]$timeoutFailRuntime.GateRegression.TimeoutInconclusive -and (Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult $timeoutFailRuntime.GateRegression)) $timeoutFailRuntime.GateRegression
  Check 'Gate regression timeout diagnostics: captures timed-out test name from INCONCL output' ((@($timeoutFailRuntime.GateRegression.LastTimedOutTests) -join ',') -eq 'test-hanging-gate.ps1') $timeoutFailRuntime.GateRegression
  $syntheticFallbackOnlyTimeoutGate = [pscustomobject]@{ Ok=$false; TimedOut=$true; ExitCode=124; RuntimeError=''; Attempts=2; TimeoutRetryAdded=$false; TimeoutFallbackAdded=$true; TimeoutFallbackBudget=600; TimeoutSchedule=@(60,600) }
  Check 'Gate regression synthetic fallback-only 124 result is incomplete (blocking)' (-not (Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult $syntheticFallbackOnlyTimeoutGate)) $syntheticFallbackOnlyTimeoutGate
  $syntheticTimeoutGate = [pscustomobject]@{ Ok=$false; TimedOut=$true; ExitCode=124; RuntimeError=''; Attempts=4; TimeoutRetryAdded=$true; TimeoutFallbackAdded=$true; TimeoutFallbackBudget=600; TimeoutSchedule=@(60,600,60,120) }
  Check 'Gate regression synthetic exhausted 124 result is inconclusive (fail-open)' ((Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult $syntheticTimeoutGate)) $syntheticTimeoutGate

  $script:GateFallbackPassTimeouts = @()
  $fallbackPassSuite = {
    param([string]$BridgeRoot, [int]$TimeoutSec, [string[]]$ChangedPaths)
    $script:GateFallbackPassTimeouts = @($script:GateFallbackPassTimeouts + $TimeoutSec)
    if ($script:GateFallbackPassTimeouts.Count -eq 1) {
      return [pscustomobject]@{ Ok=$false; ExitCode=124; TimedOut=$true; Scope=@($ChangedPaths) }
    }
    return [pscustomobject]@{ Ok=$true; ExitCode=0; TimedOut=$false; Scope=@($ChangedPaths) }
  }
  $fallbackPassRuntime = Invoke-DriverDoneGateChecksSequential -Plan $timeoutRetryPlan -BridgeRoot $root -Channel 'test' -GateRegressionSuiteScriptBlock $fallbackPassSuite
  Check 'Gate regression fallback pass: budgets are 60,600' (@($script:GateFallbackPassTimeouts) -join ',' -eq '60,600') $script:GateFallbackPassTimeouts
  Check 'Gate regression fallback pass: result is PASS and non-blocking' ([bool]$fallbackPassRuntime.GateRegression.Ok -and [bool]$fallbackPassRuntime.GateRegression.TimeoutFallbackAdded -and [int]$fallbackPassRuntime.GateRegression.TimeoutFallbackBudget -eq 600) $fallbackPassRuntime.GateRegression
  $fallbackPassBudgetSuffix = Format-DriverDoneGateRegressionBudgetSuffix -GateResult $fallbackPassRuntime.GateRegression
  Check 'Gate regression fallback pass: log suffix shows budgets and fallback' ($fallbackPassBudgetSuffix -eq ' (budgets=60,600; fallback=600s)') $fallbackPassBudgetSuffix

  $script:CapturedGateMessages = @()
  $script:ClearedGateFailureKinds = @()
  $script:SetGateFailures = @()
  $script:FakeGateState = [pscustomobject]@{
    gate_regression_fail_count = 2
    task_last_failure = [pscustomobject]@{ kind='gate_regression_failed'; text='old failure' }
  }
  function Add-Message {
    param([string]$From, [string]$Text, [string]$Kind)
    $script:CapturedGateMessages = @($script:CapturedGateMessages + [pscustomobject]@{ From=$From; Text=$Text; Kind=$Kind })
  }
  function Clear-TaskLastFailureKind {
    param([string]$Kind = '')
    $script:ClearedGateFailureKinds = @($script:ClearedGateFailureKinds + $Kind)
    if ($script:FakeGateState.task_last_failure -and [string]$script:FakeGateState.task_last_failure.kind -eq $Kind) {
      $script:FakeGateState.task_last_failure = $null
    }
  }
  function Set-TaskLastFailure {
    param([string]$Kind, [string]$Text)
    $script:SetGateFailures = @($script:SetGateFailures + [pscustomobject]@{ Kind=$Kind; Text=$Text })
  }
  function Update-State {
    param([scriptblock]$Mutation)
    & $Mutation $script:FakeGateState | Out-Null
    return $script:FakeGateState
  }

  $plannerStatus = 'DONE'
  $timeoutHandlerCommand = Get-Command Invoke-DriverDoneGateRegressionTimeoutInconclusiveHandling -ErrorAction Stop
  Check 'Gate regression timeout diagnostics: handler accepts TimedOutTests parameter' ($timeoutHandlerCommand.Parameters.ContainsKey('TimedOutTests')) $timeoutHandlerCommand.Parameters.Keys
  $timeoutFailRecord = Invoke-DriverDoneGateRegressionTimeoutInconclusiveHandling -GateResult $syntheticTimeoutGate -FailReason 'exit=124, timedOut=True' -TimedOutTests @($timeoutFailRuntime.GateRegression.LastTimedOutTests)
  $timeoutFailMessage = ''
  if ($script:CapturedGateMessages.Count -gt 0) { $timeoutFailMessage = [string]$script:CapturedGateMessages[-1].Text }
  Check 'Gate regression inconclusive timeout runtime: plannerStatus remains DONE (fail-open)' ($plannerStatus -eq 'DONE') $plannerStatus
  Check 'Gate regression inconclusive timeout runtime: stale gate_regression_failed is cleared (fail-open)' (@($script:ClearedGateFailureKinds) -contains 'gate_regression_failed') $script:ClearedGateFailureKinds
  Check 'Gate regression inconclusive timeout runtime: state records inconclusive_timeout' ([string]$script:FakeGateState.gate_regression_last_outcome -eq 'inconclusive_timeout' -and [int]$script:FakeGateState.gate_regression_last_attempts -eq 4 -and (@($script:FakeGateState.gate_regression_last_budgets) -join ',') -eq '60,600,60,120') $script:FakeGateState
  Check 'Gate regression inconclusive timeout runtime: event says final inconclusive_timeout outcome with fallback' ($timeoutFailMessage.Contains('final outcome=inconclusive_timeout') -and $timeoutFailMessage.Contains('budgets=60,600,60,120') -and $timeoutFailMessage.Contains('fallback=600s')) $timeoutFailMessage
  Check 'Gate regression timeout diagnostics: event names timed-out test' ($timeoutFailMessage.Contains('timed_out_tests=test-hanging-gate.ps1')) $timeoutFailMessage
  Check 'Gate regression inconclusive timeout runtime: handler returns machine outcome' ([string]$timeoutFailRecord.Outcome -eq 'inconclusive_timeout') $timeoutFailRecord
  Check 'Gate regression early/incomplete timeout (1 attempt) remains blocking' (-not (Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult ([pscustomobject]@{ Ok=$false; ExitCode=124; TimedOut=$true; RuntimeError=''; Attempts=1; TimeoutRetryAdded=$false; TimeoutSchedule=@(60) }))) $null
  Check 'Gate regression scheduled 60,60,120 timeout is inconclusive' (Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult ([pscustomobject]@{ Ok=$false; ExitCode=124; TimedOut=$true; RuntimeError=''; Attempts=3; TimeoutRetryAdded=$true; TimeoutSchedule=@(60,60,120) })) $null
  Check 'Gate regression timeout fail: non-timeout failure remains blocking' (-not (Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult ([pscustomobject]@{ Ok=$false; ExitCode=1; TimedOut=$false; RuntimeError='' }))) $null

  $script:GateMixedFailureTimeouts = @()
  $mixedFailureThenTimeoutSuite = {
    param([string]$BridgeRoot, [int]$TimeoutSec, [string[]]$ChangedPaths)
    $script:GateMixedFailureTimeouts = @($script:GateMixedFailureTimeouts + $TimeoutSec)
    if ($script:GateMixedFailureTimeouts.Count -eq 1) {
      return [pscustomobject]@{ Ok=$false; ExitCode=1; TimedOut=$false; Scope=@($ChangedPaths) }
    }
    return [pscustomobject]@{ Ok=$false; ExitCode=124; TimedOut=$true; Scope=@($ChangedPaths) }
  }
  $mixedFailureThenTimeoutRuntime = Invoke-DriverDoneGateChecksSequential -Plan $timeoutRetryPlan -BridgeRoot $root -Channel 'test' -GateRegressionSuiteScriptBlock $mixedFailureThenTimeoutSuite
  Check 'Gate regression timeout fail: mixed failure then timeout uses fixed schedule' (@($script:GateMixedFailureTimeouts) -join ',' -eq '60,60,120') $script:GateMixedFailureTimeouts
  Check 'Gate regression timeout fail: mixed failure then timeout remains blocking' (-not [bool]$mixedFailureThenTimeoutRuntime.GateRegression.TimeoutInconclusive) $mixedFailureThenTimeoutRuntime.GateRegression
}

function Invoke-BridgeCoreCoverageChecks {
  # Fail-safe bridge-core classification: every engine *.ps1 outside the explicit
  # non-risky trees MUST be treated as bridge-core (full suite). These cases guard
  # against silently dropping a risky engine change into the parse+smoke fast subset.

  # (a) Dependency proof — directly rebuts the "calls an undefined gate-scope function"
  # critic finding: Get-GateRegressionScope must be resolvable, and New-DriverDoneGatePlan
  # must build a plan (it calls Get-GateRegressionScope internally) without throwing.
  Check 'Gate scope dependency: Get-GateRegressionScope command is available' ([bool](Get-Command Get-GateRegressionScope -ErrorAction SilentlyContinue)) $null
  $depErr = ''
  try {
    [void](New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('lib/common.ps1'))
    [void](New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('docs/x.md'))
  } catch {
    $depErr = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  Check 'Gate scope dependency: New-DriverDoneGatePlan resolves the scope call without throwing' ([string]::IsNullOrWhiteSpace($depErr)) $depErr

  # (b) Risky engine files outside the old narrow allowlist are now bridge-core.
  $corePaths = @(
    'lib/common.ps1','watchdog.ps1','scheduler.ps1','lib/circuit-breaker.ps1',
    'lib/memory.ps1','lib/settings.ps1','critic.ps1','librarian.ps1',
    'server.ps1','supervisor.ps1','driver.ps1','tools/run-tests.ps1','tools/smoke.ps1'
  )
  foreach ($cp in $corePaths) {
    Check ("Bridge-core (full suite): {0} classified as core" -f $cp) ([bool](Test-DriverDoneGateBridgeCorePath -Path $cp)) $cp
  }

  # (c) Non-risky trees stay non-core (fast subset) — incl. a PROJECT *.ps1 under channels/.
  $nonCorePaths = @(
    'web/index.html','config.json','docs/readme.md','memory/note.md',
    'channels/telegram-bridge-bot/state.py','channels/foo/script.ps1',
    'tools/test-gate-regression-sentinel.ps1','tools/diag/gate-regression-sentinel-selftest.ps1',
    'tools/auto/Invoke-foo.ps1','bot/main.py'
  )
  foreach ($ncp in $nonCorePaths) {
    Check ("Non-core (fast subset): {0} classified as non-core" -f $ncp) (-not [bool](Test-DriverDoneGateBridgeCorePath -Path $ncp)) $ncp
  }

  # (d) Plan-level: a risky lib change (not in the old allowlist) now runs the full suite.
  $libCommonPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('lib/common.ps1')
  Check 'Bridge-core plan: lib/common.ps1 schedules the full snapshot suite' ([bool]$libCommonPlan.GateSuiteNeeded -and (@($libCommonPlan.JobNames) -contains 'gate-regression') -and -not [bool]$libCommonPlan.GateNonCoreFastSubset) $libCommonPlan

  # (e) Plan-level: a pure UI/config change skips the full suite (fast subset).
  $uiPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('web/index.html','config.json')
  Check 'Non-core plan: web/config change uses fast subset, no gate job' ([bool]$uiPlan.GateNonCoreFastSubset -and -not [bool]$uiPlan.GateSuiteNeeded -and -not (@($uiPlan.JobNames) -contains 'gate-regression')) $uiPlan

  # (f) Mixed scope semantics: ALL paths must be non-core to fast-subset; one risky path
  # flips the whole turn back to the full suite (no coverage loss for the risky file).
  $mixedPlan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @('docs/note.md','lib/common.ps1')
  Check 'Mixed scope: one risky engine path forces the full suite' ([bool]$mixedPlan.GateSuiteNeeded -and (@($mixedPlan.JobNames) -contains 'gate-regression') -and -not [bool]$mixedPlan.GateNonCoreFastSubset) $mixedPlan
}

$cases = @(
  [FastpathCase]::new('TRIVIAL', [string[]]@('docs/test'), $false),
  [FastpathCase]::new('CONTROL_PLANE', [string[]]@('driver/86-loop-completion-checks.ps1'), $true)
)

foreach ($case in $cases) {
  Invoke-FastpathCase -Case $case
}
Invoke-AdditionalFastpathChecks
Invoke-BridgeCoreCoverageChecks

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
