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
    try { $md = Get-Content -LiteralPath $digestPath -Raw -Encoding UTF8 } catch { $md = '' }
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
