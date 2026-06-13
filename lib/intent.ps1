# intent.ps1 -- LLM-based task intent classifier.
#
# Replaces the hardcoded [[DEEP-THINK]] marker regex with semantic understanding:
# instead of matching trigger words ("обсуди", "снова", "срочно", ...) we ask a
# cheap LLM to read the task text and return a STRUCTURED decomposition:
# primary mode + subtasks + flags. The driver consumes this to pick task_mode
# (discuss / normal / study / fast / chat / computer_action) and the planner sees the breakdown
# in its prompt so it can act on the user's actual intent, not just keywords.
#
# Cost: one gemini-2.5-flash-lite call per new task (~$0.0001). Graceful
# degradation: if LLM fails or returns garbage, caller falls back to legacy
# marker detection ([[DEEP-THINK]], [[NORMAL]], [[FAST]]).
#
# Why not a dictionary: users write in natural Russian / English mix. Maintaining
# a synonym list for every mode trigger is brittle (user pushes back: "обсуди"
# routed to normal mode; we'd add "обсуди" -> later "обсудим", "потолкуем",
# "перетрём", endless). LLM understands intent in one pass.

# 2026-05-28: original gemini-2.5-flash-lite design; was deepseek-v4-flash for
# a few hours during the Google billing restriction (operator's account was
# suspended for past-due payment, reinstated same day). Verified back-to-200
# on the 2.5-line, reverted. Operator can override via config.json llm.intent.
$script:IntentDefaultModel = 'gemini-2.5-flash-lite'

function Get-IntentModel {
  # Lets operator override via config.json -> llm.intent. Default flash-lite.
  $cfg = $null
  try { $cfg = Get-LLMConfig } catch {}
  if ($cfg -and $cfg.ContainsKey('intent') -and -not [string]::IsNullOrWhiteSpace([string]$cfg['intent'])) {
    return [string]$cfg['intent']
  }
  return $script:IntentDefaultModel
}

function ConvertFrom-IntentJson {
  # Strip ```json fences if present, extract first {...} block.
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ($Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  $m = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $m.Success) { return $null }
  try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

function Test-IsComputerActionTask {
  param([string]$TaskText)
  $t = ([string]$TaskText).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  if ($t -match '(?i)(удал\w*|сотр\w*|формат\w*|shutdown|restart-computer|перезагруз\w*\s+комп|выключ\w*\s+комп|git\s+push|reset\s+--hard)') { return $false }
  return [bool]([regex]::IsMatch($t, '(?i)(нажм\w*|кликн\w*|щелкн\w*|кнопк\w*|мышк\w*|курсор|закрой\s+(?:это|то)?\s*окн\w*|закрыть\s+(?:это|то)?\s*окн\w*|\bclick\b|\bpress\b|move\s+mouse|close\s+(?:this\s+)?window)'))
}

function Test-TaskIntent {
  # Classify a user task. Returns a PSCustomObject with:
  #   primary_mode    : 'discuss' | 'normal' | 'study' | 'fast' | 'chat' | 'computer_action'
  #   confidence      : 0.0-1.0
  #   reasoning       : short string (logged to chat)
  #   subtasks        : array of {action, object, after?, with?} hashtables
  #   user_wants_dialogue : bool (true if user explicitly asked for discussion)
  #   complexity      : 'trivial' | 'simple' | 'moderate' | 'complex'
  #   estimated_turns : int (rough hint for budget)
  #   raw             : raw LLM response (for debugging)
  # Returns $null on LLM error / non-JSON / model unavailable.
  param(
    [string]$TaskText,
    [int]$TimeoutSec = 25,
    [string]$Model = ''
  )
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $null }
  if ([string]::IsNullOrWhiteSpace($Model)) { $Model = Get-IntentModel }
  if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) { return $null }

  if (Test-IsComputerActionTask -TaskText $TaskText) {
    return [pscustomobject]@{
      primary_mode = 'computer_action'
      confidence = 0.9
      reasoning = 'локальное управление мышью/окном: отдельный быстрый computer-use fast-lane'
      subtasks = @(@{ action = 'computer_action'; object = 'mouse/window control' })
      user_wants_dialogue = $false
      complexity = 'trivial'
      estimated_turns = 1
      raw = $null
      source = 'deterministic-computer-action'
      model = 'rule'
    }
  }

  # Skip the LLM call for very short prompts -- they're almost always fast-lane
  # or chat ("привет", "статус?", "запусти аудит"). Saves the round-trip.
  $textTrim = $TaskText.Trim()
  if ($textTrim.Length -lt 30) {
    if (Test-IsSafeOsFastLaneTask -TaskText $textTrim) {
      return [pscustomobject]@{
        primary_mode = 'fast'
        confidence = 0.85
        reasoning = 'короткая безопасная OS-команда'
        subtasks = @()
        user_wants_dialogue = $false
        complexity = 'trivial'
        estimated_turns = 1
        raw = $null
        source = 'short-skip-fast'
      }
    }
    return [pscustomobject]@{
      primary_mode = 'normal'
      confidence = 0.5
      reasoning = 'short task, skipped LLM classification'
      subtasks = @()
      user_wants_dialogue = $false
      complexity = 'trivial'
      estimated_turns = 1
      raw = $null
      source = 'short-skip'
    }
  }

  # Truncate very long tasks so the classifier prompt stays cheap. We only need
  # the user's TOP-LEVEL intent; long specs are still seen in full by the planner.
  $taskForLLM = if ($textTrim.Length -gt 3000) { $textTrim.Substring(0, 3000) + "`n...[truncated]" } else { $textTrim }

  $prompt = @"
Ты классификатор намерения для AI-моста (Claude+Codex, PowerShell). На вход — задача от пользователя на естественном языке (русский/английский). Твоя цель: разложить задачу на структурные команды, чтобы мост выбрал правильный режим работы (а не угадывал по словарю триггеров).

РЕЖИМЫ (выбери ровно ОДИН):
- "discuss"  — пользователь явно хочет обсуждение/диалог между Claude и Codex перед реализацией. Признаки: «обсуди», «посоветуйся», «подумайте вместе», «согласуйте», «давайте обсудим», «прежде чем делать — обсудите». Также если пользователь спрашивает архитектурное мнение или просит «проанализируй и предложи». Diскуссия = синтез до согласия, потом реализация.
- "study"    — пользователь хочет ИЗУЧЕНИЕ темы (внешней / внутренней) без немедленной реализации. Признаки: «изучи», «разберись как работает», «исследуй», «найди в интернете», «прочитай эти статьи».
- "fast"     — простая безопасная императивная команда (одно обратимое OS/UI/read-действие): «запусти X», «открой файл Y», «покажи логи», «сделай скриншот», «найди программу». НЕ удаление/форматирование/kill/push.
- "chat"     — пользователь задаёт вопрос/просит объяснение БЕЗ изменения файлов: «что такое X?», «как работает Y?», «расскажи про Z», «простыми словами объясни». Ответ — текстом в чат.
- "computer_action" — пользователь просит управлять мышью/окном прямо сейчас: «нажми OK», «кликни по кнопке», «закрой это окно», «press button», «click», «move mouse». Это отдельный быстрый локальный путь без planner/coder/critic.
- "normal"   — обычная задача на реализацию: «сделай X», «добавь Y», «почини Z». БЕЗ явного намерения обсуждать или исследовать. Это default.

ПОДЗАДАЧИ: разложи задачу на 1-5 атомарных шагов. Для каждого укажи action (discuss|implement|fix|research|configure|answer) и object (что именно).

ОЦЕНКА СЛОЖНОСТИ: trivial (1 строка) / simple (1 файл) / moderate (2-3 файла) / complex (4+ файлов или архитектурное).

ВАЖНО:
- Если в задаче есть И обсуждение И реализация («обсуди и сделай») — primary_mode = "discuss" (обсуждение первично).
- НЕ ориентируйся на маркеры вроде [[DEEP-THINK]] — это устаревший способ, мы тебя используем именно чтобы их заменить.
- confidence: 0.9+ если намерение явное; 0.6-0.8 если есть нюанс; <0.5 если неоднозначно (тогда система упадёт на normal).

ЗАДАЧА:
$taskForLLM

Верни СТРОГО JSON без markdown:
{"primary_mode":"...","confidence":0.0-1.0,"reasoning":"короткое объяснение","subtasks":[{"action":"...","object":"..."}],"user_wants_dialogue":true|false,"complexity":"...","estimated_turns":1-10}
"@

  $raw = $null
  try {
    $raw = Invoke-LLM -Purpose 'intent' -Model $Model -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.1
  } catch {
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $obj = ConvertFrom-IntentJson -Text $raw
  if (-not $obj) { return $null }

  # Normalize + validate.
  $mode = ''
  if ($obj.PSObject.Properties.Name -contains 'primary_mode') { $mode = ([string]$obj.primary_mode).Trim().ToLowerInvariant() }
  if ($mode -notin @('discuss','normal','study','fast','chat','computer_action')) { $mode = 'normal' }

  $conf = 0.0
  try { $conf = [double]$obj.confidence } catch {}
  if ($conf -lt 0) { $conf = 0.0 }
  if ($conf -gt 1) { $conf = 1.0 }

  $reasoning = ''
  if ($obj.PSObject.Properties.Name -contains 'reasoning') { $reasoning = [string]$obj.reasoning }

  $subtasks = @()
  if ($obj.PSObject.Properties.Name -contains 'subtasks' -and $obj.subtasks) {
    foreach ($s in @($obj.subtasks)) {
      $action = ''; $object = ''
      try { if ($s.PSObject.Properties.Name -contains 'action') { $action = [string]$s.action } } catch {}
      try { if ($s.PSObject.Properties.Name -contains 'object') { $object = [string]$s.object } } catch {}
      if (-not [string]::IsNullOrWhiteSpace($action) -or -not [string]::IsNullOrWhiteSpace($object)) {
        $subtasks += @{ action = $action; object = $object }
      }
    }
  }

  $wantsDialogue = $false
  try { if ($obj.PSObject.Properties.Name -contains 'user_wants_dialogue') { $wantsDialogue = [bool]$obj.user_wants_dialogue } } catch {}

  $complexity = 'moderate'
  try { if ($obj.PSObject.Properties.Name -contains 'complexity') { $complexity = ([string]$obj.complexity).Trim().ToLowerInvariant() } } catch {}
  if ($complexity -notin @('trivial','simple','moderate','complex')) { $complexity = 'moderate' }

  $turns = 1
  try { if ($obj.PSObject.Properties.Name -contains 'estimated_turns') { $turns = [int]$obj.estimated_turns } } catch {}
  if ($turns -lt 1) { $turns = 1 }
  if ($turns -gt 20) { $turns = 20 }

  return [pscustomobject]@{
    primary_mode = $mode
    confidence = $conf
    reasoning = $reasoning
    subtasks = $subtasks
    user_wants_dialogue = $wantsDialogue
    complexity = $complexity
    estimated_turns = $turns
    raw = $raw
    source = 'llm'
    model = $Model
  }
}

function Format-IntentForPrompt {
  # Build a compact block the planner sees in its prompt. Shows what the
  # classifier inferred so the planner can either follow the breakdown or
  # explicitly override (e.g. "пользователь сказал обсуди, я согласен — STATUS: DISCUSS").
  param($Intent)
  if (-not $Intent) { return '' }
  $mode = ''
  try {
    if ($Intent.PSObject.Properties.Name -contains 'primary_mode') { $mode = [string]$Intent.primary_mode }
    elseif ($Intent.PSObject.Properties.Name -contains 'mode') { $mode = [string]$Intent.mode }
  } catch {}
  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add('🧭 LLM-классификатор намерения (читай как подсказку, не догму):')
  [void]$lines.Add(("  режим: " + $mode + ' (confidence=' + ('{0:N2}' -f [double]$Intent.confidence) + ')'))
  if (-not [string]::IsNullOrWhiteSpace([string]$Intent.reasoning)) {
    [void]$lines.Add(("  причина: " + [string]$Intent.reasoning))
  }
  if ([bool]$Intent.user_wants_dialogue) {
    [void]$lines.Add('  ⚠ user_wants_dialogue=TRUE — пользователь хочет обсудить, прежде чем делать.')
  }
  if ($Intent.subtasks -and @($Intent.subtasks).Count -gt 0) {
    [void]$lines.Add('  разложение на подзадачи:')
    $idx = 0
    foreach ($s in @($Intent.subtasks)) {
      $idx++
      $a = if ($s -is [hashtable]) { [string]$s['action'] } else { try { [string]$s.action } catch { '' } }
      $o = if ($s -is [hashtable]) { [string]$s['object'] } else { try { [string]$s.object } catch { '' } }
      [void]$lines.Add(("    " + $idx + '. ' + $a + ' → ' + $o))
    }
  }
  [void]$lines.Add(("  сложность: " + [string]$Intent.complexity + ', estimated_turns=' + [string]$Intent.estimated_turns))
  return ([string]::Join("`n", $lines.ToArray()))
}

function Test-IntentLowComplexity {
  # True when the classifier is CONFIDENT the task is small enough to skip the
  # heavy ceremony (planner + critic + the multi-turn Claude<->Codex "discuss"
  # debate). A 1-line / 1-file change must not trigger an architectural
  # deliberation -- that is exactly the latency the operator complained about
  # ("show a desktop screenshot" routed to discuss mode, ~7 min).
  #
  # Caps (all must hold): confidence >= MinConfidence, complexity in
  # {trivial,simple}, estimated_turns <= MaxTurns. Anything moderate/complex,
  # low-confidence, or many-turns falls through to the normal pipeline so we
  # never under-power a genuinely big task. The driver still lets the coder
  # escalate mid-task via [[PLAN]]/[[NEED-TOOL]]/[[DISPATCH-DAG]], and the
  # operator can force the full path with [[DEEP-THINK]] / [[NORMAL]].
  param($Intent, [double]$MinConfidence = 0.7, [int]$MaxTurns = 4)
  if (-not $Intent) { return $false }
  $conf = 0.0
  try { $conf = [double]$Intent.confidence } catch { return $false }
  if ($conf -lt $MinConfidence) { return $false }
  $cx = ''
  try { $cx = ([string]$Intent.complexity).Trim().ToLowerInvariant() } catch {}
  if ($cx -notin @('trivial','simple')) { return $false }
  $turns = 99
  try { $turns = [int]$Intent.estimated_turns } catch { $turns = 99 }
  if ($turns -gt $MaxTurns) { return $false }
  return $true
}
