# architect.ps1 -- the meta-improvement agent ("Architect").
#
# Where reflect.ps1 is leaf-level ("what to tweak in this turn") and Doctor is acute fix
# ("this task just failed -- diagnose & repair"), the Architect is STRUCTURAL: it looks
# across the post-mortem corpus, failure patterns, operator interventions, capability
# matrix, metrics, radar findings, and external-systems comparisons -- and proposes 1-3
# architectural changes (whole new mechanisms, new agents, new safeguards) into the
# backlog. It NEVER auto-executes. The user approves like any external idea.
#
# State / cadence:
#   - Schedule gate: at least 24h since last run (or via /api/architect/run manual trigger).
#   - Or: after >=10 closed user tasks since last run (delta trigger).
#   - Marker: control/architect.last (ISO ts) + control/architect.taskcount.last (int).
#   - Mode 'normal': 1-3 grounded structural ideas.
#   - Mode 'deep-think': open-ended weekly "what should bridge be in 3 months?".

function Get-ArchitectMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.last' }
function Get-ArchitectCountMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.taskcount.last' }
function Get-ArchitectExternalSystemsPath { Join-Path (Get-BridgeRoot) 'external-systems.md' }
function Get-ArchitectMatrixPath { Join-Path (Get-BridgeRoot) 'architecture-matrix.md' }

function Get-ArchitectScope {
  # Single source of truth: see Get-EffectiveScope in lib/channels.ps1.
  if (-not (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue)) {
    throw "Get-ArchitectScope: Get-EffectiveScope is not loaded (lib/channels.ps1 must be sourced before any architect call)"
  }
  return (Get-EffectiveScope)
}

function Get-OperatorInterventions {
  # Scan recent user messages for intervention markers -- signals where the operator stepped
  # in because the bridge couldn't do something. Returns up to $Limit most recent items.
  # Intervention markers (Russian + English heuristics): commands of correction/audit, complaints.
  param([int]$Limit = 15, [int]$Since = 0)
  $patterns = @(
    'исправ', 'почему', 'разбер', 'не\s+работа', 'не\s+вижу', 'не\s+делает',
    'не\s+выполня', 'не\s+отрабат', 'не\s+появи', 'почини', 'не\s+появ',
    'добавь', 'убери', 'удали', 'переделай', 'верни', 'это\s+баг', 'это\s+ошибк',
    'сломан', 'падает', 'ленится', 'странн', 'странно', 'что\s+случилось',
    'это\s+нормально', 'почему\s+мост', 'аудит\s+(моста|себя)',
    'broken', "doesn'?t\s+work", 'why\s+does', 'fix\s+this'
  )
  $combined = '(?i)\b(?:' + ($patterns -join '|') + ')\b'
  $msgs = @(Get-Messages -Since $Since | Where-Object { $_.from -eq 'user' })
  $hits = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in $msgs) {
    $t = [string]$m.text
    $found = [regex]::Match($t, $combined)
    if (-not $found.Success) { continue }
    $snippet = $t -replace '\s+', ' '
    if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0,200) + '...' }
    [void]$hits.Add([pscustomobject]@{
      seq     = [int]$m.seq
      ts      = [string]$m.ts
      marker  = $found.Value
      snippet = $snippet
    })
  }
  return @($hits.ToArray() | Sort-Object seq -Descending | Select-Object -First $Limit)
}

function Get-ArchitectContext {
  # Compact diagnostic dump for the Architect prompt. All strings, no ETS.
  param([int]$WindowDays = 7)
  $sb = New-Object System.Text.StringBuilder
  $scope = Get-ArchitectScope

  [void]$sb.AppendLine('=== EFFECTIVE SCOPE ===')
  [void]$sb.AppendLine("channel=$($scope.slug) is_bridge=$($scope.is_bridge)")
  [void]$sb.AppendLine("project_root=$($scope.project_root)")
  [void]$sb.AppendLine("backlog_path=$($scope.backlog_path)")
  [void]$sb.AppendLine('')

  # 1) capability matrix
  $matrixPath = Get-ArchitectMatrixPath
  if (Test-Path $matrixPath) {
    [void]$sb.AppendLine('=== CAPABILITY MATRIX (текущее состояние) ===')
    try {
      $mtx = [System.IO.File]::ReadAllText($matrixPath, [System.Text.Encoding]::UTF8)
      if ($mtx.Length -gt 8000) { $mtx = $mtx.Substring(0, 8000) + "`n...[truncated]" }
      [void]$sb.AppendLine($mtx)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 2) ARCHITECTURE_V2 (the plan / north-star architecture)
  $archPath = Join-Path (Get-BridgeRoot) 'ARCHITECTURE_V2.md'
  if (Test-Path $archPath) {
    [void]$sb.AppendLine('=== ARCHITECTURE_V2.md (план) ===')
    try {
      $arch = [System.IO.File]::ReadAllText($archPath, [System.Text.Encoding]::UTF8)
      if ($arch.Length -gt 4000) { $arch = $arch.Substring(0, 4000) + "`n...[truncated]" }
      [void]$sb.AppendLine($arch)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 3) goals.md
  $goalsPath = Join-Path (Get-BridgeRoot) 'goals.md'
  if (Test-Path $goalsPath) {
    [void]$sb.AppendLine('=== goals.md (north-star) ===')
    try {
      $gc = [System.IO.File]::ReadAllText($goalsPath, [System.Text.Encoding]::UTF8)
      if ($gc.Length -gt 2000) { $gc = $gc.Substring(0, 2000) + "`n...[truncated]" }
      [void]$sb.AppendLine($gc)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 4) failures patterns (last week, top 8)
  [void]$sb.AppendLine('=== RECURRING FAILURE CLASSES (last 7d) ===')
  try {
    $pats = @(Get-FailurePatterns -WindowHours ($WindowDays * 24) -TopN 8)
    if ($pats.Count -eq 0) { [void]$sb.AppendLine('(нет записанных классов сбоев)') }
    else { foreach ($p in $pats) { [void]$sb.AppendLine("- class=$($p.class) count=$($p.count)`n$($p.samples)") } }
  } catch { [void]$sb.AppendLine('(не удалось прочитать failures.jsonl)') }
  [void]$sb.AppendLine('')

  # 5) operator interventions (last 15)
  [void]$sb.AppendLine('=== OPERATOR INTERVENTIONS (recent 15) ===')
  [void]$sb.AppendLine('# Каждая запись = пользователь пришёл и попросил исправить/объяснить — это implicit-сигнал "мост сам не справился".')
  try {
    $ints = @(Get-OperatorInterventions -Limit 15)
    if ($ints.Count -eq 0) { [void]$sb.AppendLine('(пусто)') }
    else { foreach ($i in $ints) { [void]$sb.AppendLine("- [seq $($i.seq)] marker=«$($i.marker)»: $($i.snippet)") } }
  } catch { [void]$sb.AppendLine('(error)') }
  [void]$sb.AppendLine('')

  # 6) recent metrics snapshot
  [void]$sb.AppendLine('=== METRICS (last snapshot) ===')
  try {
    $snap = Get-LastMetricsSnapshot
    if ($snap) {
      $bPct = [Math]::Round([double]$snap.timeout_pct * 100, 1)
      $sPct = [Math]::Round([double]$snap.success_pct * 100, 1)
      [void]$sb.AppendLine("turns=$($snap.total_turns) timeout=$bPct% success=$sPct% avg_sec=$($snap.avg_sec)")
    } else { [void]$sb.AppendLine('(нет snapshot)') }
  } catch {}
  [void]$sb.AppendLine('')

  # 7) latest radar digest (top 3 items)
  $radarPath = Join-Path (Get-BridgeRoot) 'radar\digest.md'
  if (Test-Path $radarPath) {
    [void]$sb.AppendLine('=== RADAR DIGEST (latest, top of file) ===')
    try {
      $rd = [System.IO.File]::ReadAllText($radarPath, [System.Text.Encoding]::UTF8)
      if ($rd.Length -gt 2500) { $rd = $rd.Substring(0, 2500) + "`n...[truncated]" }
      [void]$sb.AppendLine($rd)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 8) external systems for comparison
  $extPath = Get-ArchitectExternalSystemsPath
  if (Test-Path $extPath) {
    [void]$sb.AppendLine('=== EXTERNAL AI SYSTEMS (для сравнения) ===')
    try {
      $ext = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
      if ($ext.Length -gt 3500) { $ext = $ext.Substring(0, 3500) + "`n...[truncated]" }
      [void]$sb.AppendLine($ext)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 9) open architect-tagged ideas (avoid duplicate proposals)
  [void]$sb.AppendLine('=== УЖЕ В БЭКЛОГЕ как architect-идеи (НЕ ПРЕДЛАГАЙ ПОВТОРНО) ===')
  try {
    $open = @(Get-Backlog | Where-Object {
      $st = [string]$_.status
      $tags = @($_.tags | ForEach-Object { [string]$_ })
      ($tags -contains 'architect') -and ($st -in @('new','approved','running','inprogress'))
    })
    if ($open.Count -eq 0) { [void]$sb.AppendLine('(пусто)') }
    else { foreach ($o in $open) { [void]$sb.AppendLine('- ' + (([string]$o.text -replace '\s+',' ').Substring(0,[Math]::Min(200,([string]$o.text -replace '\s+',' ').Length)))) } }
  } catch { [void]$sb.AppendLine('(не удалось)') }
  [void]$sb.AppendLine('')

  return $sb.ToString()
}

function Build-ArchitectPrompt {
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal', [int]$MaxIdeas = 3)
  $ctx = Get-ArchitectContext
  $modeIntro = if ($Mode -eq 'deep-think') {
    @"
РЕЖИМ: deep-think (раз в неделю). Открытый вопрос:
**Чем мост должен стать через 3 месяца, чтобы выжить и быть полезным?**
Думай шире обычной задачи: новые роли, новые подсистемы, новые источники сигнала,
new patterns из внешних систем. До $MaxIdeas структурных предложений.
"@
  } else {
    @"
РЕЖИМ: normal (плановый ход). Look-across-everything:
найди 1-$MaxIdeas архитектурных пробела на основе данных ниже.
"@
  }
  return @"
Ты — Архитектор моста Claude+Codex. Твоя единственная задача: **мета-уровень структурных
пробелов**, не leaf-tweaks. Reflect (leaf) уже работает рядом. Doctor (острый ремонт)
тоже. ТЫ смотришь на узоры через корпус и предлагаешь **новые механизмы / агенты /
подсистемы**, которых сейчас нет.

$modeIntro

ВАЖНЫЕ ЗАМЕЧАНИЯ:
- Если 3 разных post-mortem'а намекают на отсутствие капабилити X — это твой сигнал.
- Если оператор 3 раза вмешивался про одно и то же — это твой сигнал.
- Если внешняя система имеет паттерн, которого у нас нет, и оно объяснимо — это сигнал.
- НЕ предлагай мелкие фиксы (это работа reflect.ps1). НЕ предлагай уже сделанное (см. capability matrix и список выше).
- Опирайся ТОЛЬКО на данные ниже. Не выдумывай проблем "вообще".
- Каждая идея должна быть конкретной: что добавить (файл/модуль), как триггерится, какую метрику улучшит, на чём основана (post-mortem N, intervention M, и т.д.).

ДАННЫЕ:
$ctx

ВЕРНИ СТРОГО JSON-массив (без markdown), формата:
[
  {
    "text": "Полная формулировка идеи 1-2 предложения по-русски",
    "tags": ["architect", "<доп. короткие теги>"],
    "rationale": "На каких сигналах основана: <post-mortem/intervention/external/matrix-gap>",
    "value": N,
    "confidence": N,
    "effort": N
  }
]

value (1-5) = ценность для моста; confidence (1-5) = уверенность что сработает;
effort (1-5) = трудозатраты (1=просто, 5=сложно).
Если по данным ВСЁ в норме и серьёзных пробелов нет — верни пустой массив [].
"@
}

function Invoke-Architect {
  # Run one Architect reflection cycle. Returns hashtable with count + ids of created ideas.
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal', [int]$MaxIdeas = 3, [int]$TimeoutSec = 240)
  try { Add-Message -From system -Text ("🧭 Архитектор просыпается (режим: $Mode). Анализирую структурные пробелы...") -Kind event | Out-Null } catch {}
  $prompt = Build-ArchitectPrompt -Mode $Mode -MaxIdeas $MaxIdeas
  # Use deep-reasoning model purpose ('deep' -> deepseek-v4-pro by default;
  # operator can override to opus via config if desired).
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'deep' -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.3 } catch {}
  if ([string]::IsNullOrWhiteSpace($raw)) {
    try { Add-Message -From system -Text "🧭 Архитектор: LLM не ответил (пусто). Пропускаю цикл." -Kind event | Out-Null } catch {}
    return @{ ok = $false; count = 0; ids = @() }
  }
  $clean = ($raw -replace '```json','' -replace '```','').Trim()
  $m = [regex]::Match($clean, '(?s)\[.*\]')
  $ideas = @()
  if ($m.Success) { try { $ideas = @($m.Value | ConvertFrom-Json) } catch {} }
  if (-not $ideas -or $ideas.Count -eq 0) {
    try { Add-Message -From system -Text "🧭 Архитектор: структурных пробелов не вижу (или данные не дали зацепиться). Цикл закрыт без идей." -Kind event | Out-Null } catch {}
    return @{ ok = $true; count = 0; ids = @() }
  }
  $created = New-Object 'System.Collections.Generic.List[string]'
  foreach ($it in $ideas) {
    $text = [string]$it.text
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $tags = @('architect')
    try {
      if ($it.tags) {
        foreach ($t in @($it.tags)) {
          $ts = [string]$t
          if (-not [string]::IsNullOrWhiteSpace($ts) -and -not ($tags -contains $ts)) { $tags += $ts }
        }
      }
    } catch {}
    $rationale = [string]$it.rationale
    if (-not [string]::IsNullOrWhiteSpace($rationale)) { $text = $text + "`n_Основа:_ " + $rationale }
    $score = 0.0
    try {
      $v = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.value))
      $c = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.confidence))
      $e = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.effort))
      $score = [Math]::Round($v * $c / $e, 2)
    } catch {}
    $id = Add-Idea -Text $text -From 'architect' -Tags $tags -Status 'new' -Score $score
    if ($id) { [void]$created.Add([string]$id) }
  }
  if ($created.Count -gt 0) {
    try { Add-Message -From system -Text ("🧭 Архитектор: предложено " + $created.Count + " структурных идей в бэклог (тег: architect, status=new — нужно одобрение).") -Kind event | Out-Null } catch {}
  }
  return @{ ok = $true; count = $created.Count; ids = @($created.ToArray()) }
}

function Should-RunArchitect {
  # Cron-style gate: at least 24h since last + at least 10 closed user tasks since last
  # (delta). Either condition is enough; both can fire.
  $lastTs = $null
  $marker = Get-ArchitectMarkerPath
  if (Test-Path $marker) { try { $lastTs = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  if (-not $lastTs) { return $true }   # never ran -> due
  $age = (Get-Date) - $lastTs
  if ($age -ge [TimeSpan]::FromHours(24)) { return $true }
  # delta-trigger: 10 closed user tasks since last
  $lastCount = -1
  $cmkr = Get-ArchitectCountMarkerPath
  if (Test-Path $cmkr) { try { $lastCount = [int]((Get-Content $cmkr -Raw -Encoding UTF8).Trim()) } catch {} }
  if ($lastCount -ge 0) {
    $curCount = 0
    try { $curCount = @(Get-Backlog | Where-Object { [string]$_.status -eq 'done' }).Count } catch {}
    if (($curCount - $lastCount) -ge 10) { return $true }
  }
  return $false
}

function Save-ArchitectMarker {
  # Update last-run timestamp + the done-task baseline for delta trigger.
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-ArchitectMarkerPath), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $doneN = 0
    try { $doneN = @(Get-Backlog | Where-Object { [string]$_.status -eq 'done' }).Count } catch {}
    [System.IO.File]::WriteAllText((Get-ArchitectCountMarkerPath), [string]$doneN, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Start-ArchitectIfDue {
  # Called from driver idle loop. Honors autonomy.enabled and Should-RunArchitect.
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal')
  try {
    $auto = Get-AutonomySettings
    if (-not [bool]$auto.enabled) { return }
  } catch {}
  if (-not (Should-RunArchitect)) { return }
  Save-ArchitectMarker   # Touch marker BEFORE running so we don't relaunch every idle tick.
  try { Invoke-Architect -Mode $Mode -MaxIdeas 3 | Out-Null } catch { try { Add-Message -From system -Text ("🧭 Архитектор: ошибка цикла: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
}

function Get-DeepThinkMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.deepthink.last' }

function Test-WithinQuietHours {
  # Alarm-clock-style gate: runs ONLY in the user's deep-sleep window. User feedback
  # 2026-05-26: heavy tasks should fire by clock, not by timer ("я бы не привязывался к
  # таймеру, а именно по будильнику включал, когда пользователь точно спит — 2-6 утра").
  param([int]$StartHour = 2, [int]$EndHour = 6, [string[]]$DaysOfWeek = @())
  $now = Get-Date
  if ($DaysOfWeek.Count -gt 0 -and -not ($DaysOfWeek -contains $now.DayOfWeek.ToString())) { return $false }
  $h = $now.Hour
  return ($h -ge $StartHour -and $h -lt $EndHour)
}

function Should-RunDeepThink {
  # TWO weekend nights (Saturday + Sunday morning 02:00-06:00 local). Fires once per
  # window, max one deep-think per 6 days (so two firings per weekend are de-duped).
  if (-not (Test-WithinQuietHours -StartHour 2 -EndHour 6 -DaysOfWeek @('Saturday','Sunday'))) { return $false }
  $marker = Get-DeepThinkMarkerPath
  if (-not (Test-Path $marker)) { return $true }
  try { $last = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch { return $true }
  return ((Get-Date) - $last) -ge [TimeSpan]::FromDays(6)
}

function Start-DeepThinkDialog {
  # Inject a deep-think user task with the [[DEEP-THINK]] marker. The driver picks it up
  # and forces task_mode='discuss' so Claude+Codex bounce ideas back and forth (not a
  # single Opus monologue). Convergence cap is enforced by the existing discuss-mode max
  # turns. After STATUS: DONE the planner files 1-3 ideas via the normal pipeline.
  $ctx = Get-ArchitectContext
  $prompt = @"
[[DEEP-THINK]] Архитектурная мета-задача (раз в неделю в выходную ночь).

ОТКРЫТЫЙ ВОПРОС: чем мост должен стать через 3 месяца, чтобы выжить и быть полезным?

ПРАВИЛА ДИАЛОГА (важно):
- Claude (планировщик) НАЧИНАЕТ: предлагает 1-3 структурных идеи с обоснованием. STATUS: DISCUSS.
- Codex АКТИВНО КРИТИКУЕТ: что не сработает, какие риски, какие альтернативы есть, почему. Не соглашается из вежливости.
- Claude отвечает на критику: либо защищает (с дополнительными доводами), либо МЕНЯЕТ позицию (если убедили).
- Минимум 3 хода discuss, максимум 6. Если за 6 ходов не сошлись — Claude выбирает самый сильный вариант сам.
- На сходимости — STATUS: DONE с блоком `## ИТОГ` и 1-3 финальными идеями, прошедшими критику. Каждую идею — отдельной строкой в формате `IDEA: <текст>` (driver разберёт и положит в беклог с тегом architect+deep-think).

ЦЕЛЬ ДИАЛОГА — не «выработать общую позицию через компромисс», а **посмотреть на идею с разных сторон**, проверить её устойчивость. Если идея слабая — отбросить, найти лучше.

КОНТЕКСТ (общий для обоих агентов):
$ctx
"@
  try { Add-Message -From user -Text $prompt | Out-Null } catch {}
  try { Add-Message -From system -Text "🧭💭 Deep-think dialog запущен (Claude↔Codex; discuss-mode, max 6 ходов до сходимости). Это раз в неделю в ночное окно — продолжай работу, я не помешаю." -Kind event | Out-Null } catch {}
}

function Start-DeepThinkIfDue {
  # Weekly weekend-night dialog. Alarm-clock trigger (Sat/Sun 02-06 AM local), not interval.
  try {
    $auto = Get-AutonomySettings
    if (-not [bool]$auto.enabled) { return }
  } catch {}
  if (-not (Should-RunDeepThink)) { return }
  # Save marker BEFORE injection so we don't re-fire in the same hour window.
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-DeepThinkMarkerPath), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try { Start-DeepThinkDialog } catch { try { Add-Message -From system -Text ("🧭 Deep-think: ошибка: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
}
