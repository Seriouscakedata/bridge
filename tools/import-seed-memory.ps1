# Import clean seed memory into the vector store.
# Requires geminiApiKey in %USERPROFILE%\.bridge-private\secrets.json.
param([string]$Channel = 'main')

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

$seedPath = Join-Path $root 'memory\seed\main.memory.jsonl'
if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
  Write-Error "Seed file not found: $seedPath"
  exit 1
}

$records = New-Object System.Collections.Generic.List[object]
foreach ($line in [System.IO.File]::ReadAllLines($seedPath, [System.Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try {
    $item = $line | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$item.text)) { continue }
    [void]$records.Add([pscustomobject]@{
      text       = [string]$item.text
      kind       = if ($item.kind) { [string]$item.kind } else { 'project_fact' }
      trust      = if ($item.trust) { [string]$item.trust } else { 'verified' }
      status     = 'active'
      tags       = @($item.tags | ForEach-Object { [string]$_ })
      source     = 'transfer-seed'
      importance = if ($null -ne $item.importance) { [double]$item.importance } else { 0.75 }
      shared     = $false
    })
  } catch {
    Write-Warning ("Skipping invalid seed line: " + $_.Exception.Message)
  }
}

if ($records.Count -eq 0) {
  Write-Host 'No seed records to import.'
  exit 0
}

$ids = @()
try {
  if (Get-Command Add-ProjectMemoryBatch -ErrorAction SilentlyContinue) {
    $ids = @(Add-ProjectMemoryBatch -Records @($records.ToArray()) -Channel $Channel)
  } else {
    foreach ($r in $records) {
      $ids += Add-ProjectMemory -Text $r.text -Kind $r.kind -Trust $r.trust -Status $r.status -Tags $r.tags -Source $r.source -Importance $r.importance -Channel $Channel
    }
  }
} catch {
  Write-Error ("Import failed: " + $_.Exception.Message)
  exit 2
}

$ok = @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
Write-Host "Seed memory import attempted: $($records.Count), imported: $ok"
if ($ok -eq 0) {
  Write-Host 'If imported=0, check memory.enabled and geminiApiKey in .bridge-private\secrets.json.'
}
