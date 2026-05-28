# memory.ps1 -- long-term VECTOR memory for the bridge.
# Gemini embeddings (semantic recall) + Flash librarian (nightly consolidation).
# Dot-sourced from common.ps1. EVERY network path is wrapped so a failure here can
# NEVER kill the engine -- memory is best-effort: if Gemini is down, the bridge runs as before.

$script:EmbedCache = $null
$script:EmbedCacheOrder = $null
$script:EmbedCacheMax = 500
$script:LastRecallFlushTs = $null
$script:RecallFlushMinIntervalSec = 60

function Get-EmbedCacheKey {
  param([string]$Text, [string]$TaskType)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$TaskType) + "`0" + ([string]$Text))
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

# ---- paths ----
function Get-MemoryScope {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) {
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { return (Get-EffectiveScope) }
  } elseif ($Slug -ne '__all__') {
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { return (Get-EffectiveScope -Slug $Slug) }
  }
  $bridgeRoot = Get-BridgeRoot
  $memoryRoot = Join-Path $bridgeRoot 'memory'
  return [pscustomobject]@{
    slug                = 'main'
    is_bridge           = $true
    bridge_root         = $bridgeRoot
    memory_root         = $memoryRoot
    memory_store        = (Join-Path $memoryRoot 'memory.jsonl')
    bridge_memory_root  = $memoryRoot
    bridge_memory_store = (Join-Path $memoryRoot 'memory.jsonl')
  }
}
function Get-MemoryDir { param([string]$Slug = $null) [string]((Get-MemoryScope -Slug $Slug).memory_root) }
function Get-MemoryStorePath { param([string]$Slug = $null) [string]((Get-MemoryScope -Slug $Slug).memory_store) }
function Get-MemoryMapPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'map.md' }
function Get-MemoryMapPathForChannel { param([string]$Slug) Join-Path (Get-MemoryDir -Slug $Slug) 'map.md' }
function Get-MemorySharedMapPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'map.shared.md' }
function Get-MemoryMapPathsForChannel {
  param([string]$Slug)
  return [pscustomobject]@{
    Channel = (Get-MemoryMapPathForChannel -Slug $Slug)
    Shared  = (Get-MemorySharedMapPath -Slug $Slug)
  }
}
function Get-MemoryLogPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'librarian.log' }
function Get-MemoryMarkerPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'librarian.last' }

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
    dedupCosine = 0.93
    ageDaysPrune = 30
    minImportanceKeep = 0.5
    unusedDaysPrune = 7
    maxInjectChars = 1200
    skillTopK = 2
    skillMinScore = 0.55
    skillMaxInjectChars = 600
    skillImportance = 0.8
    skillDedupThreshold = 0.96
    antiSkillTopK = 2
    antiSkillMinScore = 0.55
    antiSkillMaxInjectChars = 600
    codeTopK = 4
    codeMinScore = 0.5
    codeMaxInjectChars = 900
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
  $json  = $BodyObj | ConvertTo-Json -Depth 8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  try {
    # 2026-05-28: switched from Invoke-RestMethod to Invoke-WebRequest +
    # RawContentStream + UTF-8 decode. PS 5.1's Invoke-RestMethod has a long-
    # standing bug where it decodes response bytes as ISO-8859-1 even when the
    # Content-Type explicitly says charset=utf-8 — that corrupts every Cyrillic
    # character into cp866-looking mojibake (we saw `���祢��` instead of
    # `ключевая` in every Gemini audit-fallback finding). Same workaround is
    # already used in Invoke-DeepSeekChat (lib/llm.ps1).
    $resp = Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec -UseBasicParsing
    $txt = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    return ($txt | ConvertFrom-Json)
  } catch {
    $detail = ''
    try {
      $stream = $_.Exception.Response.GetResponseStream()
      $detail = (New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)).ReadToEnd()
    } catch {}
    if ($detail) { throw "Gemini API error: $detail" }
    throw
  }
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
  if ($null -eq $script:EmbedCache) {
    $script:EmbedCache = @{}
    $script:EmbedCacheOrder = New-Object System.Collections.Generic.List[string]
  }
  $ck = Get-EmbedCacheKey -Text $t -TaskType $TaskType
  if ($script:EmbedCache.ContainsKey($ck)) {
    [void]$script:EmbedCacheOrder.Remove($ck)
    [void]$script:EmbedCacheOrder.Add($ck)
    return ,$script:EmbedCache[$ck]
  }
  $estTokens = [int][Math]::Ceiling([Math]::Max(1, $t.Length) / 4.0)
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
    try {
      $null = Add-UsageRecord -Kind paid -Provider 'gemini' -Model $model -Purpose 'embed' -PromptTokens $estTokens -CompletionTokens 0 -Status 'ok'
    } catch {}
    $vec = @($r.embedding.values | ForEach-Object { [double]$_ })
    $script:EmbedCache[$ck] = $vec
    [void]$script:EmbedCacheOrder.Add($ck)
    while ($script:EmbedCacheOrder.Count -gt $script:EmbedCacheMax) {
      $evict = $script:EmbedCacheOrder[0]
      $script:EmbedCacheOrder.RemoveAt(0)
      if ($script:EmbedCache.ContainsKey($evict)) { [void]$script:EmbedCache.Remove($evict) }
    }
    return ,$vec
  } catch { return $null }
}

function Get-EmbeddingBatch {
  # Emits one double[] vector per input text, preserving order. Falls back to Get-Embedding
  # sequentially if the Gemini batch endpoint is unavailable.
  param([string[]]$Texts, [string]$TaskType = 'RETRIEVAL_QUERY')
  if (-not $Texts -or $Texts.Count -eq 0) { return @() }
  if ($Texts.Count -eq 1) {
    Write-Output -NoEnumerate (Get-Embedding -Text ([string]$Texts[0]) -TaskType $TaskType)
    return
  }
  $batchEnabled = $true
  try {
    $cfgB = Get-BridgeConfig
    if ($cfgB -and ($cfgB.PSObject.Properties.Name -contains 'fastLane') -and $cfgB.fastLane) {
      $fl = $cfgB.fastLane
      if (($fl.PSObject.Properties.Name -contains 'embedBatchEnabled') -and $null -ne $fl.embedBatchEnabled) { $batchEnabled = [bool]$fl.embedBatchEnabled }
    }
  } catch {}
  $cleanTexts = @($Texts | ForEach-Object {
    $t = [string]$_
    if ($t.Length -gt 8000) { $t.Substring(0, 8000) } else { $t }
  })
  if (-not $batchEnabled) {
    foreach ($txt in $cleanTexts) { Write-Output -NoEnumerate (Get-Embedding -Text $txt -TaskType $TaskType) }
    return
  }
  $key = Get-Secret 'geminiApiKey'
  if (-not $key) { $key = Get-Secret 'GEMINI_API_KEY' }
  if (-not $key) {
    foreach ($txt in $cleanTexts) { Write-Output -NoEnumerate (Get-Embedding -Text $txt -TaskType $TaskType) }
    return
  }
  $mc = Get-MemoryConfig
  $model = [string]$mc.embedModel
  $url = "https://generativelanguage.googleapis.com/v1beta/models/$($model):batchEmbedContents?key=$key"
  $reqs = @($cleanTexts | ForEach-Object {
    $r = @{
      model    = "models/$model"
      content  = @{ parts = @(@{ text = [string]$_ }) }
      taskType = $TaskType
    }
    if ($mc.embedDim) { $r.outputDimensionality = [int]$mc.embedDim }
    $r
  })
  $body = @{ requests = $reqs }
  try {
    $r = Invoke-GeminiApi -Url $url -BodyObj $body -TimeoutSec 30
    $embs = @($r.embeddings)
    if ($embs.Count -ne $cleanTexts.Count) { throw "batch embedding count mismatch: got $($embs.Count), expected $($cleanTexts.Count)" }
    $estTokens = 0
    foreach ($txt in $cleanTexts) { $estTokens += [int][Math]::Ceiling([Math]::Max(1, ([string]$txt).Length) / 4.0) }
    try { $null = Add-UsageRecord -Kind paid -Provider 'gemini' -Model $model -Purpose 'embed_batch' -PromptTokens $estTokens -CompletionTokens 0 -Status 'ok' } catch {}
    foreach ($emb in $embs) {
      if (-not $emb.values) { throw 'batch embedding missing values' }
      $vec = @($emb.values | ForEach-Object { [double]$_ })
      Write-Output -NoEnumerate $vec
    }
  } catch {
    foreach ($txt in $cleanTexts) {
      Write-Output -NoEnumerate (Get-Embedding -Text $txt -TaskType $TaskType)
    }
  }
}

function Invoke-GeminiChat {
  # Returns the model's text, or $null on any failure.
  param([string]$Model, [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.2, [string]$Purpose = '')
  if ([string]::IsNullOrWhiteSpace($Prompt)) { return $null }
  $key = Get-Secret 'geminiApiKey'
  if (-not $key) { return $null }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $url = "https://generativelanguage.googleapis.com/v1beta/models/$($Model):generateContent?key=$key"
  $body = @{
    contents         = @(@{ parts = @(@{ text = $Prompt }) })
    generationConfig = @{ temperature = $Temperature }
  }
  try {
    $r = Invoke-GeminiApi -Url $url -BodyObj $body -TimeoutSec $TimeoutSec
    $pt = 0; $ct = 0; $costUsd = $null
    try {
      if ($r.usageMetadata) {
        if ($null -ne $r.usageMetadata.promptTokenCount) { $pt = [int]$r.usageMetadata.promptTokenCount }
        if ($null -ne $r.usageMetadata.candidatesTokenCount) { $ct = [int]$r.usageMetadata.candidatesTokenCount }
      }
      if (Get-Command Get-UsageCostUsd -ErrorAction SilentlyContinue) {
        $costUsd = Get-UsageCostUsd -Model $Model -PromptTokens $pt -CompletionTokens $ct
      }
      $null = Add-UsageRecord -Kind paid -Provider 'gemini' -Model $Model -Purpose $Purpose -PromptTokens $pt -CompletionTokens $ct -Status 'ok'
    } catch {
      Write-Warning ("Gemini usage accounting failed: " + $_.Exception.Message)
    }
    $responseText = [string]$r.candidates[0].content.parts[0].text
    $replayPurpose = if ([string]::IsNullOrWhiteSpace($Purpose)) { 'general' } else { $Purpose }
    Add-ReplayRecordForCurrentTask -Role ("gemini-" + $replayPurpose) -Model $Model -Mode $Purpose -Prompt $Prompt -Response $responseText `
      -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $costUsd -Status 'ok' -ErrorType $null -Provider 'gemini'
    return $responseText
  } catch {
    $replayPurpose = if ([string]::IsNullOrWhiteSpace($Purpose)) { 'general' } else { $Purpose }
    Add-ReplayRecordForCurrentTask -Role ("gemini-" + $replayPurpose) -Model $Model -Mode $Purpose -Prompt $Prompt -Response '' `
      -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'error' -ErrorType 'gemini_error' -Provider 'gemini'
    return $null
  }
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
function Get-CurrentMemoryChannel {
  # Channel slug to stamp on new memories. Driver-pinned/effective channel wins over
  # the UI's active channel so an in-flight task stays channel-local if the UI switches.
  $effectiveCmd = Get-Command -Name 'Get-EffectiveChannel' -ErrorAction SilentlyContinue
  if ($null -ne $effectiveCmd) {
    try { $s = [string](Get-EffectiveChannel); if (-not [string]::IsNullOrWhiteSpace($s)) { return $s } } catch {}
  }
  $activeCmd = Get-Command -Name 'Get-ActiveChannel' -ErrorAction SilentlyContinue
  if ($null -ne $activeCmd) {
    try { $s = [string](Get-ActiveChannel); if (-not [string]::IsNullOrWhiteSpace($s)) { return $s } } catch {}
  }
  return 'main'
}

function Assert-MemoryWriteAllowed {
  param([string]$TargetSlug)
  if ([string]::IsNullOrWhiteSpace($TargetSlug)) { $TargetSlug = Get-CurrentMemoryChannel }
  $current = Get-CurrentMemoryChannel
  if ($TargetSlug -eq 'main' -and $current -ne 'main') {
    throw 'Bridge memory is read-only from project channels'
  }
}

function Add-Memory {
  # Embed $Text and append a memory record. Returns the new id, or $null.
  # -Channel: explicit channel slug; default = current active channel.
  # -Shared:  if $true, memory is recallable inside the current channel store.
  param([string]$Text, [string[]]$Tags = @(), [string]$Source = 'task', [double]$Importance = 0.5, [string]$Channel = $null, [bool]$Shared = $false)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  Assert-MemoryWriteAllowed -TargetSlug $Channel
  $scope = Get-MemoryScope -Slug $Channel
  $vec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_DOCUMENT'
  if (-not $vec) { return $null }
  $dir = [string]$scope.memory_root
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $rec = [ordered]@{
    id         = [guid]::NewGuid().ToString('N')
    ts         = (Get-Date).ToUniversalTime().ToString('o')
    source     = $Source
    tags       = @($Tags)
    importance = [double]$Importance
    pinned     = $false
    channel    = [string]$Channel
    shared     = [bool]$Shared
    text       = [string]$Text
    vec        = @($vec)
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 6)
  $storePath = [string]$scope.memory_store
  Use-BridgeLock ({ Add-Content -LiteralPath $storePath -Value $line -Encoding UTF8 }.GetNewClosure())
  return $rec.id
}

function Get-MemoryChannel {
  # Read channel from a memory record. Legacy records without 'channel' field are treated
  # as belonging to 'main' (where everything lived before phase 4).
  param($Mem)
  if (-not $Mem) { return 'main' }
  try {
    if ($Mem.PSObject.Properties['channel']) {
      $c = [string]$Mem.channel
      if (-not [string]::IsNullOrWhiteSpace($c)) { return $c }
    }
  } catch {}
  return 'main'
}

function Test-MemoryShared {
  # Returns $true if a memory is marked shared inside its channel store.
  param($Mem)
  if (-not $Mem) { return $false }
  try {
    if ($Mem.PSObject.Properties['shared']) { return [bool]$Mem.shared }
  } catch {}
  return $false
}

function Test-MemoryVisibleInChannel {
  # Should this memory be recalled when working in $Channel?
  # YES if: shared inside the current store, OR its channel matches.
  param($Mem, [string]$Channel)
  if (Test-MemoryShared $Mem) { return $true }
  $mc = Get-MemoryChannel $Mem
  return ($mc -eq $Channel)
}

function Get-AllMemories {
  param([string]$Channel = $null)
  $p = Get-MemoryStorePath -Slug $Channel
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    [void]$out.Add($m)
  }
  return @($out.ToArray())
}

function Select-MemoryHits {
  param($Mems, $QueryVector, [int]$TopK, [double]$MinScore)
  if (-not $Mems -or @($Mems).Count -eq 0) { return @() }
  $scored = foreach ($m in @($Mems)) {
    $sim = Get-CosineSimilarity -A $QueryVector -B $m.vec
    [pscustomobject]@{ Score = [double]$sim; Mem = $m }
  }
  return @($scored | Where-Object { $_.Score -ge $MinScore } | Sort-Object -Property Score -Descending | Select-Object -First $TopK)
}

function Set-MemoryHitsLastRecalled {
  param([string]$StoreSlug, $Hits)
  try {
    if (-not $Hits -or @($Hits).Count -eq 0) { return }
    $now = Get-Date
    $allow = $true
    if ($null -ne $script:LastRecallFlushTs) {
      if (($now - $script:LastRecallFlushTs).TotalSeconds -lt $script:RecallFlushMinIntervalSec) { $allow = $false }
    }
    if (-not $allow) { return }
    $all = @(Get-AllMemories -Channel $StoreSlug)
    $idSet = @{}
    foreach ($h in @($Hits)) { $idSet[[string]$h.Mem.id] = $true }
    $stampedAny = $false
    foreach ($m in $all) {
      if ($idSet.ContainsKey([string]$m.id)) {
        $m | Add-Member -NotePropertyName lastRecalledAt -NotePropertyValue ($now.ToUniversalTime().ToString('o')) -Force
        $stampedAny = $true
      }
    }
    if ($stampedAny) {
      Save-AllMemories -Mems $all -Channel $StoreSlug
      $script:LastRecallFlushTs = $now
    }
  } catch {}
}

function Search-Memory {
  # Returns array of [pscustomobject]{ Score; Mem } sorted by score desc.
  # Project channels search their own memory store first, then bridge memory read-only.
  # -Channel: $null/'' = effective channel; '__all__' = bypass record-level filter in current store.
  # -ExcludeTag accepts either a single legacy string or a string array.
  param([string]$Query, [int]$TopK = 0, [double]$MinScore = -1, [string]$RequireTag = '', $ExcludeTag = '', [string]$Channel = $null)
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return @() }
  if ($TopK -le 0)    { $TopK = [int]$mc.recallTopK }
  if ($MinScore -lt 0) { $MinScore = [double]$mc.recallMinScore }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  $storeSlug = if ($Channel -eq '__all__') { Get-CurrentMemoryChannel } else { $Channel }
  $scope = Get-MemoryScope -Slug $storeSlug
  $qvec = Get-Embedding -Text $Query -TaskType 'RETRIEVAL_QUERY'
  if (-not $qvec) { return @() }

  $mems = @(Get-AllMemories -Channel $storeSlug)
  if (-not [string]::IsNullOrWhiteSpace($RequireTag)) {
    $mems = @($mems | Where-Object { @($_.tags) -contains $RequireTag })
  }
  foreach ($tag in @($ExcludeTag)) {
    if ([string]::IsNullOrWhiteSpace($tag)) { continue }
    $mems = @($mems | Where-Object { -not (@($_.tags) -contains $tag) })
  }
  if ($Channel -ne '__all__') {
    $mems = @($mems | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel $Channel })
  }
  $result = @(Select-MemoryHits -Mems $mems -QueryVector $qvec -TopK $TopK -MinScore $MinScore)
  Set-MemoryHitsLastRecalled -StoreSlug $storeSlug -Hits $result

  if (-not [bool]$scope.is_bridge -and $Channel -ne '__all__') {
    $remain = [Math]::Max(0, $TopK - @($result).Count)
    $bridgeCap = [Math]::Min(2, $remain)
    if ($bridgeCap -gt 0) {
      $bridgeMems = @(Get-AllMemories -Channel 'main')
      if (-not [string]::IsNullOrWhiteSpace($RequireTag)) {
        $bridgeMems = @($bridgeMems | Where-Object { @($_.tags) -contains $RequireTag })
      }
      foreach ($tag in @($ExcludeTag)) {
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        $bridgeMems = @($bridgeMems | Where-Object { -not (@($_.tags) -contains $tag) })
      }
      $bridgeMems = @($bridgeMems | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel 'main' })
      $bridgeHits = @(Select-MemoryHits -Mems $bridgeMems -QueryVector $qvec -TopK $bridgeCap -MinScore $MinScore)
      foreach ($h in $bridgeHits) {
        $h.Mem | Add-Member -NotePropertyName readonly_source -NotePropertyValue 'bridge' -Force
      }
      if ($bridgeHits.Count -gt 0) { $result = @($result + $bridgeHits) }
    }
  }
  return $result
}

function Get-MemoryRecall {
  # Formatted block to inject into a prompt. '' when nothing relevant / disabled / offline.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return '' }
  try { $hits = Search-Memory -Query $TaskText -ExcludeTag @('skill','skill-rejected') } catch { return '' }
  if (-not $hits -or @($hits).Count -eq 0) { return '' }
  $maxChars = [int]$mc.maxInjectChars
  $sb = New-Object System.Text.StringBuilder
  foreach ($h in $hits) {
    $t = ([string]$h.Mem.text).Trim() -replace '\s+', ' '
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    if ($h.Mem.PSObject.Properties['readonly_source'] -and [string]$h.Mem.readonly_source -eq 'bridge') {
      $t = "[FROM BRIDGE - readonly] $t"
    }
    $pct = [int]([Math]::Round([double]$h.Score * 100))
    $entry = "- ($pct%) $t"
    if ($sb.Length + $entry.Length + 1 -gt $maxChars) { break }
    [void]$sb.AppendLine($entry)
  }
  $bodyTxt = $sb.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($bodyTxt)) { return '' }
  return "=== ДОЛГОВРЕМЕННАЯ ПАМЯТЬ (релевантное, semantic) ===`n$bodyTxt"
}

function Get-SkillRecall {
  # Formatted procedural playbook block to inject into a prompt. '' on any failure.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return '' }
    $hits = Search-Memory -Query $TaskText -RequireTag 'skill' -TopK ([int]$mc.skillTopK) -MinScore ([double]$mc.skillMinScore)
    if (-not $hits -or @($hits).Count -eq 0) { return '' }
    $maxChars = [int]$mc.skillMaxInjectChars
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $hits) {
      $t = ([string]$h.Mem.text).Trim() -replace '\s+', ' '
      if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
      if ($h.Mem.PSObject.Properties['readonly_source'] -and [string]$h.Mem.readonly_source -eq 'bridge') {
        $t = "[FROM BRIDGE - readonly] $t"
      }
      $pct = [int]([Math]::Round([double]$h.Score * 100))
      $entry = "- ($pct%) $t"
      if ($sb.Length + $entry.Length + 1 -gt $maxChars) { break }
      [void]$sb.AppendLine($entry)
    }
    $bodyTxt = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($bodyTxt)) { return '' }
    return "=== ПЛЕЙБУК (релевантный навык) ===`n$bodyTxt"
  } catch { return '' }
}

function Get-AntiSkillRecall {
  # Formatted warning block for failed past approaches. '' on any failure.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return '' }
    $topK = [Math]::Max(1, [Math]::Min(5, [int]$mc.antiSkillTopK))
    $minScore = [Math]::Max(0.1, [Math]::Min(0.95, [double]$mc.antiSkillMinScore))
    $maxChars = [Math]::Max(200, [Math]::Min(2000, [int]$mc.antiSkillMaxInjectChars))
    $hits = Search-Memory -Query $TaskText -RequireTag 'skill-rejected' -TopK $topK -MinScore $minScore
    if (-not $hits -or @($hits).Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $hits) {
      $t = ([string]$h.Mem.text).Trim() -replace '\s+', ' '
      if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
      if ($h.Mem.PSObject.Properties['readonly_source'] -and [string]$h.Mem.readonly_source -eq 'bridge') {
        $t = "[FROM BRIDGE - readonly] $t"
      }
      $pct = [int]([Math]::Round([double]$h.Score * 100))
      $entry = "- ($pct%) $t"
      if ($sb.Length + $entry.Length + 1 -gt $maxChars) { break }
      [void]$sb.AppendLine($entry)
    }
    $bodyTxt = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($bodyTxt)) { return '' }
    return "=== НЕ ПОВТОРЯТЬ (прошлые провалы) ===`n$bodyTxt"
  } catch { return '' }
}

function Add-SkillMemory {
  # Extract and store a reusable procedure from an actual task transcript. Never throws.
  param([string]$TaskText, [string]$Transcript)
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return $null }
    if ([string]::IsNullOrWhiteSpace($Transcript)) { return $null }
    $task = [string]$TaskText; if ($task.Length -gt 1500) { $task = $task.Substring(0, 1500) }
    $tr = [string]$Transcript; if ($tr.Length -gt 10000) { $tr = $tr.Substring($tr.Length - 10000) }
    $prompt = @"
Ты — библиотекарь навыков ИИ-моста Claude+Codex.
Из фактического transcript извлеки ТОЛЬКО переиспользуемую процедуру, которая пригодится в будущих похожих задачах.
Не давай общих советов, не выдумывай шаги, не пересказывай результат задачи.

Если в transcript нет нетривиального переиспользуемого навыка, ответь ровно:
NO_SKILL

Иначе ответь строго в таком формате, без markdown-забора:
Когда применять: ...
Шаги:
1. ...
2. ...
Грабли: ...
Проверка: ...

ЗАДАЧА:
$task

TRANSCRIPT:
$tr
"@
    $raw = Invoke-LLM -Purpose 'gate' -Prompt $prompt -TimeoutSec 60 -Temperature 0.1
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $txt = ([string]$raw -replace '```(?:text|markdown|md)?','' -replace '```','').Trim()
    if ($txt -eq 'NO_SKILL') { return $null }
    if ($txt.Length -lt 120) { return $null }
    if ($txt.Length -gt 1800) { $txt = $txt.Substring(0, 1800).Trim() }
    return (Add-Memory -Text $txt -Tags @('skill') -Source 'skill' -Importance ([double]$mc.skillImportance))
  } catch { return $null }
}

function Add-StudyLessons {
  # Distill a final study Markdown report into 1-3 durable lessons. Returns count; never throws.
  param([string]$ReportPath, [string]$TaskText = '')
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return 0 }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) { return 0 }
    if ([System.IO.Path]::GetExtension([string]$ReportPath) -ine '.md') { return 0 }
    if (-not (Test-Path -LiteralPath $ReportPath)) { return 0 }
    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($report)) { return 0 }
    if ($report.Length -gt 6000) { $report = $report.Substring(0, 6000) }
    $task = [string]$TaskText; if ($task.Length -gt 1500) { $task = $task.Substring(0, 1500) }
    $prompt = @"
Ты — фильтр долговременной памяти ИИ-моста.
Из итогового study-отчёта выдели 1-3 урока, которые полезно помнить в будущих задачах.
Пиши только устойчивые выводы: архитектурные факты, грабли, правила работы, проверенные ограничения.
Не сохраняй пересказ отчёта и очевидные общие советы.

Верни СТРОГО JSON-массив строк без markdown и пояснений:
["урок 1", "урок 2"]

ЗАДАЧА:
$task

ОТЧЁТ:
$report
"@
    $raw = Invoke-LLM -Purpose 'gate' -Prompt $prompt -TimeoutSec 60 -Temperature 0.1
    if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
    $clean = ([string]$raw -replace '```json','' -replace '```','').Trim()
    $mt = [regex]::Match($clean, '(?s)\[.*\]')
    if (-not $mt.Success) { return 0 }
    try { $items = @($mt.Value | ConvertFrom-Json) } catch { return 0 }
    $count = 0
    foreach ($item in $items) {
      $lesson = ''
      if ($null -eq $item) { continue }
      if ($item -is [string]) {
        $lesson = [string]$item
      } else {
        try {
          if ($item.PSObject.Properties.Name -contains 'lesson') { $lesson = [string]$item.lesson }
          elseif ($item.PSObject.Properties.Name -contains 'text') { $lesson = [string]$item.text }
          elseif ($item.PSObject.Properties.Name -contains 'fact') { $lesson = [string]$item.fact }
          else { $lesson = ($item | ConvertTo-Json -Compress -Depth 4) }
        } catch { $lesson = [string]$item }
      }
      $lesson = ($lesson.Trim() -replace '\s+', ' ')
      if ([string]::IsNullOrWhiteSpace($lesson)) { continue }
      if ($lesson.Length -gt 800) { $lesson = $lesson.Substring(0, 800).Trim() }
      $id = Add-Memory -Text $lesson -Tags @('lesson','study') -Source 'study' -Importance 0.7
      if ($id) { $count++ }
      if ($count -ge 3) { break }
    }
    return $count
  } catch { return 0 }
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
  # Drop near-duplicate memories inside the same channel/shared scope, keeping higher importance.
  # Returns number removed. Pure-local, no API cost.
  param([double]$Threshold = 0)
  $mc = Get-MemoryConfig
  if ($Threshold -le 0) {
    $dc = $null
    try { if ($mc.ContainsKey('dedupCosine')) { $dc = [double]$mc.dedupCosine } } catch {}
    if ($null -eq $dc) { $dc = [double]$mc.dedupThreshold }
    $Threshold = $dc
  }
  $mems = @(Get-AllMemories)
  if ($mems.Count -lt 2) { return 0 }
  $arr = foreach ($m in $mems) { [pscustomobject]@{ Mem = $m; Keep = $true } }
  $arr = @($arr)
  for ($i = 0; $i -lt $arr.Count; $i++) {
    if (-not $arr[$i].Keep) { continue }
    for ($j = $i + 1; $j -lt $arr.Count; $j++) {
      if (-not $arr[$j].Keep) { continue }
      $iScope = if (Test-MemoryShared $arr[$i].Mem) { '__shared__' } else { Get-MemoryChannel $arr[$i].Mem }
      $jScope = if (Test-MemoryShared $arr[$j].Mem) { '__shared__' } else { Get-MemoryChannel $arr[$j].Mem }
      if ($iScope -ne $jScope) { continue }
      $iSkill = @($arr[$i].Mem.tags) -contains 'skill'
      $jSkill = @($arr[$j].Mem.tags) -contains 'skill'
      if ($iSkill -ne $jSkill) { continue }
      $thr = if ($iSkill -and $jSkill) { [double]$mc.skillDedupThreshold } else { $Threshold }
      $sim = Get-CosineSimilarity -A $arr[$i].Mem.vec -B $arr[$j].Mem.vec
      if ($sim -ge $thr) {
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

function Invoke-MemoryAgePrune {
  # Drop old, low-importance, unused, non-pinned memories. Returns number removed.
  param([int]$AgeDays = 0, [double]$MinImportance = -1, [int]$UnusedDays = 0)
  $mc = Get-MemoryConfig
  if ($AgeDays -le 0) { $AgeDays = [int]$mc.ageDaysPrune }
  if ($MinImportance -lt 0) { $MinImportance = [double]$mc.minImportanceKeep }
  if ($UnusedDays -le 0) { $UnusedDays = [int]$mc.unusedDaysPrune }
  $mems = @(Get-AllMemories)
  if ($mems.Count -eq 0) { return 0 }
  $now = Get-Date
  $kept = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in $mems) {
    $pinned = [bool]($m.PSObject.Properties['pinned'] -and $m.pinned)
    if ($pinned) { [void]$kept.Add($m); continue }
    $imp = 0.5
    try { $imp = [double]$m.importance } catch {}
    if ($imp -ge $MinImportance) { [void]$kept.Add($m); continue }
    $ts = $null
    try {
      if ($m.PSObject.Properties['ts'] -and -not [string]::IsNullOrWhiteSpace([string]$m.ts)) {
        $ts = [datetime]::Parse([string]$m.ts)
      }
    } catch {}
    if ($null -eq $ts) { [void]$kept.Add($m); continue }
    if (($now - $ts).TotalDays -lt $AgeDays) { [void]$kept.Add($m); continue }
    $lastRecall = $null
    try {
      if ($m.PSObject.Properties['lastRecalledAt'] -and -not [string]::IsNullOrWhiteSpace([string]$m.lastRecalledAt)) {
        $lastRecall = [datetime]::Parse([string]$m.lastRecalledAt)
      }
    } catch {}
    if ($null -ne $lastRecall) {
      if (($now - $lastRecall).TotalDays -lt $UnusedDays) { [void]$kept.Add($m); continue }
    }
  }
  $removed = $mems.Count - $kept.Count
  if ($removed -gt 0) { Save-AllMemories @($kept.ToArray()) }
  return $removed
}

# ---- management (used by the web UI) ----
function Save-AllMemories {
  param($Mems, [string]$Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  Assert-MemoryWriteAllowed -TargetSlug $Channel
  $dir = Get-MemoryDir -Slug $Channel
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $storePath = Get-MemoryStorePath -Slug $Channel
  $lines = @($Mems | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Use-BridgeLock ({ Write-AtomicFile -Path $storePath -Content $content }.GetNewClosure())
}

function Purge-MemoryForChannel {
  # Remove only non-shared memories from a channel store; shared-in-scope knowledge survives.
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return 0 }
  try {
    $mems = @(Get-AllMemories -Channel $Slug)
    if ($mems.Count -eq 0) { return 0 }
    $kept = @($mems | Where-Object {
      $isShared = Test-MemoryShared $_
      $ch = Get-MemoryChannel $_
      -not (($ch -eq $Slug) -and (-not $isShared))
    })
    $removed = $mems.Count - $kept.Count
    if ($removed -gt 0) { Save-AllMemories -Mems $kept -Channel $Slug }
    return $removed
  } catch {
    return 0
  }
}

function Get-MemoriesView {
  # All memories WITHOUT the heavy vec arrays, for the API/UI.
  # -Channel: '' or $null = active; '__all__' = all channels (admin view).
  param([string]$Channel = '__all__')
  $storeSlug = if ($Channel -eq '__all__') { Get-CurrentMemoryChannel } else { $Channel }
  $all = @(Get-AllMemories -Channel $storeSlug)
  if (-not [string]::IsNullOrWhiteSpace($Channel) -and $Channel -ne '__all__') {
    $all = @($all | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel $Channel })
  }
  $out = foreach ($m in $all) {
    [pscustomobject]@{
      id         = [string]$m.id
      ts         = [string]$m.ts
      source     = [string]$m.source
      tags       = @($m.tags)
      importance = [double]$m.importance
      pinned     = [bool]($m.PSObject.Properties['pinned'] -and $m.pinned)
      channel    = (Get-MemoryChannel $m)
      shared     = (Test-MemoryShared $m)
      text       = [string]$m.text
    }
  }
  return @($out)
}

function Remove-Memory {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $target = Get-CurrentMemoryChannel
  $mems = @(Get-AllMemories -Channel $target)
  $kept = @($mems | Where-Object { [string]$_.id -ne $Id })
  if ($kept.Count -eq $mems.Count) { return $false }
  Save-AllMemories -Mems $kept -Channel $target
  return $true
}

function Set-Memory {
  # Edit a memory in place. $Text re-embeds. Pass $null to leave a field unchanged.
  param([string]$Id, $Importance = $null, $Text = $null, $Pinned = $null, $Shared = $null, $Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $target = Get-CurrentMemoryChannel
  $mems = @(Get-AllMemories -Channel $target)
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
    if ($null -ne $Shared) {
      $m | Add-Member -NotePropertyName shared -NotePropertyValue ([bool]$Shared) -Force
    }
    if ($null -ne $Channel -and -not [string]::IsNullOrWhiteSpace([string]$Channel)) {
      $m | Add-Member -NotePropertyName channel -NotePropertyValue ([string]$Channel) -Force
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
  Save-AllMemories -Mems $mems -Channel $target
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
