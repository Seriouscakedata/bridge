# radar.ps1 -- helpers for the Habr AI/ML digest radar.

function Get-RadarDir { Join-Path (Get-BridgeRoot) 'radar' }
function Get-RadarDigestPath { Join-Path (Get-RadarDir) 'digest.md' }
function Get-RadarHistoryPath { Join-Path (Get-RadarDir) 'digest.history.jsonl' }
function Get-RadarLogPath { Join-Path (Get-RadarDir) 'radar.log' }

function Initialize-RadarDir {
  $d = Get-RadarDir
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  return $d
}

function New-RadarItemId {
  param([string]$Link, [string]$Title)
  $src = (([string]$Link).Trim().ToLowerInvariant() + '|' + ([string]$Title).Trim().ToLowerInvariant())
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($src)
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    return $hash.Substring(0, 12)
  } finally {
    $sha.Dispose()
  }
}

function Get-RadarHistoryRecords {
  $p = Get-RadarHistoryPath
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { [void]$out.Add(($line | ConvertFrom-Json)) } catch {}
  }
  return @($out.ToArray())
}

function Get-RadarLatestRun {
  $records = @(Get-RadarHistoryRecords)
  if ($records.Count -eq 0) { return $null }
  return $records[$records.Count - 1]
}

function Get-RadarDigestForApi {
  $md = ''
  $digestPath = Get-RadarDigestPath
  if (Test-Path -LiteralPath $digestPath) {
    # NOTE: use ReadAllText, NOT Get-Content -Raw. Get-Content -Raw attaches ETS provider
    # NoteProperties (PSProvider/PSDrive) to the string; ConvertTo-Json -Depth 12 then
    # recurses into those rich .NET object graphs and OOM-crashes the server. (Same ETS
    # string bug as /api/memory, but fatal here because of the high depth.)
    try { $md = [System.IO.File]::ReadAllText($digestPath, (New-Object System.Text.UTF8Encoding($false))) } catch { $md = '' }
  }

  $run = Get-RadarLatestRun
  if (-not $run) {
    return [ordered]@{
      ok = $true
      generatedAt = $null
      sources = @()
      considered = 0
      evaluated = 0
      accepted = 0
      rejectedLowValue = 0
      markdown = $md
      items = @()
    }
  }

  return [ordered]@{
    ok = $true
    generatedAt = $run.ts
    sources = @($run.sources)
    considered = [int]$run.considered
    evaluated = [int]$run.evaluated
    accepted = [int]$run.accepted
    rejectedLowValue = [int]$run.rejectedLowValue
    markdown = $md
    items = @($run.items)
  }
}

function Get-RadarDigestItem {
  param([string]$Id, [string]$Link)
  $run = Get-RadarLatestRun
  if (-not $run) { return $null }
  foreach ($item in @($run.items)) {
    if (-not [string]::IsNullOrWhiteSpace($Id) -and [string]$item.id -eq $Id) { return $item }
    if (-not [string]::IsNullOrWhiteSpace($Link) -and [string]$item.link -eq $Link) { return $item }
  }
  return $null
}

function Invoke-RadarAutoIdeas {
  # After a radar run, file backlog ideas for HIGH-VALUE digest items that look like
  # patterns the bridge doesn't have. Strict anti-backdoor: ideas are filed with
  # status='new' (NEVER auto-executed; user approves). Tag: 'radar-derived'.
  # Triggered at the end of techradar.ps1 after Write-RadarDigestFiles.
  $run = Get-RadarLatestRun
  if (-not $run) { return 0 }
  $items = @($run.items)
  if ($items.Count -eq 0) { return 0 }
  $valueFloor = 4   # only items >= 4 are "actionable" candidates
  # Cap: keep at most N pending radar-derived ideas so the backlog doesn't bloat.
  $maxPending = 5
  $existing = @()
  try { $existing = @(Get-Backlog) } catch {}
  $pendingFromRadar = @($existing | Where-Object {
    $tags = @($_.tags | ForEach-Object { [string]$_ })
    ($tags -contains 'radar-derived') -and ([string]$_.status -in @('new','approved'))
  })
  if ($pendingFromRadar.Count -ge $maxPending) {
    Write-RadarLog "auto-ideas skipped: $($pendingFromRadar.Count) pending radar-derived ideas (cap=$maxPending)"
    return 0
  }
  # De-dup: build a quick lookup of URLs already mentioned in the backlog.
  $knownUrls = @{}
  foreach ($i in $existing) {
    $t = [string]$i.text
    foreach ($mm in [regex]::Matches($t, 'https?://\S+')) { $knownUrls[$mm.Value] = 1 }
  }
  $added = 0
  $slots = $maxPending - $pendingFromRadar.Count
  foreach ($it in $items) {
    if ($added -ge $slots) { break }
    $v = 0; try { $v = [double]$it.value } catch {}
    if ($v -lt $valueFloor) { continue }
    $link = [string]$it.link
    if ($knownUrls.ContainsKey($link)) { continue }
    $title = ([string]$it.title).Trim()
    $summary = ([string]$it.summary).Trim()
    $score = 0; try { $score = [double]$it.score } catch {}
    $text = @"
[radar-derived: возможный пробел в capability-matrix]
Статья: $title
Что это и зачем нам: $summary
Источник: $link
Метрики оценки: value=$v score=$score
_Архитектор / оператор: сравни паттерн со списком возможностей моста (architecture-matrix.md). Если паттерн отсутствует и полезен — одобри, переформулируй в конкретную задачу. Если уже есть/неприменимо — отклони._
"@
    $id = Add-Idea -Text $text -From 'radar' -Tags @('radar-derived','external') -Status 'new' -Score $score
    if ($id) { $added++; $knownUrls[$link] = 1 }
  }
  if ($added -gt 0) { Write-RadarLog "auto-ideas filed: $added (value>=4 + not in backlog)" }
  return $added
}

function Add-RadarDigestItemToBacklog {
  param([string]$Id, [string]$Link)
  $item = Get-RadarDigestItem -Id $Id -Link $Link
  if (-not $item) { return [ordered]@{ ok = $false; error = 'item not found' } }

  $linkText = [string]$item.link
  if ([string]::IsNullOrWhiteSpace($linkText)) { return [ordered]@{ ok = $false; error = 'item link missing' } }

  try {
    foreach ($i in @(Get-Backlog)) {
      if ([string]$i.text -like "*$linkText*") {
        return [ordered]@{ ok = $true; id = [string]$i.id; duplicate = $true }
      }
    }
  } catch {}

  $title = ([string]$item.title).Trim()
  $summary = ([string]$item.summary).Trim()
  $text = "$title`n$summary`n$linkText"
  $score = 0.0
  try { $score = [double]$item.score } catch {}
  $idNew = Add-Idea -Text $text -From 'radar' -Tags @('external','radar') -Status 'new' -Score $score
  if ($idNew) { return [ordered]@{ ok = $true; id = [string]$idNew; duplicate = $false } }
  return [ordered]@{ ok = $false; error = 'backlog add failed' }
}
