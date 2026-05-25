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
$triageModel    = if ($cfg.triageModel) { [string]$cfg.triageModel } else { 'sonnet' }
$deepModel      = if ($cfg.deepModel)   { [string]$cfg.deepModel }   else { 'opus' }

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

function Format-Transcript {
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
  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    return ("СВОДКА ПРЕДЫДУЩЕГО ДИАЛОГА (сжато, для контекста):`n" + $summary.Trim() + "`n`n=== ПОСЛЕДНИЕ СООБЩЕНИЯ (полностью) ===`n" + $body)
  }
  return $body
}

function Build-Prompt {
  param([string]$Role, [string]$Task, [string]$Mode = 'normal')
  $transcript = Format-Transcript
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
    $suffix = @"

ТВОЙ ХОД как ПЛАНИРОВЩИК (Claude). У тебя есть инструменты Read/Grep/Glob и Bash (можешь САМ выполнять команды). Реши, как действовать, и заверши ответ ПОСЛЕДНЕЙ отдельной строкой -- только маркер STATUS.

ПРОСТОЕ ДЕЙСТВИЕ -- выполни САМ (без Codex, без Opus), затем `STATUS: DONE`. К простым относятся:
- скриншот экрана; открыть/запустить программу, файл или папку; закрыть/завершить программу или процесс; список процессов/окон; системная информация; одна-две короткие ОБРАТИМЫЕ команды.
- Сделай через Bash и кратко отчитайся по-русски.
- Скриншот: выполни `powershell -NoProfile -ExecutionPolicy Bypass -File "$bridgeRoot\tools\screenshot.ps1"` -- он напечатает путь к PNG; пришли его пользователю отдельной строкой `[[FILE: <путь>]]`.
- Любой файл пользователю -- тем же маркером `[[FILE: <путь>]]`.

Маркеры:
- STATUS: DONE -- сделано (в т.ч. ты сам выполнил простое действие выше); либо работа/обсуждение завершены -- тогда дай ИТОГ (для обсуждения -- чёткое заключение).
- STATUS: CHAT -- только ответить/спросить пользователя, без действий и без Codex (вопрос, объяснение, уточнение).
- STATUS: CONTINUE -- СЛОЖНОЕ -> Codex: написание/правка кода, многошаговое, сборка фич, итерации с тестами, рефакторинг, рискованное/необратимое в больших масштабах. Дай Codex конкретную инструкцию (что, где, критерий готовности).
- STATUS: DISCUSS -- разобрать ИДЕЮ вместе с Codex (без правок): поставь ему тезис/вопрос.

ВАЖНО: не путай простое со сложным. Если сомневаешься, либо действие рискованное/необратимое/масштабное -- НЕ делай сам: используй CONTINUE (Codex) или CHAT (спроси пользователя). Пиши по-русски.
"@
  } elseif ($Mode -eq 'discuss') {
    $suffix = @"

ТВОЙ ХОД как СОБЕСЕДНИК (Codex), на равных с Claude. Это ОБСУЖДЕНИЕ идеи, НЕ выполнение.
Разбери последний тезис/вопрос Claude по существу: найди слабые места и риски, предложи улучшения/компромиссы/альтернативы, при необходимости задай уточняющий вопрос. НЕ меняй файлы (можешь читать код/материалы для аргументов). Кратко, по делу, по-русски.
"@
  } else {
    $suffix = @"

ТВОЙ ХОД как КОДЕР (Codex). Выполни последнюю инструкцию ПЛАНИРОВЩИКА и любое сообщение [USER].
Делай реальные действия (файлы/команды) в рамках задачи. Кратко отчитайся по-русски, что сделал и каков результат.
⛔ НАПОМИНАНИЕ: restart.flag -- ТОЛЬКО если изменён `.ps1`-файл. Проверь перед созданием: `git diff --name-only HEAD`. Для `web\index.html` флаг НЕ нужен.
"@
  }
  return ($shared + $suffix)
}

function Set-AgentPid([int]$ProcId) { Update-State ({ param($s) $s.agent_pid = $ProcId }.GetNewClosure()) | Out-Null }
function Clear-AgentPid { Update-State { param($s) $s.agent_pid = $null } | Out-Null }

function Invoke-Planner {
  param([string]$Prompt, [string]$Model = '')
  $g = [guid]::NewGuid().ToString('N').Substring(0,8)
  $inF=Join-Path $env:TEMP "claude_in_$g.txt"; $outF=Join-Path $env:TEMP "claude_out_$g.txt"; $errF=Join-Path $env:TEMP "claude_err_$g.txt"
  [System.IO.File]::WriteAllText($inF, $Prompt, $Utf8NoBom)
  # Narrow --add-dir to the bridge folder (faster startup); Bash already gives full read access.
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$bridgeRoot,'--allowedTools','Read','Grep','Glob','Bash')
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

function Get-AgentStatusText {
  param([string]$Speaker, [string]$Mode)
  if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет следующий шаг.' }
  if ($Speaker -eq 'claude') { return 'Claude анализирует задачу и выбирает следующий шаг.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex оценивает план, риски и варианты без изменения файлов.' }
  if ($Speaker -eq 'codex') { return 'Codex выполняет правку и проверяет результат.' }
  return $null
}

function Get-AgentPhaseStatusText {
  param([string]$Speaker, [string]$Mode, [string]$Phase)
  $who = if ($Speaker -eq 'claude') { 'Claude' } elseif ($Speaker -eq 'codex') { 'Codex' } else { 'агент' }
  switch ($Phase) {
    'summary' { return "Драйвер проверяет объём истории перед ходом $who." }
    'prompt'  { return "Драйвер готовит свежий контекст для $who." }
    'invoke'  {
      if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex читает контекст и отвечает без изменения файлов.' }
      if ($Speaker -eq 'codex') { return 'Codex работает с файлами и командами.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет план.' }
      return 'Claude анализирует задачу и выбирает следующий шаг.'
    }
    'post'    { return "Драйвер обрабатывает ответ $who и вложения." }
    default   { return Get-AgentStatusText -Speaker $Speaker -Mode $Mode }
  }
}

function Set-BridgeStatusText {
  param([string]$Text)
  Update-State ({ param($s) $s.status_text=$Text; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
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
    $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'
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
    Update-State { param($s) $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
    Start-Sleep -Seconds 1; continue
  }
  if ($state.paused) { Update-State { param($s) $s.status='paused'; $s.active_agent=$null; $s.active_model=$null; $s.status_text='Пауза: мост ждёт команды продолжить.'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null; Start-Sleep -Seconds $loopDelay; continue }

  $maxUser = Get-MaxUserSeq

  if (-not $state.current_task) {
    if ($maxUser -gt [int]$state.last_user_seq) {
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      Update-State ({ param($s) $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'; $s.task_start_seq=$maxUser; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
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
  $speaker = if ($tt -eq 0) { 'claude' } else { Next-Speaker }
  $plannerModel = Get-PlannerModel -TaskText $task -Mode $mode
  $activeModel  = if ($speaker -eq 'claude') { $plannerModel } else { 'codex' }
  $statusText   = Get-AgentStatusText -Speaker $speaker -Mode $mode
  Update-State ({ param($s) $s.active_agent=$speaker; $s.active_model=$activeModel; $s.status_text=$statusText; $s.status='working'; $s.claimed_at=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'summary')
  Update-ContextSummary   # compress old history if it grew beyond the hot window
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'prompt')
  $prompt = Build-Prompt -Role $speaker -Task $task -Mode $mode
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'invoke')
  if ($speaker -eq 'claude') { $reply = Invoke-Planner -Prompt $prompt -Model $plannerModel }
  else { $reply = Invoke-Coder -Prompt $prompt -Mode $mode }

  if ((Read-State).abort) { continue }   # killed mid-turn -> handled at top
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'post')
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
  $visibleReply = [regex]::Replace($reply, $fileMarkerPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $savePattern, '')
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
  Update-State { param($s) $s.task_turn=[int]$s.task_turn+1; $s.turn=[int]$s.turn+1; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null

  $plannerStatus = 'CONTINUE'
  if ($speaker -eq 'claude') {
    $statusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(CHAT|CONTINUE|DISCUSS|DONE)\s*$')
    if ($statusHits.Count -gt 0) { $plannerStatus = $statusHits[$statusHits.Count - 1].Groups[1].Value.ToUpper() }
    if ($plannerStatus -eq 'DISCUSS')      { Update-State { param($s) $s.task_mode='discuss' } | Out-Null }
    elseif ($plannerStatus -eq 'CONTINUE') { Update-State { param($s) $s.task_mode='normal' } | Out-Null }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'CHAT') {
    Add-Message -From system -Text "💬 Ответ без Codex. Жду следующее сообщение." -Kind event | Out-Null
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
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
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    Update-State { param($s) $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
