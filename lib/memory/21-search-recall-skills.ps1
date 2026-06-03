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

function Search-ProjectMemory {
  # Typed memory retrieval for project context packs. Uses the same vectors/store
  # as Search-Memory but filters by kind/trust/status before scoring.
  param(
    [string]$Query,
    [string[]]$Kind = @(),
    [string[]]$Trust = @(),
    [string[]]$Status = @('active'),
    [int]$TopK = 0,
    [double]$MinScore = -1,
    [string]$Channel = $null
  )
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return @() }
  if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
  if ($TopK -le 0) { $TopK = [int]$mc.recallTopK }
  if ($MinScore -lt 0) { $MinScore = [double]$mc.recallMinScore }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  $storeSlug = if ($Channel -eq '__all__') { Get-CurrentMemoryChannel } else { $Channel }

  $mems = @(Get-AllMemories -Channel $storeSlug)
  if ($Channel -ne '__all__') {
    $mems = @($mems | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel $Channel })
  }
  if ($Kind -and @($Kind).Count -gt 0) {
    $kindSet = @{}
    foreach ($k in @($Kind)) { if (-not [string]::IsNullOrWhiteSpace($k)) { $kindSet[[string]$k] = $true } }
    if ($kindSet.Count -gt 0) { $mems = @($mems | Where-Object { $kindSet.ContainsKey((Get-MemoryKind $_)) }) }
  }
  if ($Trust -and @($Trust).Count -gt 0) {
    $trustSet = @{}
    foreach ($t in @($Trust)) { if (-not [string]::IsNullOrWhiteSpace($t)) { $trustSet[[string]$t] = $true } }
    if ($trustSet.Count -gt 0) { $mems = @($mems | Where-Object { $trustSet.ContainsKey((Get-MemoryTrust $_)) }) }
  }
  if ($Status -and @($Status).Count -gt 0) {
    $statusSet = @{}
    foreach ($s in @($Status)) { if (-not [string]::IsNullOrWhiteSpace($s)) { $statusSet[[string]$s] = $true } }
    if ($statusSet.Count -gt 0) { $mems = @($mems | Where-Object { $statusSet.ContainsKey((Get-MemoryStatus $_)) }) }
  }
  if ($mems.Count -eq 0) { return @() }

  $qvec = Get-Embedding -Text $Query -TaskType 'RETRIEVAL_QUERY'
  if (-not $qvec) { return @() }
  $result = @(Select-MemoryHits -Mems $mems -QueryVector $qvec -TopK $TopK -MinScore $MinScore)
  Set-MemoryHitsLastRecalled -StoreSlug $storeSlug -Hits $result
  return @($result)
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
