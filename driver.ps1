# driver.ps1 -- INTERACTIVE bridge: idles, and treats each [USER] chat message as a
# task. Planner (Claude) plans/reviews, Coder (Codex) executes with FULL PC access.
#
# Phase 3 (full): supports per-channel parallel drivers. Pass `-Channel <slug>` and the
# driver hard-pins itself to that channel for its entire process lifetime -- all
# Read-State/Update-State/Add-Message calls route into channels/<slug>/. Supervisor
# spawns one process per non-archived channel.
param([string]$Channel = $null)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
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

$cfg        = Get-BridgeConfig
$claudeExe  = Resolve-ClaudeExe $cfg
$codexExe   = Resolve-CodexExe  $cfg
$workRoot   = [string]$cfg.workRoot
$bridgeRoot = Get-BridgeRoot
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

function Start-ReplayForStateTask {
  param(
    [object]$State,
    [string]$TaskText,
    [string]$ChannelName
  )
  if ($null -eq $State -or [string]::IsNullOrWhiteSpace($TaskText)) { return }
  try {
    $hash = Get-ReplayTaskHash -TaskText $TaskText
    $taskId = [string]$State.current_task_id
    if ([string]::IsNullOrWhiteSpace($taskId) -or -not $taskId.EndsWith("-$hash")) {
      $taskId = New-ReplayTaskId -TaskText $TaskText
      $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $taskId -Force
      Save-ReplayTaskMeta -TaskId $taskId -Meta @{
        task_text      = $TaskText
        started_at     = (Get-Date).ToString('o')
        finished_at    = $null
        status         = 'in_progress'
        channel        = $ChannelName
        turn_count     = 0
        total_cost_usd = 0
      }
      return
    }
    $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $taskId -Force
    $turnCount = 0
    try { $turnCount = [int]$State.task_turn } catch {}
    Save-ReplayTaskMeta -TaskId $taskId -Meta @{
      task_text  = $TaskText
      status     = 'in_progress'
      channel    = $ChannelName
      turn_count = $turnCount
    }
  } catch {
    try { Write-ReplayInternalError ("Start-ReplayForStateTask: " + $_.Exception.Message) } catch {}
  }
}

function Close-ReplayForStateTask {
  param(
    [object]$State,
    [string]$Status = 'done'
  )
  if ($null -eq $State) { return }
  try {
    $taskId = [string]$State.current_task_id
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
      $turnCount = 0
      try { $turnCount = [int]$State.task_turn } catch {}
      Save-ReplayTaskMeta -TaskId $taskId -Meta @{
        finished_at = (Get-Date).ToString('o')
        status      = $Status
        turn_count  = $turnCount
      }
    }
  } catch {
    try { Write-ReplayInternalError ("Close-ReplayForStateTask: " + $_.Exception.Message) } catch {}
  } finally {
    try { $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $null -Force } catch {}
  }
}

function Get-PlannerModel {
  param([string]$TaskText, [string]$Mode)

  $cfgR = $null
  try { $cfgR = Get-BridgeConfig } catch {}
  $pr = $null
  if ($cfgR -and ($cfgR.PSObject.Properties.Name -contains 'plannerRouting')) { $pr = $cfgR.plannerRouting }
  $opusOnLong = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnLongPrompts') -and $null -ne $pr.opusOnLongPrompts) { [bool]$pr.opusOnLongPrompts } else { $false }
  $opusOnDisc = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnDiscuss') -and $null -ne $pr.opusOnDiscuss) { [bool]$pr.opusOnDiscuss } else { $false }
  $opusOnStudy = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnStudy') -and $null -ne $pr.opusOnStudy) { [bool]$pr.opusOnStudy } else { $true }
  $complexKeywords = @('архитектур','рефактор','перераб','redesign','мигр','интеграц','масштаб','overhaul','сложн','многошаг','разбер','исследуй','спроектируй','design','refactor')
  if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusKeywords') -and $pr.opusKeywords) {
    $complexKeywords = @($pr.opusKeywords | ForEach-Object { [string]$_ })
  }
  $text = if ($null -eq $TaskText) { '' } else { [string]$TaskText }

  if ($text -imatch '(^|[^\p{L}\p{N}_])(opus|опус)([^\p{L}\p{N}_]|$)') { return $deepModel }
  if ($text -match '\[\[DEEP-THINK\]\]') { return $deepModel }

  if ($Mode -eq 'study' -and $opusOnStudy) { return $deepModel }
  if ($Mode -eq 'discuss' -and $opusOnDisc) { return $deepModel }

  if ($opusOnLong) {
    $wordCount = ($text -split '\s+' | Where-Object { $_ }).Count
    if ($wordCount -gt 300) { return $deepModel }
  }

  # FIX 2026-05-27 (root-cause): removed numberedSteps + stageWords triggers.
  # Structure of a task spec (numbered points, "wave 1/2/3", "phase A/B") does NOT mean it
  # needs Opus -- it just means it's well-organized. A clear 10-step implementation spec
  # is EASIER for Sonnet, not harder. These triggers were the main reason every "structured"
  # task was getting routed to Opus + discuss-mode + xhigh reasoning, burning prepaid quota.
  # Use opusKeywords (architectural intent) and explicit [[OPUS]] / [[DEEP-THINK]] markers
  # for routing instead.

  foreach ($kw in $complexKeywords) {
    if ($kw -and ($text -imatch [regex]::Escape($kw))) { return $deepModel }
  }

  return $triageModel
}

function Get-FastLaneSettings {
  $out = @{ autoDetect = $false; minChars = 100; embedBatchEnabled = $true }
  try {
    $cfgF = Get-BridgeConfig
    if ($cfgF -and ($cfgF.PSObject.Properties.Name -contains 'fastLane') -and $cfgF.fastLane) {
      $fl = $cfgF.fastLane
      if (($fl.PSObject.Properties.Name -contains 'autoDetect') -and $null -ne $fl.autoDetect) { $out.autoDetect = [bool]$fl.autoDetect }
      if (($fl.PSObject.Properties.Name -contains 'minChars') -and $fl.minChars) { $out.minChars = [int]$fl.minChars }
      if (($fl.PSObject.Properties.Name -contains 'embedBatchEnabled') -and $null -ne $fl.embedBatchEnabled) { $out.embedBatchEnabled = [bool]$fl.embedBatchEnabled }
    }
  } catch {}
  if ([int]$out.minChars -le 0) { $out.minChars = 100 }
  return $out
}

function Get-ChunkingSettings {
  $out = @{ enabled = $true; maxChunksPerTask = 10 }
  try {
    $cfgC = Get-BridgeConfig
    if ($cfgC -and ($cfgC.PSObject.Properties.Name -contains 'chunking') -and $cfgC.chunking) {
      $ch = $cfgC.chunking
      if (($ch.PSObject.Properties.Name -contains 'enabled') -and $null -ne $ch.enabled) { $out.enabled = [bool]$ch.enabled }
      if (($ch.PSObject.Properties.Name -contains 'maxChunksPerTask') -and $ch.maxChunksPerTask) { $out.maxChunksPerTask = [int]$ch.maxChunksPerTask }
    }
  } catch {}
  if ([int]$out.maxChunksPerTask -le 0) { $out.maxChunksPerTask = 10 }
  return $out
}

$Script:CliHelpCache = @{}

function Get-CliHelpText {
  # Cached --help fetcher. Returns lowercase help text (we match
  # case-insensitively) or '' if CLI not resolvable / failed.
  param([string]$Cli)
  if ($Script:CliHelpCache.ContainsKey($Cli)) { return $Script:CliHelpCache[$Cli] }
  $text = ''
  try {
    $cfg = Get-BridgeConfig
    if ($Cli -eq 'claude') {
      $exe = Resolve-ClaudeExe $cfg
      if ($exe -and (Test-Path -LiteralPath $exe)) {
        $text = (& $exe --help 2>$null | Out-String).ToLowerInvariant()
      }
    } elseif ($Cli -eq 'codex') {
      $exe = Resolve-CodexExe $cfg
      if ($exe -and (Test-Path -LiteralPath $exe)) {
        $main = (& $exe --help 2>$null | Out-String)
        $execHelp = (& $exe exec --help 2>$null | Out-String)
        $text = ($main + "`n" + $execHelp).ToLowerInvariant()
      }
    }
  } catch { $text = '' }
  $Script:CliHelpCache[$Cli] = $text
  return $text
}

function Test-CliFlagsInDiff {
  # Deterministic pre-critic check: scan ADDED lines in a git diff for
  # claude.exe / codex.exe invocations and verify every --flag actually
  # exists in the CLI's --help output. Returns @() if clean, or array of
  # @{ cli; flag; sample } describing unknown flags. The 2026-05-27 --cwd
  # incident (the LLM critic approved a non-existent Claude flag) is the
  # reason this guard exists: deterministic checks where the LLM cannot
  # hallucinate. To extend (gemini, deepseek): add a case in Get-CliHelpText
  # and a detection pattern below.
  param([string]$Diff)
  if ([string]::IsNullOrWhiteSpace($Diff)) { return @() }

  $issues = New-Object 'System.Collections.Generic.List[object]'

  # Per-CLI detection: each tuple = @{ name; linePattern; }. linePattern
  # decides whether a diff line is "calling" this CLI.
  $cliDetectors = @(
    @{ name = 'claude'; linePattern = '(?i)claude(?:\.exe)?|Resolve-ClaudeExe|\$claude\b|claudeExe|claudeGlob|Invoke-ParallelClaudeCli' },
    @{ name = 'codex';  linePattern = '(?i)codex(?:\.exe)?|Resolve-CodexExe|\$codex\b|codexExe|Invoke-ParallelCodexCli' }
  )

  $flagRegex = [regex]'(--[A-Za-z][A-Za-z0-9-]+)'

  # Track seen flags per CLI to dedupe; also keep one example line per flag
  $seen = @{}
  foreach ($det in $cliDetectors) { $seen[$det.name] = @{} }

  foreach ($rawLine in @($Diff -split "`r?`n")) {
    # Only ADDED lines (start with single + but not +++ which is the file header).
    if ($rawLine.Length -lt 2 -or $rawLine[0] -ne '+' -or $rawLine[1] -eq '+') { continue }
    $line = $rawLine.Substring(1)

    # Skip comment lines (PowerShell # comments) -- the CLI exe name in a
    # comment is not a real invocation. Be conservative: only skip if the
    # line starts with optional whitespace + '#'.
    if ($line -match '^\s*#') { continue }

    # CSS custom properties look like long CLI flags (`--codex`) in git diffs,
    # but they are not process arguments. Ignore both declarations and var()
    # usages before applying CLI-specific detectors.
    if ($line -match '^\s*--[A-Za-z][A-Za-z0-9-]*\s*:' -or
        $line -match '\bvar\(\s*--[A-Za-z][A-Za-z0-9-]*\s*\)') {
      continue
    }

    foreach ($det in $cliDetectors) {
      if ($line -notmatch $det.linePattern) { continue }
      foreach ($fm in $flagRegex.Matches($line)) {
        $flag = $fm.Groups[1].Value
        if ($seen[$det.name].ContainsKey($flag)) { continue }
        $seen[$det.name][$flag] = $line.Trim()
      }
    }
  }

  foreach ($det in $cliDetectors) {
    if ($seen[$det.name].Count -eq 0) { continue }
    $help = Get-CliHelpText -Cli $det.name
    if ([string]::IsNullOrWhiteSpace($help)) {
      # CLI not resolvable -- skip silently, can't validate.
      continue
    }
    foreach ($flag in $seen[$det.name].Keys) {
      $flagLow = $flag.ToLowerInvariant()
      # Flag must appear in help with a word boundary AFTER it -- followed
      # by space, newline, '<' (for "<arg>"), '=' or end of string. Without
      # this we'd false-pass '--add' when only '--add-dir' exists.
      $needle = [regex]::Escape($flagLow)
      $ok = ($help -match ($needle + '(?:[\s<=,]|$)'))
      if (-not $ok) {
        [void]$issues.Add(@{
          cli    = $det.name
          flag   = $flag
          sample = $seen[$det.name][$flag]
        })
      }
    }
  }

  return @($issues.ToArray())
}

function Test-CoderClaims {
  # Deterministic gate: scan Codex reply for verifiable claims (HTTP status,
  # ParseFile OK assertions, git SHA references) and check each against ground
  # truth (actually call endpoint, actually parse file, actually look up SHA).
  # Returns @{ violations=@(); checks=@() } — mismatches go to violations,
  # confirmed claims to checks. Output is purely informational (synthesized
  # into a system message for the next planner turn) — NEVER blocks the flow.
  # Born from curator-задача 2026-05-27: Codex 3x claimed "backfill для 51"
  # at actual 3/19/35. With this gate, planner would see the discrepancy on
  # the same turn instead of after a 30s LLM verify round.
  # To extend: add new claim-class patterns + verifier blocks below.
  param([string]$Reply, [string]$BridgeRoot)

  $violations = New-Object 'System.Collections.Generic.List[object]'
  $checks = New-Object 'System.Collections.Generic.List[object]'
  $result = @{ violations = @(); checks = @() }
  if ([string]::IsNullOrWhiteSpace($Reply) -or [string]::IsNullOrWhiteSpace($BridgeRoot)) { return $result }

  # --- 1. HTTP status claims ---
  # Patterns: "/api/foo → 200", "GET /api/foo  200", "HTTP 200 from /api/foo".
  # Separator class permits arrows (->, =>, →), pipes, colons, and whitespace.
  # The "+" makes it match the whole " -> " sequence in one shot.
  $httpPatterns = @(
    '(?im)(/api/[A-Za-z0-9_/-]+)(?:[\s\-=→>|:])+(?:HTTP\s+|status\s*[:=]?\s*)?(\d{3})\b',
    '(?im)HTTP\s+(\d{3})\s+(?:from|on|по)?\s*(/api/[A-Za-z0-9_/-]+)',
    '(?im)`?Invoke-WebRequest[^\n]*?(/api/[A-Za-z0-9_/-]+)[^\n]*?(?:StatusCode|статус)\s*[=:]\s*(\d{3})'
  )
  $httpClaims = @{}
  foreach ($pat in $httpPatterns) {
    foreach ($m in [regex]::Matches($Reply, $pat)) {
      # Need to handle pattern with endpoint-first vs status-first
      $g1 = $m.Groups[1].Value; $g2 = $m.Groups[2].Value
      if ($g1 -match '^/api/') { $endpoint = $g1; $status = $g2 }
      else                       { $endpoint = $g2; $status = $g1 }
      $tmpInt = 0
      if (-not [int]::TryParse($status, [ref]$tmpInt)) { continue }
      $key = "$endpoint=$status"
      if ($httpClaims.ContainsKey($key)) { continue }
      $httpClaims[$key] = $true
    }
  }
  if ($httpClaims.Count -gt 0) {
    $auth = $null
    try { $authP = if (Get-Command Get-AuthPath -ErrorAction SilentlyContinue) { Get-AuthPath } else { Join-Path $BridgeRoot 'auth.json' }; $auth = Get-Content $authP -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $basic = ''
    if ($auth) { try { $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($auth.user + ':' + $auth.password)) } catch {} }
    foreach ($key in $httpClaims.Keys) {
      $parts = $key -split '='; $endpoint = $parts[0]; $claimed = [int]$parts[1]
      $url = "http://localhost:8787$endpoint"
      $actualStatus = 0
      try {
        $headers = if ($basic) { @{ Authorization = "Basic $basic" } } else { @{} }
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $actualStatus = [int]$resp.StatusCode
      } catch {
        try { $actualStatus = [int]$_.Exception.Response.StatusCode } catch {}
      }
      if ($actualStatus -eq $claimed) {
        [void]$checks.Add(@{ kind='http-status'; claim="$endpoint → $claimed"; actual="$actualStatus" })
      } else {
        $actualText = if ($actualStatus -gt 0) { "$actualStatus" } else { 'no response' }
        [void]$violations.Add(@{ kind='http-status'; claim="$endpoint → $claimed"; actual=$actualText })
      }
    }
  }

  # --- 2. ParseFile OK claims ---
  # Patterns: "ParseFile lib/foo.ps1 → OK", "ParseFile `lib/foo.ps1`: OK".
  $parseClaims = @{}
  foreach ($m in [regex]::Matches($Reply, '(?im)ParseFile\s+[`"'']*([A-Za-z0-9_./\\-]+\.ps1)[`"'']*\s*(?:[→\->|→]|:)?\s*(?:OK|УСПЕХ|✓|без\s+ошибок)\b')) {
    $f = ($m.Groups[1].Value -replace '\\','/').Trim('"','''','`')
    if (-not $parseClaims.ContainsKey($f)) { $parseClaims[$f] = $true }
  }
  foreach ($f in $parseClaims.Keys) {
    $fullPath = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $BridgeRoot $f }
    if (-not (Test-Path -LiteralPath $fullPath)) {
      [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual='файл не найден' })
      continue
    }
    $pTokens = $null; $pErrs = $null
    try {
      [void][System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$pTokens, [ref]$pErrs)
      if ($pErrs -and $pErrs.Count -gt 0) {
        $first = $pErrs[0]
        [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual="$($pErrs.Count) ошибок (например: " + ([string]$first.Message).Substring(0,[Math]::Min(80,([string]$first.Message).Length)) + ')' })
      } else {
        [void]$checks.Add(@{ kind='parse-file'; claim="$f = OK"; actual='действительно OK' })
      }
    } catch {
      [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual="parse failed: " + $_.Exception.Message })
    }
  }

  # --- 3. Git SHA references ---
  # Patterns: "commit abc1234", "коммит abc1234", "merged abc1234", "HEAD abc1234".
  # Only flag short-hexes adjacent to commit/sha keywords (avoid noise from
  # random hex like file hashes or numbers).
  $shaClaims = @{}
  foreach ($m in [regex]::Matches($Reply, '(?i)(?:commit|коммит|merge[ds]?|HEAD|SHA|hash)\s*[:=]?\s*[`"'']?([0-9a-f]{7,40})[`"'']?\b')) {
    $sha = $m.Groups[1].Value.ToLowerInvariant()
    # Skip all-digit "shas" (e.g. years like "2026")
    if ($sha -match '^\d+$') { continue }
    if (-not $shaClaims.ContainsKey($sha)) { $shaClaims[$sha] = $true }
  }
  foreach ($sha in $shaClaims.Keys) {
    $exists = $false
    try {
      $null = & git -C $BridgeRoot cat-file -e $sha 2>$null
      $exists = ($LASTEXITCODE -eq 0)
    } catch {}
    if ($exists) {
      [void]$checks.Add(@{ kind='git-sha'; claim="commit $sha"; actual='существует' })
    } else {
      [void]$violations.Add(@{ kind='git-sha'; claim="commit $sha"; actual='нет такого объекта в репо' })
    }
  }

  $result.violations = @($violations.ToArray())
  $result.checks = @($checks.ToArray())
  return $result
}

function Test-IsTrivialTask {
  param([string]$TaskText, [int]$MinChars = 0)
  $t = ([string]$TaskText -replace '\[\[FAST\]\]', '').Trim()
  if ($MinChars -le 0) {
    try { $MinChars = [int](Get-FastLaneSettings).minChars } catch { $MinChars = 100 }
  }
  if ($MinChars -le 0) { $MinChars = 100 }
  if ($t.Length -ge $MinChars) { return $false }
  if ($t -match '\[\[REASONING:high\]\]') { return $false }
  if ($t -match '(?m)^#+\s') { return $false }
  if ($t -match '(?m)^\d+\.\s') { return $false }
  if ($t -match '```') { return $false }
  if ($t -match '(?i)(архитектур|разбер|исследу|спроектир|design|refactor|audit)') { return $false }
  if ($t -match '(?i)\b(поправ|обнов|убер|добав|fix|update|remove|add|set|replace|rename)\w*') { return $true }
  return $false
}

function Set-FastLaneFlags {
  param($State, [string]$Reason = '')
  if (-not $State) { return }
  $State | Add-Member -NotePropertyName skip_planner -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName skip_critic -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName skip_reflect -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName fast_lane_reason -NotePropertyValue ([string]$Reason) -Force
}

function Clear-FastLaneFlags {
  param($State, [switch]$PreserveReflectSkip)
  if (-not $State) { return }
  $lastSkip = $false
  try { $lastSkip = [bool]$State.skip_reflect } catch {}
  if ($PreserveReflectSkip) {
    $State | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $lastSkip -Force
  } else {
    $State | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $false -Force
  }
  $State | Add-Member -NotePropertyName skip_planner -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName skip_critic -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName skip_reflect -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName fast_lane_reason -NotePropertyValue '' -Force
}

function Clear-ChunkingState {
  param($State)
  if (-not $State) { return }
  $State | Add-Member -NotePropertyName chunk_progress -NotePropertyValue '' -Force
  $State | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue '' -Force
  $State | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
}
$null = Initialize-Bridge

$script:CuratorLibPath = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog.ps1'
$script:CuratorControlPath = 'C:\Users\rafie\OneDrive\Documents\bridge\control'
$script:CuratorLogPath = Join-Path $script:CuratorControlPath 'curator.log'
$script:CuratorDecisionsPath = Join-Path $script:CuratorControlPath 'curator-decisions.jsonl'
$script:LastAddIdeaPath = Join-Path $script:CuratorControlPath 'last-add-idea.json'
$script:CuratorDecisionLineCount = 0

# ---------- helpers ----------
function Get-ObjectValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) { return $null }
  foreach ($name in @($Names)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    try {
      $prop = $Object.PSObject.Properties[$name]
      if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    } catch {}
  }
  return $null
}

function Normalize-ComparisonText {
  param([string]$Text)
  return (([string]$Text -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Read-JsonFileSafe {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -Depth 20)
  } catch {
    return $null
  }
}

function Resolve-AddIdeaOutcome {
  param(
    $AddResult,
    [string]$IdeaText,
    [string]$From = ''
  )

  $out = [ordered]@{
    itemId  = ''
    deduped = $false
    cosine  = $null
    created = $false
  }

  if ($AddResult -is [string]) {
    $out.itemId = ([string]$AddResult).Trim()
    $out.created = -not [string]::IsNullOrWhiteSpace($out.itemId)
  } elseif ($AddResult) {
    $out.itemId = [string](Get-ObjectValue $AddResult @('itemId','id','existingId','existingItemId'))
    $dedupFlag = Get-ObjectValue $AddResult @('deduped','isDuplicate','duplicate')
    if ($null -ne $dedupFlag) {
      try { $out.deduped = [bool]$dedupFlag } catch {}
    }
    $status = [string](Get-ObjectValue $AddResult @('status','result','action'))
    if (-not $out.deduped -and $status -imatch '^(deduped|duplicate)$') { $out.deduped = $true }
    $createdFlag = Get-ObjectValue $AddResult @('created','isNew','newItemCreated','wasCreated')
    if ($null -ne $createdFlag) {
      try { $out.created = [bool]$createdFlag } catch {}
    }
    $out.cosine = Get-ObjectValue $AddResult @('cosine','similarity','score')
    if (-not $out.created -and -not $out.deduped -and -not [string]::IsNullOrWhiteSpace($out.itemId)) {
      $out.created = $true
    }
  }

  $fallback = Read-JsonFileSafe -Path $script:LastAddIdeaPath
  if ($fallback) {
    $recentEnough = $true
    try {
      $tsRaw = [string](Get-ObjectValue $fallback @('ts','timestamp'))
      if (-not [string]::IsNullOrWhiteSpace($tsRaw)) {
        $ts = [datetime]$tsRaw
        $recentEnough = ([math]::Abs(((Get-Date).ToUniversalTime() - $ts.ToUniversalTime()).TotalSeconds) -le 30)
      }
    } catch {}
    $matchText = $true
    $fallbackText = [string](Get-ObjectValue $fallback @('text','idea','inputText'))
    if (-not [string]::IsNullOrWhiteSpace($fallbackText) -and -not [string]::IsNullOrWhiteSpace($IdeaText)) {
      $matchText = ((Normalize-ComparisonText $fallbackText) -eq (Normalize-ComparisonText $IdeaText))
    }
    $matchFrom = $true
    $fallbackFrom = [string](Get-ObjectValue $fallback @('from','speaker','source'))
    if (-not [string]::IsNullOrWhiteSpace($fallbackFrom) -and -not [string]::IsNullOrWhiteSpace($From)) {
      $matchFrom = ((Normalize-ComparisonText $fallbackFrom) -eq (Normalize-ComparisonText $From))
    }
    if ($recentEnough -and $matchText -and $matchFrom) {
      $fallbackId = [string](Get-ObjectValue $fallback @('itemId','id','existingId','existingItemId'))
      if (-not [string]::IsNullOrWhiteSpace($fallbackId)) { $out.itemId = $fallbackId }
      $fallbackDedup = Get-ObjectValue $fallback @('deduped','isDuplicate','duplicate')
      if ($null -ne $fallbackDedup) {
        try { $out.deduped = [bool]$fallbackDedup } catch {}
      }
      $fallbackAction = [string](Get-ObjectValue $fallback @('status','result','action'))
      if (-not $out.deduped -and $fallbackAction -imatch '^(deduped|duplicate)$') { $out.deduped = $true }
      $fallbackCosine = Get-ObjectValue $fallback @('cosine','similarity','score')
      if ($null -ne $fallbackCosine) { $out.cosine = $fallbackCosine }
      $fallbackCreated = Get-ObjectValue $fallback @('created','isNew','newItemCreated','wasCreated')
      if ($null -ne $fallbackCreated) {
        try { $out.created = [bool]$fallbackCreated } catch {}
      } elseif (-not $out.deduped -and -not [string]::IsNullOrWhiteSpace($out.itemId)) {
        $out.created = $true
      }
    }
  }

  return [pscustomobject]$out
}

# 2026-05-27v6: Start-BacklogCuratorAsync REMOVED.
# Was: dead-code duplicate of lib/backlog.ps1:Start-BacklogCuratorJob with
# `Start-Process -Command $string` (shell-injection risk if ItemId contained
# ';', '`', '$(' or newlines). No callers (grep confirmed). The live code path
# is lib/backlog.ps1:Start-BacklogCuratorJob which uses a temp .ps1 launcher
# (no -Command injection surface). Removal closes the audit P1 finding.

function Get-NewCuratorDecisions {
  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $script:CuratorDecisionsPath)) { return @() }
  $lines = @()
  try { $lines = @(Get-Content -LiteralPath $script:CuratorDecisionsPath -Encoding UTF8) } catch { return @() }
  if ($lines.Count -lt [int]$script:CuratorDecisionLineCount) { $script:CuratorDecisionLineCount = 0 }
  if ($lines.Count -le [int]$script:CuratorDecisionLineCount) {
    $script:CuratorDecisionLineCount = $lines.Count
    return @()
  }
  $start = [int]$script:CuratorDecisionLineCount
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json -Depth 20
      if ($obj) { [void]$items.Add($obj) }
    } catch {}
  }
  $script:CuratorDecisionLineCount = $lines.Count
  return @($items.ToArray())
}

function Publish-CuratorDecisionEvents {
  param([object[]]$Decisions = @())

  foreach ($decision in @($Decisions)) {
    if (-not $decision) { continue }
    $verdict = [string](Get-ObjectValue $decision @('verdict'))
    $action = [string](Get-ObjectValue $decision @('action'))
    $text = [string](Get-ObjectValue $decision @('text','idea','itemText','preview'))
    $reason = [string](Get-ObjectValue $decision @('reason','why'))
    $preview = Get-PushSnippet -Text $text -Max 80

    if ($action -eq 'freshness-skip' -or $action -eq 'freshness-auto-resolved') {
      $skipId = [string](Get-ObjectValue $decision @('item_id','itemId','id','ideaId'))
      $skipSha = [string](Get-ObjectValue $decision @('sha','commit','commitSha'))
      if ($skipSha.Length -gt 7) { $skipSha = $skipSha.Substring(0, 7) }
      if ([string]::IsNullOrWhiteSpace($skipId)) { $skipId = $preview }
      if ([string]::IsNullOrWhiteSpace($skipSha)) { $skipSha = 'unknown' }
      Add-Message -From system -Text "✓ Идея $skipId уже сделана в SHA $skipSha — пропускаю" -Kind event | Out-Null
      continue
    }

    switch ($verdict) {
      'approve' {
        Add-Message -From system -Text "✅ Куратор одобрил: $preview" -Kind event | Out-Null
      }
      'hold' {
        $msg = "⏸ Куратор просит твоё решение: $text"
        if (-not [string]::IsNullOrWhiteSpace($reason)) { $msg += " — $reason" }
        Add-Message -From system -Text $msg -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text $msg } catch {}
      }
      'drop' {
        $msg = "🚫 Куратор отклонил: $text"
        if (-not [string]::IsNullOrWhiteSpace($reason)) { $msg += " — $reason" }
        Add-Message -From system -Text $msg -Kind event | Out-Null
      }
    }
  }
}

function Get-MessageAttachmentPaths {
  param($Message)
  if (-not $Message.PSObject.Properties['attachments'] -or $null -eq $Message.attachments) { return @() }
  $paths = @()
  foreach ($att in @($Message.attachments)) {
    $url = [string]$att.url
    if ([string]::IsNullOrWhiteSpace($url) -or -not $url.StartsWith('/files/')) { continue }
    $storedName = [System.Uri]::UnescapeDataString($url.Substring('/files/'.Length))
    if ([string]::IsNullOrWhiteSpace($storedName)) { continue }
    $paths += [System.IO.Path]::GetFullPath((Join-Path (Get-FilesPath) $storedName))
  }
  return $paths
}

try {
  if (Test-Path -LiteralPath $script:CuratorDecisionsPath) {
    $script:CuratorDecisionLineCount = @(Get-Content -LiteralPath $script:CuratorDecisionsPath -Encoding UTF8).Count
  }
} catch {
  $script:CuratorDecisionLineCount = 0
}

function Start-LibrarianIfDue {
  # Run the memory consolidator detached when idle, gated by HYBRID schedule:
  #   - HARD floor: at least 30 min since the last run (so we don't spam Gemini).
  #   - SOFT ceiling: at least 6h since the last run -> run unconditionally.
  #   - DELTA trigger: >= 5 new memories since the last run -> run early (after the floor).
  # Old "every 24h" was useless during active development (map could be 24h stale while
  # memory grew 50+ entries). User noticed: "карта памяти сутки не обновлялась". 2026-05-26.
  try { $mc = Get-MemoryConfig } catch { return }
  if (-not $mc.enabled) { return }
  $deltaTrigger = 10
  $ceilingHours = 6
  try {
    $cfgLib = Get-BridgeConfig
    if ($cfgLib -and ($cfgLib.PSObject.Properties.Name -contains 'librarian') -and $cfgLib.librarian) {
      if (($cfgLib.librarian.PSObject.Properties.Name -contains 'deltaTriggerCount') -and $cfgLib.librarian.deltaTriggerCount) { $deltaTrigger = [int]$cfgLib.librarian.deltaTriggerCount }
      if (($cfgLib.librarian.PSObject.Properties.Name -contains 'ceilingHours') -and $cfgLib.librarian.ceilingHours) { $ceilingHours = [int]$cfgLib.librarian.ceilingHours }
    }
  } catch {}
  $scope = Get-EffectiveScope
  $marker = Join-Path ([string]$scope.memory_root) 'librarian.last'
  $countMarker = Join-Path ([string]$scope.memory_root) 'librarian.count.last'
  $lastTs = $null
  if (Test-Path $marker) { try { $lastTs = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  if ($lastTs) {
    $age = (Get-Date) - $lastTs
    if ($age -lt [TimeSpan]::FromMinutes(30)) { return }     # hard floor
    if ($age -lt [TimeSpan]::FromHours($ceilingHours)) {
      # within the soft ceiling: only run if enough new memories accumulated
      $lastCount = -1
      if (Test-Path $countMarker) { try { $lastCount = [int]((Get-Content $countMarker -Raw -Encoding UTF8).Trim()) } catch {} }
      $curCount = 0
      try { $curCount = @(Get-AllMemories).Count } catch {}
      if ($lastCount -ge 0 -and ($curCount - $lastCount) -lt $deltaTrigger) { return }
    }
  }
  $lib = Join-Path $bridgeRoot 'librarian.ps1'
  if (-not (Test-Path $lib)) { return }
  # Touch the marker NOW so we don't relaunch every idle tick while it runs.
  try {
    $md = [string]$scope.memory_root
    if (-not (Test-Path $md)) { New-Item -ItemType Directory -Path $md -Force | Out-Null }
    [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try {
    $launch = [pscustomobject]@{ File = $lib }
    $libProc = Invoke-WithChannelEnv -Slug ([string]$scope.slug) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($libProc) {
      $libTicks = 0L; try { $libTicks = (Get-Process -Id $libProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'librarian' -ProcessId $libProc.Id -Ticks $libTicks } catch {}
    }
    Add-Message -From system -Text "🧠 Запущен библиотекарь памяти (консолидация в фоне)." -Kind event | Out-Null
  } catch {}
}

function Test-AuditMaintenanceBusy {
  param([int]$MaxWaitMinutes = 60)
  $auditDir = Join-Path $bridgeRoot 'audit'
  $waitMarker = Join-Path $auditDir 'audit.waiting'
  $lockMarker = Join-Path $auditDir '.audit.lock'
  $freshFor = [TimeSpan]::FromMinutes([Math]::Max(1, $MaxWaitMinutes + 10))

  if (Test-Path -LiteralPath $waitMarker) {
    $waitTs = $null
    try { $waitTs = [datetime]((Get-Content -LiteralPath $waitMarker -Raw -Encoding UTF8).Trim()) } catch {}
    if ($waitTs -and ((Get-Date) - $waitTs) -lt $freshFor) { return $true }
    try { Remove-Item -LiteralPath $waitMarker -Force -ErrorAction SilentlyContinue } catch {}
  }

  if (Test-Path -LiteralPath $lockMarker) {
    $lockPid = 0
    try { $lockPid = [int]((Get-Content -LiteralPath $lockMarker -Raw -Encoding UTF8).Trim()) } catch {}
    if ($lockPid -gt 0) {
      try {
        if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { return $true }
      } catch {}
    }
    try { Remove-Item -LiteralPath $lockMarker -Force -ErrorAction SilentlyContinue } catch {}
  }

  return $false
}

function Start-AuditIfDue {
  # Run the daily bridge audit detached during the configured night window:
  #   - audit.enabled in config.json gates the whole thing.
  #   - current local hour must be inside [windowStartHour..windowEndHour] (wraps midnight if start > end).
  #   - audit/audit.last marker must be older than floorHours (default 20h) so we run ~once/day.
  # The detached audit runner dot-sources lib/common.ps1 + tools/audit.ps1, waits
  # for stable idle, then calls Invoke-BridgeAudit. audit.last is written only by
  # a successful audit; audit.waiting only prevents duplicate waiting processes.
  $auditCfg = $null
  try {
    $cfgA = Get-BridgeConfig
    if ($cfgA -and ($cfgA.PSObject.Properties.Name -contains 'audit') -and $cfgA.audit) { $auditCfg = $cfgA.audit }
  } catch { return }
  if (-not $auditCfg) { return }
  $enabled = if ($null -ne $auditCfg.enabled) { [bool]$auditCfg.enabled } else { $true }
  if (-not $enabled) { return }
  $startH  = if ($null -ne $auditCfg.windowStartHour) { [int]$auditCfg.windowStartHour } else { 1 }
  $endH    = if ($null -ne $auditCfg.windowEndHour)   { [int]$auditCfg.windowEndHour }   else { 6 }
  $floorH  = if ($null -ne $auditCfg.floorHours)      { [int]$auditCfg.floorHours }      else { 20 }
  $maxWait = if ($null -ne $auditCfg.maxWaitMinutes)  { [int]$auditCfg.maxWaitMinutes }  else { 60 }
  if ($startH -lt 0) { $startH = 0 } elseif ($startH -gt 23) { $startH = 23 }
  if ($endH -lt 0) { $endH = 0 } elseif ($endH -gt 23) { $endH = 23 }
  if ($floorH -lt 1) { $floorH = 1 } elseif ($floorH -gt 168) { $floorH = 168 }
  if ($maxWait -lt 1) { $maxWait = 1 } elseif ($maxWait -gt 240) { $maxWait = 240 }
  $hourNow = (Get-Date).Hour
  $inWindow = $false
  if ($startH -le $endH) {
    if ($hourNow -ge $startH -and $hourNow -le $endH) { $inWindow = $true }
  } else {
    # window wraps midnight (e.g. 22..5)
    if ($hourNow -ge $startH -or $hourNow -le $endH) { $inWindow = $true }
  }
  if (-not $inWindow) { return }
  $auditDir = Join-Path $bridgeRoot 'audit'
  $marker   = Join-Path $auditDir 'audit.last'
  $waitMarker = Join-Path $auditDir 'audit.waiting'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($floorH)) { return }
    } catch {}
  }
  $auditScript = Join-Path $bridgeRoot 'tools\audit.ps1'
  if (-not (Test-Path -LiteralPath $auditScript)) { return }
  $auditRunner = Join-Path $bridgeRoot 'tools\audit-runner.ps1'
  if (-not (Test-Path -LiteralPath $auditRunner)) { return }
  if (Test-AuditMaintenanceBusy -MaxWaitMinutes $maxWait) { return }
  $waitMarkerWritten = $false
  try {
    if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($waitMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $waitMarkerWritten = $true
  } catch { return }
  if (-not $waitMarkerWritten) { return }
  $stateFile = $null
  try { $stateFile = Get-StatePath } catch {}
  if ([string]::IsNullOrWhiteSpace($stateFile)) { $stateFile = Join-Path $bridgeRoot 'channels\main\state.json' }
  try {
    $args = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $auditRunner,
      '-BridgePath', $bridgeRoot,
      '-StateFile', $stateFile,
      '-MaxWaitMinutes', [string]$maxWait,
      '-WaitMarker', $waitMarker
    )
    $launch = [pscustomobject]@{ Args = $args; Channel = (Get-EffectiveChannel) }
    $auditProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList $Launch.Args -WindowStyle Hidden -PassThru
    }
    if (-not $auditProc) { throw 'Start-Process did not return an audit process' }
    $auditTicks = 0L
    try { $auditTicks = (Get-Process -Id $auditProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
    try { Register-ChildProcess -Label 'audit' -ProcessId $auditProc.Id -Ticks $auditTicks } catch {}
    Add-Message -From system -Text ("🔍 Запущен аудит моста (фоновое задание, ожидание idle до {0} мин)." -f $maxWait) -Kind event | Out-Null
  } catch {
    try { if (Test-Path -LiteralPath $waitMarker) { Remove-Item -LiteralPath $waitMarker -Force -ErrorAction SilentlyContinue } } catch {}
  }
}

function Start-FeatureVerifierIfDue {
  # 2026-05-28 Phase 4: daily feature verifier. Walks features/registry.json,
  # runs scenarios from each feature's `scenarios` field via tools/scenario.ps1
  # (headless Chrome user-flow tests), records pass/fail to features/state.json
  # + audit/feature-verifier-YYYY-MM-DD.md. Broken features post chat alert.
  $vCfg = $null
  try {
    $cfgF = Get-BridgeConfig
    if ($cfgF -and ($cfgF.PSObject.Properties.Name -contains 'featureVerifier') -and $cfgF.featureVerifier) { $vCfg = $cfgF.featureVerifier }
  } catch {}
  $enabled = if ($vCfg -and $null -ne $vCfg.enabled) { [bool]$vCfg.enabled } else { $true }
  if (-not $enabled) { return }
  $startH = if ($vCfg -and $null -ne $vCfg.windowStartHour) { [int]$vCfg.windowStartHour } else { 2 }
  $endH   = if ($vCfg -and $null -ne $vCfg.windowEndHour)   { [int]$vCfg.windowEndHour }   else { 6 }
  $floorH = if ($vCfg -and $null -ne $vCfg.floorHours)      { [int]$vCfg.floorHours }      else { 20 }
  $hourNow = (Get-Date).Hour
  $inWindow = if ($startH -le $endH) { ($hourNow -ge $startH -and $hourNow -le $endH) } else { ($hourNow -ge $startH -or $hourNow -le $endH) }
  if (-not $inWindow) { return }
  $marker = Join-Path $bridgeRoot 'features\verifier.last'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($floorH)) { return }
    } catch {}
  }
  $verifierScript = Join-Path $bridgeRoot 'tools\feature-verifier.ps1'
  if (-not (Test-Path -LiteralPath $verifierScript)) { return }
  try {
    $vArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifierScript, '-BridgePath', $bridgeRoot)
    $launch = [pscustomobject]@{ Args = $vArgs; Channel = (Get-EffectiveChannel) }
    $vp = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList $Launch.Args -WindowStyle Hidden -PassThru
    }
    if ($vp) {
      $vpTicks = 0L
      try { $vpTicks = (Get-Process -Id $vp.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'feature-verifier' -ProcessId $vp.Id -Ticks $vpTicks } catch {}
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      Add-Message -From system -Text "🩻 Запущен Feature Verifier (проверка сценариев на живом UI)." -Kind event | Out-Null
    }
  } catch {}
}

function Start-ReflectIfDue {
  # Launch idle self-reflection at most once per autonomy.reflectEveryHours, detached.
  $marker = Join-Path $bridgeRoot 'reflect.last'
  try {
    $stSkipReflect = Read-State
    if ([bool]$stSkipReflect.skip_reflect -or [bool]$stSkipReflect.last_task_skip_reflect) {
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      try { Update-State { param($s) $s | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $false -Force } | Out-Null } catch {}
      return
    }
  } catch {}
  $auto = $null
  try { $cfgA = Get-BridgeConfig; if ($cfgA.PSObject.Properties.Name -contains 'autonomy') { $auto = $cfgA.autonomy } } catch { return }
  $enabled = if ($auto -and $null -ne $auto.enabled) { [bool]$auto.enabled } else { $true }
  if (-not $enabled) { return }
  $everyH = if ($auto -and $auto.reflectEveryHours) { [double]$auto.reflectEveryHours } else { 6 }
  if (Test-Path $marker) {
    try {
      $last = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($everyH)) { return }
    } catch {}
  }
  try {
    $cfgReflect = Get-BridgeConfig
    $minSec = 60
    if ($cfgReflect -and ($cfgReflect.PSObject.Properties.Name -contains 'reflect') -and $cfgReflect.reflect) {
      if (($cfgReflect.reflect.PSObject.Properties.Name -contains 'minTaskDurationSec') -and $cfgReflect.reflect.minTaskDurationSec) { $minSec = [int]$cfgReflect.reflect.minTaskDurationSec }
    }
    $stReflect = Read-State
    $totalSec = 0
    try { $totalSec = [int]$stReflect.task_agent_duration_sec } catch {}
    if ($totalSec -le 0) { try { $totalSec = [int]$stReflect.last_task_agent_duration_sec } catch {} }
    if ($totalSec -gt 0 -and $totalSec -lt $minSec) {
      try { Write-Host "[reflect skipped: task duration $totalSec s < $minSec s]" } catch {}
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      return
    }
  } catch {}
  $rf = Join-Path $bridgeRoot 'reflect.ps1'
  if (-not (Test-Path $rf)) { return }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try {
    $launch = [pscustomobject]@{ File = $rf; Channel = (Get-EffectiveChannel) }
    $rfProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($rfProc) {
      $rfTicks = 0L; try { $rfTicks = (Get-Process -Id $rfProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'reflect' -ProcessId $rfProc.Id -Ticks $rfTicks } catch {}
    }
  } catch {}
}

function Start-TechRadarIfDue {
  # Launch weekly tech-radar, detached, no more than once per radarEveryHours (default 168=7d).
  $everyH = 168
  try { $cfgB = Get-BridgeConfig; if ($cfgB.PSObject.Properties.Name -contains 'radarEveryHours') { $everyH = [int]$cfgB.radarEveryHours } } catch {}
  $marker = Join-Path $bridgeRoot 'radar.last'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($everyH)) { return }
    } catch {}
  }
  $rf = Join-Path $bridgeRoot 'techradar.ps1'
  if (-not (Test-Path -LiteralPath $rf)) { return }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try {
    $launch = [pscustomobject]@{ File = $rf; Channel = (Get-EffectiveChannel) }
    $rdProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($rdProc) {
      $rdTicks = 0L; try { $rdTicks = (Get-Process -Id $rdProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'tech-radar' -ProcessId $rdProc.Id -Ticks $rdTicks } catch {}
    }
    Add-Message -From system -Text "📡 Тех-радар запущен в фоне (еженедельный обход Хабра)." -Kind event | Out-Null
  } catch {}
}

function Start-CanaryIfDue {
  try {
    $ccfg = Get-BridgeConfig
    $canaryCfg = $null
    if ($ccfg.PSObject.Properties.Name -contains 'canary') { $canaryCfg = $ccfg.canary }
    if ($canaryCfg -and ($canaryCfg.PSObject.Properties.Name -contains 'enabled') -and -not [bool]$canaryCfg.enabled) { return }

    $ivH = 6.0
    try {
      if ($canaryCfg -and ($canaryCfg.PSObject.Properties.Name -contains 'intervalHours') -and $canaryCfg.intervalHours) {
        $ivH = [double]$canaryCfg.intervalHours
      }
    } catch {}

    $ctlDir = Join-Path $bridgeRoot 'control'
    if (-not (Test-Path -LiteralPath $ctlDir)) { New-Item -ItemType Directory -Path $ctlDir -Force | Out-Null }
    $launchMarker = Join-Path $ctlDir 'canary-launch.last'
    if (Test-Path -LiteralPath $launchMarker) {
      try {
        $lastLaunch = [DateTime]::Parse((Get-Content -LiteralPath $launchMarker -Raw -Encoding UTF8).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if (((Get-Date).ToUniversalTime() - $lastLaunch.ToUniversalTime()).TotalMinutes -lt 30) { return }
      } catch {}
    }

    $lastRun = $null
    $runsPath = Join-Path $ctlDir 'canary-runs.jsonl'
    if (Test-Path -LiteralPath $runsPath) {
      try {
        $lastLine = Get-Content -LiteralPath $runsPath -Tail 1 -Encoding UTF8
        if ($lastLine) {
          $lastObj = $lastLine | ConvertFrom-Json
          if ($lastObj.timestamp) {
            $lastRun = [DateTime]::Parse([string]$lastObj.timestamp, $null, [Globalization.DateTimeStyles]::RoundtripKind)
          }
        }
      } catch {}
    }
    if (-not $lastRun) {
      try {
        $cst = Get-CanaryState
        if ($cst.last_heartbeat_at) {
          $lastRun = [DateTime]::Parse([string]$cst.last_heartbeat_at, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        }
      } catch {}
    }
    if ($lastRun -and (((Get-Date).ToUniversalTime() - $lastRun.ToUniversalTime()).TotalHours -lt $ivH)) { return }

    $canaryScript = Join-Path $PSScriptRoot 'canary.ps1'
    if (-not (Test-Path -LiteralPath $canaryScript)) { return }
    [System.IO.File]::WriteAllText($launchMarker, (Get-Date).ToUniversalTime().ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $launch = [pscustomobject]@{ File = $canaryScript; Channel = (Get-EffectiveChannel) }
    $caProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File)) -WindowStyle Hidden -PassThru
    }
    if ($caProc) {
      $caTicks = 0L; try { $caTicks = (Get-Process -Id $caProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'canary' -ProcessId $caProc.Id -Ticks $caTicks } catch {}
    }
  } catch {}
}

function Get-AutonomyRequireApproval {
  try { return [bool](Get-AutonomySettings).requireApproval } catch { return $false }
}

function Get-LastUserActivityMinutes {
  # Minutes since the last write to conversation.jsonl (mtime = any bridge activity proxy).
  # Faster than parsing messages; captures user, agent, and system writes alike.
  # Fallback: driver start time from state.
  $ts = $null
  try {
    $p = Get-ConversationPath
    if (Test-Path -LiteralPath $p) { $ts = (Get-Item -LiteralPath $p).LastWriteTimeUtc }
  } catch {}
  if (-not $ts) { try { $ts = ([datetime](Read-State).driver_started).ToUniversalTime() } catch {} }
  if (-not $ts) { return 99999 }
  try { return ((Get-Date).ToUniversalTime() - $ts).TotalMinutes } catch { return 99999 }
}

# Detect-StudyMode now lives in lib/study.ps1 (loaded via common.ps1).
# It requires a BOUNDED study command-verb and accepts -IsAutonomous to skip
# backlog tasks. Defining it here would shadow the lib version -> do not re-add.

function Test-AutonomyReady {
  # True if the bridge may START autonomous backlog work right now (reads merged settings).
  $a = $null
  try { $a = Get-AutonomySettings } catch { return $false }
  if (-not $a) { return $false }
  if (-not [bool]$a.enabled) { return $false }
  $quietMin = [double]$a.idleQuietMinutes
  if ((Get-LastUserActivityMinutes) -lt $quietMin) { return $false }
  $cap = [int]$a.maxAutonomousTasksPerDay
  if ($cap -gt 0) {
    $st = Read-State
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $cnt = 0
    if (($st.PSObject.Properties.Name -contains 'autonomous_day') -and ([string]$st.autonomous_day -eq $today)) { $cnt = [int]$st.autonomous_count }
    if ($cnt -ge $cap) { return $false }
  }
  return $true
}

function Get-RecallKeywords {
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return @() }
  return @([regex]::Matches([string]$TaskText, '[\p{L}\p{N}_]{3,}') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
}

function Get-KeywordScore {
  param([string]$Text = '', [object[]]$Keywords = @())
  if ([string]::IsNullOrWhiteSpace($Text) -or -not $Keywords -or $Keywords.Count -eq 0) { return 0 }
  $score = 0
  foreach ($kw in $Keywords) {
    if ($Text -imatch [regex]::Escape([string]$kw)) { $score++ }
  }
  return $score
}

function Get-DecisionsRecall {
  param([string]$TaskText = '')
  $dp = Join-Path $bridgeRoot 'decisions'
  if (-not (Test-Path $dp)) { return '' }
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  $take = if ($keywords.Count -gt 0) { 10 } else { 5 }
  $files = @(Get-ChildItem $dp -Filter '*.md' -File | Sort-Object LastWriteTime -Descending | Select-Object -First $take)
  if ($files.Count -eq 0) { return '' }
  $items = foreach ($f in $files) {
    try { $raw = Get-Content $f.FullName -Raw -Encoding UTF8 } catch { continue }
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    [pscustomobject]@{
      File  = $f
      Raw   = $raw
      Score = Get-KeywordScore -Text $raw -Keywords $keywords
    }
  }
  if (-not $items) { return '' }
  if ($keywords.Count -gt 0) {
    $items = @($items | Sort-Object @{Expression='Score';Descending=$true}, @{Expression={$_.File.LastWriteTime};Descending=$true} | Select-Object -First 5)
  } else {
    $items = @($items | Select-Object -First 5)
  }
  $blocks = foreach ($item in $items) {
    $f = $item.File
    $raw = [string]$item.Raw
    $trimmed = $raw.Trim()
    $snippet = if ($trimmed.Length -gt 400) { $trimmed.Substring(0,400) + '...' } else { $trimmed }
    "[$($f.BaseName)]`n$snippet"
  }
  if (-not $blocks) { return '' }
  return "=== НЕДАВНИЕ ЗАМЕТКИ (decisions/) ===`n" + ($blocks -join "`n---`n")
}

function Get-EvidenceRecall {
  param([string]$TaskText = '')
  $ep = Join-Path $bridgeRoot 'evidence.jsonl'
  if (-not (Test-Path $ep)) { return '' }
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  if ($keywords.Count -eq 0) { return '' }
  try { $lines = @(Get-Content -LiteralPath $ep -Encoding UTF8 -Tail 50) } catch { return '' }
  if ($lines.Count -eq 0) { return '' }
  $items = foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rec = $line | ConvertFrom-Json } catch { continue }
    $haystack = @([string]$rec.source, [string]$rec.summary, [string]$rec.task) -join "`n"
    $score = Get-KeywordScore -Text $haystack -Keywords $keywords
    if ($score -le 0) { continue }
    [pscustomobject]@{
      Score      = $score
      Source     = [string]$rec.source
      Summary    = [string]$rec.summary
      Confidence = [string]$rec.confidence
      Agent      = [string]$rec.agent
    }
  }
  $items = @($items | Sort-Object @{Expression='Score';Descending=$true} | Select-Object -First 5)
  if ($items.Count -eq 0) { return '' }
  $blocks = foreach ($item in $items) {
    "[$($item.Source)] $($item.Summary) (conf: $($item.Confidence), агент: $($item.Agent))"
  }
  return "=== РЕЛЕВАНТНЫЕ EVIDENCE ===`n" + ($blocks -join "`n")
}

function Get-RecurrenceContext {
  # 2026-05-28: detect when current task is likely a RECURRENCE of an earlier
  # complaint (e.g., user said "проблема осталась", "опять мигает"). When detected,
  # we pull recent fix-commits and inject an architectural-review block so the
  # planner explicitly considers OTHER layers instead of patching the same files
  # again. Cheap heuristic, no LLM.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  $markersRegex = '(?i)(\bпроблема\s+(осталась|та\s*же|сохрани)|снова\s+(мига|тормоз|падает|висит|ломается|ломае)|опять|ещё\s+раз|не\s+помог|всё\s+ещё|все\s+ещё|так\s+же|повтор(я|и)?ется|несмотря|не\s+пофиксил|не\s+помогло|по-прежнему)'
  $hasMarkers = [regex]::IsMatch($TaskText, $markersRegex)
  if (-not $hasMarkers) { return '' }
  # Pull recent fix/repair commits to show what was tried.
  $recentFixes = @()
  try {
    $log = & git -C $bridgeRoot log --oneline -30 --since='72 hours ago' 2>$null
    if ($log) {
      $recentFixes = @(([string[]]$log) | Where-Object { $_ -match '^[0-9a-f]+\s+(fix|repair|chore.fix)\b' })
    }
  } catch {}
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  # Score each fix-commit against task keywords; keep top 8.
  $scored = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l in $recentFixes) {
    $score = Get-KeywordScore -Text $l -Keywords $keywords
    if ($score -gt 0) {
      [void]$scored.Add([pscustomobject]@{ score = $score; line = $l })
    }
  }
  $top = @($scored | Sort-Object @{Expression='score';Descending=$true} | Select-Object -First 8)
  # Also figure out which file-areas were touched recently.
  $touchedAreas = @{}
  foreach ($entry in $top) {
    $sha = ($entry.line -split '\s+')[0]
    if (-not $sha) { continue }
    try {
      $files = @(& git -C $bridgeRoot show --name-only --format='' $sha 2>$null | Where-Object { $_ -and ([string]$_).Trim() })
    } catch { $files = @() }
    foreach ($f in $files) {
      $area = ([string]$f).Split('/\')[0]
      if (-not $area) { continue }
      if ($touchedAreas.ContainsKey($area)) { $touchedAreas[$area] = [int]$touchedAreas[$area] + 1 }
      else { $touchedAreas[$area] = 1 }
    }
  }
  $blocks = New-Object 'System.Collections.Generic.List[string]'
  [void]$blocks.Add('🚨 РЕЦИДИВ ДЕТЕКТИРОВАН: текст задачи содержит маркеры повторной жалобы ("снова", "проблема осталась", "не помогло" и т.п.).')
  if ($top.Count -gt 0) {
    [void]$blocks.Add("Релевантные fix-коммиты последних 72ч (по ключевым словам задачи):")
    foreach ($entry in $top) { [void]$blocks.Add("  $($entry.line)") }
    if ($touchedAreas.Count -gt 0) {
      $areaSummary = ($touchedAreas.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true} | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
      [void]$blocks.Add("Слои, где правили: $areaSummary")
    }
  } else {
    [void]$blocks.Add("(Релевантных fix-коммитов в последних 72ч не нашлось по ключевым словам — возможно симптом старый или формулировка другая.)")
  }
  [void]$blocks.Add('')
  [void]$blocks.Add('🧭 ПРАВИЛО ДЛЯ ЭТОЙ ИТЕРАЦИИ:')
  [void]$blocks.Add('1. НЕ начинай сразу с CONTINUE → Codex с правкой того же файла. Если в "Слои, где правили" доминирует один (например web/), вероятный корень в ДРУГОМ слое (server.ps1, lib/, config).')
  [void]$blocks.Add('2. Первым ходом проведи мини-аудит: какие файлы трогали прошлые фиксы (используй Read), какие слои НЕ трогали, и где данные текут через границу слоёв (UI ↔ HTTP ↔ lib ↔ файлы).')
  [void]$blocks.Add('3. ПОПЫТАЙСЯ воспроизвести проблему до фикса: какой именно сценарий приводит к симптому? Без воспроизведения фикс — гадание.')
  [void]$blocks.Add('4. Только после этого выдай CONTINUE с инструкцией Codex, явно указав на ДРУГОЙ слой / иной механизм.')
  return ($blocks -join "`n")
}

function Format-Transcript {
  param([string]$TaskText = '')
  # Compressed context: a rolling summary of older messages + the hot window (full).
  $labels = @{ claude='[PLANNER/Claude]'; codex='[CODER/Codex]'; user='[USER]'; system='[SYSTEM]' }
  $summarizedSeq = [int](Read-State).summarized_seq
  $lines = foreach ($m in (Get-Messages -Since $summarizedSeq)) {
    $line = "$($labels[$m.from]): $($m.text)"
    $attPaths = @(Get-MessageAttachmentPaths $m)
    if ($attPaths.Count -gt 0) { $line += " (вложения: $($attPaths -join '; '))" }
    $line
  }
  $body = ($lines -join "`n`n")
  $summary = Read-Summary
  if ([string]::IsNullOrWhiteSpace($TaskText)) {
    try { $TaskText = [string](Read-State).current_task } catch { $TaskText = '' }
  }
  $decSect = Get-DecisionsRecall -TaskText $TaskText
  $evSect = Get-EvidenceRecall -TaskText $TaskText
  $memSect = ''
  try { $memSect = Get-MemoryRecall -TaskText $TaskText } catch { $memSect = '' }
  $skillSect = ''
  try { $skillSect = Get-SkillRecall -TaskText $TaskText } catch { $skillSect = '' }
  $antiSkillSect = ''
  try { $antiSkillSect = Get-AntiSkillRecall -TaskText $TaskText } catch { $antiSkillSect = '' }
  $codeSect = ''
  try { $codeSect = Get-CodeRecall -Query $TaskText } catch { $codeSect = '' }
  # 2026-05-28: Recurrence detection — if user/task contains "снова/опять/проблема осталась"
  # markers, surface recent fix commits + force planner to consider other layers.
  $recurrenceSect = ''
  try { $recurrenceSect = Get-RecurrenceContext -TaskText $TaskText } catch { $recurrenceSect = '' }
  # 2026-05-28: LLM-classified intent breakdown for the current task. Persisted in
  # state.task_intent at task acceptance; surfaced here so the planner sees the
  # structured decomposition on every turn, not just turn 1. This is what makes
  # "обсуди и сделай" actually trigger discuss-mode + show the subtask list.
  $intentSect = ''
  try {
    if (Get-Command Format-IntentForPrompt -ErrorAction SilentlyContinue) {
      $stIntent = $null
      try { $stIntent = (Read-State).task_intent } catch {}
      if ($stIntent) { $intentSect = Format-IntentForPrompt -Intent $stIntent }
    }
  } catch { $intentSect = '' }
  # 2026-05-28 Phase 2: semantic dedup gate. Surface top-3 most-similar
  # registered features when a non-trivial task arrives, so the planner can
  # decide "extend feature X" vs "create new Y" with eyes open.
  $dedupSect = ''
  try {
    if (Get-Command Test-FeatureSimilarity -ErrorAction SilentlyContinue) {
      $simMatches = $null
      try { $simMatches = Test-FeatureSimilarity -TaskText $TaskText -Threshold 0.7 -TopK 3 } catch { $simMatches = $null }
      if ($simMatches -and @($simMatches).Count -gt 0 -and (Get-Command Format-FeatureSimilarityForPrompt -ErrorAction SilentlyContinue)) {
        $dedupSect = Format-FeatureSimilarityForPrompt -Matches $simMatches
      }
    }
  } catch { $dedupSect = '' }
  $decAppend = if ($decSect) { "`n`n$decSect" } else { '' }
  $evAppend = if ($evSect) { "`n`n$evSect" } else { '' }
  $memAppend = if ($memSect) { "`n`n$memSect" } else { '' }
  $skillAppend = if ($skillSect) { "`n`n$skillSect" } else { '' }
  $antiSkillAppend = if ($antiSkillSect) { "`n`n$antiSkillSect" } else { '' }
  $codeAppend = if ($codeSect) { "`n`n$codeSect" } else { '' }
  $recurrenceAppend = if ($recurrenceSect) { "`n`n$recurrenceSect" } else { '' }
  $intentAppend = if ($intentSect) { "`n`n$intentSect" } else { '' }
  $dedupAppend = if ($dedupSect) { "`n`n$dedupSect" } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    return ("СВОДКА ПРЕДЫДУЩЕГО ДИАЛОГА (сжато, для контекста):`n" + $summary.Trim() + "`n`n=== ПОСЛЕДНИЕ СООБЩЕНИЯ (полностью) ===`n" + $body + $memAppend + $skillAppend + $antiSkillAppend + $codeAppend + $decAppend + $evAppend + $recurrenceAppend + $intentAppend + $dedupAppend)
  }
  return $body + $memAppend + $skillAppend + $antiSkillAppend + $codeAppend + $decAppend + $evAppend + $recurrenceAppend + $intentAppend + $dedupAppend
}

function Get-ActiveProjectBinding {
  $slug = [string]$Channel
  try {
    if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $slug = Normalize-ChannelSlug $slug }
  } catch {}
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      return (Get-ChannelProjectBinding -Slug $slug)
    }
  } catch {}
  return [pscustomobject]@{
    slug                = $slug
    project_root        = $(if ($slug -eq 'main') { $bridgeRoot } else { '' })
    project_type        = $(if ($slug -eq 'main') { 'bridge (self)' } else { '' })
    project_description = ''
    source              = 'driver-fallback'
    ok                  = ($slug -eq 'main')
    error               = $(if ($slug -eq 'main') { '' } else { "Канал '$slug' не привязан к проекту" })
  }
}

function Get-ActiveProjectRoot {
  $binding = Get-ActiveProjectBinding
  if ($binding -and [bool]$binding.ok -and -not [string]::IsNullOrWhiteSpace([string]$binding.project_root)) {
    return [string]$binding.project_root
  }
  return ''
}

function Get-ProjectFocusPromptBlock {
  $binding = Get-ActiveProjectBinding
  $slug = if ($binding -and $binding.slug) { [string]$binding.slug } else { [string]$Channel }
  $root = if ($binding -and $binding.project_root) { [string]$binding.project_root } else { '' }
  $ptype = if ($binding -and $binding.project_type) { [string]$binding.project_type } else { '' }
  $pdesc = if ($binding -and $binding.project_description) { [string]$binding.project_description } else { '' }
  $source = if ($binding -and $binding.source) { [string]$binding.source } else { '' }
  if ([string]::IsNullOrWhiteSpace($root)) { $root = '<не привязан>' }
  if ([string]::IsNullOrWhiteSpace($ptype)) { $ptype = 'не задан' }
  if ([string]::IsNullOrWhiteSpace($pdesc)) { $pdesc = 'не задано' }

  $guard = ''
  if ($slug -ne 'main') {
    $guard = @"

ФОКУС-КАНАЛА:
- Все аудиты, чтение проекта, команды, правки и git-операции относятся к этому проекту.
- НЕ использовать bridge (`$bridgeRoot`) как целевой проект и НЕ менять файлы bridge без прямой просьбы пользователя.
- Если задача явно требует менять bridge из этого канала -- сначала объясни конфликт фокуса и запроси подтверждение.
"@
  } else {
    $guard = @"

ФОКУС-КАНАЛА:
- Канал `main` предназначен для улучшений самого bridge.
"@
  }

  return @"
⚠ АКТИВНЫЙ ПРОЕКТ: $slug
Путь: $root
Тип: $ptype
Описание: $pdesc
Источник привязки: $source$guard
"@
}

function Build-Prompt {
  param([string]$Role, [string]$Task, [string]$Mode = 'normal', [switch]$FastLane)
  $projectBinding = Get-ActiveProjectBinding
  $activeProjectRoot = if ($projectBinding -and [bool]$projectBinding.ok) { [string]$projectBinding.project_root } else { $bridgeRoot }
  if ([string]::IsNullOrWhiteSpace($activeProjectRoot)) { $activeProjectRoot = $bridgeRoot }
  $activeProjectBlock = Get-ProjectFocusPromptBlock
  # Tool Foundry (Ф1): advertise already-built tools so agents REUSE instead of re-requesting.
  $autoToolsLine = ''
  try { $atb = Get-AutoToolsPromptBlock; if (-not [string]::IsNullOrWhiteSpace($atb)) { $autoToolsLine = "`n" + $atb } } catch { $autoToolsLine = '' }
  $channelIsMain = ($projectBinding -and ([string]$projectBinding.slug -eq 'main'))
  $bridgeScopeRules = if ($channelIsMain) {
@'
- САМОУЛУЧШЕНИЕ РАЗРЕШЕНО: тебе МОЖНО улучшать сам мост (файлы в `C:\Users\rafie\OneDrive\Documents\bridge\`: `web\index.html`, `server.ps1`, `driver.ps1`, `lib\common.ps1` и т.п.). СТРОГИЕ ПРАВИЛА БЕЗОПАСНОСТИ (нарушение убьёт мост):
  1) Каждый `.ps1` сохраняй СТРОГО в UTF-8 С BOM. Без BOM PowerShell 5.1 не распарсит русский/эмодзи -> мост умрёт. В PowerShell записать с BOM: `[System.IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($true)))`.
  2) После записи любого `.ps1` ПРОВЕРЬ синтаксис: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('<путь>',[ref]$t,[ref]$e)|Out-Null;if($e.Count){'ERR'}else{'OK'}"`. Применяй, ТОЛЬКО если 'OK'.
  3) Применить правки .ps1-файлов движка: создай файл `bridge\control\restart.flag` -- супервизор перезапустит мост (без UAC). ⛔ СТРОГИЙ ЗАПРЕТ: restart.flag создавать ТОЛЬКО если изменён хотя бы один `.ps1`-файл. Перед созданием флага ОБЯЗАТЕЛЬНО проверь: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" diff --name-only HEAD` -- если в выводе НЕТ ни одного `.ps1`, флаг НЕ создавай (мост перезапустится зря).
  4) После КАЖДОЙ проверенной рабочей правки: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" add -A; git -C "..." commit -m "что сделал"`. Это фиксирует прогресс (watchdog откатит на последний коммит при поломке).
  5) `web\index.html` (UI) можно править свободно -- применяется без перезапуска (просто обнови вкладку). ⛔ НЕ создавай restart.flag ради HTML-правок -- это лишние перезапуски и шум в истории.
  6) НЕ ТРОГАЙ: `watchdog.ps1`, `supervisor.ps1` без крайней нужды, папку `.git`, задачи Планировщика; НЕ убивай процессы моста/watchdog; НЕ удаляй файлы движка.
  7) `secrets.json` содержит API-ключи (Gemini и др.). НИКОГДА не выводи его содержимое в чат и не коммить — он в .gitignore. Память: `lib\memory.ps1` (embeddings+поиск), `librarian.ps1` (ночная консолидация), хранилище `memory\` (gitignored).
'@
  } else {
@"
- BRIDGE-ОГРАНИЧЕНИЕ ДЛЯ ЭТОГО КАНАЛА: bridge (`$bridgeRoot`) является инфраструктурой моста, а НЕ активным проектом. Не читай/не аудируй/не меняй bridge как цель задачи без прямой просьбы пользователя.
"@
  }
  $restartReminder = if ($channelIsMain) {
    "⛔ НАПОМИНАНИЕ: restart.flag -- ТОЛЬКО если изменён `.ps1`-файл. Проверь перед созданием: `git diff --name-only HEAD`. Для `web\index.html` флаг НЕ нужен."
  } else {
    "⛔ НАПОМИНАНИЕ: не создавай `bridge\control\restart.flag` в этом канале. Активный проект находится вне bridge."
  }
  $safetyGateRule = if ($channelIsMain) {
    'SAFETY GATE: перед удалением файлов/папок ВНЕ директории bridge, массовой перезаписью чужих данных, убийством процессов пользователя, внешними сетевыми запросами — напиши строку [[SAFETY: <что именно>]] и НЕ ВЫПОЛНЯЙ. Драйвер остановится и спросит пользователя.'
  } else {
    "SAFETY GATE: перед удалением файлов/папок ВНЕ активного проекта ($activeProjectRoot), массовой перезаписью чужих данных, убийством процессов пользователя, внешними сетевыми запросами — напиши строку [[SAFETY: <что именно>]] и НЕ ВЫПОЛНЯЙ. Драйвер остановится и спросит пользователя."
  }
  if ($FastLane -and $Role -eq 'codex') {
    $taskText = [string]$Task
    $skillSect = ''
    try { $skillSect = Get-SkillRecall -TaskText $taskText } catch { $skillSect = '' }
    $skillAppend = if ($skillSect) { "`n`n$skillSect" } else { '' }
    $autoScopeLine = ''
    try {
      $promptStateFast = Read-State
      if ([string]$promptStateFast.current_backlog_id) {
        $sc = (Get-AutonomySettings).scope
        if ($sc -eq 'projects') { $autoScopeLine = "ОБЛАСТЬ АВТОНОМНОЙ ЗАДАЧИ: сам мост И его проекты под $workRoot. НЕ трогай личные/системные файлы вне проектов." }
        else { $autoScopeLine = "ОБЛАСТЬ АВТОНОМНОЙ ЗАДАЧИ: ТОЛЬКО сам мост ($bridgeRoot). НЕ меняй другие проекты/файлы вне bridge." }
      }
    } catch {}
    return @"
Ты часть автономной пары ИИ-ассистентов с ПОЛНЫМ доступом к компьютеру пользователя (Windows).
Рабочий корень: $activeProjectRoot

$activeProjectBlock

FAST-LANE: Planner пропущен. Выполни пользовательскую задачу напрямую как Codex.

ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:
$taskText
$autoScopeLine

ПРАВИЛА:
- Пиши кратко и ПО-РУССКИ. Технические токены, пути, команды и строку STATUS не переводи.
- Делай только явно нужную маленькую правку; не расширяй scope.
- НЕ трогай `watchdog.ps1`, `supervisor.ps1`, `.git/*`, `secrets.json`, `auth.json`.
- Для `.ps1`: сохраняй UTF-8 с BOM, затем проверь ParseFile. Если менял `.ps1`, запусти smoke перед коммитом.
- Проверяй результат реальным запуском/helper-тестом, затем сделай один commit.
- $restartReminder
$bridgeScopeRules
- В конце дай краткий отчёт и отдельную строку `[[VERIFIED: что проверено | результат]]`.
- Последняя строка должна быть ровно: `STATUS: DONE`.
$skillAppend
"@
  }
  $transcript = Format-Transcript
  $promptState = Read-State
  $dt = [int]$promptState.discuss_turn
  $studyTurn = [int]$promptState.task_turn
  # Scope notice for AUTONOMOUS (backlog) tasks only -- user-typed tasks are never restricted.
  $autoScopeLine = ''
  try {
    if ([string]$promptState.current_backlog_id) {
      $sc = (Get-AutonomySettings).scope
      if ($sc -eq 'projects') { $autoScopeLine = "ОБЛАСТЬ АВТОНОМНОЙ ЗАДАЧИ: сам мост И его проекты под $workRoot. НЕ трогай личные/системные файлы вне проектов." }
      else { $autoScopeLine = "ОБЛАСТЬ АВТОНОМНОЙ ЗАДАЧИ: ТОЛЬКО сам мост ($bridgeRoot). НЕ меняй другие проекты/файлы вне bridge." }
    }
  } catch {}
  $claudeToolHint = if ($Mode -eq 'research') {
    'У тебя есть инструменты Read/Grep/Glob, WebSearch и WebFetch. Bash недоступен.'
  } elseif ($Mode -eq 'study') {
    'У тебя есть инструменты Read/Grep/Glob, WebSearch, WebFetch и Bash.'
  } else {
    'У тебя есть инструменты Read/Grep/Glob и Bash (можешь САМ выполнять команды).'
  }
  $claudeActionBlock = if ($Mode -eq 'research') {
@"
RESEARCH-ХОД -- не выполняй действия в системе и не меняй файлы. Твоя задача: найти/прочитать внешние источники, выделить проверяемые факты, записать evidence-маркеры и дать план следующего action-хода.
"@
  } elseif ($Mode -eq 'study') {
@"
STUDY-ХОД -- выполняй текущую фазу изучения. Можно читать источники и локальные файлы, запускать обратимые команды и создавать итоговый Markdown-отчёт для пользователя.
"@
  } else {
@"
ПРОСТОЕ ДЕЙСТВИЕ -- выполни САМ (без Codex, без Opus), затем `STATUS: DONE`. К простым относятся:
- скриншот экрана; открыть/запустить программу, файл или папку; закрыть/завершить программу или процесс; список процессов/окон; системная информация; одна-две короткие ОБРАТИМЫЕ команды.
- Сделай через Bash и кратко отчитайся по-русски.
- Скриншот: выполни `powershell -NoProfile -ExecutionPolicy Bypass -File "$bridgeRoot\tools\screenshot.ps1"` -- он напечатает путь к PNG; пришли его пользователю отдельной строкой `[[FILE: <путь>]]`.
- Любой файл пользователю -- тем же маркером `[[FILE: <путь>]]`.
"@
  }
  $planPromptBlock = ''
  $taskCheckpointPromptBlock = ''
  try {
    $planPromptText = Format-PlanForPrompt
    if (-not [string]::IsNullOrWhiteSpace($planPromptText)) {
      $planPromptBlock = "`n`nПЛАН-ДОСКА (веди работу по ней):`n$planPromptText"
    } elseif ($Role -eq 'codex') {
      $cpBlock = Get-TaskCheckpointBlock
      if (-not [string]::IsNullOrWhiteSpace($cpBlock)) {
        $taskCheckpointPromptBlock = "`n`n$cpBlock"
      }
    }
  } catch {}
  $shared = @"
Ты часть автономной пары ИИ-ассистентов с ПОЛНЫМ доступом к компьютеру пользователя (Windows).
Рабочий корень: $activeProjectRoot

$activeProjectBlock

ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:
$Task
$autoScopeLine

РОЛИ: ПЛАНИРОВЩИК = Claude (разбор задачи, инструкции, ревью). КОДЕР = Codex (выполнение: файлы, команды, тесты).
ПРАВИЛА:
- Сообщения [USER] -- от пользователя-оператора. ВЫСШИЙ приоритет, выполняй их.
- Пиши кратко и ПО-РУССКИ. Технические токены (пути, команды, код) и строку STATUS не переводи.
- [SYSTEM] -- объективные события от драйвера.
- У вас полный доступ: чтение/запись файлов где угодно и запуск команд. Будь аккуратен с необратимыми действиями (удаление, перезапись, сеть).
- Чтобы прислать файл/скриншот пользователю в чат, помести в ответ отдельной строкой маркер `[[FILE: C:\полный\путь]]` (можно несколько).
- ПАМЯТЬ: заметил устойчивый факт, полезный в будущем (решение, грабли, предпочтение пользователя, важная деталь проекта/настройки)? Добавь отдельной строкой `[[REMEMBER: краткий факт одной фразой]]` — он сразу попадёт в долговременную память (semantic recall). Только то, что реально стоит помнить надолго, без мусора и без повторов уже известного.
- ИНИЦИАТИВА: заметил, как улучшить сам мост или процесс (надёжность, скорость, UX, память, автономия) — НЕ отвлекайся от текущей задачи, просто оставь отдельной строкой `[[IDEA: суть улучшения одной-двумя фразами]]`. Идея уйдёт в бэклог на одобрение пользователю. Это поощряется; будь конкретен (что и зачем), без дублей уже предложенного.
- ДОЛГИЕ ПРОЦЕССЫ: если нужно запустить команду, которая работает ДОЛГО (сборка, тесты, прогон проекта на минуты/часы) — НЕ запускай её обычным образом (будет таймаут хода). Вместо этого оставь отдельной строкой `[[RUNJOB: команда | рабочая_папка]]` (папка необязательна). Мост запустит её в фоне, дождётся завершения БЕЗ таймаута и пришлёт тебе вывод и код выхода отдельным [SYSTEM]-сообщением — тогда продолжишь. Для быстрых команд (секунды) RUNJOB не нужен.
- САМО-ПОСТРОЕННЫЕ ИНСТРУМЕНТЫ (Tool Foundry, заказывает планировщик): нужна ПЕРЕИСПОЛЬЗУЕМАЯ возможность, которой ещё нет (спец-парсер, конвертер, генератор, валидатор)? Закажи её ОТДЕЛЬНОЙ строкой [[NEED-TOOL: имя | контракт-что-делает]] (имя латиницей: буква, далее буквы/цифры/_ и дефис). Мост синтезирует её в песочнице (parse → smoke-тест → критик на ДРУГОЙ модели) и при успехе даст функцию Invoke-<имя> в tools/auto/, доступную сразу и впредь. Разовую мелочь делай напрямую; не дублируй уже существующее.$autoToolsLine
- ПАРАЛЛЕЛЬ (только планировщик): если задачу можно разбить на 2+ НЕЗАВИСИМЫЕ части — есть ДВЕ формы:
  • Для ВНЕШНЕГО репо (другой проект пользователя, НЕ мост): отдельной строкой `[[PARALLEL: <путь_к_репо> || под-задача 1 ;; под-задача 2 ;; под-задача 3]]`. Каждая уйдёт отдельному Codex-воркеру в изолированной копии репо параллельно, результаты вольются обратно (конфликты придут тебе на разрешение). Путь репозитория ОБЯЗАТЕЛЕН (НЕ сам мост — мост этой формой запретит).
  • Для самого моста (bridge): обрамляй каждый поток парой `[[PARALLEL:<id>]] ... [[/PARALLEL:<id>]]`. Внутри блока ОБЯЗАТЕЛЬНЫ две строки:
      `files: путь1, путь2` — файлы которые этот поток правит. НЕ должны пересекаться между потоками.
      `complexity: simple|moderate|complex|architectural` — насколько сложна работа в этом потоке. От этого зависит какой воркер получит задачу (см. ниже).
  Минимум 2 блока. До 6 одновременно (см. `parallel.maxStreams`). Драйвер сам выбирает подходящего воркера из пула.

  ⚙ ПУЛ ВОРКЕРОВ И РОУТИНГ:
  В `config.json -> parallel.workers` лежит список воркеров с метаданными (strength 1-5, speed, cost, domains, model, reasoning). Драйвер для каждого блока подбирает воркера автоматически:
    - `complexity: simple`        → strength ≥ 2 (любой подходит, обычно codex-medium/codex-alt/sonnet)
    - `complexity: moderate`      → strength ≥ 3 (codex-high, codex-medium, codex-alt, codex-specialist, sonnet)
    - `complexity: complex`       → strength ≥ 4 (codex-xhigh, codex-high, opus)
    - `complexity: architectural` → strength ≥ 5 (codex-xhigh, opus — opus открыт только здесь или с `[[OPUS]]`)
  Среди подходящих по силе — выбирается аффинный к домену файлов (.html/.css/.js → sonnet; .ps1/.py/.go → codex-варианты) и самый дешёвый.
  Воркеры не дублируются в одной диспетчеризации (один bucket → один поток), что позволяет до 6 параллельных потоков на разных моделях/ризонингах.

  Можно перебить выбор: добавь в блок строку `worker: <id>` (например `worker: codex-xhigh`) — драйвер возьмёт именно его. Используй редко (auto-route обычно лучше).
  Опционально `[[OPUS]]` в теле блока — разблокирует opus для не-architectural задач, ЕСЛИ реально нужен.

  📦 ВНУТРЕННИЙ ЧАНКИНГ ВОРКЕРА:
  Каждый параллельный воркер ВНУТРИ своего потока может разбить работу на этапы через `STATUS: CONTINUE-CHUNK:N/M`. Драйвер автоматически перезапустит того же воркера в том же worktree на следующий чанк с тем же model/reasoning. Используй это знание: если подзадача потока БОЛЬШАЯ (например «сделать рефактор + добавить тесты + обновить доку») — НЕ дроби её на 3 параллельных блока (зависимы). Дай одному воркеру в его теле подсказку: «работа разбивается на 3 этапа — используй CONTINUE-CHUNK». Воркер сам управит. Это сочетает скорость параллели (между потоками) с надёжностью чанкинга (внутри потока).

  ⚠ КРИТИЧНО — иначе движок не задетектит:
    1) Финальная отдельная строка ВСЕГО твоего ответа = `STATUS: CONTINUE` (драйвер сам поднимет до DONE после успешного merge всех воркеров). НЕ пиши STATUS: DONE.
    2) Внутри блоков `[[PARALLEL:N]]...[[/PARALLEL:N]]` лежит ПРОМПТ ВОРКЕРА (что он должен сделать). НЕ ставь там `STATUS: ...` и `[[VERIFIED:]]` — это сгенерит сам воркер.
    3) Открывающий `[[PARALLEL:N]]` И закрывающий `[[/PARALLEL:N]]` ОБА ОБЯЗАТЕЛЬНЫ, id совпадают.

  ПРИМЕР правильного ответа (3 потока, разная сложность → разные воркеры авто):
  ```
  Разбиваю на 3 потока. Файлы не пересекаются.

  [[PARALLEL:A]]
  files: server.ps1
  complexity: complex
  Добавь GET-эндпоинт /api/foo с агрегацией из 3 файлов state. Тест HTTP 200 + latency. Коммить в свою ветку.
  [[/PARALLEL:A]]

  [[PARALLEL:B]]
  files: web/index.html
  complexity: moderate
  Добавь в правый верхний угол span id="fooBadge" — зелёная точка, polling /api/foo. ui_audit -RequireId fooBadge desktop+mobile.
  [[/PARALLEL:B]]

  [[PARALLEL:C]]
  files: docs/foo.md
  complexity: simple
  Создай 1-страничный README про /api/foo: что возвращает, пример вызова.
  [[/PARALLEL:C]]

  STATUS: CONTINUE
  ```
  В этом примере: A → codex-high/xhigh (complex+backend), B → claude-sonnet (moderate+frontend), C → codex-medium или alt (simple+docs).
$bridgeScopeRules

ДИАЛОГ:
$transcript$taskCheckpointPromptBlock$planPromptBlock
"@
  if ($Role -eq 'claude') {
    $claudeBase = @"

ТВОЙ ХОД как ПЛАНИРОВЩИК (Claude). $claudeToolHint Реши, как действовать, и заверши ответ ПОСЛЕДНЕЙ отдельной строкой -- только маркер STATUS.

$claudeActionBlock

Маркеры:
- STATUS: DONE -- сделано (в т.ч. ты сам выполнил простое действие выше); либо работа/обсуждение завершены -- тогда дай ИТОГ (для обсуждения -- чёткое заключение).
- STATUS: CHAT -- только ответить/спросить пользователя, без действий и без Codex (вопрос, объяснение, уточнение).
- STATUS: CONTINUE -- СЛОЖНОЕ -> Codex: написание/правка кода, многошаговое, сборка фич, итерации с тестами, рефакторинг, рискованное/необратимое в больших масштабах. Дай Codex конкретную инструкцию (что, где, критерий готовности).
- STATUS: DISCUSS -- разобрать ИДЕЮ вместе с Codex (без правок): поставь ему тезис/вопрос.
- STATUS: RESEARCH -- нужен отдельный web-ход Claude: поиск/чтение внешних источников без Bash. Дай краткую причину, особенно если это второй research-ход по задаче.
- Codex может вернуть STATUS: CONTINUE-CHUNK:N/M -- это знак, что многоэтапная задача продолжается следующим этапом без участия Claude. Драйвер сам удержит ход за Codex, ты не обязан реагировать.

🔁 ПРАВИЛО CODER-DELEGATION (КРИТИЧНО): если задача потребовала изменения файлов в репо (`.ps1`/`.html`/`.css`/`.js`/`config.json`/новые файлы) — это работа Codex, НЕ твоя. Сам внести правку ОК ТОЛЬКО для тривиального (1-2 строки, явный фикс опечатки/одного флага). Для остального обязателен STATUS: CONTINUE с конкретной инструкцией Codex'у (что менять, где, критерий приёмки). Это потому, что: (а) у Codex code-fine-tuning, он лучше пишет; (б) критик ревьюит ТОЛЬКО Codex-diff, твой собственный diff проходит без независимой проверки — слепое пятно; (в) Opus-турны дорогие, их надо тратить на планирование, а не на редактирование. Гейт в драйвере: если ты выдал STATUS: DONE с file-правками БЕЗ привлечения Codex — DONE отклоняется и тебя заворачивают на CONTINUE. Это уже случалось (probe 2: Opus сам поправил web/index.html, обошёл критика).
ПРАВИЛО ВЕРИФИКАЦИИ: перед STATUS: DONE -- если Codex выполнял действия (файлы/команды), ты ОБЯЗАН явно показать результат проверки и добавить отдельной строкой маркер [[VERIFIED: что проверено | результат]]. Без [[VERIFIED:]] DONE отклоняется.
⚠ ПОВЕДЕНЧЕСКАЯ ПРОВЕРКА (КРИТИЧНО): если задача создала ИСПОЛНЯЕМОЕ (скрипт, функцию, фичу, которая производит вывод) — diff или содержимое файла НЕ считается проверкой. ОБЯЗАТЕЛЬНО ЗАПУСТИ это на реальном/тестовом входе и покажи ФАКТИЧЕСКИЙ вывод, и убедись, что вывод осмысленный и отвечает критериям задачи (не «код выглядит правильно», а «запустил — работает и даёт верный результат»). Для исполняемых задач DONE без реального запуска запрещён. Урок: тех-радар в diff «выглядел нормально», но при запуске выдавал мусор (заголовки = XmlElement) — потому что его никто не ЗАПУСТИЛ и не посмотрел вывод.
🌐 ПРОВЕРКА API/UI (КРИТИЧНО):
- API-эндпоинт: [[VERIFIED:]] ОБЯЗАН включать РЕАЛЬНЫЙ вызов эндпоинта по HTTP (Invoke-WebRequest на http://localhost:8787/api/... с авторизацией из auth.json) с кодом 200 И быстрым непустым ответом. Запуск только внутренней функции в изоляции НЕ считается. Урок: /api/radar OOM-ронял сервер именно на HTTP-вызове, в изоляции функция работала за 100мс.
- UI/HTML/CSS/JS: [[VERIFIED:]] ОБЯЗАН включать прогон `tools\ui_audit.ps1` с проверкой структурных инвариантов (например `-RequireId planToggle -RequireOutside btnsSecondary` — кнопка должна быть НЕ внутри `⋮`-меню) И с проверкой при мобильном вьюпорте (`-Width 390 -Height 844`). "Файл изменён" / "diff выглядит правильно" / "страница грузится" НЕ считается. Урок 2026-05-26: коммит «add plan board to mobile» прошёл, потому что кнопка БЫЛА в DOM — но внутри `btns-secondary` (скрыто за `⋮`); пользователь её не видел. ui_audit.ps1 поймал бы это инвариантом `-RequireOutside btnsSecondary`.

🖼 ПРАВИЛО ВИЗУАЛЬНОЙ БАЗЫ (UI-задачи): до первой правки HTML/CSS/JS — ОБЯЗАТЕЛЬНО сними baseline-скрин в обоих вьюпортах. Используй [[RUNJOB: powershell -NoProfile -ExecutionPolicy Bypass -File tools\visit.ps1 -Url http://localhost:8787 | C:\Users\rafie\OneDrive\Documents\bridge]] (desktop 1920×1080) и [[RUNJOB: powershell -NoProfile -ExecutionPolicy Bypass -File tools\visit.ps1 -Url http://localhost:8787 -Mobile | C:\Users\rafie\OneDrive\Documents\bridge]] (mobile 390×844). Получив пути PNG — отправь планировщику [[FILE: путь]] оба снимка. «Diff выглядит правильно» без визуального снимка не аргумент. Если задача про ВНЕШНИЙ сайт — замени URL в RUNJOB на нужный.

📌 ПРАВИЛО «ДУБЛЬ/COVERED»: если задача закрывается как «уже покрыта» существующим коммитом или «дубль» (новые изменения не вносились) — ОБЯЗАТЕЛЬНА отдельная строка: «COVERED: задача закрыта как дубль [commit <SHA> / <причина>]. Изменений не вносилось.» Без неё STATUS: DONE при нулевых изменениях = нарушение прозрачности (пользователь не видит, что именно было пропущено).

🔀 ПРОВЕРКА ПАРАЛЛЕЛИ НА КАЖДОМ STATUS: CONTINUE (КРИТИЧНО — экономит время):
Раньше планировщик эмитил [[PARALLEL:N]] только на ПЕРВОМ ходе большой задачи. На итерациях (verify-reject, fix-bug, доделать-хвост) — отправлял Codex'у одно последовательное CONTINUE, даже когда фикс трогал 2+ независимых файла. Это пропуск возможности параллелить.
ПЕРЕД каждым STATUS: CONTINUE задай себе вопрос: «инструкция, которую я даю Codex'у, трогает 2+ файла, и они НЕ зависят друг от друга по содержимому?»
- Если ДА (например «фикс баг A в lib/foo.ps1 + добавить тест в tools/test.ps1» — файлы независимы) → разбей на [[PARALLEL:N]] блоки. Даже одну фиксу + один тест можно дать двум разным воркерам параллельно.
- Если НЕТ (всё в один файл, или есть зависимость B-after-A) → обычное последовательное CONTINUE.
Это правило родилось из curator-задачи 2026-05-27: 6 итераций verify-reject подряд, ВСЕ последовательные. Реально 1-2 из них можно было параллелить (fix prompt в lib/backlog.ps1 + revert items в backlog.jsonl — разные файлы, могли идти одновременно).

ПЛАН-ДОСКА: для КРУПНОЙ задачи (несколько эпиков/много шагов) в первом ходе сформируй доску блоком [[PLAN]] ... [[/PLAN]]: строки EPIC/TASK/STEP, deps и критерии готовности. Затем веди работу пошагово; при готовности шага ставь отдельной строкой [[STEP-DONE: <id> | краткий результат]]. Для мелкой задачи план не нужен.

ДИСПАТЧ DAG (Project Foundry, только для канала, ПРИВЯЗАННОГО к отдельному проекту — НЕ к самому bridge): если доска уже создана и у независимых STEP'ов проставлены deps, можешь отдать ВСЮ доску движку строкой [[DISPATCH-DAG]] (или [[DISPATCH-DAG: N]] — ширина параллелизма, по умолчанию из конфига). Движок сам берёт готовые шаги, гоняет их параллельными воркерами в worktree'ах проекта, гейтит каждый (готово + есть коммит) и мёрджит-или-откатывает, волна за волной; статусы шагов на доске обновятся автоматически. Это замена ручного STEP-DONE для проектных задач. Над самим bridge-репозиторием DAG-исполнение запрещено.

ВАЖНО: не путай простое со сложным. Если сомневаешься, либо действие рискованное/необратимое/масштабное -- НЕ делай сам: используй CONTINUE (Codex) или CHAT (спроси пользователя). Пиши по-русски.

⏹ ПРАВИЛО «КРИТЕРИЙ ОСТАНОВКИ»: для любой многошаговой задачи — сформулируй чёткий критерий DONE до начала работы (что конкретно должно работать/вернуть/не сломаться). Для открытых задач вида «делай что считаешь нужным» — первым ходом напиши план (2–4 пункта) с явным критерием завершения. Без критерия остановки — потенциальный бесконечный цикл анализа.

🗣 ПРАВИЛО «ГЛАГОЛ ОБСУЖДЕНИЯ» (КРИТИЧНО): если в тексте задачи (где угодно — в начале, в середине, в секции «обсудить») есть глаголы «обсуди», «обсудим», «обсудите», «посоветуйся», «согласуй(те)», «давайте обсудим», «подумайте вместе», «перед тем как делать обсудите» — это **императивное требование пользователя** услышать мнение Codex'а до реализации. Твой ПЕРВЫЙ ход ОБЯЗАН быть STATUS: DISCUSS с конкретными вопросами Codex'у по дизайну. НЕ «разрешаю сам», НЕ «хватает контекста, запускаю воркеров», НЕ «принимаю решение единолично» — это **нарушение протокола**.

Если ты уверен, что обсуждать действительно нечего и контекста хватает — всё равно сделай STATUS: DISCUSS в формате: «Мой план: [3-5 пунктов]. Codex, есть возражения по дизайну? Согласен с приоритетами? Если у тебя нет добавок — на следующем ходе перейду к реализации.» Это даёт Codex'у возможность возразить или дополнить (и не выглядит как обход пользовательского запроса).

Признак, что правило сработало: на следующий ход driver запустит Codex'а с твоим discuss-промптом, и он либо одобрит, либо предложит правки. Только после его ответа — STATUS: CONTINUE с реализацией.

Урок 2026-05-28: на задаче Phase 1 Feature Registry пользователь явно прописал «ОБСУДИТЬ КОРОТКО: ...», но планировщик ответил «Хватает контекста. Разрешаю design-вопросы и запускаю 3 параллельных потока» — обошёл обсуждение. Пользователь это заметил: «ты дал задачу мосту обсудить, но этого не произошло и вообще кодекс мало используется». Это правило — фикс этой ошибки.

🧭 ПРАВИЛО CROSS-LAYER ДИАГНОСТИКИ (КРИТИЧНО для багов вида «X не работает»):
Если задача описывает СИМПТОМ от пользователя (UI мигает / API возвращает не то / агент завис / медленно / не сохраняется), ДО первой правки кода проверь ВСЕ слои, через которые течёт данные. Не оставайся в файле, где симптом проявился — там почти никогда нет корня.
- UI-симптом → проверь HTTP-эндпоинты, которые этот UI дёргает (читай server.ps1, найди обработчик). Симптом «UI показывает не то» = «либо server вернул не то, либо клиент неправильно отрендерил». Если сервер 200 + правильный JSON — корень в клиенте. Если сервер 200 + НЕправильный JSON — корень в сервере.
- API-симптом → проверь PowerShell-функцию, что её обслуживает (Get-X, Save-Y в lib/*.ps1), + её зависимости (Get-PinnedChannel, Read-State, файловая система).
- Driver-симптом (агент не отвечает / зацикливается) → проверь Wait-AgentProcess, Read-AgentOutput, потом сами CLI-аргументы агента (claude/codex), потом сам promp-stage.
- Memory/State-симптом (что-то не сохранилось) → проверь Update-State (lock contention?), Write-AtomicFile (OneDrive sync race?), формат файла (BOM?).
Дешёвый чек: посчитай, сколько слоёв есть между жалобой пользователя и местом в коде, на которое ты смотришь. Если >=2 → значит ты не на нижнем этаже. Спустись.

🚩 ПРАВИЛО «ВТОРОЙ И ТРЕТИЙ РАЗ»: если в истории канала есть СХОЖАЯ жалоба пользователя 2-3 раза подряд (по семантике, не по дословному совпадению) — это сильный сигнал, что прошлые фиксы патчили симптом. На этой итерации:
- ЗАПРЕТИ себе править те же файлы, что в прошлый раз — корень почти наверняка где-то ещё.
- В первом ходе сделай мини-аудит: какие коммиты были на эту тему, что они меняли, в каких слоях. Если все фиксы в одном слое (например все 4 в web/index.html) — следующий должен быть в ДРУГОМ слое (server / lib / config).
- Подели задачу: «исследование архитектуры» (без правок) → «доказательство корня» (минимальное воспроизведение) → «фикс именно корня». Не торопись сразу в Codex.
"@
    if ($Mode -eq 'research') {
      $researchNote = "`n`nРЕЖИМ RESEARCH: ищи, читай внешние источники, анализируй. ЗАПРЕЩЕНО запускать Bash/изменять файлы.`nОБЯЗАТЕЛЬНО в этом ходе: дай хотя бы 1 маркер [[EVIDENCE: url | краткий тезис | high|med|low]].`nЗатем напиши STATUS: CONTINUE с планом для Codex (или STATUS: DONE если задача только исследовательская)."
      $suffix = $claudeBase + $researchNote
    } elseif ($Mode -eq 'discuss') {
      $snapState = Read-State
      $discussSnapshot = if ($snapState.discuss_snapshot) { [string]$snapState.discuss_snapshot } else { '' }
      $snapshotBlock = if (-not [string]::IsNullOrWhiteSpace($discussSnapshot)) { "`n`nПРЕДЫДУЩИЙ СНИМОК ОБСУЖДЕНИЯ (пережил сжатие истории; продолжай отсюда):`n$discussSnapshot" } else { '' }
      $convergeNote = if ($dt -ge ($discussMinTurns - 1)) {
        "`n`n🎯 ФАЗА КОНВЕРГЕНЦИИ (ход $dt): хватит исследовать и оппонировать — СФОРМУЛИРУЙ итоговое решение или компромисс с конкретикой. Заполни «Решение:» и «Риски:», доведи «Открыто:» до «нет». Не тяни до потолка — сходитесь к решению."
      } else {
        "`n`nФаза исследования/оппозиции (ход $dt): разбери варианты и риски; к ходу $($discussMinTurns - 1) перейдёшь к конвергенции."
      }
      $discussNote = "`n`nРЕЖИМ ОБСУЖДЕНИЯ (ход $dt, минимум $discussMinTurns, максимум $discussMaxTurns). Цель — НЕ спорить, а СОЙТИСЬ к решению; ты ведёшь обсуждение к синтезу.`nКаждый ход ЗАКАНЧИВАЙ блоком состояния — ровно эти строки с этими префиксами (для машинного парсинга):`nТип: <idea|architecture|implementation>`nСогласовано: <что уже принято обеими сторонами; это не переоткрывается>`nОткрыто: <нерешённые вопросы; если их нет — напиши «нет»>`nРешение: <текущий консолидированный вариант>`nРиски: <ключевые риски и как смягчаем>`nЕсли Тип=architecture или implementation: обязателен пункт «План реализации:» — конкретные файлы/шаги/критерии готовности.`nЯвно принимай сильные пункты Codex, не пересказывай без нужды; спорь только по сути нерешённого.`nSTATUS: DONE разрешён, когда ходов >= $discussMinTurns И «Открыто:» пусто/«нет» И заполнены «Решение:» и «Риски:» — тогда дай ## ИТОГ.`nЕсли discuss закрывается БЕЗ передачи кодеру (DONE, но не было CONTINUE→Codex, нет [[FILE:]] и нет коммита по этой задаче) — в ## ИТОГЕ ОБЯЗАТЕЛЬНА отдельная строка: ``DISCUSS-ONLY: код не написан. Причина: <короткое почему>. Идея в бэклоге: <id или нет>``. Иначе пользователь решит «обсудили и сделали», а в коде ничего нет (это уже случалось — задача c5a256c8).`nSTATUS: CONTINUE разрешён в конце discuss, если Тип=architecture/implementation И есть непустой «План реализации:».`nИначе — STATUS: DISCUSS.$convergeNote$snapshotBlock"
      $suffix = $claudeBase + $discussNote
    } elseif ($Mode -eq 'study') {
      $subtype = [string]$promptState.study_subtype
      $phase   = [string]$promptState.study_phase
      $snap    = if ($promptState.study_snapshot) { [string]$promptState.study_snapshot } else { '' }
      $snapBlock = if (-not [string]::IsNullOrWhiteSpace($snap)) { "`n`nСНИМОК ИЗУЧЕНИЯ (пережил сжатие; учитывай как базу):`n$snap" } else { '' }
      $subtypeNote = if ($subtype -eq 'local') {
        "Подтип: study-local. Codex ведёт локальный трек: структура кода, git log, манифесты, точки входа, тесты, grep TODO/FIXME. Ты (Claude) добираешь web-контекст и делаешь синтез."
      } else {
        "Подтип: study-external. Ты (Claude) ведёшь web-исследование. 3 слоя запросов: (a) разведка, (b) глубина, (c) контекст — каждый запрос + ЗАЧЕМ. Факты → [[EVIDENCE:]]. Codex может собрать минимальный пример."
      }
      $forceStudy = if ($studyTurn -ge ($studyMaxTurns - 1)) { "`nВНИМАНИЕ: достигнут последний бюджетный ход study — форсируй синтез сейчас." } else { '' }
      $studyNote = "`n`nРЕЖИМ STUDY (фаза: $phase, ходов: $studyTurn, макс: $studyMaxTurns). $subtypeNote`n`nПоисковые запросы пиши ЯВНО в ответе с пояснением зачем.`nФаза 'plan' → сформулируй план изучения: какие вопросы закрыть и какими источниками.`nФаза 'gather-local'/'gather-web' → собирай проверяемые факты. Для web-фактов обязателен [[EVIDENCE: url | тезис | high|med|low]].`nФаза 'synthesis' → ОБЯЗАТЕЛЕН итоговый Отчёт в [[FILE:]] (Markdown, структура: Назначение · Архитектура · Файлы/точки входа · Как использовать · Зависимости · Риски · Альтернативы · Источники).`nFINDING-маркер для локальных находок: [[FINDING: файл_или_источник | факт]].$forceStudy`n$snapBlock"
      $suffix = $claudeBase + $studyNote
    } else {
      $suffix = $claudeBase
    }
  } elseif ($Mode -eq 'discuss') {
    $codexDiscussPhase = if ($dt -ge ($discussMinTurns - 1)) {
      "🎯 ФАЗА КОНВЕРГЕНЦИИ: предложи КОНКРЕТНЫЙ итог/компромисс, а не только критику. Если согласен — явно заяви критерий завершения."
    } else {
      "Фаза исследования/оппозиции: проверяй на прочность, но готовься к конвергенции."
    }
    $suffix = @"

ТВОЙ ХОД как РЕЦЕНЗЕНТ РЕШЕНИЯ (Codex) — раунд $dt (минимум $discussMinTurns, максимум $discussMaxTurns).
Цель обсуждения — СОЙТИСЬ к рабочему решению, а не спорить. Ты проверяешь решение Claude на прочность и помогаешь его закрыть.
В каждом ответе:
  1. Явно ПРИМИ сильные/верные пункты Claude (назови их) — чтобы они закрылись и не переоткрывались.
  2. Добавляй риск или возражение ТОЛЬКО если оно новое и конкретное (не повторяй уже учтённое в «Согласовано»).
  3. Видишь нерешённый вопрос — назови его коротко, чтобы Claude внёс в «Открыто».
  4. Когда открытых блокеров нет — так и скажи, предложи критерий завершения.
⚠ Ты НЕ обязан возражать ради возражения. Согласие с обоснованием — это нормально и желательно. НЕ переоткрывай согласованное. Обсуждение закрывает Claude.
$codexDiscussPhase
Кратко, конкретно, по-русски. НЕ меняй файлы (читать код/материалы для аргументов — можно).
"@
  } elseif ($Mode -eq 'study') {
    $subtype = [string]$promptState.study_subtype
    $phase = [string]$promptState.study_phase
    $snap = if ($promptState.study_snapshot) { [string]$promptState.study_snapshot } else { '' }
    $snapBlock = if (-not [string]::IsNullOrWhiteSpace($snap)) { "`n`nСНИМОК ИЗУЧЕНИЯ (уже собрано):`n$snap" } else { '' }
    $codexStudyDetail = if ($subtype -eq 'local') {
      "Ведущий агент локального трека — ты. Изучи структуру репозитория: git log --oneline -20, дерево папок, манифесты зависимостей, точки входа, тесты. Проверь, есть ли .git и package.json/pyproject.toml/etc. Если путь не является настоящим репозиторием — сообщи [[STUDY_FALLBACK: external]] в ответе. Используй [[FINDING: файл | факт]] для машинного сбора. Кратко, конкретно."
    } else {
      "Вспомогательная роль. Если нужен минимальный код-пример для проверки понимания — собери его. Иначе кратко проверь практические риски и дополни Claude через [[FINDING: источник | факт]]."
    }
    $suffix = @"

ТВОЙ ХОД как КОДЕР в режиме STUDY (подтип: $subtype, фаза: $phase).
$codexStudyDetail
$snapBlock
"@
  } else {
    $chunkBlock = ''
    try {
      $cp = [string]$promptState.chunk_progress
      if (-not [string]::IsNullOrWhiteSpace($cp)) {
        $cbc = [string]$promptState.chunk_base_commit
        $shortBase = if ($cbc.Length -gt 7) { $cbc.Substring(0,7) } else { $cbc }
        $stageText = "ты только что закрыл чанк $cp"
        $pm = [regex]::Match($cp, '^\s*(\d+)\s*/\s*(\d+)\s*$')
        if ($pm.Success) {
          $prevN = [int]$pm.Groups[1].Value
          $totalM = [int]$pm.Groups[2].Value
          if ($prevN -lt $totalM) {
            $stageText = "ты выполняешь чанк $($prevN + 1) из $totalM. Прошлый чанк ($prevN/$totalM) закрыт"
          } else {
            $stageText = "ты только что закрыл финальный чанк $prevN/$totalM"
          }
        }
        $chunkBlock = "`n`nЭТАП ЗАДАЧИ: $stageText. Предыдущий коммит: $shortBase. Продолжай со следующего этапа. Если вся работа готова -- STATUS: DONE. Если впереди ещё этап -- закоммить его и заверши ответ маркером STATUS: CONTINUE-CHUNK:N/M (N -- номер этого только что завершённого этапа)."
      }
    } catch {}
    $resumeWarningBlock = ''
    if ($studyTurn -gt 0) {
      $resumeWarningBlock = "`n`n⚠ ВОЗОБНОВЛЕНИЕ ЗАДАЧИ: у тебя в репо могут быть незакоммиченные правки от ДРУГОЙ задачи. ДО начала работы выполни: ``git -C '$activeProjectRoot' status --short``. Если найдёшь изменения, НЕ относящиеся к текущей задаче — ЗАКОММИТЬ их ОТДЕЛЬНО (отдельный коммит, отдельная тема) перед тем, как начинать. НЕ смешивай темы разных задач в одном коммите."
    }
    $suffix = @"

ТВОЙ ХОД как КОДЕР (Codex). Выполни последнюю инструкцию ПЛАНИРОВЩИКА и любое сообщение [USER].$resumeWarningBlock
Делай реальные действия (файлы/команды) в рамках задачи. Кратко отчитайся по-русски, что сделал и каков результат.
ПЛАН ЗАДАЧИ: для сложных задач (3+ шага) в первом ответе пиши нумерованный чеклист шагов. Обновляй при каждом ходе: ✅ готово, 🔄 текущий, ⬜ впереди.

МНОГОЭТАПНЫЕ ЗАДАЧИ (опционально): если задача явно требует 3+ независимых коммитов и грозит таймаутом одного хода -- разбей её на этапы. После завершения этапа N из M:
  1. ОБЯЗАТЕЛЬНО сделай git commit по этому этапу.
  2. Заверши ответ ровно строкой STATUS: CONTINUE-CHUNK:N/M (N -- номер только что закрытого этапа, 1-based; M -- общее число этапов).
  3. Драйвер сверит HEAD: если коммит есть, ты получишь следующий ход с тем же current_task и контекстом следующего чанка; если коммита нет -- попросит закоммитить и повторить.
Лимит: 10 чанков на задачу (защита от runaway). Когда всё готово -- обычный STATUS: DONE, и тогда chunk_progress очистится автоматически.
Chunking -- опция, а не обязательство: для тривиальных задач (1 коммит) используй обычный STATUS: DONE.
$chunkBlock

КАЧЕСТВО, А НЕ «ЛИШЬ БЫ РАБОТАЛО» (это важно — на этом уже лажали):
- ПРОВЕРЯЙ СВОЙ ВЫВОД ЗАПУСКОМ: написал скрипт/функцию — САМ запусти и убедись, что вывод осмысленный и верный на РЕАЛЬНОМ примере, а не «код вроде правильный». Сообщать о готовности исполняемого без фактического запуска — нельзя.
- Думай о КОРРЕКТНОСТИ, а не о «счастливом пути»: краевые случаи, пустые/битые данные, кодировки. Сомневаешься в API/парсинге (напр. как достать текст из XML/JSON) — ПРОВЕРЬ на примере, не угадывай.
- Без халтуры: не глуши ошибки пустым catch, не оставляй заглушек/TODO/хардкода вместо логики, не «выглядит правильно» — а «запустил, работает».
- Лучше сделать меньше, но правильно и проверенно, чем «вроде готово» со скрытым багом (его поймает критик/верификация — и задача вернётся к тебе же).

🔢 ПРАВИЛО ЧИСЛЕННЫХ УТВЕРЖДЕНИЙ (КРИТИЧНО — каждый verify-loop вырастает из этого нарушения):
Если в своём STATUS: DONE отчёте ты пишешь ЧИСЛО (например «обработал N items», «X из Y файлов изменены», «50/51 прошли проверку», «merged 3 streams», «backfill для 51 items», «commits=2», «latency 27ms», «memory_count=125») — ОБЯЗАТЕЛЬНО приложи ВЫВОД РЕАЛЬНОЙ КОМАНДЫ, которая это число произвела. Не «я посчитал», не «должно быть N» — а конкретный `Get-Content X | Measure | Lines` / `grep -c pattern X` / `git log --oneline -5` / `Invoke-WebRequest ... | Select StatusCode,Content` с FACTUAL выводом в твоём отчёте.
Шаблон: «Заявление: N=51. Проверка: `<команда>` → `<вывод>` (фактически N=51 ✓)». Если команда показала ДРУГОЕ число — НЕ закрывай DONE, исправь и пере-проверь.
БЕЗ proof'а планировщик RЕЖEКТИТ твой STATUS: DONE и возвращает тебя на доработку (это и есть verify-loop). Каждый отвергнутый DONE = ещё 5-10 минут на ход. ПРОВЕРЯЙ СЕБЯ САМ перед заявлением.
Это правило родилось после curator-задачи 2026-05-27: «backfill всех 51 items» был заявлен 3 раза подряд при фактических 3 / 19 / 35 — каждый цикл = ещё один ход планировщика на проверку.
$safetyGateRule
$restartReminder
"@
  }
  return ($shared + $suffix)
}

function Set-AgentPid([int]$ProcId) { Update-State ({ param($s) $s.agent_pid = $ProcId }.GetNewClosure()) | Out-Null }
function Clear-AgentPid { Update-State { param($s) $s.agent_pid = $null } | Out-Null }

$agentPidsFile = Join-Path $bridgeRoot 'runtime\agent_pids.txt'

function Stop-AgentTree {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try { & taskkill /PID $ProcId /T /F 2>$null | Out-Null } catch {}
}

function Register-AgentPid {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try {
    $dir = Split-Path -Parent $agentPidsFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Record PID + start-time + name. Start-time makes the record uniquely identify THIS
    # process, so a later-recycled PID (e.g. the user's app) can never be mistaken for ours.
    $ticks = 0; $name = ''
    try { $pp = Get-Process -Id $ProcId -ErrorAction SilentlyContinue; if ($pp) { $ticks = $pp.StartTime.Ticks; $name = $pp.ProcessName } } catch {}
    Add-Content -LiteralPath $agentPidsFile -Value ("$ProcId|$ticks|$name") -Encoding UTF8
  } catch {}
}

function Unregister-AgentPid {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try {
    if (-not (Test-Path $agentPidsFile)) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content $agentPidsFile -Encoding UTF8)) {
      $trimmed = ([string]$line).Trim()
      if (-not $trimmed) { continue }
      $linePid = ($trimmed -split '\|')[0]
      if ($linePid -notmatch '^\d+$') { continue }
      if ([int]$linePid -ne $ProcId) { [void]$kept.Add($trimmed) }
    }
    [System.IO.File]::WriteAllLines($agentPidsFile, $kept.ToArray(), $Utf8NoBom)
  } catch {}
}

function Sweep-AgentOrphans {
  # Kill ONLY processes this bridge spawned, verified by PID **and** start-time. A recycled
  # PID now owned by another app (e.g. the user's Codex) has a different start-time -> skipped.
  # Records without a verified start-time are NEVER killed (fail-safe). Format: PID|ticks|name.
  param()
  if (-not (Test-Path $agentPidsFile)) { return }
  try {
    $seen = @{}
    foreach ($line in (Get-Content $agentPidsFile -Encoding UTF8)) {
      $trimmed = ([string]$line).Trim()
      if (-not $trimmed) { continue }
      $parts = $trimmed -split '\|'
      if ($parts[0] -notmatch '^\d+$') { continue }
      $orphanPid = [int]$parts[0]
      $ticks = 0; if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') { $ticks = [long]$parts[1] }
      if ($orphanPid -eq $PID -or $seen.ContainsKey($orphanPid)) { continue }
      $seen[$orphanPid] = $true
      if ($ticks -le 0) { continue }   # no verified start-time -> DO NOT kill (safety)
      try {
        $proc = Get-Process -Id $orphanPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.StartTime.Ticks -eq $ticks) {
          Write-Host "Sweep: убиваю свой орфан PID $orphanPid ($($proc.ProcessName))"
          Stop-AgentTree $orphanPid
        }
      } catch {}
    }
  } catch {}
  try { [System.IO.File]::WriteAllText($agentPidsFile, '', $Utf8NoBom) } catch {}
}

function Wait-AgentProcess {
  # Wait for an agent process up to $TimeoutMs, refreshing the heartbeat every ~5s so a
  # long turn doesn't look "dead" to the watchdog (which else false-positive rolls back).
  # Returns $true if the process exited within the timeout.
  # MsgFile/ErrFile/OutFile: optional temp-file paths; used for 60s telemetry ticks
  # (stagnation observability — no hard abort, data only).
  param($Proc, [int]$TimeoutMs, [string]$MsgFile='', [string]$ErrFile='', [string]$OutFile='')
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $lastTelemetrySec = -1
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    if ($Proc.WaitForExit(5000)) { return $true }
    try { Update-State { param($s) $s.heartbeat=(Get-Date).ToString('o') } | Out-Null } catch {}
    $elapsedSec = [int]$sw.Elapsed.TotalSeconds
    if ($elapsedSec - $lastTelemetrySec -ge 60) {
      $lastTelemetrySec = $elapsedSec
      try {
        $cpuSec = $null
        try { $cpuSec = [math]::Round((Get-Process -Id $Proc.Id -ErrorAction Stop).TotalProcessorTime.TotalSeconds, 2) } catch {}
        $fInfo = [ordered]@{}
        foreach ($pair in @(,@('msgF',$MsgFile),@('errF',$ErrFile),@('outF',$OutFile))) {
          $label = $pair[0]; $fpath = $pair[1]
          if (-not [string]::IsNullOrWhiteSpace($fpath)) {
            $fi = Get-Item $fpath -ErrorAction SilentlyContinue
            $fInfo[$label] = if ($fi) { [ordered]@{ len=[long]$fi.Length; mtime=$fi.LastWriteTime.ToString('o') } } else { [ordered]@{ len=0; mtime=$null } }
          }
        }
        $telem = [ordered]@{ ts=(Get-Date).ToString('o'); elapsed_sec=$elapsedSec; cpu_sec=$cpuSec; files=$fInfo }
        Update-State ({ param($s) $s | Add-Member -NotePropertyName agent_telemetry -NotePropertyValue $telem -Force }.GetNewClosure()) | Out-Null
      } catch {}
    }
  }
  return $Proc.WaitForExit(0)
}

function Get-OtherChannelsAgents { Get-OtherChannelsAgentsImpl }
function Set-CurrentAgent {
  param([string]$Agent)
  Set-CurrentAgentImpl -Agent $Agent
}

function Invoke-Planner {
  param([string]$Prompt, [string]$Model = '', [string]$Mode = 'normal', [switch]$NoFallback)
  if (-not $NoFallback) {
    # Cross-agent fallback: if Claude is busy in another channel and Codex is free in all
    # other channels, delegate this planner turn to Codex with a planner-prefix prompt.
    $others = Get-OtherChannelsAgents
    $claudeBusyElsewhere = $false
    $codexBusyElsewhere = $false
    foreach ($k in $others.Keys) {
      if ($others[$k] -eq 'claude') { $claudeBusyElsewhere = $true }
      if ($others[$k] -eq 'codex')  { $codexBusyElsewhere = $true }
    }
    if ($claudeBusyElsewhere -and -not $codexBusyElsewhere) {
      $busyCh = ($others.GetEnumerator() | Where-Object { $_.Value -eq 'claude' } | Select-Object -First 1).Key
      Add-Message -From system -Text ("🔀 Fallback: Claude занят в канале '" + $busyCh + "' → Codex берёт planner-турн.") -Kind event | Out-Null
      $fallbackPrefix = @"
⚠ FALLBACK MODE: Ты сейчас замещаешь Claude-планировщика (он занят в канале '$busyCh'). Твоя роль — ПЛАНИРОВЩИК, не кодер. Отвечай как обычный планировщик: разбери задачу, дай инструкции/решение, заверши маркером STATUS (DONE / CHAT / CONTINUE / DISCUSS / RESEARCH). НЕ редактируй файлы и не запускай команд. Будь короче обычного — это резервный ход.

ЗАДАЧА ОТ ОПЕРАТОРА:
"@
      $coderRes = Invoke-Coder -Prompt ($fallbackPrefix + "`n" + $Prompt) -Mode 'planner-fallback' -NoFallback
      return [pscustomobject]@{ text=$coderRes.text; status=$coderRes.status; duration=$coderRes.duration; errorType=$coderRes.errorType; fallback='codex_as_planner' }
    }
  }
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "claude_in_$g.txt"; $outF=Join-Path $env:TEMP "claude_out_$g.txt"; $errF=Join-Path $env:TEMP "claude_err_$g.txt"
  # Opus -> maximum thinking budget ('ultrathink' = top tier in Claude Code). They write code.
  $effPrompt = if ($Model -match 'opus') { $Prompt + "`n`nultrathink" } else { $Prompt }
  [System.IO.File]::WriteAllText($inF, $effPrompt, $Utf8NoBom)
  $plannerCwd = Get-ActiveProjectRoot
  if ([string]::IsNullOrWhiteSpace($plannerCwd)) { $plannerCwd = $bridgeRoot }
  $allowedTools = if ($Mode -eq 'advisory') { @('Read','Grep','Glob') }
                  elseif ($Mode -eq 'coder-fallback') { @('Read','Grep','Glob','Bash','Edit','MultiEdit','Write') }
                  elseif ($Mode -eq 'research') { @('Read','Grep','Glob','WebSearch','WebFetch') }
                  elseif ($Mode -eq 'study') { @('Read','Grep','Glob','WebSearch','WebFetch','Bash') }
                  else { @('Read','Grep','Glob','Bash') }
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$plannerCwd,'--allowedTools') + $allowedTools
  if ($Model) { $claudeArgs += @('--model', $Model) }
  $reply = ''
  $claudeTimedOut = $false
  $claudeSilentExit = $false
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $launch = [pscustomobject]@{
      File = $claudeExe
      Args = $claudeArgs
      Cwd  = $plannerCwd
      In   = $inF
      Out  = $outF
      Err  = $errF
      Channel = (Get-EffectiveChannel)
    }
    $p = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath ([string]$Launch.File) -ArgumentList $Launch.Args `
        -WorkingDirectory ([string]$Launch.Cwd) -RedirectStandardInput ([string]$Launch.In) -RedirectStandardOutput ([string]$Launch.Out) -RedirectStandardError ([string]$Launch.Err) -NoNewWindow -PassThru
    }
    $null = $p.Handle; Set-AgentPid $p.Id; Register-AgentPid $p.Id
    Set-CurrentAgent 'claude'
    # Planner cap history: 240s -> 600s (probe 2 ultrathink audit), -> 900s (2026-05-26
    # planner_timeout incident: open-ended multi-channel diagnostic "разберись почему
    # Codex не отвечает в travel-planner" hit 606s on Opus+ultrathink). Now symmetric
    # with coder cap (900s, 4cb5f53). Sonnet finishes long before this cap, no regression
    # for simple tasks; watchdog still catches truly hung drivers via restart_loop guard.
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 900000 -ErrFile $errF -OutFile $outF)) {
      Stop-AgentTree $p.Id
      $replayModel = if ([string]::IsNullOrWhiteSpace($Model)) { 'claude' } else { $Model }
      Add-ReplayRecordForCurrentTask -Role 'planner' -Model $replayModel -Mode $Mode -Prompt $Prompt -Response '' `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'timeout' -ErrorType 'planner_timeout' -Provider 'claude'
      # 2026-05-28: NO longer early-return on timeout — fall through to Codex
      # then Gemini-3-flash fallback ladder below. The old behavior bubbled up
      # 'planner_timeout' which triggered Doctor, which then ran ANOTHER hung
      # claude.exe and timed out again — two 15-min hangs per task. Now we
      # try alternates first.
      $claudeTimedOut = $true
    } elseif (Test-Path $outF) {
      $reply = Get-Content $outF -Raw -Encoding UTF8
    }
  } finally {
    Set-CurrentAgent $null
    if ($p -and $p.Id) { Unregister-AgentPid $p.Id }; Clear-AgentPid
    # Capture process output BEFORE cleanup if reply is empty (diagnostic for silent exits/timeouts).
    # Symmetric to Run-Codex finally (driver.ps1:1748-1763, commit 779761c).
    if ([string]::IsNullOrWhiteSpace($reply)) {
      $se = Get-Content $errF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      $so = Get-Content $outF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if (-not [string]::IsNullOrWhiteSpace($se)) {
        $seTail = if ($se.Length -gt 2000) { '...(truncated, last 2000)' + $se.Substring($se.Length - 2000) } else { $se }
        Add-Message -From system -Text ("⚠ [Claude stderr tail]:`n" + $seTail) -Kind event | Out-Null
      }
      if (-not [string]::IsNullOrWhiteSpace($so)) {
        $soTail = if ($so.Length -gt 2000) { '...(truncated, last 2000)' + $so.Substring($so.Length - 2000) } else { $so }
        Add-Message -From system -Text ("⚠ [Claude stdout tail]:`n" + $soTail) -Kind event | Out-Null
      }
      if ([string]::IsNullOrWhiteSpace($se) -and [string]::IsNullOrWhiteSpace($so)) {
        Add-Message -From system -Text "⚠ [Claude silent exit]: stdout+stderr пусты (планировщик завис без вывода)" -Kind event | Out-Null
        $claudeSilentExit = $true
      }
    }
    Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue
  }
  if ($null -eq $reply) { $reply = '' }
  $replayModel = if ([string]::IsNullOrWhiteSpace($Model)) { 'claude' } else { $Model }

  # === Post-Claude fallback ladder (2026-05-28) =========================
  # If Claude timed out OR returned silent/empty, walk down the ladder:
  #   1. Codex (-Mode planner-fallback, read-only) — has tools, can inspect
  #      the codebase before writing the plan. ~1-3min reliable.
  #   2. gemini-3-flash via Invoke-LLM — text-only reserve, ~30-60s.
  # Both alternates are skipped when -NoFallback is set (e.g. when planner
  # is itself being called as a coder-fallback to avoid recursion).
  $claudeUsable = (-not [string]::IsNullOrWhiteSpace($reply)) -and (-not $claudeTimedOut) -and (-not $claudeSilentExit)
  if ((-not $claudeUsable) -and (-not $NoFallback)) {
    # ---- Ladder step 1: Codex as planner ----
    $reason = if ($claudeTimedOut) { 'timeout (900с)' } elseif ($claudeSilentExit) { 'silent exit' } else { 'пустой ответ' }
    Add-Message -From system -Text ("🔀 Fallback ladder 1/2: Claude — " + $reason + " → Codex берёт planner-турн.") -Kind event | Out-Null
    $fallbackPrefix = @"
⚠ FALLBACK MODE: Ты сейчас замещаешь Claude-планировщика (он завис/silent-exit). Твоя роль — ПЛАНИРОВЩИК, не кодер. Разбери задачу, при необходимости прочитай файлы для контекста, дай инструкции/решение, заверши маркером STATUS (DONE / CHAT / CONTINUE / DISCUSS / RESEARCH). НЕ редактируй файлы и не запускай git-команд. Будь короче обычного — это резервный ход.

ЗАДАЧА ОТ ОПЕРАТОРА:
"@
    try {
      $codexRes = Invoke-Coder -Prompt ($fallbackPrefix + "`n" + $Prompt) -Mode 'planner-fallback' -NoFallback
      if ($codexRes -and -not [string]::IsNullOrWhiteSpace([string]$codexRes.text)) {
        Add-ReplayRecordForCurrentTask -Role 'planner' -Model 'codex' -Mode ($Mode + '+codex-fallback') -Prompt $Prompt -Response ([string]$codexRes.text) `
          -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'ok' -ErrorType $null -Provider 'codex'
        return [pscustomobject]@{
          text = ([string]$codexRes.text).Trim()
          status = 'ok'
          duration = [int]$sw.Elapsed.TotalSeconds
          errorType = $null
          fallback = 'codex'
        }
      }
      Add-Message -From system -Text "⚠ Codex-fallback тоже вернул пусто" -Kind event | Out-Null
    } catch {
      Add-Message -From system -Text ("⚠ Codex-fallback упал: " + $_.Exception.Message) -Kind event | Out-Null
    }

    # ---- Ladder step 2: gemini-3-flash (text-only reserve) ----
    Add-Message -From system -Text "🔀 Fallback ladder 2/2: Codex не справился → gemini-3-flash (резерв)." -Kind event | Out-Null
    try {
      # Ensure Invoke-LLM is in scope (driver.ps1 dot-sources common.ps1 at the
      # top, so it should already be — but be defensive).
      if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
        $llmLib = Join-Path $bridgeRoot 'lib\llm.ps1'
        if (Test-Path -LiteralPath $llmLib) { . $llmLib }
      }
      $geminiPrompt = @"
Ты резервный планировщик автономного моста (Claude+Codex+Gemini). Прошлые две попытки (Claude через claude.exe, потом Codex) не дали ответа.

У тебя НЕТ доступа к файлам — только текст ниже. Выдай короткий план словами, не более 10 шагов. Заверши маркером STATUS: DONE.

ЗАДАЧА:
$Prompt
"@
      $geminiReply = Invoke-LLM -Purpose 'planner-reserve' -Model 'gemini-3-flash' -Prompt $geminiPrompt -TimeoutSec 90 -Temperature 0.2
      if (-not [string]::IsNullOrWhiteSpace([string]$geminiReply)) {
        Add-ReplayRecordForCurrentTask -Role 'planner' -Model 'gemini-3-flash' -Mode ($Mode + '+gemini-reserve') -Prompt $Prompt -Response ([string]$geminiReply) `
          -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'ok' -ErrorType $null -Provider 'gemini'
        return [pscustomobject]@{
          text = ([string]$geminiReply).Trim()
          status = 'ok'
          duration = [int]$sw.Elapsed.TotalSeconds
          errorType = $null
          fallback = 'gemini-3-flash'
        }
      }
      Add-Message -From system -Text "⚠ gemini-3-flash тоже вернул пусто — все три уровня лестницы провалены" -Kind event | Out-Null
    } catch {
      Add-Message -From system -Text ("⚠ gemini-3-flash резерв упал: " + $_.Exception.Message) -Kind event | Out-Null
    }

    # All three failed — return the original Claude failure for Doctor escalation.
    $finalError = if ($claudeTimedOut) { 'planner_timeout' } elseif ($claudeSilentExit) { 'planner_silent_exit' } else { 'planner_empty' }
    return [pscustomobject]@{
      text = ''
      status = 'timeout'
      duration = [int]$sw.Elapsed.TotalSeconds
      errorType = $finalError
      fallback = 'all_exhausted'
    }
  }

  # === Claude success path ===============================================
  Add-ReplayRecordForCurrentTask -Role 'planner' -Model $replayModel -Mode $Mode -Prompt $Prompt -Response $reply `
    -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'ok' -ErrorType $null -Provider 'claude'
  return [pscustomobject]@{ text=$reply.Trim(); status='ok'; duration=[int]$sw.Elapsed.TotalSeconds; errorType=$null }
}

function Get-LastClaudeInstruction {
  try {
    $msgs = @(Get-Messages -Since 0)
    $lastClaude = ($msgs | Where-Object { [string]$_.from -eq 'claude' } | Select-Object -Last 1)
    if ($lastClaude) { return [string]$lastClaude.text }
  } catch {}
  return ''
}

function Get-AllowedCoderRoots {
  # Independent allowlist of filesystem roots a coder turn may operate in.
  # Deliberately does NOT trust the computed $coderCwd -- that is the value being validated.
  # Union of: bridgeRoot (+ sandbox scratch) and the active channel's project_root.
  # Being a superset is intentional: precise per-task write confinement is enforced at the
  # OS level by Codex -s workspace-write (Gate A); this allowlist is a fail-closed tripwire
  # that only fires when cwd is genuinely wild (outside bridge, project, and sandbox).
  $roots = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($bridgeRoot)) {
    $roots.Add($bridgeRoot)
    $roots.Add((Join-Path $bridgeRoot 'sandbox'))
  }
  try {
    $bind = Get-ActiveProjectBinding
    if ($bind -and -not [string]::IsNullOrWhiteSpace([string]$bind.project_root)) { $roots.Add([string]$bind.project_root) }
  } catch {}
  try {
    $scope = Get-EffectiveScope
    if ($scope -and -not [string]::IsNullOrWhiteSpace([string]$scope.project_root)) { $roots.Add([string]$scope.project_root) }
  } catch {}
  return ($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Test-PathInAllowedRoot {
  # Fail-closed containment check: $true only if $Path resolves inside one of $AllowedRoots.
  # Resolves to absolute form first so '..' traversal and relative paths cannot escape.
  param([string]$Path, [string[]]$AllowedRoots)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if (-not $AllowedRoots -or @($AllowedRoots).Count -eq 0) { return $false }
  $full = $null
  try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
  $pathNorm = $full.TrimEnd('\','/')
  $sep = [System.IO.Path]::DirectorySeparatorChar
  foreach ($r in $AllowedRoots) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    $rootFull = $null
    try { $rootFull = [System.IO.Path]::GetFullPath($r) } catch { continue }
    $rootNorm = $rootFull.TrimEnd('\','/')
    if ($pathNorm.Equals($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($pathNorm.StartsWith($rootNorm + $sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($pathNorm.StartsWith($rootNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-CoderSandboxMode {
  # Resolves the Codex CLI sandbox mode passed via -s for a coder turn.
  # Precedence: config 'coder.sandboxMode' (overlaid by settings.json) -> fail-safe default.
  # Default is 'workspace-write' (OS-confines coder writes to its -C cwd / project root) as
  # of Gate A (2026-05-28). The fallback is also 'workspace-write' so a missing/corrupted
  # config fails CLOSED (confined), never open. Operator escape-hatch: set
  # coder.sandboxMode='danger-full-access' in settings.json (gitignored, survives rollback)
  # for a maintenance window; the autonomy loop has no path to self-escalate.
  $valid = @('read-only','workspace-write','danger-full-access')
  $default = 'workspace-write'
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'coder') -and $cfg.coder) {
      $coderCfg = $cfg.coder
      if (($coderCfg.PSObject.Properties.Name -contains 'sandboxMode')) {
        $m = [string]$coderCfg.sandboxMode
        if (-not [string]::IsNullOrWhiteSpace($m) -and ($valid -contains $m)) { return $m }
      }
    }
  } catch {}
  return $default
}

function Get-CoderReasoningEffort {
  param([string]$CoderCwd)
  $st = Read-State
  $mode = if ($st.task_mode) { [string]$st.task_mode } else { 'normal' }
  $crc = 0
  try { $crc = [int]$st.critic_retry_count } catch {}
  $instr = Get-LastClaudeInstruction
  $plen = if ($null -eq $instr) { 0 } else { ([string]$instr).Length }
  if ([bool]$st.skip_planner -and [bool]$st.skip_critic) {
    return [pscustomobject]@{ effort='medium'; plen=$plen; mode=$mode; crc=$crc; wt='fast-lane' }
  }
  if ($instr -match '\[\[REASONING:high\]\]' -or $crc -ge 1) {
    $wtLabel = 'n/a'
    return [pscustomobject]@{ effort='xhigh'; plen=$plen; mode=$mode; crc=$crc; wt=$wtLabel }
  }
  if ($mode -eq 'discuss') {
    return [pscustomobject]@{ effort='high'; plen=$plen; mode=$mode; crc=$crc; wt='discuss-high' }
  }

  $wtClean = $true
  try {
    $lines = @(& git -C $CoderCwd status --porcelain 2>$null)
    foreach ($ln in $lines) {
      if ([string]::IsNullOrWhiteSpace($ln) -or $ln.Length -lt 3) { continue }
      $p = $ln.Substring(3).Trim()
      if ($p -match '^(memory|decisions|control|runtime|dispatcher|channels|snapshots|reports|skills)/') { continue }
      if ($p -match '\.(jsonl|log|tmp)$') { continue }
      if ($p -match '^study-[^/\\]+\.md$') { continue }
      if ($p -match '\.(ps1|psm1|html|css|js|json|md)$') { $wtClean = $false; break }
    }
  } catch {}

  $wtLabel = if ($wtClean) { 'clean' } else { 'dirty' }
  if ($wtClean -and $plen -gt 0 -and $plen -lt 800) {
    return [pscustomobject]@{ effort='medium'; plen=$plen; mode=$mode; crc=$crc; wt=$wtLabel }
  }
  return [pscustomobject]@{ effort='high'; plen=$plen; mode=$mode; crc=$crc; wt=$wtLabel }
}

function Invoke-Coder {
  param([string]$Prompt, [string]$Mode = 'code', [switch]$NoFallback)
  if (-not $NoFallback) {
    # Cross-agent fallback: if Codex is busy in another channel and Claude is free in all
    # other channels, delegate this coder turn to Claude Opus as a real coder fallback.
    $others = Get-OtherChannelsAgents
    $codexBusyElsewhere = $false
    $claudeBusyElsewhere = $false
    foreach ($k in $others.Keys) {
      if ($others[$k] -eq 'codex')  { $codexBusyElsewhere = $true }
      if ($others[$k] -eq 'claude') { $claudeBusyElsewhere = $true }
    }
    if ($codexBusyElsewhere -and -not $claudeBusyElsewhere) {
      $busyCh = ($others.GetEnumerator() | Where-Object { $_.Value -eq 'codex' } | Select-Object -First 1).Key
      Add-Message -From system -Text ("🔀 Fallback: Codex занят в канале '" + $busyCh + "' → Claude Opus берёт coder-турн (реальное выполнение).") -Kind event | Out-Null
      $fallbackPrefix = @"
⚠ FALLBACK MODE: Ты сейчас замещаешь Codex-кодера (он занят в канале '$busyCh'). Выполняй задачу реально: можно читать/редактировать файлы и запускать команды доступными инструментами. Соблюдай все правила безопасности из промпта ниже: SAFETY для опасных действий, RUNJOB для долгих команд, UTF-8 BOM для .ps1, ParseFile/smoke/commit/restart.flag по правилам моста. Не вызывай Codex и не жди его освобождения — ты резервный кодер этого хода. Отчитайся кратко по результату.

ЗАДАЧА:
"@
      $fallbackModel = 'opus'
      try {
        $fallbackCfg = Get-BridgeConfig
        if ($fallbackCfg.deepModel) { $fallbackModel = [string]$fallbackCfg.deepModel }
      } catch {}
      $plannerRes = Invoke-Planner -Prompt ($fallbackPrefix + "`n" + $Prompt) -Model $fallbackModel -Mode 'coder-fallback' -NoFallback
      return [pscustomobject]@{ text=$plannerRes.text; status=$plannerRes.status; duration=$plannerRes.duration; errorType=$plannerRes.errorType; fallback='claude_as_coder' }
    }
  }
  $coderBinding = Get-ActiveProjectBinding
  if ($coderBinding -and ([string]$coderBinding.slug -ne 'main') -and -not [bool]$coderBinding.ok) {
    $reason = [string]$coderBinding.error
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "Канал '$([string]$coderBinding.slug)' не привязан к проекту" }
    return [pscustomobject]@{
      text             = "PREFLIGHT_BLOCKED: $reason"
      status           = 'preflight_blocked'
      duration         = 0
      errorType        = 'preflight_blocked'
      preflightBlocked = $true
      reason           = $reason
    }
  }
  $coderCwd = if ($coderBinding -and [bool]$coderBinding.ok) { [string]$coderBinding.project_root } else { $bridgeRoot }
  if ([string]::IsNullOrWhiteSpace($coderCwd)) { $coderCwd = $bridgeRoot }
  # Path-confinement tripwire (fail-closed): refuse to launch the coder if its working
  # directory is not inside an allowlisted root (bridge / sandbox / bound project). Under
  # normal operation cwd is always one of these; this only fires on a corrupted binding or
  # a path-traversal escape. Defense-in-depth beneath the OS sandbox (Gate A workspace-write).
  $allowedCoderRoots = Get-AllowedCoderRoots
  if (-not (Test-PathInAllowedRoot -Path $coderCwd -AllowedRoots $allowedCoderRoots)) {
    Add-Message -From system -Text ("🛑 Path-confinement: coder cwd вне allowlisted-корня → отказ. cwd='$coderCwd'") -Kind event | Out-Null
    try {
      Add-Content -LiteralPath (Join-Path $bridgeRoot 'driver.out.log') -Value (
        (Get-Date).ToString('s') + " path-confinement BLOCK cwd='$coderCwd' allowed='" + (@($allowedCoderRoots) -join ';') + "'"
      ) -Encoding UTF8
    } catch {}
    return [pscustomobject]@{
      text             = "PATH_CONFINEMENT_BLOCKED: coder cwd вне разрешённого корня: $coderCwd"
      status           = 'preflight_blocked'
      duration         = 0
      errorType        = 'path_confinement'
      preflightBlocked = $true
      reason           = "coder cwd вне allowlisted-корня: $coderCwd"
    }
  }
  if (Get-Command Get-PreflightBlockers -ErrorAction SilentlyContinue) {
    $pf = Get-PreflightBlockers -Channel $Channel -ProjectRoot $coderCwd
  } else {
    $pf = [pscustomobject]@{ Hard = @(); Soft = @('pre-flight helper Get-PreflightBlockers не загружен') }
  }
  if (@($pf.Hard).Count -gt 0) {
    $reason = (@($pf.Hard) -join '; ')
    return [pscustomobject]@{
      text             = "PREFLIGHT_BLOCKED: $reason"
      status           = 'preflight_blocked'
      duration         = 0
      errorType        = 'preflight_blocked'
      preflightBlocked = $true
      reason           = $reason
    }
  }
  if (@($pf.Soft).Count -gt 0) {
    $warn = "=== PRE-FLIGHT WARNINGS ===`n" + ((@($pf.Soft) | ForEach-Object { "- $_" }) -join "`n") + "`n===========================`n`n"
    $Prompt = $warn + $Prompt
  }
  $ctxBlock = ''
  try { $ctxBlock = Get-CoderRuntimeContextBlock -RepoRoot $coderCwd } catch { $ctxBlock = '' }
  if ($ctxBlock) {
    $Prompt = $ctxBlock + "`n`n" + $Prompt
  }
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "codex_in_$g.txt"; $msgF=Join-Path $env:TEMP "codex_msg_$g.txt"; $outF=Join-Path $env:TEMP "codex_out_$g.txt"; $errF=Join-Path $env:TEMP "codex_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $Prompt, $Utf8NoBom)
  $readOnlyCoderMode = ($Mode -eq 'discuss' -or $Mode -eq 'planner-fallback')
  $sbMode = if ($readOnlyCoderMode) { 'read-only' } else { Get-CoderSandboxMode }
  $reply = ''
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $replayCoderModel = 'codex-cli'
  # Per-channel project root routes Codex -C to the active project. No non-main fallback.
  # Global Codex instance mutex: Codex MSIX supports only one exec session at a time.
  # When another channel's driver is running Codex, wait up to 120s for it to finish.
  $codexLockFile = Join-Path $bridgeRoot 'runtime\codex.lock'
  $codexLockAcquired = $false
  $codexLockWaitSec = 0
  $codexLockWarned = $false
  $codexLockDir = Split-Path -Parent $codexLockFile
  if (-not (Test-Path $codexLockDir)) { New-Item -ItemType Directory -Force -Path $codexLockDir | Out-Null }
  while (-not $codexLockAcquired) {
    $lockStale = $false
    if (Test-Path $codexLockFile) {
      try {
        $ldata = Get-Content $codexLockFile -Raw -Encoding UTF8 -ErrorAction Stop
        $lparts = @(([string]$ldata).Trim() -split '\|')
        $lpid = 0; $lticks = [long]0
        if ($lparts.Count -gt 0) { [int]::TryParse($lparts[0], [ref]$lpid) | Out-Null }
        if ($lparts.Count -gt 1) { [long]::TryParse($lparts[1], [ref]$lticks) | Out-Null }
        $lproc = $null
        if ($lpid -gt 0) { $lproc = Get-Process -Id $lpid -ErrorAction SilentlyContinue }
        $lockStale = $true
        if ($lproc) {
          try {
            if ($lticks -gt 0 -and $lproc.StartTime.Ticks -eq $lticks) {
              $lockAgeSec = [math]::Max(0, [int](((Get-Date) - (Get-Item $codexLockFile).LastWriteTime).TotalSeconds))
              $lockStale = ($lockAgeSec -gt 920)
            }
          } catch {
            $lockStale = $true
          }
        }
      } catch {
        $lockStale = $true
      }
      if ($lockStale) {
        Remove-Item $codexLockFile -Force -ErrorAction SilentlyContinue
      }
    }

    try {
      $myPid = $PID; $myTicks = [long]0
      try { $myTicks = (Get-Process -Id $PID -ErrorAction Stop).StartTime.Ticks } catch { $myTicks = 0 }
      $lockPayload = "$myPid|$myTicks"
      $lockBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($lockPayload)
      $fs = [System.IO.File]::Open($codexLockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      try { $fs.Write($lockBytes, 0, $lockBytes.Length) } finally { $fs.Dispose() }
      $codexLockAcquired = $true
      break
    } catch [System.IO.IOException] {
      # Another channel won the race to create the lock.
    } catch {
      Add-Message -From system -Text ("⚠ Codex mutex: не смог захватить lock: " + $_.Exception.Message + ". Продолжаю без mutex.") -Kind event | Out-Null
      break
    }

    if ($codexLockWaitSec -ge 120) {
      Add-Message -From system -Text "⚠ Codex mutex: ждали 120s — другой канал не освободил lock. Продолжаю без mutex." -Kind event | Out-Null
      break
    }
    if (-not $codexLockWarned) {
      Add-Message -From system -Text "⏳ Codex занят другим каналом — жду (до 120s)..." -Kind event | Out-Null
      $codexLockWarned = $true
    }
    Start-Sleep -Seconds 5
    $codexLockWaitSec += 5
  }
  try {
    $effRes = Get-CoderReasoningEffort -CoderCwd $coderCwd
    $effort = [string]$effRes.effort
    if ([string]::IsNullOrWhiteSpace($effort)) { $effort = 'high' }
    $replayCoderModel = "codex-cli/$effort"
    $reasonArg = "model_reasoning_effort=`"$effort`""
    try {
      Add-Content -LiteralPath (Join-Path $bridgeRoot 'driver.out.log') -Value (
        (Get-Date).ToString('s') + " codex effort=$effort plen=$($effRes.plen) mode=$($effRes.mode) crc=$($effRes.crc) wt=$($effRes.wt)"
      ) -Encoding UTF8
    } catch {}
    $launch = [pscustomobject]@{
      File = $codexExe
      Args = @('exec','--color','never','--skip-git-repo-check','-c',$reasonArg,'-s',$sbMode,'-C',$coderCwd,'-o',$msgF,'-')
      Cwd  = $coderCwd
      In   = $inF
      Out  = $outF
      Err  = $errF
      Channel = (Get-EffectiveChannel)
    }
    $p = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath ([string]$Launch.File) `
        -ArgumentList $Launch.Args `
        -WorkingDirectory ([string]$Launch.Cwd) -RedirectStandardInput ([string]$Launch.In) -RedirectStandardOutput ([string]$Launch.Out) -RedirectStandardError ([string]$Launch.Err) -NoNewWindow -PassThru
    }
    $null = $p.Handle; Set-AgentPid $p.Id; Register-AgentPid $p.Id
    Set-CurrentAgent 'codex'
    # Coder cap was 600s - too tight after visual-baseline rule (d02ac8f) added
    # mandatory visit.ps1 invocations on top of edits, ui_audit, verification, and
    # commit for UI tasks. Drag-handle fix timed out at 603s twice. Raised to 900s.
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 900000 -MsgFile $msgF -ErrFile $errF -OutFile $outF)) {
      Stop-AgentTree $p.Id
      Add-ReplayRecordForCurrentTask -Role 'coder' -Model $replayCoderModel -Mode $Mode -Prompt $Prompt -Response '' `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'timeout' -ErrorType 'coder_timeout' -Provider 'codex'
      return [pscustomobject]@{ text=''; status='timeout'; duration=[int]$sw.Elapsed.TotalSeconds; errorType='coder_timeout' }
    }
    if (Test-Path $msgF) { $reply = Get-Content $msgF -Raw -Encoding UTF8 }
  } finally {
    Set-CurrentAgent $null
    if ($codexLockAcquired) { Remove-Item $codexLockFile -Force -ErrorAction SilentlyContinue }
    if ($p -and $p.Id) { Unregister-AgentPid $p.Id }; Clear-AgentPid
    # Capture process output BEFORE cleanup if reply is empty (diagnostic for silent exits/timeouts).
    if ([string]::IsNullOrWhiteSpace($reply)) {
      $se = Get-Content $errF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      $so = Get-Content $outF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if (-not [string]::IsNullOrWhiteSpace($se)) {
        $seTail = if ($se.Length -gt 2000) { '...(truncated, last 2000)' + $se.Substring($se.Length - 2000) } else { $se }
        Add-Message -From system -Text ("⚠ [Codex stderr tail]:`n" + $seTail) -Kind event | Out-Null
      }
      if (-not [string]::IsNullOrWhiteSpace($so)) {
        $soTail = if ($so.Length -gt 2000) { '...(truncated, last 2000)' + $so.Substring($so.Length - 2000) } else { $so }
        Add-Message -From system -Text ("⚠ [Codex stdout tail]:`n" + $soTail) -Kind event | Out-Null
      }
      if ([string]::IsNullOrWhiteSpace($se) -and [string]::IsNullOrWhiteSpace($so)) {
        Add-Message -From system -Text "⚠ [Codex silent exit]: stdout+stderr пусты (агент завис без вывода)" -Kind event | Out-Null
      }
    }
    Remove-Item $inF,$msgF,$outF,$errF -ErrorAction SilentlyContinue
  }
  if ($null -eq $reply) { $reply = '' }
  Add-ReplayRecordForCurrentTask -Role 'coder' -Model $replayCoderModel -Mode $Mode -Prompt $Prompt -Response $reply `
    -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'ok' -ErrorType $null -Provider 'codex'
  return [pscustomobject]@{ text=$reply.Trim(); status='ok'; duration=[int]$sw.Elapsed.TotalSeconds; errorType=$null }
}

function Invoke-Summarizer {
  param([string]$Existing, [string]$NewBlock)
  $prompt = @"
Ты ведёшь компактную сводку диалога между пользователем (оператором) и парой ИИ-агентов (мост Claude+Codex).
Текущая сводка (может быть пустой):
---
$Existing
---
Влей в неё новые сообщения ниже и верни ОБНОВЛЁННУЮ сводку. Сохраняй: ключевые решения, что уже сделано, важные факты/пути/настройки, открытые вопросы. Выкидывай: системный шум, повторы, болтовню. Пиши кратко и по-русски, маркерами. Верни ТОЛЬКО текст сводки, без преамбулы.

НОВЫЕ СООБЩЕНИЯ:
$NewBlock
"@
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "sum_in_$g.txt"; $outF=Join-Path $env:TEMP "sum_out_$g.txt"; $errF=Join-Path $env:TEMP "sum_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $prompt, $Utf8NoBom)
  $reply = ''
  try {
    $launch = [pscustomobject]@{
      File = $claudeExe
      Args = @('-p','--model',$triageModel)
      In   = $inF
      Out  = $outF
      Err  = $errF
      Channel = (Get-EffectiveChannel)
    }
    $p = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath ([string]$Launch.File) -ArgumentList $Launch.Args `
        -RedirectStandardInput ([string]$Launch.In) -RedirectStandardOutput ([string]$Launch.Out) -RedirectStandardError ([string]$Launch.Err) -NoNewWindow -PassThru
    }
    $null = $p.Handle; Register-AgentPid $p.Id
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 120000 -ErrFile $errF -OutFile $outF)) { Stop-AgentTree $p.Id; return $null }
    if (Test-Path $outF) { $reply = Get-Content $outF -Raw -Encoding UTF8 }
  } finally { if ($p -and $p.Id) { Unregister-AgentPid $p.Id }; Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue }
  if ($null -eq $reply) { return $null }
  return $reply.Trim()
}

function Update-ContextSummary {
  # Fold messages older than the hot window into the rolling summary, in batches.
  $all = Get-Messages -Since 0
  if (@($all).Count -eq 0) { return }
  $maxSeq = [int]$all[-1].seq
  $summarizedSeq = [int](Read-State).summarized_seq
  $hotFrom = $maxSeq - $fullContext
  $labels = @{ claude='[PLANNER/Claude]'; codex='[CODER/Codex]'; user='[USER]'; system='[SYSTEM]' }
  $toFold = @($all | Where-Object { [int]$_.seq -gt $summarizedSeq -and [int]$_.seq -le $hotFrom })
  if ($toFold.Count -lt $summarizeBatch) { return }
  $block = ($toFold | ForEach-Object { "$($labels[$_.from]): $($_.text)" }) -join "`n"
  $new = Invoke-Summarizer -Existing (Read-Summary) -NewBlock $block
  if ([string]::IsNullOrWhiteSpace($new)) { return }   # keep old summary on failure
  Write-Summary $new
  $foldedMax = [int]$toFold[-1].seq
  Update-State ({ param($s) $s | Add-Member -NotePropertyName summarized_seq -NotePropertyValue $foldedMax -Force }.GetNewClosure()) | Out-Null
  Add-Message -From system -Text "🗜 История свёрнута в сводку (последние $fullContext сообщений остаются целиком)." -Kind event | Out-Null
}

function Get-MaxUserSeq {
  $u = Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' }
  if ($u) { return ([int]($u[-1].seq)) } else { return 0 }
}
function Next-Speaker {
  $msgs = Get-Messages -Since 0
  for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
    if ($msgs[$i].from -eq 'claude') { return 'codex' }
    if ($msgs[$i].from -eq 'codex')  { return 'claude' }
  }
  return 'claude'
}

function Get-StudySpeaker {
  param([int]$TaskTurn, [string]$StudySubtype, [string]$StudyPhase)
  if ($TaskTurn -le 0) { return 'claude' }
  if ($StudyPhase -eq 'synthesis' -or $TaskTurn -ge ($studyMaxTurns - 1)) { return 'claude' }
  if ($StudySubtype -eq 'local') {
    if ($TaskTurn -eq 1) { return 'codex' }
    return 'claude'
  }
  if ($TaskTurn -eq 2) { return (Next-Speaker) }
  return 'claude'
}

function Get-TaskTopic {
  param([string]$TaskText, [int]$MaxLen = 200)
  $clean = ($TaskText -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
  if ($clean.Length -le $MaxLen) { return $clean }
  return ($clean.Substring(0, $MaxLen).TrimEnd() + '...')
}

function Get-AgentStatusText {
  param([string]$Speaker, [string]$Mode, [string]$TaskText = '')
  $topic = if ($TaskText) { Get-TaskTopic $TaskText } else { '' }
  if ($topic) {
    if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return "Claude исследует источники: «$topic»" }
    if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return "Claude обдумывает план: «$topic»" }
    if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return "Claude изучает и синтезирует: «$topic»" }
    if ($Speaker -eq 'claude') { return "Claude планирует: «$topic»" }
    if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return "Codex оценивает идею: «$topic»" }
    if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return "Codex собирает локальные находки: «$topic»" }
    if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
  }
  if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude ищет и сверяет внешние источники без Bash.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет следующий шаг.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return 'Claude ведёт web-трек study и готовит синтез.' }
  if ($Speaker -eq 'claude') { return 'Claude анализирует задачу и выбирает следующий шаг.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex оценивает план, риски и варианты без изменения файлов.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return 'Codex изучает локальную структуру и фиксирует FINDING.' }
  if ($Speaker -eq 'codex') { return 'Codex выполняет правку и проверяет результат.' }
  return $null
}

function Get-AgentPhaseStatusText {
  param([string]$Speaker, [string]$Mode, [string]$Phase, [string]$TaskText = '')
  $who   = if ($Speaker -eq 'claude') { 'Claude' } elseif ($Speaker -eq 'codex') { 'Codex' } else { 'агент' }
  $topic = if ($TaskText) { Get-TaskTopic $TaskText } else { '' }
  switch ($Phase) {
    'summary' { return "Проверяю историю диалога перед ходом $who..." }
    'prompt'  { return "Готовлю контекст и промпт для $who..." }
    'invoke'  {
      if ($topic) {
        if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return "Claude ищет внешние источники: «$topic»" }
        if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return "Codex оценивает идею: «$topic»" }
        if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return "Codex изучает локальный проект: «$topic»" }
        if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return "Claude обдумывает план: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return "Claude изучает источники и готовит отчёт: «$topic»" }
        return "Claude планирует: «$topic»"
      }
      if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex читает контекст и отвечает без изменения файлов.' }
      if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return 'Codex собирает локальные FINDING-находки.' }
      if ($Speaker -eq 'codex') { return 'Codex работает с файлами и командами.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude проверяет внешние источники без Bash.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет план.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return 'Claude ведёт study-исследование и синтезирует отчёт.' }
      return 'Claude анализирует задачу и выбирает следующий шаг.'
    }
    'post'    { return "Обрабатываю ответ $who, проверяю вложения..." }
    default   { return Get-AgentStatusText -Speaker $Speaker -Mode $Mode -TaskText $TaskText }
  }
}

function Set-BridgeStatusText {
  param([string]$Text)
  Update-State ({ param($s) $s.status_text=$Text; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
}

function Write-TurnLog {
  param(
    [string]$Speaker,
    [string]$Model,
    [string]$Mode,
    [DateTime]$StartedAtUtc,
    [string]$Reply,
    [string]$Status = ''
  )
  try {
    $turnStatus = $Status
    if ([string]::IsNullOrWhiteSpace($turnStatus)) {
      if ([string]$Reply -match 'timeout') { $turnStatus = 'timeout' }
      elseif ([string]::IsNullOrWhiteSpace($Reply)) { $turnStatus = 'empty' }
      else { $turnStatus = 'ok' }
    }
    $sec = [Math]::Round(([DateTime]::UtcNow - $StartedAtUtc).TotalSeconds, 3)
    $entry = [ordered]@{
      ts      = [DateTime]::UtcNow.ToString('o')
      speaker = $Speaker
      model   = $Model
      sec     = $sec
      status  = $turnStatus
      mode    = $Mode
    }
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'turns.jsonl') -Value ($entry | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
    try {
      $null = Add-UsageRecord -Kind prepaid -Provider $Speaker -Model $Model -Purpose $Mode -Sec $sec -Status $turnStatus
    } catch {}
  } catch {}
}

function Reset-TaskAgentDuration {
  param($State)
  $State | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue 0 -Force
}

function Complete-TaskAgentDuration {
  param($State)
  $totalSec = 0
  try { $totalSec = [int]$State.task_agent_duration_sec } catch {}
  $State | Add-Member -NotePropertyName last_task_agent_duration_sec -NotePropertyValue $totalSec -Force
  $State | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue 0 -Force
}

function Get-PushSnippet {
  param([string]$Text, [int]$Max = 120)
  $s = ([string]$Text).Trim() -replace '\s+', ' '
  if ($s.Length -gt $Max) { return ($s.Substring(0, $Max) + '...') }
  return $s
}

function Write-EvidenceLog {
  param(
    [string]$Agent,
    [string]$Task,
    [string]$Source,
    [string]$Summary,
    [string]$Confidence
  )
  try {
    $taskSnippet = ([string]$Task).Trim()
    if ($taskSnippet.Length -gt 100) { $taskSnippet = $taskSnippet.Substring(0, 100) }
    $entry = [ordered]@{
      ts         = [DateTime]::UtcNow.ToString('o')
      agent      = $Agent
      task       = $taskSnippet
      source     = $Source
      summary    = $Summary
      confidence = $Confidence
    }
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'evidence.jsonl') -Value ($entry | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}

# ---------- startup ----------
Sweep-AgentOrphans

# Resume an interrupted task across restarts instead of dropping it. Conversation,
# summary and decisions are file-based and already survive. We keep current_task /
# task_turn / task_mode / last_user_seq / summarized_seq, and only clear the transient
# execution state (a killed agent process). The loop re-runs the interrupted turn.
$boot = Read-State
$resumeTask = if ($boot -and $boot.current_task) { [string]$boot.current_task } else { '' }
if (-not [string]::IsNullOrWhiteSpace($resumeTask)) {
  # 2026-05-28: detect "stuck task" — if we've already resumed this task N times
  # without it closing, give up and mark failed. Real incident: Phase 1 task
  # survived 7+ restarts in 20 min while verify-loop and unrelated commits kept
  # triggering supervisor recycles. Auditor flagged "Supervisor restarts exceed
  # limit (7/5)" but bridge kept re-resuming with no escape valve.
  $prevRestartCount = 0
  try { if ($boot.PSObject.Properties.Name -contains 'task_restart_count') { $prevRestartCount = [int]$boot.task_restart_count } } catch {}
  $maxRestarts = 3
  try {
    $cfgRC = Get-BridgeConfig
    if ($cfgRC -and $cfgRC.PSObject.Properties.Name -contains 'taskRestartCap' -and $cfgRC.taskRestartCap) { $maxRestarts = [int]$cfgRC.taskRestartCap }
  } catch {}
  if ($maxRestarts -lt 2) { $maxRestarts = 2 }
  if ($maxRestarts -gt 10) { $maxRestarts = 10 }

  if ($prevRestartCount -ge $maxRestarts) {
    # Stuck task: bail out. Mark backlog failed if linked, clear state, post msg.
    $stuckTaskShort = $resumeTask
    if ($stuckTaskShort.Length -gt 100) { $stuckTaskShort = $stuckTaskShort.Substring(0, 100) + '…' }
    $stuckBacklogId = if ($boot.current_backlog_id) { [string]$boot.current_backlog_id } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stuckBacklogId)) {
      try { Set-Idea -Id $stuckBacklogId -Status 'failed' -Reason ("task_restart_loop_" + $prevRestartCount) | Out-Null } catch {}
    }
    Update-State {
      param($s)
      $s.current_task = $null
      $s.current_task_id = $null
      $s.task_turn = 0
      $s.task_mode = 'normal'
      $s.task_did_actions = $false
      $s.coder_fired = $false
      $s.verify_retry_count = 0
      $s.critic_retry_count = 0
      $s.status = 'idle'
      $s.active_agent = $null
      $s.active_model = $null
      $s.status_text = $null
      $s.agent_pid = $null
      $s.current_agent = $null
      $s.current_agent_pid = 0
      $s.driver_started = (Get-Date).ToString('o')
      $s.heartbeat = (Get-Date).ToString('o')
      $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force
    } | Out-Null
    Add-Message -From system -Text ("⚠ Задача пережила " + $prevRestartCount + " рестартов без закрытия — помечаю как failed и перехожу к следующей. Текст: «" + $stuckTaskShort + "»") -Kind event | Out-Null
  } else {
    Update-State {
      param($s)
      Start-ReplayForStateTask -State $s -TaskText $resumeTask -ChannelName $Channel
      $s.status='working'; $s.stop=$false; $s.abort=$false
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
      $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
      $newCount = $prevRestartCount + 1
      $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue $newCount -Force
    } | Out-Null
    $remaining = $maxRestarts - $prevRestartCount - 1
    $tail = if ($remaining -le 0) { '' } else { " (осталось $remaining попыток до auto-fail)" }
    Add-Message -From system -Text ("♻ Мост перезапущен — возобновляю прерванную задачу (прогресс и история сохранены)." + $tail) -Kind event | Out-Null
  }
} else {
  Update-State {
    param($s)
    $s.status='idle'; $s.stop=$false; $s.abort=$false
    $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
    $s.current_task=$null; $s.current_task_id=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Reset-TaskAgentDuration $s; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s
    $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
  } | Out-Null
  Add-Message -From system -Text "Интерактивный режим запущен. Полный доступ к ПК. Жду задачу от тебя в чате…" -Kind event | Out-Null
  # 2026-05-27v6: startup cleanup tasks (P0/P3 audit findings):
  #   - Sweep orphan *.tmp.* files (was 100+ leak from silent Remove failures)
  #   - Merge any *.unflushed sidecars from failed Add-Message writes
  try {
    $sweep = Sweep-OrphanTmpFiles -MinAgeMin 60
    if ($sweep -and (([int]$sweep.cleaned -gt 0) -or ([int]$sweep.failed -gt 0))) {
      $stuckPart = if ([int]$sweep.failed -gt 0) { ", " + $sweep.failed + " stuck (see control/tmp-leak.log)" } else { '' }
      Add-Message -From system -Text ("🧹 Tmp-sweep on startup: cleaned " + $sweep.cleaned + " orphan .tmp files" + $stuckPart) -Kind event | Out-Null
    }
  } catch {}
  # 2026-05-28: orphan git-worktree janitor. Parallel-worker worktrees whose teardown ran
  # under OneDrive readonly-reparse locks leave .git/worktrees/<name> metadata that git's
  # auto-gc can't prune ("failed to delete ...: Permission denied" on every commit).
  # Self-heal: force-remove admin dirs that no longer map to a live worktree.
  try {
    $wtClean = Clear-OrphanWorktrees -RepoRoot (Get-BridgeRoot)
    if ([int]$wtClean -gt 0) {
      Add-Message -From system -Text ("🧹 Worktree-janitor: removed " + $wtClean + " orphaned .git/worktrees entries.") -Kind event | Out-Null
    }
  } catch {}
  try {
    $unflush = Merge-UnflushedSidecars
    if ($unflush -and [int]$unflush.sidecars -gt 0) {
      Add-Message -From system -Text ("📥 Восстановлено " + $unflush.merged + " потерянных строк из " + $unflush.sidecars + " sidecar-файлов (сообщения, не дописанные в прошлый рестарт).") -Kind event | Out-Null
    }
  } catch {}
  # 2026-05-27v7: zombie-job recovery (audit deferred -- but came up live with
  # be073b57/774d71ed visit.ps1 jobs stuck after restart). At startup, re-check
  # active_jobs in state: if PID is dead and no .done marker -- write fake .done
  # with exit=-1 so polling loop closes them next iteration. Without this, driver
  # waits jobMaxH (6h default) blocking ALL new user tasks meanwhile.
  try {
    $bootState = Read-State
    $bootJobs = @()
    try { if ($bootState.PSObject.Properties.Name -contains 'active_jobs') { $bootJobs = @($bootState.active_jobs) } } catch {}
    if ($bootJobs.Count -gt 0) {
      $recovered = 0
      foreach ($bj in $bootJobs) {
        $jp = 0; try { $jp = [int]$bj.pid } catch {}
        $alive = $false
        if ($jp -gt 0) {
          try {
            $bp = Get-Process -Id $jp -ErrorAction SilentlyContinue
            if ($bp) {
              $ticks = 0L; try { $ticks = [long]$bj.startTicks } catch {}
              if ($ticks -le 0) { $alive = $true }
              else { try { if ($bp.StartTime.Ticks -eq $ticks) { $alive = $true } } catch {} }
            }
          } catch {}
        }
        if (-not $alive) {
          # Write a .done marker so the polling loop's Test-JobDone returns true.
          # exit-code -1 indicates "process died, no clean exit" — orphan classification.
          $jobsDir = Join-Path (Get-BridgeRoot) 'jobs'
          $donePath = Join-Path $jobsDir (([string]$bj.id) + '.done')
          try {
            if (-not (Test-Path -LiteralPath $donePath)) {
              [System.IO.File]::WriteAllText($donePath, '-1', (New-Object System.Text.UTF8Encoding($false)))
              $recovered++
            }
          } catch {}
        }
      }
      if ($recovered -gt 0) {
        Add-Message -From system -Text ("⚠ Zombie-jobs recovered: " + $recovered + " фоновых задач после рестарта помечены как orphan (процесс умер до записи .done). Драйвер не залипнет в ожидании.") -Kind event | Out-Null
      }
    }
  } catch {}
}

# Doctor restart-loop guard (FIX: 2026-05-26).
# Bug: when Codex (as Doctor's coder) edited a .ps1 and set restart.flag, the bridge
# restarted, Doctor stayed active (doctor_active=true, current_task=<doctor task>), but
# doctor_attempts never incremented because the increment branch only triggers when
# current_task is EMPTY. Result: infinite restart loop, Codex never committed, working tree
# accumulated changes. This guard treats each driver startup-while-Doctor-active as one
# "attempt", so the existing max-attempts gate actually fires.
#
# 2026-05-26 incident: 6 restarts in 10 min while Doctor was "in progress" -- user had to
# kill the bridge manually. Save Codex's pending edits to a stash branch first if you see
# the loop happening again (changes are recoverable via `git stash list`).
try {
  $startupState = Read-State
  try {
    if ($startupState) {
      $_bootCh = if ($startupState.current_channel) { [string]$startupState.current_channel } else { $Channel }
      $_lastSnap = Get-LastSnapshot -Channel $_bootCh
      if ($_lastSnap -and [string]::IsNullOrWhiteSpace([string]$startupState.held_task) -and [string]::IsNullOrWhiteSpace([string]$startupState.current_task)) {
        $_snapAge = ((Get-Date) - (Get-Item $_lastSnap).LastWriteTime).TotalMinutes
        if ($_snapAge -lt 60) {
          try { Add-Message -From system -Text ("♻ Снимок state до рестарта (<60мин): " + $_lastSnap + ". Если задача потеряна — снимок содержит прежний контекст.") -Kind event | Out-Null } catch {}
        }
      }
    }
  } catch {}
  if ([bool]$startupState.doctor_active) {
    $newAtt = [int]$startupState.doctor_attempts + 1
    $maxA = 3   # initial + 2 restarts; beyond that the loop is real and we escalate
    Update-State { param($s) $s.doctor_attempts = [int]$s.doctor_attempts + 1 } | Out-Null
    Add-Message -From system -Text ("🩺 Доктор резюмирован после рестарта (попытка " + $newAtt + "/" + $maxA + ").") -Kind event | Out-Null
    if ($newAtt -ge $maxA) {
      # Restart loop -- abort Doctor cleanly + restore held_task so the operator sees what
      # was running. Doctor's prompt may have generated useful diagnostic memories; those
      # stay in long-term memory regardless.
      $held = [string]$startupState.held_task
      $reason = [string]$startupState.doctor_reason
      Update-State {
        param($s)
        $s.doctor_active = $false
        $s.doctor_attempts = 0
        $s.doctor_reason = ''
        $s.doctor_started_at = $null
        Close-ReplayForStateTask -State $s -Status 'aborted'
        $s.current_task = $null    # operator will re-submit / inspect; don't auto-resume held_task to avoid loop chain
        $s.held_task = $held       # keep for the operator-visible event below
        $s.task_turn = 0
        $s.task_mode = 'normal'
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        $s.status = 'idle'
        $s.active_agent = $null
        $s.active_model = $null
        $s.status_text = $null
      } | Out-Null
      $snip = $held; if ($snip.Length -gt 80) { $snip = $snip.Substring(0,80) + '...' }
      Add-Message -From system -Text ("⚠ Доктор отменён: restart-loop ($newAtt рестартов мостa при reason='" + $reason + "'). Приостановленная задача: «" + $snip + "» — оператор, проверь рабочее дерево (git status / git stash list) и при необходимости перепиши задачу.") -Kind event | Out-Null
    }
  }
} catch {}

# ---------- main loop ----------
while ($true) {
 try {
  # Phase 3 (full): channel is hard-pinned at process startup. No per-iteration re-evaluation
  # -- each driver lives in its own channel for its entire lifetime.
  $state = Read-State
  # FIX 2026-05-27: Read-State now returns $null on structurally-broken state.json
  # (Test-StateShape failure). Self-heal: re-run Initialize-Bridge to restore defaults,
  # then re-read. Without this, a state-wipe accident (like yesterday's) would just hang
  # the driver silently on subsequent iterations.
  if ($null -eq $state) {
    try { Add-Message -From system -Text "⚠ Driver: state.json повреждён — auto-recover через Initialize-Bridge defaults." -Kind event } catch {}
    try { $null = Initialize-Bridge } catch {}
    $state = Read-State
    if ($null -eq $state) {
      # Recovery itself failed — sleep + retry. Never hard-crash the loop.
      Start-Sleep -Seconds 5; continue
    }
  }

  if ($state.stop) { Add-Message -From system -Text "Мост остановлен." -Kind event | Out-Null; Update-State { param($s) $s.status='stopped'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null } | Out-Null; break }

  if ($state.abort) {
    Add-Message -From system -Text "🛑 Стоп-кран: текущая задача прервана. Жду новую." -Kind event | Out-Null
    try { foreach ($j in @($state.active_jobs)) { Stop-BridgeJob $j } } catch {}
    # Abort is always intentional (user kill button) -- no post-mortem needed.
    # If Doctor was active, clean up its state gracefully before resetting.
    if ([bool](Read-State).doctor_active) {
      try { Abort-Doctor -Reason 'manual abort by operator' } catch {}
    }
      Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
    Start-Sleep -Seconds 1; continue
  }
  if ($state.paused) { Update-State { param($s) $s.status='paused'; $s.active_agent=$null; $s.active_model=$null; $s.status_text='Пауза: мост ждёт команды продолжить.'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null; Start-Sleep -Seconds $loopDelay; continue }

  # 🩺 Doctor pre-checks: pick up watchdog's repair.signal, or seed the doctor task if active.
  # When Doctor is active and current_task is empty, we synthesize the doctor task (diagnose +
  # minimal fix + verify + commit) and let the normal pipeline run it. On its DONE we restore
  # the held task. Max attempts gate prevents infinite repair loops.
  try {
    $sigReason = Test-DoctorSignal
    if ($sigReason -and -not [bool]$state.doctor_active -and [string]::IsNullOrWhiteSpace([string]$state.held_task)) {
      Activate-Doctor -Reason $sigReason -Detail 'signal from watchdog' | Out-Null
      $state = Read-State
    }
  } catch {}
  # Restart-loop trigger (wave 3): >=3 restarts in 5 min with no ok turns -> Doctor.
  # User reported 2026-05-26: bridge restarted 4x without Doctor activating; this closes that gap.
  # GUARD (2026-05-26 second fix): Test-RestartLoop counts the LAST 5 min of conversation
  # restart events. On a fresh boot after a prior restart loop, those old events are still
  # in the window and would false-positive Doctor. Skip the check during the driver's first
  # 90s of uptime so the "noise from the past" ages out before we look.
  if (-not [bool]$state.doctor_active) {
    $driverUptime = 0
    try { $driverUptime = ((Get-Date) - [datetime]$state.driver_started).TotalSeconds } catch {}
    if ($driverUptime -ge 90) {
      try {
        $loopReason = Test-RestartLoop
        if ($loopReason) {
          Activate-Doctor -Reason 'restart_loop' -Detail $loopReason | Out-Null
          $state = Read-State
        }
      } catch {}
    }
  }
  if ([bool]$state.doctor_active -and [string]::IsNullOrWhiteSpace([string]$state.current_task)) {
    $maxA = Get-DoctorMaxAttempts
    $att  = [int]$state.doctor_attempts
    if ($att -ge $maxA) {
      Abort-Doctor -Reason "max attempts ($maxA) reached"
      Start-Sleep -Seconds $loopDelay; continue
    }
    try {
      $doctorTask = Get-DoctorTaskText
      $baseCommitD = ''
      try { $baseCommitD = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch {}
      Update-State ({ param($s)
        $s.current_task     = $doctorTask
        $s.task_turn        = 0
        $s.task_mode        = 'normal'
        $s.task_start_seq   = [int]$s.lastSeq
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        Clear-ChunkingState $s
        $s.doctor_attempts  = [int]$s.doctor_attempts + 1
        $s.status           = 'working'
        $s.heartbeat        = (Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommitD -Force
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      try { Add-SessionDecisionEvent -EventType 'doctor_fix' -Meta @{ what='doctor_activated' } -Channel $Channel } catch {}
      try { Add-Message -From system -Text "🩺 Доктор приступает к диагностике и фиксу." -Kind event | Out-Null } catch {}
      $state = Read-State
    } catch {
      try { Add-Message -From system -Text ("🩺 Доктор: ошибка при подготовке задачи: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      Abort-Doctor -Reason "setup error"
      Start-Sleep -Seconds $loopDelay; continue
    }
  }

  try {
    $curatorDecisions = @(Get-NewCuratorDecisions)
    if ($curatorDecisions.Count -gt 0) { Publish-CuratorDecisionEvents -Decisions $curatorDecisions }
  } catch {
    try { Add-Message -From system -Text ("⚠ Curator decision poll failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
  }

  # --- BACKGROUND JOBS: if any are running, WAIT (poll) instead of running an agent turn,
  #     so long commands (e.g. hour-long project runs) don't time out and the bridge is
  #     neither "idle" (no autonomy grab) nor killed. Results are fed back when done.
  $activeJobs = @(); try { if ($state.active_jobs) { $activeJobs = @($state.active_jobs) } } catch {}
  if ($activeJobs.Count -gt 0) {
    $jobMaxH = 6; try { $cfgJ = Get-BridgeConfig; if ($cfgJ.PSObject.Properties.Name -contains 'jobMaxHours') { $jobMaxH = [double]$cfgJ.jobMaxHours } } catch {}
    $stillRunning = New-Object System.Collections.Generic.List[object]
    foreach ($job in $activeJobs) {
      $finished = $false; $reason = 'done'
      if (Test-JobDone $job) { $finished = $true }
      else {
        $ageMin = 99999; try { $ageMin = ((Get-Date).ToUniversalTime() - ([datetime]$job.started).ToUniversalTime()).TotalMinutes } catch {}
        # ORPHAN DETECTION (FIX 2026-05-26): if the launched process is dead AND no .done
        # marker was written, the job was killed mid-run (typical cause: bridge restart
        # while visit.ps1 was running). Without this, the driver waits up to jobMaxH (6h)
        # before timing out, blocking ALL new user input meanwhile. We give 3 minutes for
        # the runner to start + write its .done; after that, dead pid = orphan.
        $isOrphan = $false
        if ($ageMin -ge 3) {
          try {
            $jp = 0; try { $jp = [int]$job.pid } catch {}
            if ($jp -le 0) {
              $isOrphan = $true   # no PID ever recorded -- bad startup, dead since birth
            } else {
              $proc = Get-Process -Id $jp -ErrorAction SilentlyContinue
              if (-not $proc) { $isOrphan = $true }
              else {
                # Verify it's the SAME process (PID could be recycled). startTicks must match.
                $stickyTicks = 0; try { $stickyTicks = [long]$job.startTicks } catch {}
                if ($stickyTicks -gt 0) {
                  try { if ($proc.StartTime.Ticks -ne $stickyTicks) { $isOrphan = $true } } catch {}
                }
              }
            }
          } catch {}
        }
        if ($isOrphan) { $finished = $true; $reason = 'orphan' }
        elseif (($ageMin / 60.0) -ge $jobMaxH) { try { Stop-BridgeJob $job } catch {}; $finished = $true; $reason = 'timeout' }
      }
      if ($finished) {
        $res = Get-JobResult $job
        $cap = 1500   # cap "Вывод (хвост)" to avoid context flood
        $tail = [string]$res.tail
        if ($tail.Length -gt $cap) { $tail = '...(хвост обрезан)...' + "`n" + $tail.Substring($tail.Length - $cap) }
        if ($reason -eq 'timeout') {
          Add-Message -From system -Text ("⏱ Фоновая задача [$($job.id)] превысила лимит ($jobMaxH ч) и остановлена.`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$tail") -Kind event | Out-Null
        } elseif ($reason -eq 'orphan') {
          Add-Message -From system -Text ("⚠ Фоновая задача [$($job.id)] потеряна: процесс умер, не записав .done маркер (вероятно, перезапуск моста во время её работы). Снимаю с polling, продолжаю.`nКоманда: $($job.cmd)") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Фоновая задача [$($job.id)] завершена (код выхода: $($res.exitCode)).`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$tail") -Kind event | Out-Null
        }
      } else { [void]$stillRunning.Add($job) }
    }
    $remaining = @($stillRunning.ToArray())
    Update-State ({ param($s) $s.active_jobs=$remaining; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o'); $s.status_text=$(if ($remaining.Count -gt 0) { "⏳ Жду фоновую задачу (" + $remaining.Count + ")..." } else { $null }) }.GetNewClosure()) | Out-Null
    if ($remaining.Count -gt 0) { Start-Sleep -Seconds $loopDelay; continue }
    $state = Read-State
  }

  $maxUser = Get-MaxUserSeq

  if (-not $state.current_task) {
    if ($maxUser -gt [int]$state.last_user_seq) {
      $script:idleStreak = 0   # user activity -> restore snappy idle cadence
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      $projectBindingForTask = Get-ActiveProjectBinding
      if ($projectBindingForTask -and ([string]$projectBindingForTask.slug -ne 'main') -and -not [bool]$projectBindingForTask.ok) {
        $slugForTask = [string]$projectBindingForTask.slug
        $reasonForTask = [string]$projectBindingForTask.error
        if ([string]::IsNullOrWhiteSpace($reasonForTask)) { $reasonForTask = "Канал '$slugForTask' не привязан к проекту" }
        $msg = @"
⚠ Канал '$slugForTask' не привязан к проекту. Задачу не запускаю, чтобы не уйти в bridge.

Добавь привязку в settings.json:
{
  "channels": {
    "$slugForTask": {
      "projectPath": "C:\\путь\\к\\проекту",
      "projectType": "тип проекта",
      "projectDescription": "краткое описание"
    }
  }
}

Причина: $reasonForTask
Затем повтори задачу.
"@
        Add-Message -From system -Text $msg -Kind event | Out-Null
        Update-State ({ param($s)
          $s.last_user_seq=$maxUser
          $s.current_task=$null
          $s.current_task_id=$null
          $s.status='idle'
          $s.active_agent=$null
          $s.active_model=$null
          $s.status_text=$null
          $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        Start-Sleep -Seconds $loopDelay
        continue
      }
      $studyDetect = Detect-StudyMode -TaskText $taskMsg
      # 🧭 [[DEEP-THINK]] marker forces discuss-mode dialog (Claude↔Codex back-and-forth)
      # instead of normal planner->coder. Used by Start-DeepThinkDialog on Sat/Sun nights.
      #
      # FIX 2026-05-27: anchor the marker to its own line at start (multi-line ^). Previously
      # the regex matched the literal anywhere in the task text -- so if a spec MENTIONED the
      # marker in an example or referenced it in instructions to Codex, the task itself
      # got routed to discuss-mode. Now requires marker to be alone on a line (with optional
      # leading whitespace) -- can't be inside code blocks, quotes, or prose.
      $deepThinkMark = [bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[DEEP-THINK\]\]\s*$'))
      # 2026-05-28: ALSO trigger discuss-mode if task contains explicit discussion
      # verbs anywhere in text. This is a deterministic override BEFORE the LLM
      # intent classifier — was needed because classifier weighs by overall
      # task topic and silently drops "обсудите коротко" sections in mostly-
      # implementation tasks. Forces discuss when user explicitly asks for it,
      # regardless of how much implementation spec is attached.
      $discussVerbRegex = '(?im)\b(обсуди(?:м|те|ть)?|обсудим(?:те)?|посоветуйс(?:я|е)|согласуй(?:те|тесь)?|давайте\s+обсудим|подумайте\s+вместе|перед(?:\s+тем)?\s+(?:чем|как)[^.]{0,80}обсуд|coordinate\s+with\s+codex|discuss\s+with\s+codex)'
      $discussVerbMark = [bool]([regex]::IsMatch($taskMsg, $discussVerbRegex))
      # [[NORMAL]] override forces task_mode=normal even if other auto-detect would route
      # elsewhere (study/discuss). For operators who know "obsuzhdat' nechego, delay".
      $normalOverride = [bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[NORMAL\]\]\s*$'))
      $fastLaneCfg = Get-FastLaneSettings
      $fastMark = [bool]([regex]::IsMatch($taskMsg, '\[\[FAST\]\]'))
      $reasoningHighMark = [bool]([regex]::IsMatch($taskMsg, '\[\[REASONING:high\]\]'))
      $autoFastLane = $false
      if (-not $fastMark -and -not $reasoningHighMark -and [bool]$fastLaneCfg.autoDetect) {
        $autoFastLane = Test-IsTrivialTask -TaskText $taskMsg -MinChars ([int]$fastLaneCfg.minChars)
      }
      $fastLaneReason = ''
      if ($fastMark -and -not $reasoningHighMark) { $fastLaneReason = 'marker' }
      elseif ($autoFastLane) { $fastLaneReason = 'auto' }

      # 2026-05-28: LLM intent classifier. Replaces hardcoded [[DEEP-THINK]] regex
      # with semantic understanding of the user's task. Explicit markers
      # ([[FAST]], [[NORMAL]], [[DEEP-THINK]]) always win; the LLM call only
      # fires when no marker forces a mode. Confidence threshold 0.7 prevents
      # acting on uncertain classifications (falls through to legacy detection).
      # Decomposed subtasks are surfaced to the planner via Format-IntentForPrompt
      # in Build-PromptHistory so the planner sees the structured breakdown,
      # not just a single mode tag.
      $taskIntent = $null
      if (-not $fastLaneReason -and -not $normalOverride -and -not $deepThinkMark -and (Get-Command Test-TaskIntent -ErrorAction SilentlyContinue)) {
        try { $taskIntent = Test-TaskIntent -TaskText $taskMsg -TimeoutSec 25 } catch { $taskIntent = $null }
      }
      $intentMode = ''
      if ($taskIntent -and [double]$taskIntent.confidence -ge 0.7) {
        $intentMode = [string]$taskIntent.primary_mode
      }
      # Convert intent into legacy mode flags so the existing switch below stays simple.
      $intentForcedFastLane = ($intentMode -eq 'fast')
      $intentForcedDiscuss  = ($intentMode -eq 'discuss')
      $intentForcedStudy    = ($intentMode -eq 'study')
      # 2026-05-29 complexity throttle: even when the classifier routed to a
      # heavy mode (e.g. discuss) by topic, a CONFIDENT trivial/simple verdict
      # means the task does not warrant the full ceremony. Test-IntentLowComplexity
      # gates on confidence>=0.7 + complexity in {trivial,simple} + turns<=4.
      # This is the fix for "show a desktop screenshot" being routed to a ~7-min
      # discuss debate. Honour the operator's autoDetect switch so the throttle
      # can be disabled wholesale; explicit markers already suppress $taskIntent.
      $intentLowComplexity = $false
      if ($taskIntent -and [bool]$fastLaneCfg.autoDetect -and (Get-Command Test-IntentLowComplexity -ErrorAction SilentlyContinue)) {
        try { $intentLowComplexity = [bool](Test-IntentLowComplexity -Intent $taskIntent) } catch { $intentLowComplexity = $false }
      }

      $taskProjectRoot = Get-ActiveProjectRoot
      if ([string]::IsNullOrWhiteSpace($taskProjectRoot)) { $taskProjectRoot = $bridgeRoot }
      $baseCommit = try { (& git -C $taskProjectRoot rev-parse HEAD 2>$null).Trim() } catch { '' }

      # Snapshot intent for the state mutator closure.
      $intentRecord = $null
      if ($taskIntent) {
        $intentRecord = [pscustomobject]@{
          primary_mode = [string]$taskIntent.primary_mode
          mode = [string]$taskIntent.primary_mode
          confidence = [double]$taskIntent.confidence
          reasoning = [string]$taskIntent.reasoning
          user_wants_dialogue = [bool]$taskIntent.user_wants_dialogue
          complexity = [string]$taskIntent.complexity
          estimated_turns = [int]$taskIntent.estimated_turns
          subtasks = @($taskIntent.subtasks)
          model = [string]$taskIntent.model
          ts = (Get-Date).ToUniversalTime().ToString('o')
        }
      }
      $intentForcedFastLaneClosure = $intentForcedFastLane
      $intentForcedDiscussClosure  = $intentForcedDiscuss
      $intentForcedStudyClosure    = $intentForcedStudy
      $discussVerbClosure          = $discussVerbMark
      $intentLowComplexityClosure  = $intentLowComplexity

      Update-State ({ param($s)
        $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'
        Start-ReplayForStateTask -State $s -TaskText $taskMsg -ChannelName $Channel
        $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
        Clear-FastLaneFlags $s
        # Precedence: explicit markers > discuss-verb regex > LLM intent (high conf) > legacy detection.
        # discuss-verb is BEFORE the LLM intent fork: deterministic catch for
        # "обсуди" в любом месте текста, не зависит от того что классификатор
        # решил по доминирующей теме задачи (он часто прозевает discuss-секции
        # в задачах с большим implementation-спеком).
        # 2026-05-29: a CONFIDENT trivial/simple verdict ($intentLowComplexityClosure)
        # neuters the two "discuss" branches so a 1-line change can't be dragged into
        # a multi-turn Claude<->Codex debate; it then lands on the new fast-lane catch
        # below (after study, which keeps its own output contract). Markers/normal/
        # deep-think still win because they suppress $taskIntent upstream.
        if ($fastLaneReason) { Set-FastLaneFlags -State $s -Reason $fastLaneReason; $s.task_mode='normal' }
        elseif ($normalOverride) { $s.task_mode='normal' }  # explicit operator force
        elseif ($deepThinkMark) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($discussVerbClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedFastLaneClosure) { Set-FastLaneFlags -State $s -Reason 'llm-intent'; $s.task_mode='normal' }
        elseif ($intentForcedDiscussClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedStudyClosure) { $s.task_mode='study'; $s.study_subtype='external'; $s.study_phase='plan' }
        elseif ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
        elseif ($intentLowComplexityClosure) { Set-FastLaneFlags -State $s -Reason 'llm-simple'; $s.task_mode='normal' }
        $s.task_start_seq=$maxUser; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$null; $s.status='working'; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
        $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
        # 2026-05-28: reset restart-counter when a new task arrives. Counter
        # tracks "this task survived N driver restarts without closing" and
        # auto-fails the task at $maxRestarts (boot.ps1 resume block).
        $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force
        Clear-AuditorSuppressedHashes -State $s
        Clear-ChunkingState $s
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
        $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
        # Persist intent so planner can render it via Format-IntentForPrompt on later turns too.
        $s | Add-Member -NotePropertyName task_intent -NotePropertyValue $intentRecord -Force
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
      try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
      Add-Message -From system -Text "📥 Новая задача принята в работу." -Kind event | Out-Null
      if ($fastLaneReason -eq 'marker') { Add-Message -From system -Text "🚀 Fast-lane активирован ([[FAST]])" -Kind event | Out-Null }
      elseif ($fastLaneReason -eq 'auto') { Add-Message -From system -Text "🚀 Auto fast-lane detected (короткая императивная задача)" -Kind event | Out-Null }
      if ($normalOverride -and -not $fastLaneReason) { Add-Message -From system -Text "📐 [[NORMAL]] override -- task_mode=normal forced (auto-detect bypassed)." -Kind event | Out-Null }
      if ($deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) { Add-Message -From system -Text "🧭💭 Deep-think dialog detected — режим: discuss (Claude↔Codex до сходимости, max 6 ходов)." -Kind event | Out-Null }
      if ($discussVerbMark -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentLowComplexity) { Add-Message -From system -Text "🗣 Discuss-verb detected (обсуди/согласуйте/...) — режим: discuss (Claude↔Codex до сходимости, max 6 ходов). Хочешь обычный режим без обсуждения — добавь [[NORMAL]] в начало задачи." -Kind event | Out-Null }
      if ($studyDetect -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentForcedDiscuss -and -not $intentForcedStudy -and -not $intentForcedFastLane) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: user" -Kind event | Out-Null }
      # 2026-05-28: announce LLM-classifier verdict so user sees what mode was inferred and why.
      if ($taskIntent -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) {
        $confPct = [int]([double]$taskIntent.confidence * 100)
        $verdictText = "🧠 LLM-классификатор намерения ($([string]$taskIntent.model)): mode=" + [string]$taskIntent.primary_mode + ", confidence=$confPct%"
        if (-not [string]::IsNullOrWhiteSpace([string]$taskIntent.reasoning)) { $verdictText += "`n   причина: " + [string]$taskIntent.reasoning }
        if ([bool]$taskIntent.user_wants_dialogue) { $verdictText += "`n   ⚠ пользователь явно хочет диалог" }
        if ($intentLowComplexity) { $verdictText += "`n   → режим: fast-lane (простая задача — пропускаю планировщик/критика/обсуждение). Нужен полный разбор — добавь [[DEEP-THINK]]." }
        elseif ($intentForcedDiscuss) { $verdictText += "`n   → режим: discuss (Claude↔Codex)" }
        elseif ($intentForcedStudy) { $verdictText += "`n   → режим: study" }
        elseif ($intentForcedFastLane) { $verdictText += "`n   → режим: fast-lane (skip planner)" }
        elseif ([double]$taskIntent.confidence -lt 0.7) { $verdictText += "`n   (confidence < 70% → не применён, режим normal)" }
        Add-Message -From system -Text $verdictText -Kind event | Out-Null
      }
      $state = Read-State
    } else {
      # Reconcile: a backlog task that ended without success leaves current_backlog_id set.
      $leftBid = [string]$state.current_backlog_id
      if ($leftBid) {
        try { if ((Get-IdeaById -Id $leftBid).status -eq 'running') { Set-Idea -Id $leftBid -Status 'failed' | Out-Null; Add-Message -From system -Text "⚠ Автозадача из бэклога не завершилась успешно — помечена 'failed'." -Kind event | Out-Null } } catch {}
        Update-State { param($s) $s.current_backlog_id=$null } | Out-Null
        $state = Read-State
      }
      # Learning loop: metric snapshot during idle every 3 hours, plus hypothesis reflection.
      $_lastSnap = try { Get-LastMetricsSnapshot } catch { $null }
      $_snapAgeH = if ($_lastSnap) { ([DateTime]::UtcNow - [DateTime]$_lastSnap.ts).TotalHours } else { 999 }
      # Snapshot every 3h (cheap, just stats from turns.jsonl).
      if ($_snapAgeH -ge 3) { try { Write-MetricsSnapshot } catch {} }
      # Hypothesis verdict closure runs ONLY in the nightly quiet window 02:00-06:00 local
      # (user feedback 2026-05-26: "по будильнику, когда я точно сплю"). Heavier I/O + Add-Memory
      # call doesn't bother the user, and we still close verdicts within ~24h.
      try { if (Test-WithinQuietHours -StartHour 2 -EndHour 6) { Invoke-MetricsReflection } } catch {}

      # 🧭 Architect (meta-improvement): cron-style, fires when idle if 24h passed OR 10
      # closed tasks accumulated since last run. Architect proposes STRUCTURAL gaps as
      # backlog ideas (tag=architect status=new -> needs user approval). Different from
      # reflect.ps1 (leaf-level tweaks) and Doctor (acute repair).
      try { Start-ArchitectIfDue -Mode 'normal' } catch {}
      try { Start-DeepThinkIfDue } catch {}
      try { Start-AuditorIfDue } catch {}
      try {
        if ([string]$Channel -eq 'main') {
          if ($null -eq $script:LastTestCleanupTick) { $script:LastTestCleanupTick = 0 }
          $script:LastTestCleanupTick = [int]$script:LastTestCleanupTick + 1
          if ($script:LastTestCleanupTick -ge 30) {
            $script:LastTestCleanupTick = 0
            $cleaned = @(Invoke-TestChannelCleanup -GraceMinutes 10)
            if ($cleaned.Count -gt 0) {
              Write-Host ("[cleanup] processed test channels: " + (($cleaned | ForEach-Object { $_.Name }) -join ', '))
            }
          }
        }
      } catch {}

      # Autonomy: after enough idle quiet, take the next approved backlog idea and run it
      # as a self-task. Freshness skips are logged by backlog/curator and surfaced via poll.
      $claimedIdea = $null
      $claimedIdeaSelection = $null
      $auditBusyForAutonomy = $false
      try { $auditBusyForAutonomy = Test-AuditMaintenanceBusy } catch {}
      if ((-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        try {
          $claimedIdeaSelection = Get-NextApprovedIdea
          if ($claimedIdeaSelection -and ($claimedIdeaSelection.PSObject.Properties.Name -contains 'skipped')) {
            $skipDecisions = @($claimedIdeaSelection.skipped)
            if ($skipDecisions.Count -gt 0) { Publish-CuratorDecisionEvents -Decisions $skipDecisions }
          }
          if ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'idea') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'item'))) {
            $claimedIdea = Get-ObjectValue $claimedIdeaSelection @('idea','item')
          } elseif ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'id') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'text'))) {
            $claimedIdea = $claimedIdeaSelection
          }
        } catch {}
      }
      # 🌱 Increment B -- graduated self-development: AUTO-CLAIM of an UNapproved 'new' idea within
      # the operator's selfExecuteTier dial. When no human/curator-approved idea is queued and the
      # dial is 'green'/'yellow', take the next runnable 'new' idea whose risk tier is within the
      # dial (Get-NextSelfExecIdea excludes external/radar and red-tier, and skips past out-of-dial
      # items so the queue can't wedge). It is promoted into $claimedIdea HERE -- BEFORE the dirty
      # guard -- so it runs the IDENTICAL pipeline as approved ideas (dirty guard, smoke+critic
      # gates, verdict auto-revert). $selfDev* are read by the shadow-observability block below.
      $selfDevTier = 'off'
      $selfDevClaimed = $false
      $selfDevPick = $null
      $selfDevTierOfPick = ''
      $selfDevReason = ''
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main') -and (Test-AutonomyReady)) {
        try { $selfDevTier = ([string](Get-AutonomySettings).selfExecuteTier).ToLowerInvariant() } catch { $selfDevTier = 'shadow' }
        # 🛡 Safety reflex: if recent self-exec commits regressed (verdict 'worse'), dial DOWN one
        # notch BEFORE picking again, so the system throttles its own autonomy after regressions.
        try {
          $reflex = Test-SelfDevSafetyReflex -CurrentDial $selfDevTier
          if ($reflex -and $reflex.shouldDampen) {
            try { Set-AutonomySetting @{ selfExecuteTier = [string]$reflex.newDial } | Out-Null } catch {}
            Add-Message -From system -Text ("🛡 Само-защита: понижаю диск само-развития $($reflex.fromDial)→$($reflex.newDial) — недавние авто-коммиты дали регресс (worse=$($reflex.worseCount)). Система притормаживает сама.") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-dev-dampen'; from=[string]$reflex.fromDial; to=[string]$reflex.newDial; worse=[int]$reflex.worseCount }) } catch {}
            $selfDevTier = [string]$reflex.newDial
          }
        } catch {}
        if ($selfDevTier -eq 'green' -or $selfDevTier -eq 'yellow') {
          try { $selfDevPick = Get-NextSelfExecIdea -Dial $selfDevTier } catch { $selfDevPick = $null }
          if ($selfDevPick) {
            $rt = Get-IdeaRiskTier -Idea $selfDevPick
            $selfDevTierOfPick = [string]$rt.tier
            $selfDevReason = [string]$rt.reason
            try { Set-IdeaRiskTier -Id ([string]$selfDevPick.id) -Tier $selfDevTierOfPick -Reason $selfDevReason | Out-Null } catch {}
            $claimedIdea = $selfDevPick
            $selfDevClaimed = $true
            try { Set-IdeaSelfExec -Id ([string]$selfDevPick.id) -Dial $selfDevTier | Out-Null } catch {}
            $script:lastShadowIdeaId = [string]$selfDevPick.id
            $ideaPrev = [string]$selfDevPick.text
            if ($ideaPrev.Length -gt 80) { $ideaPrev = $ideaPrev.Substring(0,80) + '…' }
            Add-Message -From system -Text ("🌱 Само-развитие [диск=$selfDevTier]: беру НОВУЮ идею автономно (риск=$selfDevTierOfPick · $selfDevReason): «$ideaPrev»") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-exec-claim'; item_id=[string]$selfDevPick.id; tier=$selfDevTierOfPick; reason=$selfDevReason; dial=$selfDevTier }) } catch {}
          }
        }
      }
      # 2026-05-28: dirty-state guard. Before starting an autonomous task,
      # verify the bridge's working tree is clean. Starting work on top of
      # uncommitted edits leads to two bad outcomes: (a) Codex/Claude's diff
      # mixes its changes with whatever was sitting in the tree, making
      # rollback impossible; (b) a watchdog restart loses everything that
      # wasn't committed. Hold the task and ping the operator instead.
      if ($claimedIdea) {
        try {
          $dirty = (& git -C $bridgeRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          # Filter out the perennial autosaved files that aren't real edits
          $dirty = @($dirty | Where-Object {
            $line = ([string]$_).Substring(3).Trim()
            $line -notmatch '^(decisions/session-ledger\.jsonl|turns\.jsonl|channels/[^/]+/state\.json|channels/[^/]+/conversation\.jsonl|features/state\.json|control/.*\.log|audit/.*\.md|audit/.*\.json|logs/.*)$'
          })
          if ($dirty.Count -gt 0) {
            # Dirty tree is a TRANSIENT condition (uncommitted edits), so do NOT change the idea's
            # status -- marking it 'held' would STRAND it, since the selectors only pick 'new'/
            # 'approved' (this silently wedged self-/backlog tasks whenever a stray file sat in the
            # tree). Leave the idea in the queue and just skip this tick; it gets re-picked once the
            # tree is clean. Dedupe the notice by idea id so idle ticks don't spam while it stays dirty.
            if ([string]$claimedIdea.id -ne [string]$script:lastDirtyDeferId) {
              $script:lastDirtyDeferId = [string]$claimedIdea.id
              $preview = ($dirty | Select-Object -First 5 | ForEach-Object { ([string]$_).Trim() }) -join '; '
              Add-Message -From system -Text ("🚧 Автозадача отложена: рабочее дерево не чистое ($($dirty.Count) файлов). Закоммить или сделай stash; мост возьмёт задачу как только дерево станет чистым (идея остаётся в очереди). Превью: $preview") -Kind event | Out-Null
            }
            $claimedIdea = $null
          }
        } catch {
          # If git itself errors, fail open — better to start the task than wedge
          # the loop. The watchdog/critic will catch a bad commit downstream.
        }
      }
      # 🌒 Shadow observability (graduated autonomy; autonomy.selfExecuteTier). When an UNapproved
      # 'new' idea WOULD be the next self-pick but is NOT being executed this tick -- either the dial
      # is 'shadow' (observe-only) or the top idea's risk tier exceeds the dial -- surface it in chat
      # WITHOUT running it. (When the dial DID auto-claim an in-dial idea, $selfDevClaimed is set and
      # the claim path above already announced it.) Posts only when the would-pick CHANGES, so idle
      # ticks don't spam. main channel only.
      if ((-not $claimedIdea) -and (-not $selfDevClaimed) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main')) {
        try {
          $selfTier = if ($selfDevTier) { $selfDevTier } else { 'shadow' }
          if ($selfTier -and $selfTier -ne 'off' -and (Test-AutonomyReady)) {
            $shadowPick = $null
            try { $shadowPick = Get-NextRunnableIdea -IncludeNew $true } catch {}
            $shadowId = if ($shadowPick) { [string]$shadowPick.id } else { '' }
            # Only act when the would-pick CHANGES, so we don't repost every idle tick.
            if ($shadowId -ne [string]$script:lastShadowIdeaId) {
              $script:lastShadowIdeaId = $shadowId
              if ($shadowPick -and ([string]$shadowPick.status -eq 'new')) {
                $rt = Get-IdeaRiskTier -Idea $shadowPick
                $tier = [string]$rt.tier; $why = [string]$rt.reason
                try { Set-IdeaRiskTier -Id $shadowId -Tier $tier -Reason $why | Out-Null } catch {}
                $verb = if ($selfTier -eq 'shadow') { 'взяла бы (shadow, без запуска)' }
                        else { "НЕ запускает (риск=$tier выше диска=$selfTier)" }
                $ideaText = [string]$shadowPick.text
                if ($ideaText.Length -gt 80) { $ideaText = $ideaText.Substring(0,80) + '…' }
                Add-Message -From system -Text ("🌒 Само-развитие [диск=$selfTier]: $verb новую идею «$ideaText» · риск=$tier · $why") -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='shadow-pick'; item_id=$shadowId; tier=$tier; reason=$why; dial=$selfTier; would_execute=$false }) } catch {}
              }
            }
          }
        } catch {}
      }
      if ($claimedIdea) {
        $script:idleStreak = 0   # autonomous task claimed -> snappy idle again once it finishes
        $bid = [string]$claimedIdea.id
        $btext = '[Автозадача из бэклога] ' + [string]$claimedIdea.text
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $studyDetect = Detect-StudyMode -TaskText $btext -IsAutonomous
        $baseCommit = try { (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch { '' }
        Update-State ({ param($s)
          $s.current_task=$btext; $s.task_turn=0; $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
          Start-ReplayForStateTask -State $s -TaskText $btext -ChannelName $Channel
          Clear-FastLaneFlags $s
          if ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
          $s.task_start_seq=[int]$s.lastSeq; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$bid; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o')
          $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
          $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          Clear-AuditorSuppressedHashes -State $s
          Clear-ChunkingState $s
          $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
          $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
          Reset-TaskAgentDuration $s
          if ([string]$s.autonomous_day -eq $today) { $s.autonomous_count=[int]$s.autonomous_count+1 } else { $s.autonomous_day=$today; $s.autonomous_count=1 }
        }.GetNewClosure()) | Out-Null
        try {
          $taskText = [string]$btext
          $taskForLedger = if ($taskText.Length -gt 120) { $taskText.Substring(0,120) } else { $taskText }
          Add-SessionDecisionEvent -EventType 'task_start' -Meta @{ task=$taskForLedger } -Channel $Channel
          $mGoal = if ($taskText.Length -gt 600) { $taskText.Substring(0,600) } else { $taskText }
          Update-State ({ param($s)
            $s.session_mission = [pscustomobject]@{ goal=$mGoal; next_step=''; accepted_decisions=@(); constraints=@(); recent_done=@(); blockers=@() }
          }.GetNewClosure()) | Out-Null
        } catch {}
        try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
        try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
        try { Set-Idea -Id $bid -Status 'running' -IncrementAttempts $true | Out-Null } catch {}
        Add-Message -From system -Text "🤖 Беру задачу из бэклога в работу (автономно): $([string]$claimedIdea.text)" -Kind event | Out-Null
        if ($studyDetect) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: backlog" -Kind event | Out-Null }
        $state = Read-State
      } else {
        Update-State { param($s) $s.status='idle'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        try { Start-LibrarianIfDue } catch {}
        try { Start-AuditIfDue } catch {}
        try { Start-FeatureVerifierIfDue } catch {}
        try { Update-FeatureActivations | Out-Null } catch {}
        try { Start-ReflectIfDue } catch {}
        try { Start-TechRadarIfDue } catch {}
        try { Start-CanaryIfDue } catch {}
        # 🧹 Anti-junk hygiene: archive unclaimed 'new' ideas older than ideaStaleDays. Throttled to
        # once per 24h via control/stale-sweep.last so it's near-free on the idle path.
        try {
          $ssMarker = Join-Path (Get-BridgeRoot) 'control\stale-sweep.last'
          $ssDue = $true
          if (Test-Path $ssMarker) { try { $ssDue = (((Get-Date) - [datetime]((Get-Content $ssMarker -Raw -Encoding UTF8).Trim())).TotalHours -ge 24) } catch {} }
          if ($ssDue) {
            [System.IO.File]::WriteAllText($ssMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $staleN = Invoke-BacklogStaleSweep
            if ($staleN -gt 0) { Add-Message -From system -Text "🧹 Гигиена бэклога: $staleN неразобранных идей старше срока → авто-архив (auto-stale)." -Kind event | Out-Null }
          }
        } catch {}
        # 🗄 Archive hygiene: weekly prune of conversation.archive.jsonl (lines older than 7 days).
        # Only the archive sidecar is touched — never the live chat or summary — so this can NOT
        # affect the bridge's context. Throttled via control/archive-prune.last (~7d).
        try {
          $apMarker = Join-Path (Get-BridgeRoot) 'control\archive-prune.last'
          $apDue = $true
          if (Test-Path $apMarker) { try { $apDue = (((Get-Date) - [datetime]((Get-Content $apMarker -Raw -Encoding UTF8).Trim())).TotalDays -ge 7) } catch {} }
          if ($apDue) {
            [System.IO.File]::WriteAllText($apMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $prunedN = Invoke-ConversationArchivePrune -MaxAgeDays 7
            if ($prunedN -gt 0) { Add-Message -From system -Text "🗄 Архив чата почищен: удалено $prunedN сообщений старше 7 дней (из архива, не из чата)." -Kind event | Out-Null }
          }
        } catch {}
        # 2026-05-27v6: log rotation every idle tick (cheap — Rotate-LogIfBig
        # is O(1) when file is under limit). 2MB cap = ~1 month of metrics.
        try {
          $brRoot = Get-BridgeRoot
          Rotate-LogIfBig -Path (Join-Path $brRoot 'metrics.jsonl')      -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'usage.jsonl')        -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'bridge-lock.log')    -MaxKB 512  -Keep 2 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'critic.log')         -MaxKB 1024 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-leak.log')  -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-sweep.log') -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\children.jsonl') -MaxKB 256 -Keep 1 | Out-Null
        } catch {}
        # 2026-05-27v6: sweep registered child processes (audit P2 -- detect crashed children)
        try { Sweep-ChildProcesses -MaxAgeMin 30 | Out-Null } catch {}
        # 2026-05-28: sweep orphan codex.exe processes (real incident: 11 zombies
        # accumulated, one 22h old, 360MB resident). NEVER touches claude.exe
        # (user IDE is also claude.exe). Configurable cutoff via config.json
        # orphanSweep.codexMaxIdleMin, default 30 minutes.
        try {
          $orphMax = 30
          try {
            $cfgO = Get-BridgeConfig
            if ($cfgO -and $cfgO.PSObject.Properties.Name -contains 'orphanSweep' -and $cfgO.orphanSweep -and $cfgO.orphanSweep.codexMaxIdleMin) {
              $orphMax = [int]$cfgO.orphanSweep.codexMaxIdleMin
            }
          } catch {}
          if ($orphMax -lt 5) { $orphMax = 5 }
          $ores = Sweep-OrphanAgentProcesses -MaxIdleMin $orphMax
          if ($ores -and [int]$ores.killed -gt 0) {
            Add-Message -From system -Text ("🧹 Auto-sweep: убит " + $ores.killed + " orphan codex.exe (старше " + $orphMax + " мин, не привязан к активному агенту)") -Kind event | Out-Null
          }
        } catch {}
        # Adaptive backoff: snappy for the first $idleFastTicks ticks after activity, then
        # +1s per extra consecutive idle tick, capped at $idleMaxPoll. Cuts redundant ~1Hz wakeups.
        $script:idleStreak = [int]$script:idleStreak + 1
        $sleepSec = $idlePoll
        if ($script:idleStreak -gt $idleFastTicks) { $sleepSec = [Math]::Min($idleMaxPoll, $idlePoll + ($script:idleStreak - $idleFastTicks)) }
        Start-Sleep -Seconds $sleepSec; continue
      }
    }
  } else {
    if ($maxUser -gt [int]$state.last_user_seq) { Update-State ({ param($s) $s.last_user_seq=$maxUser }.GetNewClosure()) | Out-Null }
  }

  $task = [string]$state.current_task
  $tt   = [int]$state.task_turn
  $mode = if ($state.task_mode) { [string]$state.task_mode } else { 'normal' }
  $forcePlanner = [bool]$state.force_planner
  $forceCoder = $false
  try { $forceCoder = [bool]$state.force_coder } catch {}
  $skipPlanner = [bool]$state.skip_planner
  $speaker = if ($forceCoder) { 'codex' }
              elseif ($forcePlanner) { 'claude' }
              elseif ($mode -eq 'research') { 'claude' }
              elseif ($mode -eq 'study') { Get-StudySpeaker -TaskTurn $tt -StudySubtype ([string]$state.study_subtype) -StudyPhase ([string]$state.study_phase) }
              elseif ($skipPlanner -and $mode -eq 'normal' -and $tt -eq 0) { 'codex' }
              elseif ($tt -eq 0) { 'claude' }
              else { Next-Speaker }
  if ($forcePlanner) { Update-State { param($s) $s.force_planner=$false } | Out-Null }
  if ($forceCoder) { Update-State { param($s) $s.force_coder=$false } | Out-Null }
  $plannerEscalate = $false
  try { $plannerEscalate = ([int](Read-State).timeout_retry_count -ge 1) } catch {}
  $plannerModel = Select-PlannerModel -TaskText $task -Mode $mode -Escalate $plannerEscalate
  $activeModel  = if ($speaker -eq 'claude') { $plannerModel } else { 'codex' }
  $statusText   = Get-AgentStatusText -Speaker $speaker -Mode $mode -TaskText $task
  Update-State ({ param($s) $s.active_agent=$speaker; $s.active_model=$activeModel; $s.status_text=$statusText; $s.status='working'; $s.claimed_at=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null

  $fastLaneTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'summary' -TaskText $task)
  if (-not $fastLaneTurn) { Update-ContextSummary }   # compress old history if it grew beyond the hot window
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'prompt' -TaskText $task)
  $prompt = Build-Prompt -Role $speaker -Task $task -Mode $mode -FastLane:$fastLaneTurn
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'invoke' -TaskText $task)
  $turnStart = [DateTime]::UtcNow
  $headBeforeTurn = ''
  try { $headBeforeTurn = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch {}
  try {
    if ($speaker -eq 'claude') { $turnResult = Invoke-Planner -Prompt $prompt -Model $plannerModel -Mode $mode }
    else {
      $turnResult = Invoke-Coder -Prompt $prompt -Mode $mode
      # Track that the coder role actually ran for this task. A Claude fallback counts as
      # the coder for this turn because it has write tools and is not merely advisory.
      if ($turnResult.status -eq 'ok') { Update-State { param($s) $s.coder_fired = $true } | Out-Null }
    }
  } catch {
    Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $_.Exception.Message -Status 'error'
    throw
  }
  $reply = [string]$turnResult.text
  Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $reply -Status ([string]$turnResult.status)
  $guardChannelSlug = [string]$Channel
  try { $guardChannelSlug = Normalize-ChannelSlug $guardChannelSlug } catch {}
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and $guardChannelSlug -ne 'main') {
    try {
      $bridgeHeadAfterGuard = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
      $bridgeDirtyAfterGuard = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      if (($headBeforeTurn -and $bridgeHeadAfterGuard -and $headBeforeTurn -ne $bridgeHeadAfterGuard) -or @($bridgeDirtyAfterGuard).Count -gt 0) {
        $changed = if (@($bridgeDirtyAfterGuard).Count -gt 0) { @($bridgeDirtyAfterGuard) -join ', ' } else { "commit $($headBeforeTurn.Substring(0,7))..$($bridgeHeadAfterGuard.Substring(0,7))" }
        $guardMsg = "⚠ Project-focus guard: канал '$guardChannelSlug' не является main, но после coder-хода изменился bridge: $changed. Останавливаю дальнейшие шаги и возвращаю планировщику для разбора."
        try { Set-TaskLastFailure -Kind bridge_guard -Text $guardMsg } catch {}
        Add-Message -From system -Text $guardMsg -Kind event | Out-Null
        Update-State { param($s) $s.force_planner=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        continue
      }
    } catch {
      Add-Message -From system -Text ("⚠ Project-focus guard не смог проверить bridge diff: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  try {
    $turnSec = 0
    try { $turnSec = [int]$turnResult.duration } catch {}
    if ($turnSec -gt 0) {
      Update-State ({ param($s)
        $curSec = 0
        try { $curSec = [int]$s.task_agent_duration_sec } catch {}
        $s | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue ($curSec + $turnSec) -Force
      }.GetNewClosure()) | Out-Null
    }
  } catch {}
  if ($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') {
    try {
      $headAfterTurn = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim()
      if (-not [string]::IsNullOrWhiteSpace($headBeforeTurn) -and -not [string]::IsNullOrWhiteSpace($headAfterTurn) -and $headBeforeTurn -ne $headAfterTurn) {
        $commitLines = @(& git -C $bridgeRoot log --reverse --format='%H%x09%s' "$headBeforeTurn..$headAfterTurn" 2>$null)
        foreach ($cl in $commitLines) {
          $parts = @(([string]$cl) -split "`t", 2)
          if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) { continue }
          $sha = [string]$parts[0]
          $subj = if ($parts.Count -ge 2) { [string]$parts[1] } else { '' }
          $shortSha = if ($sha.Length -gt 7) { $sha.Substring(0, 7) } else { $sha }
          Add-TaskCheckpoint -Kind commit -Text (($shortSha + ' ' + $subj).Trim())
          try {
            $pmState = Read-State
            if ($pmState -and ($pmState.PSObject.Properties.Name -contains 'task_last_failure') -and $null -ne $pmState.task_last_failure) {
              $pmPath = Invoke-PostMortem -CommitSha $sha -State $pmState -RepoRoot $bridgeRoot -TimeoutSec 30
              if ($pmPath) { Add-Message -From system -Text ("📋 Post-mortem создан: " + $pmPath) -Kind event | Out-Null }
            }
          } catch {
            try { Add-Message -From system -Text ("⚠ Post-mortem не создан: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
          }
        }
      }
    } catch {}
  }

  # 2026-05-29: close the Gate-A commit gap. Codex runs in a workspace-write sandbox that BLOCKS
  # writes to .git (index.lock ACL "Permission denied"), so it often can't commit its own work and
  # reports "can't close the task honestly -- need a git commit via the driver". The driver runs
  # OUTSIDE the sandbox, so it commits the coder's verified edits right here. Without this, edits
  # sat uncommitted until a later turn happened to win the ACL race (real friction + extra loops).
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and ([string]$turnResult.status -eq 'ok')) {
    try {
      $headNowAC = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
      if ($headNowAC -and $headBeforeTurn -and $headNowAC -eq $headBeforeTurn) {
        $acDirty = @(& git -C $bridgeRoot status --porcelain 2>$null | Where-Object {
          $line = ([string]$_).Substring(3).Trim()
          $line -notmatch '^(decisions/session-ledger\.jsonl|turns\.jsonl|channels/[^/]+/state\.json|channels/[^/]+/conversation\.jsonl|features/state\.json|control/.*|audit/.*|logs/.*)$'
        })
        if (@($acDirty).Count -gt 0) {
          $acFiles = @()
          foreach ($d in $acDirty) {
            $l = [string]$d; if ($l.Length -le 3) { continue }
            $nm = $l.Substring(3).Trim()
            if ($nm -match ' -> ') { $nm = ($nm -split ' -> ', 2)[1].Trim() }
            $nm = $nm.Trim('"'); if ($nm) { $acFiles += $nm }
          }
          if ($acFiles.Count -gt 0) {
            $acMsg = 'auto-commit (driver; coder sandbox cannot reach .git): ' + (($task -replace '\s+',' ').Trim())
            if ($acMsg.Length -gt 180) { $acMsg = $acMsg.Substring(0,180) }
            & git -C $bridgeRoot add -- @($acFiles) 2>$null | Out-Null
            & git -C $bridgeRoot commit -m $acMsg 2>$null | Out-Null
            $acNewHead = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
            if ($acNewHead -and $acNewHead -ne $headBeforeTurn) {
              try { Add-TaskCheckpoint -Kind commit -Text (($acNewHead.Substring(0,7) + ' ' + $acMsg).Trim()) } catch {}
              Add-Message -From system -Text ("💾 Драйвер зафиксировал правки Codex (coder в sandbox не имеет доступа к .git): " + $acNewHead.Substring(0,7)) -Kind event | Out-Null
            }
          }
        }
      }
    } catch {}
  }

  if ((Read-State).abort) { continue }   # killed mid-turn -> handled at top

  if ($turnResult.status -eq 'preflight_blocked' -or [bool]$turnResult.preflightBlocked) {
    $reason = [string]$turnResult.reason
    if ([string]::IsNullOrWhiteSpace($reason)) {
      $reason = ([string]$reply) -replace '^PREFLIGHT_BLOCKED:\s*',''
    }
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'неизвестная причина' }
    try { Set-TaskLastFailure -Kind preflight_blocked -Text $reason } catch {}
    Add-Message -From system -Text ("Pre-flight gate заблокировал запуск Codex: " + $reason + ". Claude, дай инструкцию повторно, когда условие снято, или ответь пользователю через CHAT.") -Kind event | Out-Null
    Update-State { param($s) $s.force_planner=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
    continue
  }

  # Handle agent timeouts as retryable structured errors.
  if ($turnResult.status -eq 'timeout') {
    $who = if ($turnResult.errorType -eq 'coder_timeout') { 'Codex' } else { 'Claude' }
    $dur = [int]$turnResult.duration
    $trc = [int](Read-State).timeout_retry_count
    # 🩺 Long timeouts (>= ~60% of cap) almost never come back via retry — same prompt would
    # just timeout again, wasting another 500+s. Heuristic threshold 350s catches both planner
    # (cap 600s) and coder (cap 900s after Doctor raised it 4cb5f53). User feedback 2026-05-26:
    # "Doctor didn't appear on timeout" -> now Doctor activates ON the long timeout, not after retry.
    $isLongTimeout = ($dur -ge 350)
    if ($trc -lt 1 -and -not $isLongTimeout -and -not [bool](Read-State).doctor_active) {
      Add-Message -From system -Text "⏱ Таймаут $who (${dur}с, $($turnResult.errorType)) — короткий, повторяю попытку..." -Kind event | Out-Null
      $newTrc = $trc + 1
      $mutTrc = { param($s) $s.timeout_retry_count = $newTrc; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()
      Update-State $mutTrc | Out-Null
      continue
    } else {
      try { Invoke-PostMortem -FailureType 'timeout' -Task $task -Context "$($turnResult.errorType) (${dur}с)" } catch {}
      # 🩺 If we're already inside a Doctor task and Doctor itself timed out, escalate -- don't recurse.
      if ([bool](Read-State).doctor_active) {
        Add-Message -From system -Text "⏱ Доктор сам упёрся в таймаут (${dur}с). Эскалирую оператору." -Kind event | Out-Null
        try { Abort-Doctor -Reason "doctor timeout (${dur}с)" } catch {}
        Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      } else {
        $reasonMsg = if ($trc -ge 1) { "повторился (${dur}с)" } elseif ($isLongTimeout) { "длинный (${dur}с) — retry почти наверняка снова упрётся" } else { "(${dur}с)" }
        Add-Message -From system -Text "⏱ Таймаут $who $reasonMsg. Передаю Доктору на саморемонт." -Kind event | Out-Null
        $activationDetail = if ($trc -ge 1) { "${dur}с после retry" } elseif ($isLongTimeout) { "${dur}с — длинный, без retry" } else { "${dur}с" }
        try { Activate-Doctor -Reason ([string]$turnResult.errorType) -Detail $activationDetail | Out-Null } catch {}
        Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      }
      continue
    }
  }
  Update-State { param($s) $s.timeout_retry_count=0 } | Out-Null

  # Safety gate: intercept dangerous-action flag from Codex before processing reply
  if ($speaker -eq 'codex') {
    $safetyPat = '(?m)^\s*\[\[SAFETY:\s*(.+?)\s*\]\]\s*$'
    $safetyM = [regex]::Match([string]$reply, $safetyPat)
    if ($safetyM.Success) {
      $safetyDesc = $safetyM.Groups[1].Value.Trim()
      $preReply = [regex]::Replace([string]$reply, $safetyPat, '').Trim()
      if (-not [string]::IsNullOrWhiteSpace($preReply)) {
        Add-Message -From codex -Text $preReply | Out-Null
      }
      Add-Message -From system -Text "🛡 SAFETY GATE: Codex запрашивает разрешение:`n`n**$safetyDesc**`n`nНапиши «да, выполни» для подтверждения, или дай иную инструкцию." -Kind event | Out-Null
      try { Send-PushEvent -Kind gate -Text $safetyDesc } catch {}
      try { Invoke-PostMortem -FailureType 'safety' -Task $task -Context "SAFETY: $safetyDesc" } catch {}
        Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      continue
    }
  }

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'post' -TaskText $task)
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = "(нет ответа от $speaker)" }
  $fastLaneActiveForTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  $attachmentMetas = @()
  $failedAttachmentPaths = @()
  $fileMarkerPaths = @()
  $fileMarkerPattern = '(?m)^\s*\[\[FILE:\s*(.+?)\s*\]\]\s*$'
  foreach ($match in [regex]::Matches($reply, $fileMarkerPattern)) {
    $sourcePath = $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    if ($sourcePath.StartsWith('<') -and $sourcePath.EndsWith('>') -and $sourcePath.Length -gt 2) {
      $sourcePath = $sourcePath.Substring(1, $sourcePath.Length - 2).Trim()
    }
    $fileMarkerPaths += $sourcePath
    $meta = Register-AttachmentPath -SourcePath $sourcePath
    if ($meta) {
      $attachmentMetas += $meta
      try { Add-TaskCheckpoint -Kind file -Text $sourcePath } catch {}
    }
    else { $failedAttachmentPaths += $sourcePath }
  }
  # Auto-detect image file paths from markdown links: [name](</C:/path.png>)
  $imgMdPattern = '\[[^\]]*\]\(<\/?([^>]+\.(?:png|jpg|jpeg|gif|bmp|webp))>\)'
  foreach ($mdMatch in [regex]::Matches($reply, $imgMdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $mdMatch.Groups[1].Value.Trim()
    if ($imgPath -match '^/([A-Za-z]:.*)') { $imgPath = $Matches[1] }
    $imgPath = $imgPath.Replace('/', '\')
    $normalized = $imgPath
    if ($normalized -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # Best-effort: bare Windows paths (no spaces supported)
  $imgBarePattern = '([A-Za-z]:\\[^\s\[\]<>"'']+\.(?:png|jpg|jpeg|gif|bmp|webp))'
  foreach ($bareMatch in [regex]::Matches($reply, $imgBarePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $bareMatch.Groups[1].Value.Trim()
    if ($imgPath -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # [[SAVE: title]] ... [[/SAVE]] -> durable decision note
  $savePattern = '(?s)\[\[SAVE:\s*(.+?)\s*\]\](.*?)\[\[/SAVE\]\]'
  $savedPaths = @()
  foreach ($m in [regex]::Matches($reply, $savePattern)) {
    $st = $m.Groups[1].Value.Trim(); $sc = $m.Groups[2].Value.Trim()
    if ($sc) { $savedPaths += (Save-Decision -Title $st -Content $sc) }
  }
  $evidencePattern = '(?m)^\s*\[\[EVIDENCE:\s*(.+?)\s*\]\]\s*$'
  $verifiedPattern = '(?m)^\s*\[\[VERIFIED:\s*(.+?)\s*\]\]\s*$'
  $evidenceSources = @()
  foreach ($m in [regex]::Matches($reply, $evidencePattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $source = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $summary = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $confidence = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($source)) { continue }
    if (Write-EvidenceLog -Agent $speaker -Task $task -Source $source -Summary $summary -Confidence $confidence) {
      $evidenceSources += $source
    }
  }
  foreach ($m in [regex]::Matches($reply, $verifiedPattern)) {
    $vtext = $m.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($vtext)) {
      try { Add-TaskCheckpoint -Kind verified -Text $vtext } catch {}
      try { Add-SessionDecisionEvent -EventType 'verified_commit' -Meta @{ what=$vtext.Substring(0,[Math]::Min(100,$vtext.Length)) } -Channel $Channel } catch {}
    }
  }
  $findingPattern = '(?m)^\s*\[\[FINDING:\s*(.+?)\s*\]\]\s*$'
  $studyFindings = @()
  foreach ($m in [regex]::Matches($reply, $findingPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 2)
    $fsrc = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $ffact = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($fsrc)) { $studyFindings += "$fsrc | $ffact" }
  }
  $studyFallbackPattern = '(?m)^\s*\[\[STUDY_FALLBACK:\s*external\s*\]\]\s*$'
  if ($reply -imatch '\[\[STUDY_FALLBACK:\s*external\s*\]\]') {
    Update-State { param($s) $s.study_subtype='external'; $s.study_phase='gather-web' } | Out-Null
    Add-Message -From system -Text "📚 Study: путь не является репозиторием — переключаюсь на external." -Kind event | Out-Null
  }
  $pbForMarkers = Get-ActiveProjectBinding
  $channelIsMainMarkers = ($pbForMarkers -and ([string]$pbForMarkers.slug -eq 'main'))

  # [[REMEMBER: fact]] -> agent deliberately pushes a durable memory (no gate -- the agent chose).
  $rememberPattern = '(?m)^\s*\[\[REMEMBER:\s*(.+?)\s*\]\]\s*$'
  $rememberedFacts = @()
  foreach ($m in [regex]::Matches($reply, $rememberPattern)) {
    $fact = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($fact)) { continue }
    try {
      $rid = Add-Memory -Text $fact -Tags @('explicit', $speaker) -Source ('explicit:' + $speaker) -Importance 0.75 -Channel ([string]$pbForMarkers.slug)
      if ($rid) { $rememberedFacts += $fact }
    } catch {}
  }
  # [[IDEA: ...]] -> agent raises a self-improvement idea into the backlog (status 'new').
  $ideaPattern = '(?m)^\s*\[\[IDEA:\s*(.+?)\s*\]\]\s*$'
  $proposedIdeas = New-Object System.Collections.Generic.List[string]
  # 2026-05-28: suppress mid-task echoing of the user spec back as "ideas".
  # Real incident: my Phase 1 task spec mentioned "Этап 2: Test-FeatureSimilarity",
  # the planner emitted [[IDEA: добавить Test-FeatureSimilarity...]] in turn 1 as
  # a sincere idea — but it's just the user's roadmap restated. We compare each
  # idea-text against the current task text by word-overlap; >50% → suppress.
  # Also gather words from current task for cheap overlap check.
  $taskTextForSuppress = ''
  try { $taskTextForSuppress = [string](Read-State).current_task } catch {}
  $taskNorm = ''
  $taskWords = @()
  if (-not [string]::IsNullOrWhiteSpace($taskTextForSuppress)) {
    $taskNorm = ($taskTextForSuppress -replace '\s+',' ').Trim().ToLowerInvariant()
    $taskWords = @($taskNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
  }
  foreach ($m in [regex]::Matches($reply, $ideaPattern)) {
    $idea = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($idea)) { continue }
    # Mid-task echo guard
    if ($taskWords.Count -gt 5) {
      try {
        $ideaNorm = ($idea -replace '\s+',' ').Trim().ToLowerInvariant()
        $ideaWords = @($ideaNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
        if ($ideaWords.Count -gt 2) {
          $shared = ($ideaWords | Where-Object { $taskWords -contains $_ }).Count
          $ratio = $shared / [Math]::Max(1, $ideaWords.Count)
          if ($ratio -gt 0.5) {
            Add-Message -From system -Text ("💡 Идея пропущена (повтор текста задачи, overlap " + ('{0:N2}' -f $ratio) + "): " + ($idea.Substring(0,[Math]::Min(80,$idea.Length)))) -Kind event | Out-Null
            continue
          }
        }
      } catch {}
    }
    try {
      $ideaScope = if ($channelIsMainMarkers) { 'bridge' } else { 'project' }
      $addIdeaResult = Add-Idea -Text $idea -From $speaker -Tags @($speaker) -Status 'new' -Project ([string]$pbForMarkers.slug) -Scope $ideaScope
      $ideaOutcome = Resolve-AddIdeaOutcome -AddResult $addIdeaResult -IdeaText $idea -From $speaker
      if ($ideaOutcome.deduped) {
        $cosineText = 'n/a'
        if ($null -ne $ideaOutcome.cosine) {
          try { $cosineText = ('{0:N2}' -f ([double]$ideaOutcome.cosine)) } catch {}
        }
        $dedupId = if ([string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) { 'unknown' } else { [string]$ideaOutcome.itemId }
        Add-Message -From system -Text "💡 Идея уже в беклоге (cosine $cosineText): id=$dedupId" -Kind event | Out-Null
      } elseif ($ideaOutcome.created -and -not [string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) {
        [void]$proposedIdeas.Add($idea)
      } elseif ($addIdeaResult) {
        [void]$proposedIdeas.Add($idea)
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Add-Idea failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  # [[RUNJOB: команда | папка]] -> запустить долгую команду в фоне (без таймаута хода).
  $runjobPattern = '(?m)^\s*\[\[RUNJOB:\s*(.+?)\s*\]\]\s*$'
  $startedJobs = @()
  foreach ($m in [regex]::Matches($reply, $runjobPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    $parts = $spec -split '\|', 2
    $jcmd = $parts[0].Trim()
    $jdir = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($jcmd)) { continue }
    try { $job = Start-BridgeJob -Command $jcmd -WorkDir $jdir; if ($job) { $startedJobs += $job } } catch {}
  }
  if ($startedJobs.Count -gt 0) {
    $sj = $startedJobs
    Update-State ({ param($s) $cur=@(); if ($s.active_jobs) { $cur=@($s.active_jobs) }; $s.active_jobs=@($cur + $sj) }.GetNewClosure()) | Out-Null
    foreach ($job in $sj) { Add-Message -From system -Text "🛠 Запущена фоновая задача [$($job.id)]: $($job.cmd)`nЖду завершения (без таймаута), результат придёт сюда." -Kind event | Out-Null }
  }
  # [[NEED-TOOL: имя | контракт]] -> синтез инструмента на лету (Tool Foundry, Ф1). Сборка
  # идёт в песочнице (Build-AutoTool: parse -> smoke в ДОЧЕРНЕМ процессе -> критик на ДРУГОЙ
  # модели); зелёный инструмент пишется в tools/auto/<имя>.ps1 и СРАЗУ dot-source'ится здесь
  # (мы в script-scope верхнеуровневого while-цикла), поэтому Invoke-<имя> доступен и этому
  # ходу, и всем следующим. Reuse-before-rebuild: активный одноимённый инструмент не пересобираем.
  $needToolPattern = '(?m)^\s*\[\[NEED-TOOL:\s*(.+?)\s*\]\]\s*$'
  foreach ($m in [regex]::Matches($reply, $needToolPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    $ntParts = $spec -split '\|', 2
    $ntName = $ntParts[0].Trim()
    $ntContract = if ($ntParts.Count -ge 2) { $ntParts[1].Trim() } else { '' }
    $ntSafe = $null
    try { $ntSafe = Test-AutoToolName -Name $ntName } catch {}
    if (-not $ntSafe) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL]] отклонён: недопустимое имя '" + $ntName + "'. Нужно латиницей: буква, далее буквы/цифры/_ и дефис.") -Kind event | Out-Null
      continue
    }
    if ([string]::IsNullOrWhiteSpace($ntContract)) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL: " + $ntSafe + "]] без контракта. Формат: [[NEED-TOOL: имя | что инструмент делает]].") -Kind event | Out-Null
      continue
    }
    $ntExisting = $null
    try { $ntExisting = Get-AutoTool -Name $ntSafe } catch {}
    if ($ntExisting -and ([string]$ntExisting.status -eq 'active')) {
      Add-Message -From system -Text ("🔧 Инструмент '" + $ntSafe + "' уже есть (вызов: Invoke-" + $ntSafe + "). Переиспользуй — не пересобираю.") -Kind event | Out-Null
      continue
    }
    Add-Message -From system -Text ("🏗 Tool Foundry: синтез '" + $ntSafe + "' в песочнице (parse → smoke → критик)…") -Kind event | Out-Null
    $ntBuilt = $null
    try { $ntBuilt = Build-AutoTool -Name $ntSafe -Contract $ntContract } catch { $ntBuilt = $null }
    if ($ntBuilt -and $ntBuilt.ok) {
      try {
        $ntFile = Join-Path (Get-ToolForgeRoot) ($ntBuilt.name + '.ps1')
        if (Test-Path -LiteralPath $ntFile) { . $ntFile }   # load into engine script-scope NOW
      } catch {}
      Add-Message -From system -Text ("✅ Инструмент готов: '" + $ntBuilt.name + "' (вызов: " + $ntBuilt.entry + "). Контракт: " + $ntContract + ". Доступен сразу и на следующих ходах.") -Kind event | Out-Null
    } else {
      $ntWhy = if ($ntBuilt) { [string]$ntBuilt.reason } else { 'сборка упала (исключение)' }
      Add-Message -From system -Text ("⚠ Не построил '" + $ntSafe + "' → карантин. Причина: " + $ntWhy + ". Сделай задачу без него или уточни контракт и повтори [[NEED-TOOL]].") -Kind event | Out-Null
    }
  }
  # [[PLAN]] ... [[/PLAN]] -> создать persisted план-доску для текущей задачи.
  $planBlockPattern = '(?is)\[\[PLAN\]\].*?\[\[/PLAN\]\]'
  $planCreatedStepCount = $null
  try {
    $planNodes = ConvertFrom-PlanBlock -Text $reply
    if ($planNodes) {
      $planCreatedStepCount = New-Plan -Task $task -Nodes $planNodes
    }
  } catch {
    Add-Message -From system -Text ("⚠ Не удалось создать план-доску: " + $_.Exception.Message) -Kind event | Out-Null
  }

  # [[DISPATCH-DAG]] / [[DISPATCH-DAG: N]] -> исполнить ТЕКУЩУЮ план-доску как реально
  # диспетчеризуемый DAG (Project Foundry, Ф2): готовые шаги веером уходят в параллельных
  # воркеров в worktree'ах ПРИВЯЗАННОГО ПРОЕКТА, каждый шаг гейтится (done + >=1 commit) и
  # мёрджится-или-откатывается, волна за волной. Статусы шагов план-доски пишет сам
  # Invoke-PlanDag (через Set-PlanStepStatus), поэтому после диспатча доска отражает факт.
  # Жёстко отказываемся работать над самим bridge-репозиторием (foundry-слой тоже откажет).
  $dispatchDagPattern = '(?m)^\s*\[\[DISPATCH-DAG(?::\s*(\d+))?\]\]\s*$'
  $dispatchHit = [regex]::Match($reply, $dispatchDagPattern)
  if ($dispatchHit.Success) {
    $reqPar = 0
    if ($dispatchHit.Groups[1].Success) { try { $reqPar = [int]$dispatchHit.Groups[1].Value } catch { $reqPar = 0 } }
    $binding = $null
    try { $binding = Get-ChannelProjectBinding -Slug $Channel } catch { $binding = $null }
    if (-not $binding -or -not [bool]$binding.ok) {
      $bwhy = if ($binding) { [string]$binding.error } else { 'нет привязки' }
      Add-Message -From system -Text ("⚠ [[DISPATCH-DAG]] пропущен: канал не привязан к проекту ($bwhy). Сначала создай проект (New-Project) и привяжи канал.") -Kind event | Out-Null
    } else {
      $projRoot = [string]$binding.project_root
      $bridgeFull = ''; try { $bridgeFull = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\','/') } catch {}
      $projFull = $projRoot; try { $projFull = [System.IO.Path]::GetFullPath($projRoot).TrimEnd('\','/') } catch {}
      if ($projFull -and $bridgeFull -and $projFull.Equals($bridgeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Message -From system -Text "⚠ [[DISPATCH-DAG]] отклонён: канал указывает на сам bridge-репозиторий. DAG-исполнение работает только над отдельным проектом." -Kind event | Out-Null
      } else {
        $parNote = if ($reqPar -gt 0) { " (parallel=$reqPar)" } else { "" }
        Add-Message -From system -Text ("🧭 DISPATCH-DAG: исполняю план-доску как DAG над проектом " + $projFull + $parNote + "…") -Kind event | Out-Null
        $dag = $null
        try {
          if ($reqPar -gt 0) { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot -MaxParallel $reqPar }
          else               { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot }
        } catch {
          Add-Message -From system -Text ("⚠ DISPATCH-DAG исключение: " + $_.Exception.Message) -Kind event | Out-Null
        }
        if ($dag) {
          $icon = if ([bool]$dag.ok) { "✅" } else { "⚠" }
          $dmsg = $icon + " DISPATCH-DAG: " + [string]$dag.summary
          if (-not [bool]$dag.ok -and $dag.blockers -and $dag.blockers.Count -gt 0) {
            $blines = @($dag.blockers.GetEnumerator() | ForEach-Object { [string]$_.Key + ' <- ' + ((@($_.Value) -join ', ')) }) -join '; '
            if (-not [string]::IsNullOrWhiteSpace($blines)) { $dmsg += ("`nБлокеры: " + $blines) }
          }
          Add-Message -From system -Text $dmsg -Kind event | Out-Null
        }
      }
    }
  }

  # [[STEP-DONE: id | результат]] и [[STEP: id | status | результат]] -> обновить шаги плана.
  $stepDonePattern = '(?m)^\s*\[\[STEP-DONE:\s*([^|\]]+?)(?:\s*\|\s*(.*?))?\s*\]\]\s*$'
  $stepPattern = '(?m)^\s*\[\[STEP:\s*(.+?)\s*\]\]\s*$'
  $planStepUpdates = @()
  foreach ($m in [regex]::Matches($reply, $stepDonePattern)) {
    $stepId = $m.Groups[1].Value.Trim()
    $stepResult = if ($m.Groups.Count -gt 2) { $m.Groups[2].Value.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId)) { continue }
    $stepCheckpoint = if ([string]::IsNullOrWhiteSpace($stepResult)) { $stepId } else { "$stepId | $stepResult" }
    try { Add-TaskCheckpoint -Kind step_done -Text $stepCheckpoint } catch {}
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status done -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → done" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  foreach ($m in [regex]::Matches($reply, $stepPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $stepId = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $rawStepStatus = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $stepStatus = if ($parts.Count -ge 2) { Normalize-PlanStatus -Status $rawStepStatus } else { '' }
    $stepResult = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId) -or [string]::IsNullOrWhiteSpace($stepStatus)) { continue }
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status $stepStatus -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → $stepStatus" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  $visibleReply = [regex]::Replace($reply, $fileMarkerPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $savePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $evidencePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $verifiedPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $findingPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $studyFallbackPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $rememberPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $ideaPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $runjobPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $needToolPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, '(?s)\[\[PARALLEL:.+?\]\]', '')
  $visibleReply = [regex]::Replace($visibleReply, $planBlockPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $dispatchDagPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepDonePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepPattern, '')
  if ($speaker -eq 'claude' -or [string]$turnResult.fallback -eq 'claude_as_coder' -or $fastLaneActiveForTurn) {
    $visibleReply = [regex]::Replace($visibleReply, '(?im)^\s*STATUS:\s*\w+\s*$', '')
  }
  $visibleReply = $visibleReply.Trim()
  if ($failedAttachmentPaths.Count -gt 0) {
    $failLines = ($failedAttachmentPaths | ForEach-Object { "- $_" }) -join "`n"
    $fileWarning = "⚠ Не удалось прикрепить файл:`n$failLines"
    if ([string]::IsNullOrWhiteSpace($visibleReply)) { $visibleReply = $fileWarning }
    else { $visibleReply = $visibleReply.TrimEnd() + "`n`n" + $fileWarning }
  }
  if ([string]::IsNullOrWhiteSpace($visibleReply) -and $attachmentMetas.Count -eq 0) { $visibleReply = "(нет ответа от $speaker)" }
  Add-Message -From $speaker -Text $visibleReply -Attachments $attachmentMetas -Model $activeModel | Out-Null
  foreach ($sp in $savedPaths) { Add-Message -From system -Text "📝 Заметка сохранена: $sp" -Kind event | Out-Null }
  foreach ($source in $evidenceSources) { Add-Message -From system -Text "📊 Evidence записан: $source" -Kind event | Out-Null }
  if ($null -ne $planCreatedStepCount) { Add-Message -From system -Text "🗂 План-доска создана: шагов $planCreatedStepCount" -Kind event | Out-Null }
  foreach ($pu in $planStepUpdates) { Add-Message -From system -Text "🗂 Шаг плана обновлён: $pu" -Kind event | Out-Null }
  if ($studyFindings.Count -gt 0) {
    $snap = [string](Read-State).study_snapshot
    $snapParts = @()
    if (-not [string]::IsNullOrWhiteSpace($snap)) { $snapParts += $snap.Trim() }
    $snapParts += ($studyFindings -join "`n")
    $newSnap = ($snapParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    Update-State ({ param($s) $s.study_snapshot = $newSnap }.GetNewClosure()) | Out-Null
  }
  foreach ($rf in $rememberedFacts) { Add-Message -From system -Text "🧠 Запомнено агентом: $rf" -Kind event | Out-Null }
  foreach ($pi in $proposedIdeas) { Add-Message -From system -Text "💡 Идея в бэклог (от $speaker): $pi" -Kind event | Out-Null }

  # [[PARALLEL: <repo> || подзадача1 ;; подзадача2 ;; ...]] -> планировщик запускает
  # независимые под-задачи ПАРАЛЛЕЛЬНО (каждая в своём worktree), затем мерж. Блокирует
  # ход на время выполнения (heartbeat обновляется), потом постит сводку.
  # FIX 2026-05-27: regex requires '||' so it only matches OLD external-repo syntax, NOT
  # new [[PARALLEL:N]]...[[/PARALLEL:N]] (which has no '||' and is handled later via
  # Test-CanParallelize/Invoke-ParallelDispatch).
  if ($speaker -eq 'claude') {
    $pmatch = [regex]::Match($reply, '(?s)\[\[PARALLEL:\s*((?:(?!\[\[).)+?\|\|(?:(?!\[\[).)+?)\s*\]\]')
    if ($pmatch.Success) {
      $pspec = $pmatch.Groups[1].Value.Trim()
      $prepo = Get-ActiveProjectRoot
      if ([string]::IsNullOrWhiteSpace($prepo)) { $prepo = $workRoot }
      $psubsRaw = $pspec
      if ($pspec -match '(?s)^(.*?)\|\|(.*)$') { $prepo = $matches[1].Trim(); $psubsRaw = $matches[2].Trim() }
      $psubs = @($psubsRaw -split '\s*;;\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($psubs.Count -lt 2) {
        Add-Message -From system -Text "🧩 PARALLEL проигнорирован: нужно >=2 под-задачи через ' ;; '." -Kind event | Out-Null
      } else {
        Add-Message -From system -Text "🧩 Параллельная команда: $($psubs.Count) воркеров в worktrees репозитория $prepo. Жду завершения (без таймаута)..." -Kind event | Out-Null
        $pcount = $psubs.Count
        $tick = ({ param() Update-State ({ param($s) $s.heartbeat=(Get-Date).ToString('o'); $s.status_text="🧩 Параллельные воркеры ($pcount)..." }.GetNewClosure()) | Out-Null }).GetNewClosure()
        $pres = $null
        try { $pres = Invoke-CodexParallel -RepoRoot $prepo -Subtasks $psubs -OnTick $tick -TimeoutSec 3600 } catch { Add-Message -From system -Text "🧩 Параллель: ошибка — $($_.Exception.Message)" -Kind event | Out-Null }
        if ($pres) {
          if ($pres.error) {
            Add-Message -From system -Text "🧩 Параллель не запущена: $($pres.error)" -Kind event | Out-Null
          } else {
            $plines = foreach ($pr in $pres.results) {
              $stat = if ($pr.mergeOk) { 'влито ✅' } elseif ($pr.conflict) { 'КОНФЛИКТ ⚠ (разрешить вручную)' } else { 'не влито ❌' }
              "• $($pr.name): $stat — " + (($pr.subtask -replace '\s+',' '))
            }
            Add-Message -From system -Text ("🧩 Параллель завершена: влито $($pres.merged), конфликтов $($pres.conflicts).`n" + ($plines -join "`n") + "`n`nПланировщик: проверь результат ЗАПУСКОМ, разреши конфликты если есть, доведи до DONE.") -Kind event | Out-Null
          }
        }
      }
    }
  }

  # Stagnation detector: if the coder role made no bridge file changes and no attachments for N turns, trigger self-diagnosis.
  if ($speaker -eq 'codex' -and $mode -ne 'discuss') {
    $gitDiffOut = & git -C $bridgeRoot diff --stat HEAD 2>&1
    # Also check the channel's effective project root (may differ from bridgeRoot).
    if ([string]::IsNullOrWhiteSpace($gitDiffOut)) {
      try {
        $effPR = [string](Get-EffectiveProjectRoot)
        if (-not [string]::IsNullOrWhiteSpace($effPR) -and $effPR -ne $bridgeRoot -and (Test-Path $effPR)) {
          $gitDiffOutPR = & git -C $effPR diff --stat HEAD 2>&1
          if (-not [string]::IsNullOrWhiteSpace($gitDiffOutPR)) { $gitDiffOut = $gitDiffOutPR }
        }
      } catch {
        Add-Message -From system -Text ("⚠ Stagnation detector project_root check failed: " + $_.Exception.Message) -Kind event | Out-Null
      }
    }
    if ($mode -eq 'normal') { Update-State { param($s) $s.task_did_actions=$true } | Out-Null }
    $hasChanges = -not [string]::IsNullOrWhiteSpace($gitDiffOut) -or $attachmentMetas.Count -gt 0
    $npc = [int](Read-State).no_progress_count
    if ($hasChanges) {
      Update-State { param($s) $s.no_progress_count=0 } | Out-Null
    } else {
      $newNpc = $npc + 1
      $mutNpc = { param($s) $s.no_progress_count = $newNpc }.GetNewClosure()
      Update-State $mutNpc | Out-Null
      if ($newNpc -ge 4) {
        Add-Message -From system -Text "⚠ Нет изменений файлов $newNpc ходов подряд. Codex — объясни, что блокирует выполнение, или предложи иной подход." -Kind event | Out-Null
        Update-State { param($s) $s.no_progress_count=0 } | Out-Null
      }
    }
  }

  $modeBeforeIncrement = $mode
  Update-State { param($s) $s.task_turn=[int]$s.task_turn+1; $s.turn=[int]$s.turn+1; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
  if ($modeBeforeIncrement -eq 'discuss') {
    Update-State { param($s) $s.discuss_turn=[int]$s.discuss_turn+1 } | Out-Null
  }
  if ($modeBeforeIncrement -eq 'discuss' -and $speaker -eq 'claude') {
    try {
      $snapMatch = [regex]::Match($reply, '(?ims)^\s*Тип\s*:.*?(?=^\s*STATUS:|\z)')
      if (-not $snapMatch.Success) {
        $snapMatch = [regex]::Match($reply, '(?ims)^\s*Согласовано\s*:.*?(?=^\s*STATUS:|\z)')
      }
      if ($snapMatch.Success) {
        $snap = $snapMatch.Value.Trim()
        $markerCount = [regex]::Matches($snap, '(?im)^[*_> \t#-]*(Тип|Согласовано|Открыто|Решение|Риски|План\s+реализации)[^:\n]*:').Count
        if ($markerCount -ge 2) {
          Update-State ({ param($s) $s.discuss_snapshot = $snap }.GetNewClosure()) | Out-Null
        }
      }
    } catch {}
  }
  if ($modeBeforeIncrement -eq 'study') {
    $stStudy = Read-State
    $curPhase = [string]$stStudy.study_phase
    $turnNow = [int]$stStudy.task_turn
    if ($curPhase -eq 'plan') {
      $nextPhase = if ($stStudy.study_subtype -eq 'local') { 'gather-local' } else { 'gather-web' }
      Update-State ({ param($s) $s.study_phase=$nextPhase }.GetNewClosure()) | Out-Null
    } elseif ($turnNow -ge ($studyMaxTurns - 1)) {
      Update-State { param($s) $s.study_phase='synthesis' } | Out-Null
    } elseif ($curPhase -match '^gather' -and $turnNow -ge 2) {
      Update-State { param($s) $s.study_phase='synthesis' } | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $modeBeforeIncrement -eq 'research' -and $evidenceSources.Count -eq 0) {
    Add-Message -From system -Text "🔍 Research-ход не дал маркер [[EVIDENCE: ...]]. Дальнейший web-доступ по этой задаче заблокирован до новой задачи." -Kind event | Out-Null
    $researchBlockValue = $researchMaxTurns
    Update-State ({ param($s) $s.research_count=$researchBlockValue }.GetNewClosure()) | Out-Null
  }

  # Loop detector: three identical non-empty progress fingerprints in one task -> Doctor.
  try {
    $fpDiff  = ((& git -C $bridgeRoot diff --stat HEAD 2>$null) -join '|').Trim()
    $fpReply = if ($null -eq $reply) { '' } else { ([string]$reply).Trim() }
    $fpInput = ($fpDiff + '|||' + $fpReply).Trim()
    if (-not [string]::IsNullOrWhiteSpace($fpInput)) {
      $fpBytes = [System.Text.Encoding]::UTF8.GetBytes($fpInput)
      $fpHash  = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($fpBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
      $fp8     = $fpHash.Substring(0, 8)

      $stFp   = Read-State
      $fpList = @()
      try { if ($null -ne $stFp.progress_fingerprints) { $fpList = @($stFp.progress_fingerprints) } } catch {}
      $fpList = @($fpList) + @($fp8)
      if ($fpList.Count -gt 3) { $fpList = @($fpList[($fpList.Count - 3)..($fpList.Count - 1)]) }

      $isLoop = ($fpList.Count -eq 3) -and (($fpList | Select-Object -Unique).Count -eq 1)
      $curLoopCount = 0
      try { $curLoopCount = [int]$stFp.task_loop_count } catch {}
      if ($isLoop) { $curLoopCount++ }

      $newFpList = @($fpList)
      $newLoopCount = $curLoopCount
      Update-State ({ param($s)
        $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue $newFpList -Force
        $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue $newLoopCount -Force
      }.GetNewClosure()) | Out-Null

      if ($isLoop) {
        Add-Message -From system -Text '🔁 Loop detected: 3× same fingerprint — переключаю в Doctor' -Kind event | Out-Null
        $stLoop = Read-State
        $isAlreadyDoctor = ([bool]$stLoop.doctor_active) -or ([string]$stLoop.task_mode -eq 'doctor')
        if ($isAlreadyDoctor) {
          Add-Message -From system -Text '🛑 Loop в режиме Doctor — прерываю задачу.' -Kind event | Out-Null
          Update-State { param($s)
            Complete-TaskAgentDuration $s
            Close-ReplayForStateTask -State $s -Status 'aborted'
            $s.current_task = $null; $s.task_turn = 0; $s.status = 'idle'; $s.active_agent = $null; $s.active_model = $null; $s.status_text = $null
            $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
            $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          } | Out-Null
        } else {
          try {
            Activate-Doctor -Reason 'loop_detected' -Detail '3x same progress fingerprint' | Out-Null
          } catch {
            Add-Message -From system -Text ("⚠ Activate-Doctor failed in loop-detector: " + $_.Exception.Message) -Kind event | Out-Null
          }
          Update-State { param($s)
            $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
            $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          } | Out-Null
        }
        continue
      }
    }
  } catch {
    Add-Message -From system -Text ("⚠ Loop-detector error: " + $_.Exception.Message) -Kind event | Out-Null
  }

  $plannerStatus = 'CONTINUE'
  $fastLaneDone = $false
  if ($speaker -eq 'codex') {
    $chunkSettings = Get-ChunkingSettings
    $cm = [regex]::Match($reply, '(?im)^\s*STATUS:\s*CONTINUE-CHUNK\s*:\s*(\d+)\s*/\s*(\d+)\s*$')
    if ([bool]$chunkSettings.enabled -and $cm.Success) {
      $chunkN = [int]$cm.Groups[1].Value
      $chunkM = [int]$cm.Groups[2].Value
      $maxChunks = [int]$chunkSettings.maxChunksPerTask
      $headNow = ''
      try { $headNow = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch {}
      $stChunk = Read-State
      $chunkBase = [string]$stChunk.chunk_base_commit
      if ([string]::IsNullOrWhiteSpace($chunkBase)) { $chunkBase = [string]$stChunk.task_base_commit }
      $baseLabel = if ([string]::IsNullOrWhiteSpace($chunkBase)) { '<empty>' } elseif ($chunkBase.Length -gt 7) { $chunkBase.Substring(0,7) } else { $chunkBase }
      $headAdvanced = (-not [string]::IsNullOrWhiteSpace($headNow)) -and ($headNow -ne $chunkBase)
      if (-not $headAdvanced) {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM помечен, но коммит не зафиксирован (HEAD не сдвинулся с $baseLabel). Закоммить и повтори с тем же STATUS: CONTINUE-CHUNK:$chunkN/$chunkM." -Kind event | Out-Null
        Update-State { param($s) $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        continue
      }
      $shortSha = if ($headNow.Length -gt 7) { $headNow.Substring(0,7) } else { $headNow }
      $newProgress = "$chunkN/$chunkM"
      if ($chunkN -ge $maxChunks) {
        Add-Message -From system -Text "Достигнут лимит чанков на задачу ($chunkN/$maxChunks, последний коммит $shortSha). Принудительно закрываю задачу. Если работа не завершена — раздели на отдельные задачи." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
          $s | Add-Member -NotePropertyName skip_critic -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0; $s.verify_retry_count=2
        }.GetNewClosure()) | Out-Null
        $plannerStatus = 'DONE'
        $fastLaneDone = $true
      } else {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM завершён: commit $shortSha. Продолжаю на следующий чанк." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0
          $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        continue
      }
    } elseif ([bool]$chunkSettings.enabled) {
      $stChunkDone = Read-State
      $hasChunkProgress = -not [string]::IsNullOrWhiteSpace([string]$stChunkDone.chunk_progress)
      $doneHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*DONE\s*$')
      if ($hasChunkProgress -and $doneHits.Count -gt 0) {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='planner'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
        Update-State { param($s) $s.task_did_actions=$true; $s.no_progress_count=0 } | Out-Null
      }
    }

    # 2026-05-27: Deterministic claim verification for Codex reply. Parses
    # the reply for verifiable assertions (HTTP status, ParseFile OK, git SHA)
    # and checks each against ground truth. NEVER blocks the flow — only
    # synthesizes a system event so the next planner turn sees the discrepancy
    # alongside Codex's claim. Catches the over-claim pattern (curator-задача
    # 2026-05-27) before the LLM verify gate spends a 30s round.
    try {
      $gateReport = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRoot
      if ($gateReport.violations.Count -gt 0) {
        $vparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($v in $gateReport.violations) {
          [void]$vparts.Add("• [$($v.kind)] Codex заявил: $($v.claim) → реальность: $($v.actual)")
        }
        $okText = if ($gateReport.checks.Count -gt 0) { " (попутно $($gateReport.checks.Count) утверждений сверены OK)" } else { '' }
        Add-Message -From system -Text ("🔢 Gate-check: " + $gateReport.violations.Count + " несоответствий в reply Codex" + $okText + ":`n" + [string]::Join("`n", $vparts.ToArray()) + "`n`nПланировщик: учти эти разрывы при ревью STATUS — Codex заявил неточно, нужна доработка.") -Kind event | Out-Null
      } elseif ($gateReport.checks.Count -gt 0) {
        $kparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in ($gateReport.checks | Select-Object -First 5)) {
          [void]$kparts.Add("[$($c.kind)] $($c.claim)")
        }
        $more = if ($gateReport.checks.Count -gt 5) { " (+ $($gateReport.checks.Count - 5) more)" } else { '' }
        Add-Message -From system -Text ("✓ Gate-check Codex'а: " + $gateReport.checks.Count + " утверждений сверены с фактами OK — " + [string]::Join('; ', $kparts.ToArray()) + $more) -Kind event | Out-Null
      }
    } catch {
      Add-Message -From system -Text ("⚠ Gate-check exception: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  if ($fastLaneActiveForTurn) {
    $coderStatusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(DONE|CONTINUE)\s*$')
    if ($coderStatusHits.Count -gt 0) {
      $coderStatus = $coderStatusHits[$coderStatusHits.Count - 1].Groups[1].Value.ToUpper()
      if ($coderStatus -eq 'DONE') {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='coder'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
      }
    }
  }
  if ($speaker -eq 'claude') {
    $statusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(CHAT|CONTINUE|DISCUSS|DONE|RESEARCH)\s*$')
    if ($statusHits.Count -gt 0) { $plannerStatus = $statusHits[$statusHits.Count - 1].Groups[1].Value.ToUpper() }

    # FIX 2026-05-27: parallel coder dispatch. If planner reply contains >= 2 [[PARALLEL:N]]
    # blocks with file-disjoint workloads, fan out to worker pool (Claude+Codex round-robin
    # in separate worktrees) instead of normal Codex-only flow. After merge, treat as if
    # planner had said STATUS: DONE so verify gate + critic proceed normally on combined diff.
    if ($plannerStatus -eq 'CONTINUE' -and ($modeBeforeIncrement -eq 'normal' -or $modeBeforeIncrement -eq 'discuss')) {
      $parStreams = $null
      try { $parStreams = Test-CanParallelize -PlanText $reply } catch { $parStreams = $null }
      if ($parStreams -and $parStreams.Count -ge 2) {
        try {
          Add-Message -From system -Text ("🔀 Parallel dispatch: " + $parStreams.Count + " streams detected in planner reply") -Kind event | Out-Null
          $parResult = Invoke-ParallelDispatch -Streams $parStreams -TimeoutMin 25 -PollSec 10
          if ($parResult.ok) {
            Add-Message -From system -Text ("✅ Parallel completed: " + $parResult.merged + " streams merged into main") -Kind event | Out-Null
            $plannerStatus = 'DONE'   # work landed via workers; let verify+critic gates run
            $modeBeforeIncrement = 'normal'  # parallel delivered real implementation; force normal-mode so verify+critic+smoke gates run
            Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.task_did_actions = $true; $s.coder_fired = $true } | Out-Null
          } else {
            Add-Message -From system -Text ("⚠ Parallel failed: " + $parResult.reason + " -- fallback to sequential Codex") -Kind event | Out-Null
            # leave $plannerStatus as CONTINUE -- normal Codex turn next iteration
          }
        } catch {
          Add-Message -From system -Text ("⚠ Parallel exception: " + $_.Exception.Message + " -- fallback to sequential") -Kind event | Out-Null
        }
      }
    }

    if ($plannerStatus -eq 'DISCUSS') {
      if ($modeBeforeIncrement -ne 'discuss') {
        Update-State { param($s) $s.task_mode='discuss'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='discuss' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'CONTINUE') {
      if ($modeBeforeIncrement -eq 'discuss') {
        $dtNow = [int](Read-State).discuss_turn
        # FIX 2026-05-27: accept synonyms for the convergence-check keywords. Claude often
        # writes "Согласовано:" / "Decision:" / "Решено:" instead of literal "Решение:" —
        # technically a converged plan, but the pedantic gate kept rejecting it (12-min
        # ping-pong observed today on a 12-point task). Same for Риски/Risks/Risk.
        $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
        $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
        $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
        # FIX 2026-05-26 (Codex's Doctor fix, applied manually after restart-loop incident):
        # TrimEnd punctuation so "Открыто: нет." matches the "no open blockers" regex.
        # Without this, a trailing dot in "нет." was treated as an unresolved open question
        # and the convergence gate kept looping until 905s Codex timeout fired.
        $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
        $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
        $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
        $ceiling     = ($dtNow -ge $discussMaxTurns)
        $planMatch = [regex]::Match($reply, '(?ims)^[*_> \t#-]*План\s+реализации[^:\n]*:[*_ \t]*(.*?)(?=^\s*[*_> \t#-]*(STATUS:|Тип:|Согласовано:|Открыто:|Решение:|Риски:)|\z)')
        $hasPlan = $planMatch.Success -and -not [string]::IsNullOrWhiteSpace($planMatch.Groups[1].Value)
        if (-not $ceiling -and (-not $converged -or -not $hasPlan)) {
          $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
                 elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
                 elseif (-not $openClosed) { "остались открытые вопросы: $openVal" }
                 else { "нет непустого «План реализации:»" }
          Add-Message -From system -Text "💬 CONTINUE из обсуждения требует конвергенции и непустой «План реализации:» — $why. Claude, закройте блок состояния и повторите." -Kind event | Out-Null
          $plannerStatus = 'DISCUSS'
          Update-State { param($s) $s.task_mode='discuss' } | Out-Null
        } else {
          if ($ceiling -and (-not $converged -or -not $hasPlan)) {
            Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) достигнут — закрываю обсуждение с текущим планом, передаю Codex'у." -Kind event | Out-Null
          }
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      } elseif ($modeBeforeIncrement -eq 'study') {
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'RESEARCH') {
      if ($modeBeforeIncrement -eq 'study') {
        Add-Message -From system -Text "📚 Study уже имеет web-инструменты; продолжаю в режиме study вместо отдельного research." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } elseif ($modeBeforeIncrement -eq 'research') {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        $rc = [int](Read-State).research_count
        if ($rc -lt $researchMaxTurns) {
          $newRc = $rc + 1
          Update-State ({ param($s) $s.task_mode='research'; $s.research_count=$newRc; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' }.GetNewClosure()) | Out-Null
        } else {
          Add-Message -From system -Text "🔍 Бюджет research исчерпан ($researchMaxTurns/$researchMaxTurns ходов). Codex получит уже собранные данные." -Kind event | Out-Null
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      }
    }
    if ($modeBeforeIncrement -eq 'research' -and $plannerStatus -ne 'DONE' -and $plannerStatus -ne 'CHAT') {
      Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'CHAT') {
    Add-Message -From system -Text "💬 Ответ без Codex. Жду следующее сообщение." -Kind event | Out-Null
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  # Guard: в discuss DONE разрешён только при конвергенции (по состоянию), с полом и потолком по ходам
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'discuss') {
    $dtNow = [int](Read-State).discuss_turn
    # FIX 2026-05-27: same synonyms accepted here (DONE-in-discuss path), see CONTINUE branch above.
    $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
    $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
    $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
    # Same TrimEnd punctuation fix as above (2026-05-26): keeps "нет." from being treated
    # as unresolved open question.
    $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
    $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
    $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
    $ceiling     = ($dtNow -ge $discussMaxTurns)
    if (-not $converged -and -not $ceiling) {
      $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
             elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
             else { "остались открытые вопросы: $openVal" }
      Add-Message -From system -Text "💬 Обсуждение продолжается — $why. Claude, доведите до синтеза: блок Согласовано/Открыто/Решение/Риски, «Открыто» пусто." -Kind event | Out-Null
      $plannerStatus = 'DISCUSS'
      Update-State { param($s) $s.task_mode='discuss' } | Out-Null
    } elseif ($ceiling -and -not $converged) {
      Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) — закрываю с текущим решением." -Kind event | Out-Null
    }
    # 🧭 Deep-think harvest: at converged DONE of a [[DEEP-THINK]] discuss task, parse the
    # planner's `IDEA: <text>` lines from the ## ИТОГ and file them as backlog ideas with
    # tag=architect+deep-think. These are the ideas that survived the Claude<->Codex critique.
    if (($converged -or $ceiling) -and ($task -match '\[\[DEEP-THINK\]\]')) {
      try {
        $pbForDeepThink = Get-ActiveProjectBinding
        $ideaLines = [regex]::Matches($reply, '(?im)^\s*[*_> \t#-]*IDEA:\s*(.+)$')
        $filed = 0
        foreach ($im in $ideaLines) {
          $itext = $im.Groups[1].Value.Trim() -replace '\*+$',''
          if ([string]::IsNullOrWhiteSpace($itext)) { continue }
          $id = Add-Idea -Text $itext -From 'architect' -Tags @('architect','deep-think','dialog-survived') -Status 'new' -Project ([string]$pbForDeepThink.slug) -Scope 'bridge'
          if ($id) { $filed++ }
        }
        if ($filed -gt 0) {
          Add-Message -From system -Text ("🧭💭 Deep-think dialog завершён: " + $filed + " идей прошли критику Codex'а и легли в беклог (тег: architect+deep-think+dialog-survived, status=new).") -Kind event | Out-Null
        }
      } catch {}
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'study') {
    $hasStudyReport = $false
    foreach ($fp in $fileMarkerPaths) {
      try {
        if ([System.IO.Path]::GetExtension([string]$fp) -ieq '.md') { $hasStudyReport = $true }
      } catch {}
    }
    if (-not $hasStudyReport -or $attachmentMetas.Count -eq 0) {
      Add-Message -From system -Text "📚 Study требует итоговый Markdown-отчёт через [[FILE: ...md]]. Claude, создай/прикрепи отчёт и повтори синтез." -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
      Update-State { param($s) $s.task_mode='study'; $s.study_phase='synthesis' } | Out-Null
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $didActions = [bool](Read-State).task_did_actions
    $hasVerify  = $reply -imatch '(?im)^\s*\[\[VERIFIED:\s*.+?\]\]\s*$'
    $vrc        = [int](Read-State).verify_retry_count
    if ($didActions -and -not $hasVerify -and $vrc -lt 2) {
      Add-Message -From system -Text "🔍 Фаза верификации: задача меняла файлы, но проверки нет. Агент, ВЫПОЛНИ проверочную команду/тест/чтение файла/скриншот, покажи результат и добавь строку [[VERIFIED: что проверено | результат]], затем STATUS: DONE." -Kind event | Out-Null
      $plannerStatus = 'VERIFY'
      Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$true } | Out-Null
    } elseif ($didActions -and -not $hasVerify -and $vrc -ge 2) {
      $vfDiff = ''
      try {
        $vfBase = [string](Read-State).task_base_commit
        if (-not [string]::IsNullOrWhiteSpace($vfBase)) {
          $vfDiff = (& git -C $bridgeRoot diff $vfBase -- 2>$null | Out-String).Trim()
          if ($vfDiff.Length -gt 2000) { $vfDiff = $vfDiff.Substring(0,2000) + "`n...[truncated]" }
        }
      } catch {}
      $vfLast = $reply.Trim(); if ($vfLast.Length -gt 800) { $vfLast = $vfLast.Substring(0,800) + "`n...[truncated]" }
      $vfMsg = "🔍 Верификация не пройдена за 2 попытки — закрываю как есть."
      if ($vfDiff) { $vfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$vfDiff`n``````" }
      if ($vfLast) { $vfMsg += "`n`n**Последний вывод агента:**`n``````$vfLast`n``````" }
      Add-Message -From system -Text $vfMsg -Kind event | Out-Null
      try { Send-PushEvent -Kind need_you -Text "Верификация не пройдена: $(Get-PushSnippet -Text $task)" } catch {}
      # 2026-05-28: explicitly clear task_did_actions so the verify-check doesn't
      # re-fire on the next planner DONE. Previously this branch only printed
      # a message — but the same DONE could land again after a restart (vrc=2
      # preserved), and the elseif would print THE SAME warning forever. Bridge
      # logged "Верификация не пройдена за 2 попытки" repeatedly on every restart.
      # Setting task_did_actions=false makes the verify-check a no-op next pass,
      # letting plannerStatus=DONE close the task naturally.
      Update-State { param($s) $s.task_did_actions = $false } | Out-Null
    }
  }
  # Coder-bypass gate: planner did file edits without invoking Codex -> reject DONE, force CONTINUE->Codex+critic.
  # The critic only reviews Codex diffs; if Opus modifies files directly, its diff ships without independent review.
  # Probe 2 (2026-05-26) exposed this: Opus single-handedly committed mobile button rearrangement; critic skipped.
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $stCB = Read-State
    if ([bool]$stCB.task_did_actions -and -not [bool]$stCB.coder_fired) {
      $cbr = [int]$stCB.coder_bypass_retry_count
      if ($cbr -lt 2) {
        Add-Message -From system -Text "🔁 Кодер пропущен: задача меняла файлы, но Codex не вызывался. Claude, ОБЯЗАТЕЛЬНО передай реализацию через STATUS: CONTINUE с конкретной инструкцией Codex'у (что/где/критерий) — он напишет правки, критик их проверит. Multi-agent дисциплина: правки кода идут через кодера, а не через планировщика." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.coder_bypass_retry_count=[int]$s.coder_bypass_retry_count+1; $s.force_planner=$true } | Out-Null
      } else {
        Add-Message -From system -Text "🔁 Coder-bypass: планировщик 2× не передал работу Codex — закрываю как есть, нужно внимание оператора." -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text "Coder-bypass: $(Get-PushSnippet -Text $task)" } catch {}
      }
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    # Независимый критик: перед закрытием ревьюим git-дифф задачи на другой модели.
    # Серьёзное -> возврат Codex на доработку; сбои критика не блокируют завершение.
    try {
      $stC = Read-State
      if ([bool]$stC.task_did_actions) {
        if ([bool]$stC.skip_critic) {
          Add-Message -From system -Text "⏭ Critic пропущен (fast-lane)" -Kind event | Out-Null
        } else {
        $criticMaxRetries = 2
        try { $cfgCr = Get-BridgeConfig; if ($cfgCr.PSObject.Properties.Name -contains 'criticMaxRetries') { $criticMaxRetries = [int]$cfgCr.criticMaxRetries } } catch {}
        $crc  = [int]$stC.critic_retry_count
        $base = [string]$stC.task_base_commit
        $diff = ''
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          try { $diff = (& git -C $bridgeRoot diff $base -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if ([string]::IsNullOrWhiteSpace($diff)) {
          try { $diff = (& git -C $bridgeRoot diff HEAD -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($diff)) {
          if ($crc -ge $criticMaxRetries) {
            Add-Message -From system -Text "🔎 Критик: лимит доработок ($criticMaxRetries) исчерпан — закрываю задачу как есть, нужно внимание оператора." -Kind event | Out-Null
            try { Send-PushEvent -Kind need_you -Text "Критик исчерпал лимит доработок: $(Get-PushSnippet -Text $task)" } catch {}
          } else {
            $llmCfg = $null
            try { $llmCfg = Get-LLMConfig } catch {}
            $criticLight = if ($llmCfg -and $llmCfg.ContainsKey('critic')) { [string]$llmCfg['critic'] } else { 'deepseek-v4-flash' }
            $criticHeavy = if ($llmCfg -and $llmCfg.ContainsKey('criticHeavy')) { [string]$llmCfg['criticHeavy'] } else { 'deepseek-v4-pro' }
            $diffNames = @()
            try {
              if (-not [string]::IsNullOrWhiteSpace($base)) { $diffNames = @(& git -C $bridgeRoot diff --name-only $base -- 2>$null) }
              if (@($diffNames).Count -eq 0) { $diffNames = @(& git -C $bridgeRoot diff --name-only HEAD -- 2>$null) }
            } catch {}
            $linesChanged = 0
            try {
              $numstat = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $numstat = @(& git -C $bridgeRoot diff --numstat $base -- 2>$null) }
              if (@($numstat).Count -eq 0) { $numstat = @(& git -C $bridgeRoot diff --numstat HEAD -- 2>$null) }
              foreach ($lnStat in @($numstat)) {
                $parts = @(([string]$lnStat) -split '\s+')
                if ($parts.Count -ge 2) {
                  $adds = 0; $dels = 0
                  [int]::TryParse($parts[0], [ref]$adds) | Out-Null
                  [int]::TryParse($parts[1], [ref]$dels) | Out-Null
                  $linesChanged += ($adds + $dels)
                }
              }
            } catch {}
            $heavyRegex = '(?i)security|auth|secret|crypto|race|mutex|lock|concurr(en|ency)?|sql\s*injection|inject(ion)?|csrf|xss'
            $isHeavyCritic = (@($diffNames).Count -gt 3) -or ($linesChanged -gt 100) -or ($diff -match $heavyRegex)
            $crcNow = 0
            try { $crcNow = [int](Read-State).critic_retry_count } catch {}
            if ($crcNow -ge 1) { $isHeavyCritic = $true }
            $criticModelName = if ($isHeavyCritic) { $criticHeavy } else { $criticLight }

            # 2026-05-27: deterministic CLI-flag check BEFORE the LLM critic.
            # The LLM critic (deepseek) approved a non-existent --cwd flag for
            # claude.exe in the prior Wave-C-tails task because it has no way
            # to run the CLI. This pre-check actually invokes `cli --help` and
            # rejects diffs that introduce unknown flags. Findings here are
            # treated as serious and prepended to LLM issues -- they cannot be
            # talked away by the LLM.
            $cliFlagIssues = @()
            try { $cliFlagIssues = @(Test-CliFlagsInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ CLI-flag check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $cliFlagIssuesText = ''
            if ($cliFlagIssues.Count -gt 0) {
              $parts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $cliFlagIssues) {
                [void]$parts.Add(("$($iss.cli).exe не знает флага '$($iss.flag)' (в --help отсутствует). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $cliFlagIssuesText = [string]::Join(' ; ', $parts.ToArray())
              Add-Message -From system -Text ("🔎 CLI-flag-check: " + $cliFlagIssuesText) -Kind event | Out-Null
            }

            $diffWasTruncated = $false
            $diffBytes = 0
            try { $diffBytes = [Text.Encoding]::UTF8.GetByteCount($diff) } catch { $diffBytes = $diff.Length }
            if ($diff.Length -gt 16000) {
              $diffWasTruncated = $true
              $diff = $diff.Substring(0,16000) + "`n...[дифф обрезан]..."
            }
            $truncationNote = if ($diffWasTruncated) {
              "ВАЖНО: diff ниже обрезан по лимиту контекста. Не считай сам факт обрезки синтаксической ошибкой, потерей кода или доказательством обрезанной функции; проверяй только реально видимые изменения. Синтаксис .ps1 и BOM проверяются отдельными командами."
            } else { "" }
            $diffTruncatedText = ([string]$diffWasTruncated).ToLowerInvariant()
            $changedFilesText = ''
            try {
              $changedLines = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $changedLines = @(& git -C $bridgeRoot diff --name-status $base -- 2>$null) }
              if (@($changedLines).Count -eq 0) { $changedLines = @(& git -C $bridgeRoot diff --name-status HEAD -- 2>$null) }
              $changedFilesText = [string]::Join("`n", @($changedLines))
              if ($changedFilesText.Length -gt 3000) { $changedFilesText = $changedFilesText.Substring(0, 3000) + "`n...[changed-files truncated]..." }
            } catch {
              $changedFilesText = "(changed-files unavailable: $($_.Exception.Message))"
            }
            $taskHistory = ''
            if (-not [string]::IsNullOrWhiteSpace($base)) {
              try {
                $histLines = @(& git -C $bridgeRoot log --oneline --name-status "$base..HEAD" 2>$null)
                $taskHistory = [string]::Join("`n", @($histLines))
                if ($taskHistory.Length -gt 6000) {
                  $taskHistory = $taskHistory.Substring(0, 6000) + "`n...[история обрезана]..."
                }
              } catch {
                $taskHistory = "(task-history unavailable: $($_.Exception.Message))"
              }
            }
            # HEAD context lets the critic distinguish "not in this diff" from "not in repo".
            $headContext = ''
            $symbolEvidence = ''
            try {
              $repoPs1Files = @()
              try { $repoPs1Files = @(& git -C $bridgeRoot ls-files --cached '*.ps1' 2>$null) } catch { $repoPs1Files = @() }
              $repoPs1List = if ($repoPs1Files.Count -gt 0) { [string]::Join(', ', $repoPs1Files) } else { '(none)' }

              $funcLines = New-Object 'System.Collections.Generic.List[string]'
              $diffPs1Names = @($diffNames | Where-Object { $_ -match '\.ps1$' })
              $diffPs1Set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
              foreach ($relDiffPs1 in $diffPs1Names) { [void]$diffPs1Set.Add([string]$relDiffPs1) }
              foreach ($relf in $diffPs1Names) {
                $fullF = Join-Path $bridgeRoot $relf
                if (Test-Path $fullF) {
                  $fns = @()
                  try {
                    $fns = @(& git -C $bridgeRoot show ('HEAD:' + ($relf -replace '\\','/')) 2>$null |
                      Select-String -Pattern '^\s*function\s+([A-Za-z][\w-]*)' -AllMatches |
                      ForEach-Object { $_.Matches | ForEach-Object { $_.Groups[1].Value } })
                  } catch { $fns = @() }
                  if ($fns.Count -gt 0) {
                    [void]$funcLines.Add(($relf + ': ' + [string]::Join(', ', $fns)))
                  }
                }
              }

              $allFuncsInDiffedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
              foreach ($ln in @($funcLines)) {
                $parts2 = $ln -split ': ', 2
                if ($parts2.Count -eq 2) {
                  foreach ($fn in ($parts2[1] -split ', ')) {
                    [void]$allFuncsInDiffedFiles.Add($fn.Trim())
                  }
                }
              }

              $calledInDiff = @()
              try {
                $cmdNamePattern = '(?:Invoke-|Get-|Set-|Add-|Remove-|Test-|New-|Write-|Read-|Send-|Update-|Save-|Load-|Build-|Find-|Format-|Start-|Stop-)[A-Za-z][\w-]*'
                $calledSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($dln in ($diff -split "`r?`n")) {
                  if ($dln -notmatch '^[\+\- ]') { continue }
                  if ($dln -match '^(?:\+\+\+|---)') { continue }
                  $codeLine = if ($dln.Length -gt 0) { $dln.Substring(1) } else { '' }
                  if ($codeLine -match '^\s*#') { continue }
                  foreach ($m in [regex]::Matches($codeLine, "(?<![\w-])$cmdNamePattern(?![\w-])")) {
                    [void]$calledSet.Add($m.Value)
                  }
                }
                $calledInDiff = @($calledSet | Sort-Object)
              } catch { $calledInDiff = @() }

              $crossRefs = New-Object 'System.Collections.Generic.List[string]'
              $symbolEvidenceParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($fn in $calledInDiff) {
                if ($allFuncsInDiffedFiles.Contains($fn)) { continue }
                $fnFiles = New-Object 'System.Collections.Generic.List[string]'
                foreach ($rf in $repoPs1Files) {
                  $fullRf = Join-Path $bridgeRoot $rf
                  if (-not (Test-Path $fullRf)) { continue }
                  if ($diffPs1Set.Contains([string]$rf)) { continue }
                  try {
                    $headLines = @(& git -C $bridgeRoot show ('HEAD:' + ($rf -replace '\\','/')) 2>$null)
                    $fnPattern = '^\s*function\s+' + [regex]::Escape($fn) + '\b'
                    $hitIndex = -1
                    for ($idx = 0; $idx -lt $headLines.Count; $idx++) {
                      if ([string]$headLines[$idx] -match $fnPattern) { $hitIndex = $idx; break }
                    }
                    $hit = ($hitIndex -ge 0)
                    if ($hit) {
                      [void]$fnFiles.Add($rf)
                      if ($symbolEvidence.Length -lt 8000) {
                        $endIdx = [Math]::Min($headLines.Count - 1, $hitIndex + 10)
                        $bodyLines = New-Object 'System.Collections.Generic.List[string]'
                        for ($bodyIdx = $hitIndex; $bodyIdx -le $endIdx; $bodyIdx++) {
                          [void]$bodyLines.Add([string]$headLines[$bodyIdx])
                        }
                        $snippet = ("### {0} -> {1}`n{2}" -f $fn, $rf, [string]::Join("`n", $bodyLines.ToArray()))
                        [void]$symbolEvidenceParts.Add($snippet)
                        $symbolEvidence = [string]::Join("`n`n", $symbolEvidenceParts.ToArray())
                        if ($symbolEvidence.Length -gt 8000) {
                          $symbolEvidence = $symbolEvidence.Substring(0, 8000) + "`n...[symbol-evidence truncated]..."
                          break
                        }
                      }
                    }
                  } catch { $hit = $false }
                }
                if ($fnFiles.Count -gt 0) {
                  [void]$crossRefs.Add($fn + ' -> ' + [string]::Join(', ', $fnFiles.ToArray()))
                }
                if ($symbolEvidence.Length -gt 8000) { break }
              }

              $hcParts = New-Object 'System.Collections.Generic.List[string]'
              if ($funcLines.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ:`n" + [string]::Join("`n", $funcLines.ToArray()))
              }
              if ($crossRefs.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ ИЗ DIFF, ОПРЕДЕЛЁННЫЕ В ДРУГИХ ФАЙЛАХ:`n" + [string]::Join("`n", $crossRefs.ToArray()))
              }
              [void]$hcParts.Add("ВСЕ .ps1 ФАЙЛЫ РЕПО: $repoPs1List")
              $headContext = [string]::Join("`n`n", $hcParts.ToArray())
              if ($headContext.Length -gt 8000) { $headContext = $headContext.Substring(0, 8000) + "`n...[контекст обрезан]..." }
              if ([string]::IsNullOrWhiteSpace($symbolEvidence)) { $symbolEvidence = "(no cross-file symbol evidence)" }
            } catch {
              $headContext = "(head-context unavailable: $($_.Exception.Message))"
              $symbolEvidence = "(symbol-evidence unavailable: $($_.Exception.Message))"
            }
            $criticPrompt = @"
Ты — независимый код-критик. Другой ИИ (Codex) внёс изменения в проект на PowerShell (автономный мост Claude<->Codex на Windows). Проверь git-дифф на СЕРЬЁЗНЫЕ проблемы: баги, уязвимости безопасности, регрессии, потеря данных, падения, синтаксические ошибки, нарушение инвариантов (каждый .ps1 в UTF-8 с BOM; не трогать watchdog/supervisor/.git; не выводить секреты).
НЕ придирайся к стилю, именованию и форматированию — отмечай только то, что реально сломает работу или создаёт риск.

ОСОБО ПРОВЕРЬ ИЗВЕСТНЫЕ ГРАБЛИ POWERSHELL (частые причины аварий в этом проекте — при наличии ставь severity=serious):
- ConvertTo-Json по строке из `Get-Content -Raw` (или по сырым объектам из ConvertFrom-Json), особенно с -Depth>=12 → рекурсия по ETS-графу провайдера (PSProvider/PSDrive) → OOM ~70ГБ и краш хоста. Должно быть [IO.File]::ReadAllText или `("" + $s)` + ПЛОСКИЕ DTO + -Depth<=10. (это уже роняло мост — /api/radar)
- .ps1 без BOM (PS 5.1 ломает кириллицу); вызов нативного exe (git и т.п.) под $ErrorActionPreference='Stop' (stderr бросит исключение).
- Новый/изменённый API-эндпоинт или UI БЕЗ реальной проверки по HTTP/загрузке страницы.
- Бесконечные циклы / отсутствие таймаута; убийство процессов по возрасту/эвристике; чтение или вывод secrets.json.
- `param([string[]]$Args)` или другие зарезервированные имена параметров (Args/Input/PSCmdlet/MyInvocation/PSScriptRoot) — silent override автоматическими переменными, функция получит пусто или мусор (2026-05-27: Get-BacklogGitOutput с `$Args` вернула git help-страницу 2335 символов вместо коммитов, freshness-check 18 items работал на мусоре).
- `Add-Content -Encoding UTF8` в PS 5.1 пишет BOM при создании файла — JSONL с BOM ломает строгие парсеры. Для JSONL нужно `[IO.File]::AppendAllText($path,$line+"`n",(New-Object Text.UTF8Encoding($false)))`.
- Native command stderr через `2>&1` под PS 5.1 — каждая stderr-строка оборачивается в NativeCommandError ErrorRecord, что часто валит скрипт. Используй `2>$null` отдельно или `cmd /c "... 2>NUL"`.

🔢 ОТДЕЛЬНО — OVER-CLAIM ПАТТЕРН (это уже было причиной 1-часового цикла verify-reject):
Если в коммит-сообщениях или в обвязке кода Codex ЗАЯВЛЯЕТ численный результат («backfill для 51 items», «обновлено N файлов», «все 4 теста OK», «merged 3 streams») БЕЗ инкорпорированной команды-доказательства в самом коде/коммите — это RED FLAG. Помечай severity=serious с конкретикой:
- «commit message заявляет 51 items, но в коде только цикл foreach без проверки итогового count»
- «комментарий говорит "all parsed OK", но parse-проверка не возвращается / не логируется»
Это родилось из curator-задачи 2026-05-27 где Codex 3 раза подряд заявлял «backfill 51» при реальных 3/19/35.

🩺 ПРОВЕРКА: ЗАКРЫВАЕТ ЛИ ФИКС СИМПТОМ ИЛИ ТОЛЬКО МАСКИРУЕТ?
Задача обычно описывает симптом от пользователя («X мигает», «Y тормозит», «не могу Z»). Прежде чем дать OK:
1. Восстанови по тексту задачи: что именно увидел пользователь? Какой конкретный сценарий ломался?
2. Спроси сам себя: ЕСЛИ пользователь повторит этот сценарий после применения этого диффа — симптом ИСЧЕЗНЕТ или просто станет менее частым/будет глотаться guard'ом?
3. Если диф добавляет защиту (guard / try-catch / timeout / retry / epoch check / abort signal / debounce) — это часто МАСКА, а не фикс. Корень обычно лежит на этаж глубже: данные испорчены в источнике, а guard ловит их уже на выходе. Помечай severity=serious с пометкой «patches symptom, not root cause» и предложи где искать корень.
4. Особо для UI/HTTP пар: если диф меняет КЛИЕНТ (web/), но НЕ ТРОГАЕТ серверный эндпоинт, который этот клиент дёргает — это сильный сигнал маскировки. Перечисли эндпоинты, упомянутые в diff клиента, и спроси «их серверная сторона была пересмотрена в этом дифе?». Если нет — severity=serious с конкретным эндпоинтом для проверки.
5. Слова в комментариях кода и в коммит-сообщении: «race», «flicker», «stale», «timing», «debounce», «throttle», «retry» — это часто сигнал, что чинят временной симптом, а не источник несоответствия. Спроси «есть ли источник правды или два потока данных, которые расходятся?»

🔁 ПРОВЕРКА: ЭТО НЕ ПЕРВАЯ ПОПЫТКА?
Если в тексте задачи (или в HEAD-контексте ниже) есть признаки «уже исправляли», «повторяется», «снова», «опять», «ещё раз», «несмотря на <SHA>», ссылки на предыдущие коммиты-фиксы в этой же области — это RECURRENCE. Тогда:
- Назови явно, чем этот диф ОТЛИЧАЕТСЯ от прошлых попыток на уровне рут-каузы (а не имени файла).
- Если диф структурно ПОХОЖ на прошлые (тот же файл, та же функция, добавлен ещё один guard/epoch/abort/timeout) — severity=serious с подписью «N-th attempt, structurally similar to previous fix, root cause likely elsewhere».
- Если этот диф впервые трогает СОВСЕМ ДРУГОЙ слой (UI→server, client→config, lib→tests) — это хороший знак, не флаг.

ЗАДАЧА: $task

=== КОНТЕКСТ ЗАДАЧИ ===
DIFF_META: base=$base | diff_truncated=$diffTruncatedText | diff_bytes=$diffBytes
DIFF ниже — полный диф от начала задачи до HEAD. Если diff_truncated=true — файлы за пределом могут быть изменены; их отсутствие в DIFF не доказывает, что они не менялись.
TASK_HISTORY показывает все коммиты задачи — используй его для проверки полноты фаз и файлов.
SYMBOL_EVIDENCE — сигнатуры и первые строки функций, вызванных в DIFF, но определённых в других файлах. Если функция есть в SYMBOL_EVIDENCE или в блоке "ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ" из HEAD-контекста — не флагируй её как отсутствующую. Duplicate/drift флагируй только если изменённые строки DIFF реально вводят конфликтующую реализацию.
Аудируй только строки DIFF со знаком + или -. Не аудируй unchanged код из SYMBOL_EVIDENCE, TASK_HISTORY или HEAD-контекста.

=== CHANGED_FILES ===
$changedFilesText

=== TASK_HISTORY ===
$taskHistory

=== SYMBOL_EVIDENCE ===
$symbolEvidence

КОНТЕКСТ HEAD (для проверки over-claim: функции, упомянутые в diff, существуют в этих файлах — не помечай их как несуществующие):
$headContext

$truncationNote

GIT-ДИФФ:
$diff

Верни СТРОГО JSON без markdown и без пояснений:
{"verdict":"OK","severity":"none","issues":[],"summary":"одна фраза по-русски"}
Где severity = "serious" ТОЛЬКО если есть баг/уязвимость/регрессия, которую обязательно исправить до закрытия; иначе "minor" или "none".
"@
            $rawC = Invoke-LLM -Purpose 'critic' -Model $criticModelName -Prompt $criticPrompt -TimeoutSec 90 -Temperature 0.1
            $verdict='OK'; $severity='none'; $summary=''; $issuesText=''
            if (-not [string]::IsNullOrWhiteSpace($rawC)) {
              $cleanC = ($rawC -replace '```json','' -replace '```','').Trim()
              $mC = [regex]::Match($cleanC, '(?s)\{.*\}')
              if ($mC.Success) {
                try {
                  $cv = $mC.Value | ConvertFrom-Json
                  if ($cv.verdict)  { $verdict  = [string]$cv.verdict }
                  if ($cv.severity) { $severity = ([string]$cv.severity).Trim().ToLower() }
                  if ($cv.summary)  { $summary  = [string]$cv.summary }
                  if ($cv.issues) {
                    $issueParts = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($issue in @($cv.issues)) {
                      if ($null -eq $issue) { continue }
                      if ($issue -is [string]) {
                        $txtIssue = ([string]$issue).Trim()
                      } else {
                        $fields = New-Object 'System.Collections.Generic.List[string]'
                        foreach ($pn in @('file','line','severity','issue','problem','message','summary','fix')) {
                          try {
                            if ($issue.PSObject.Properties.Name -contains $pn) {
                              $pv = [string]$issue.$pn
                              if (-not [string]::IsNullOrWhiteSpace($pv)) { [void]$fields.Add(("{0}={1}" -f $pn,$pv)) }
                            }
                          } catch {}
                        }
                        if ($fields.Count -gt 0) { $txtIssue = [string]::Join(' | ', [string[]]@($fields.ToArray())) }
                        else { $txtIssue = ($issue | ConvertTo-Json -Compress -Depth 4) }
                      }
                      if (-not [string]::IsNullOrWhiteSpace($txtIssue)) { [void]$issueParts.Add($txtIssue) }
                    }
                    $issuesText = [string]::Join('; ', [string[]]@($issueParts.ToArray()))
                  }
                } catch {}
              }
            }
            if ([string]::IsNullOrWhiteSpace($issuesText) -and -not [string]::IsNullOrWhiteSpace($summary)) { $issuesText = $summary }

            # 2026-05-27: CLI-flag findings ALWAYS escalate to 'serious' regardless
            # of what the LLM critic decided. Deterministic checks override LLM
            # opinion (the LLM cannot run the CLI, so trust ground truth).
            if ($cliFlagIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $prefix = "Неверные CLI-флаги (ground-truth check, --help проверен реально): " + $cliFlagIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $prefix }
              else { $issuesText = $prefix + ' ; ' + $issuesText }
            }

            $taskShort = ($task -replace '\s+',' ').Trim()
            if ($taskShort.Length -gt 80) { $taskShort = $taskShort.Substring(0,80) }
            try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + "  model=$criticModelName verdict=$verdict severity=$severity crc=$crc | $taskShort | $summary | $issuesText") -Encoding UTF8 } catch {}
            if ($severity -eq 'serious') {
              $newCrc = $crc + 1
              Update-State ({ param($s) $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue $newCrc -Force }.GetNewClosure()) | Out-Null
              try { Set-TaskLastFailure -Kind critic_rejected -Text $issuesText } catch {}
              Add-Message -From system -Text "🔎 Независимый критик ($criticModelName) нашёл серьёзное (попытка $newCrc/$criticMaxRetries): $issuesText`n`nCodex, исправь это и снова доведи до STATUS: DONE — задачу НЕ закрываю." -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
              Update-State { param($s) $s.task_mode='normal' } | Out-Null
            } else {
              Add-Message -From system -Text "🔎 Критик ($criticModelName): $verdict / $severity — $summary" -Kind event | Out-Null
            }
          }
        }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + '  critic-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Fast ParseFile gate: syntax-check each changed .ps1 individually before slow smoke.
  # Gives specific file+line errors instantly; also catches newly-created .ps1 not yet in smoke list.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $pfFiles = @()
        try { $pfFiles = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { $_ -match '\.ps1$' }) } catch {}
        $pfFailed = $false
        foreach ($psf in $pfFiles) {
          $fullPath = Join-Path $bridgeRoot $psf
          if (Test-Path $fullPath) {
            $pfErrors = $null; $pfTokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($fullPath,[ref]$pfTokens,[ref]$pfErrors) | Out-Null
            if ($pfErrors -and $pfErrors.Count -gt 0) {
              $errLine = $pfErrors[0].Extent.StartLineNumber; $errMsg = $pfErrors[0].Message
              Add-Message -From system -Text "🚨 ParseFile FAILED: $psf line $errLine — $errMsg. Codex, исправь синтаксис." -Kind event | Out-Null
              Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
              $plannerStatus = 'CONTINUE'; $pfFailed = $true; break
            }
          }
        }
        if (-not $pfFailed -and $pfFiles.Count -gt 0) {
          Add-Message -From system -Text "✅ ParseFile OK: $($pfFiles -join ', ')" -Kind event | Out-Null
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  parsefile-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Auto-smoke gate: after critic passes, if .ps1 files changed vs HEAD, run smoke.ps1 to catch
  # broken masts before accepting DONE. Reuses verify_retry_count so no new state field needed.
  # Catches cases where [[VERIFIED: smoke OK]] is claimed but smoke actually fails.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $psChanged = $false
        try {
          $gitSmFiles = & git -C $bridgeRoot diff --name-only HEAD 2>$null
          $psChanged = (@($gitSmFiles | Where-Object { $_ -match '\.ps1$' })).Count -gt 0
        } catch {}
        if ($psChanged) {
          $smokeFile = Join-Path $bridgeRoot 'smoke.ps1'
          if (Test-Path $smokeFile) {
            $launch = [pscustomobject]@{ File = $smokeFile; Channel = (Get-EffectiveChannel) }
            $smokeOut = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
              param($Launch)
              & powershell -NoProfile -ExecutionPolicy Bypass -File ([string]$Launch.File) 2>&1 | Out-String
            }
            $smokeOk  = $smokeOut -imatch 'SMOKE OK'
            $smokeVrc = [int](Read-State).verify_retry_count
            if (-not $smokeOk) {
              $smokeShort = ($smokeOut -replace '\s+',' ').Trim()
              if ($smokeShort.Length -gt 300) { $smokeShort = $smokeShort.Substring(0,300) + '...' }
              try { Set-TaskLastFailure -Kind smoke_failed -Text $smokeShort } catch {}
              if ($smokeVrc -lt 2) {
                Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$false } | Out-Null
                Add-Message -From system -Text "🚨 Авто-smoke FAILED (попытка $($smokeVrc+1)/2) — .ps1 повреждены, задача НЕ закрывается. Codex, исправь: $smokeShort" -Kind event | Out-Null
                $plannerStatus = 'CONTINUE'
              } else {
                $sfDiff = ''
                try {
                  $sfBase = [string](Read-State).task_base_commit
                  if (-not [string]::IsNullOrWhiteSpace($sfBase)) {
                    $sfDiff = (& git -C $bridgeRoot diff $sfBase -- 2>$null | Out-String).Trim()
                    if ($sfDiff.Length -gt 2000) { $sfDiff = $sfDiff.Substring(0,2000) + "`n...[truncated]" }
                  }
                } catch {}
                $sfMsg = "🚨 Авто-smoke провалился 2× — закрываю как есть, нужно внимание оператора."
                if ($sfDiff) { $sfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$sfDiff`n``````" }
                $sfMsg += "`n`n**Smoke output:** $smokeShort"
                Add-Message -From system -Text $sfMsg -Kind event | Out-Null
                try { Send-PushEvent -Kind need_you -Text "Smoke FAIL: $(Get-PushSnippet -Text $task)" } catch {}
              }
            } else {
              Add-Message -From system -Text "✅ Авто-smoke: OK — .ps1 не сломаны." -Kind event | Out-Null
            }
          }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  auto-smoke-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # QA agent gate: after verify/coder-bypass/critic/parse/smoke gates, run runtime QA before accepting DONE.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stQa = Read-State
      if ([bool]$stQa.task_did_actions) {
        $qaTaskId = [string]$stQa.current_task_id
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = [string]$stQa.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = 'task-' + [string]$stQa.task_start_seq }
        $qaResult = Invoke-QAAgent -TaskId $qaTaskId -TaskTitle $task -Channel $Channel
        if ($qaResult.Verdict -eq 'FAIL') {
          Add-Message -From system -Text "🔴 QA-агент: FAIL`n$($qaResult.Summary)`nВозвращаю задачу на доработку." -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
        } else {
          Add-Message -From system -Text "✅ QA-агент: PASS — $($qaResult.Summary)" -Kind event | Out-Null
        }
      }
    } catch {
      Add-Message -From system -Text "⚠ QA-агент: ошибка запуска ($($_.Exception.Message)), пропускаю." -Kind event | Out-Null
    }
  }
  if ($plannerStatus -eq 'CONTINUE') {
    try {
      $stCp = Read-State
      $cpTaskId = [string]$stCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = [string]$stCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = 'task-' + [string]$stCp.task_start_seq }
      $cpStep = 0
      try { $cpStep = [int]$stCp.task_turn } catch { $cpStep = 0 }
      $conversationSummary = ''
      try {
        $conversationSummary = [string](Read-Summary)
      } catch {
        try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  summary-read-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
      }
      $cpSummary = if ($conversationSummary) { $conversationSummary.Substring(0, [Math]::Min(500, $conversationSummary.Length)) } else { '' }
      Write-TaskCheckpoint -TaskId $cpTaskId -TaskTitle $task -Step $cpStep -LastSummary $cpSummary -Channel $Channel
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  checkpoint-write-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE') {
    if ($mode -eq 'discuss') {
      try {
        $startSeqD = [int](Read-State).task_start_seq
        $thread = (Get-Messages -Since ($startSeqD - 1) | ForEach-Object { "**$($_.from):** $($_.text)" }) -join "`n`n"
        $dpath = Save-Decision -Title $task -Content $thread
        Add-Message -From system -Text "📝 Итог обсуждения сохранён: $dpath" -Kind event | Out-Null
      } catch {}
    }
    try {
      $memId = Add-TaskMemory -TaskText $task -Outcome $visibleReply -Source ('task:' + $mode)
      if ($memId) { Add-Message -From system -Text "🧠 Запомнено в долговременную память." -Kind event | Out-Null }
    } catch {}
    try {
      $stMem = Read-State
      $turnForSkill = [int]$stMem.task_turn
      $didActionsForSkill = [bool]$stMem.task_did_actions
      if ($turnForSkill -ge 2 -and $didActionsForSkill -and $modeBeforeIncrement -ne 'study') {
        $startSeqSkill = [int]$stMem.task_start_seq
        $thread = (Get-Messages -Since ($startSeqSkill - 1) | ForEach-Object {
          "**$($_.from):** $($_.text)"
        }) -join "`n`n"
        $skillId = Add-SkillMemory -TaskText $task -Transcript $thread
        if ($skillId) { Add-Message -From system -Text "📘 плейбук сохранён." -Kind event | Out-Null }
      }
    } catch {}
    try {
      if ($modeBeforeIncrement -eq 'study') {
        $studyReportPath = $null
        foreach ($fp in $fileMarkerPaths) {
          try {
            $candidate = [string]$fp
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.md' -and (Test-Path -LiteralPath $candidate)) {
              $studyReportPath = $candidate
              break
            }
          } catch {}
        }
        if ($studyReportPath) {
          $lessonCount = Add-StudyLessons -ReportPath $studyReportPath -TaskText $task
          Add-Message -From system -Text "🎓 уроков: $lessonCount" -Kind event | Out-Null
        }
      }
    } catch {}
    # If this was an autonomous backlog task, close it out.
    try {
      $doneBid = [string](Read-State).current_backlog_id
      if ($doneBid) {
        Set-Idea -Id $doneBid -Status 'done' | Out-Null
        Add-Message -From system -Text "✅ Автозадача из бэклога выполнена и закрыта." -Kind event | Out-Null
      }
    } catch {}
    # Mark ANY self-improvement commit as a hypothesis for the 24h verdict cycle (was previously
    # only autonomous backlog tasks -> we missed user-injected tasks and Doctor fixes entirely).
    # Wave 3 widening: any task that changed HEAD vs task_base_commit gets a baseline+commit row.
    try {
      $stEnd = Read-State
      $baseC = [string]$stEnd.task_base_commit
      $headC = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
      if ($baseC -and $headC -and $baseC -ne $headC) {
        Write-Hypothesis -CommitHash $headC -TaskText ([string]$task)
      }
    } catch {}
    # 🌱 Self-dev attribution: stamp the resulting commit on a self-executed idea so the safety
    # reflex can later correlate it to the 24h verdict (worse -> auto-dampen the dial). Read-mostly.
    try {
      $stSd = Read-State
      $sdBid = [string]$stSd.current_backlog_id
      if ($sdBid) {
        $sdIdea = Get-IdeaById $sdBid
        if ($sdIdea -and ([bool]$sdIdea.self_exec)) {
          $sdHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
          if ($sdHead) { Set-IdeaSelfExec -Id $sdBid -Dial ([string]$sdIdea.self_exec_dial) -Commit $sdHead | Out-Null }
        }
      }
    } catch {}
    # 🩺 If Doctor just finished a repair, restore the held task instead of going idle.
    if ([bool](Read-State).doctor_active) {
      try { Complete-Doctor } catch { try { Add-Message -From system -Text ("🩺 Complete-Doctor: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
      try { Send-PushEvent -Kind done -Text "🩺 Doctor fix shipped; resuming held task." } catch {}
      continue
    }
    try { Send-PushEvent -Kind done -Text "Задача: $(Get-PushSnippet -Text $task)" } catch {}
    Add-Message -From system -Text "✅ Задача выполнена. Жду следующую." -Kind event | Out-Null
    try {
      $stDoneCp = Read-State
      $doneCpTaskId = [string]$stDoneCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = [string]$stDoneCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = 'task-' + [string]$stDoneCp.task_start_seq }
      Clear-TaskCheckpoint -TaskId $doneCpTaskId -Channel $Channel
    } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s -PreserveReflectSkip; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    try { Send-PushEvent -Kind need_you -Text "Достигнут лимит ходов ($maxTurns): $(Get-PushSnippet -Text $task)" } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
