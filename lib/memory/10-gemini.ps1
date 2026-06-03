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
