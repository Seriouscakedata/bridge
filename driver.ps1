# driver.ps1 -- INTERACTIVE bridge: idles, and treats each [USER] chat message as a
# task. Planner (Claude) plans/reviews, Coder (Codex) executes with FULL PC access.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
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
$discussMinTurns   = if ($cfg.discussMinTurns)   { [int]$cfg.discussMinTurns }      else { 6 }
$researchMaxTurns  = if ($cfg.researchMaxTurns)  { [int]$cfg.researchMaxTurns }     else { 2 }

function Get-PlannerModel {
  param([string]$TaskText, [string]$Mode)

  if ($Mode -eq 'discuss') { return $deepModel }

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
  $decAppend = if ($decSect) { "`n`n$decSect" } else { '' }
  $evAppend = if ($evSect) { "`n`n$evSect" } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    return ("СВОДКА ПРЕДЫДУЩЕГО ДИАЛОГА (сжато, для контекста):`n" + $summary.Trim() + "`n`n=== ПОСЛЕДНИЕ СООБЩЕНИЯ (полностью) ===`n" + $body + $decAppend + $evAppend)
  }
  return $body + $decAppend + $evAppend
}

function Build-Prompt {
  param([string]$Role, [string]$Task, [string]$Mode = 'normal')
  $transcript = Format-Transcript
  $dt = [int](Read-State).discuss_turn
  $claudeToolHint = if ($Mode -eq 'research') {
    'У тебя есть инструменты Read/Grep/Glob, WebSearch и WebFetch. Bash недоступен.'
  } else {
    'У тебя есть инструменты Read/Grep/Glob и Bash (можешь САМ выполнять команды).'
  }
  $claudeActionBlock = if ($Mode -eq 'research') {
@"
RESEARCH-ХОД -- не выполняй действия в системе и не меняй файлы. Твоя задача: найти/прочитать внешние источники, выделить проверяемые факты, записать evidence-маркеры и дать план следующего action-хода.
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
  $shared = @"
Ты часть автономной пары ИИ-ассистентов с ПОЛНЫМ доступом к компьютеру пользователя (Windows).
Рабочий корень: $workRoot

ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:
$Task

РОЛИ: ПЛАНИРОВЩИК = Claude (разбор задачи, инструкции, ревью). КОДЕР = Codex (выполнение: файлы, команды, тесты).
ПРАВИЛА:
- Сообщения [USER] -- от пользователя-оператора. ВЫСШИЙ приоритет, выполняй их.
- Пиши кратко и ПО-РУССКИ. Технические токены (пути, команды, код) и строку STATUS не переводи.
- [SYSTEM] -- объективные события от драйвера.
- У вас полный доступ: чтение/запись файлов где угодно и запуск команд. Будь аккуратен с необратимыми действиями (удаление, перезапись, сеть).
- Чтобы прислать файл/скриншот пользователю в чат, помести в ответ отдельной строкой маркер `[[FILE: C:\полный\путь]]` (можно несколько).
- САМОУЛУЧШЕНИЕ РАЗРЕШЕНО: тебе МОЖНО улучшать сам мост (файлы в `C:\Users\rafie\OneDrive\Documents\bridge\`: `web\index.html`, `server.ps1`, `driver.ps1`, `lib\common.ps1` и т.п.). СТРОГИЕ ПРАВИЛА БЕЗОПАСНОСТИ (нарушение убьёт мост):
  1) Каждый `.ps1` сохраняй СТРОГО в UTF-8 С BOM. Без BOM PowerShell 5.1 не распарсит русский/эмодзи -> мост умрёт. В PowerShell записать с BOM: `[System.IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($true)))`.
  2) После записи любого `.ps1` ПРОВЕРЬ синтаксис: `powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('<путь>',[ref]$t,[ref]$e)|Out-Null;if($e.Count){'ERR'}else{'OK'}"`. Применяй, ТОЛЬКО если 'OK'.
  3) Применить правки .ps1-файлов движка: создай файл `bridge\control\restart.flag` -- супервизор перезапустит мост (без UAC). ⛔ СТРОГИЙ ЗАПРЕТ: restart.flag создавать ТОЛЬКО если изменён хотя бы один `.ps1`-файл. Перед созданием флага ОБЯЗАТЕЛЬНО проверь: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" diff --name-only HEAD` -- если в выводе НЕТ ни одного `.ps1`, флаг НЕ создавай (мост перезапустится зря).
  4) После КАЖДОЙ проверенной рабочей правки: `git -C "C:\Users\rafie\OneDrive\Documents\bridge" add -A; git -C "..." commit -m "что сделал"`. Это фиксирует прогресс (watchdog откатит на последний коммит при поломке).
  5) `web\index.html` (UI) можно править свободно -- применяется без перезапуска (просто обнови вкладку). ⛔ НЕ создавай restart.flag ради HTML-правок -- это лишние перезапуски и шум в истории.
  6) НЕ ТРОГАЙ: `watchdog.ps1`, `supervisor.ps1` без крайней нужды, папку `.git`, задачи Планировщика; НЕ убивай процессы моста/watchdog; НЕ удаляй файлы движка.

ДИАЛОГ:
$transcript
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

ПРАВИЛО ВЕРИФИКАЦИИ: перед STATUS: DONE -- если Codex выполнял действия (файлы/команды), ты ОБЯЗАН явно показать в ответе результат проверки: вывод команды, git diff, содержимое файла или тест. Без явной проверки STATUS: DONE запрещён -- используй STATUS: CONTINUE и попроси Codex проверить, или проверь сам через Bash.

ВАЖНО: не путай простое со сложным. Если сомневаешься, либо действие рискованное/необратимое/масштабное -- НЕ делай сам: используй CONTINUE (Codex) или CHAT (спроси пользователя). Пиши по-русски.
"@
    if ($Mode -eq 'research') {
      $researchNote = "`n`nРЕЖИМ RESEARCH: ищи, читай внешние источники, анализируй. ЗАПРЕЩЕНО запускать Bash/изменять файлы.`nОБЯЗАТЕЛЬНО в этом ходе: дай хотя бы 1 маркер [[EVIDENCE: url | краткий тезис | high|med|low]].`nЗатем напиши STATUS: CONTINUE с планом для Codex (или STATUS: DONE если задача только исследовательская)."
      $suffix = $claudeBase + $researchNote
    } elseif ($Mode -eq 'discuss') {
      $discussNote = "`n`nРЕЖИМ ОБСУЖДЕНИЯ (ход $dt / минимум $discussMinTurns): ты ведёшь настоящую дискуссию, не просто принимаешь аргументы. Отвечай на возражения Codex по существу — прими или оспорь каждый конкретный аргумент с обоснованием. Не суммируй позиции без ответа на критику. STATUS: DONE разрешён ТОЛЬКО когда ходов >= $discussMinTurns И все ключевые разногласия исчерпаны. Иначе — STATUS: DISCUSS с новым вопросом или тезисом."
      $suffix = $claudeBase + $discussNote
    } else {
      $suffix = $claudeBase
    }
  } elseif ($Mode -eq 'discuss') {
    $suffix = @"

ТВОЙ ХОД как ОППОНЕНТ (Codex) — раунд $dt из $discussMinTurns минимум.
Это НАСТОЯЩАЯ ДИСКУССИЯ. Твоя роль — КРИТИЧЕСКИ проверять позицию Claude, не соглашаться по умолчанию.
ОБЯЗАТЕЛЬНО в каждом ответе:
  1. Укажи конкретный слабый пункт, риск или скрытое допущение в последнем аргументе Claude (не общий, а конкретный).
  2. Предложи альтернативный подход или компромисс, реально отличающийся от предложенного Claude.
  3. Задай уточняющий вопрос, если позиция Claude неполная или противоречивая.
⚠ ЗАПРЕЩЕНО: соглашаться без конкретных аргументов; перефразировать слова Claude без возражений; писать «в целом согласен»; закрывать обсуждение (это роль Claude).
Кратко, конкретно, по-русски. НЕ меняй файлы (читать код/материалы для аргументов — можно).
"@
  } else {
    $suffix = @"

ТВОЙ ХОД как КОДЕР (Codex). Выполни последнюю инструкцию ПЛАНИРОВЩИКА и любое сообщение [USER].
Делай реальные действия (файлы/команды) в рамках задачи. Кратко отчитайся по-русски, что сделал и каков результат.
ПЛАН ЗАДАЧИ: для сложных задач (3+ шага) в первом ответе пиши нумерованный чеклист шагов. Обновляй при каждом ходе: ✅ готово, 🔄 текущий, ⬜ впереди.
SAFETY GATE: перед удалением файлов/папок ВНЕ директории bridge, массовой перезаписью чужих данных, убийством процессов пользователя, внешними сетевыми запросами — напиши строку [[SAFETY: <что именно>]] и НЕ ВЫПОЛНЯЙ. Драйвер остановится и спросит пользователя.
⛔ НАПОМИНАНИЕ: restart.flag -- ТОЛЬКО если изменён `.ps1`-файл. Проверь перед созданием: `git diff --name-only HEAD`. Для `web\index.html` флаг НЕ нужен.
"@
  }
  return ($shared + $suffix)
}

function Set-AgentPid([int]$ProcId) { Update-State ({ param($s) $s.agent_pid = $ProcId }.GetNewClosure()) | Out-Null }
function Clear-AgentPid { Update-State { param($s) $s.agent_pid = $null } | Out-Null }

function Invoke-Planner {
  param([string]$Prompt, [string]$Model = '', [string]$Mode = 'normal')
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "claude_in_$g.txt"; $outF=Join-Path $env:TEMP "claude_out_$g.txt"; $errF=Join-Path $env:TEMP "claude_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $Prompt, $Utf8NoBom)
  # Narrow --add-dir to the bridge folder (faster startup); Bash already gives full read access.
  $allowedTools = if ($Mode -eq 'research') { @('Read','Grep','Glob','WebSearch','WebFetch') } else { @('Read','Grep','Glob','Bash') }
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$bridgeRoot,'--allowedTools') + $allowedTools
  if ($Model) { $claudeArgs += @('--model', $Model) }
  $reply = ''
  try {
    $p = Start-Process -FilePath $claudeExe -ArgumentList $claudeArgs `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $null = $p.Handle; Set-AgentPid $p.Id
    if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch {}; return '(planner timeout)' }
    if (Test-Path $outF) { $reply = Get-Content $outF -Raw -Encoding UTF8 }
  } finally { Clear-AgentPid; Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue }
  if ($null -eq $reply) { $reply = '' }
  return $reply.Trim()
}

function Invoke-Coder {
  param([string]$Prompt, [string]$Mode = 'code')
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "codex_in_$g.txt"; $msgF=Join-Path $env:TEMP "codex_msg_$g.txt"; $outF=Join-Path $env:TEMP "codex_out_$g.txt"; $errF=Join-Path $env:TEMP "codex_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $Prompt, $Utf8NoBom)
  $sbMode = if ($Mode -eq 'discuss') { 'read-only' } else { 'danger-full-access' }
  $reply = ''
  try {
    $p = Start-Process -FilePath $codexExe `
      -ArgumentList 'exec','--color','never','--skip-git-repo-check','-s',$sbMode,'-C',$workRoot,'-o',$msgF,'-' `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    $null = $p.Handle; Set-AgentPid $p.Id
    if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch {}; return '(coder timeout)' }
    if (Test-Path $msgF) { $reply = Get-Content $msgF -Raw -Encoding UTF8 }
  } finally { Clear-AgentPid; Remove-Item $inF,$msgF,$outF,$errF -ErrorAction SilentlyContinue }
  if ($null -eq $reply) { $reply = '' }
  return $reply.Trim()
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
    $null = $p.Handle
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; return $null }
    if (Test-Path $outF) { $reply = Get-Content $outF -Raw -Encoding UTF8 }
  } finally { Remove-Item $inF,$outF,$errF -ErrorAction SilentlyContinue }
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
    if ($Speaker -eq 'claude') { return "Claude планирует: «$topic»" }
    if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return "Codex оценивает идею: «$topic»" }
    if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
  }
  if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude ищет и сверяет внешние источники без Bash.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет следующий шаг.' }
  if ($Speaker -eq 'claude') { return 'Claude анализирует задачу и выбирает следующий шаг.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex оценивает план, риски и варианты без изменения файлов.' }
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
        if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return "Claude обдумывает план: «$topic»" }
        return "Claude планирует: «$topic»"
      }
      if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex читает контекст и отвечает без изменения файлов.' }
      if ($Speaker -eq 'codex') { return 'Codex работает с файлами и командами.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude проверяет внешние источники без Bash.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет план.' }
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
  } catch {}
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
    $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0
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
    Update-State { param($s) $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
    Start-Sleep -Seconds 1; continue
  }
  if ($state.paused) { Update-State { param($s) $s.status='paused'; $s.active_agent=$null; $s.active_model=$null; $s.status_text='Пауза: мост ждёт команды продолжить.'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null; Start-Sleep -Seconds $loopDelay; continue }

  $maxUser = Get-MaxUserSeq

  if (-not $state.current_task) {
    if ($maxUser -gt [int]$state.last_user_seq) {
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      Update-State ({ param($s) $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'; $s.discuss_turn=0; $s.research_count=0; $s.task_start_seq=$maxUser; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
      Add-Message -From system -Text "📥 Новая задача принята в работу." -Kind event | Out-Null
      $state = Read-State
    } else {
      Update-State { param($s) $s.status='idle'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      Start-Sleep -Seconds $idlePoll; continue
    }
  } else {
    if ($maxUser -gt [int]$state.last_user_seq) { Update-State ({ param($s) $s.last_user_seq=$maxUser }.GetNewClosure()) | Out-Null }
  }

  $task = [string]$state.current_task
  $tt   = [int]$state.task_turn
  $mode = if ($state.task_mode) { [string]$state.task_mode } else { 'normal' }
  $speaker = if ($mode -eq 'research') { 'claude' } elseif ($tt -eq 0) { 'claude' } else { Next-Speaker }
  $plannerModel = Get-PlannerModel -TaskText $task -Mode $mode
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
    if ($speaker -eq 'claude') { $reply = Invoke-Planner -Prompt $prompt -Model $plannerModel -Mode $mode }
    else { $reply = Invoke-Coder -Prompt $prompt -Mode $mode }
  } catch {
    Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $_.Exception.Message -Status 'error'
    throw
  }
  Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $reply

  if ((Read-State).abort) { continue }   # killed mid-turn -> handled at top

  # Handle agent timeouts as retryable errors, not normal replies.
  if ($reply -eq '(coder timeout)' -or $reply -eq '(planner timeout)') {
    $who = if ($reply -eq '(coder timeout)') { 'Codex' } else { 'Claude' }
    $trc = [int](Read-State).timeout_retry_count
    if ($trc -lt 1) {
      Add-Message -From system -Text "⏱ Таймаут $who — повторяю попытку..." -Kind event | Out-Null
      $newTrc = $trc + 1
      $mutTrc = { param($s) $s.timeout_retry_count = $newTrc; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()
      Update-State $mutTrc | Out-Null
      continue
    } else {
      Add-Message -From system -Text "⏱ Таймаут $who повторился. Задача приостановлена — уточни или дай новую." -Kind event | Out-Null
      Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
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
      Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      continue
    }
  }

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'post' -TaskText $task)
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = "(нет ответа от $speaker)" }
  $attachmentMetas = @()
  $failedAttachmentPaths = @()
  $fileMarkerPattern = '(?m)^\s*\[\[FILE:\s*(.+?)\s*\]\]\s*$'
  foreach ($match in [regex]::Matches($reply, $fileMarkerPattern)) {
    $sourcePath = $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    if ($sourcePath.StartsWith('<') -and $sourcePath.EndsWith('>') -and $sourcePath.Length -gt 2) {
      $sourcePath = $sourcePath.Substring(1, $sourcePath.Length - 2).Trim()
    }
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
  $visibleReply = [regex]::Replace($reply, $fileMarkerPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $savePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $evidencePattern, '')
  if ($speaker -eq 'claude') { $visibleReply = [regex]::Replace($visibleReply, '(?im)^\s*STATUS:\s*\w+\s*$', '') }
  $visibleReply = $visibleReply.Trim()
  if ($failedAttachmentPaths.Count -gt 0) {
    $failLines = ($failedAttachmentPaths | ForEach-Object { "- $_" }) -join "`n"
    $fileWarning = "⚠ Не удалось прикрепить файл:`n$failLines"
    if ([string]::IsNullOrWhiteSpace($visibleReply)) { $visibleReply = $fileWarning }
    else { $visibleReply = $visibleReply.TrimEnd() + "`n`n" + $fileWarning }
  }
  if ([string]::IsNullOrWhiteSpace($visibleReply) -and $attachmentMetas.Count -eq 0) { $visibleReply = "(нет ответа от $speaker)" }
  Add-Message -From $speaker -Text $visibleReply -Attachments $attachmentMetas | Out-Null
  foreach ($sp in $savedPaths) { Add-Message -From system -Text "📝 Заметка сохранена: $sp" -Kind event | Out-Null }
  foreach ($source in $evidenceSources) { Add-Message -From system -Text "📊 Evidence записан: $source" -Kind event | Out-Null }

  # Stagnation detector: if Codex made no bridge file changes and no attachments for N turns, trigger self-diagnosis.
  if ($speaker -eq 'codex' -and $mode -ne 'discuss') {
    $gitDiffOut = & git -C $bridgeRoot diff --stat HEAD 2>&1
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
        Update-State { param($s) $s.task_mode='discuss'; $s.discuss_turn=0 } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='discuss' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'CONTINUE') { Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0 } | Out-Null }
    elseif ($plannerStatus -eq 'RESEARCH') {
      if ($modeBeforeIncrement -eq 'research') {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0 } | Out-Null
      } else {
        $rc = [int](Read-State).research_count
        if ($rc -lt $researchMaxTurns) {
          $newRc = $rc + 1
          Update-State ({ param($s) $s.task_mode='research'; $s.research_count=$newRc; $s.discuss_turn=0 }.GetNewClosure()) | Out-Null
        } else {
          Add-Message -From system -Text "🔍 Бюджет research исчерпан ($researchMaxTurns/$researchMaxTurns ходов). Codex получит уже собранные данные." -Kind event | Out-Null
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0 } | Out-Null
        }
      }
    }
    if ($modeBeforeIncrement -eq 'research' -and $plannerStatus -ne 'DONE' -and $plannerStatus -ne 'CHAT') {
      Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0 } | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'CHAT') {
    Add-Message -From system -Text "💬 Ответ без Codex. Жду следующее сообщение." -Kind event | Out-Null
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  # Guard: block premature DONE in discuss mode
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'discuss') {
    $dtNow = [int](Read-State).discuss_turn
    if ($dtNow -lt $discussMinTurns) {
      Add-Message -From system -Text "💬 Обсуждение продолжается ($dtNow/$discussMinTurns ходов). Claude, углубите дискуссию — не закрывайте тему раньше времени." -Kind event | Out-Null
      $plannerStatus = 'DISCUSS'
      Update-State { param($s) $s.task_mode='discuss' } | Out-Null
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
    Add-Message -From system -Text "✅ Задача выполнена. Жду следующую." -Kind event | Out-Null
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.discuss_turn=0; $s.research_count=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
