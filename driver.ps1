# driver.ps1 -- INTERACTIVE bridge: idles, and treats each [USER] chat message as a
# task. Planner (Claude) plans/reviews, Coder (Codex) executes with FULL PC access.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\metrics.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
$ErrorActionPreference = 'Continue'

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
$fullContext    = if ($cfg.fullContextCount) { [int]$cfg.fullContextCount } else { 20 }
$summarizeBatch = if ($cfg.summarizeBatch)   { [int]$cfg.summarizeBatch }   else { 15 }
$triageModel       = if ($cfg.triageModel)       { [string]$cfg.triageModel }       else { 'sonnet' }
$deepModel         = if ($cfg.deepModel)         { [string]$cfg.deepModel }         else { 'opus' }
$discussMinTurns   = if ($cfg.discussMinTurns)   { [int]$cfg.discussMinTurns }      else { 3 }
$discussMaxTurns   = if ($cfg.discussMaxTurns)   { [int]$cfg.discussMaxTurns }      else { 8 }
$researchMaxTurns  = if ($cfg.researchMaxTurns)  { [int]$cfg.researchMaxTurns }     else { 2 }
$studyMaxTurns     = if ($cfg.studyMaxTurns)     { [int]$cfg.studyMaxTurns }        else { 5 }

function Get-PlannerModel {
  param([string]$TaskText, [string]$Mode)

  if ($Mode -eq 'discuss' -or $Mode -eq 'study') { return $deepModel }

  $text = if ($null -eq $TaskText) { '' } else { [string]$TaskText }

  if ($text -imatch '(^|[^\p{L}\p{N}_])(opus|опус)([^\p{L}\p{N}_]|$)') { return $deepModel }

  $wordCount = ($text -split '\s+' | Where-Object { $_ }).Count
  if ($wordCount -gt 300) { return $deepModel }

  $numberedSteps = ([regex]::Matches($text, '(?m)^\s*\d+[\.\)]')).Count
  if ($numberedSteps -ge 3) { return $deepModel }

  $stageWords = ([regex]::Matches($text, '(?i)(фаз[аыеу]?|этап\w*|шаг\w*)')).Count
  if ($stageWords -ge 2) { return $deepModel }

  $complexKeywords = @('архитектур','рефактор','перераб','redesign','мигр','интеграц','масштаб','overhaul','сложн','многошаг')
  foreach ($kw in $complexKeywords) {
    if ($text -imatch $kw) { return $deepModel }
  }

  return $triageModel
}
$null = Initialize-Bridge

# ---------- helpers ----------
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

function Start-LibrarianIfDue {
  # Run the memory consolidator detached when idle, gated by HYBRID schedule:
  #   - HARD floor: at least 30 min since the last run (so we don't spam Gemini).
  #   - SOFT ceiling: at least 6h since the last run -> run unconditionally.
  #   - DELTA trigger: >= 5 new memories since the last run -> run early (after the floor).
  # Old "every 24h" was useless during active development (map could be 24h stale while
  # memory grew 50+ entries). User noticed: "карта памяти сутки не обновлялась". 2026-05-26.
  try { $mc = Get-MemoryConfig } catch { return }
  if (-not $mc.enabled) { return }
  $marker = Join-Path $bridgeRoot 'memory\librarian.last'
  $countMarker = Join-Path $bridgeRoot 'memory\librarian.count.last'
  $lastTs = $null
  if (Test-Path $marker) { try { $lastTs = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  if ($lastTs) {
    $age = (Get-Date) - $lastTs
    if ($age -lt [TimeSpan]::FromMinutes(30)) { return }     # hard floor
    if ($age -lt [TimeSpan]::FromHours(6)) {
      # within the soft ceiling: only run if enough new memories accumulated
      $lastCount = -1
      if (Test-Path $countMarker) { try { $lastCount = [int]((Get-Content $countMarker -Raw -Encoding UTF8).Trim()) } catch {} }
      $curCount = 0
      try { $curCount = @(Get-AllMemories).Count } catch {}
      if ($lastCount -ge 0 -and ($curCount - $lastCount) -lt 5) { return }
    }
  }
  $lib = Join-Path $bridgeRoot 'librarian.ps1'
  if (-not (Test-Path $lib)) { return }
  # Touch the marker NOW so we don't relaunch every idle tick while it runs.
  try {
    $md = Join-Path $bridgeRoot 'memory'
    if (-not (Test-Path $md)) { New-Item -ItemType Directory -Path $md -Force | Out-Null }
    [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$lib -WindowStyle Hidden | Out-Null
    Add-Message -From system -Text "🧠 Запущен библиотекарь памяти (консолидация в фоне)." -Kind event | Out-Null
  } catch {}
}

function Start-ReflectIfDue {
  # Launch idle self-reflection at most once per autonomy.reflectEveryHours, detached.
  $auto = $null
  try { $cfgA = Get-BridgeConfig; if ($cfgA.PSObject.Properties.Name -contains 'autonomy') { $auto = $cfgA.autonomy } } catch { return }
  $enabled = if ($auto -and $null -ne $auto.enabled) { [bool]$auto.enabled } else { $true }
  if (-not $enabled) { return }
  $everyH = if ($auto -and $auto.reflectEveryHours) { [double]$auto.reflectEveryHours } else { 6 }
  $marker = Join-Path $bridgeRoot 'reflect.last'
  if (Test-Path $marker) {
    try {
      $last = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($everyH)) { return }
    } catch {}
  }
  $rf = Join-Path $bridgeRoot 'reflect.ps1'
  if (-not (Test-Path $rf)) { return }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null } catch {}
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
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null
    Add-Message -From system -Text "📡 Тех-радар запущен в фоне (еженедельный обход Хабра)." -Kind event | Out-Null
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
  $codeSect = ''
  try { $codeSect = Get-CodeRecall -Query $TaskText } catch { $codeSect = '' }
  $decAppend = if ($decSect) { "`n`n$decSect" } else { '' }
  $evAppend = if ($evSect) { "`n`n$evSect" } else { '' }
  $memAppend = if ($memSect) { "`n`n$memSect" } else { '' }
  $skillAppend = if ($skillSect) { "`n`n$skillSect" } else { '' }
  $codeAppend = if ($codeSect) { "`n`n$codeSect" } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    return ("СВОДКА ПРЕДЫДУЩЕГО ДИАЛОГА (сжато, для контекста):`n" + $summary.Trim() + "`n`n=== ПОСЛЕДНИЕ СООБЩЕНИЯ (полностью) ===`n" + $body + $memAppend + $skillAppend + $codeAppend + $decAppend + $evAppend)
  }
  return $body + $memAppend + $skillAppend + $codeAppend + $decAppend + $evAppend
}

function Build-Prompt {
  param([string]$Role, [string]$Task, [string]$Mode = 'normal')
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
  try {
    $planPromptText = Format-PlanForPrompt
    if (-not [string]::IsNullOrWhiteSpace($planPromptText)) {
      $planPromptBlock = "`n`nПЛАН-ДОСКА (веди работу по ней):`n$planPromptText"
    }
  } catch {}
  $shared = @"
Ты часть автономной пары ИИ-ассистентов с ПОЛНЫМ доступом к компьютеру пользователя (Windows).
Рабочий корень: $workRoot

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
- ПАРАЛЛЕЛЬ (только планировщик): если задачу можно разбить на 2+ НЕЗАВИСИМЫЕ части (напр. изучить разных субагентов, разобрать разные модули/файлы, аудит UI отдельно) — оставь отдельной строкой `[[PARALLEL: <путь_к_репозиторию> || под-задача 1 ;; под-задача 2 ;; под-задача 3]]`. Каждая уйдёт отдельному Codex-воркеру в ИЗОЛИРОВАННОЙ копии репо ПАРАЛЛЕЛЬНО, результаты вольются обратно (конфликты придут тебе на разрешение). Только для по-настоящему независимых частей (не трогают одни и те же файлы); путь репозитория обязателен (НЕ сам мост). После завершения проверь результат запуском.
- САМОУЛУЧШЕНИЕ РАЗРЕШЕНО: тебе МОЖНО улучшать сам мост (файлы в `C:\Users\rafie\OneDrive\Documents\bridge\`: `web\index.html`, `server.ps1`, `driver.ps1`, `lib\common.ps1` и т.п.). СТРОГИЕ ПРАВИЛА БЕЗОПАСНОСТИ (нарушение убьёт мост):
  1) Каждый `.ps1` сохраняй СТРОГО в UTF-8 С BOM. Без BOM PowerShell 5.1 не распарсит русский/эмодзи -> мост умрёт. В PowerShell записать с BOM: `[System.IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($true)))`.
  2) После записи любого `.ps1` ПРОВЕРЬ синтаксис: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('<путь>',[ref]$t,[ref]$e)|Out-Null;if($e.Count){'ERR'}else{'OK'}"`. Применяй, ТОЛЬКО если 'OK'.
  3) Применить правки .ps1-файлов движка: создай файл `bridge\control\restart.flag` -- супервизор перезапустит мост (без UAC). ⛔ СТРОГИЙ ЗАПРЕТ: restart.flag создавать ТОЛЬКО если изменён хотя бы один `.ps1`-файл. Перед созданием флага ОБЯЗАТЕЛЬНО проверь: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" diff --name-only HEAD` -- если в выводе НЕТ ни одного `.ps1`, флаг НЕ создавай (мост перезапустится зря).
  4) После КАЖДОЙ проверенной рабочей правки: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" add -A; git -C "..." commit -m "что сделал"`. Это фиксирует прогресс (watchdog откатит на последний коммит при поломке).
  5) `web\index.html` (UI) можно править свободно -- применяется без перезапуска (просто обнови вкладку). ⛔ НЕ создавай restart.flag ради HTML-правок -- это лишние перезапуски и шум в истории.
  6) НЕ ТРОГАЙ: `watchdog.ps1`, `supervisor.ps1` без крайней нужды, папку `.git`, задачи Планировщика; НЕ убивай процессы моста/watchdog; НЕ удаляй файлы движка.
  7) `secrets.json` содержит API-ключи (Gemini и др.). НИКОГДА не выводи его содержимое в чат и не коммить — он в .gitignore. Память: `lib\memory.ps1` (embeddings+поиск), `librarian.ps1` (ночная консолидация), хранилище `memory\` (gitignored).

ДИАЛОГ:
$transcript$planPromptBlock
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

🔁 ПРАВИЛО CODER-DELEGATION (КРИТИЧНО): если задача потребовала изменения файлов в репо (`.ps1`/`.html`/`.css`/`.js`/`config.json`/новые файлы) — это работа Codex, НЕ твоя. Сам внести правку ОК ТОЛЬКО для тривиального (1-2 строки, явный фикс опечатки/одного флага). Для остального обязателен STATUS: CONTINUE с конкретной инструкцией Codex'у (что менять, где, критерий приёмки). Это потому, что: (а) у Codex code-fine-tuning, он лучше пишет; (б) критик ревьюит ТОЛЬКО Codex-diff, твой собственный diff проходит без независимой проверки — слепое пятно; (в) Opus-турны дорогие, их надо тратить на планирование, а не на редактирование. Гейт в драйвере: если ты выдал STATUS: DONE с file-правками БЕЗ привлечения Codex — DONE отклоняется и тебя заворачивают на CONTINUE. Это уже случалось (probe 2: Opus сам поправил web/index.html, обошёл критика).
ПРАВИЛО ВЕРИФИКАЦИИ: перед STATUS: DONE -- если Codex выполнял действия (файлы/команды), ты ОБЯЗАН явно показать результат проверки и добавить отдельной строкой маркер [[VERIFIED: что проверено | результат]]. Без [[VERIFIED:]] DONE отклоняется.
⚠ ПОВЕДЕНЧЕСКАЯ ПРОВЕРКА (КРИТИЧНО): если задача создала ИСПОЛНЯЕМОЕ (скрипт, функцию, фичу, которая производит вывод) — diff или содержимое файла НЕ считается проверкой. ОБЯЗАТЕЛЬНО ЗАПУСТИ это на реальном/тестовом входе и покажи ФАКТИЧЕСКИЙ вывод, и убедись, что вывод осмысленный и отвечает критериям задачи (не «код выглядит правильно», а «запустил — работает и даёт верный результат»). Для исполняемых задач DONE без реального запуска запрещён. Урок: тех-радар в diff «выглядел нормально», но при запуске выдавал мусор (заголовки = XmlElement) — потому что его никто не ЗАПУСТИЛ и не посмотрел вывод.
🌐 ПРОВЕРКА API/UI (КРИТИЧНО):
- API-эндпоинт: [[VERIFIED:]] ОБЯЗАН включать РЕАЛЬНЫЙ вызов эндпоинта по HTTP (Invoke-WebRequest на http://localhost:8787/api/... с авторизацией из auth.json) с кодом 200 И быстрым непустым ответом. Запуск только внутренней функции в изоляции НЕ считается. Урок: /api/radar OOM-ронял сервер именно на HTTP-вызове, в изоляции функция работала за 100мс.
- UI/HTML/CSS/JS: [[VERIFIED:]] ОБЯЗАН включать прогон `tools\ui_audit.ps1` с проверкой структурных инвариантов (например `-RequireId planToggle -RequireOutside btnsSecondary` — кнопка должна быть НЕ внутри `⋮`-меню) И с проверкой при мобильном вьюпорте (`-Width 390 -Height 844`). "Файл изменён" / "diff выглядит правильно" / "страница грузится" НЕ считается. Урок 2026-05-26: коммит «add plan board to mobile» прошёл, потому что кнопка БЫЛА в DOM — но внутри `btns-secondary` (скрыто за `⋮`); пользователь её не видел. ui_audit.ps1 поймал бы это инвариантом `-RequireOutside btnsSecondary`.

ПЛАН-ДОСКА: для КРУПНОЙ задачи (несколько эпиков/много шагов) в первом ходе сформируй доску блоком [[PLAN]] ... [[/PLAN]]: строки EPIC/TASK/STEP, deps и критерии готовности. Затем веди работу пошагово; при готовности шага ставь отдельной строкой [[STEP-DONE: <id> | краткий результат]]. Для мелкой задачи план не нужен.

ВАЖНО: не путай простое со сложным. Если сомневаешься, либо действие рискованное/необратимое/масштабное -- НЕ делай сам: используй CONTINUE (Codex) или CHAT (спроси пользователя). Пиши по-русски.
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
    $suffix = @"

ТВОЙ ХОД как КОДЕР (Codex). Выполни последнюю инструкцию ПЛАНИРОВЩИКА и любое сообщение [USER].
Делай реальные действия (файлы/команды) в рамках задачи. Кратко отчитайся по-русски, что сделал и каков результат.
ПЛАН ЗАДАЧИ: для сложных задач (3+ шага) в первом ответе пиши нумерованный чеклист шагов. Обновляй при каждом ходе: ✅ готово, 🔄 текущий, ⬜ впереди.
КАЧЕСТВО, А НЕ «ЛИШЬ БЫ РАБОТАЛО» (это важно — на этом уже лажали):
- ПРОВЕРЯЙ СВОЙ ВЫВОД ЗАПУСКОМ: написал скрипт/функцию — САМ запусти и убедись, что вывод осмысленный и верный на РЕАЛЬНОМ примере, а не «код вроде правильный». Сообщать о готовности исполняемого без фактического запуска — нельзя.
- Думай о КОРРЕКТНОСТИ, а не о «счастливом пути»: краевые случаи, пустые/битые данные, кодировки. Сомневаешься в API/парсинге (напр. как достать текст из XML/JSON) — ПРОВЕРЬ на примере, не угадывай.
- Без халтуры: не глуши ошибки пустым catch, не оставляй заглушек/TODO/хардкода вместо логики, не «выглядит правильно» — а «запустил, работает».
- Лучше сделать меньше, но правильно и проверенно, чем «вроде готово» со скрытым багом (его поймает критик/верификация — и задача вернётся к тебе же).
SAFETY GATE: перед удалением файлов/папок ВНЕ директории bridge, массовой перезаписью чужих данных, убийством процессов пользователя, внешними сетевыми запросами — напиши строку [[SAFETY: <что именно>]] и НЕ ВЫПОЛНЯЙ. Драйвер остановится и спросит пользователя.
⛔ НАПОМИНАНИЕ: restart.flag -- ТОЛЬКО если изменён `.ps1`-файл. Проверь перед созданием: `git diff --name-only HEAD`. Для `web\index.html` флаг НЕ нужен.
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
  param($Proc, [int]$TimeoutMs)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    if ($Proc.WaitForExit(5000)) { return $true }
    try { Update-State { param($s) $s.heartbeat=(Get-Date).ToString('o') } | Out-Null } catch {}
  }
  return $Proc.WaitForExit(0)
}

function Invoke-Planner {
  param([string]$Prompt, [string]$Model = '', [string]$Mode = 'normal')
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "claude_in_$g.txt"; $outF=Join-Path $env:TEMP "claude_out_$g.txt"; $errF=Join-Path $env:TEMP "claude_err_$g.txt"
  # Opus -> maximum thinking budget ('ultrathink' = top tier in Claude Code). They write code.
  $effPrompt = if ($Model -match 'opus') { $Prompt + "`n`nultrathink" } else { $Prompt }
  [System.IO.File]::WriteAllText($inF, $effPrompt, $Utf8NoBom)
  # Narrow --add-dir to the bridge folder (faster startup); Bash already gives full read access.
  $allowedTools = if ($Mode -eq 'research') { @('Read','Grep','Glob','WebSearch','WebFetch') }
                  elseif ($Mode -eq 'study') { @('Read','Grep','Glob','WebSearch','WebFetch','Bash') }
                  else { @('Read','Grep','Glob','Bash') }
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$bridgeRoot,'--allowedTools') + $allowedTools
  if ($Model) { $claudeArgs += @('--model', $Model) }
  $reply = ''
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $p = Start-Process -FilePath $claudeExe -ArgumentList $claudeArgs `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $null = $p.Handle; Set-AgentPid $p.Id; Register-AgentPid $p.Id
    # Planner cap was 240s — too tight for Opus on ultrathink on multi-part tasks (probe 2
    # timed out here on a complex audit). Raised to 600s to match Codex; Sonnet finishes long
    # before this cap so no regression for simple tasks.
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 600000)) {
      Stop-AgentTree $p.Id
      return [pscustomobject]@{ text=''; status='timeout'; duration=[int]$sw.Elapsed.TotalSeconds; errorType='planner_timeout' }
    }
    if (Test-Path $outF) { $reply = Get-Content $outF -Raw -Encoding UTF8 }
  } finally { if ($p -and $p.Id) { Unregister-AgentPid $p.Id }; Clear-AgentPid; Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue }
  if ($null -eq $reply) { $reply = '' }
  return [pscustomobject]@{ text=$reply.Trim(); status='ok'; duration=[int]$sw.Elapsed.TotalSeconds; errorType=$null }
}

function Invoke-Coder {
  param([string]$Prompt, [string]$Mode = 'code')
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "codex_in_$g.txt"; $msgF=Join-Path $env:TEMP "codex_msg_$g.txt"; $outF=Join-Path $env:TEMP "codex_out_$g.txt"; $errF=Join-Path $env:TEMP "codex_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $Prompt, $Utf8NoBom)
  $sbMode = if ($Mode -eq 'discuss') { 'read-only' } else { 'danger-full-access' }
  $reply = ''
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $p = Start-Process -FilePath $codexExe `
      -ArgumentList 'exec','--color','never','--skip-git-repo-check','-c','model_reasoning_effort="xhigh"','-s',$sbMode,'-C',$workRoot,'-o',$msgF,'-' `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $null = $p.Handle; Set-AgentPid $p.Id; Register-AgentPid $p.Id
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 600000)) {
      Stop-AgentTree $p.Id
      return [pscustomobject]@{ text=''; status='timeout'; duration=[int]$sw.Elapsed.TotalSeconds; errorType='coder_timeout' }
    }
    if (Test-Path $msgF) { $reply = Get-Content $msgF -Raw -Encoding UTF8 }
  } finally { if ($p -and $p.Id) { Unregister-AgentPid $p.Id }; Clear-AgentPid; Remove-Item $inF,$msgF,$outF,$errF -ErrorAction SilentlyContinue }
  if ($null -eq $reply) { $reply = '' }
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
    $p = Start-Process -FilePath $claudeExe -ArgumentList '-p','--model',$triageModel `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $null = $p.Handle; Register-AgentPid $p.Id
    if (-not (Wait-AgentProcess -Proc $p -TimeoutMs 120000)) { Stop-AgentTree $p.Id; return $null }
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
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'turns.jsonl') -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
    try {
      $null = Add-UsageRecord -Kind prepaid -Provider $Speaker -Model $Model -Purpose $Mode -Sec $sec -Status $turnStatus
    } catch {}
  } catch {}
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
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'evidence.jsonl') -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
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
  Update-State {
    param($s)
    $s.status='working'; $s.stop=$false; $s.abort=$false
    $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
    $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
  } | Out-Null
  Add-Message -From system -Text "♻ Мост перезапущен — возобновляю прерванную задачу (прогресс и история сохранены)." -Kind event | Out-Null
} else {
  Update-State {
    param($s)
    $s.status='idle'; $s.stop=$false; $s.abort=$false
    $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
    $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
    $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
  } | Out-Null
  Add-Message -From system -Text "Интерактивный режим запущен. Полный доступ к ПК. Жду задачу от тебя в чате…" -Kind event | Out-Null
}

# ---------- main loop ----------
while ($true) {
 try {
  $state = Read-State

  if ($state.stop) { Add-Message -From system -Text "Мост остановлен." -Kind event | Out-Null; Update-State { param($s) $s.status='stopped'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null } | Out-Null; break }

  if ($state.abort) {
    Add-Message -From system -Text "🛑 Стоп-кран: текущая задача прервана. Жду новую." -Kind event | Out-Null
    try { foreach ($j in @($state.active_jobs)) { Stop-BridgeJob $j } } catch {}
    try { Invoke-PostMortem -FailureType 'rollback' -Task ([string]$state.current_task) -Context 'manual abort' } catch {}
    Update-State { param($s) $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
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
        $s.doctor_attempts  = [int]$s.doctor_attempts + 1
        $s.status           = 'working'
        $s.heartbeat        = (Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommitD -Force
      }.GetNewClosure()) | Out-Null
      try { Add-Message -From system -Text "🩺 Доктор приступает к диагностике и фиксу." -Kind event | Out-Null } catch {}
      $state = Read-State
    } catch {
      try { Add-Message -From system -Text ("🩺 Доктор: ошибка при подготовке задачи: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      Abort-Doctor -Reason "setup error"
      Start-Sleep -Seconds $loopDelay; continue
    }
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
        $ageH = 0; try { $ageH = ((Get-Date).ToUniversalTime() - ([datetime]$job.started).ToUniversalTime()).TotalHours } catch {}
        if ($ageH -ge $jobMaxH) { try { Stop-BridgeJob $job } catch {}; $finished = $true; $reason = 'timeout' }
      }
      if ($finished) {
        $res = Get-JobResult $job
        if ($reason -eq 'timeout') {
          Add-Message -From system -Text ("⏱ Фоновая задача [$($job.id)] превысила лимит ($jobMaxH ч) и остановлена.`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$($res.tail)") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Фоновая задача [$($job.id)] завершена (код выхода: $($res.exitCode)).`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$($res.tail)") -Kind event | Out-Null
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
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      $studyDetect = Detect-StudyMode -TaskText $taskMsg
      $baseCommit = try { (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch { '' }
      Update-State ({ param($s)
        $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'
        $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
        if ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
        $s.task_start_seq=$maxUser; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$null; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
        $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
      }.GetNewClosure()) | Out-Null
      try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
      Add-Message -From system -Text "📥 Новая задача принята в работу." -Kind event | Out-Null
      if ($studyDetect) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: user" -Kind event | Out-Null }
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
      $_lastSnap = try { Get-LastSnapshot } catch { $null }
      $_snapAgeH = if ($_lastSnap) { ([DateTime]::UtcNow - [DateTime]$_lastSnap.ts).TotalHours } else { 999 }
      if ($_snapAgeH -ge 3) {
        try { Write-MetricsSnapshot } catch {}
        try { Invoke-MetricsReflection } catch {}
      }

      # Autonomy: after enough idle quiet, take the next runnable backlog idea and run it
      # as a self-task. With requireApproval=false, 'new' ideas run too (approved first).
      $claimedIdea = $null
      if (Test-AutonomyReady) { try { $claimedIdea = Get-NextRunnableIdea -IncludeNew (-not (Get-AutonomyRequireApproval)) } catch {} }
      if ($claimedIdea) {
        $bid = [string]$claimedIdea.id
        $btext = '[Автозадача из бэклога] ' + [string]$claimedIdea.text
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $studyDetect = Detect-StudyMode -TaskText $btext -IsAutonomous
        $baseCommit = try { (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch { '' }
        Update-State ({ param($s)
          $s.current_task=$btext; $s.task_turn=0; $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
          if ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
          $s.task_start_seq=[int]$s.lastSeq; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$bid; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o')
          $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
          $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
          if ([string]$s.autonomous_day -eq $today) { $s.autonomous_count=[int]$s.autonomous_count+1 } else { $s.autonomous_day=$today; $s.autonomous_count=1 }
        }.GetNewClosure()) | Out-Null
        try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
        try { Set-Idea -Id $bid -Status 'running' -IncrementAttempts $true | Out-Null } catch {}
        Add-Message -From system -Text "🤖 Беру задачу из бэклога в работу (автономно): $([string]$claimedIdea.text)" -Kind event | Out-Null
        if ($studyDetect) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: backlog" -Kind event | Out-Null }
        $state = Read-State
      } else {
        Update-State { param($s) $s.status='idle'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        try { Start-LibrarianIfDue } catch {}
        try { Start-ReflectIfDue } catch {}
        try { Start-TechRadarIfDue } catch {}
        Start-Sleep -Seconds $idlePoll; continue
      }
    }
  } else {
    if ($maxUser -gt [int]$state.last_user_seq) { Update-State ({ param($s) $s.last_user_seq=$maxUser }.GetNewClosure()) | Out-Null }
  }

  $task = [string]$state.current_task
  $tt   = [int]$state.task_turn
  $mode = if ($state.task_mode) { [string]$state.task_mode } else { 'normal' }
  $forcePlanner = [bool]$state.force_planner
  $speaker = if ($forcePlanner) { 'claude' }
             elseif ($mode -eq 'research') { 'claude' }
             elseif ($mode -eq 'study') { Get-StudySpeaker -TaskTurn $tt -StudySubtype ([string]$state.study_subtype) -StudyPhase ([string]$state.study_phase) }
             elseif ($tt -eq 0) { 'claude' }
             else { Next-Speaker }
  if ($forcePlanner) { Update-State { param($s) $s.force_planner=$false } | Out-Null }
  $plannerEscalate = $false
  try { $plannerEscalate = ([int](Read-State).timeout_retry_count -ge 1) } catch {}
  $plannerModel = Select-PlannerModel -TaskText $task -Mode $mode -Escalate $plannerEscalate
  $activeModel  = if ($speaker -eq 'claude') { $plannerModel } else { 'codex' }
  $statusText   = Get-AgentStatusText -Speaker $speaker -Mode $mode -TaskText $task
  Update-State ({ param($s) $s.active_agent=$speaker; $s.active_model=$activeModel; $s.status_text=$statusText; $s.status='working'; $s.claimed_at=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'summary' -TaskText $task)
  Update-ContextSummary   # compress old history if it grew beyond the hot window
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'prompt' -TaskText $task)
  $prompt = Build-Prompt -Role $speaker -Task $task -Mode $mode
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'invoke' -TaskText $task)
  $turnStart = [DateTime]::UtcNow
  try {
    if ($speaker -eq 'claude') { $turnResult = Invoke-Planner -Prompt $prompt -Model $plannerModel -Mode $mode }
    else {
      $turnResult = Invoke-Coder -Prompt $prompt -Mode $mode
      # Track that Codex actually ran for this task: used by the coder-bypass gate below
      # so the planner can't ship file changes via STATUS:DONE without Codex+critic review.
      if ($turnResult.status -eq 'ok') { Update-State { param($s) $s.coder_fired = $true } | Out-Null }
    }
  } catch {
    Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $_.Exception.Message -Status 'error'
    throw
  }
  $reply = [string]$turnResult.text
  Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $reply -Status ([string]$turnResult.status)

  if ((Read-State).abort) { continue }   # killed mid-turn -> handled at top

  # Handle agent timeouts as retryable structured errors.
  if ($turnResult.status -eq 'timeout') {
    $who = if ($turnResult.errorType -eq 'coder_timeout') { 'Codex' } else { 'Claude' }
    $dur = [int]$turnResult.duration
    $trc = [int](Read-State).timeout_retry_count
    if ($trc -lt 1) {
      Add-Message -From system -Text "⏱ Таймаут $who (${dur}с, $($turnResult.errorType)) — повторяю попытку..." -Kind event | Out-Null
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
        Add-Message -From system -Text "⏱ Таймаут $who повторился (${dur}с). Передаю Доктору на саморемонт." -Kind event | Out-Null
        try { Activate-Doctor -Reason ([string]$turnResult.errorType) -Detail "${dur}с после retry" | Out-Null } catch {}
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
      Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      continue
    }
  }

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'post' -TaskText $task)
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = "(нет ответа от $speaker)" }
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
    if ($meta) { $attachmentMetas += $meta }
    else { $failedAttachmentPaths += $sourcePath }
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
  # [[REMEMBER: fact]] -> agent deliberately pushes a durable memory (no gate -- the agent chose).
  $rememberPattern = '(?m)^\s*\[\[REMEMBER:\s*(.+?)\s*\]\]\s*$'
  $rememberedFacts = @()
  foreach ($m in [regex]::Matches($reply, $rememberPattern)) {
    $fact = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($fact)) { continue }
    try {
      $rid = Add-Memory -Text $fact -Tags @('explicit', $speaker) -Source ('explicit:' + $speaker) -Importance 0.75
      if ($rid) { $rememberedFacts += $fact }
    } catch {}
  }
  # [[IDEA: ...]] -> agent raises a self-improvement idea into the backlog (status 'new').
  $ideaPattern = '(?m)^\s*\[\[IDEA:\s*(.+?)\s*\]\]\s*$'
  $proposedIdeas = @()
  foreach ($m in [regex]::Matches($reply, $ideaPattern)) {
    $idea = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($idea)) { continue }
    try { $iid = Add-Idea -Text $idea -From $speaker -Tags @($speaker) -Status 'new'; if ($iid) { $proposedIdeas += $idea } } catch {}
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

  # [[STEP-DONE: id | результат]] и [[STEP: id | status | результат]] -> обновить шаги плана.
  $stepDonePattern = '(?m)^\s*\[\[STEP-DONE:\s*([^|\]]+?)(?:\s*\|\s*(.*?))?\s*\]\]\s*$'
  $stepPattern = '(?m)^\s*\[\[STEP:\s*(.+?)\s*\]\]\s*$'
  $planStepUpdates = @()
  foreach ($m in [regex]::Matches($reply, $stepDonePattern)) {
    $stepId = $m.Groups[1].Value.Trim()
    $stepResult = if ($m.Groups.Count -gt 2) { $m.Groups[2].Value.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId)) { continue }
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
  $visibleReply = [regex]::Replace($visibleReply, '(?s)\[\[PARALLEL:.+?\]\]', '')
  $visibleReply = [regex]::Replace($visibleReply, $planBlockPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepDonePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepPattern, '')
  if ($speaker -eq 'claude') { $visibleReply = [regex]::Replace($visibleReply, '(?im)^\s*STATUS:\s*\w+\s*$', '') }
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
  if ($speaker -eq 'claude') {
    $pmatch = [regex]::Match($reply, '(?s)\[\[PARALLEL:\s*(.+?)\s*\]\]')
    if ($pmatch.Success) {
      $pspec = $pmatch.Groups[1].Value.Trim()
      $prepo = $workRoot; $psubsRaw = $pspec
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

  # Stagnation detector: if Codex made no bridge file changes and no attachments for N turns, trigger self-diagnosis.
  if ($speaker -eq 'codex' -and $mode -ne 'discuss') {
    $gitDiffOut = & git -C $bridgeRoot diff --stat HEAD 2>&1
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
        $markerCount = [regex]::Matches($snap, '(?im)^\s*(Тип|Согласовано|Открыто|Решение|Риски|План реализации)\s*:').Count
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

  $plannerStatus = 'CONTINUE'
  if ($speaker -eq 'claude') {
    $statusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(CHAT|CONTINUE|DISCUSS|DONE|RESEARCH)\s*$')
    if ($statusHits.Count -gt 0) { $plannerStatus = $statusHits[$statusHits.Count - 1].Groups[1].Value.ToUpper() }
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
        $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*Решение:[ \t]*\S'
        $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*Риски:[ \t]*\S'
        $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
        $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim() } else { 'нет' }
        $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
        $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
        $planMatch = [regex]::Match($reply, '(?ims)^[*_> \t#-]*План реализации:[ \t]*(.*?)(?=^\s*(STATUS:|Тип:|Согласовано:|Открыто:|Решение:|Риски:)|\z)')
        $hasPlan = $planMatch.Success -and -not [string]::IsNullOrWhiteSpace($planMatch.Groups[1].Value)
        if (-not $converged -or -not $hasPlan) {
          $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
                 elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
                 elseif (-not $openClosed) { "остались открытые вопросы: $openVal" }
                 else { "нет непустого «План реализации:»" }
          Add-Message -From system -Text "💬 CONTINUE из обсуждения требует конвергенции и непустой «План реализации:» — $why. Claude, закройте блок состояния и повторите." -Kind event | Out-Null
          $plannerStatus = 'DISCUSS'
          Update-State { param($s) $s.task_mode='discuss' } | Out-Null
        } else {
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
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  # Guard: в discuss DONE разрешён только при конвергенции (по состоянию), с полом и потолком по ходам
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'discuss') {
    $dtNow = [int](Read-State).discuss_turn
    $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*Решение:[ \t]*\S'
    $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*Риски:[ \t]*\S'
    $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
    $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim() } else { 'нет' }
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
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $didActions = [bool](Read-State).task_did_actions
    $hasVerify  = $reply -imatch '(?im)^\s*\[\[VERIFIED:\s*.+?\]\]\s*$'
    $vrc        = [int](Read-State).verify_retry_count
    if ($didActions -and -not $hasVerify -and $vrc -lt 2) {
      Add-Message -From system -Text "🔍 Фаза верификации: задача меняла файлы, но проверки нет. Claude, ВЫПОЛНИ через Bash проверочную команду/тест/чтение файла/скриншот, покажи результат и добавь строку [[VERIFIED: что проверено | результат]], затем STATUS: DONE." -Kind event | Out-Null
      $plannerStatus = 'VERIFY'
      Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$true } | Out-Null
    } elseif ($didActions -and -not $hasVerify -and $vrc -ge 2) {
      Add-Message -From system -Text "🔍 Верификация не пройдена за 2 попытки — закрываю как есть (нужно внимание оператора)." -Kind event | Out-Null
      try { Send-PushEvent -Kind need_you -Text "Верификация не пройдена: $(Get-PushSnippet -Text $task)" } catch {}
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
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    # Независимый критик: перед закрытием ревьюим git-дифф задачи на другой модели.
    # Серьёзное -> возврат Codex на доработку; сбои критика не блокируют завершение.
    try {
      $stC = Read-State
      if ([bool]$stC.task_did_actions) {
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
            $diffWasTruncated = $false
            if ($diff.Length -gt 16000) {
              $diffWasTruncated = $true
              $diff = $diff.Substring(0,16000) + "`n...[дифф обрезан]..."
            }
            $truncationNote = if ($diffWasTruncated) {
              "ВАЖНО: diff ниже обрезан по лимиту контекста. Не считай сам факт обрезки синтаксической ошибкой, потерей кода или доказательством обрезанной функции; проверяй только реально видимые изменения. Синтаксис .ps1 и BOM проверяются отдельными командами."
            } else { "" }
            $criticModelName = ''
            try { $criticModelName = [string](Get-LLMConfig)['critic'] } catch {}
            $criticPrompt = @"
Ты — независимый код-критик. Другой ИИ (Codex) внёс изменения в проект на PowerShell (автономный мост Claude<->Codex на Windows). Проверь git-дифф на СЕРЬЁЗНЫЕ проблемы: баги, уязвимости безопасности, регрессии, потеря данных, падения, синтаксические ошибки, нарушение инвариантов (каждый .ps1 в UTF-8 с BOM; не трогать watchdog/supervisor/.git; не выводить секреты).
НЕ придирайся к стилю, именованию и форматированию — отмечай только то, что реально сломает работу или создаёт риск.

ОСОБО ПРОВЕРЬ ИЗВЕСТНЫЕ ГРАБЛИ POWERSHELL (частые причины аварий в этом проекте — при наличии ставь severity=serious):
- ConvertTo-Json по строке из `Get-Content -Raw` (или по сырым объектам из ConvertFrom-Json), особенно с -Depth>=12 → рекурсия по ETS-графу провайдера (PSProvider/PSDrive) → OOM ~70ГБ и краш хоста. Должно быть [IO.File]::ReadAllText или `("" + $s)` + ПЛОСКИЕ DTO + -Depth<=10. (это уже роняло мост — /api/radar)
- .ps1 без BOM (PS 5.1 ломает кириллицу); вызов нативного exe (git и т.п.) под $ErrorActionPreference='Stop' (stderr бросит исключение).
- Новый/изменённый API-эндпоинт или UI БЕЗ реальной проверки по HTTP/загрузке страницы.
- Бесконечные циклы / отсутствие таймаута; убийство процессов по возрасту/эвристике; чтение или вывод secrets.json.

ЗАДАЧА: $task

$truncationNote

GIT-ДИФФ:
$diff

Верни СТРОГО JSON без markdown и без пояснений:
{"verdict":"OK","severity":"none","issues":[],"summary":"одна фраза по-русски"}
Где severity = "serious" ТОЛЬКО если есть баг/уязвимость/регрессия, которую обязательно исправить до закрытия; иначе "minor" или "none".
"@
            $rawC = Invoke-LLM -Purpose 'critic' -Prompt $criticPrompt -TimeoutSec 90 -Temperature 0.1
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
            $taskShort = ($task -replace '\s+',' ').Trim()
            if ($taskShort.Length -gt 80) { $taskShort = $taskShort.Substring(0,80) }
            try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + "  model=$criticModelName verdict=$verdict severity=$severity crc=$crc | $taskShort | $summary | $issuesText") -Encoding UTF8 } catch {}
            if ($severity -eq 'serious') {
              $newCrc = $crc + 1
              Update-State ({ param($s) $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue $newCrc -Force }.GetNewClosure()) | Out-Null
              Add-Message -From system -Text "🔎 Независимый критик ($criticModelName) нашёл серьёзное (попытка $newCrc/$criticMaxRetries): $issuesText`n`nCodex, исправь это и снова доведи до STATUS: DONE — задачу НЕ закрываю." -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
              Update-State { param($s) $s.task_mode='normal' } | Out-Null
            } else {
              Add-Message -From system -Text "🔎 Критик ($criticModelName): $verdict / $severity — $summary" -Kind event | Out-Null
            }
          }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + '  critic-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE') {
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
        # Mark autonomous improvements as hypotheses for later reflection.
        $_hCommit = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
        if ($_hCommit) { try { Write-Hypothesis -CommitHash $_hCommit -TaskText ([string]$task) } catch {} }
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
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; $s.current_backlog_id=$null; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    try { Send-PushEvent -Kind need_you -Text "Достигнут лимит ходов ($maxTurns): $(Get-PushSnippet -Text $task)" } catch {}
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
