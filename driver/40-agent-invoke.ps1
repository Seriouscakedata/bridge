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
  # Premium Claude models (Opus/Fable/Mythos) get the heavy architecture-thinking hint.
  $heavyClaudeModel = ($Model -match '(?i)(opus|fable|mythos)')
  $effPrompt = if ($heavyClaudeModel) { $Prompt + "`n`nultrathink" } else { $Prompt }
  [System.IO.File]::WriteAllText($inF, $effPrompt, $Utf8NoBom)
  $plannerCwd = Get-ActiveProjectRoot
  if ([string]::IsNullOrWhiteSpace($plannerCwd)) { $plannerCwd = $bridgeRoot }
  $allowedTools = if ($Mode -eq 'advisory') { @('Read','Grep','Glob') }
                  elseif ($Mode -eq 'coder-fallback') { @('Read','Grep','Glob','Bash','Edit','MultiEdit','Write') }
                  elseif ($Mode -eq 'research') { @('Read','Grep','Glob','WebSearch','WebFetch') }
                  elseif ($Mode -eq 'study') { @('Read','Grep','Glob','WebSearch','WebFetch','Bash') }
                  else { @('Read','Grep','Glob','Bash') }
  # 2026-06-11 A1 (speed program): plain `-p` does NOT stream stdout — the only bytes arrive
  # with the final answer, so byte-growth liveness was blind for the whole turn and healthy
  # agentic turns >grace were killed as "zero-output" (large share of the measured 31%
  # sonnet zero-byte fallbacks were false kills). stream-json emits the init event in <1s and
  # ticks thinking_tokens/tool events throughout — byte growth now means real liveness.
  # Measured locally (CLI 2.1.170): first bytes at 839ms, thinking streams, result line last.
  $claudeArgs = @('-p','--output-format','stream-json','--verbose','--permission-mode','acceptEdits','--add-dir',$plannerCwd,'--allowedTools') + $allowedTools
  if ($Model) {
    $claudeArgs += @('--model', $Model)
    # 2026-06-09: xhigh on premium architecture models. Fable 5 was verified locally to accept this
    # flag through Claude Code; Sonnet keeps the CLI default for speed.
    if ($heavyClaudeModel) { $claudeArgs += @('--effort', 'xhigh') }
  }
  $reply = ''
  $claudeTimedOut = $false
  $claudeSilentExit = $false
  $claudeZeroOutputTimeout = $false
  # First-output grace (cold-start zero-output fast-fail -> Codex). 150s -> 300s (2026-06-09,
  # operator speed root): Claude reasons SILENTLY (no streamed output during extended thinking),
  # so a heavy planner turn emitted 0 bytes for >150s and was FALSELY killed as "zero-output",
  # thrashing to a Codex fallback when Claude was merely still reasoning. The 900s wall cap below
  # and the adaptive stagnation grace still backstop a genuinely-hung process; a true zero-output
  # hang now just takes 300s (not 150s) before fallback — a bounded, rare cost. (Sonnet/Haiku emit
  # first output well under this; only deep Opus reasoning needs the headroom.)
  # 2026-06-11 (speed audit): MADE MODEL-AWARE. Measured: 31% of sonnet planner turns emitted 0 bytes
  # for the full 300s then fell back to Codex — sonnet's first token normally lands in seconds, so a
  # 90s+ silence is a HUNG claude.exe, not thinking. Heavy reasoning models (opus/fable/mythos) keep
  # the 300s headroom (they really do reason silently); sonnet/haiku fast-fail at 90s -> ~150s saved
  # per affected atom. The 900s wall cap + adaptive stagnation grace still backstop genuine hangs.
  # 2026-06-11 A1: with stream-json the init event lands in <1s and thinking ticks bytes throughout,
  # so 60s of TRUE silence now means a genuinely hung claude.exe for ANY model (auth prompt, node
  # crash, network). One flat fast grace replaces the 90s/300s split — real hangs detected 5x faster.
  $plannerFirstOutputGraceMs = 60000
  $plannerFirstOutputGraceSec = [int]($plannerFirstOutputGraceMs / 1000)
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
    $waitReason = $null
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 900000 -ErrFile $errF -OutFile $outF -FirstOutputGraceMs $plannerFirstOutputGraceMs -StopReason ([ref]$waitReason))) {
      Stop-AgentTree $p.Id
      # Detect the opt-in zero-output grace kill, not a regular timeout or later stagnation abort.
      if ([string]$waitReason -eq 'zero_output_grace') {
        $claudeZeroOutputTimeout = $true
      }
      $replayModel = if ([string]::IsNullOrWhiteSpace($Model)) { 'claude' } else { $Model }
      $replayErrorType = if ($claudeZeroOutputTimeout) { 'planner_zero_output_timeout' } else { 'planner_timeout' }
      Add-ReplayRecordForCurrentTask -Role 'planner' -Model $replayModel -Mode $Mode -Prompt $Prompt -Response '' `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'timeout' -ErrorType $replayErrorType -Provider 'claude'
      # 2026-05-28: NO longer early-return on timeout — fall through to Codex
      # then Gemini-3-flash fallback ladder below. The old behavior bubbled up
      # 'planner_timeout' which triggered Doctor, which then ran ANOTHER hung
      # claude.exe and timed out again — two 15-min hangs per task. Now we
      # try alternates first.
      $claudeTimedOut = $true
    } elseif (Test-Path $outF) {
      $rawPlannerOut = Get-Content $outF -Raw -Encoding UTF8
      $reply = $rawPlannerOut
      # A1: stream-json output — the answer text lives in the LAST {"type":"result"} line's
      # .result field. Fall back to the raw text if no result line parses (older CLI / plain
      # text), so this stays backward-compatible.
      try {
        $resultLine = $null
        foreach ($streamLine in ($rawPlannerOut -split "`n")) {
          if ($streamLine -match '"type"\s*:\s*"result"') { $resultLine = $streamLine }
        }
        if ($resultLine) {
          $resultObj = $resultLine | ConvertFrom-Json
          if ($resultObj -and $resultObj.PSObject.Properties.Name -contains 'result' -and -not [string]::IsNullOrWhiteSpace([string]$resultObj.result)) {
            $reply = [string]$resultObj.result
          }
        }
      } catch {}
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
      if ([string]::IsNullOrWhiteSpace($se) -and [string]::IsNullOrWhiteSpace($so) -and (-not $claudeZeroOutputTimeout)) {
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
  $claudeUsable = (-not [string]::IsNullOrWhiteSpace($reply)) -and (-not $claudeTimedOut) -and (-not $claudeSilentExit) -and (-not $claudeZeroOutputTimeout)
  if ((-not $claudeUsable) -and (-not $NoFallback)) {
    # ---- Ladder step 1: Codex as planner ----
    $reason = if ($claudeZeroOutputTimeout) { "zero-output timeout (${plannerFirstOutputGraceSec}s)" } elseif ($claudeTimedOut) { 'timeout (900с)' } elseif ($claudeSilentExit) { 'silent exit' } else { 'пустой ответ' }
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
    $finalError = if ($claudeZeroOutputTimeout) { 'planner_zero_output_timeout' } elseif ($claudeTimedOut) { 'planner_timeout' } elseif ($claudeSilentExit) { 'planner_silent_exit' } else { 'planner_empty' }
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
      # 2026-06-06 (operator): PER-CHANNEL override. Lets a specific project channel that genuinely
      # needs broader access (e.g. a media project calling an external image/video API) run with a
      # wider sandbox WITHOUT lowering protection on main / control-plane channels — those keep the
      # global default (workspace-write). main is never in this map, so the bridge stays confined
      # while editing itself. Checked BEFORE the global coder.sandboxMode.
      try {
        $ch = ''
        try { $ch = [string](Get-EffectiveChannel) } catch {}
        if (-not [string]::IsNullOrWhiteSpace($ch) -and ($coderCfg.PSObject.Properties.Name -contains 'sandboxModeByChannel') -and $coderCfg.sandboxModeByChannel) {
          $byCh = $coderCfg.sandboxModeByChannel
          if ($byCh.PSObject.Properties.Name -contains $ch) {
            $cm = [string]$byCh.$ch
            if (-not [string]::IsNullOrWhiteSpace($cm) -and ($valid -contains $cm)) { return $cm }
          }
        }
      } catch {}
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
    # 2026-05-30: discuss = deep architectural dialogue (brainstorm/deep-think) where Codex critiques
    # and counter-proposes on hard problems -> xhigh, symmetric with Opus's xhigh in discuss. Was 'high'.
    return [pscustomobject]@{ effort='xhigh'; plen=$plen; mode=$mode; crc=$crc; wt='discuss-xhigh' }
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
    # FIX 2026-05-29: NEVER fall back to Claude-as-coder in DISCUSS mode. discuss needs TWO DISTINCT
    # agents (Claude proposes, Codex critiques). If Codex is busy and Claude also plays the Codex turn,
    # the "dialogue" becomes Claude talking to ITSELF -- "Codex принимает пункты Claude" where both are
    # Claude (operator-reported role-confusion). In discuss we let the real Codex turn wait/surface its
    # busy status instead of simulating the opponent with the same model.
    if ($codexBusyElsewhere -and -not $claudeBusyElsewhere -and $Mode -ne 'discuss') {
      $busyCh = ($others.GetEnumerator() | Where-Object { $_.Value -eq 'codex' } | Select-Object -First 1).Key
      Add-Message -From system -Text ("🔀 Fallback: Codex занят в канале '" + $busyCh + "' → Claude premium берёт coder-турн (реальное выполнение).") -Kind event | Out-Null
      $fallbackPrefix = @"
⚠ FALLBACK MODE: Ты сейчас замещаешь Codex-кодера (он занят в канале '$busyCh'). Выполняй задачу реально: можно читать/редактировать файлы и запускать команды доступными инструментами. Соблюдай все правила безопасности из промпта ниже: SAFETY для опасных действий, RUNJOB для долгих команд, UTF-8 BOM для .ps1, ParseFile/smoke/commit/restart.flag по правилам моста. Не вызывай Codex и не жди его освобождения — ты резервный кодер этого хода. Отчитайся кратко по результату.

ЗАДАЧА:
"@
      $fallbackModel = 'claude-fable-5'
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
  # 2026-06-01 ERR-007: when Doctor is active, the coder MUST be rooted at the bridge repo, not the
  # active channel's project_root. Doctor (Get-DoctorTaskText) is ALWAYS bridge self-repair — it
  # diagnoses bridge logs and fixes bridge code via `repair(<area>):` commits — but it can be TRIGGERED
  # inside a PROJECT channel (e.g. loop_detected during that project's parallel dispatch). With cwd set
  # to project_root, the coder's workspace-write sandbox rejected every apply_patch to bridge files as
  # "outside project", so the bridge could diagnose but never self-repair. Rooting Doctor's coder at the
  # bridge restores the self-repair loop. (bridgeRoot is always in Get-AllowedCoderRoots, so the
  # path-confinement tripwire below still passes.)
  $doctorActiveNow = $false; try { $doctorActiveNow = [bool](Read-State).doctor_active } catch {}
  $coderCwd = if ($doctorActiveNow) { $bridgeRoot }
              elseif ($coderBinding -and [bool]$coderBinding.ok) { [string]$coderBinding.project_root }
              else { $bridgeRoot }
  if ([string]::IsNullOrWhiteSpace($coderCwd)) { $coderCwd = $bridgeRoot }
  if ($doctorActiveNow -and ([string]$coderBinding.slug -ne 'main')) {
    try { Add-Message -From system -Text "🩺 Doctor self-repair: coder укоренён в bridge-репо (не в проекте), чтобы фикс кода моста проходил sandbox (ERR-007)." -Kind event | Out-Null } catch {}
  }
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
  $isProbeTurn = $false
  $probeMetrics = $null
  $probeTimeoutMs = 0
  $probeExit = 'unknown'
  $probeVerdict = ''
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
    $coderTimeoutMs = 900000
    try {
      $timeoutCfg = Get-BridgeConfig
      if ($timeoutCfg.coderTimeoutMs -gt 0) { $coderTimeoutMs = [int]$timeoutCfg.coderTimeoutMs }
    } catch {
      try { if ($cfg.coderTimeoutMs -gt 0) { $coderTimeoutMs = [int]$cfg.coderTimeoutMs } } catch {}
    }
    # 2026-06-11 A2 (speed program): the planner-fallback rung inherited the full coder budget
    # (25 min) — when Claude hung AND Codex hung, the "quick reserve plan" took longer than the
    # original hang (worst case ~44 min to an answer). The fallback prompt itself demands a SHORT
    # reply with no file edits; 6 minutes is generous for a read-and-plan turn.
    if ($Mode -eq 'planner-fallback' -and $coderTimeoutMs -gt 360000) { $coderTimeoutMs = 360000 }
    $probeTags = @()
    $probeTaskPrompt = $Prompt
    try {
      $probeState = Read-State
      if ($probeState -and $probeState.current_task) { $probeTaskPrompt = [string]$probeState.current_task }
      $probeBacklogId = if ($probeState -and $probeState.current_backlog_id) { [string]$probeState.current_backlog_id } else { '' }
      if (-not [string]::IsNullOrWhiteSpace($probeBacklogId) -and (Get-Command Get-IdeaById -ErrorAction SilentlyContinue)) {
        $probeIdea = Get-IdeaById -Id $probeBacklogId
        if ($probeIdea -and $probeIdea.tags) { $probeTags = @($probeIdea.tags | ForEach-Object { [string]$_ }) }
      }
    } catch { $probeTags = @() }
    $isProbeTurn = Test-IsProbeTask -Prompt $probeTaskPrompt -Command '' -Tags $probeTags
    if ($isProbeTurn) {
      try {
        $probeMetrics = Get-RuntimeStateMetrics
        $probeTimeoutMs = Get-AdaptiveProbeTimeoutMs -Metrics $probeMetrics -CoderTimeoutMs $coderTimeoutMs
        $coderTimeoutMs = $probeTimeoutMs
        try {
          Add-Content -LiteralPath (Join-Path $bridgeRoot 'driver.out.log') -Value (
            (Get-Date).ToString('s') + " probe-timeout computed=$probeTimeoutMs metrics=" + ($probeMetrics | ConvertTo-Json -Compress -Depth 4)
          ) -Encoding UTF8
        } catch {}
      } catch {
        $probeExit = 'error'
        $probeVerdict = 'adaptive-timeout-error: ' + $_.Exception.Message
        try { Add-Message -From system -Text ("⚠ probe-timeout: adaptive calculation failed, using coderTimeoutMs=" + $coderTimeoutMs + ": " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      }
    }
    $waitOk = $false
    try {
      $waitOk = Wait-AgentProcess -Proc $p -TimeoutMs $coderTimeoutMs -MsgFile $msgF -ErrFile $errF -OutFile $outF
    } catch {
      $probeExit = 'error'
      $probeVerdict = 'wait-error: ' + $_.Exception.Message
      throw
    }
    if (-not $waitOk) {
      $probeExit = 'timeout'
      $probeVerdict = 'timeout'
      Stop-AgentTree $p.Id
      Add-ReplayRecordForCurrentTask -Role 'coder' -Model $replayCoderModel -Mode $Mode -Prompt $Prompt -Response '' `
        -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'timeout' -ErrorType 'coder_timeout' -Provider 'codex'
      return [pscustomobject]@{ text=''; status='timeout'; duration=[int]$sw.Elapsed.TotalSeconds; errorType='coder_timeout' }
    }
    $probeExit = 'ok'
    if (Test-Path $msgF) { $reply = Get-Content $msgF -Raw -Encoding UTF8 }
    if ($isProbeTurn -and $reply -match '(?m)^\s*(STATUS|VERDICT|verdict)\s*[:=]\s*(.+?)\s*$') { $probeVerdict = [string]$matches[2] }
  } catch {
    if ($isProbeTurn -and $probeExit -eq 'unknown') {
      $probeExit = 'error'
      $probeVerdict = $_.Exception.Message
    }
    throw
  } finally {
    if ($isProbeTurn) {
      try {
        if ($null -eq $probeMetrics) { $probeMetrics = Get-RuntimeStateMetrics }
        if ($probeTimeoutMs -le 0) { $probeTimeoutMs = $coderTimeoutMs }
        if ([string]::IsNullOrWhiteSpace($probeVerdict)) { $probeVerdict = $probeExit }
        Write-ProbeDuration -ComputedTimeoutMs $probeTimeoutMs -ActualDurationMs ([int]$sw.ElapsedMilliseconds) -Metrics $probeMetrics -Exit $probeExit -Verdict $probeVerdict
      } catch {
        try { Add-Message -From system -Text ("⚠ probe-timeout: failed to write duration telemetry: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      }
    }
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
