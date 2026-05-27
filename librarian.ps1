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

# 2b) Age prune: drop old, low-importance, unused, non-pinned records.
$pruned = 0
try { $pruned = Invoke-MemoryAgePrune } catch { Write-LibLog "age-prune error: $($_.Exception.Message)" }
Write-LibLog "age-prune removed: $pruned"

# 3) Regenerate per-channel + shared maps; legacy map.md stays as concatenation for backward compat.
$mems = @(Get-AllMemories)
if ($mems.Count -eq 0) {
  Write-LibLog 'no memories yet; map skipped'
} else {
  # Group: shared (cross-channel) + per-channel (NOT shared). Legacy records (no channel) -> 'main'.
  $sharedMems = @($mems | Where-Object { Test-MemoryShared $_ })
  $localMems  = @($mems | Where-Object { -not (Test-MemoryShared $_) })
  $perChannel = @{}
  foreach ($m in $localMems) {
    $ch = Get-MemoryChannel $m
    if (-not $perChannel.ContainsKey($ch)) { $perChannel[$ch] = New-Object 'System.Collections.Generic.List[object]' }
    [void]$perChannel[$ch].Add($m)
  }

  function _GenMapSection {
    param($GroupMems, [string]$Label, [string]$TargetPath)
    if (-not $GroupMems -or @($GroupMems).Count -eq 0) {
      $stub = "# Карта памяти ($Label)`n`n_Обновлено: $(Get-Date -Format 'yyyy-MM-dd HH:mm') · записей: 0_`n`n_(нет записей)_`n"
      Write-AtomicFile -Path $TargetPath -Content $stub
      return $stub
    }
    $listing = ($GroupMems | Sort-Object { [double]$_.importance } -Descending | ForEach-Object {
      "- [$($_.source)] (важн. $([Math]::Round([double]$_.importance,2))) $(($_.text -replace '\s+',' ').Trim())"
    }) -join "`n"
    if ($listing.Length -gt 18000) { $listing = $listing.Substring(0, 18000) }
    $prompt = @"
Ты — библиотекарь долговременной памяти ИИ-моста (Claude+Codex, разработка на ПК пользователя).
КОНТЕКСТ ЭТОЙ СЕКЦИИ: $Label.
Ниже — сырые записи памяти. Собери из них компактную организованную «карту памяти» на русском в Markdown:
- сгруппируй по темам;
- объедини дубли и близкое по смыслу, убери явный мусор;
- пиши кратко, маркерами, только то, что реально полезно помнить надолго;
- не выдумывай факты, опирайся ТОЛЬКО на записи ниже.
Верни ТОЛЬКО Markdown карты, без преамбулы.

ЗАПИСИ ПАМЯТИ:
$listing
"@
    $map = $null
    try { $map = Invoke-LLM -Purpose 'librarian' -Prompt $prompt -TimeoutSec 180 -Temperature 0.3 } catch { $map = $null }
    if ([string]::IsNullOrWhiteSpace($map)) {
      Write-LibLog "map section '$Label' generation failed (empty reply) -- keeping previous if exists"
      if (Test-Path $TargetPath) { return (Get-Content $TargetPath -Raw -Encoding UTF8) }
      $stub = "# Карта памяти ($Label)`n`n_(генерация не удалась)_`n"
      Write-AtomicFile -Path $TargetPath -Content $stub
      return $stub
    }
    # strip a wrapping ```markdown ... ``` fence if the model added one
    $map = ($map -replace '(?s)^\s*```(?:markdown|md)?\s*\r?\n','' -replace '(?s)\r?\n```\s*$','').Trim()
    $header = "# Карта памяти ($Label)`n`n_Обновлено: $(Get-Date -Format 'yyyy-MM-dd HH:mm') · записей: $(@($GroupMems).Count)_`n`n"
    $full = $header + $map.Trim() + "`n"
    Write-AtomicFile -Path $TargetPath -Content $full
    return $full
  }

  $sections = New-Object 'System.Collections.Generic.List[string]'
  $channelSlugs = @($perChannel.Keys | ForEach-Object { [string]$_ } | Sort-Object)
  foreach ($slug in $channelSlugs) {
    $group = @($perChannel[$slug].ToArray())
    $sectionTxt = _GenMapSection -GroupMems $group -Label "канал $slug" -TargetPath (Get-MemoryMapPathForChannel -Slug $slug)
    [void]$sections.Add("## map.$slug.md`n`n$sectionTxt")
  }
  $sharedTxt = _GenMapSection -GroupMems $sharedMems -Label 'общая память (shared, cross-channel)' -TargetPath (Get-MemorySharedMapPath)
  [void]$sections.Add("## map.shared.md`n`n$sharedTxt")

  # Legacy concat: existing tools/scripts still read memory/map.md.
  $legacyHeader = "# Карта памяти моста (legacy concat)`n`n_Обновлено: $(Get-Date -Format 'yyyy-MM-dd HH:mm') · записей: $($mems.Count)_`n`n"
  $legacy = $legacyHeader + ($sections -join "`n`n")
  Write-AtomicFile -Path (Get-MemoryMapPath) -Content $legacy
  Write-LibLog "maps regenerated; channels=$($perChannel.Count) shared=$(@($sharedMems).Count) total=$($mems.Count)"
  # Save current count -> the driver's delta-trigger uses this to decide when to wake us early.
  try { [System.IO.File]::WriteAllText((Join-Path (Get-MemoryDir) 'librarian.count.last'), [string]$mems.Count, $Utf8NoBom) } catch {}
}

try { [System.IO.File]::WriteAllText((Get-MemoryMarkerPath), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-LibLog '=== librarian done ==='
