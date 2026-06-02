# scholar.ps1 -- Autonomous Scholar: deep-read external articles, follow key links,
# assess usefulness AGAINST the bridge's current gaps, and file ideas/knowledge.
#
# WHY: the old radar judged articles by RSS title+summary only -> 0 ideas in 329 backlog
# items. This reads the FULL text (+ key links) via the Claude research agent (WebFetch/
# WebSearch), and scores relevance against what actually HURTS the bridge right now
# (failure classes) and what it already HAS (feature registry) -- so an article only
# yields an idea if it closes a real gap. Funnel: cheap filter -> deep read -> match -> synth.
#
# STAGE 1 (this file): Get-ScholarGaps + Build-ScholarPrompt + Invoke-ArticleStudy (ONE article).
# STAGE 2 (next): Invoke-ScholarRun (batch top-N + dedup + file), Start-ScholarIfDue (autonomy).

function Get-ScholarGaps {
  # Compact "what hurts + what we already have" snapshot, so the reader matches articles to
  # REAL needs, not generic "interesting for AI". Kept short to leave room for the article text.
  $sb = New-Object System.Text.StringBuilder
  # 1) what hurts -- recurring failure classes (the bridge's live pain)
  try {
    if (Get-Command Get-FailurePatterns -ErrorAction SilentlyContinue) {
      $pats = @(Get-FailurePatterns -WindowHours 168 -TopN 6)
      if ($pats.Count -gt 0) {
        [void]$sb.AppendLine('БОЛИТ СЕЙЧАС (классы сбоев за 7д -- идеи под них особенно ценны):')
        foreach ($p in $pats) { [void]$sb.AppendLine('- ' + [string]$p.class + ' x' + [string]$p.count) }
      }
    }
  } catch {}
  # 2) what the bridge WANTS to improve -- open architect ideas + dev directions, so articles can
  #    match a real improvement TARGET, not only failure classes. Recall quality / durability /
  #    orchestration are genuine gaps even when not in the failure log.
  try {
    $openArch = @(Get-Backlog | Where-Object { (@($_.tags | ForEach-Object { [string]$_ }) -contains 'architect') -and ([string]$_.status -in @('new', 'approved')) } | Select-Object -First 5)
    if ($openArch.Count -gt 0) {
      [void]$sb.AppendLine('')
      [void]$sb.AppendLine('МОСТ ХОЧЕТ УЛУЧШИТЬ (открытые идеи -- статьи под эти темы особенно ценны):')
      foreach ($o in $openArch) { $t = ([string]$o.text -replace '\s+', ' '); if ($t.Length -gt 110) { $t = $t.Substring(0, 110) }; [void]$sb.AppendLine('- ' + $t) }
    }
  } catch {}
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('НАПРАВЛЕНИЯ РАЗВИТИЯ (приём ценен и тянет на "idea", ЕСЛИ ложится на PowerShell/CLI-стек без Python-ML): надёжность/durability состояния, КАЧЕСТВО recall vector-памяти (reranking, confidence-оценка достаточности, query-expansion), оркестрация агентов, скорость/latency LLM-вызовов, восстановление после сбоёв, автономность.')

  # 3) what we already have -- feature names from the registry (avoid proposing duplicates)
  try {
    $regPath = Join-Path (Get-BridgeRoot) 'features\registry.json'
    if (Test-Path -LiteralPath $regPath) {
      $parsed = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $feats = @($parsed)
      $names = @($feats | ForEach-Object { [string]$_.name } | Where-Object { $_ })
      if ($names.Count -gt 0) { [void]$sb.AppendLine(''); [void]$sb.AppendLine('УЖЕ ЕСТЬ (НЕ предлагай дубли): ' + ($names -join ' · ')) }
    }
  } catch {}
  return $sb.ToString()
}

function Build-ScholarPrompt {
  param([string]$Url, [string]$Title, [string]$Gaps)
  return @"
Ты — исследователь-аналитик автономного моста Claude+Codex (стек: PowerShell/Windows; агент:
планировщик Claude -> кодер Codex; vector-память с recall; backlog задач; ночной само-аудит;
авто-исполнение задач по tier'ам). Твоя задача — оценить, поможет ли статья УЛУЧШИТЬ САМ МОСТ.

ПРОБЕЛЫ И БОЛИ МОСТА СЕЙЧАС (с этим сопоставляй полезность — не "интересно вообще", а "решает НАШУ боль"):
$Gaps

СТАТЬЯ ДЛЯ ИЗУЧЕНИЯ:
  URL: $Url
  Заголовок: $Title

ШАГИ (делай именно так):
1. WebFetch по URL — прочитай ПОЛНЫЙ текст статьи, не аннотацию.
2. Если в тексте есть 1-2 КЛЮЧЕВЫЕ ссылки или инструменты, раскрывающие важный паттерн (например
   реализация приёма, документация инструмента) — пройди по ним через WebFetch. Не более 2 переходов.
3. Извлеки КОНКРЕТНЫЕ применимые приёмы/механизмы (как именно работает), а не общие тезисы.
4. Сопоставь с пробелами моста выше: закрывает ли это РЕАЛЬНУЮ боль? применимо ли к нашему стеку
   (PowerShell/Windows, Claude+Codex, файловое состояние)? не дубль ли того, что уже есть?

ВЕРДИКТ — выбери РОВНО ОДИН:
- "idea"      — есть конкретный приём под РЕАЛЬНЫЙ пробел моста. Сформулируй actionable-идею:
                ЧТО добавить (какой файл/модуль моста), КАКОЙ пробел закрывает, КАКАЯ метрика улучшится.
- "knowledge" — полезно для понимания (паттерн/предостережение), но не немедленная задача.
                Сформулируй 1-2 фразы знания для памяти моста.
- "skip"      — неприменимо к нашему стеку, вода, или уже реализовано в мосте.

Верни СТРОГО JSON (без markdown, без преамбулы), формат:
{ "verdict": "idea|knowledge|skip", "idea": "<если idea: что добавить · в какой файл · какой пробел · метрика>", "knowledge": "<если knowledge: 1-2 фразы>", "rationale": "<почему этот вердикт, с привязкой к конкретному пробелу моста>", "pattern": "<краткое имя приёма>", "links_followed": ["<url если ходил по ссылкам>"] }
"@
}

function Invoke-ArticleStudy {
  # CORE: deep-study ONE article via the Claude research agent (WebFetch/WebSearch enabled).
  # Returns the parsed verdict object, or $null on failure/timeout (fail-soft, never throws).
  param([string]$Url, [string]$Title = '', [string]$Gaps = '', [int]$TimeoutSec = 200)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  $claudeExe = $null
  try { $claudeExe = Resolve-ClaudeExe (Get-BridgeConfig) } catch { return $null }
  if (-not $claudeExe) { return $null }
  if ([string]::IsNullOrWhiteSpace($Gaps)) { try { $Gaps = Get-ScholarGaps } catch {} }
  $prompt = Build-ScholarPrompt -Url $Url -Title $Title -Gaps $Gaps
  $tmpBase = Join-Path $env:TEMP ('scholar_' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
  $inF = "$tmpBase.in"; $outF = "$tmpBase.out"; $errF = "$tmpBase.err"
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $utf8)
  # research-mode toolset: web reading, no Bash/Edit (read-only investigation).
  $claudeArgs = @('-p','--permission-mode','acceptEdits','--allowedTools','Read','Grep','Glob','WebSearch','WebFetch','--model','sonnet')
  $raw = ''
  try {
    $spawn = { Start-Process -FilePath $claudeExe -ArgumentList $claudeArgs -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru }
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
      $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action $spawn
    } else { $p = & $spawn }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return $null }
    if (Test-Path -LiteralPath $outF) { $raw = [System.IO.File]::ReadAllText($outF, [System.Text.Encoding]::UTF8) }
  } catch { return $null }
  finally { Remove-Item -LiteralPath $inF, $outF, $errF -Force -ErrorAction SilentlyContinue }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $clean = ($raw -replace '```json', '' -replace '```', '').Trim()
  $mm = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mm.Success) { return $null }
  $verdict = $null
  try { $verdict = $mm.Value | ConvertFrom-Json } catch { return $null }
  return $verdict
}

# ───────── DeepSeek-flash variant: bridge fetches text, flash analyses (cheap, no web agent) ─────────
# DeepSeek (api.deepseek.com) is chat-only -- no WebFetch. So the BRIDGE downloads the article text
# (free Invoke-WebRequest) + follows a couple of links itself, then flash does the reasoning cheaply.
# Trade-off vs the Claude variant: much cheaper per article, but link-following is bridge-driven
# (regex extract) rather than the agent deciding. Good for the wide/cheap first pass of the funnel.

function Get-ArticleText {
  # Download a URL and strip HTML to readable text (bridge-side, no LLM). Caps length.
  param([string]$Url, [int]$MaxChars = 12000)
  try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 3
    $html = [string]$resp.Content
    $html = $html -replace '(?s)<script.*?</script>', ' ' -replace '(?s)<style.*?</style>', ' '
    $text = $html -replace '(?s)<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + ' …[обрезано]' }
    return $text
  } catch { return '' }
}

function Get-ArticleLinks {
  # Extract up to $Max external content links from an article (to follow them). Skips nav/asset/utm noise.
  param([string]$Url, [int]$Max = 2)
  try {
    $html = [string](Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30).Content
    $links = @([regex]::Matches($html, 'href="(https?://[^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
      Where-Object { $_ -notmatch '(?i)habr\.com|utm_|\.css|\.js|\.png|\.jpg|\.svg|/comments|javascript:|facebook|twitter|t\.me|vk\.com' } |
      Select-Object -Unique | Select-Object -First $Max)
    return $links
  } catch { return @() }
}

function Build-ScholarFlashPrompt {
  param([string]$Url, [string]$Title, [string]$Gaps, [string]$Body, [string]$LinkText)
  $linkBlock = if ([string]::IsNullOrWhiteSpace($LinkText)) { '(ссылки не извлекались)' } else { $LinkText }
  return @"
Ты — исследователь-аналитик автономного моста Claude+Codex (PowerShell/Windows; планировщик Claude ->
кодер Codex; vector-память; backlog; ночной само-аудит). Оцени, поможет ли статья УЛУЧШИТЬ САМ МОСТ.

ПРОБЕЛЫ/БОЛИ МОСТА (сопоставляй с этим -- "решает НАШУ боль", а не "интересно вообще"):
$Gaps

СТАТЬЯ (полный текст уже скачан для тебя -- читай его, а не аннотацию):
  URL: $Url
  Заголовок: $Title
  ТЕКСТ:
$Body

ТЕКСТ ПО КЛЮЧЕВЫМ ССЫЛКАМ ИЗ СТАТЬИ:
$linkBlock

ЗАДАЧА: извлеки КОНКРЕТНЫЕ применимые приёмы/механизмы; сопоставь с пробелами моста.

ЖЁСТКИЕ ПРАВИЛА (против ложных идей -- нарушишь = мусор в бэклоге):
1. НЕ ВЫДУМЫВАЙ проблему моста. Опирайся ТОЛЬКО на список пробелов/болей выше. Если статья не бьёт
   прямо в один из НИХ -- это "knowledge" или "skip", НИКОГДА не "idea".
2. ПРОВЕРЬ СТЕК. Мост — это PowerShell-скрипты на Windows, оркестрирующие Claude+Codex CLI. У него
   НЕТ: Python-ML-рантайма, GPU, локальных моделей, тяжёлых сервисов (Qdrant/векторных БД своих,
   контейнеров). Если приём ТРЕБУЕТ Python-библиотеку, GPU, обучение/инференс ML-модели, внешний
   демон — он НЕприменим напрямую -> максимум "knowledge", НЕ "idea".
3. "idea" допустима ТОЛЬКО если приём реально ложится на PowerShell/CLI-стек И закрывает указанную
   боль. Малейшее сомнение в применимости -> "knowledge".

Вердикт -- РОВНО один:
- "idea"      -> приём ложится на наш стек И закрывает УКАЗАННУЮ боль: что добавить (файл/модуль), какой пробел, метрика.
- "knowledge" -> полезно для понимания ИЛИ требует чужого стека (Python/GPU/ML): 1-2 фразы знания.
- "skip"      -> неприменимо/вода/уже есть.

Верни СТРОГО JSON (без markdown):
{ "verdict":"idea|knowledge|skip", "idea":"...", "knowledge":"...", "rationale":"<привязка к пробелу>", "pattern":"<имя приёма>" }
"@
}

function Invoke-ArticleStudyFlash {
  # Cheap variant: bridge downloads text (+links), DeepSeek-flash does the reasoning. Returns verdict or $null.
  param([string]$Url, [string]$Title = '', [string]$Gaps = '', [int]$TimeoutSec = 70, [int]$FollowLinks = 2)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  if ([string]::IsNullOrWhiteSpace($Gaps)) { try { $Gaps = Get-ScholarGaps } catch {} }
  $body = Get-ArticleText -Url $Url
  if ([string]::IsNullOrWhiteSpace($body)) { return $null }
  $linkText = ''
  if ($FollowLinks -gt 0) {
    foreach ($l in (Get-ArticleLinks -Url $Url -Max $FollowLinks)) {
      $lt = Get-ArticleText -Url $l -MaxChars 4000
      if ($lt) { $linkText += "`n[ссылка: $l]`n$lt`n" }
    }
  }
  $prompt = Build-ScholarFlashPrompt -Url $Url -Title $Title -Gaps $Gaps -Body $body -LinkText $linkText
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'reflect' -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.2 } catch { return $null }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $clean = ($raw -replace '```json', '' -replace '```', '').Trim()
  $mm = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mm.Success) { return $null }
  try { return $mm.Value | ConvertFrom-Json } catch { return $null }
}

# ───────── ACTIVE PULL — search the web for solutions to the bridge's OWN pains ─────────
# This is the "research, don't browse" half: the bridge turns its failure classes / open gaps into
# concrete web queries, then a Claude research agent searches + reads + synthesises an idea that
# fits OUR stack. Complements the passive RSS pass (which yields knowledge for brainstorm fuel).

function Get-ScholarQuestions {
  # flash turns the bridge's pains into concrete English web-search queries (cheap).
  param([int]$Max = 2)
  $gaps = ''; try { $gaps = Get-ScholarGaps } catch {}
  if ([string]::IsNullOrWhiteSpace($gaps)) { return @() }
  $prompt = @"
Боли и направления развития моста (PowerShell/Windows; агент: планировщик Claude -> кодер Codex; vector-память):
$gaps

Сформулируй $Max КОНКРЕТНЫХ англоязычных поисковых запроса (для web-поиска) под САМЫЕ острые боли/пробелы,
чтобы найти ПРИМЕНИМЫЕ к нашему стеку решения (НЕ Python-ML/GPU). Каждый -- готовая строка для поиска.
Верни СТРОГО JSON-массив строк: ["query one", "query two"]
"@
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'reflect' -Prompt $prompt -TimeoutSec 40 -Temperature 0.3 } catch {}
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $clean = ($raw -replace '```json', '' -replace '```', '').Trim()
  $mm = [regex]::Match($clean, '(?s)\[.*\]')
  if (-not $mm.Success) { return @() }
  try { return @(($mm.Value | ConvertFrom-Json) | Where-Object { $_ } | Select-Object -First $Max) } catch { return @() }
}

function Build-ScholarSearchPrompt {
  param([string]$Question, [string]$Gaps)
  return @"
Ты — исследователь автономного моста Claude+Codex (PowerShell/Windows; планировщик->кодер; vector-память).
ВОПРОС/БОЛЬ для исследования: $Question

ПРОБЕЛЫ МОСТА (контекст для оценки применимости):
$Gaps

ШАГИ:
1. WebSearch по вопросу -- найди 2-3 релевантных источника (статьи, доки, обсуждения).
2. WebFetch топ-1-2 -- прочитай ПОЛНЫЙ текст, извлеки КОНКРЕТНЫЙ приём решения.
3. СТЕК-ГЕЙТ: мост на PowerShell/CLI, без Python-ML/GPU/тяжёлых сервисов. Приём, требующий чужого
   стека -> "knowledge", НЕ "idea". "idea" -- только если ложится на PowerShell/CLI И решает боль.

Верни СТРОГО JSON (без markdown):
{ "verdict":"idea|knowledge|skip", "idea":"что добавить · в какой файл моста · какой пробел · метрика", "knowledge":"1-2 фразы", "rationale":"<привязка к боли>", "pattern":"<имя приёма>", "source":"<url>" }
"@
}

function Invoke-ScholarSearch {
  # Active pull: a Claude research agent searches the web for a bridge pain and synthesises a verdict.
  param([string]$Question, [string]$Gaps = '', [int]$TimeoutSec = 220)
  if ([string]::IsNullOrWhiteSpace($Question)) { return $null }
  $claudeExe = $null; try { $claudeExe = Resolve-ClaudeExe (Get-BridgeConfig) } catch { return $null }
  if (-not $claudeExe) { return $null }
  if ([string]::IsNullOrWhiteSpace($Gaps)) { try { $Gaps = Get-ScholarGaps } catch {} }
  $prompt = Build-ScholarSearchPrompt -Question $Question -Gaps $Gaps
  $tmpBase = Join-Path $env:TEMP ('scholarsearch_' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
  $inF = "$tmpBase.in"; $outF = "$tmpBase.out"; $errF = "$tmpBase.err"
  [System.IO.File]::WriteAllText($inF, $prompt, (New-Object System.Text.UTF8Encoding($false)))
  $claudeArgs = @('-p', '--permission-mode', 'acceptEdits', '--allowedTools', 'Read', 'Grep', 'Glob', 'WebSearch', 'WebFetch', '--model', 'sonnet')
  $raw = ''
  try {
    $spawn = { Start-Process -FilePath $claudeExe -ArgumentList $claudeArgs -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru }
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) { $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action $spawn } else { $p = & $spawn }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return $null }
    if (Test-Path -LiteralPath $outF) { $raw = [System.IO.File]::ReadAllText($outF, [System.Text.Encoding]::UTF8) }
  } catch { return $null }
  finally { Remove-Item -LiteralPath $inF, $outF, $errF -Force -ErrorAction SilentlyContinue }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $clean = ($raw -replace '```json', '' -replace '```', '').Trim()
  $mm = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mm.Success) { return $null }
  try { return $mm.Value | ConvertFrom-Json } catch { return $null }
}

function Format-ScholarKnowledgeForPrompt {
  # Render recent accumulated knowledge for injection into the Architect/brainstorm prompt -- so the
  # bridge gets "inspired by border-line findings" exactly as the operator asked.
  param([int]$Last = 8)
  $kp = Get-ScholarKnowledgePath
  if (-not (Test-Path -LiteralPath $kp)) { return '' }
  $entries = @()
  try { $entries = @(Get-Content -LiteralPath $kp -Encoding UTF8 | Where-Object { $_ } | Select-Object -Last $Last) } catch { return '' }
  if ($entries.Count -eq 0) { return '' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('=== ЗНАНИЯ ИЗ ВНЕШНИХ ИСТОЧНИКОВ (Scholar -- приёмы из статей; вдохновись, если ложится на наш стек) ===')
  foreach ($e in $entries) {
    try { $o = $e | ConvertFrom-Json; $t = ([string]$o.text -replace '\s+', ' '); if ($t.Length -gt 220) { $t = $t.Substring(0, 220) + '…' }; [void]$sb.AppendLine('- ' + $t) } catch {}
  }
  return $sb.ToString()
}

# ───────── STAGE 2 — orchestration + autonomy ─────────

function Get-ScholarSeenPath      { Join-Path (Get-BridgeRoot) 'radar\scholar-seen.jsonl' }
function Get-ScholarKnowledgePath { Join-Path (Get-BridgeRoot) 'radar\scholar-knowledge.jsonl' }
function Get-ScholarLastPath      { Join-Path (Get-BridgeRoot) 'radar\scholar.last' }

function Get-ScholarSeenUrls {
  # Set of URLs already studied (any verdict) -- so we never re-read the same article.
  $h = @{}
  $p = Get-ScholarSeenPath
  if (Test-Path -LiteralPath $p) {
    foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $o = $line | ConvertFrom-Json; if ($o.url) { $h[[string]$o.url] = 1 } } catch {}
    }
  }
  return $h
}

function Add-ScholarSeen {
  param([string]$Url, [string]$Verdict)
  try {
    $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); url = [string]$Url; verdict = [string]$Verdict }
    $line = ($rec | ConvertTo-Json -Compress)
    Add-Content -LiteralPath (Get-ScholarSeenPath) -Value $line -Encoding UTF8
  } catch {}
}

function Add-ScholarKnowledge {
  # Knowledge goes to a durable jsonl (later injected into the architect/scholar context).
  param([string]$Text, [string]$Url, [string]$Pattern)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  try {
    $rec = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); pattern = [string]$Pattern; text = [string]$Text; source = [string]$Url }
    Add-Content -LiteralPath (Get-ScholarKnowledgePath) -Value ($rec | ConvertTo-Json -Compress) -Encoding UTF8
  } catch {}
}

function Invoke-ScholarRun {
  # Orchestrate one Scholar pass: take top-N radar candidates -> flash reads each -> idea (Claude-
  # verified) into backlog, knowledge into the knowledge log, dedup by URL. Returns a summary.
  param([int]$MaxArticles = 4, [int]$FollowLinks = 1, [bool]$VerifyIdeasWithClaude = $true, [int]$MaxAgeDays = 21, [int]$SearchQuestions = 2)
  $run = $null
  try { $run = Get-RadarLatestRun } catch {}
  if (-not $run) { return @{ ok = $false; reason = 'no-radar-run'; studied = 0 } }
  $items = @(@($run.items) | Sort-Object { -1 * ([double]([string]$_.value -replace '[^\d.]', '0')) })
  if ($items.Count -eq 0) { return @{ ok = $false; reason = 'no-items'; studied = 0 } }
  $gaps = ''; try { $gaps = Get-ScholarGaps } catch {}
  $seen = Get-ScholarSeenUrls
  $studied = 0; $ideas = 0; $knowledge = 0; $skipped = 0
  try { Add-Message -From system -Text ('📚 Scholar просыпается: ищу решения болей в web (active) + изучаю до ' + $MaxArticles + ' статей из радара (passive).') -Kind event | Out-Null } catch {}
  # PHASE 1 (ACTIVE PULL): search the web for solutions to the bridge's OWN pains -- this is where
  # ideas under our stack come from (vs the RSS pass which is mostly knowledge fuel).
  $searched = 0
  if ($SearchQuestions -gt 0) {
    $questions = @(); try { $questions = @(Get-ScholarQuestions -Max $SearchQuestions) } catch {}
    foreach ($q in $questions) {
      $sv = $null; try { $sv = Invoke-ScholarSearch -Question $q -Gaps $gaps } catch {}
      $searched++
      if (-not $sv) { continue }
      $sVerdict = ([string]$sv.verdict).Trim().ToLower()
      if ($sVerdict -eq 'idea' -and $sv.idea) {
        $txt = '[scholar/поиск под боль: ' + $q + '] ' + [string]$sv.idea
        if ($sv.source) { $txt += "`nИсточник: " + [string]$sv.source }
        $id = $null; try { $id = Add-Idea -Text $txt -From 'scholar' -Tags @('scholar', 'external', 'active-search') -Status 'new' } catch {}
        if ($id) { $ideas++ }
      }
      elseif ($sVerdict -eq 'knowledge' -and $sv.knowledge) { Add-ScholarKnowledge -Text ([string]$sv.knowledge) -Url ([string]$sv.source) -Pattern ([string]$sv.pattern); $knowledge++ }
    }
  }
  # PHASE 2 (PASSIVE): read fresh RSS candidates -> mostly knowledge (brainstorm fuel), occasional idea.
  foreach ($it in $items) {
    if ($studied -ge $MaxArticles) { break }
    $url = [string]$it.link
    if ([string]::IsNullOrWhiteSpace($url) -or $seen.ContainsKey($url)) { continue }
    # freshness gate: only articles published within MaxAgeDays -- stale tech info is worse than none.
    $pub = [string]$it.published
    if (-not [string]::IsNullOrWhiteSpace($pub)) {
      $pubDate = [datetime]::MinValue
      if ([datetime]::TryParse($pub, [ref]$pubDate)) {
        if (((Get-Date).ToUniversalTime() - $pubDate.ToUniversalTime()).TotalDays -gt $MaxAgeDays) { continue }
      }
    }
    $title = [string]$it.title
    $v = $null
    try { $v = Invoke-ArticleStudyFlash -Url $url -Title $title -Gaps $gaps -FollowLinks $FollowLinks } catch {}
    $studied++
    if (-not $v) { Add-ScholarSeen -Url $url -Verdict 'error'; continue }
    $verdict = ([string]$v.verdict).Trim().ToLower()
    if ($verdict -eq 'idea') {
      $ideaText = [string]$v.idea
      # Claude double-check: flash idea is cheap but spam-prone; Claude verifies before backlog.
      if ($VerifyIdeasWithClaude) {
        $cv = $null
        try { $cv = Invoke-ArticleStudy -Url $url -Title $title -Gaps $gaps -TimeoutSec 200 } catch {}
        if ($cv) {
          $cVerdict = ([string]$cv.verdict).Trim().ToLower()
          if ($cVerdict -ne 'idea') {
            # flash over-claimed -> downgrade
            if ($cv.knowledge) { Add-ScholarKnowledge -Text ([string]$cv.knowledge) -Url $url -Pattern ([string]$v.pattern); $knowledge++ }
            Add-ScholarSeen -Url $url -Verdict ('flash-idea->claude-' + $cVerdict)
            continue
          }
          if ($cv.idea) { $ideaText = [string]$cv.idea }   # use Claude's refined formulation
        }
      }
      $txt = '[scholar/внешний источник] ' + $ideaText + "`nИсточник: " + $url
      $id = $null
      try { $id = Add-Idea -Text $txt -From 'scholar' -Tags @('scholar', 'external', 'radar-derived') -Status 'new' } catch {}
      if ($id) { $ideas++ }
      Add-ScholarSeen -Url $url -Verdict 'idea'
    }
    elseif ($verdict -eq 'knowledge') {
      if ($v.knowledge) { Add-ScholarKnowledge -Text ([string]$v.knowledge) -Url $url -Pattern ([string]$v.pattern); $knowledge++ }
      Add-ScholarSeen -Url $url -Verdict 'knowledge'
    }
    else { $skipped++; Add-ScholarSeen -Url $url -Verdict 'skip' }
  }
  try { Add-Message -From system -Text ('📚 Scholar закончил: web-поисков ' + $searched + ' · изучено статей ' + $studied + ' · идей в бэклог ' + $ideas + ' · знаний ' + $knowledge + ' · пропущено ' + $skipped + '.') -Kind event | Out-Null } catch {}
  return @{ ok = $true; searched = $searched; studied = $studied; ideas = $ideas; knowledge = $knowledge; skipped = $skipped }
}

function Start-ScholarIfDue {
  # Autonomous trigger: run Scholar at most once per FloorHours, in a night window. Marker: radar\scholar.last.
  # This is the replacement for the broken radar auto-idea path -- radar collects RSS, Scholar reads+judges.
  param([int]$FloorHours = 24, [int]$WindowStartHour = 1, [int]$WindowEndHour = 6, [int]$MaxArticles = 4)
  $hour = (Get-Date).Hour
  $inWindow = if ($WindowStartHour -le $WindowEndHour) { ($hour -ge $WindowStartHour -and $hour -le $WindowEndHour) } else { ($hour -ge $WindowStartHour -or $hour -le $WindowEndHour) }
  if (-not $inWindow) { return $false }
  $marker = Get-ScholarLastPath
  if (Test-Path -LiteralPath $marker) {
    try { $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim()); if (((Get-Date) - $last).TotalHours -lt $FloorHours) { return $false } } catch {}
  }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try { Invoke-ScholarRun -MaxArticles $MaxArticles | Out-Null } catch {}
  return $true
}
