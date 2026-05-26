# librarian.ps1 -- nightly memory consolidation ("dream cycle"), runs once/24h.
# Launched detached by driver.ps1 when idle. Ingests decisions into the vector store,
# dedups near-duplicates, and regenerates the human-readable memory map via Gemini Flash.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

function Write-LibLog {
  param([string]$Msg)
  try { Add-Content -LiteralPath (Get-MemoryLogPath) -Value ((Get-Date).ToString('s') + '  ' + $Msg) -Encoding UTF8 } catch {}
}

$mc = Get-MemoryConfig
if (-not $mc.enabled) { Write-LibLog 'memory disabled; exit'; return }
$key = Get-Secret 'geminiApiKey'
if (-not $key) { Write-LibLog 'no api key; exit'; return }

$dir = Get-MemoryDir
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Write-LibLog '=== librarian start ==='

# 1) Ingest decisions/*.md that are not yet in the store (idempotent by source tag).
$existing = @(Get-AllMemories)
$existingSources = @{}
foreach ($m in $existing) { $s = [string]$m.source; if ($s) { $existingSources[$s] = $true } }

$decDir = Get-DecisionsPath
$ingested = 0
if (Test-Path $decDir) {
  foreach ($f in (Get-ChildItem $decDir -Filter '*.md' -File)) {
    $src = 'decision:' + $f.BaseName
    if ($existingSources.ContainsKey($src)) { continue }
    try { $raw = Get-Content $f.FullName -Raw -Encoding UTF8 } catch { continue }
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $txt = $raw.Trim()
    if ($txt.Length -gt 1500) { $txt = $txt.Substring(0, 1500) }
    $id = Add-Memory -Text $txt -Tags @('decision') -Source $src -Importance 0.7
    if ($id) { $ingested++ }
  }
}
Write-LibLog "ingested decisions: $ingested"

# 2) Dedup near-duplicates (local, free).
$removed = 0
try { $removed = Invoke-MemoryDedup } catch { Write-LibLog "dedup error: $($_.Exception.Message)" }
Write-LibLog "dedup removed: $removed"

# 3) Regenerate the human-readable memory map via Flash.
$mems = @(Get-AllMemories)
if ($mems.Count -gt 0) {
  $listing = ($mems | Sort-Object { [double]$_.importance } -Descending | ForEach-Object {
    "- [$($_.source)] (важн. $([Math]::Round([double]$_.importance,2))) $(($_.text -replace '\s+',' ').Trim())"
  }) -join "`n"
  if ($listing.Length -gt 18000) { $listing = $listing.Substring(0, 18000) }
  $prompt = @"
Ты — библиотекарь долговременной памяти ИИ-моста (Claude+Codex, разработка на ПК пользователя).
Ниже — сырые записи памяти. Собери из них компактную организованную «карту памяти» на русском в Markdown:
- сгруппируй по темам (например: О пользователе, Архитектура моста, Грабли/gotchas, Решения, Настройки и пути);
- объедини дубли и близкое по смыслу, убери явный мусор;
- пиши кратко, маркерами, только то, что реально полезно помнить надолго;
- не выдумывай факты, опирайся ТОЛЬКО на записи ниже.
Верни ТОЛЬКО Markdown карты, без преамбулы.

ЗАПИСИ ПАМЯТИ:
$listing
"@
  $map = Invoke-LLM -Purpose 'librarian' -Prompt $prompt -TimeoutSec 180 -Temperature 0.3
  if (-not [string]::IsNullOrWhiteSpace($map)) {
    # strip a wrapping ```markdown ... ``` fence if the model added one
    $map = ($map -replace '(?s)^\s*```(?:markdown|md)?\s*\r?\n','' -replace '(?s)\r?\n```\s*$','').Trim()
    $header = "# Карта памяти моста`n`n_Обновлено: $(Get-Date -Format 'yyyy-MM-dd HH:mm') · записей: $($mems.Count)_`n`n"
    Write-AtomicFile -Path (Get-MemoryMapPath) -Content ($header + $map.Trim() + "`n")
    Write-LibLog "map regenerated; memories: $($mems.Count)"
    # Save current count -> the driver's delta-trigger uses this to decide when to wake us early.
    try { [System.IO.File]::WriteAllText((Join-Path (Get-MemoryDir) 'librarian.count.last'), [string]$mems.Count, $Utf8NoBom) } catch {}
  } else {
    Write-LibLog 'map generation failed (empty reply)'
  }
} else {
  Write-LibLog 'no memories yet; map skipped'
}

try { [System.IO.File]::WriteAllText((Get-MemoryMarkerPath), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-LibLog '=== librarian done ==='
