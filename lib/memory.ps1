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
    skillTopK = 2
    skillMinScore = 0.55
    skillMaxInjectChars = 600
    skillImportance = 0.8
    skillDedupThreshold = 0.96
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
    return Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSec
  } catch {
    $detail = ''
    try {
      $stream = $_.Exception.Response.GetResponseStream()
      $detail = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
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
    return ,@($r.embedding.values | ForEach-Object { [double]$_ })
  } catch { return $null }
}

function Invoke-GeminiChat {
  # Returns the model's text, or $null on any failure.
  param([string]$Model, [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.2, [string]$Purpose = '')
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
    try {
      $pt = 0; $ct = 0
      if ($r.usageMetadata) {
        if ($null -ne $r.usageMetadata.promptTokenCount) { $pt = [int]$r.usageMetadata.promptTokenCount }
        if ($null -ne $r.usageMetadata.candidatesTokenCount) { $ct = [int]$r.usageMetadata.candidatesTokenCount }
      }
      $null = Add-UsageRecord -Kind paid -Provider 'gemini' -Model $Model -Purpose $Purpose -PromptTokens $pt -CompletionTokens $ct -Status 'ok'
    } catch {}
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
function Get-CurrentMemoryChannel {
  # Channel slug to stamp on new memories. Falls back to 'main' (legacy/no-channels-yet).
  if (Get-Command Get-ActiveChannel -ErrorAction SilentlyContinue) {
    try { $s = [string](Get-ActiveChannel); if (-not [string]::IsNullOrWhiteSpace($s)) { return $s } } catch {}
  }
  return 'main'
}

function Add-Memory {
  # Embed $Text and append a memory record. Returns the new id, or $null.
  # -Channel: explicit channel slug; default = current active channel.
  # -Shared:  if $true, memory is recallable from EVERY channel (cross-channel knowledge).
  param([string]$Text, [string[]]$Tags = @(), [string]$Source = 'task', [double]$Importance = 0.5, [string]$Channel = $null, [bool]$Shared = $false)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  $vec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_DOCUMENT'
  if (-not $vec) { return $null }
  $dir = Get-MemoryDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
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
  Use-BridgeLock ({ Add-Content -LiteralPath (Get-MemoryStorePath) -Value $line -Encoding UTF8 }.GetNewClosure())
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
  # Returns $true if a memory is marked shared (cross-channel).
  param($Mem)
  if (-not $Mem) { return $false }
  try {
    if ($Mem.PSObject.Properties['shared']) { return [bool]$Mem.shared }
  } catch {}
  return $false
}

function Test-MemoryVisibleInChannel {
  # Should this memory be recalled when working in $Channel?
  # YES if: shared OR no channel set (legacy) AND $Channel == 'main', OR its channel matches.
  param($Mem, [string]$Channel)
  if (Test-MemoryShared $Mem) { return $true }
  $mc = Get-MemoryChannel $Mem
  return ($mc -eq $Channel)
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
  # -Channel: filter so only memories from $Channel + 'shared' memories are searched.
  #          $null/'' = use active channel; '__all__' = bypass filter (admin/UI views).
  param([string]$Query, [int]$TopK = 0, [double]$MinScore = -1, [string]$RequireTag = '', [string]$ExcludeTag = '', [string]$Channel = $null)
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return @() }
  if ($TopK -le 0)    { $TopK = [int]$mc.recallTopK }
  if ($MinScore -lt 0) { $MinScore = [double]$mc.recallMinScore }
  $mems = @(Get-AllMemories)
  if (-not [string]::IsNullOrWhiteSpace($RequireTag)) {
    $mems = @($mems | Where-Object { @($_.tags) -contains $RequireTag })
  }
  if (-not [string]::IsNullOrWhiteSpace($ExcludeTag)) {
    $mems = @($mems | Where-Object { -not (@($_.tags) -contains $ExcludeTag) })
  }
  # Channel filter (phase 4): default to active channel; '__all__' skips filtering.
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  if ($Channel -ne '__all__') {
    $mems = @($mems | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel $Channel })
  }
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
  try { $hits = Search-Memory -Query $TaskText -ExcludeTag 'skill' } catch { return '' }
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

# ---- management (used by the web UI) ----
function Save-AllMemories {
  param($Mems)
  $lines = @($Mems | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Use-BridgeLock ({ Write-AtomicFile -Path (Get-MemoryStorePath) -Content $content }.GetNewClosure())
}

function Get-MemoriesView {
  # All memories WITHOUT the heavy vec arrays, for the API/UI.
  # -Channel: '' or $null = active; '__all__' = all channels (admin view).
  param([string]$Channel = '__all__')
  $all = @(Get-AllMemories)
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
  $mems = @(Get-AllMemories)
  $kept = @($mems | Where-Object { [string]$_.id -ne $Id })
  if ($kept.Count -eq $mems.Count) { return $false }
  Save-AllMemories $kept
  return $true
}

function Set-Memory {
  # Edit a memory in place. $Text re-embeds. Pass $null to leave a field unchanged.
  param([string]$Id, $Importance = $null, $Text = $null, $Pinned = $null, $Shared = $null, $Channel = $null)
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
