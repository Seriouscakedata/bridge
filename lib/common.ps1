# common.ps1 -- shared helpers for the bridge. Dot-source this.
# All state lives in files under the bridge root so it survives reboots.

$ErrorActionPreference = 'Stop'
$script:CommonLibRoot = $PSScriptRoot

# Common implementation modules. Keep this loader thin; edit behavior in lib/common/*.ps1.
. (Join-Path $script:CommonLibRoot 'common\00-core-config.ps1')
. (Join-Path $script:CommonLibRoot 'common\10-process-cleanup.ps1')
. (Join-Path $script:CommonLibRoot 'common\20-state-locks.ps1')
. (Join-Path $script:CommonLibRoot 'common\30-task-context.ps1')
. (Join-Path $script:CommonLibRoot 'common\40-preflight-channels.ps1')
. (Join-Path $script:CommonLibRoot 'common\50-messages-init.ps1')


$LoadBridgeModule = {
  param([string]$Name, [string]$File)
  $modulePath = Join-Path $PSScriptRoot $File
  try {
    . $modulePath
    Set-BridgeCapability -Name $Name -Path $modulePath -Ok $true
  } catch {
    Set-BridgeCapability -Name $Name -Path $modulePath -Ok $false -Error $_.Exception.Message
    Write-Warning "$File failed to load: $($_.Exception.Message)"
  }
}

# Replay capture is loaded before memory/LLM helpers so background chat calls can
# write records when a task is active. Best-effort and non-fatal.
. $LoadBridgeModule 'replay' 'replay.ps1'
# Long-term vector memory (Gemini embeddings + Flash librarian). Best-effort: if this
# layer fails to load or Gemini is unreachable, the engine keeps running unchanged.
. $LoadBridgeModule 'memory' 'memory.ps1'
# Per-project semantic code memory, stored separately from ordinary long-term memory.
. $LoadBridgeModule 'codemem' 'codemem.ps1'
# LLM router (DeepSeek/Gemini for cheap background thinking) -- load AFTER memory.ps1.
. $LoadBridgeModule 'llm' 'llm.ps1'
# Usage accounting (prepaid agent turns + paid API calls). Best-effort and non-fatal.
. $LoadBridgeModule 'usage' 'usage.ps1'
# Planner model router layered on top of Get-PlannerModel; learns from turns.jsonl outcomes.
. $LoadBridgeModule 'router' 'router.ps1'
# Channel layout helpers must load before backlog.ps1 because Get-BacklogPath
# delegates to Get-ChannelBacklogPath when channels are available.
. $LoadBridgeModule 'channels' 'channels.ps1'
# Run channel migration once — moves legacy bridge-root files into channels/main/ if needed.
# Idempotent; safe to call on every Initialize-Bridge.
try {
  if (Get-Command Initialize-Channels -ErrorAction SilentlyContinue) { Initialize-Channels }
  else { Write-Warning "Initialize-Channels skipped: channels module is unavailable" }
} catch { Write-Warning "Initialize-Channels failed: $($_.Exception.Message)" }
# Self-improvement backlog (ideas the agents raise themselves).
. $LoadBridgeModule 'backlog' 'backlog.ps1'
# User-tunable settings (gitignored overrides: idle-quiet, autonomy scope, etc.).
. $LoadBridgeModule 'settings' 'settings.ps1'
# Background job manager (long-running commands -- e.g. hour-long project runs).
. $LoadBridgeModule 'jobs' 'jobs.ps1'
# Worktree isolation primitives (foundation for parallel workers + sandbox).
. $LoadBridgeModule 'worktrees' 'worktrees.ps1'
# Tool Foundry (Фаза 1): registry + loader for tools the bridge synthesizes on the fly.
. $LoadBridgeModule 'toolforge' 'toolforge.ps1'
# Parallel worker orchestration (run sub-tasks concurrently in worktrees, merge back).
. $LoadBridgeModule 'parallel' 'parallel.ps1'
. $LoadBridgeModule 'doctor' 'doctor.ps1'
. $LoadBridgeModule 'architect' 'architect.ps1'
# Evidence-backed per-project memory layer (typed memory + context pack) on top
# of memory.ps1/codemem.ps1/channels.ps1. Best-effort and non-fatal.
. $LoadBridgeModule 'project-context' 'project-context.ps1'
# Telegram push notifications (best-effort, non-fatal).
. $LoadBridgeModule 'notify' 'notify.ps1'
# Study-mode detection (single source of truth; bounded command-verb gate).
. $LoadBridgeModule 'study' 'study.ps1'
# LLM intent classifier — replaces hardcoded [[DEEP-THINK]] regex with semantic
# task understanding (gemini-flash-lite, cheap). Must load AFTER llm.ps1.
. $LoadBridgeModule 'intent' 'intent.ps1'
# Radar (RSS digest collector) + Scholar (autonomous deep-reader: reads FULL article text + links,
# verdicts idea/knowledge/skip against bridge gaps -- replaces radar's title-only judging). Scholar
# depends on radar (candidates) + llm + backlog (all loaded above).
. $LoadBridgeModule 'radar' 'radar.ps1'
. $LoadBridgeModule 'scholar' 'scholar.ps1'
