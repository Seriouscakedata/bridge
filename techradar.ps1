param(
  [int]$MaxPerFeed = 8,
  [int]$MaxDigestItems = 12
)

# techradar.ps1 -- weekly AI/ML digest from approved Habr feeds.
# Reads RSS, evaluates articles via DeepSeek, writes a digest. It never writes to backlog.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\radar.ps1')
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$bridgeRoot = Get-BridgeRoot
$null = Initialize-RadarDir

function Write-RadarLog {
  param([string]$Msg)
  $line = (Get-Date).ToString('s') + '  ' + $Msg
  try { Add-Content -LiteralPath (Get-RadarLogPath) -Value $line -Encoding UTF8 } catch {}
  Write-Host $line
}

function Test-RadarFeedUrl {
  param([string]$Url)
  return ($Url -match '^https://habr\.com/ru/(flows/ai_and_ml|hubs/(artificial_intelligence|machine_learning|natural_language_processing))/articles/?$')
}

function ConvertTo-RssUrl {
  param([string]$PageUrl)
  $rss = $PageUrl -replace 'habr\.com/ru/', 'habr.com/ru/rss/'
  $rss = $rss.TrimEnd('/') + '/?fl=ru'
  return $rss
}

function Get-RadarNodeText {
  param($Node)
  if ($null -eq $Node) { return '' }
  try {
    if ($Node -is [System.Xml.XmlNode]) { return ([System.Net.WebUtility]::HtmlDecode([string]$Node.InnerText)).Trim() }
    if ($Node.PSObject.Properties.Name -contains '#text') { return ([System.Net.WebUtility]::HtmlDecode([string]$Node.'#text')).Trim() }
  } catch {}
  return ([System.Net.WebUtility]::HtmlDecode([string]$Node)).Trim()
}

function ConvertFrom-RadarHtml {
  param([string]$Html, [int]$MaxChars = 700)
  if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
  $txt = $Html -replace '(?is)<script[^>]*>.*?</script>', ' '
  $txt = $txt -replace '(?is)<style[^>]*>.*?</style>', ' '
  $txt = $txt -replace '<[^>]+>', ' '
  $txt = [System.Net.WebUtility]::HtmlDecode($txt)
  $txt = ($txt -replace '\s+', ' ').Trim()
  if ($txt.Length -gt $MaxChars) { $txt = $txt.Substring(0, $MaxChars).Trim() }
  return $txt
}

function Get-RadarFeedUrls {
  $sourcesPath = Join-Path $bridgeRoot 'sources.md'
  $feedUrls = @()
  if (Test-Path -LiteralPath $sourcesPath) {
    foreach ($line in (Get-Content -LiteralPath $sourcesPath -Encoding UTF8)) {
      if ($line -match '(https://habr\.com[^\s)\]]+)') {
        $url = $Matches[1].TrimEnd('/') + '/'
        if (Test-RadarFeedUrl $url) { $feedUrls += $url }
        else { Write-RadarLog "skip source (not AI/ML feed): $url" }
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
  return @($feedUrls)
}

function Get-FeedArticles {
  param([string]$RssUrl, [int]$Max = 8)
  try {
    $resp = Invoke-WebRequest -Uri $RssUrl -UseBasicParsing -TimeoutSec 30 `
      -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; bridge-radar/2.0)' }
    [xml]$xml = $resp.Content
    return @(@($xml.rss.channel.item) | Select-Object -First $Max | ForEach-Object {
      $title = Get-RadarNodeText $_.title
      $link = Get-RadarNodeText $_.link
      $desc = ConvertFrom-RadarHtml (Get-RadarNodeText $_.description)
      $pub = Get-RadarNodeText $_.pubDate
      [PSCustomObject]@{
        title = $title
        link = $link
        desc = $desc
        published = $pub
      }
    } | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string]$_.title) -and
      -not [string]::IsNullOrWhiteSpace([string]$_.link)
    })
  } catch {
    Write-RadarLog "fetch failed: $RssUrl | $($_.Exception.Message)"
    return @()
  }
}

function Limit-RadarNumber {
  param($Value)
  $n = 1.0
  try { $n = [double]$Value } catch {}
  return [Math]::Max(1.0, [Math]::Min(5.0, $n))
}

function ConvertFrom-RadarEvalJson {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $clean = ($Raw -replace '```json', '' -replace '```', '').Trim()
  $match = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $match.Success) { return $null }
  try { return ($match.Value | ConvertFrom-Json) } catch { return $null }
}

function Invoke-RadarArticleEval {
  param($Article)
  $title = [string]$Article.title
  $desc = [string]$Article.desc
  $link = [string]$Article.link
  $evalPrompt = @"
Ты — тех-радар ИИ-инженера. Оцени статью для команды, разрабатывающей автономного ИИ-агента на Windows (Claude+Codex).
Тематика интереса: ИИ-агенты и оркестрация, долгосрочная память/контекст, инструменты разработки, удешевление LLM, автоматизация PowerShell/Windows.

СТАТЬЯ:
Заголовок: $title
Аннотация: $desc
Ссылка: $link

Оцени:
- value (1-5): польза именно для нашей работы; 1-2 = нерелевантно или почти не применимо, 3 = потенциально полезно, 5 = очень ценно.
- confidence (1-5): достоверность/реальность.
- effort (1-5): сложность применения.

Верни СТРОГО JSON без markdown:
{"value":N,"confidence":N,"effort":N,"summary":"одна фраза по-русски — что это и зачем нам"}
"@
  $raw = Invoke-LLM -Purpose 'reflect' -Prompt $evalPrompt -TimeoutSec 60 -Temperature 0.2
  return (ConvertFrom-RadarEvalJson -Raw $raw)
}

function Write-RadarDigestFiles {
  param($Run)
  $lines = New-Object 'System.Collections.Generic.List[string]'
  $runItems = @($Run['items'])
  [void]$lines.Add('# Тех-радар AI/ML')
  [void]$lines.Add('')
  [void]$lines.Add("_Обновлено: $($Run['ts'])_")
  [void]$lines.Add('')
  [void]$lines.Add("Источники: $(@($Run['sources']).Count); оценено: $($Run['evaluated']); в дайджесте: $($Run['accepted']); отброшено value<3: $($Run['rejectedLowValue']).")
  [void]$lines.Add('')
  if ($runItems.Count -eq 0) {
    [void]$lines.Add('Релевантных пунктов для дайджеста нет.')
  } else {
    $n = 1
    foreach ($item in $runItems) {
      [void]$lines.Add("$n. [$($item.title)]($($item.link))")
      [void]$lines.Add("   Что это и зачем нам: $($item.summary)")
      [void]$lines.Add("   Оценка: value=$($item.value); confidence=$($item.confidence); effort=$($item.effort); score=$($item.score)")
      [void]$lines.Add('')
      $n++
    }
  }
  [System.IO.File]::WriteAllText((Get-RadarDigestPath), (($lines.ToArray() -join "`n") + "`n"), $Utf8NoBom)

  $jsonLine = ($Run | ConvertTo-Json -Compress -Depth 8)
  $hist = Get-RadarHistoryPath
  if (Test-Path -LiteralPath $hist) {
    Add-Content -LiteralPath $hist -Value $jsonLine -Encoding UTF8
  } else {
    [System.IO.File]::WriteAllText($hist, $jsonLine + "`n", $Utf8NoBom)
  }
}

Write-RadarLog '=== radar digest start ==='
$feedUrls = @(Get-RadarFeedUrls)
Write-RadarLog "sources=$($feedUrls.Count) maxPerFeed=$MaxPerFeed"

$seen = @{}
$accepted = New-Object 'System.Collections.Generic.List[object]'
$considered = 0
$evaluated = 0
$rejectedLowValue = 0
$evalFailed = 0

foreach ($feedUrl in $feedUrls) {
  $rssUrl = ConvertTo-RssUrl $feedUrl
  Write-RadarLog "fetch $rssUrl"
  $articles = @(Get-FeedArticles -RssUrl $rssUrl -Max $MaxPerFeed)
  Write-RadarLog "got $($articles.Count) articles"

  foreach ($art in $articles) {
    $link = [string]$art.link
    if ([string]::IsNullOrWhiteSpace($link) -or $seen.ContainsKey($link)) { continue }
    $seen[$link] = 1
    $considered++

    $title = [string]$art.title
    Write-RadarLog "article: $title"
    $ev = Invoke-RadarArticleEval -Article $art
    if (-not $ev) {
      $evalFailed++
      Write-RadarLog "eval failed: $title"
      continue
    }
    $evaluated++

    $v = Limit-RadarNumber $ev.value
    $c = Limit-RadarNumber $ev.confidence
    $e = Limit-RadarNumber $ev.effort
    $score = [Math]::Round($v * $c / $e, 2)
    $summary = ([string]$ev.summary).Trim()
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Краткая оценка не вернулась.' }

    if ($v -lt 3.0) {
      $rejectedLowValue++
      Write-RadarLog "reject value<3 v=$v c=$c e=$e score=$score | $title"
      continue
    }

    $item = [ordered]@{
      id = New-RadarItemId -Link $link -Title $title
      title = $title
      summary = $summary
      link = $link
      value = $v
      confidence = $c
      effort = $e
      score = $score
      published = [string]$art.published
      source = $feedUrl
    }
    [void]$accepted.Add([pscustomobject]$item)
    Write-RadarLog "accept v=$v c=$c e=$e score=$score | $title"
  }
}

$items = @($accepted.ToArray() | Sort-Object @{Expression={ [double]$_.score }; Descending=$true}, @{Expression={ [double]$_.value }; Descending=$true} | Select-Object -First $MaxDigestItems)
$run = [ordered]@{
  type = 'digest'
  ts = (Get-Date).ToUniversalTime().ToString('o')
  sources = @($feedUrls)
  considered = $considered
  evaluated = $evaluated
  accepted = @($items).Count
  acceptedBeforeCap = @($accepted.ToArray()).Count
  rejectedLowValue = $rejectedLowValue
  evalFailed = $evalFailed
  items = @($items)
}

Write-RadarDigestFiles -Run $run
try { [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'radar.last'), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-RadarLog "digest items=$(@($items).Count) considered=$considered evaluated=$evaluated rejectedLowValue=$rejectedLowValue evalFailed=$evalFailed"
# 🪞 radar -> action: file backlog ideas for value>=4 items that aren't already in the backlog.
# Strict anti-backdoor: status='new', never auto-executed, capped to 5 pending.
try { $autoN = Invoke-RadarAutoIdeas; if ($autoN -gt 0) { Add-Message -From system -Text "📡 Радар нашёл $autoN потенциально полезных паттернов и положил в бэклог как 'radar-derived' (тег + status=new). Архитектор разберётся / решишь сам." -Kind event | Out-Null } } catch {}
Write-RadarLog '=== radar digest done ==='
