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
. (Join-Path $PSScriptRoot 'lib\verify-selftest.ps1')
. (Join-Path $PSScriptRoot 'lib\delivery-gate-shadow.ps1')
. (Join-Path $PSScriptRoot 'lib\task-management.ps1')
. (Join-Path $PSScriptRoot 'lib\prompt-builder.ps1')
$ErrorActionPreference = 'Continue'

# Tool Foundry (Фаза 1): load every GREEN (status=active) self-built tool from
# tools/auto/. MUST stay at TOP LEVEL -- dot-sourcing inside a function would trap the
# tool functions in that function's local scope instead of the engine's script scope.
# Get-ActiveAutoToolPaths is pure + best-effort: broken/missing tools are silently
# dropped (re-validated names, BOM + parse + hash checked) so a bad tool can never
# block the engine. Re-check immediately before dot-source to close TOCTOU gaps.
try {
  foreach ($p in (Get-ActiveAutoToolPaths)) {
    try {
      if (Test-AutoToolLoadReady -Path $p) { . $p }
    } catch {}
  }
} catch {}

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

if (-not $script:DriverOriginalTestTaskIntent) {
  try { $script:DriverOriginalTestTaskIntent = (Get-Command Test-TaskIntent -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}

function Test-DriverBugfixIntentFallbackMatch {
  param([string]$TaskText)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $false }
  return ([string]$TaskText -match '(?i)\bBROKEN\b|broken\s+behavior|\berror\b|\bcrash(?:es|ed|ing)?\b')
}

function New-DriverBugfixIntentFallback {
  param(
    [string]$TaskText,
    $PreviousIntent = $null
  )
  $raw = $null
  try { if ($PreviousIntent -and ($PreviousIntent.PSObject.Properties.Name -contains 'raw')) { $raw = $PreviousIntent.raw } } catch {}
  return [pscustomobject]@{
    primary_mode = 'normal'
    confidence = 0.72
    reasoning = 'keyword fallback: BROKEN/error/crash means bugfix/repair even when classifier was skipped or low-confidence'
    subtasks = @(@{ action = 'fix'; object = 'reported broken behavior' })
    user_wants_dialogue = $false
    complexity = 'simple'
    estimated_turns = 2
    raw = $raw
    source = 'keyword-bugfix-fallback'
    fallback_intent = 'bugfix'
    tags = @('bugfix','repair')
  }
}

function Test-TaskIntent {
  param(
    [string]$TaskText,
    [int]$TimeoutSec = 25,
    [string]$Model = ''
  )

  $intent = $null
  if ($script:DriverOriginalTestTaskIntent) {
    try {
      if ([string]::IsNullOrWhiteSpace($Model)) {
        $intent = & $script:DriverOriginalTestTaskIntent -TaskText $TaskText -TimeoutSec $TimeoutSec
      } else {
        $intent = & $script:DriverOriginalTestTaskIntent -TaskText $TaskText -TimeoutSec $TimeoutSec -Model $Model
      }
    } catch {
      $intent = $null
    }
  }

  if (Test-DriverBugfixIntentFallbackMatch -TaskText $TaskText) {
    $confidence = 0.0
    try { if ($intent -and ($intent.PSObject.Properties.Name -contains 'confidence')) { $confidence = [double]$intent.confidence } } catch { $confidence = 0.0 }
    if ((-not $intent) -or $confidence -lt 0.70) {
      return (New-DriverBugfixIntentFallback -TaskText $TaskText -PreviousIntent $intent)
    }
    try {
      $intent | Add-Member -NotePropertyName fallback_intent -NotePropertyValue 'bugfix' -Force
      $intent | Add-Member -NotePropertyName tags -NotePropertyValue @('bugfix','repair') -Force
    } catch {}
  }

  return $intent
}

if (-not $script:DriverOriginalStartFeatureVerifierIfDue) {
  try { $script:DriverOriginalStartFeatureVerifierIfDue = (Get-Command Start-FeatureVerifierIfDue -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}

function Invoke-DriverFeatureVerifierBrokenFiling {
  param([string]$Reason = 'idle')
  if (-not (Get-Command Add-FeatureVerifierBrokenBugfixBacklogItems -ErrorAction SilentlyContinue)) { return $null }
  $result = $null
  try { $result = Add-FeatureVerifierBrokenBugfixBacklogItems -BridgeRoot $bridgeRoot } catch { return $null }
  if ($result -and [int]$result.created_count -gt 0) {
    try {
      Add-Message -From system -Kind event -Text ("🩻 Feature Verifier BROKEN → создано bugfix задач: " + [int]$result.created_count + " (" + $Reason + ").") | Out-Null
    } catch {}
  }
  return $result
}

function Start-FeatureVerifierIfDue {
  try { Invoke-DriverFeatureVerifierBrokenFiling -Reason 'pre-verifier-check' | Out-Null } catch {}
  if ($script:DriverOriginalStartFeatureVerifierIfDue) {
    try { & $script:DriverOriginalStartFeatureVerifierIfDue } catch {}
  }
  try { Invoke-DriverFeatureVerifierBrokenFiling -Reason 'post-verifier-check' | Out-Null } catch {}
}

function Invoke-DriverComputerActionFastLane {
  param(
    [string]$TaskText,
    [string]$ChannelName = '',
    [string]$LapaSkill = '',
    [hashtable]$LapaParams = @{}
  )
  # 2026-06-18: лапа as the bridge's PRIMARY hands. When the intent classifier named a
  # structured лапа skill (open-app/type — validated upstream against the allow-list),
  # route the computer_action straight into лапа with its own generous per-skill
  # --timeout, instead of the weak tools\computer-use.ps1 click/vision path. Mirrors the
  # proven in-driver pattern (driver/84-loop-reply-markers.ps1): tmp\lapa-disabled.flag
  # kill-switch, 10-min recent-run dedup (no double-fire), default stop_flag, Invoke-LapaSkill
  # (never throws). A hard PS-side kill backstop lives in Invoke-PythonCapture so a wedged
  # python cannot block the single-threaded driver loop. Clicks/close-window keep LapaSkill=''
  # and fall through to computer-use.ps1 unchanged. Sends to humans are NOT routed here
  # (allow-list is open-app/type only) — they stay on the explicit [[ЛАПА]] marker path.
  $started = [DateTime]::UtcNow
  $output = ''
  $ok = $false
  $viaLapa = $false
  $lapaActive = ((-not [string]::IsNullOrWhiteSpace($LapaSkill)) -and -not (Test-Path -LiteralPath (Join-Path $bridgeRoot 'tmp\lapa-disabled.flag')))
  if ($lapaActive) {
    $viaLapa = $true
    if ($null -eq $LapaParams) { $LapaParams = @{} }
    $lkey = ($LapaSkill + '|' + ((($LapaParams.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join '|'))).ToLowerInvariant()
    $lapaLogDir = Join-Path $bridgeRoot 'tmp\lapa-marker-log'
    $lapaDup = $false
    try {
      if (Test-Path -LiteralPath $lapaLogDir) {
        $lcut = (Get-Date).AddMinutes(-10)
        foreach ($lf in @(Get-ChildItem $lapaLogDir -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $lcut })) {
          if ((([string]([System.IO.File]::ReadAllText($lf.FullName))).Trim().ToLowerInvariant()) -eq $lkey) { $lapaDup = $true; break }
        }
      }
    } catch {}
    if ($lapaDup) {
      $output = "лапа/${LapaSkill}: то же действие уже выполнялось за 10 мин — пропущено."
      $ok = $true
    } else {
      if (-not $LapaParams.ContainsKey('stop_flag')) { $LapaParams['stop_flag'] = (Join-Path $bridgeRoot 'tmp\lapa-stop.flag') }
      if (-not $LapaParams.ContainsKey('timeout')) { $LapaParams['timeout'] = $(if ($LapaSkill -like 'telegram*') { '60' } else { '40' }) }
      try {
        . (Join-Path $bridgeRoot 'tools\lapa-control.ps1')
        $r = Invoke-LapaSkill -Skill $LapaSkill -Params $LapaParams
        $ok = [bool]$r.ok
        $output = "лапа/$LapaSkill → " + ([string]$r.status)
        if ((-not $r.ok) -and $r.error) { $output += " — " + ([string]$r.error) }
        if ($r.proof_path) { $output += " (пруф: " + ([string]$r.proof_path) + ")" }
        try { New-Item -ItemType Directory -Force -Path $lapaLogDir | Out-Null; [System.IO.File]::WriteAllText((Join-Path $lapaLogDir ((Get-Date -Format 'yyyyMMddHHmmssfff') + '.txt')), $lkey) } catch {}
      } catch {
        $ok = $false
        $output = "лапа/$LapaSkill → ошибка вызова: " + $_.Exception.Message
      }
    }
  } else {
    $toolPath = Join-Path $bridgeRoot 'tools\computer-use.ps1'
    if (-not (Test-Path -LiteralPath $toolPath)) {
      Add-Message -From system -Text "🖱 Computer-action fast-lane недоступен: tools\computer-use.ps1 не найден." -Kind event | Out-Null
      return $false
    }
    Add-Message -From system -Text "🖱 Computer-action fast-lane: выполняю локальное UI-действие без planner/coder/critic." -Kind event | Out-Null
    try {
      $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $toolPath -Task $TaskText -TimeoutMs 5000 2>&1)
      $output = (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
      $ok = ($LASTEXITCODE -eq 0)
    } catch {
      $output = $_.Exception.Message
      $ok = $false
    }
  }
  $elapsedMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
  $summary = $output
  if ($summary.Length -gt 1200) { $summary = $summary.Substring(0, 1200) + '...' }
  if ([string]::IsNullOrWhiteSpace($summary)) { $summary = if ($ok) { 'completed' } else { 'failed without output' } }
  $prefix = if ($viaLapa) { if ($ok) { "🎛 Computer-action через лапу выполнен" } else { "⚠ Computer-action через лапу не выполнен" } } else { if ($ok) { "✅ Computer-action выполнен" } else { "⚠ Computer-action не выполнен" } }
  Add-Message -From system -Text ($prefix + " (" + $elapsedMs + " ms).`n" + $summary) -Kind event | Out-Null
  Update-State ({ param($s)
    try { Complete-TaskAgentDuration $s } catch {}
    try { Close-ReplayForStateTask -State $s -Status $(if ($ok) { 'done' } else { 'failed' }) } catch {}
    $s.current_task=$null
    $s.task_turn=0
    $s.task_mode='normal'
    $s.no_progress_count=0
    $s.timeout_retry_count=0
    $s.task_did_actions=[bool]$ok
    $s.coder_fired=$false
    $s.coder_bypass_retry_count=0
    $s.verify_retry_count=0
    $s.force_planner=$false
    $s.discuss_turn=0
    $s.discuss_snapshot=''
    $s.study_phase=''
    $s.study_subtype=''
    $s.study_snapshot=''
    $s.research_count=0
    try { Clear-AuditorSuppressedHashes -State $s } catch {}
    try { Clear-FastLaneFlags $s } catch {}
    try { Clear-ChunkingState $s } catch {}
    $s.active_agent=$null
    $s.active_model=$null
    $s.status_text=$null
    $s.agent_pid=$null
    $s.status='idle'
    $s.heartbeat=(Get-Date).ToString('o')
  }.GetNewClosure()) | Out-Null
  return [bool]$ok
}

if (-not $script:DriverOriginalGetMemoryRecall) {
  try { $script:DriverOriginalGetMemoryRecall = (Get-Command Get-MemoryRecall -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:DriverOriginalSearchProjectMemory) {
  try { $script:DriverOriginalSearchProjectMemory = (Get-Command Search-ProjectMemory -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:DriverOriginalStartBacklogReaperIfDue) {
  try { $script:DriverOriginalStartBacklogReaperIfDue = (Get-Command Start-BacklogReaperIfDue -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
$script:DriverBacklogReaperRetryDueAt = $null
$script:DriverBacklogReaperRetryIds = @()

function Get-DriverMemoryRecordTimestamp {
  param($Mem)
  foreach ($field in @('ts','createdAt','created_at','timestamp')) {
    try {
      if ($Mem -and ($Mem.PSObject.Properties.Name -contains $field) -and -not [string]::IsNullOrWhiteSpace([string]$Mem.$field)) {
        return ([datetime]::Parse([string]$Mem.$field).ToUniversalTime())
      }
    } catch {}
  }
  return $null
}

function Invoke-DriverMemoryArchiveRotation {
  param(
    [string]$Channel = $null,
    [int]$MaxEntries = 1000,
    [int]$OlderThanDays = 14
  )
  try {
    foreach ($fn in @('Get-MemoryStorePath','Get-MemoryDir','Get-AllMemories','Save-AllMemories','Write-AtomicFile')) {
      if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { return $null }
    }
    if ([string]::IsNullOrWhiteSpace($Channel)) {
      if (Get-Command Get-CurrentMemoryChannel -ErrorAction SilentlyContinue) { $Channel = Get-CurrentMemoryChannel }
    }
    if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
    $storePath = Get-MemoryStorePath -Slug $Channel
    if (-not (Test-Path -LiteralPath $storePath)) { return [pscustomobject]@{ rotated=$false; reason='missing-store'; count=0 } }
    $lineCount = 0
    foreach ($line in [System.IO.File]::ReadLines($storePath)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $lineCount++
      if ($lineCount -gt $MaxEntries) { break }
    }
    if ($lineCount -le $MaxEntries) { return [pscustomobject]@{ rotated=$false; reason='below-threshold'; count=$lineCount } }

    $mems = @(Get-AllMemories -Channel $Channel)
    if ($mems.Count -le $MaxEntries) { return [pscustomobject]@{ rotated=$false; reason='below-threshold-after-parse'; count=$mems.Count } }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1 * [Math]::Max(1, $OlderThanDays))
    $archive = New-Object 'System.Collections.Generic.List[object]'
    $keep = New-Object 'System.Collections.Generic.List[object]'
    $oldest = $null; $newest = $null
    foreach ($m in $mems) {
      $kind = ''
      try { if ($m.PSObject.Properties.Name -contains 'type') { $kind = [string]$m.type } } catch {}
      if ($kind -eq 'archive_summary') { [void]$keep.Add($m); continue }
      $pinned = $false
      try { $pinned = [bool]($m.PSObject.Properties.Name -contains 'pinned' -and $m.pinned) } catch {}
      if ($pinned) { [void]$keep.Add($m); continue }
      $ts = Get-DriverMemoryRecordTimestamp -Mem $m
      if ($null -eq $ts -or $ts -ge $cutoff) { [void]$keep.Add($m); continue }
      [void]$archive.Add($m)
      if ($null -eq $oldest -or $ts -lt $oldest) { $oldest = $ts }
      if ($null -eq $newest -or $ts -gt $newest) { $newest = $ts }
    }
    if ($archive.Count -eq 0) { return [pscustomobject]@{ rotated=$false; reason='no-old-records'; count=$mems.Count } }

    $dir = Get-MemoryDir -Slug $Channel
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $archiveName = 'archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl'
    $archivePath = Join-Path $dir $archiveName
    $archiveLines = @($archive.ToArray() | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
    Write-AtomicFile -Path $archivePath -Content (($archiveLines -join "`n") + "`n")

    $summaryText = "Archived " + $archive.Count + " memory records older than " + $OlderThanDays + " days to " + $archiveName + "."
    $summary = [ordered]@{
      id = ('archive-summary-' + ([guid]::NewGuid().ToString('N')))
      ts = (Get-Date).ToUniversalTime().ToString('o')
      type = 'archive_summary'
      kind = 'memory_note'
      channel = $Channel
      text = $summaryText
      tags = @('memory-archive','archive_summary')
      importance = 0.4
      status = 'active'
      count = $archive.Count
      oldest = $(if ($oldest) { $oldest.ToString('o') } else { $null })
      newest = $(if ($newest) { $newest.ToString('o') } else { $null })
      archived_to = $archiveName
    }
    [void]$keep.Add([pscustomobject]$summary)
    Save-AllMemories -Mems @($keep.ToArray()) -Channel $Channel
    return [pscustomobject]@{ rotated=$true; archived=$archive.Count; kept=$keep.Count; archive=$archiveName; channel=$Channel }
  } catch {
    try { Add-Message -From system -Kind event -Text ("⚠ Memory archive rotation skipped: " + $_.Exception.Message) | Out-Null } catch {}
    return [pscustomobject]@{ rotated=$false; reason='error'; error=$_.Exception.Message }
  }
}

function Invoke-DriverMemoryArchiveRotationForRecall {
  try {
    $channel = $null
    try { if (Get-Command Get-CurrentMemoryChannel -ErrorAction SilentlyContinue) { $channel = Get-CurrentMemoryChannel } } catch {}
    Invoke-DriverMemoryArchiveRotation -Channel $channel | Out-Null
  } catch {}
}

function Get-MemoryRecall {
  param([string]$TaskText = '')
  Invoke-DriverMemoryArchiveRotationForRecall
  if ($script:DriverOriginalGetMemoryRecall) { return (& $script:DriverOriginalGetMemoryRecall -TaskText $TaskText) }
  return ''
}

function Search-ProjectMemory {
  param(
    [string]$Query,
    [string[]]$Kind = @(),
    [string[]]$Trust = @(),
    [string[]]$Status = @('active'),
    [int]$TopK = 0,
    [double]$MinScore = -1,
    [string]$Channel = $null
  )
  Invoke-DriverMemoryArchiveRotationForRecall
  if (-not $script:DriverOriginalSearchProjectMemory) { return @() }
  return @(& $script:DriverOriginalSearchProjectMemory -Query $Query -Kind $Kind -Trust $Trust -Status $Status -TopK $TopK -MinScore $MinScore -Channel $Channel)
}

function Get-DriverRunningBacklogIdSet {
  $set = @{}
  try {
    foreach ($item in @(Get-Backlog)) {
      $status = ([string]$item.status).Trim().ToLowerInvariant()
      if (@('running','working') -contains $status) {
        $id = [string]$item.id
        if (-not [string]::IsNullOrWhiteSpace($id)) { $set[$id] = $true }
      }
    }
  } catch {}
  return $set
}

function Get-DriverBacklogItemsStillRunning {
  param([string[]]$Ids)
  $remaining = New-Object 'System.Collections.Generic.List[string]'
  if (-not $Ids -or @($Ids).Count -eq 0) { return @() }
  $want = @{}
  foreach ($id in @($Ids)) { if (-not [string]::IsNullOrWhiteSpace($id)) { $want[$id] = $true } }
  try {
    foreach ($item in @(Get-Backlog)) {
      $id = [string]$item.id
      if (-not $want.ContainsKey($id)) { continue }
      $status = ([string]$item.status).Trim().ToLowerInvariant()
      if (@('running','working') -contains $status) { [void]$remaining.Add($id) }
    }
  } catch {
    foreach ($id in $want.Keys) { [void]$remaining.Add($id) }
  }
  return @($remaining.ToArray())
}

function Start-BacklogReaperIfDue {
  $retryNow = $false
  if ($script:DriverBacklogReaperRetryDueAt -and (Get-Date) -ge $script:DriverBacklogReaperRetryDueAt) { $retryNow = $true }
  if (-not (Get-Command Invoke-BacklogStateReaper -ErrorAction SilentlyContinue)) { return }
  $recovered = @()
  try {
    $preItems = @(Get-Backlog)
    $hasRunning = @($preItems | Where-Object { @('running','working') -contains ([string]$_.status).Trim().ToLowerInvariant() }).Count
    if ($hasRunning -eq 0 -and -not $retryNow) { return }
    $recovered = @(Invoke-BacklogLocked ({
      $items = @(Get-Backlog)
      $reapState = $null; try { $reapState = Read-State } catch {}
      $r = Invoke-BacklogStateReaper -Items $items -RuntimeState $reapState -HeartbeatMaxAgeSeconds 900
      if (@($r.recovered).Count -gt 0) { Save-Backlog @($r.items); return @($r.recovered) }
      return @()
    }.GetNewClosure()))
  } catch { $recovered = @() }
  foreach ($rec in @($recovered)) {
    try {
      Add-Message -From system -Text ("♻️ Zombie-reaper восстановил задачу " + [string]$rec.id + " (была '" + [string]$rec.from_status + "' без живого владельца) → held; lease освобождён для повторного claim.") -Kind event | Out-Null
    } catch {}
  }
  $candidateIds = @($recovered | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($retryNow -and $script:DriverBacklogReaperRetryIds) { $candidateIds = @($candidateIds + @($script:DriverBacklogReaperRetryIds)) | Select-Object -Unique }
  if (@($candidateIds).Count -eq 0) { return }
  Start-Sleep -Seconds 5
  $stillRunning = @(Get-DriverBacklogItemsStillRunning -Ids $candidateIds)
  if ($stillRunning.Count -eq 0) {
    $script:DriverBacklogReaperRetryDueAt = $null
    $script:DriverBacklogReaperRetryIds = @()
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='zombie-reaper-recovered-verified'; item_ids=@($candidateIds) }) } catch {}
    return
  }
  if ($retryNow) {
    $script:DriverBacklogReaperRetryDueAt = $null
    $script:DriverBacklogReaperRetryIds = @()
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='zombie-reaper-recovery-retry-failed'; item_ids=@($stillRunning) }) } catch {}
    try { Add-Message -From system -Kind event -Text ("⚠ Zombie-reaper retry did not recover item(s) from running/working: " + ((@($stillRunning) | Select-Object -First 4) -join ',')) | Out-Null } catch {}
  } else {
    $script:DriverBacklogReaperRetryDueAt = (Get-Date).AddSeconds(30)
    $script:DriverBacklogReaperRetryIds = @($stillRunning)
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='zombie-reaper-recovery-retry-scheduled'; retry_at=$script:DriverBacklogReaperRetryDueAt.ToUniversalTime().ToString('o'); item_ids=@($stillRunning) }) } catch {}
    try { Add-Message -From system -Kind event -Text ("⚠ Zombie-reaper did not recover item(s) from running/working; retry scheduled in 30s: " + ((@($stillRunning) | Select-Object -First 4) -join ',')) | Out-Null } catch {}
  }
}

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
  foreach ($fn in @('Wait-AgentProcess','Get-PlannerModel','Start-ReplayForStateTask','Sweep-AgentOrphans','Initialize-DriverStartup','Start-DriverMainLoop','Activate-Doctor','Complete-Doctor','Abort-Doctor','Get-TaskRepoRoot','Test-QualityBypassesInDiff','Start-ProjectAcceptanceIfDue','Invoke-ProjectAcceptance','Invoke-VerifySelftestGate','Get-GateRegressionScope','Invoke-GateRegressionSuite','New-TaskManagementSnapshot','Write-TaskManagementShadowRecord','Format-TaskManagementSummary','Get-ApprovedBacklogClaimabilityReport','Get-BacklogClaimabilitySignature','Update-BacklogClaimabilityIdleState','Ensure-BridgeSelfCanaryGateTasks','Invoke-QAAgentScenarioSuite','Invoke-QAAgentPostCommit','Start-BacklogPrioritizerIfDue','ConvertTo-BacklogClaimStringArray','Test-BridgeSelfAdmissionEvidence','Add-FeatureVerifierBrokenBugfixBacklogItems','Invoke-DriverComputerActionFastLane')) {
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
  try {
    $intentProbe = Test-TaskIntent -TaskText 'BROKEN crash'
    $intentTags = @()
    try { $intentTags = @($intentProbe.tags | ForEach-Object { ([string]$_).ToLowerInvariant() }) } catch { $intentTags = @() }
    if (-not $intentProbe -or [string]$intentProbe.fallback_intent -ne 'bugfix' -or (@($intentTags) -notcontains 'bugfix')) {
      [void]$stFail.Add('bugfix intent fallback missed BROKEN/crash short task')
    }
  } catch {
    [void]$stFail.Add('bugfix intent fallback threw: ' + $_.Exception.Message)
  }
  try {
    $validAdmissionProbe = [pscustomobject]@{
      admitted = $true
      mode = 'bridge_self_canary'
      canary_required = $true
      checks = @('powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest','powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1','canary evidence: Invoke-CanaryCycle PASS')
      rollback_plan = 'rollback to previous verified commit if canary/selftest/smoke fails'
    }
    $admitProbe = Test-IdeaBridgeSelfAdmitted -Idea ([pscustomobject]@{ id='selftest-admit'; status='approved'; text='Change driver.ps1'; tags=@('bridge-self'); scope='bridge'; files=@('driver.ps1'); bridge_self_admission=$validAdmissionProbe })
    if (-not ($admitProbe -and [bool]$admitProbe.ok -and [bool]$admitProbe.canary_evidence)) { [void]$stFail.Add('bridge_self_admission canary evidence probe rejected') }
    $deniedAdmissionProbe = [pscustomobject]@{
      admitted = $false
      mode = 'bridge_self_canary'
      canary_required = $true
      checks = @('powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest','powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1','canary evidence: Invoke-CanaryCycle PASS')
      rollback_plan = 'rollback to previous verified commit if canary/selftest/smoke fails'
    }
    $deniedProbe = Test-IdeaBridgeSelfAdmitted -Idea ([pscustomobject]@{ id='selftest-deny'; status='approved'; text='Change driver.ps1'; tags=@('bridge-self'); scope='bridge'; files=@('driver.ps1'); bridge_self_admission=$deniedAdmissionProbe })
    if ($deniedProbe -and [bool]$deniedProbe.ok) { [void]$stFail.Add('bridge_self_admission admitted=false probe accepted') }
    $brokenState = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-feature-verifier-selftest-' + [guid]::NewGuid().ToString('N') + '.json')
    $brokenJson = '{"backlog-curator":{"last_health":"broken","last_verified_at":"2026-06-11T00:00:00Z","scenario_results":[{"scenario":"backlog-add","ok":false,"error":"BROKEN behavior"}]}}'
    try {
      [System.IO.File]::WriteAllText($brokenState, $brokenJson, (New-Object System.Text.UTF8Encoding($false)))
      $dry = Add-FeatureVerifierBrokenBugfixBacklogItems -BridgeRoot $bridgeRoot -StatePath $brokenState -DigestPath (Join-Path $bridgeRoot 'audit\feature-verifier-selftest.md') -ExistingItems @() -DryRun
    } finally {
      try { Remove-Item -LiteralPath $brokenState -Force -ErrorAction SilentlyContinue } catch {}
    }
    $would = @($dry.would_create)
    if (-not ($dry -and [int]$dry.would_create_count -eq 1 -and $would.Count -eq 1 -and [string]$would[0].type -eq 'bugfix' -and [string]$would[0].text -match 'Report:')) {
      [void]$stFail.Add('feature-verifier BROKEN dry-run did not create bugfix report task')
    }
  } catch {
    [void]$stFail.Add('canary/admission or feature-verifier filing probe threw: ' + $_.Exception.Message)
  }
  if ($stFail.Count -gt 0) { foreach ($f in $stFail) { Write-Output ('DRIVER SELFTEST FAIL: ' + $f) }; exit 1 }
  Write-Output 'DRIVER SELFTEST OK'
  exit 0
}


Initialize-DriverStartup
Start-DriverMainLoop
