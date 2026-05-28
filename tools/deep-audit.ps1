[CmdletBinding()]
param(
  [string]$BridgePath = '',
  # 2026-05-28: ProjectRoot is the codebase the deep-audit actually inspects.
  # By default = BridgePath (bridge audits itself). For non-main channels the
  # caller passes the channel's project_root so codex sees the project's git
  # history instead of bridge's. tmp files + audit.log still live under
  # BridgePath (central audit infra).
  [string]$ProjectRoot = '',
  [int]$CodexTimeoutSec = 180,
  [int]$ClaudeTimeoutSec = 90,
  [switch]$NoCodex,
  [switch]$NoClaude,
  # 2026-05-28: if both flags are clear, codex.exe and claude.exe spawn
  # concurrently. Total wall time = max(codex, claude) instead of sum.
  # Pass -Sequential to force the old back-to-back behavior (debugging).
  [switch]$Sequential,
  # 2026-05-28: functional-pass agent selector.
  #   'gemini-only' (DEFAULT) — go straight to gemini-3-flash; skip claude.exe.
  #                   A/B verified 2026-05-28: even with the encoding fix in
  #                   place, gemini-3-flash found 46 findings (10 critical
  #                   undocumented systems) vs claude.exe's 32 findings (1
  #                   trivial self-referential critical). gemini was the same
  #                   wall time (~250s), saved claude.exe tokens, and caught
  #                   the architect-agent / llm-router / semantic-code-memory
  #                   gaps that claude missed.
  #   'auto'        — try claude.exe first, fall back to gemini-3-flash on
  #                   hang/empty. Kept for fallback testing / if claude.exe
  #                   on Windows is ever fixed upstream.
  [ValidateSet('auto','gemini-only')]
  [string]$FunctionalAgent = 'gemini-only',
  # 2026-05-28: write the result JSON to this file with explicit UTF-8 encoding,
  # bypassing the subprocess stdout pipe entirely. Required workaround for PS 5.1:
  # when this script is launched via Start-Process -RedirectStandardOutput
  # -WindowStyle Hidden, the stdout stream is bound to the system console code-
  # page (cp866 on Russian Windows) BEFORE the script can set
  # [Console]::OutputEncoding=UTF8, so any Cyrillic text in the JSON gets
  # re-encoded to cp866 mid-flight and arrives as garbage to the caller.
  # Writing directly to a file with [System.IO.File]::WriteAllText + UTF-8
  # NoBOM sidesteps the console layer completely. If empty, falls back to
  # stdout (legacy behavior).
  [string]$OutputFile = ''
)

# Resolve default BridgePath: param-default can't use $PSScriptRoot reliably
# (it's empty during param-binding in some invocation contexts).
if ([string]::IsNullOrWhiteSpace($BridgePath)) {
  $scriptDir = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    try { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
  }
  if (-not [string]::IsNullOrWhiteSpace($scriptDir)) {
    $BridgePath = Split-Path -Parent $scriptDir
  } else {
    $BridgePath = 'C:\Users\rafie\OneDrive\Documents\bridge'
  }
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = $BridgePath }
try { $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot) } catch {}
try { $BridgePath = [System.IO.Path]::GetFullPath($BridgePath) } catch {}

# tools/deep-audit.ps1 -- backlog item 90747e410b "deep-audit Codex+Claude".
#
# Phase 2 of the nightly audit pipeline. Runs AFTER static+deepseek finishes,
# uses the real Codex/Claude agents (not just deepseek/gemini) to get a
# qualitative second opinion. Specifically:
#
#   CODEX-SECURITY:  reads last-24h git diff, looks for REAL injection /
#                    path-traversal / auth-bypass / hardcoded-secrets that
#                    static grep misses. Returns structured JSON findings.
#   CLAUDE-FUNCTIONAL: reads scoped features/registry.json + state.json + audit.log
#                    week, looks for drift (description vs code) and dormant
#                    features. Returns structured JSON observations.
#
# Outputs to stdout: { codex_security: [...], claude_functional: [...] }
# Designed to be invoked from tools/audit.ps1 OR manually for testing.
#
# SKIP conditions:
# - No .ps1/.html commits in last 24h -> skip codex (nothing changed)
# - scoped features/registry.json missing -> skip functional pass (no context)
# - codex.exe / claude.exe not resolvable -> skip that half gracefully

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Helpers ---

function Get-DeepAuditBridgeRoot {
  if ($BridgePath -and (Test-Path -LiteralPath $BridgePath)) {
    return [System.IO.Path]::GetFullPath($BridgePath)
  }
  return [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-DeepAuditConfig {
  $root = Get-DeepAuditBridgeRoot
  $cfgPath = Join-Path $root 'config.json'
  if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
  try { return (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Resolve-DeepCodexExe {
  param($Cfg)
  $cands = @(
    "$env:LOCALAPPDATA\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\OpenAI\Codex\bin\codex.exe",
    "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
  )
  if ($Cfg -and $Cfg.codexExe) { $cands += [string]$Cfg.codexExe }
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
  return $null
}

function Resolve-DeepClaudeExe {
  param($Cfg)
  $globs = @(
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code\*\claude.exe",
    "$env:APPDATA\Claude\claude-code\*\claude.exe"
  )
  if ($Cfg -and $Cfg.claudeGlob) { $globs += [string]$Cfg.claudeGlob }
  foreach ($g in $globs) {
    if (-not $g) { continue }
    $hits = @(Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($hits.Count -gt 0) { return $hits[0].FullName }
  }
  return $null
}

function Get-Last24hChangedFiles {
  param([string]$Root)
  try {
    $files = & git -C $Root log --since='24 hours ago' --name-only --pretty=format: 2>$null
    return @($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique | Where-Object { $_ -match '\.(ps1|html|js|json)$' })
  } catch { return @() }
}

function Get-FileContentCapped {
  param([string]$Path, [int]$Cap = 4000)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try {
    $c = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($c.Length -gt $Cap) { return $c.Substring(0, $Cap) + "`n...[truncated at $Cap chars]" }
    return $c
  } catch { return '' }
}

function Get-DeepAuditFeatureScope {
  param([string]$BridgeRoot)
  try {
    $commonLib = Join-Path $BridgeRoot 'lib\common.ps1'
    if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib 2>$null | Out-Null }
    $channelsLib = Join-Path $BridgeRoot 'lib\channels.ps1'
    if (-not (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $channelsLib -PathType Leaf)) {
      . $channelsLib 2>$null | Out-Null
    }
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) {
      return (Get-EffectiveScope)
    }
  } catch {}
  $featuresRoot = Join-Path $BridgeRoot 'features'
  return [pscustomobject]@{
    slug = 'main'
    is_bridge = $true
    bridge_root = $BridgeRoot
    project_root = $BridgeRoot
    features_root = $featuresRoot
    features_registry = (Join-Path $featuresRoot 'registry.json')
    features_state = (Join-Path $featuresRoot 'state.json')
    features_exists = (Test-Path -LiteralPath $featuresRoot -PathType Container)
  }
}

function Test-IsTestFile {
  param([string]$Path)
  $name = [System.IO.Path]::GetFileName($Path)
  if ($name -match '(?i)\b(test|smoke|wave-.*-test|scenario)') { return $true }
  if ($Path -match '(?i)scenarios[/\\]') { return $true }
  return $false
}

function Extract-Json {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ($Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  # Try array first, then object
  $m = [regex]::Match($clean, '(?s)\[.*\]')
  if (-not $m.Success) { $m = [regex]::Match($clean, '(?s)\{.*\}') }
  if (-not $m.Success) { return $null }
  try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

# --- Codex security pass (async-friendly split) ---
#
# 2026-05-28: split into Start-CodexSecurityAsync + Complete-CodexSecurityAsync
# so codex.exe can run in parallel with claude.exe. Each returns/consumes a
# state object carrying { proc; tmp files; deadline; pre-computed skip-result }.
# Sequential mode falls back to wrapper Invoke-CodexSecurityPass below.

function Start-CodexSecurityAsync {
  param([string]$ProjRoot, [string]$BridgeRoot, [string]$CodexExe, [int]$TimeoutSec)
  # If the project has no relevant changes, return a "skipped" state that
  # Complete-CodexSecurityAsync will pass through unchanged.
  $changed = Get-Last24hChangedFiles -Root $ProjRoot
  $relevant = @($changed | Where-Object { -not (Test-IsTestFile -Path $_) })
  if ($relevant.Count -eq 0) {
    Write-Host "[deep-audit] codex: no .ps1/.html commits in last 24h, skip"
    return [pscustomobject]@{
      kind = 'codex'; proc = $null; preResult = @{ skipped = $true; reason = 'no_changes_last_24h'; findings = @() }
    }
  }
  Write-Host "[deep-audit] codex: examining $($relevant.Count) changed files..."
  $bodyBuilder = New-Object 'System.Text.StringBuilder'
  [void]$bodyBuilder.AppendLine('Ты security-аудитор. Это git-diff проекта за 24 часа. Найди РЕАЛЬНЫЕ уязвимости — не "теоретические", а такие, что можно эксплуатировать.')
  [void]$bodyBuilder.AppendLine('')
  [void]$bodyBuilder.AppendLine('ИЩИ:')
  [void]$bodyBuilder.AppendLine('- command injection: где user-input (HTTP body, URL params, file content) попадает в shell, dynamic command evaluation или process launch без sanitization')
  [void]$bodyBuilder.AppendLine('- path traversal: Get-Content/Set-Content с путём из request без GetFullPath/StartsWith($BridgeRoot) проверки')
  [void]$bodyBuilder.AppendLine('- auth bypass: новый /api/X handler в server.ps1 без вызова Test-Auth')
  [void]$bodyBuilder.AppendLine('- hardcoded secrets: API-ключи, токены, пароли в коде (не в secrets.json)')
  [void]$bodyBuilder.AppendLine('- abandoned mutex: $mutex.WaitOne без try/finally { ReleaseMutex }')
  [void]$bodyBuilder.AppendLine('')
  [void]$bodyBuilder.AppendLine('ИГНОРИРУЙ false-positives:')
  [void]$bodyBuilder.AppendLine('- audit-security.ps1: намеренно содержит detector strings для анализа dynamic command execution')
  [void]$bodyBuilder.AppendLine('- smoke.ps1, scenarios/*.js, wave-*-tests.ps1: тестовый код, не expose endpoints')
  [void]$bodyBuilder.AppendLine('- watchdog.ps1, lib/canary.ps1: служебный код, упоминание /api/ — не handler')
  [void]$bodyBuilder.AppendLine('')
  [void]$bodyBuilder.AppendLine('ФАЙЛЫ:')
  $totalChars = 0
  foreach ($f in $relevant) {
    $full = Join-Path $ProjRoot $f
    $content = Get-FileContentCapped -Path $full -Cap 4000
    if ([string]::IsNullOrWhiteSpace($content)) { continue }
    $totalChars += $content.Length
    if ($totalChars -gt 50000) { [void]$bodyBuilder.AppendLine("... остальные файлы пропущены (общий лимит 50К)"); break }
    [void]$bodyBuilder.AppendLine("--- $f ---")
    [void]$bodyBuilder.AppendLine($content)
    [void]$bodyBuilder.AppendLine('')
  }
  [void]$bodyBuilder.AppendLine('')
  [void]$bodyBuilder.AppendLine('Верни СТРОГО JSON-массив (или [] если уязвимостей не нашёл):')
  [void]$bodyBuilder.AppendLine('[{"file":"путь","line":N,"severity":"critical|warning","category":"command-injection|path-traversal|auth-bypass|hardcoded-secret|abandoned-mutex","finding":"что именно","recommendation":"как починить"}]')
  [void]$bodyBuilder.AppendLine('')
  [void]$bodyBuilder.AppendLine('После JSON напиши на отдельной строке: STATUS: DONE')

  # Write prompt to temp file (tmp lives under bridge audit/, NOT under ProjRoot).
  $tmpDir = Join-Path $BridgeRoot 'audit\tmp'
  if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $inF = Join-Path $tmpDir ("deep-codex-in_$stamp.txt")
  $msgF = Join-Path $tmpDir ("deep-codex-out_$stamp.txt")
  $outF = Join-Path $tmpDir ("deep-codex-stdout_$stamp.txt")
  $errF = Join-Path $tmpDir ("deep-codex-stderr_$stamp.txt")
  [System.IO.File]::WriteAllText($inF, $bodyBuilder.ToString(), $Utf8NoBom)

  Write-Host "[deep-audit] codex: spawning codex.exe (timeout ${TimeoutSec}s, project=$ProjRoot)..."
  try {
    $reasonArg = 'model_reasoning_effort="medium"'
    $spawn = {
      Start-Process -FilePath $CodexExe `
        -ArgumentList 'exec','--color','never','--skip-git-repo-check','-c',$reasonArg,'-s','read-only','-C',$ProjRoot,'-o',$msgF,'-' `
        -WorkingDirectory $ProjRoot -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    }
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
      $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action $spawn
    } else {
      $p = & $spawn
    }
    return [pscustomobject]@{
      kind = 'codex'; proc = $p; preResult = $null
      msgF = $msgF; inF = $inF; outF = $outF; errF = $errF
      startedAt = (Get-Date); timeoutSec = $TimeoutSec
    }
  } catch {
    Write-Host "[deep-audit] codex: spawn failed: $($_.Exception.Message)"
    Remove-Item $inF,$msgF,$outF,$errF -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      kind = 'codex'; proc = $null; preResult = @{ skipped = $false; error = 'codex_spawn_failed'; findings = @() }
    }
  }
}

function Complete-CodexSecurityAsync {
  param($State)
  if (-not $State) { return @{ skipped = $true; reason = 'no_state'; findings = @() } }
  if ($State.preResult) { return $State.preResult }
  if (-not $State.proc) { return @{ skipped = $false; error = 'no_proc'; findings = @() } }

  $remainingMs = [int]([Math]::Max(0, ($State.timeoutSec * 1000) - ((Get-Date) - $State.startedAt).TotalMilliseconds))
  $waited = $State.proc.WaitForExit($remainingMs)
  if (-not $waited) {
    try { $State.proc.Kill() } catch {}
    Write-Host "[deep-audit] codex: TIMEOUT after $($State.timeoutSec)s"
    Remove-Item $State.inF,$State.msgF,$State.outF,$State.errF -ErrorAction SilentlyContinue
    return @{ skipped = $false; error = 'codex_timeout'; findings = @() }
  }

  # 2026-05-28: codex.exe `-o $msgF` does NOT always materialise the final
  # reply in the output file — on this machine the same JSON tends to leak
  # to stdout (captured in $outF) instead. So read both and pick whichever
  # has actual content; prefer the -o file because it's the documented path.
  $replyFromMsg = if (Test-Path $State.msgF) { Get-Content $State.msgF -Raw -Encoding UTF8 } else { '' }
  $replyFromOut = if (Test-Path $State.outF) { Get-Content $State.outF -Raw -Encoding UTF8 } else { '' }
  $replySource = ''
  $reply = ''
  if (-not [string]::IsNullOrWhiteSpace($replyFromMsg)) {
    $reply = $replyFromMsg
    $replySource = 'msg-file'
  } elseif (-not [string]::IsNullOrWhiteSpace($replyFromOut)) {
    $reply = $replyFromOut
    $replySource = 'stdout-fallback'
    Write-Host "[deep-audit] codex: -o file empty, reading from stdout instead"
  }
  Remove-Item $State.inF,$State.msgF,$State.outF,$State.errF -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($reply)) {
    return @{ skipped = $false; error = 'codex_empty_reply'; findings = @() }
  }
  $parsed = Extract-Json -Text $reply
  $findings = @()
  if ($parsed) {
    if ($parsed -is [Array]) { $findings = @($parsed) }
    elseif ($parsed.findings) { $findings = @($parsed.findings) }
  }
  Write-Host "[deep-audit] codex: returned $($findings.Count) findings (source=$replySource)"
  return @{ skipped = $false; findings = $findings; tokens = $reply.Length; source = $replySource }
}

function Invoke-CodexSecurityPass {
  # Legacy synchronous wrapper (start + wait in one call). Used for -Sequential.
  param([string]$ProjRoot, [string]$BridgeRoot, [string]$CodexExe, [int]$TimeoutSec)
  $state = Start-CodexSecurityAsync -ProjRoot $ProjRoot -BridgeRoot $BridgeRoot -CodexExe $CodexExe -TimeoutSec $TimeoutSec
  return (Complete-CodexSecurityAsync -State $state)
}

# --- Claude functional pass (async-friendly split) ---

function Start-ClaudeFunctionalAsync {
  param([string]$ProjRoot, [string]$BridgeRoot, [string]$ClaudeExe, [int]$TimeoutSec)
  # Registry/state are scoped to the effective channel; audit-log lives under BridgeRoot.
  # Git history is per-project (ProjRoot).
  $featureScope = Get-DeepAuditFeatureScope -BridgeRoot $BridgeRoot
  $registryPath = [string]$featureScope.features_registry
  if (-not (Test-Path -LiteralPath $registryPath)) {
    Write-Host "[deep-audit] claude: feature registry missing for channel '$($featureScope.slug)', skip"
    return [pscustomobject]@{
      kind = 'claude'; proc = $null; preResult = @{ skipped = $true; reason = 'no_registry'; findings = @() }
    }
  }
  $registryRaw = Get-FileContentCapped -Path $registryPath -Cap 30000
  $statePath = [string]$featureScope.features_state
  $stateRaw = if (Test-Path -LiteralPath $statePath) { Get-FileContentCapped -Path $statePath -Cap 5000 } else { '{}' }
  $auditLogTail = ''
  $auditLogPath = Join-Path $BridgeRoot 'audit\audit.log'
  if (Test-Path -LiteralPath $auditLogPath) {
    try { $auditLogTail = (Get-Content -LiteralPath $auditLogPath -Tail 30 -Encoding UTF8 | Out-String).Trim() } catch {}
  }
  $gitLogWeek = ''
  try { $gitLogWeek = (& git -C $ProjRoot log --since='7 days ago' --pretty=format:'%h %s' 2>$null | Out-String).Trim() } catch {}

  $promptBuilder = New-Object 'System.Text.StringBuilder'
  [void]$promptBuilder.AppendLine('Ты архитектурный аудитор автономного моста Claude+Codex. Я дам тебе:')
  [void]$promptBuilder.AppendLine('1. Реестр фич текущего канала — что мы заявляем что есть в системе')
  [void]$promptBuilder.AppendLine('2. State фич (last_activated_at, last_health) — что фактически активировалось')
  [void]$promptBuilder.AppendLine('3. Хвост audit.log за неделю — тренды')
  [void]$promptBuilder.AppendLine('4. Git log за неделю — что реально менялось в коде')
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('ОЦЕНИ:')
  [void]$promptBuilder.AppendLine('- DORMANT: какие фичи в реестре статус=active, но last_activated_at>30 дней назад (или null)?')
  [void]$promptBuilder.AppendLine('- DRIFT: где описание фичи в реестре расходится с её реальным поведением (видимо в git log)?')
  [void]$promptBuilder.AppendLine('- COVERAGE: какие фичи не имеют scenarios в registry, но это user-facing? (scenario_recommended)')
  [void]$promptBuilder.AppendLine('- UNDOCUMENTED: какие паттерны в git log не отражены в реестре? (новый функционал без записи)')
  [void]$promptBuilder.AppendLine('- TREND: видны ли в audit.log повторяющиеся проблемы (одна и та же категория > 3 раза)?')
  [void]$promptBuilder.AppendLine('')
  # 2026-05-28: was 'НЕ ПРЕДЛАГАЙ удалять — только маркируй для human-review'.
  # That default made every finding land in the backlog with an explicit
  # 'Mark for human-review' tail, which neutered the bridge's autonomy — it
  # treated each item as 'wait for operator' instead of attempting a fix.
  # Now LLM is told to write actionable recommendations; ONLY irreversible
  # actions (deletion, billing, drop) get the [HUMAN-REVIEW] prefix.
  [void]$promptBuilder.AppendLine('Для каждого finding выдай actionable recommendation, которую мост может выполнить сам.')
  [void]$promptBuilder.AppendLine('ИСКЛЮЧЕНИЕ: если действие НЕОБРАТИМОЕ (удаление кода/фич/файлов, изменение биллинга, drop таблиц, force-push) — начни recommendation с префикса "[HUMAN-REVIEW]".')
  [void]$promptBuilder.AppendLine('Не предлагай удалять активно используемые фичи без явных доказательств что они мертвы.')
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('=== РЕЕСТР ФИЧ ===')
  [void]$promptBuilder.AppendLine($registryRaw)
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('=== STATE (last_activated, last_health) ===')
  [void]$promptBuilder.AppendLine($stateRaw)
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('=== AUDIT LOG (последние 30 строк) ===')
  [void]$promptBuilder.AppendLine($auditLogTail)
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('=== GIT LOG за неделю ===')
  [void]$promptBuilder.AppendLine($gitLogWeek)
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('Верни СТРОГО JSON-массив:')
  [void]$promptBuilder.AppendLine('[{"feature_id":"id","category":"dormant|drift|coverage|undocumented|trend","severity":"critical|warning|info","observation":"что заметил","recommendation":"что предлагаешь"}]')
  [void]$promptBuilder.AppendLine('Если ничего не нашёл — верни [].')

  $tmpDir = Join-Path $BridgeRoot 'audit\tmp'
  if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $inF = Join-Path $tmpDir ("deep-claude-in_$stamp.txt")
  $outF = Join-Path $tmpDir ("deep-claude-out_$stamp.txt")
  $errF = Join-Path $tmpDir ("deep-claude-err_$stamp.txt")
  [System.IO.File]::WriteAllText($inF, $promptBuilder.ToString(), $Utf8NoBom)

  Write-Host "[deep-audit] claude: spawning claude.exe (timeout ${TimeoutSec}s, project=$ProjRoot)..."
  $allowedTools = @('Read','Grep','Glob')
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$ProjRoot,'--allowedTools') + $allowedTools + @('--model','sonnet')
  try {
    $spawn = {
      Start-Process -FilePath $ClaudeExe -ArgumentList $claudeArgs `
        -WorkingDirectory $ProjRoot -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    }
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
      $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action $spawn
    } else {
      $p = & $spawn
    }
    return [pscustomobject]@{
      kind = 'claude'; proc = $p; preResult = $null
      promptText = $promptBuilder.ToString()
      bridgeRoot = $BridgeRoot
      inF = $inF; outF = $outF; errF = $errF
      startedAt = (Get-Date); timeoutSec = $TimeoutSec
    }
  } catch {
    Write-Host "[deep-audit] claude: spawn failed: $($_.Exception.Message)"
    Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      kind = 'claude'; proc = $null; preResult = @{ skipped = $false; error = 'claude_spawn_failed'; findings = @() }
    }
  }
}

function Invoke-DeepGeminiClaudeFallback {
  # 2026-05-28: shared helper. claude.exe -p has TWO failure modes on large
  # stdin: hang-then-timeout, and return-empty-fast. Both should fall back to
  # a cheaper Gemini model instead of silently emitting zero findings.
  #
  # Model policy (set by user 2026-05-28): NEVER use gemini-2.5-pro anywhere
  # — too expensive. gemini-3-flash is allowed but only as a last-resort
  # reserve since it's also pricier than flash-lite. So this fallback fires
  # only when claude.exe genuinely failed and there is no other path; the
  # primary find-by-Codex pass still runs and most useful findings come
  # from there.
  param([string]$BridgeRoot, [string]$PromptText, [string]$FailMode)
  $fallbackModel = 'gemini-3-flash'
  Write-Host "[deep-audit] claude: $FailMode -> falling back to Invoke-LLM $fallbackModel (reserve only)"
  $commonLib = Join-Path $BridgeRoot 'lib\common.ps1'
  if (-not (Test-Path -LiteralPath $commonLib)) {
    return @{ skipped = $false; error = ("claude_${FailMode}_no_common_lib"); findings = @() }
  }
  try {
    . $commonLib 2>$null | Out-Null
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
      return @{ skipped = $false; error = ("claude_${FailMode}_no_invoke_llm"); findings = @() }
    }
    $fbReply = Invoke-LLM -Purpose 'audit-functional' -Model $fallbackModel -Prompt $PromptText -TimeoutSec 120 -Temperature 0.2
    if ([string]::IsNullOrWhiteSpace($fbReply)) {
      return @{ skipped = $false; error = ("claude_${FailMode}_fallback_empty"); findings = @() }
    }
    $fbParsed = Extract-Json -Text $fbReply
    $fbFindings = @()
    if ($fbParsed) {
      if ($fbParsed -is [Array]) { $fbFindings = @($fbParsed) }
      elseif ($fbParsed.findings) { $fbFindings = @($fbParsed.findings) }
    }
    Write-Host "[deep-audit] claude->$fallbackModel fallback ($FailMode): returned $($fbFindings.Count) findings"
    return @{ skipped = $false; findings = $fbFindings; tokens = $fbReply.Length; source = ($fallbackModel + '-fallback') }
  } catch {
    Write-Host "[deep-audit] claude fallback failed: $($_.Exception.Message)"
    return @{ skipped = $false; error = ("claude_${FailMode}_fallback_exception"); findings = @() }
  }
}

function Complete-ClaudeFunctionalAsync {
  param($State)
  if (-not $State) { return @{ skipped = $true; reason = 'no_state'; findings = @() } }
  if ($State.preResult) { return $State.preResult }
  if (-not $State.proc) { return @{ skipped = $false; error = 'no_proc'; findings = @() } }

  $remainingMs = [int]([Math]::Max(0, ($State.timeoutSec * 1000) - ((Get-Date) - $State.startedAt).TotalMilliseconds))
  $waited = $State.proc.WaitForExit($remainingMs)
  if (-not $waited) {
    try { $State.proc.Kill() } catch {}
    Write-Host "[deep-audit] claude: TIMEOUT after $($State.timeoutSec)s"
    Remove-Item $State.inF,$State.outF,$State.errF -ErrorAction SilentlyContinue
    # 2026-05-28: known issue — claude.exe -p hangs on large stdin (~67K context)
    # on this machine. Instead of silently losing the functional pass, fall back
    # to a cheaper Gemini reserve model (gemini-3-flash) with the same prompt.
    return (Invoke-DeepGeminiClaudeFallback -BridgeRoot $State.bridgeRoot -PromptText $State.promptText -FailMode 'timeout')
  }

  $reply = if (Test-Path $State.outF) { Get-Content $State.outF -Raw -Encoding UTF8 } else { '' }
  Remove-Item $State.inF,$State.outF,$State.errF -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($reply)) {
    return (Invoke-DeepGeminiClaudeFallback -BridgeRoot $State.bridgeRoot -PromptText $State.promptText -FailMode 'empty_reply')
  }
  $parsed = Extract-Json -Text $reply
  $findings = @()
  if ($parsed) {
    if ($parsed -is [Array]) { $findings = @($parsed) }
    elseif ($parsed.findings) { $findings = @($parsed.findings) }
  }
  Write-Host "[deep-audit] claude: returned $($findings.Count) findings"
  return @{ skipped = $false; findings = $findings; tokens = $reply.Length; source = 'claude.exe' }
}

function Invoke-ClaudeFunctionalPass {
  # Legacy synchronous wrapper. Used for -Sequential.
  param([string]$ProjRoot, [string]$BridgeRoot, [string]$ClaudeExe, [int]$TimeoutSec)
  $state = Start-ClaudeFunctionalAsync -ProjRoot $ProjRoot -BridgeRoot $BridgeRoot -ClaudeExe $ClaudeExe -TimeoutSec $TimeoutSec
  return (Complete-ClaudeFunctionalAsync -State $state)
}

# --- Main ---

$bridgeRoot = Get-DeepAuditBridgeRoot
$projRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot } else { $bridgeRoot }
$cfg = Get-DeepAuditConfig
try {
  $commonLib = Join-Path $bridgeRoot 'lib\common.ps1'
  if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib 2>$null | Out-Null }
} catch {}

$codexResult = @{ skipped = $true; reason = 'no_codex_flag'; findings = @() }
$claudeResult = @{ skipped = $true; reason = 'no_claude_flag'; findings = @() }

Write-Host "[deep-audit] bridge=$bridgeRoot"
Write-Host "[deep-audit] project=$projRoot"
$mode = if ($Sequential) { 'sequential' } else { 'parallel' }
Write-Host "[deep-audit] mode=$mode"
Write-Host "[deep-audit] functional-agent=$FunctionalAgent"

# Resolve executables up front (cheap).
$codexExe = $null
$claudeExe = $null
if (-not $NoCodex) {
  $codexExe = Resolve-DeepCodexExe -Cfg $cfg
  if (-not $codexExe) { $codexResult = @{ skipped = $true; reason = 'codex_exe_not_found'; findings = @() } }
}
# 2026-05-28: claude.exe is only resolved when FunctionalAgent='auto'. In
# 'gemini-only' mode we go straight to gemini-3-flash and skip the claude.exe
# subprocess entirely (no encoding surprises, no token spend on broken bytes).
if (-not $NoClaude -and $FunctionalAgent -eq 'auto') {
  $claudeExe = Resolve-DeepClaudeExe -Cfg $cfg
  if (-not $claudeExe) { $claudeResult = @{ skipped = $true; reason = 'claude_exe_not_found'; findings = @() } }
}

# Functional-pass helper: in 'gemini-only' mode synthesise the same prompt the
# Claude pass would have built, then call gemini-3-flash directly.
function Invoke-GeminiOnlyFunctional {
  param([string]$ProjRoot, [string]$BridgeRoot)
  $featureScope = Get-DeepAuditFeatureScope -BridgeRoot $BridgeRoot
  $registryPath = [string]$featureScope.features_registry
  if (-not (Test-Path -LiteralPath $registryPath)) {
    Write-Host "[deep-audit] functional: feature registry missing for channel '$($featureScope.slug)', skip"
    return @{ skipped = $true; reason = 'no_registry'; findings = @() }
  }
  $registryRaw = Get-FileContentCapped -Path $registryPath -Cap 30000
  $statePath = [string]$featureScope.features_state
  $stateRaw = if (Test-Path -LiteralPath $statePath) { Get-FileContentCapped -Path $statePath -Cap 5000 } else { '{}' }
  $auditLogTail = ''
  $auditLogPath = Join-Path $BridgeRoot 'audit\audit.log'
  if (Test-Path -LiteralPath $auditLogPath) {
    try { $auditLogTail = (Get-Content -LiteralPath $auditLogPath -Tail 30 -Encoding UTF8 | Out-String).Trim() } catch {}
  }
  $gitLogWeek = ''
  try { $gitLogWeek = (& git -C $ProjRoot log --since='7 days ago' --pretty=format:'%h %s' 2>$null | Out-String).Trim() } catch {}

  $sb = New-Object 'System.Text.StringBuilder'
  [void]$sb.AppendLine('Ты архитектурный аудитор автономного моста Claude+Codex. Я дам тебе:')
  [void]$sb.AppendLine('1. Реестр фич текущего канала — что мы заявляем что есть в системе')
  [void]$sb.AppendLine('2. State фич (last_activated_at, last_health)')
  [void]$sb.AppendLine('3. Хвост audit.log за неделю')
  [void]$sb.AppendLine('4. Git log за неделю')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('ОЦЕНИ:')
  [void]$sb.AppendLine('- DORMANT: какие фичи в реестре status=active, но last_activated_at>30 дней назад (или null)?')
  [void]$sb.AppendLine('- DRIFT: где описание фичи в реестре расходится с её реальным поведением (видимо в git log)?')
  [void]$sb.AppendLine('- COVERAGE: какие фичи не имеют scenarios в registry, но это user-facing? (scenario_recommended)')
  [void]$sb.AppendLine('- UNDOCUMENTED: какие паттерны в git log не отражены в реестре? (новый функционал без записи)')
  [void]$sb.AppendLine('- TREND: видны ли в audit.log повторяющиеся проблемы (одна и та же категория > 3 раза)?')
  [void]$sb.AppendLine('')
  # 2026-05-28: same change as in Start-ClaudeFunctionalAsync — actionable
  # by default, [HUMAN-REVIEW] prefix only for irreversible operations.
  [void]$sb.AppendLine('Для каждого finding выдай actionable recommendation, которую мост может выполнить сам.')
  [void]$sb.AppendLine('ИСКЛЮЧЕНИЕ: если действие НЕОБРАТИМОЕ (удаление кода/фич/файлов, изменение биллинга, drop таблиц, force-push) — начни recommendation с префикса "[HUMAN-REVIEW]".')
  [void]$sb.AppendLine('Не предлагай удалять активно используемые фичи без явных доказательств что они мертвы.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('=== РЕЕСТР ФИЧ ===')
  [void]$sb.AppendLine($registryRaw)
  [void]$sb.AppendLine('=== STATE ===')
  [void]$sb.AppendLine($stateRaw)
  [void]$sb.AppendLine('=== AUDIT LOG (последние 30 строк) ===')
  [void]$sb.AppendLine($auditLogTail)
  [void]$sb.AppendLine('=== GIT LOG за неделю ===')
  [void]$sb.AppendLine($gitLogWeek)
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Верни СТРОГО JSON-массив:')
  [void]$sb.AppendLine('[{"feature_id":"id","category":"dormant|drift|coverage|undocumented|trend","severity":"critical|warning|info","observation":"что заметил","recommendation":"что предлагаешь"}]')
  [void]$sb.AppendLine('Если ничего не нашёл — верни [].')

  Write-Host "[deep-audit] functional: direct gemini-3-flash (skipping claude.exe)..."
  $commonLib = Join-Path $BridgeRoot 'lib\common.ps1'
  if (-not (Test-Path -LiteralPath $commonLib)) {
    return @{ skipped = $false; error = 'no_common_lib'; findings = @() }
  }
  try {
    . $commonLib 2>$null | Out-Null
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
      return @{ skipped = $false; error = 'no_invoke_llm'; findings = @() }
    }
    $reply = Invoke-LLM -Purpose 'audit-functional' -Model 'gemini-3-flash' -Prompt $sb.ToString() -TimeoutSec 120 -Temperature 0.2
    if ([string]::IsNullOrWhiteSpace($reply)) {
      return @{ skipped = $false; error = 'gemini_empty'; findings = @() }
    }
    $parsed = Extract-Json -Text $reply
    $findings = @()
    if ($parsed) {
      if ($parsed -is [Array]) { $findings = @($parsed) }
      elseif ($parsed.findings) { $findings = @($parsed.findings) }
    }
    Write-Host "[deep-audit] gemini-only: returned $($findings.Count) findings"
    return @{ skipped = $false; findings = $findings; tokens = $reply.Length; source = 'gemini-3-flash-direct' }
  } catch {
    Write-Host "[deep-audit] gemini-only failed: $($_.Exception.Message)"
    return @{ skipped = $false; error = ('gemini_exception: ' + $_.Exception.Message); findings = @() }
  }
}

if ($Sequential) {
  # Legacy back-to-back execution (codex first, then functional pass).
  if ($codexExe) {
    $codexResult = Invoke-CodexSecurityPass -ProjRoot $projRoot -BridgeRoot $bridgeRoot -CodexExe $codexExe -TimeoutSec $CodexTimeoutSec
  }
  if ($FunctionalAgent -eq 'gemini-only') {
    $claudeResult = Invoke-GeminiOnlyFunctional -ProjRoot $projRoot -BridgeRoot $bridgeRoot
  } elseif ($claudeExe) {
    $claudeResult = Invoke-ClaudeFunctionalPass -ProjRoot $projRoot -BridgeRoot $bridgeRoot -ClaudeExe $claudeExe -TimeoutSec $ClaudeTimeoutSec
  }
} else {
  # Parallel mode: codex.exe (security) runs in parallel with the functional pass.
  $codexState = $null
  $claudeState = $null
  if ($codexExe) {
    $codexState = Start-CodexSecurityAsync -ProjRoot $projRoot -BridgeRoot $bridgeRoot -CodexExe $codexExe -TimeoutSec $CodexTimeoutSec
  }
  if ($FunctionalAgent -eq 'auto' -and $claudeExe) {
    $claudeState = Start-ClaudeFunctionalAsync -ProjRoot $projRoot -BridgeRoot $bridgeRoot -ClaudeExe $claudeExe -TimeoutSec $ClaudeTimeoutSec
  }
  $tStart = Get-Date
  if ($codexState) { $codexResult = Complete-CodexSecurityAsync -State $codexState }
  if ($FunctionalAgent -eq 'gemini-only') {
    # Gemini-only path is synchronous HTTP — runs after Codex is launched so
    # they still overlap (Codex stays in the background while gemini answers).
    $claudeResult = Invoke-GeminiOnlyFunctional -ProjRoot $projRoot -BridgeRoot $bridgeRoot
  } elseif ($claudeState) {
    $claudeResult = Complete-ClaudeFunctionalAsync -State $claudeState
  }
  $elapsed = [Math]::Round(((Get-Date) - $tStart).TotalSeconds, 1)
  Write-Host "[deep-audit] parallel wait done in ${elapsed}s"
}

$output = [pscustomobject]@{
  ts = (Get-Date).ToString('o')
  bridge_root = $bridgeRoot
  project_root = $projRoot
  mode = $mode
  codex_security = $codexResult
  claude_functional = $claudeResult
}

# Emit JSON for caller (audit.ps1) to capture.
# Prefer file output (UTF-8 NoBOM, byte-exact) over stdout — see -OutputFile note.
$jsonOut = $output | ConvertTo-Json -Depth 8 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  try {
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputFile, $jsonOut, $u8NoBom)
    Write-Host "[deep-audit] result written to: $OutputFile (utf-8 nobom, $($jsonOut.Length) chars)"
  } catch {
    Write-Host "[deep-audit] -OutputFile write failed: $($_.Exception.Message), falling back to stdout"
    $jsonOut
  }
} else {
  $jsonOut
}
