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
  # 2) what we already have -- feature names from the registry (avoid proposing duplicates)
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

# ───────── STAGE 2 (next increment) — orchestration + autonomy ─────────
# function Invoke-ScholarRun { ... }   # batch top-N candidates -> study each -> dedup -> file idea/knowledge
# function Start-ScholarIfDue { ... }  # autonomous trigger (idle/schedule); replaces broken radar auto-idea
