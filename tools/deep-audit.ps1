[CmdletBinding()]
param(
  [string]$BridgePath = '',
  [int]$CodexTimeoutSec = 180,
  [int]$ClaudeTimeoutSec = 90,
  [switch]$NoCodex,
  [switch]$NoClaude
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

# tools/deep-audit.ps1 -- backlog item 90747e410b "deep-audit Codex+Claude".
#
# Phase 2 of the nightly audit pipeline. Runs AFTER static+deepseek finishes,
# uses the real Codex/Claude agents (not just deepseek/gemini) to get a
# qualitative second opinion. Specifically:
#
#   CODEX-SECURITY:  reads last-24h git diff, looks for REAL injection /
#                    path-traversal / auth-bypass / hardcoded-secrets that
#                    static grep misses. Returns structured JSON findings.
#   CLAUDE-FUNCTIONAL: reads features/registry.json + state.json + audit.log
#                    week, looks for drift (description vs code) and dormant
#                    features. Returns structured JSON observations.
#
# Outputs to stdout: { codex_security: [...], claude_functional: [...] }
# Designed to be invoked from tools/audit.ps1 OR manually for testing.
#
# SKIP conditions:
# - No .ps1/.html commits in last 24h -> skip codex (nothing changed)
# - features/registry.json missing -> skip claude (no context)
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

# --- Codex security pass ---

function Invoke-CodexSecurityPass {
  param([string]$Root, [string]$CodexExe, [int]$TimeoutSec)
  $changed = Get-Last24hChangedFiles -Root $Root
  $relevant = @($changed | Where-Object { -not (Test-IsTestFile -Path $_) })
  if ($relevant.Count -eq 0) {
    Write-Host "[deep-audit] codex: no .ps1/.html commits in last 24h, skip"
    return @{ skipped = $true; reason = 'no_changes_last_24h'; findings = @() }
  }
  Write-Host "[deep-audit] codex: examining $($relevant.Count) changed files..."
  $bodyBuilder = New-Object 'System.Text.StringBuilder'
  [void]$bodyBuilder.AppendLine('Ты security-аудитор. Это git-diff моста за 24 часа. Найди РЕАЛЬНЫЕ уязвимости — не "теоретические", а такие, что можно эксплуатировать.')
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
    $full = Join-Path $Root $f
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

  # Write prompt to temp file
  $tmpDir = Join-Path $Root 'audit\tmp'
  if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $inF = Join-Path $tmpDir ("deep-codex-in_$stamp.txt")
  $msgF = Join-Path $tmpDir ("deep-codex-out_$stamp.txt")
  $outF = Join-Path $tmpDir ("deep-codex-stdout_$stamp.txt")
  $errF = Join-Path $tmpDir ("deep-codex-stderr_$stamp.txt")
  [System.IO.File]::WriteAllText($inF, $bodyBuilder.ToString(), $Utf8NoBom)

  Write-Host "[deep-audit] codex: spawning codex.exe (timeout ${TimeoutSec}s)..."
  try {
    $reasonArg = 'model_reasoning_effort="medium"'
    $p = Start-Process -FilePath $CodexExe `
      -ArgumentList 'exec','--color','never','--skip-git-repo-check','-c',$reasonArg,'-s','read-only','-C',$Root,'-o',$msgF,'-' `
      -WorkingDirectory $Root -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $waited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $waited) {
      try { $p.Kill() } catch {}
      Write-Host "[deep-audit] codex: TIMEOUT after ${TimeoutSec}s"
      return @{ skipped = $false; error = 'codex_timeout'; findings = @() }
    }
  } catch {
    Write-Host "[deep-audit] codex: spawn failed: $($_.Exception.Message)"
    return @{ skipped = $false; error = 'codex_spawn_failed'; findings = @() }
  }

  $reply = if (Test-Path $msgF) { Get-Content $msgF -Raw -Encoding UTF8 } else { '' }
  Remove-Item $inF,$msgF,$outF,$errF -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($reply)) {
    return @{ skipped = $false; error = 'codex_empty_reply'; findings = @() }
  }
  $parsed = Extract-Json -Text $reply
  $findings = @()
  if ($parsed) {
    if ($parsed -is [Array]) { $findings = @($parsed) }
    elseif ($parsed.findings) { $findings = @($parsed.findings) }
  }
  Write-Host "[deep-audit] codex: returned $($findings.Count) findings"
  return @{ skipped = $false; findings = $findings; tokens = $reply.Length }
}

# --- Claude functional pass ---

function Invoke-ClaudeFunctionalPass {
  param([string]$Root, [string]$ClaudeExe, [int]$TimeoutSec)
  $registryPath = Join-Path $Root 'features\registry.json'
  if (-not (Test-Path -LiteralPath $registryPath)) {
    Write-Host "[deep-audit] claude: features/registry.json missing, skip"
    return @{ skipped = $true; reason = 'no_registry'; findings = @() }
  }
  $registryRaw = Get-FileContentCapped -Path $registryPath -Cap 30000
  $statePath = Join-Path $Root 'features\state.json'
  $stateRaw = if (Test-Path -LiteralPath $statePath) { Get-FileContentCapped -Path $statePath -Cap 5000 } else { '{}' }
  $auditLogTail = ''
  $auditLogPath = Join-Path $Root 'audit\audit.log'
  if (Test-Path -LiteralPath $auditLogPath) {
    try { $auditLogTail = (Get-Content -LiteralPath $auditLogPath -Tail 30 -Encoding UTF8 | Out-String).Trim() } catch {}
  }
  $gitLogWeek = ''
  try { $gitLogWeek = (& git -C $Root log --since='7 days ago' --pretty=format:'%h %s' 2>$null | Out-String).Trim() } catch {}

  $promptBuilder = New-Object 'System.Text.StringBuilder'
  [void]$promptBuilder.AppendLine('Ты архитектурный аудитор автономного моста Claude+Codex. Я дам тебе:')
  [void]$promptBuilder.AppendLine('1. Реестр фич (features/registry.json) — что мы заявляем что есть в системе')
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
  [void]$promptBuilder.AppendLine('НЕ ПРЕДЛАГАЙ удалять — только маркируй для human-review. Цель: дайджест на еженедельное ревью пользователем.')
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

  $tmpDir = Join-Path $Root 'audit\tmp'
  if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $inF = Join-Path $tmpDir ("deep-claude-in_$stamp.txt")
  $outF = Join-Path $tmpDir ("deep-claude-out_$stamp.txt")
  $errF = Join-Path $tmpDir ("deep-claude-err_$stamp.txt")
  [System.IO.File]::WriteAllText($inF, $promptBuilder.ToString(), $Utf8NoBom)

  Write-Host "[deep-audit] claude: spawning claude.exe (timeout ${TimeoutSec}s)..."
  $allowedTools = @('Read','Grep','Glob')
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$Root,'--allowedTools') + $allowedTools + @('--model','sonnet')
  try {
    $p = Start-Process -FilePath $ClaudeExe -ArgumentList $claudeArgs `
      -WorkingDirectory $Root -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $waited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $waited) {
      try { $p.Kill() } catch {}
      Write-Host "[deep-audit] claude: TIMEOUT after ${TimeoutSec}s"
      return @{ skipped = $false; error = 'claude_timeout'; findings = @() }
    }
  } catch {
    Write-Host "[deep-audit] claude: spawn failed: $($_.Exception.Message)"
    return @{ skipped = $false; error = 'claude_spawn_failed'; findings = @() }
  }

  $reply = if (Test-Path $outF) { Get-Content $outF -Raw -Encoding UTF8 } else { '' }
  Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue
  if ([string]::IsNullOrWhiteSpace($reply)) {
    # 2026-05-28: claude.exe -p sometimes hangs/exits without output for large
    # stdin-piped prompts (67K context). Rather than fail this whole phase,
    # fall back to Invoke-LLM gemini-2.5-pro — same prompt, different agent.
    # Spirit of "two heads" preserved (codex security + a separate-model
    # functional review) even if claude.exe isn't cooperating.
    Write-Host "[deep-audit] claude: empty reply -> falling back to Invoke-LLM gemini-2.5-pro"
    $fbBuilder = Get-Item -LiteralPath (Join-Path $Root 'lib\common.ps1') -ErrorAction SilentlyContinue
    if ($fbBuilder) {
      try {
        . (Join-Path $Root 'lib\common.ps1') 2>$null | Out-Null
        if (Get-Command Invoke-LLM -ErrorAction SilentlyContinue) {
          $fbPrompt = $promptBuilder.ToString()
          $fbReply = Invoke-LLM -Purpose 'audit-functional' -Model 'gemini-2.5-pro' -Prompt $fbPrompt -TimeoutSec 120 -Temperature 0.2
          if (-not [string]::IsNullOrWhiteSpace($fbReply)) {
            $fbParsed = Extract-Json -Text $fbReply
            $fbFindings = @()
            if ($fbParsed) {
              if ($fbParsed -is [Array]) { $fbFindings = @($fbParsed) }
              elseif ($fbParsed.findings) { $fbFindings = @($fbParsed.findings) }
            }
            Write-Host "[deep-audit] claude->gemini-pro fallback: returned $($fbFindings.Count) findings"
            return @{ skipped = $false; findings = $fbFindings; tokens = $fbReply.Length; source = 'gemini-2.5-pro-fallback' }
          }
        }
      } catch {
        Write-Host "[deep-audit] claude fallback failed: $($_.Exception.Message)"
      }
    }
    return @{ skipped = $false; error = 'claude_empty_reply_and_fallback_failed'; findings = @() }
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

# --- Main ---

$root = Get-DeepAuditBridgeRoot
$cfg = Get-DeepAuditConfig

$codexResult = @{ skipped = $true; reason = 'no_codex_flag'; findings = @() }
$claudeResult = @{ skipped = $true; reason = 'no_claude_flag'; findings = @() }

if (-not $NoCodex) {
  $codexExe = Resolve-DeepCodexExe -Cfg $cfg
  if (-not $codexExe) {
    $codexResult = @{ skipped = $true; reason = 'codex_exe_not_found'; findings = @() }
  } else {
    $codexResult = Invoke-CodexSecurityPass -Root $root -CodexExe $codexExe -TimeoutSec $CodexTimeoutSec
  }
}

if (-not $NoClaude) {
  $claudeExe = Resolve-DeepClaudeExe -Cfg $cfg
  if (-not $claudeExe) {
    $claudeResult = @{ skipped = $true; reason = 'claude_exe_not_found'; findings = @() }
  } else {
    $claudeResult = Invoke-ClaudeFunctionalPass -Root $root -ClaudeExe $claudeExe -TimeoutSec $ClaudeTimeoutSec
  }
}

$output = [pscustomobject]@{
  ts = (Get-Date).ToString('o')
  codex_security = $codexResult
  claude_functional = $claudeResult
}

# Emit JSON for caller (audit.ps1) to capture
$output | ConvertTo-Json -Depth 8 -Compress
