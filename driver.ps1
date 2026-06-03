# driver.ps1 -- INTERACTIVE bridge: idles, and treats each [USER] chat message as a
# task. Planner (Claude) plans/reviews, Coder (Codex) executes with FULL PC access.
#
# Phase 3 (full): supports per-channel parallel drivers. Pass `-Channel <slug>` and the
# driver hard-pins itself to that channel for its entire process lifetime -- all
# Read-State/Update-State/Add-Message calls route into channels/<slug>/. Supervisor
# spawns one process per non-archived channel.
param([string]$Channel = $null, [switch]$SelfTest)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\agent-wait.ps1')
. (Join-Path $PSScriptRoot 'lib\metrics.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
# Project Foundry (Фаза 2): New-Project pipeline + the dispatched-DAG executor
# (Invoke-FoundryPlanDispatch / Invoke-PlanDag / New-FoundryStepRunner). Depends on
# plan.ps1 (above) plus worktrees/parallel/channels (loaded via common.ps1).
. (Join-Path $PSScriptRoot 'lib\foundry.ps1')
. (Join-Path $PSScriptRoot 'lib\auditor.ps1')
. (Join-Path $PSScriptRoot 'lib\canary.ps1')
. (Join-Path $PSScriptRoot 'lib\replay.ps1')
. (Join-Path $PSScriptRoot 'lib\postmortem.ps1')
. (Join-Path $PSScriptRoot 'lib\features.ps1')
. (Join-Path $PSScriptRoot 'lib\qa-agent.ps1')
. (Join-Path $PSScriptRoot 'lib\project-acceptance.ps1')
. (Join-Path $PSScriptRoot 'lib\checkpoint.ps1')
$ErrorActionPreference = 'Continue'

# Tool Foundry (Фаза 1): load every GREEN (status=active) self-built tool from
# tools/auto/. MUST stay at TOP LEVEL -- dot-sourcing inside a function would trap the
# tool functions in that function's local scope instead of the engine's script scope.
# Get-ActiveAutoToolPaths is pure + best-effort: broken/missing tools are silently
# dropped (re-validated names, parse-checked) so a bad tool can never block the engine.
try { foreach ($p in (Get-ActiveAutoToolPaths)) { . $p } } catch {}

# Resolve and lock the channel for this driver process. If -Channel wasn't passed
# (legacy single-driver mode or supervisor before update), fall back to active marker.
if ([string]::IsNullOrWhiteSpace($Channel)) {
  $Channel = (Get-ActiveChannel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
}
$Channel = Normalize-ChannelSlug $Channel
Set-PinnedChannel $Channel
Write-Host ("driver pinned to channel: " + $Channel)

# UTF-8 end-to-end (Russian survives the stdin/stdout file round-trip).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom; [Console]::InputEncoding = $Utf8NoBom } catch {}

try {
  $cfg = Get-BridgeConfig
  $requiredConfigKeys = @('port','maxTurns','loopDelaySeconds','workRoot')
  foreach ($requiredConfigKey in $requiredConfigKeys) {
    if ($cfg.PSObject.Properties.Name -notcontains $requiredConfigKey -or $null -eq $cfg.$requiredConfigKey) {
      Write-Error ("FATAL driver config error: missing required config key '" + $requiredConfigKey + "'")
      exit 3
    }
  }
} catch {
  Write-Error ("FATAL driver config error: " + $_.Exception.Message)
  exit 3
}
$claudeExe  = Resolve-ClaudeExe $cfg
$codexExe   = Resolve-CodexExe  $cfg
$workRoot   = [string]$cfg.workRoot
$bridgeRoot = Get-BridgeRoot

# 2026-05-31 (Foundation #4): ensure node/npm on PATH for PROJECT channels (build/test/verify).
# The driver starts -NoProfile inheriting the supervisor's stale PATH (captured before node was
# installed), so child coder processes can't find node. Locate it once and prepend to this
# process's PATH; spawned codex/claude inherit it. No-op if node is already visible.
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  $nodeDirs = @()
  try { $nodeDirs += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenJS.NodeJS*\node-*-win-x64\node.exe') -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName }) } catch {}
  $nodeDirs += @((Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'))
  foreach ($d in $nodeDirs) { if ($d -and (Test-Path (Join-Path $d 'node.exe'))) { $env:Path = [string]$d + ';' + $env:Path; break } }
}
$maxTurns   = [int]$cfg.maxTurns
$loopDelay  = [int]$cfg.loopDelaySeconds
$idlePoll   = if ($cfg.idlePollSeconds) { [int]$cfg.idlePollSeconds } else { 3 }
# Adaptive idle backoff (perf 2026-05-29): keep the snappy $idlePoll cadence for the first
# $idleFastTicks consecutive idle ticks after any activity, then ramp the sleep +1s/tick up to
# $idleMaxPoll. A long-idle bridge otherwise wakes ~1Hz to run maintenance that is almost always
# "not due" -- pure redundant looping. The streak resets to 0 the instant a user message arrives
# or an autonomous task is claimed, so post-activity responsiveness is unchanged.
$idleMaxPoll   = if ($cfg.idleMaxPollSeconds) { [int]$cfg.idleMaxPollSeconds } else { 5 }
$idleFastTicks = if ($cfg.idleFastTicks)      { [int]$cfg.idleFastTicks }      else { 8 }
if ($idleMaxPoll -lt $idlePoll) { $idleMaxPoll = $idlePoll }   # never sleep below base cadence
$script:idleStreak = 0
$fullContext    = if ($cfg.fullContextCount) { [int]$cfg.fullContextCount } else { 20 }
$summarizeBatch = if ($cfg.summarizeBatch)   { [int]$cfg.summarizeBatch }   else { 15 }
$triageModel       = if ($cfg.triageModel)       { [string]$cfg.triageModel }       else { 'sonnet' }
$deepModel         = if ($cfg.deepModel)         { [string]$cfg.deepModel }         else { 'opus' }
$discussMinTurns   = if ($cfg.discussMinTurns)   { [int]$cfg.discussMinTurns }      else { 3 }
$discussMaxTurns   = if ($cfg.discussMaxTurns)   { [int]$cfg.discussMaxTurns }      else { 8 }
$researchMaxTurns  = if ($cfg.researchMaxTurns)  { [int]$cfg.researchMaxTurns }     else { 2 }
$studyMaxTurns     = if ($cfg.studyMaxTurns)     { [int]$cfg.studyMaxTurns }        else { 5 }


# Driver implementation modules. Keep this entrypoint thin; edit behavior in driver/*.ps1.
. (Join-Path $PSScriptRoot 'driver\00-task-session.ps1')
. (Join-Path $PSScriptRoot 'driver\10-maintenance.ps1')
. (Join-Path $PSScriptRoot 'driver\20-context.ps1')
. (Join-Path $PSScriptRoot 'driver\30-prompt-agent-state.ps1')
. (Join-Path $PSScriptRoot 'driver\40-agent-invoke.ps1')
. (Join-Path $PSScriptRoot 'driver\50-loop-utils.ps1')
. (Join-Path $PSScriptRoot 'driver\60-startup.ps1')
. (Join-Path $PSScriptRoot 'driver\80-loop-preflight.ps1')
. (Join-Path $PSScriptRoot 'driver\81-loop-idle-claim.ps1')
. (Join-Path $PSScriptRoot 'driver\82-loop-turn-setup.ps1')
. (Join-Path $PSScriptRoot 'driver\83-loop-agent-turn.ps1')
. (Join-Path $PSScriptRoot 'driver\84-loop-reply-markers.ps1')
. (Join-Path $PSScriptRoot 'driver\85-loop-mode-transitions.ps1')
. (Join-Path $PSScriptRoot 'driver\86-loop-completion.ps1')
. (Join-Path $PSScriptRoot 'driver\87-loop-final-guard.ps1')
. (Join-Path $PSScriptRoot 'driver\90-main-loop.ps1')

# ---------- driver self-test (pre-promote runtime gate) ----------
# smoke.ps1 PARSES every .ps1 and runs common.ps1 at runtime (Get-PreflightBlockers), but it never
# EXECUTES driver.ps1 -- so a parse-OK-but-runtime-broken edit here (the PS5.1 `(if...)` expression
# bomb behind the 2026-05-26 restart-loop) shipped green and only blew up on the NEXT restart.
# Running this file as `-SelfTest` in a CHILD process makes reaching this line proof that every
# dot-sourced lib + driver module function loaded without a runtime error; we then smoke the pure
# helpers most exposed to Doctor/coder timeout edits.
# This guard sits BEFORE the startup block (Sweep-AgentOrphans, tmp-sweep, zombie-recovery, Doctor
# restart-loop guard) so the child performs NO process kills, NO Add-Message, NO state writes -- it
# is safe to run alongside the live driver. (Initialize-Bridge above is idempotent without -Reset:
# it only creates missing dirs, never overwrites an existing convo/state.)
if ($SelfTest) {
  $stFail = New-Object System.Collections.ArrayList
  try {
    $probeCfg = Get-BridgeConfig
    $ct = 900000
    if ($probeCfg.coderTimeoutMs -and [int]$probeCfg.coderTimeoutMs -gt 0) { $ct = [int]$probeCfg.coderTimeoutMs }
    if ($ct -le 0) { [void]$stFail.Add('coderTimeoutMs resolved <= 0') }
    $cr = 2
    if ($probeCfg.PSObject.Properties.Name -contains 'criticMaxRetries') { $cr = [int]$probeCfg.criticMaxRetries }
    if ($cr -lt 0) { [void]$stFail.Add('criticMaxRetries < 0') }
  } catch { [void]$stFail.Add('config probe threw: ' + $_.Exception.Message) }
  foreach ($fn in @('Wait-AgentProcess','Get-PlannerModel','Start-ReplayForStateTask','Sweep-AgentOrphans','Initialize-DriverStartup','Start-DriverMainLoop','Activate-Doctor','Complete-Doctor','Abort-Doctor','Get-TaskRepoRoot','Test-QualityBypassesInDiff','Start-ProjectAcceptanceIfDue','Invoke-ProjectAcceptance')) {
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { [void]$stFail.Add('missing function: ' + $fn) }
  }
  foreach ($sbName in @('DriverLoopPreflightBlock','DriverLoopIdleClaimBlock','DriverLoopTurnSetupBlock','DriverLoopAgentTurnBlock','DriverLoopReplyMarkersBlock','DriverLoopModeTransitionBlock','DriverLoopCompletionBlock','DriverLoopFinalGuardBlock')) {
    $sb = Get-Variable -Name $sbName -Scope Script -ErrorAction SilentlyContinue
    if (-not $sb -or -not ($sb.Value -is [scriptblock])) { [void]$stFail.Add('missing loop scriptblock: ' + $sbName) }
  }
  try {
    $qbProbe = @(Test-QualityBypassesInDiff -Diff "+  typescript: { ignoreBuildErrors: true },")
    if ($qbProbe.Count -lt 1) { [void]$stFail.Add('quality-bypass detector missed ignoreBuildErrors') }
  } catch {
    [void]$stFail.Add('quality-bypass detector threw: ' + $_.Exception.Message)
  }
  if ($stFail.Count -gt 0) { foreach ($f in $stFail) { Write-Output ('DRIVER SELFTEST FAIL: ' + $f) }; exit 1 }
  Write-Output 'DRIVER SELFTEST OK'
  exit 0
}


Initialize-DriverStartup
Start-DriverMainLoop
