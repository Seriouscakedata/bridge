# techradar.ps1 -- weekly AI/ML tech-radar from Habr feeds (research-only, no shell).
# Reads sources.md, fetches RSS, evaluates via DeepSeek, files into backlog as external/new.
# Launched detached by driver.ps1; ideas require MANUAL approval before any auto-run.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$bridgeRoot = Get-BridgeRoot
function Write-RadarLog {
  param([string]$Msg)
  try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'radar.log') -Value ((Get-Date).ToString('s') + '  ' + $Msg) -Encoding UTF8 } catch {}
}

function ConvertTo-RssUrl {
  param([string]$PageUrl)
  # https://habr.com/ru/flows/.../articles/ -> https://habr.com/ru/rss/flows/.../articles/?fl=ru
  $rss = $PageUrl -replace 'habr\.com/ru/', 'habr.com/ru/rss/'
  $rss = $rss.TrimEnd('/') + '/?fl=ru'
  return $rss
}

function Get-FeedArticles {
  param([string]$RssUrl, [int]$Max = 8)
  try {
    $resp = Invoke-WebRequest -Uri $RssUrl -UseBasicParsing -TimeoutSec 30 `
      -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; bridge-radar/1.0)' }
    [xml]$xml = $resp.Content
    return @(@($xml.rss.channel.item) | Select-Object -First $Max | ForEach-Object {
      $desc = [string]$_.description -replace '<[^>]+>','' -replace '\s+',' '
      if ($desc.Length -gt 500) { $desc = $desc.Substring(0,500) }
      [PSCustomObject]@{ title=$([string]$_.title); link=$([string]$_.link); desc=$desc }
    })
  } catch { return @() }
}

function Test-RadarFeedUrl {
  param([string]$Url)
  return ($Url -match '^https://habr\.com/ru/(flows/ai_and_ml|hubs/(artificial_intelligence|machine_learning|natural_language_processing))/articles/?$')
}

Write-RadarLog '=== radar start ==='

# Read feed URLs from sources.md
$sourcesPath = Join-Path $bridgeRoot 'sources.md'
$feedUrls = @()
if (Test-Path -LiteralPath $sourcesPath) {
  foreach ($line in (Get-Content -LiteralPath $sourcesPath -Encoding UTF8)) {
    if ($line -match '(https://habr\.com[^\s)\]]+)') {
      $url = $Matches[1].TrimEnd('/') + '/'
      if (Test-RadarFeedUrl $url) { $feedUrls += $url }
    }
  }
}
$feedUrls = @($feedUrls | Select-Object -Unique)
if ($feedUrls.Count -eq 0) {
  $feedUrls = @(
    'https://habr.com/ru/flows/ai_and_ml/articles/',
    'https://habr.com/ru/hubs/artificial_intelligence/articles/',
    'https://habr.com/ru/hubs/machine_learning/articles/',
    'https://habr.com/ru/hubs/natural_language_processing/articles/'
  )
}

# Build dedup set from existing backlog (URLs already stored)
$knownUrls = @{}
try {
  @(Get-Backlog) | ForEach-Object {
    if ([string]$_.text -match 'https?://\S+') { $knownUrls[$Matches[0]] = 1 }
  }
} catch {}

$scoreThreshold = 2.0
$added = 0
$seen = @{}

foreach ($feedUrl in $feedUrls) {
  $rssUrl = ConvertTo-RssUrl $feedUrl
  Write-RadarLog "fetch $rssUrl"
  $articles = Get-FeedArticles -RssUrl $rssUrl -Max 8
  Write-RadarLog "got $($articles.Count) articles"

  foreach ($art in $articles) {
    $link = [string]$art.link
    if ([string]::IsNullOrWhiteSpace($link) -or $seen.ContainsKey($link) -or $knownUrls.ContainsKey($link)) { continue }
    $seen[$link] = 1
    $title = [string]$art.title
    $desc  = [string]$art.desc

    $evalPrompt = @"
Ты — тех-радар ИИ-инженера. Оцени статью для команды, разрабатывающей автономного ИИ-агента на Windows (Claude+Codex).
Тематика интереса: ИИ-агенты и оркестрация, долгосрочная память/контекст, инструменты разработки, удешевление LLM, автоматизация PowerShell/Windows.

СТАТЬЯ:
Заголовок: $title
Аннотация: $desc
Ссылка: $link

Оцени:
- value (1-5): польза для нашей работы (1=нерелевантно, 5=очень ценно)
- confidence (1-5): достоверность/реальность (1=сомнительно, 5=проверено)
- effort (1-5): сложность применения (1=легко, 5=очень сложно)

Верни СТРОГО JSON без markdown:
{"value":N,"confidence":N,"effort":N,"summary":"одна фраза по-русски — что это и зачем нам"}
"@

    $raw = Invoke-LLM -Purpose 'reflect' -Prompt $evalPrompt -TimeoutSec 60 -Temperature 0.2
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-RadarLog "no LLM reply: $title"; continue }

    $clean = ($raw -replace '```json','' -replace '```','').Trim()
    $match = [regex]::Match($clean, '(?s)\{.*\}')
    if (-not $match.Success) { continue }
    $ev = $null
    try { $ev = $match.Value | ConvertFrom-Json } catch { continue }

    $v = [Math]::Max(1.0,[Math]::Min(5.0,[double]$ev.value))
    $c = [Math]::Max(1.0,[Math]::Min(5.0,[double]$ev.confidence))
    $e = [Math]::Max(1.0,[Math]::Min(5.0,[double]$ev.effort))
    $score = [Math]::Round($v * $c / $e, 2)
    $summary = [string]$ev.summary
    Write-RadarLog "score=$score v=$v c=$c e=$e | $title"

    if ($score -lt $scoreThreshold) { continue }

    $ideaText = "$title`n$summary`n$link"
    $id = Add-Idea -Text $ideaText -From 'radar' -Tags @('external','radar') -Status 'new' -Score $score
    if ($id) { $added++ }
  }
}

Write-RadarLog "added=$added"
if ($added -gt 0) {
  try { Add-Message -From system -Text "📡 Тех-радар: $added новых статей в Бэклоге — одобри вручную (🧠 → «Бэклог»)." -Kind event | Out-Null } catch {}
}
try { [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'radar.last'), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-RadarLog '=== radar done ==='
