# memory.ps1 -- long-term VECTOR memory for the bridge.
# Gemini embeddings (semantic recall) + Flash librarian (nightly consolidation).
# Dot-sourced from common.ps1. EVERY network path is wrapped so a failure here can
# NEVER kill the engine -- memory is best-effort: if Gemini is down, the bridge runs as before.

# ---- paths ----
function Get-MemoryDir { Join-Path (Get-BridgeRoot) 'memory' }
function Get-MemoryStorePath { Join-Path (Get-MemoryDir) 'memory.jsonl' }
function Get-MemoryMapPath { Join-Path (Get-MemoryDir) 'map.md' }
function Get-MemoryLogPath { Join-Path (Get-MemoryDir) 'librarian.log' }
function Get-MemoryMarkerPath { Join-Path (Get-MemoryDir) 'librarian.last' }

# ---- secrets / config ----
function Get-Secret {
  param([string]$Name)
  $p = Join-Path (Get-BridgeRoot) 'secrets.json'
  if (-not (Test-Path $p)) { return $null }
  try { $s = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  if ($s.PSObject.Properties.Name -contains $Name) { return [string]$s.$Name }
  return $null
}

function Get-MemoryConfig {
  $defaults = @{
    enabled        = $true
    embedModel     = 'gemini-embedding-001'
    embedDim       = 1536
    autoGate       = $true
    recallTopK     = 5
    recallMinScore = 0.62
    dedupThreshold = 0.93
    maxInjectChars = 1200
  }
  $m = $null
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'memory') { $m = $cfg.memory }
  } catch {}
  $out = @{}
  foreach ($k in $defaults.Keys) {
    if ($m -and ($m.PSObject.Properties.Name -contains $k) -and $null -ne $m.$k) { $out[$k] = $m.$k }
    else { $out[$k] = $defaults[$k] }
  }
  return $out
}

# ---- Gemini REST ----
function Invoke-GeminiApi {
  param([string]$Url, $BodyObj, [int]$TimeoutSec = 60)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $json  = $BodyObj | ConvertTo-Json -Depth 12
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec
}

function Get-Embedding {
  # Returns a double[] vector, or $null on any failure.
  param([string]$Text, [string]$TaskType = 'RETRIEVAL_DOCUMENT')
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $key = Get-Secret 'geminiApiKey'
  if (-not $key) { return $null }
  $mc = Get-MemoryConfig
  $model = [string]$mc.embedModel
  # cap very long text so a single huge memory doesn't blow the request
  $t = [string]$Text
  if ($t.Length -gt 8000) { $t = $t.Substring(0, 8000) }
  $url = "https://generativelanguage.googleapis.com/v1beta/models/$($model):embedContent?key=$key"
  $body = @{
    model    = "models/$model"
    content  = @{ parts = @(@{ text = $t }) }
    taskType = $TaskType
  }
  if ($mc.embedDim) { $body.outputDimensionality = [int]$mc.embedDim }
  try {
    $r = Invoke-GeminiApi -Url $url -BodyObj $body -TimeoutSec 60
    if (-not $r.embedding.values) { return $null }
    return ,@($r.embedding.values | ForEach-Object { [double]$_ })
  } catch { return $null }
}

function Invoke-GeminiChat {
  # Returns the model's text, or $null on any failure.
  param([string]$Model, [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.2)
  if ([string]::IsNullOrWhiteSpace($Prompt)) { return $null }
  $key = Get-Secret 'geminiApiKey'
  if (-not $key) { return $null }
  $url = "https://generativelanguage.googleapis.com/v1beta/models/$($Model):generateContent?key=$key"
  $body = @{
    contents         = @(@{ parts = @(@{ text = $Prompt }) })
    generationConfig = @{ temperature = $Temperature }
  }
  try {
    $r = Invoke-GeminiApi -Url $url -BodyObj $body -TimeoutSec $TimeoutSec
    return [string]$r.candidates[0].content.parts[0].text
  } catch { return $null }
}

# ---- vector math ----
function Get-CosineSimilarity {
  param($A, $B)
  if (-not $A -or -not $B) { return 0.0 }
  $n = [Math]::Min($A.Count, $B.Count)
  if ($n -eq 0) { return 0.0 }
  $dot = 0.0; $na = 0.0; $nb = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $x = [double]$A[$i]; $y = [double]$B[$i]
    $dot += $x * $y; $na += $x * $x; $nb += $y * $y
  }
  if ($na -le 0 -or $nb -le 0) { return 0.0 }
  return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}

# ---- store ----
function Add-Memory {
  # Embed $Text and append a memory record. Returns the new id, or $null.
  param([string]$Text, [string[]]$Tags = @(), [string]$Source = 'task', [double]$Importance = 0.5)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  $vec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_DOCUMENT'
  if (-not $vec) { return $null }
  $dir = Get-MemoryDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $rec = [ordered]@{
    id         = [guid]::NewGuid().ToString('N')
    ts         = (Get-Date).ToUniversalTime().ToString('o')
    source     = $Source
    tags       = @($Tags)
    importance = [double]$Importance
    pinned     = $false
    text       = [string]$Text
    vec        = @($vec)
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 6)
  Use-BridgeLock ({ Add-Content -LiteralPath (Get-MemoryStorePath) -Value $line -Encoding UTF8 }.GetNewClosure())
  return $rec.id
}

function Get-AllMemories {
  $p = Get-MemoryStorePath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    [void]$out.Add($m)
  }
  return @($out.ToArray())
}

function Search-Memory {
  # Returns array of [pscustomobject]{ Score; Mem } sorted by score desc.
  param([string]$Query, [int]$TopK = 0, [double]$MinScore = -1)
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return @() }
  if ($TopK -le 0)    { $TopK = [int]$mc.recallTopK }
  if ($MinScore -lt 0) { $MinScore = [double]$mc.recallMinScore }
  $mems = @(Get-AllMemories)
  if ($mems.Count -eq 0) { return @() }
  $qvec = Get-Embedding -Text $Query -TaskType 'RETRIEVAL_QUERY'
  if (-not $qvec) { return @() }
  $scored = foreach ($m in $mems) {
    $sim = Get-CosineSimilarity -A $qvec -B $m.vec
    [pscustomobject]@{ Score = [double]$sim; Mem = $m }
  }
  return @($scored | Where-Object { $_.Score -ge $MinScore } | Sort-Object -Property Score -Descending | Select-Object -First $TopK)
}

function Get-MemoryRecall {
  # Formatted block to inject into a prompt. '' when nothing relevant / disabled / offline.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return '' }
  try { $hits = Search-Memory -Query $TaskText } catch { return '' }
  if (-not $hits -or @($hits).Count -eq 0) { return '' }
  $maxChars = [int]$mc.maxInjectChars
  $sb = New-Object System.Text.StringBuilder
  foreach ($h in $hits) {
    $t = ([string]$h.Mem.text).Trim() -replace '\s+', ' '
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    $pct = [int]([Math]::Round([double]$h.Score * 100))
    $entry = "- ($pct%) $t"
    if ($sb.Length + $entry.Length + 1 -gt $maxChars) { break }
    [void]$sb.AppendLine($entry)
  }
  $bodyTxt = $sb.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($bodyTxt)) { return '' }
  return "=== ДОЛГОВРЕМЕННАЯ ПАМЯТЬ (релевантное, semantic) ===`n$bodyTxt"
}

# ---- write gate (Flash-Lite) ----
function Get-MemoryDistilled {
  # Cheap gate: decide if a task outcome is worth keeping; if so distill to a durable fact.
  # Returns [pscustomobject]{ Fact; Importance; Tags } or $null.
  param([string]$TaskText, [string]$Outcome)
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  $task = [string]$TaskText; if ($task.Length -gt 1500) { $task = $task.Substring(0,1500) }
  $out  = [string]$Outcome;  if ($out.Length  -gt 4000) { $out  = $out.Substring(0,4000) }
  $prompt = @"
Ты — фильтр долговременной памяти ИИ-моста (Claude+Codex, разработка на ПК пользователя).
Реши, стоит ли запоминать результат НАДОЛГО. Запоминаем только устойчивое и переиспользуемое:
решения, факты о проекте/настройках/путях, найденные грабли (gotchas), предпочтения пользователя.
НЕ запоминаем: болтовню, разовые статусы, мусор, быстро устаревающее.

ЗАДАЧА:
$task

РЕЗУЛЬТАТ:
$out

Ответь СТРОГО одной строкой JSON без markdown и пояснений:
{"keep": true|false, "fact": "1-2 предложения сути по-русски", "importance": 0.0-1.0, "tags": ["короткие","теги"]}
Если запоминать не стоит — {"keep": false}.
"@
  $raw = Invoke-LLM -Purpose 'gate' -Prompt $prompt -TimeoutSec 40 -Temperature 0.1
  if (-not $raw) { return $null }
  $clean = ($raw -replace '```json','' -replace '```','').Trim()
  $mt = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mt.Success) { return $null }
  try { $obj = $mt.Value | ConvertFrom-Json } catch { return $null }
  if (-not $obj.keep) { return $null }
  if ([string]::IsNullOrWhiteSpace([string]$obj.fact)) { return $null }
  $imp = 0.5
  try { if ($obj.PSObject.Properties.Name -contains 'importance' -and $null -ne $obj.importance) { $imp = [double]$obj.importance } } catch {}
  if ($imp -lt 0) { $imp = 0 }; if ($imp -gt 1) { $imp = 1 }
  $tags = @()
  try { if ($obj.tags) { $tags = @($obj.tags | ForEach-Object { [string]$_ }) } } catch {}
  return [pscustomobject]@{ Fact = [string]$obj.fact; Importance = $imp; Tags = $tags }
}

function Add-TaskMemory {
  # Gate + store, in one call. Returns memory id or $null. Never throws.
  param([string]$TaskText, [string]$Outcome, [string]$Source = 'task')
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled -or -not $mc.autoGate) { return $null }
    $d = Get-MemoryDistilled -TaskText $TaskText -Outcome $Outcome
    if (-not $d) { return $null }
    return (Add-Memory -Text $d.Fact -Tags $d.Tags -Source $Source -Importance $d.Importance)
  } catch { return $null }
}

# ---- consolidation (librarian helpers) ----
function Invoke-MemoryDedup {
  # Drop near-duplicate memories (cosine >= threshold), keeping higher importance.
  # Returns number removed. Pure-local, no API cost.
  param([double]$Threshold = 0)
  $mc = Get-MemoryConfig
  if ($Threshold -le 0) { $Threshold = [double]$mc.dedupThreshold }
  $mems = @(Get-AllMemories)
  if ($mems.Count -lt 2) { return 0 }
  $arr = foreach ($m in $mems) { [pscustomobject]@{ Mem = $m; Keep = $true } }
  $arr = @($arr)
  for ($i = 0; $i -lt $arr.Count; $i++) {
    if (-not $arr[$i].Keep) { continue }
    for ($j = $i + 1; $j -lt $arr.Count; $j++) {
      if (-not $arr[$j].Keep) { continue }
      $sim = Get-CosineSimilarity -A $arr[$i].Mem.vec -B $arr[$j].Mem.vec
      if ($sim -ge $Threshold) {
        $ip = [bool]($arr[$i].Mem.PSObject.Properties['pinned'] -and $arr[$i].Mem.pinned)
        $jp = [bool]($arr[$j].Mem.PSObject.Properties['pinned'] -and $arr[$j].Mem.pinned)
        if ($ip -and -not $jp) { $arr[$j].Keep = $false; continue }   # never drop a pinned memory
        if ($jp -and -not $ip) { $arr[$i].Keep = $false; break }
        $ii = [double]$arr[$i].Mem.importance; $jj = [double]$arr[$j].Mem.importance
        if ($jj -gt $ii) { $arr[$i].Keep = $false; break } else { $arr[$j].Keep = $false }
      }
    }
  }
  $kept = @($arr | Where-Object { $_.Keep } | ForEach-Object { $_.Mem })
  $removed = $mems.Count - $kept.Count
  if ($removed -gt 0) { Save-AllMemories $kept }
  return $removed
}

# ---- management (used by the web UI) ----
function Save-AllMemories {
  param($Mems)
  $lines = @($Mems | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Use-BridgeLock ({ Write-AtomicFile -Path (Get-MemoryStorePath) -Content $content }.GetNewClosure())
}

function Get-MemoriesView {
  # All memories WITHOUT the heavy vec arrays, for the API/UI.
  $out = foreach ($m in @(Get-AllMemories)) {
    [pscustomobject]@{
      id         = [string]$m.id
      ts         = [string]$m.ts
      source     = [string]$m.source
      tags       = @($m.tags)
      importance = [double]$m.importance
      pinned     = [bool]($m.PSObject.Properties['pinned'] -and $m.pinned)
      text       = [string]$m.text
    }
  }
  return @($out)
}

function Remove-Memory {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $mems = @(Get-AllMemories)
  $kept = @($mems | Where-Object { [string]$_.id -ne $Id })
  if ($kept.Count -eq $mems.Count) { return $false }
  Save-AllMemories $kept
  return $true
}

function Set-Memory {
  # Edit a memory in place. $Text re-embeds. Pass $null to leave a field unchanged.
  param([string]$Id, $Importance = $null, $Text = $null, $Pinned = $null)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $mems = @(Get-AllMemories)
  $found = $false
  foreach ($m in $mems) {
    if ([string]$m.id -ne $Id) { continue }
    $found = $true
    if ($null -ne $Importance) {
      $imp = [double]$Importance; if ($imp -lt 0) { $imp = 0 }; if ($imp -gt 1) { $imp = 1 }
      $m | Add-Member -NotePropertyName importance -NotePropertyValue $imp -Force
    }
    if ($null -ne $Pinned) {
      $p = [bool]$Pinned
      $m | Add-Member -NotePropertyName pinned -NotePropertyValue $p -Force
      if ($p) { $m | Add-Member -NotePropertyName importance -NotePropertyValue 1.0 -Force }
    }
    if ($null -ne $Text -and -not [string]::IsNullOrWhiteSpace([string]$Text) -and ([string]$Text) -ne ([string]$m.text)) {
      $newVec = Get-Embedding -Text ([string]$Text) -TaskType 'RETRIEVAL_DOCUMENT'
      if (-not $newVec) { return $false }   # embedding failed -> don't half-update
      $m | Add-Member -NotePropertyName text -NotePropertyValue ([string]$Text) -Force
      $m | Add-Member -NotePropertyName vec  -NotePropertyValue (@($newVec)) -Force
    }
    break
  }
  if (-not $found) { return $false }
  Save-AllMemories $mems
  return $true
}

function Get-MemoryStats {
  $mems = @(Get-AllMemories)
  $last = $null
  $mp = Get-MemoryMarkerPath
  if (Test-Path $mp) { try { $last = (Get-Content $mp -Raw -Encoding UTF8).Trim() } catch {} }
  $bySource = [ordered]@{}
  foreach ($m in $mems) {
    $key = (([string]$m.source) -split ':')[0]
    if ([string]::IsNullOrWhiteSpace($key)) { $key = '?' }
    if ($bySource.Contains($key)) { $bySource[$key] = [int]$bySource[$key] + 1 } else { $bySource[$key] = 1 }
  }
  $pinned = @($mems | Where-Object { $_.PSObject.Properties['pinned'] -and $_.pinned }).Count
  return [pscustomobject]@{
    count         = $mems.Count
    pinned        = $pinned
    lastLibrarian = $last
    mapExists     = (Test-Path (Get-MemoryMapPath))
    bySource      = $bySource
  }
}
