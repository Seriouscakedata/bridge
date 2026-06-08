# backlog-core.ps1 -- backlog classification, picker, operator batch, and self-execution helpers.

#region Backlog prioritization helpers

function Get-IdeaSeverityRank {
  # Severity priority for backlog picker: critical findings before warnings, warnings
  # before info, info before plain ideas. Lower rank = higher priority.
  # 2026-05-28: introduced so audit findings outrank regular ideas in Get-NextRunnableIdea.
  param([AllowNull()]$Idea)
  if ($null -eq $Idea) { return 3 }
  $sev = ''
  try {
    if ($Idea.PSObject.Properties.Name -contains 'severity' -and $null -ne $Idea.severity) {
      $sev = ([string]$Idea.severity).Trim().ToLowerInvariant()
    }
  } catch { $sev = '' }
  switch ($sev) {
    'critical' { return 0 }
    'crit'     { return 0 }
    'warning'  { return 1 }
    'warn'     { return 1 }
    'info'     { return 2 }
    default    { return 3 }
  }
}

#endregion Backlog prioritization helpers

#region Backlog failure classes, curator, and picker API

function Get-BacklogFailureClassValues {
  return @('flaky', 'spec-unclear', 'blocked', 'real-bug')
}

function Normalize-BacklogFailureClass {
  param([AllowNull()][string]$Value)
  $v = ([string]$Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($v)) { return '' }
  $v = ($v -replace '\s+', '-')
  switch ($v) {
    'flaky'        { return 'flaky' }
    'flake'        { return 'flaky' }
    'transient'    { return 'flaky' }
    'intermittent' { return 'flaky' }
    'spec-unclear' { return 'spec-unclear' }
    'unclear-spec' { return 'spec-unclear' }
    'unclear'      { return 'spec-unclear' }
    'ambiguous'    { return 'spec-unclear' }
    'blocked'      { return 'blocked' }
    'blocker'      { return 'blocked' }
    'real-bug'     { return 'real-bug' }
    'bug'          { return 'real-bug' }
    'realbug'      { return 'real-bug' }
    default {
      foreach ($cls in (Get-BacklogFailureClassValues)) {
        if ($v -match ('(?<![a-z0-9-])' + [regex]::Escape($cls) + '(?![a-z0-9-])')) { return $cls }
      }
      return ''
    }
  }
}

function Get-BacklogFailureClass {
  param([AllowNull()]$Item)
  if ($null -eq $Item) { return '' }
  try {
    if ($Item.PSObject.Properties.Name -contains 'fail_class') {
      return (Normalize-BacklogFailureClass ([string]$Item.fail_class))
    }
  } catch {}
  return ''
}

function New-BacklogFailureClassPrompt {
  param([Parameter(Mandatory=$true)]$Item)
  $id = ''
  $text = ''
  $reason = ''
  $status = ''
  $tags = ''
  try { $id = [string]$Item.id } catch {}
  try { $text = ([string]$Item.text -replace '\s+', ' ').Trim() } catch {}
  try { $reason = ([string]$Item.reason -replace '\s+', ' ').Trim() } catch {}
  try { $status = [string]$Item.status } catch {}
  try { $tags = (@($Item.tags | ForEach-Object { [string]$_ }) -join ',') } catch {}
  if ($text.Length -gt 1800) { $text = $text.Substring(0, 1800) + '...' }
  if ($reason.Length -gt 800) { $reason = $reason.Substring(0, 800) + '...' }

  return @"
Classify this failed autonomous backlog task into exactly one class:
- flaky: transient timeout, model timeout, restart race, intermittent infrastructure issue.
- spec-unclear: task request/acceptance/touch-set is ambiguous or internally contradictory.
- blocked: cannot proceed safely because it requires operator approval, forbidden scope, missing dependency, unavailable secret/service, or hard constraint conflict.
- real-bug: implementation/test failed because bridge code or behavior is actually wrong.

Return only one token from this set: flaky, spec-unclear, blocked, real-bug

Task id: $id
Status: $status
Tags: $tags
Failure reason: $reason
Task text: $text
"@
}

function Invoke-BacklogFailureClassModel {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [string]$Model = 'gemini-2.5-flash-lite',
    [scriptblock]$Classifier = $null,
    [int]$TimeoutSec = 45
  )
  if ($Classifier) {
    return (Normalize-BacklogFailureClass ([string](& $Classifier $Item)))
  }

  if (-not (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue)) {
    $fallbackRoot = (Get-BacklogFallbackBridgeRoot).Replace("'", "''")
    Set-Item -Path Function:\Get-BridgeRoot -Value ([scriptblock]::Create("return '$fallbackRoot'")) -Force
  }
  if (-not (Get-Command Add-ReplayRecordForCurrentTask -ErrorAction SilentlyContinue)) {
    function global:Add-ReplayRecordForCurrentTask { param($Role, $Model, $Mode, $Prompt, $Response, $LatencyMs, $CostUsd, $Status, $ErrorType, $Provider) }
  }
  if (-not (Get-Command Get-SecretsPath -ErrorAction SilentlyContinue)) {
    $privateSecrets = Join-Path (Join-Path ([string]$env:USERPROFILE) '.bridge-private') 'secrets.json'
    $legacySecrets = Join-Path (Get-BacklogFallbackBridgeRoot) 'secrets.json'
    $secretsPath = ''
    if (Test-Path -LiteralPath $privateSecrets) { $secretsPath = $privateSecrets }
    elseif (Test-Path -LiteralPath $legacySecrets) { $secretsPath = $legacySecrets }
    if (-not [string]::IsNullOrWhiteSpace($secretsPath)) {
      $escapedSecrets = $secretsPath.Replace("'", "''")
      Set-Item -Path Function:\Get-SecretsPath -Value ([scriptblock]::Create("return '$escapedSecrets'")) -Force
    }
  }
  if (-not (Get-Command Invoke-LLMProvider -ErrorAction SilentlyContinue) -and -not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
    $memoryLib = Join-Path (Get-BacklogLibraryDir) 'memory.ps1'
    if (Test-Path -LiteralPath $memoryLib) { . $memoryLib }
    $llmLib = Join-Path (Get-BacklogLibraryDir) 'llm.ps1'
    if (Test-Path -LiteralPath $llmLib) { . $llmLib }
  }

  $prompt = New-BacklogFailureClassPrompt -Item $Item
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $raw = $null
    try {
      if (Get-Command Invoke-LLMProvider -ErrorAction SilentlyContinue) {
        $raw = Invoke-LLMProvider -Model $Model -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.0 -Purpose 'failure-classifier'
      } elseif (Get-Command Invoke-LLM -ErrorAction SilentlyContinue) {
        $raw = Invoke-LLM -Model $Model -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.0 -Purpose 'failure-classifier'
      }
    } catch {
      $raw = $null
    }
    $cls = Normalize-BacklogFailureClass ([string]$raw)
    if (-not [string]::IsNullOrWhiteSpace($cls)) { return $cls }
    $prompt += "`n`nYour previous answer was invalid. Return exactly one allowed token and nothing else."
  }
  return ''
}

function Get-BacklogFailureClassFallback {
  param([AllowNull()]$Item)
  $text = ''
  $reason = ''
  try { $text = ([string]$Item.text).ToLowerInvariant() } catch {}
  try { $reason = ([string]$Item.reason).ToLowerInvariant() } catch {}
  $combined = ($reason + "`n" + $text)
  if ($combined -match '(operator|approval|forbidden|hard constraint|touch-?set|scope|blocked|held|control plane|watchdog|supervisor|circuit.?breaker|secret|missing dependency|outside)') {
    return 'blocked'
  }
  if ($combined -match '(timeout|timed out|zero-output|restart|race|transient|network|rate limit|429|503|flaky|intermittent)') {
    return 'flaky'
  }
  if ($combined -match '(unclear|ambiguous|spec|acceptance pending|contradict|н[её]ясн|непонят|противореч)') {
    return 'spec-unclear'
  }
  if ($combined -match '(parse|parser|smoke|test failed|tests failed|build failed|regression|bug|broken|exception|syntax|ошибк|слом)') {
    return 'real-bug'
  }
  return 'spec-unclear'
}

function Get-BacklogFailureClassGroups {
  param([object[]]$Items)
  $groups = [ordered]@{}
  foreach ($cls in (Get-BacklogFailureClassValues)) { $groups[$cls] = New-Object 'System.Collections.Generic.List[object]' }
  $groups['unclassified'] = New-Object 'System.Collections.Generic.List[object]'
  foreach ($item in @($Items)) {
    if ($null -eq $item) { continue }
    try { if ([string]$item.status -ne 'failed') { continue } } catch { continue }
    $cls = Get-BacklogFailureClass -Item $item
    if ([string]::IsNullOrWhiteSpace($cls)) { $cls = 'unclassified' }
    if (-not $groups.Contains($cls)) { $groups[$cls] = New-Object 'System.Collections.Generic.List[object]' }
    [void]$groups[$cls].Add($item)
  }
  return $groups
}

function Update-BacklogFailureClasses {
  param(
    [string]$BacklogPath = '',
    [string]$Model = 'gemini-2.5-flash-lite',
    [scriptblock]$Classifier = $null
  )

  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $getFailureClassFn = ${function:Get-BacklogFailureClass}
  $invokeFailureClassModelFn = ${function:Invoke-BacklogFailureClassModel}
  $setBacklogObjectPropertyFn = ${function:Set-BacklogObjectProperty}
  $writeBacklogAtomicFileFn = ${function:Write-BacklogAtomicFile}
  $getFailureClassValuesFn = ${function:Get-BacklogFailureClassValues}
  $getFailureClassFallbackFn = ${function:Get-BacklogFailureClassFallback}
  return (Invoke-BacklogLocked ({
    $usingExplicitPath = -not [string]::IsNullOrWhiteSpace($BacklogPath)
    if ($usingExplicitPath) {
      $itemsList = New-Object 'System.Collections.Generic.List[object]'
      $byId = New-Object 'System.Collections.Specialized.OrderedDictionary'
      $noId = New-Object 'System.Collections.Generic.List[object]'
      if (Test-Path -LiteralPath $BacklogPath) {
        foreach ($line in (Get-Content -LiteralPath $BacklogPath -Encoding UTF8)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          try { $parsed = $line | ConvertFrom-Json } catch { continue }
          $iid = ''
          try { $iid = [string]$parsed.id } catch { $iid = '' }
          if ([string]::IsNullOrWhiteSpace($iid)) { [void]$noId.Add($parsed); continue }
          if ($byId.Contains($iid)) { $byId[$iid] = $parsed } else { $byId.Add($iid, $parsed) }
        }
      }
      foreach ($k in $byId.Keys) { [void]$itemsList.Add($byId[$k]) }
      foreach ($v in $noId) { [void]$itemsList.Add($v) }
      $items = @($itemsList.ToArray())
    } else {
      $items = @(& $getBacklogFn)
    }
    $checked = 0
    $updated = 0
    $failed = 0
    foreach ($item in $items) {
      try { if ([string]$item.status -ne 'failed') { continue } } catch { continue }
      $checked++
      $existing = & $getFailureClassFn -Item $item
      if (-not [string]::IsNullOrWhiteSpace($existing)) {
        if ([string]$item.fail_class -ne $existing) { & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class' -Value $existing; $updated++ }
        continue
      }
      $cls = & $invokeFailureClassModelFn -Item $item -Model $Model -Classifier $Classifier
      if ([string]::IsNullOrWhiteSpace($cls)) {
        & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_error' -Value 'classifier-empty-or-invalid'
        & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_model' -Value $Model
        $cls = & $getFailureClassFallbackFn -Item $item
        & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class' -Value $cls
        & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_source' -Value 'fallback-after-llm-empty'
        & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_at' -Value ((Get-Date).ToUniversalTime().ToString('o'))
        $failed++
        $updated++
        continue
      }
      & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class' -Value $cls
      & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_model' -Value $Model
      & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_source' -Value $(if ($Classifier) { 'mock' } else { 'llm' })
      & $setBacklogObjectPropertyFn -Item $item -Name 'fail_class_at' -Value ((Get-Date).ToUniversalTime().ToString('o'))
      try {
        if ($item.PSObject.Properties.Name -contains 'fail_class_error') { $item.PSObject.Properties.Remove('fail_class_error') }
      } catch {}
      $updated++
    }
    if ($updated -gt 0 -or $failed -gt 0) {
      if ($usingExplicitPath) {
        $lines = @($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
        $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
        & $writeBacklogAtomicFileFn -Path $BacklogPath -Content $content
      } else {
        & $saveBacklogFn $items
      }
    }
    return [pscustomobject]@{
      checked = [int]$checked
      updated = [int]$updated
      failed = [int]$failed
      model = $Model
      allowed = @(& $getFailureClassValuesFn)
    }
  }.GetNewClosure()))
}

function New-BacklogLLMPriorityPrompt {
  param([object[]]$Ideas)

  $promptBuilder = New-Object System.Text.StringBuilder
  [void]$promptBuilder.AppendLine('Ты — приоритизатор задач для автономного ИИ-моста.')
  [void]$promptBuilder.AppendLine('Ниже список задач. Оцени каждую по шкале 0-100 с учётом:')
  [void]$promptBuilder.AppendLine('- Практической ценности (насколько улучшит работу моста)')
  [void]$promptBuilder.AppendLine('- Срочности (блокирует ли что-то прямо сейчас)')
  [void]$promptBuilder.AppendLine('- Важности и блокирующего эффекта для других задач')
  [void]$promptBuilder.AppendLine('- Сложности реализации: простые задачи выше только при прочих равных; сложные/избегаемые задачи не занижай автоматически')
  [void]$promptBuilder.AppendLine('- Безопасности (задачи, снижающие риски — приоритет)')
  [void]$promptBuilder.AppendLine('- Anti-avoidance: поднимай задачи, которые выглядят трудными, но устраняют повторяющиеся отказы, таймауты, broken gates или архитектурный долг')
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('Формат ответа: только JSON-массив объектов:')
  [void]$promptBuilder.AppendLine('[{"id":"<идентификатор>","score":<число 0-100>,"reason":"<одна фраза>"},...]')
  [void]$promptBuilder.AppendLine('')
  [void]$promptBuilder.AppendLine('Задачи:')
  foreach ($idea in @($Ideas)) {
    $title = ''
    try {
      if ($idea.PSObject.Properties.Name -contains 'title' -and -not [string]::IsNullOrWhiteSpace([string]$idea.title)) {
        $title = [string]$idea.title
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($title)) {
      $title = ([string]$idea.text -replace '\s+', ' ').Trim()
    }
    if ($title.Length -gt 220) { $title = $title.Substring(0, 220) + '...' }
    $effort = ''
    $value = ''
    try { $effort = [string]$idea.effort } catch { $effort = '' }
    try { $value = [string]$idea.value } catch { $value = '' }
    if ([string]::IsNullOrWhiteSpace($effort)) { $effort = 'n/a' }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = 'n/a' }
    [void]$promptBuilder.AppendLine(("ID: {0} | {1} | effort:{2} | value:{3}" -f [string]$idea.id, $title, $effort, $value))
  }
  return $promptBuilder.ToString().Trim()
}

function Get-BacklogPrioritizerModel {
  if (-not (Get-Command Get-LLMConfig -ErrorAction SilentlyContinue)) { return '' }
  try {
    $cfg = Get-LLMConfig
    foreach ($key in @('prioritizer','deep','fallback')) {
      if ($cfg -and $cfg.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$cfg[$key])) {
        return [string]$cfg[$key]
      }
    }
  } catch {}
  return ''
}

function ConvertFrom-BacklogJsonDictionary {
  param([string]$JsonText)
  if ([string]::IsNullOrWhiteSpace($JsonText)) { return $null }
  try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return $serializer.DeserializeObject([string]$JsonText)
  } catch {
    return $null
  }
}

function Get-BacklogDictionaryValue {
  param(
    [AllowNull()]$Map,
    [string]$Name,
    [AllowNull()]$Default = $null
  )
  if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Name)) { return $Default }
  try {
    if ($Map.PSObject.Methods.Name -contains 'ContainsKey' -and $Map.ContainsKey($Name)) {
      return $Map[$Name]
    }
  } catch {}
  try {
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Name)) {
      return $Map[$Name]
    }
  } catch {}
  return $Default
}

function Get-BacklogPrioritizerSettings {
  param(
    [string]$Channel = $env:BRIDGE_CHANNEL,
    [int]$IntervalMinutes = 60,
    [int]$MaxItems = 20
  )

  $settings = [ordered]@{
    Enabled = $false
    UseLLMPriority = $false
    IdleEnabled = $false
    IntervalMinutes = [int]$(if ($IntervalMinutes -gt 0) { $IntervalMinutes } else { 60 })
    MaxItems = [int]$(if ($MaxItems -gt 0) { $MaxItems } else { 20 })
    Channel = $(if ([string]::IsNullOrWhiteSpace($Channel)) { 'main' } else { [string]$Channel })
  }
  try {
    $cfgPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
    if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { return [pscustomobject]$settings }
    $raw = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]$settings }
    $cfg = ConvertFrom-BacklogJsonDictionary -JsonText $raw
    $backlogCfg = Get-BacklogDictionaryValue -Map $cfg -Name 'backlog' -Default $null
    if ($backlogCfg -is [System.Collections.IDictionary]) {
      $idleEnabled = Get-BacklogDictionaryValue -Map $backlogCfg -Name 'enableLLMPrioritizerOnIdle' -Default $null
      if ($null -ne $idleEnabled) { $settings.IdleEnabled = [bool]$idleEnabled }
      $usePriority = Get-BacklogDictionaryValue -Map $backlogCfg -Name 'useLLMPriority' -Default $null
      if ($null -ne $usePriority) { $settings.UseLLMPriority = [bool]$usePriority }
      $intervalValue = Get-BacklogDictionaryValue -Map $backlogCfg -Name 'prioritizerIntervalMinutes' -Default $null
      if ($null -ne $intervalValue) {
        $iv = [int]$intervalValue
        if ($iv -gt 0) { $settings.IntervalMinutes = $iv }
      }
      $maxItemsValue = Get-BacklogDictionaryValue -Map $backlogCfg -Name 'prioritizerMaxItems' -Default $null
      if ($null -ne $maxItemsValue) {
        $mi = [int]$maxItemsValue
        if ($mi -gt 0) { $settings.MaxItems = $mi }
      }
    }
  } catch {}
  $settings.Enabled = ([bool]$settings.IdleEnabled -or [bool]$settings.UseLLMPriority)
  return [pscustomobject]$settings
}

function Update-BacklogLLMPriorityOrder {
  param(
    [object[]]$AllItems,
    [object[]]$Ideas,
    [object[]]$Ranked
  )

  $items = @($AllItems)
  $originalItems = @($items)
  $ideasArr = @($Ideas)
  $rankedArr = @($Ranked)
  if ($items.Count -eq 0 -or $ideasArr.Count -eq 0 -or $rankedArr.Count -eq 0) {
    return [pscustomobject]@{ Items = @($items); Updated = 0; Reordered = $false }
  }

  $idToIndex = @{}
  for ($idx = 0; $idx -lt $items.Count; $idx++) {
    $itemId = ''
    try { $itemId = [string]$items[$idx].id } catch { $itemId = '' }
    if (-not [string]::IsNullOrWhiteSpace($itemId)) { $idToIndex[$itemId] = $idx }
  }

  $ideaIds = @{}
  $ideaOrder = @{}
  $eligibleSlots = New-Object 'System.Collections.Generic.List[int]'
  for ($i = 0; $i -lt $ideasArr.Count; $i++) {
    $ideaId = ''
    try { $ideaId = [string]$ideasArr[$i].id } catch { $ideaId = '' }
    if ([string]::IsNullOrWhiteSpace($ideaId) -or -not $idToIndex.ContainsKey($ideaId)) { continue }
    if (-not $ideaIds.ContainsKey($ideaId)) {
      $ideaIds[$ideaId] = $true
      $ideaOrder[$ideaId] = $i
      [void]$eligibleSlots.Add([int]$idToIndex[$ideaId])
    }
  }
  if ($eligibleSlots.Count -eq 0) {
    return [pscustomobject]@{ Items = @($items); Updated = 0; Reordered = $false }
  }

  $seenRanked = @{}
  $rankRows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($rank in $rankedArr) {
    $id = ''
    try { $id = [string]$rank.id } catch { $id = '' }
    if ([string]::IsNullOrWhiteSpace($id) -or -not $ideaIds.ContainsKey($id) -or $seenRanked.ContainsKey($id)) { continue }
    $score100 = 0.0
    try { $score100 = [double]$rank.score } catch { continue }
    if ($score100 -lt 0) { $score100 = 0.0 }
    if ($score100 -gt 100) { $score100 = 100.0 }
    $reason = ''
    try { $reason = ([string]$rank.reason).Trim() } catch { $reason = '' }
    $seenRanked[$id] = $true
    [void]$rankRows.Add([pscustomobject]@{
      id = $id
      score100 = [double]$score100
      reason = $reason
      original_order = [int]$ideaOrder[$id]
    })
  }

  if ($rankRows.Count -eq 0) {
    return [pscustomobject]@{ Items = @($items); Updated = 0; Reordered = $false }
  }

  $orderedRowsList = New-Object 'System.Collections.Generic.List[object]'
  foreach ($sortedRow in @($rankRows | Sort-Object @{ Expression = { -[double]$_.score100 } }, @{ Expression = { [int]$_.original_order } })) {
    [void]$orderedRowsList.Add($sortedRow)
  }
  foreach ($idea in $ideasArr) {
    $id = ''
    try { $id = [string]$idea.id } catch { $id = '' }
    if ([string]::IsNullOrWhiteSpace($id) -or -not $ideaIds.ContainsKey($id) -or $seenRanked.ContainsKey($id)) { continue }
    [void]$orderedRowsList.Add([pscustomobject]@{
      id = $id
      score100 = $null
      reason = ''
      original_order = [int]$ideaOrder[$id]
    })
  }
  $orderedRows = @($orderedRowsList.ToArray())

  $now = (Get-Date).ToUniversalTime().ToString('o')
  $updated = 0
  $rankNo = 0
  foreach ($row in @($orderedRows)) {
    $rankNo++
    $idx = [int]$idToIndex[[string]$row.id]
    $target = $items[$idx]
    if ($null -ne $row.score100) {
      $target | Add-Member -NotePropertyName score -NotePropertyValue ([Math]::Round([double]$row.score100 / 10.0, 2)) -Force
      $target | Add-Member -NotePropertyName llm_priority_score -NotePropertyValue ([Math]::Round([double]$row.score100, 2)) -Force
      $target | Add-Member -NotePropertyName llm_priority_reason -NotePropertyValue ([string]$row.reason) -Force
      $target | Add-Member -NotePropertyName llm_priority_at -NotePropertyValue $now -Force
      $updated++
    }
    $target | Add-Member -NotePropertyName llm_priority_rank -NotePropertyValue $rankNo -Force
    $items[$idx] = $target
  }

  $slots = @($eligibleSlots.ToArray() | Sort-Object)
  $reordered = $false
  for ($slotNo = 0; $slotNo -lt $slots.Count -and $slotNo -lt $orderedRows.Count; $slotNo++) {
    $slotIndex = [int]$slots[$slotNo]
    $sourceId = [string]$orderedRows[$slotNo].id
    $sourceIndex = [int]$idToIndex[$sourceId]
    $currentId = ''
    try { $currentId = [string]$items[$slotIndex].id } catch { $currentId = '' }
    if ($currentId -ne $sourceId) { $reordered = $true }
    $items[$slotIndex] = $originalItems[$sourceIndex]
  }

  return [pscustomobject]@{
    Items = @($items)
    Updated = [int]$updated
    Reordered = [bool]$reordered
  }
}

function Invoke-BacklogLLMPrioritize {
  param(
    [int]$MaxItems = 20,
    [string]$Channel = $env:BRIDGE_CHANNEL
  )
  if ($MaxItems -le 0) { return 0 }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }

  $runner = {
    param([int]$BoundMaxItems)
    $allItems = @(Get-Backlog)
    $ideas = @(
      $allItems |
      Where-Object {
        $status = [string]$_.status
        if ($status -ne 'approved' -and $status -ne 'new') { return $false }
        $tags = @($_.tags | ForEach-Object { [string]$_ })
        return (-not ($tags -contains 'external') -and -not ($tags -contains 'radar'))
      } |
      Select-Object -First $BoundMaxItems
    )
    if ($ideas.Count -eq 0) { return 0 }

    Ensure-BacklogLLMLoaded
    $prompt = New-BacklogLLMPriorityPrompt -Ideas $ideas
    $raw = $null
    try {
      if (Get-Command Invoke-LLM -ErrorAction SilentlyContinue) {
        $raw = Invoke-LLM -Purpose 'prioritizer' -Prompt $prompt -TimeoutSec 30 -Temperature 0.2
      } elseif (Get-Command Invoke-LLMProvider -ErrorAction SilentlyContinue) {
        $priorityModel = Get-BacklogPrioritizerModel
        if ([string]::IsNullOrWhiteSpace($priorityModel)) {
          Write-Warning 'Invoke-BacklogLLMPrioritize: prioritizer model is not configured'
          return 0
        }
        $raw = Invoke-LLMProvider -Model $priorityModel -Prompt $prompt -TimeoutSec 30 -Temperature 0.2
      } else {
        Write-Warning 'Invoke-BacklogLLMPrioritize: neither Invoke-LLM nor Invoke-LLMProvider is available'
        return 0
      }
    } catch {
      Write-Warning ("Invoke-BacklogLLMPrioritize: LLM call failed: " + $_.Exception.Message)
      return 0
    }

    if ([string]::IsNullOrWhiteSpace([string]$raw)) {
      Write-Warning 'Invoke-BacklogLLMPrioritize: empty LLM response'
      return 0
    }

    $clean = ([string]$raw -replace '```json', '' -replace '```', '').Trim()
    $match = [regex]::Match($clean, '(?s)\[.*\]')
    if (-not $match.Success) {
      Write-Warning 'Invoke-BacklogLLMPrioritize: could not find JSON array in LLM response'
      return 0
    }

    $ranked = @()
    try {
      $ranked = @($match.Value | ConvertFrom-Json)
    } catch {
      Write-Warning ("Invoke-BacklogLLMPrioritize: failed to parse JSON: " + $_.Exception.Message)
      return 0
    }

    $priorityUpdate = Update-BacklogLLMPriorityOrder -AllItems $allItems -Ideas $ideas -Ranked $ranked
    $updated = [int]$priorityUpdate.Updated
    if ($updated -gt 0) { Save-Backlog @($priorityUpdate.Items) }
    $reorderText = if ([bool]$priorityUpdate.Reordered) { ', порядок top-N изменён' } else { '' }
    Write-Host "🧠 LLM-приоритизация: обновлено $($updated) идей из $($ideas.Count)$reorderText"
    return $updated
  }.GetNewClosure()

  try {
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
      return (Invoke-WithChannelEnv -Slug $Channel -Action $runner -ArgumentList @($MaxItems))
    }
    return (& $runner $MaxItems)
  } catch {
    Write-Warning ("Invoke-BacklogLLMPrioritize: failed for channel '" + $Channel + "': " + $_.Exception.Message)
    return 0
  }
}

function Start-BacklogPrioritizerIfDue {
  param(
    [string]$Channel = $env:BRIDGE_CHANNEL,
    [int]$IntervalMinutes = 60,
    [int]$MaxItems = 20
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $settings = Get-BacklogPrioritizerSettings -Channel $Channel -IntervalMinutes $IntervalMinutes -MaxItems $MaxItems
  if (-not [bool]$settings.Enabled) { return 0 }
  $IntervalMinutes = [int]$settings.IntervalMinutes
  $MaxItems = [int]$settings.MaxItems
  if ($IntervalMinutes -le 0) { $IntervalMinutes = 60 }
  if ($MaxItems -le 0) { $MaxItems = 20 }

  $root = Get-BacklogFallbackBridgeRoot
  $controlDir = Join-Path $root 'control'
  try { if (-not (Test-Path -LiteralPath $controlDir)) { New-Item -ItemType Directory -Path $controlDir -Force | Out-Null } } catch {}
  $safeChannel = ([string]$Channel -replace '[^A-Za-z0-9_.-]', '_')
  $marker = Join-Path $controlDir ('backlog-prioritizer.' + $safeChannel + '.last')
  $due = $true
  if (Test-Path -LiteralPath $marker -PathType Leaf) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      $due = (((Get-Date) - $last).TotalMinutes -ge $IntervalMinutes)
    } catch { $due = $true }
  }
  if (-not $due) { return 0 }
  [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  $updated = 0
  try { $updated = [int](Invoke-BacklogLLMPrioritize -MaxItems $MaxItems -Channel $Channel) } catch { $updated = 0 }
  try {
    Write-BacklogJsonLine ([ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      action = 'llm-prioritize-idle'
      channel = [string]$Channel
      max_items = [int]$MaxItems
      updated = [int]$updated
    })
  } catch {}
  return $updated
}

function Invoke-BacklogCurator {
  param([string]$ItemId)
  if ([string]::IsNullOrWhiteSpace($ItemId)) { return $null }
  Ensure-BacklogPathFunction
  $now = (Get-Date).ToUniversalTime().ToString('o')
  try {
    $items = @(Get-Backlog)
    $item = $null
    foreach ($i in $items) {
      if ([string]$i.id -eq $ItemId) { $item = $i; break }
    }
    if (-not $item) { return $null }

    Ensure-BacklogLLMLoaded
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) { throw 'Invoke-LLM unavailable' }

    $gitLog = Get-BacklogGitOutput -GitArgs @('log', '-5', '--oneline')
    if ([string]::IsNullOrWhiteSpace($gitLog)) { $gitLog = '(no git log)' }
    $status = Get-BacklogStatusSummary
    $prompt = @"
Ты куратор беклога автономного ИИ-моста (Claude+Codex, PowerShell, web UI).
Компоненты: driver.ps1, server.ps1, lib/*.ps1, web/index.html, memory/.

Item: $([string]$item.text)
Создан: $([string]$item.from)

Последние 5 коммитов:
$gitLog

Текущий статус моста: $status

Реши: approve / hold / drop.
Критерии:
- approve: ясный scope, понятная польза для моста, нет признаков что уже сделано
- drop: дубль, out-of-scope (personal/нерелевантно), текст-каша, признаки что уже сделано
- hold: нужно решение пользователя (architectural ambiguity, выбор)

Верни СТРОГО JSON: {"verdict":"approve|hold|drop","confidence":0.0-1.0,"reason":"короткая фраза","already_done_sha":null или "<sha>"}
"@
    $raw = Invoke-LLM -Purpose 'backlog-curator' -Model $script:BacklogCuratorModel -Prompt $prompt -TimeoutSec 70 -Temperature 0.1
    $obj = ConvertFrom-BacklogStrictJson -Text ([string]$raw)
    if (-not $obj) { throw 'curator returned non-json' }

    $verdict = ([string]$obj.verdict).ToLowerInvariant()
    if ($verdict -notin @('approve', 'hold', 'drop')) { $verdict = 'drop' }
    $confidence = 0.0
    try { $confidence = [double]$obj.confidence } catch { $confidence = 0.0 }
    if ($confidence -lt 0) { $confidence = 0.0 }
    if ($confidence -gt 1) { $confidence = 1.0 }
    $reason = ([string]$obj.reason).Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no reason' }
    if ($confidence -lt 0.6) {
      $verdict = 'drop'
      $reason = "$reason (low confidence)"
    }

    $mapped = switch ($verdict) {
      'approve' { 'approved' }
      'hold' { 'held' }
      default { 'auto-dropped' }
    }
    $curator = [ordered]@{
      verdict = $verdict
      confidence = $confidence
      reason = $reason
      model = $script:BacklogCuratorModel
      ts = (Get-Date).ToUniversalTime().ToString('o')
      judged_at_sha = (Get-BacklogCurrentSha)
    }
    if ($obj.PSObject.Properties.Name -contains 'already_done_sha') {
      $curator.already_done_sha = $obj.already_done_sha
    }
    $item | Add-Member -NotePropertyName auto_curator -NotePropertyValue ([pscustomobject]$curator) -Force
    $item | Add-Member -NotePropertyName status -NotePropertyValue $mapped -Force
    Save-Backlog $items

    Write-BacklogJsonLine ([ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      action = 'judge'
      item_id = $ItemId
      text = [string]$item.text
      verdict = $verdict
      confidence = $confidence
      reason = $reason
      model = $script:BacklogCuratorModel
    })
    return [pscustomobject]@{ verdict = $verdict; confidence = $confidence; reason = $reason }
  } catch {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'judge-error'
      item_id = $ItemId
      error = [string]$_.Exception.Message
    })
    return $null
  }
}

function Test-ProjectScopedApprovedBacklogAllowed {
  # Project tabs are already isolated by channel + project_root binding. If the active
  # channel is a real project channel, approved project-scoped backlog must drain there
  # even when the global autonomy scope is left at the safer bridge default.
  try {
    $autoScopeSettings = Get-AutonomySettings
    if ([string]$autoScopeSettings.scope -eq 'projects') { return $true }
  } catch {}

  try {
    $slug = ''
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $slug = [string](Get-EffectiveChannel) }
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = [string]$env:BRIDGE_CHANNEL }
    if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'main') { return $false }

    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) {
      $scope = Get-EffectiveScope -Slug $slug
      if ($scope -and -not [bool]$scope.is_bridge -and -not [string]::IsNullOrWhiteSpace([string]$scope.project_root)) {
        return $true
      }
    }
  } catch {}

  return $false
}

function ConvertTo-BacklogClaimStringArray {
  param($Value)
  $items = New-Object 'System.Collections.Generic.List[string]'
  if ($null -eq $Value) { return [string[]]@() }
  if ($Value -is [string]) {
    $s = $Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$items.Add($s) }
    return [string[]]@($items.ToArray())
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if ($null -eq $item) { continue }
      $s = ([string]$item).Trim()
      if (-not [string]::IsNullOrWhiteSpace($s) -and -not $items.Contains($s)) { [void]$items.Add($s) }
    }
  }
  return [string[]]@($items.ToArray())
}

function Test-BacklogClaimTruthy {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return [bool]$Value }
  $s = ([string]$Value).Trim().ToLowerInvariant()
  return (@('1','true','yes','y','on','admitted','approved','ok') -contains $s)
}

function Test-BacklogClaimTextMatch {
  param([string[]]$Values, [string]$Pattern)
  foreach ($value in @($Values)) {
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if ($value -match $Pattern) { return $true }
  }
  return $false
}

function Test-BridgeControlPlanePath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = $Path.Replace('\','/').Trim().TrimStart('./').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  if ($p -match '(^|/)driver[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)driver/[^/]+\.ps1$') { return $true }
  if ($p -match '(^|/)(server|supervisor|watchdog)\.ps1$') { return $true }
  if ($p -match '(^|/)lib/backlog[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)lib/(parallel|circuit-breaker)\.ps1$') { return $true }
  return $false
}

function Test-IdeaTouchesControlPlanePath {
  param($Idea)
  if (-not $Idea) { return $false }
  $paths = New-Object 'System.Collections.Generic.List[string]'
  foreach ($source in @(
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'files' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'workpack_touch_set' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'touch_set' -Default @())
    )) {
    foreach ($path in @(ConvertTo-BacklogClaimStringArray $source)) {
      if (-not [string]::IsNullOrWhiteSpace($path)) { [void]$paths.Add($path) }
    }
  }
  foreach ($path in @($paths.ToArray())) {
    if (Test-BridgeControlPlanePath -Path $path) { return $true }
  }
  return $false
}

function Test-BacklogItemHeld {
  param($Item)
  if (-not $Item) { return $false }
  $status = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')
  return ($status -eq 'held')
}

function Get-IdeaBridgeSelfAdmission {
  param($Idea)
  if (-not $Idea) { return $null }
  $admission = Get-BacklogPackObjectValue -Obj $Idea -Name 'bridge_self_admission' -Default $null
  if ($admission) { return $admission }
  try {
    $meta = Get-BacklogPackObjectValue -Obj $Idea -Name 'autopilot_meta' -Default $null
    if ($meta) {
      $admission = Get-BacklogPackObjectValue -Obj $meta -Name 'bridge_self_admission' -Default $null
      if ($admission) { return $admission }
    }
  } catch {}
  return $null
}

function Test-IdeaBridgeSelfAdmitted {
  # Alternative to the manual 'operator' tag for bridge-self control-plane tasks.
  # This does NOT lower the safety bar: an admitted task must be bridge-scoped,
  # non-external, and carry explicit self-test/smoke/canary/rollback evidence.
  param($Idea)

  $missing = New-Object 'System.Collections.Generic.List[string]'
  $reason = ''
  if (-not $Idea) { return [pscustomobject]@{ ok=$false; reason='missing idea'; missing=@('idea') } }
  try {
    if (Test-IdeaExternal $Idea) {
      return [pscustomobject]@{ ok=$false; reason='external source cannot self-admit bridge control-plane work'; missing=@('non_external_source') }
    }
  } catch {}
  $scope = [string](Get-BacklogPackObjectValue -Obj $Idea -Name 'scope' -Default 'bridge')
  if (-not [string]::IsNullOrWhiteSpace($scope) -and $scope -ne 'bridge') {
    return [pscustomobject]@{ ok=$false; reason='not bridge scope'; missing=@('scope_bridge') }
  }

  $admission = Get-IdeaBridgeSelfAdmission -Idea $Idea
  if (-not $admission) {
    return [pscustomobject]@{ ok=$false; reason='missing bridge_self_admission'; missing=@('bridge_self_admission') }
  }

  $admitted = Test-BacklogClaimTruthy (Get-BacklogPackObjectValue -Obj $admission -Name 'admitted' -Default $false)
  if (-not $admitted) {
    $status = [string](Get-BacklogPackObjectValue -Obj $admission -Name 'status' -Default '')
    $admitted = Test-BacklogClaimTruthy $status
  }
  if (-not $admitted) { [void]$missing.Add('admitted=true') }

  $mode = ([string](Get-BacklogPackObjectValue -Obj $admission -Name 'mode' -Default '')).Trim().ToLowerInvariant()
  if ($mode -notin @('canary','bridge_self_canary','bridge-self-canary','operatorless_canary')) {
    [void]$missing.Add('mode=bridge_self_canary')
  }

  $canaryRequired = Test-BacklogClaimTruthy (Get-BacklogPackObjectValue -Obj $admission -Name 'canary_required' -Default $false)
  if (-not $canaryRequired) { [void]$missing.Add('canary_required=true') }

  $checks = New-Object 'System.Collections.Generic.List[string]'
  foreach ($source in @(
      (Get-BacklogPackObjectValue -Obj $admission -Name 'checks' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'checks' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'verification_checks' -Default @())
    )) {
    foreach ($check in @(ConvertTo-BacklogClaimStringArray $source)) {
      if (-not $checks.Contains($check)) { [void]$checks.Add($check) }
    }
  }
  $checksArr = @($checks.ToArray())
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)driver\.ps1.*-SelfTest|self[- ]?test')) { [void]$missing.Add('driver_selftest_check') }
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)smoke\.ps1|smoke')) { [void]$missing.Add('smoke_check') }
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)canary|Invoke-CanaryCycle')) { [void]$missing.Add('canary_check') }

  $rollback = [string](Get-BacklogPackObjectValue -Obj $admission -Name 'rollback_plan' -Default '')
  if ([string]::IsNullOrWhiteSpace($rollback)) { $rollback = [string](Get-BacklogPackObjectValue -Obj $admission -Name 'rollback' -Default '') }
  if ([string]::IsNullOrWhiteSpace($rollback)) { [void]$missing.Add('rollback_plan') }

  $files = @()
  $files += @(ConvertTo-BacklogClaimStringArray (Get-BacklogPackObjectValue -Obj $Idea -Name 'files' -Default @()))
  $files += @(ConvertTo-BacklogClaimStringArray (Get-BacklogPackObjectValue -Obj $Idea -Name 'workpack_touch_set' -Default @()))
  $files = @($files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  if ($files.Count -eq 0) { [void]$missing.Add('files') }

  if ($missing.Count -gt 0) {
    $reason = 'bridge_self_admission incomplete: ' + ((@($missing.ToArray()) | Sort-Object -Unique) -join ', ')
    return [pscustomobject]@{ ok=$false; reason=$reason; missing=@($missing.ToArray()) }
  }

  return [pscustomobject]@{
    ok = $true
    reason = 'bridge_self_admission accepted'
    missing = @()
    checks = @($checksArr)
    rollback_plan = $rollback
  }
}

function Test-BacklogApprovedItemClaimable {
  param(
    $Item,
    [bool]$ProjectScopeAllowed = $false
  )
  if (-not $Item) { return [pscustomobject]@{ claimable=$false; reason='missing-item'; admission=$null } }
  if (Test-BacklogItemHeld -Item $Item) {
    return [pscustomobject]@{ claimable=$false; reason='held'; admission=$null }
  }
  if ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '') -ne 'approved') {
    return [pscustomobject]@{ claimable=$false; reason='not-approved'; admission=$null }
  }
  $id = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
  if ([string]::IsNullOrWhiteSpace($id)) { return [pscustomobject]@{ claimable=$false; reason='missing-id'; admission=$null } }

  $scope = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'scope' -Default '')
  if ((-not $ProjectScopeAllowed) -and $scope -eq 'project') {
    return [pscustomobject]@{ claimable=$false; reason='project-scope-blocked'; admission=$null }
  }

  $tags = @()
  try { $tags = @(ConvertTo-BacklogClaimStringArray (Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @()) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() }) } catch { $tags = @() }
  $isOperator = (@($tags) -contains 'operator')
  # 2026-06-06 (operator hotfix): project-autopilot coordinator tasks (scope=project, work-ONLY-in-project-root)
  # are PLANNERS, not control-plane executors. Their text mentions driver.ps1/supervisor/backlog ONLY as
  # instructions teaching the worker how to flag control-plane atoms — the control-plane regex false-matches
  # those words and blocked the coordinator, wedging CHAPTER autopilot. The atoms the coordinator emits are
  # re-checked by THIS gate at their own claim time, so exempting ONLY the coordinator is safe.
  $isProjectAutopilot = $false
  try { $isProjectAutopilot = (@($tags) -contains 'project-autopilot') } catch { $isProjectAutopilot = $false }
  $isProjectAutopilotAtom = ($isProjectAutopilot -and (@($tags) -contains 'atom'))
  $touchesControl = $false
  try {
    if ($isProjectAutopilot) {
      $touchesControl = ($isProjectAutopilotAtom -and [bool](Test-IdeaTouchesControlPlanePath -Idea $Item))
    } else {
      $touchesControl = [bool](Test-IdeaTouchesControlPlane -Idea $Item)
    }
  } catch { $touchesControl = $false }
  if ($touchesControl -and -not $isOperator) {
    $admission = Test-IdeaBridgeSelfAdmitted -Idea $Item
    if ($admission -and [bool]$admission.ok) {
      return [pscustomobject]@{ claimable=$true; reason='bridge-self-admission'; admission=$admission }
    }
    return [pscustomobject]@{ claimable=$false; reason='control-plane-blocked'; admission=$admission }
  }

  $claimReason = 'regular'
  if ($isOperator) { $claimReason = 'operator' }
  return [pscustomobject]@{ claimable=$true; reason=$claimReason; admission=$null }
}

function Get-BacklogGovernorManualLocks {
  $locks = New-Object 'System.Collections.Generic.List[object]'
  foreach ($path in @(
      (Join-Path (Get-BacklogFallbackBridgeRoot) 'state\manual-locks.json'),
      (Join-Path (Get-BacklogControlDir) 'manual-locks.json')
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
      $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $parsed = $raw | ConvertFrom-Json
      $arr = @()
      if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        $arr = @($parsed)
      } else {
        $inner = Get-BacklogPackObjectValue -Obj $parsed -Name 'locks' -Default $null
        if ($null -eq $inner) { $inner = Get-BacklogPackObjectValue -Obj $parsed -Name 'manual_locks' -Default $null }
        if ($null -eq $inner) { $inner = Get-BacklogPackObjectValue -Obj $parsed -Name 'items' -Default $null }
        if ($null -ne $inner) { $arr = @($inner) } else { $arr = @($parsed) }
      }
      foreach ($lock in @($arr)) {
        if ($null -ne $lock) { [void]$locks.Add($lock) }
      }
    } catch {}
  }
  return @($locks.ToArray())
}

function Get-BacklogGovernorActiveItems {
  param([object[]]$Items)
  return @($Items | Where-Object {
    $st = ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'status' -Default '')).ToLowerInvariant()
    ($st -in @('running','working'))
  })
}

function Set-BacklogGovernorDrop {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [Parameter(Mandatory=$true)]$Verdict,
    [string]$Phase = 'claim'
  )
  $now = (Get-Date).ToUniversalTime().ToString('o')
  $reason = 'queue-governor:' + [string]$Verdict.reason
  Set-BacklogObjectProperty -Item $Item -Name 'status' -Value 'auto-dropped'
  Set-BacklogObjectProperty -Item $Item -Name 'governor_drop_reason' -Value $reason
  Set-BacklogObjectProperty -Item $Item -Name 'governor_drop_detail' -Value ([string]$Verdict.detail)
  Set-BacklogObjectProperty -Item $Item -Name 'governor_drop_evidence' -Value $Verdict.evidence
  Set-BacklogObjectProperty -Item $Item -Name 'governor_claim' -Value ([pscustomobject][ordered]@{
    action = 'drop'
    reason = [string]$Verdict.reason
    detail = [string]$Verdict.detail
    ts = $now
    evidence = $Verdict.evidence
  })
  Set-BacklogObjectProperty -Item $Item -Name 'auto_curator' -Value ([pscustomobject][ordered]@{
    verdict = 'drop'
    confidence = 1.0
    reason = $reason
    model = 'queue-governor-v1'
    ts = $now
    judged_at_sha = (Get-BacklogCurrentSha)
  })
  try {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'governor-auto-drop'
      item_id = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
      reason = [string]$Verdict.reason
      detail = [string]$Verdict.detail
      evidence = $Verdict.evidence
      phase = [string]$Phase
    })
  } catch {}
}

function Set-BacklogGovernorDeferred {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [Parameter(Mandatory=$true)]$Verdict,
    [string]$Phase = 'claim'
  )
  $now = (Get-Date).ToUniversalTime().ToString('o')
  Set-BacklogObjectProperty -Item $Item -Name 'governor_deferred_reason' -Value ([string]$Verdict.reason)
  Set-BacklogObjectProperty -Item $Item -Name 'governor_deferred_detail' -Value ([string]$Verdict.detail)
  Set-BacklogObjectProperty -Item $Item -Name 'governor_deferred_evidence' -Value $Verdict.evidence
  Set-BacklogObjectProperty -Item $Item -Name 'governor_deferred_at' -Value $now
  Set-BacklogObjectProperty -Item $Item -Name 'governor_claim' -Value ([pscustomobject][ordered]@{
    action = 'defer'
    reason = [string]$Verdict.reason
    detail = [string]$Verdict.detail
    ts = $now
    evidence = $Verdict.evidence
  })
  try {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'governor-deferred'
      item_id = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
      reason = [string]$Verdict.reason
      detail = [string]$Verdict.detail
      evidence = $Verdict.evidence
      phase = [string]$Phase
    })
  } catch {}
}

function Invoke-BacklogGovernorFilterApprovedItems {
  param(
    [object[]]$Items,
    [bool]$ProjectScopeAllowed = $false,
    [string]$Phase = 'claim'
  )
  $allowed = New-Object 'System.Collections.Generic.List[object]'
  $deferred = New-Object 'System.Collections.Generic.List[object]'
  $dropped = New-Object 'System.Collections.Generic.List[object]'
  $blocked = New-Object 'System.Collections.Generic.List[object]'
  $dirty = $false
  $activeItems = @(Get-BacklogGovernorActiveItems -Items $Items)
  $manualLocks = @(Get-BacklogGovernorManualLocks)
  foreach ($item in @($Items)) {
    if ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '') -ne 'approved') { continue }
    $base = Test-BacklogApprovedItemClaimable -Item $item -ProjectScopeAllowed $ProjectScopeAllowed
    if (-not ($base -and [bool]$base.claimable)) {
      [void]$blocked.Add([pscustomobject][ordered]@{
        id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
        reason = [string]$base.reason
        detail = ''
      })
      continue
    }

    $verdict = Test-BacklogGovernorClaimable -Item $item -ActiveItems $activeItems -ManualLocks $manualLocks
    Set-BacklogObjectProperty -Item $item -Name 'governor_last_checked_at' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Set-BacklogObjectProperty -Item $item -Name 'governor_claim_evidence' -Value $verdict.evidence
    if ([string]$verdict.action -eq 'allow') {
      Set-BacklogObjectProperty -Item $item -Name 'governor_claim' -Value ([pscustomobject][ordered]@{
        action = 'allow'
        reason = [string]$verdict.reason
        detail = [string]$verdict.detail
        ts = (Get-Date).ToUniversalTime().ToString('o')
        evidence = $verdict.evidence
      })
      [void]$allowed.Add($item)
      $dirty = $true
      continue
    }
    if ([string]$verdict.action -eq 'drop') {
      Set-BacklogGovernorDrop -Item $item -Verdict $verdict -Phase $Phase
      [void]$dropped.Add([pscustomobject][ordered]@{
        id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
        reason = [string]$verdict.reason
        detail = [string]$verdict.detail
        evidence = $verdict.evidence
      })
      $dirty = $true
      continue
    }
    Set-BacklogGovernorDeferred -Item $item -Verdict $verdict -Phase $Phase
    [void]$deferred.Add([pscustomobject][ordered]@{
      id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
      reason = [string]$verdict.reason
      detail = [string]$verdict.detail
      evidence = $verdict.evidence
    })
    $dirty = $true
  }
  if ($dirty) { Save-Backlog $Items }
  return [pscustomobject][ordered]@{
    items = @($allowed.ToArray())
    deferred = @($deferred.ToArray())
    dropped = @($dropped.ToArray())
    blocked = @($blocked.ToArray())
    changed = [bool]$dirty
  }
}

function Get-ApprovedBacklogClaimabilityReport {
  param([object[]]$Items = $null)

  if ($null -eq $Items) { $Items = @(Get-Backlog) }
  $approved = @($Items | Where-Object { [string]$_.status -eq 'approved' })
  $governorResult = $null
  try { $governorResult = Invoke-BacklogGovernorFilterApprovedItems -Items $Items -ProjectScopeAllowed ([bool](Test-ProjectScopedApprovedBacklogAllowed)) -Phase 'claimability-report' } catch { $governorResult = $null }
  $runnable = New-Object 'System.Collections.Generic.List[object]'
  $controlPlane = New-Object 'System.Collections.Generic.List[object]'
  $admittedControlPlane = New-Object 'System.Collections.Generic.List[object]'
  $projectScope = New-Object 'System.Collections.Generic.List[object]'
  $other = New-Object 'System.Collections.Generic.List[object]'
  $projectAllowed = $false
  try { $projectAllowed = [bool](Test-ProjectScopedApprovedBacklogAllowed) } catch { $projectAllowed = $false }

  foreach ($item in @($approved)) {
    $id = ''
    try { $id = [string]$item.id } catch {}
    $sample = [pscustomobject]@{
      id = $id
      text = [string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '')
      scope = [string](Get-BacklogPackObjectValue -Obj $item -Name 'scope' -Default '')
      workpack_status = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_status' -Default '')
      workpack_conflict_group = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default '')
    }
    $claim = Test-BacklogApprovedItemClaimable -Item $item -ProjectScopeAllowed $projectAllowed
    if ($claim -and [bool]$claim.claimable) {
      $governorAction = ''
      try { $governorAction = [string](Get-BacklogPackObjectValue -Obj (Get-BacklogPackObjectValue -Obj $item -Name 'governor_claim' -Default $null) -Name 'action' -Default '') } catch { $governorAction = '' }
      if ($governorAction -eq 'defer' -or $governorAction -eq 'drop') { continue }
      if ([string]$claim.reason -eq 'bridge-self-admission') { [void]$admittedControlPlane.Add($sample) }
      [void]$runnable.Add($sample)
      continue
    }
    switch ([string]$claim.reason) {
      'control-plane-blocked' { [void]$controlPlane.Add($sample); continue }
      'project-scope-blocked' { [void]$projectScope.Add($sample); continue }
      default { [void]$other.Add($sample); continue }
    }
  }

  $blocked = [int]$controlPlane.Count + [int]$projectScope.Count + [int]$other.Count
  return [pscustomobject][ordered]@{
    approved_count = [int]$approved.Count
    runnable_count = [int]$runnable.Count
    blocked_count = [int]$blocked
    control_plane_blocked = [int]$controlPlane.Count
    admitted_control_plane = [int]$admittedControlPlane.Count
    project_scope_blocked = [int]$projectScope.Count
    other_blocked = [int]$other.Count
    governor_deferred_count = $(if ($governorResult) { @($governorResult.deferred).Count } else { 0 })
    governor_dropped_count = $(if ($governorResult) { @($governorResult.dropped).Count } else { 0 })
    project_scope_allowed = [bool]$projectAllowed
    runnable_ids = @($runnable.ToArray() | Select-Object -First 8 | ForEach-Object { [string]$_.id })
    control_plane_ids = @($controlPlane.ToArray() | Select-Object -First 8 | ForEach-Object { [string]$_.id })
    admitted_control_plane_ids = @($admittedControlPlane.ToArray() | Select-Object -First 8 | ForEach-Object { [string]$_.id })
    project_scope_ids = @($projectScope.ToArray() | Select-Object -First 8 | ForEach-Object { [string]$_.id })
    governor_deferred = $(if ($governorResult) { @($governorResult.deferred) } else { @() })
    governor_dropped = $(if ($governorResult) { @($governorResult.dropped) } else { @() })
  }
}

function Get-NextApprovedIdea {
  # Next approved item, checking whether recent commits already resolved stale work.
  # 2026-05-28: sort key chain is severity rank (critical=0 / warning=1 / info=2 / none=3)
  # first, then score desc, then ts asc. So audit criticals get pulled before warnings,
  # warnings before info, info before plain ideas.
  $skipped = New-Object 'System.Collections.Generic.List[string]'
  while ($true) {
    # SYSTEMIC GUARD 2026-05-31/06-04: even an APPROVED control-plane task does not auto-run unless
    # the operator delegated it (tag 'operator') OR it has deterministic bridge_self_admission.
    $projectScopeAllowedForClaim = $false
    try { $projectScopeAllowedForClaim = [bool](Test-ProjectScopedApprovedBacklogAllowed) } catch { $projectScopeAllowedForClaim = $false }
    $allItems = @(Get-Backlog)
    $governorFiltered = Invoke-BacklogGovernorFilterApprovedItems -Items $allItems -ProjectScopeAllowed $projectScopeAllowedForClaim -Phase 'single-claim'
    $items = @($governorFiltered.items |
      Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                  @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                  @{Expression={[string]$_.ts}})
    if ($items.Count -eq 0) { return $null }

    $candidate = $items[0]
    $result = Test-IdeaStillRelevant -ItemId ([string]$candidate.id)
    if ($result -and [bool]$result.done) {
      $all = @(Get-Backlog)
      foreach ($i in $all) {
        if ([string]$i.id -ne [string]$candidate.id) { continue }
        $i | Add-Member -NotePropertyName status -NotePropertyValue 'auto-resolved' -Force
        $i | Add-Member -NotePropertyName resolved_by_sha -NotePropertyValue $result.sha -Force
        $i | Add-Member -NotePropertyName resolved_reason -NotePropertyValue ([string]$result.reason) -Force
        break
      }
      Save-Backlog $all
      [void]$skipped.Add([string]$candidate.id)
      Write-BacklogJsonLine ([ordered]@{
        ts = (Get-Date).ToUniversalTime().ToString('o')
        action = 'freshness-skip'
        item_id = [string]$candidate.id
        text = [string]$candidate.text
        sha = $result.sha
        reason = [string]$result.reason
      })
      if ($skipped.Count -ge 3) {
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'freshness-skip-limit'
          skipped_ids = @($skipped.ToArray())
        })
        # M5 FIX (load audit): with 90+ runnable approved items behind the 3 stale ones, returning
        # null IDLES the driver on a FULL queue. The 3-skip cap is only a per-tick budget for the
        # (expensive) freshness probe -- once spent, take the next not-yet-probed approved item AS-IS
        # (its freshness is re-checked next tick / by the verify gate) instead of wedging the drain.
        $nextUnprobed = @($items | Where-Object { $skipped -notcontains [string]$_.id } | Select-Object -First 1)
        if (@($nextUnprobed).Count -gt 0) { return $nextUnprobed[0] }
        return $null
      }
      continue
    }
    return $candidate
  }
}

function Test-IdeaExternal {
  # Externally-sourced ideas (tech-radar / web) are security-sensitive: they must NEVER
  # auto-run, only after explicit human approval (status 'approved').
  param($Idea)
  $tags = @($Idea.tags)
  return (($tags -contains 'external') -or ($tags -contains 'radar') -or ([string]$Idea.from -eq 'radar'))
}

function Get-NextRunnableIdea {
  # Next idea to auto-run. 'approved' (human-greenlit) always runs. With -IncludeNew
  # (autonomy without manual approval) 'new' items run too -- EXCEPT external/radar ones,
  # which always require explicit approval (anti-backdoor: web-sourced never auto-executes).
  param([bool]$IncludeNew = $false)
  $useLLMPriority = $false
  try {
    $prioritySettings = Get-BacklogPrioritizerSettings -Channel $env:BRIDGE_CHANNEL -IntervalMinutes 60 -MaxItems 15
    $useLLMPriority = [bool]$prioritySettings.UseLLMPriority
  } catch {}
  if ($useLLMPriority -or $env:BRIDGE_LLM_PRIORITY -eq '1') {
    $priorityChannel = [string]$env:BRIDGE_CHANNEL
    if ([string]::IsNullOrWhiteSpace($priorityChannel)) { $priorityChannel = 'main' }
    try { Invoke-BacklogLLMPrioritize -MaxItems 15 -Channel $priorityChannel | Out-Null } catch {}
  }
  # 2026-05-28: sort key chain is (1) status approved-before-new, (2) severity rank
  # critical=0 / warning=1 / info=2 / none=3, (3) score desc, (4) ts asc.
  # Audit criticals always outrank warnings, warnings outrank info, info outranks plain ideas.
  $projectScopeAllowedForRunnable = $false
  try { $projectScopeAllowedForRunnable = [bool](Test-ProjectScopedApprovedBacklogAllowed) } catch { $projectScopeAllowedForRunnable = $false }
  $allRunnableItems = @(Get-Backlog)
  $governorRunnable = Invoke-BacklogGovernorFilterApprovedItems -Items $allRunnableItems -ProjectScopeAllowed $projectScopeAllowedForRunnable -Phase 'runnable-claim'
  $approvedRunnable = @($governorRunnable.items)
  $newRunnable = @()
  if ($IncludeNew) {
    $newRunnable = @($allRunnableItems | Where-Object {
      [string]$_.status -eq 'new' -and -not (Test-IdeaExternal $_)
    })
  }
  $items = @((@($approvedRunnable) + @($newRunnable)) |
    Sort-Object @{Expression={ if (@($_.tags) -contains 'operator') {0} else {1} }},
                @{Expression={ if ([string]$_.status -eq 'approved') {0} else {1} }},
                @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}})
  if ($items.Count -gt 0) { return $items[0] }
  return $null
}

function Add-OperatorBatch {
  # Block C -- operator delegation. The conductor (Claude) hands the bridge a batch of
  # well-specified tasks; they are tagged 'operator' (claimed FIRST -- ahead of audit/auto ideas
  # via the operator-tier sort key in Get-NextRunnableIdea), tagged with a shared batch id for
  # progress tracking, pre-approved (the operator is trusted), and SkipCurator (no LLM gate on a
  # human-vetted instruction). Returns the batch id. This is how 100s of tasks enter the massive
  # worker pool under my orchestration, with a single handle to watch them by.
  param(
    [string[]]$Tasks,
    [string]$BatchLabel = '',
    [string]$Project = '',
    [string]$Scope = 'bridge'
  )
  $clean = @($Tasks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($clean.Count -eq 0) { return $null }
  $batchId = 'opb-' + ([guid]::NewGuid().ToString('N').Substring(0,10))
  $ids = @()
  $idx = 0
  foreach ($t in $clean) {
    $idx++
    $label = if ([string]::IsNullOrWhiteSpace($BatchLabel)) { '' } else { "[$BatchLabel $idx/$($clean.Count)] " }
    # NOTE: parentheses around the concat are REQUIRED — `@('operator', 'batch:' + $batchId)`
    # parses as THREE elements in PowerShell (the `+` binds as unary), splitting the batch tag
    # into "batch:" + "<id>" and breaking every batch-progress metric. Verified 2026-05-31.
    $id = Add-Idea -Text ($label + $t) -From 'operator' -Tags @('operator', ('batch:' + $batchId)) -Status 'approved' -Severity 'critical' -Project $Project -Scope $Scope -SkipCurator
    if ($id) { $ids += $id }
  }
  try { Add-Message -From system -Text ("🎛 Оператор делегировал batch " + $batchId + ": " + $ids.Count + " задач (приоритет operator, исполняются первыми).") -Kind event | Out-Null } catch {}
  return [pscustomobject]@{ batchId = $batchId; count = $ids.Count; ids = $ids }
}

#endregion Backlog failure classes, curator, and picker API

#region Operator batch reporting and self-execution safety

function Get-OperatorBatchProgress {
  # Progress of operator-delegated batches for the pulse: per batch id, how many done/failed/
  # blocked are terminal, plus still-running/nonterminal items.
  $items = @(Get-Backlog | Where-Object { @($_.tags) -contains 'operator' })
  $byBatch = @{}
  foreach ($it in $items) {
    $bid = @($it.tags | Where-Object { $_ -like 'batch:*' } | Select-Object -First 1)
    $bid = if ($bid.Count) { [string]$bid[0] } else { 'batch:?' }
    if (-not $byBatch.ContainsKey($bid)) {
      $byBatch[$bid] = [pscustomobject]@{ total = 0; done = 0; failed = 0; blocked = 0; running = 0 }
    }
    $byBatch[$bid].total++
    switch ([string]$it.status) {
      'done'         { $byBatch[$bid].done++ }
      'auto-resolved'{ $byBatch[$bid].done++ }
      'failed'       { $byBatch[$bid].failed++ }
      'held'         { $byBatch[$bid].blocked++ }
      'rejected'     { $byBatch[$bid].blocked++ }
      'auto-dropped' { $byBatch[$bid].blocked++ }
      'running'      { $byBatch[$bid].running++ }
      default        { $byBatch[$bid].running++ }
    }
  }
  return $byBatch
}

function Get-OperatorBatchTaskTitle {
  param($Item, [int]$MaxLength = 180)
  if ($null -eq $Item) { return '' }
  $title = ''
  try { $title = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'title' -Default '') } catch { $title = '' }
  if ([string]::IsNullOrWhiteSpace($title)) {
    $raw = ''
    try { $raw = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '') } catch { $raw = '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $lines = @($raw -split "\r?\n" | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($lines.Count -gt 0) { $title = [string]$lines[0] }
      else { $title = $raw }
    }
  }
  $title = ($title -replace '\s+', ' ').Trim()
  if ($title.Length -gt $MaxLength) { $title = $title.Substring(0, $MaxLength) + '...' }
  return $title
}

function Write-OperatorBatchReportError {
  param([string]$Message)
  $text = if ([string]::IsNullOrWhiteSpace($Message)) { 'unknown error' } else { [string]$Message }
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = ((Get-Date).ToUniversalTime().ToString('o') + " " + $text + "`n")
    [System.IO.File]::AppendAllText((Join-Path $dir 'operator-batch-errors.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try {
    if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
      Add-Message -From system -Text ("⚠ operator-batch summary failed: " + $text) -Kind event | Out-Null
    }
  } catch {}
}

function Get-OperatorBatchReportLedgerPath {
  return (Join-Path (Get-BacklogControlDir) 'operator-batch-reports.jsonl')
}

function Get-OperatorBatchReportKey {
  param([string]$BatchTag, [string]$BatchId)
  if (-not [string]::IsNullOrWhiteSpace($BatchTag)) { return ([string]$BatchTag).ToLowerInvariant() }
  if (-not [string]::IsNullOrWhiteSpace($BatchId)) { return ('batch:' + [string]$BatchId).ToLowerInvariant() }
  return ''
}

function Test-OperatorBatchReportLogged {
  param([string]$BatchTag, [string]$BatchId)
  $key = Get-OperatorBatchReportKey -BatchTag $BatchTag -BatchId $BatchId
  if ([string]::IsNullOrWhiteSpace($key)) { return $false }
  $path = Get-OperatorBatchReportLedgerPath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }

  try {
    $lineNo = 0
    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)) {
      $lineNo++
      $rawLine = [string]$line
      if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
      if ($rawLine.ToLowerInvariant().Contains($key)) { return $true }
      try {
        $rec = $rawLine | ConvertFrom-Json
        $recKey = Get-OperatorBatchReportKey -BatchTag ([string]$rec.batch_tag) -BatchId ([string]$rec.batch_id)
        if ($recKey -eq $key) { return $true }
      } catch {
        Write-OperatorBatchJsonWarningOnce -Source 'operator-batch ledger' -LineNumber $lineNo -Message $_.Exception.Message
      }
    }
  } catch {
    Write-OperatorBatchReportError -Message ("operator-batch ledger read failed: " + $_.Exception.Message)
  }
  return $false
}

function Add-OperatorBatchReportLedger {
  param([Parameter(Mandatory=$true)]$Report, [bool]$Posted)
  $batchTag = [string]$Report.batch_tag
  $batchId = [string]$Report.batch_id
  if (Test-OperatorBatchReportLogged -BatchTag $batchTag -BatchId $batchId) { return }

  $path = Get-OperatorBatchReportLedgerPath
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $record = [ordered]@{
    ts        = (Get-Date).ToUniversalTime().ToString('o')
    batch_tag = $batchTag
    batch_id  = $batchId
    report_ts = [string]$Report.report_ts
    posted    = [bool]$Posted
    summary   = [string]$Report.summary
  }
  $line = ($record | ConvertTo-Json -Compress -Depth 4)
  [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Write-OperatorBatchJsonWarningOnce {
  param(
    [Parameter(Mandatory=$true)][string]$Source,
    [int]$LineNumber,
    [string]$Message
  )
  if ($null -eq $script:OperatorBatchJsonWarnings) { $script:OperatorBatchJsonWarnings = @{} }
  $key = ([string]$Source + ':' + [string]$LineNumber + ':' + [string]$Message)
  if ($script:OperatorBatchJsonWarnings.ContainsKey($key)) { return }
  $script:OperatorBatchJsonWarnings[$key] = $true
  Write-OperatorBatchReportError -Message ("{0} invalid JSON at line {1}: {2}" -f $Source, $LineNumber, $Message)
}

function Reset-OperatorBatchReportMarker {
  param(
    [Parameter(Mandatory=$true)][string]$BatchTag,
    [Parameter(Mandatory=$true)][string]$ReportTs,
    [string]$Reason = ''
  )
  Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    $dirty = $false
    foreach ($item in @($items)) {
      if (-not ((@($item.tags) -contains 'operator') -and (@($item.tags) -contains $BatchTag))) { continue }
      $reportedAt = [string](Get-BacklogPackObjectValue -Obj $item -Name 'operator_batch_reported_at' -Default '')
      if ($reportedAt -ne $ReportTs) { continue }
      Set-BacklogObjectProperty -Item $item -Name operator_batch_reported -Value $false
      Set-BacklogObjectProperty -Item $item -Name operator_batch_report_error -Value $Reason
      $dirty = $true
    }
    if ($dirty) { Save-Backlog $items }
  }.GetNewClosure()) | Out-Null
}

function Test-OperatorBatchSummaryAlreadyPosted {
  param([string]$Summary, [string]$BatchId = '', [string]$BatchTag = '', [int]$Tail = 5000)
  if (Test-OperatorBatchReportLogged -BatchTag $BatchTag -BatchId $BatchId) { return $true }
  if ([string]::IsNullOrWhiteSpace($Summary) -and [string]::IsNullOrWhiteSpace($BatchId)) { return $false }
  if (-not (Get-Command Get-ConversationPath -ErrorAction SilentlyContinue)) { return $false }
  $path = ''
  try { $path = [string](Get-ConversationPath) } catch { $path = '' }
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return $false }
  try {
    $contentArgs = @{ LiteralPath = $path; Encoding = 'UTF8'; ErrorAction = 'Stop' }
    if ($Tail -gt 0) { $contentArgs['Tail'] = [Math]::Max(1, $Tail) }
    $batchPrefix = ''
    if (-not [string]::IsNullOrWhiteSpace($BatchId)) { $batchPrefix = 'operator-batch ' + [string]$BatchId + ':' }
    $lineNo = 0
    foreach ($line in @(Get-Content @contentArgs)) {
      $lineNo++
      $rawLine = [string]$line
      if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
      if (-not [string]::IsNullOrWhiteSpace($Summary) -and $rawLine.Contains($Summary)) { return $true }
      if (-not [string]::IsNullOrWhiteSpace($batchPrefix) -and $rawLine.Contains($batchPrefix)) { return $true }
      try {
        $rec = $rawLine | ConvertFrom-Json
        $from = [string]$rec.from
        if ($from -ne 'system') { continue }
        $messages = New-Object 'System.Collections.Generic.List[string]'
        foreach ($prop in @('text','message','content')) {
          if ($rec.PSObject.Properties.Name -contains $prop) {
            $value = [string]$rec.PSObject.Properties[$prop].Value
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$messages.Add($value) }
          }
        }
        foreach ($msg in @($messages.ToArray())) {
          if (-not [string]::IsNullOrWhiteSpace($Summary) -and $msg -eq $Summary) { return $true }
          if (-not [string]::IsNullOrWhiteSpace($batchPrefix) -and $msg.StartsWith($batchPrefix, [System.StringComparison]::Ordinal)) { return $true }
        }
      } catch {
        Write-OperatorBatchJsonWarningOnce -Source 'conversation scan tail' -LineNumber $lineNo -Message $_.Exception.Message
      }
    }
  } catch {
    Write-OperatorBatchReportError -Message ("conversation scan failed for operator-batch " + [string]$BatchId + ": " + $_.Exception.Message)
  }
  return $false
}

function Test-OperatorBatchReportPersisted {
  param(
    [object[]]$Items,
    [Parameter(Mandatory=$true)][string]$BatchTag,
    [Parameter(Mandatory=$true)][string]$ReportTs
  )
  $matched = 0
  foreach ($item in @($Items)) {
    if (-not ((@($item.tags) -contains 'operator') -and (@($item.tags) -contains $BatchTag))) { continue }
    $matched++
    $reported = $false
    $reportedAt = ''
    try { $reported = [bool](Get-BacklogPackObjectValue -Obj $item -Name 'operator_batch_reported' -Default $false) } catch { $reported = $false }
    try { $reportedAt = [string](Get-BacklogPackObjectValue -Obj $item -Name 'operator_batch_reported_at' -Default '') } catch { $reportedAt = '' }
    if (-not $reported -or $reportedAt -ne $ReportTs) { return $false }
  }
  return ($matched -gt 0)
}

function Publish-OperatorBatchCompletionSummariesIfNeeded {
  # Driver idle hook calls Start-ProjectAutopilotIfNeeded even on non-project channels. Use that
  # existing hook to post ONE terminal summary per operator batch, then persist a marker on the
  # batch's backlog items so the report never repeats.
  $reports = @(Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    if ($items.Count -eq 0) { return @() }

    $progress = Get-OperatorBatchProgress
    if ($null -eq $progress -or $progress.Count -eq 0) { return @() }

    $terminal = @{ done = $true; 'auto-resolved' = $true; failed = $true; held = $true; rejected = $true; 'auto-dropped' = $true }
    $reports = New-Object 'System.Collections.Generic.List[object]'
    $dirty = $false

    foreach ($batchTag in @($progress.Keys | Sort-Object)) {
      $batchItems = @(
        $items | Where-Object {
          (@($_.tags) -contains 'operator') -and (@($_.tags) -contains [string]$batchTag)
        }
      )
      if ($batchItems.Count -eq 0) { continue }

      $alreadyReported = $false
      foreach ($batchItem in $batchItems) {
        $reported = $false
        try { $reported = [bool](Get-BacklogPackObjectValue -Obj $batchItem -Name 'operator_batch_reported' -Default $false) } catch { $reported = $false }
        if ($reported) { $alreadyReported = $true; break }
      }
      if ($alreadyReported) { continue }

      $allTerminal = $true
      $failedTitles = New-Object 'System.Collections.Generic.List[string]'
      foreach ($batchItem in $batchItems) {
        $status = ([string](Get-BacklogPackObjectValue -Obj $batchItem -Name 'status' -Default '')).ToLowerInvariant()
        if (-not $terminal.ContainsKey($status)) { $allTerminal = $false; break }
        if ($status -eq 'failed') {
          $title = Get-OperatorBatchTaskTitle -Item $batchItem
          if (-not [string]::IsNullOrWhiteSpace($title)) { [void]$failedTitles.Add($title) }
        }
      }
      if (-not $allTerminal) { continue }

      $batchId = ([string]$batchTag -replace '^batch:', '')
      $batchProgress = $progress[[string]$batchTag]
      $summary = ("operator-batch {0}: {1} done, {2} failed, {3} blocked" -f $batchId, [int]$batchProgress.done, [int]$batchProgress.failed, [int]$batchProgress.blocked)
      if ($failedTitles.Count -gt 0) {
        $summary += "`nfailed tasks:"
        foreach ($title in @($failedTitles.ToArray())) {
          $summary += "`n- $title"
        }
      }

      $reportTs = (Get-Date).ToUniversalTime().ToString('o')
      $alreadyPosted = Test-OperatorBatchSummaryAlreadyPosted -Summary $summary -BatchId $batchId -BatchTag ([string]$batchTag)
      foreach ($batchItem in $batchItems) {
        Set-BacklogObjectProperty -Item $batchItem -Name operator_batch_reported -Value $true
        Set-BacklogObjectProperty -Item $batchItem -Name operator_batch_reported_at -Value $reportTs
        Set-BacklogObjectProperty -Item $batchItem -Name operator_batch_report -Value $summary
      }
      $dirty = $true
      [void]$reports.Add([pscustomobject]@{ batch_tag = [string]$batchTag; batch_id = $batchId; summary = $summary; report_ts = $reportTs; post_message = (-not $alreadyPosted) })
    }

    if ($dirty) {
      Save-Backlog $items
      $savedItems = @(Get-Backlog)
      foreach ($report in @($reports.ToArray())) {
        if (-not (Test-OperatorBatchReportPersisted -Items $savedItems -BatchTag ([string]$report.batch_tag) -ReportTs ([string]$report.report_ts))) {
          throw ("operator-batch marker did not persist for {0}" -f [string]$report.batch_id)
        }
      }
    }

    return @($reports.ToArray())
  }.GetNewClosure()))

  $published = New-Object 'System.Collections.Generic.List[object]'
  foreach ($report in @($reports)) {
    $postedOrObserved = -not [bool]$report.post_message
    if ([bool]$report.post_message) {
      try {
        Add-Message -From system -Text ([string]$report.summary) -Kind event | Out-Null
        $postedOrObserved = $true
      } catch {
        $reason = ("Add-Message failed for operator-batch {0}: {1}" -f [string]$report.batch_id, $_.Exception.Message)
        Write-OperatorBatchReportError -Message $reason
        Reset-OperatorBatchReportMarker -BatchTag ([string]$report.batch_tag) -ReportTs ([string]$report.report_ts) -Reason $reason
        continue
      }
    }
    try { Add-OperatorBatchReportLedger -Report $report -Posted $postedOrObserved } catch { Write-OperatorBatchReportError -Message ("operator-batch ledger append failed: " + $_.Exception.Message) }
    [void]$published.Add([pscustomobject]@{ batch_id = [string]$report.batch_id; summary = [string]$report.summary; posted = [bool]$report.post_message })
  }
  return @($published.ToArray())
}

function Get-NextSelfExecIdea {
  # Increment B selection (graduated self-development). Returns the next UNapproved 'new' idea whose
  # heuristic risk tier is WITHIN the operator's selfExecuteTier dial -- so a 'green' dial never
  # auto-runs a 'yellow' idea, AND the queue never wedges on an out-of-dial item sitting ahead of
  # runnable ones (we scan past it to the first in-dial idea). External/radar are excluded
  # (anti-backdoor), and project-scoped ideas are skipped unless autonomy scope is 'projects' --
  # mirroring Get-NextApprovedIdea. red-tier is never returned at any dial. Deterministic, no LLM.
  #   Dial 'green'  -> first new idea classified green
  #   Dial 'yellow' -> first new idea classified green OR yellow
  param([string]$Dial)
  $d = ([string]$Dial).ToLowerInvariant()
  if ($d -ne 'green' -and $d -ne 'yellow') { return $null }
  $cands = @(Get-Backlog | Where-Object {
      ([string]$_.status -eq 'new') -and -not (Test-IdeaExternal $_)
    } |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}})
  try {
    $sc = Get-AutonomySettings
    if ([string]$sc.scope -ne 'projects') {
      $cands = @($cands | Where-Object { -not ($_.PSObject.Properties.Name -contains 'scope') -or ([string]$_.scope -ne 'project') })
    }
  } catch {}
  foreach ($it in $cands) {
    $t = ([string](Get-IdeaRiskTier -Idea $it).tier)
    $ok = ($d -eq 'green' -and $t -eq 'green') -or ($d -eq 'yellow' -and ($t -eq 'green' -or $t -eq 'yellow'))
    if ($ok) { return $it }
  }
  return $null
}

function Test-IdeaTouchesControlPlane {
  # TRUE if the task edits the bridge's own control/safety plane (supervisor, watchdog, circuit-
  # breaker, the driver core loop, restart-limit, script-integrity). Autonomously editing these is
  # what repeatedly deadlocked the bridge on 2026-05-31 (a cascade of conflicting over-protections
  # the bridge generated for itself). Used to (1) classify such ideas as red, and (2) HARD-BLOCK
  # auto-claim of them unless the OPERATOR explicitly delegated (tag 'operator') or the item carries
  # a valid bridge_self_admission. Deterministic.
  param($Idea)
  try { if (Test-IdeaTouchesControlPlanePath -Idea $Idea) { return $true } } catch {}
  $t = ''
  try { $t = ([string]$Idea.text).ToLowerInvariant() } catch {}
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  $cpPat = '(watchdog|supervisor|process[_ -]?supervision|runtime[_ -]?incident|circuit[_ -]?break|restart[_ -]?limit|script[_ -]?integrit|concurrent.{0,4}driver|control[_ -]?plane|driver[^/\s\\]*\.ps1|driver[\\/][^\s,;:]+\.ps1|server\.ps1|supervisor\.ps1|watchdog\.ps1|lib[\\/]backlog[^/\s\\]*\.ps1|lib[\\/](parallel|circuit-breaker)\.ps1|circuit-breaker\.ps1|kill-bridge|self[_ -]?edit)'
  return [bool]($t -match $cpPat)
}

function Get-IdeaRiskTier {
  # Heuristic risk classifier for graduated self-execution. CONSERVATIVE by design:
  #   red    = never auto-executes — externally-sourced (anti-backdoor) OR touches the
  #            safety/security/irreversible surface (watchdog, .git, secrets, delete, sandbox...)
  #   green  = explicitly low-blast-radius & reversible (docs/comments/typos/lint/log wording)
  #   yellow = everything else (a real code change) — never auto-green; caution by default
  # Deterministic, no LLM (cheap enough to run every idle tick). Returns @{ tier; reason }.
  # Patterns are bilingual (RU+EN) because ideas are authored in both.
  param($Idea)
  $text = ''
  try { $text = ([string]$Idea.text).ToLowerInvariant() } catch {}
  if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ tier = 'red'; reason = 'пустой текст идеи' } }
  try { if (Test-IdeaExternal $Idea) { return [pscustomobject]@{ tier = 'red'; reason = 'внешний источник (radar/web) — только ручное одобрение' } } } catch {}
  # 2026-05-30: 'token' was a bare alternative -> it red-flagged COST telemetry like
  # "failed-token-burn"/"token usage"/"tokens spent" (LLM-token metrics, NOT auth). A real
  # task (split SPEED/COST slices in deep-audit) sat unapproved 18h on that false red. Narrow
  # 'token' to auth-context via negative-lookahead that excludes the cost vocabulary; auth/API
  # tokens still match (secret|credential|api-key|auth.json also cover the security cases).
  # 2026-05-31: the bridge's own CONTROL PLANE is now red = operator-only. A cascade of
  # autonomously-generated 'process_supervision' / 'runtime-incident' tasks edited supervisor /
  # watchdog / circuit-breaker / restart-limit / script-integrity and repeatedly DEADLOCKED the
  # bridge ("we keep raising it from the dead"). Self-editing the safety/control surface autonomously
  # is the single highest-risk class -- it must go through the operator, never auto-exec.
  if (Test-IdeaTouchesControlPlane -Idea $Idea) { return [pscustomobject]@{ tier = 'red'; reason = 'правка собственного контура моста (supervisor/watchdog/circuit-breaker) — только оператор' } }
  $redPat = '(watchdog|supervisor|kill[- ]?switch|\.git|force[- ]?push|reset --hard|secret|credential|пароль|password|auth\.json|tokens?\b(?![-\s]?(?:burn|usage|count|budget|spent|cost|drain|throughput|per\b|/))|api[- ]?key|sandbox|permission|разрешени|удал|delete|drop\s+table|rm\s+-rf|encrypt|шифр|биллинг|billing|оплат|payment)'
  if ($text -match $redPat) { return [pscustomobject]@{ tier = 'red'; reason = 'затрагивает безопасность/необратимое/деньги' } }
  $greenPat = '(коммент|comment|документац|\bdocs?\b|readme|typo|опечат|орфограф|wording|форматир|\bformat\b|\blint\b|мёртв\w* код|dead code|unused|неиспольз|лог[- ]?сообщен|log message|whitespace|пробел|отступ|переименован\w* переменн|rename \w+ variable)'
  if ($text -match $greenPat) { return [pscustomobject]@{ tier = 'green'; reason = 'узкий обратимый скоуп (доки/комменты/линт/тексты)' } }
  return [pscustomobject]@{ tier = 'yellow'; reason = 'реальное изменение кода — нужна осторожность' }
}

function Set-IdeaRiskTier {
  # Persist a classified risk tier on the backlog item (UI visibility + audit trail).
  param([string]$Id, [string]$Tier, [string]$Reason = '')
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $hit = $false
  foreach ($i in $items) {
    if ([string]$i.id -eq $Id) {
      $i | Add-Member -NotePropertyName risk_tier   -NotePropertyValue ([string]$Tier)   -Force
      $i | Add-Member -NotePropertyName risk_reason -NotePropertyValue ([string]$Reason) -Force
      $i | Add-Member -NotePropertyName risk_ts     -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $hit = $true; break
    }
  }
  if ($hit) { Save-Backlog $items }
  return $hit
}

function Set-IdeaSelfExec {
  # Mark a backlog item as auto-claimed by graduated self-development (Increment B). At claim time
  # call with -Dial; at task completion call again with -Commit to stamp the resulting SHA so the
  # safety-reflex can correlate it to the 24h verdict. Additive; never removes existing fields.
  param([string]$Id, [string]$Dial = '', [string]$Commit = '')
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog); $hit = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $i | Add-Member -NotePropertyName self_exec -NotePropertyValue $true -Force
    if (-not [string]::IsNullOrWhiteSpace($Dial)) { $i | Add-Member -NotePropertyName self_exec_dial -NotePropertyValue ([string]$Dial) -Force }
    if (-not ($i.PSObject.Properties.Name -contains 'self_exec_ts')) {
      $i | Add-Member -NotePropertyName self_exec_ts -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($Commit)) { $i | Add-Member -NotePropertyName self_exec_commit -NotePropertyValue ([string]$Commit) -Force }
    $hit = $true; break
  }
  if ($hit) { Save-Backlog $items }
  return $hit
}

function Test-SelfDevSafetyReflex {
  # Graduated-autonomy safety reflex: if recent self-executed commits were judged 'worse' by the
  # 24h verdict cycle, recommend dialing selfExecuteTier DOWN one notch (yellow->green->shadow) so
  # the system throttles its OWN autonomy after regressions -- the system learning caution. This is
  # the SECOND line of defence; smoke+critic gates (pre-commit) and verdict auto-revert (per-commit)
  # are the first. Read-only here -- the caller applies the change. CONSERVATIVE: fires only on
  # >=WorseThreshold settled 'worse' verdicts among self-exec commits within the lookback window.
  # Returns @{ shouldDampen; fromDial; newDial; worseCount }.
  param([string]$CurrentDial, [int]$WorseThreshold = 2, [int]$LookbackDays = 14)
  $cur = ([string]$CurrentDial).ToLowerInvariant()
  $out = [pscustomobject]@{ shouldDampen = $false; fromDial = $cur; newDial = $cur; worseCount = 0 }
  if ($cur -ne 'green' -and $cur -ne 'yellow') { return $out }   # shadow/off: nothing to dampen
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($LookbackDays))
  $selfCommits = @{}
  foreach ($i in @(Get-Backlog)) {
    if (-not ([bool]$i.self_exec)) { continue }
    $c = [string]$i.self_exec_commit
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    $ts = $null; try { $ts = ([datetime]$i.self_exec_ts).ToUniversalTime() } catch {}
    if ($ts -and $ts -lt $cutoff) { continue }
    $selfCommits[$c] = $true
    if ($c.Length -ge 7) { $selfCommits[$c.Substring(0, 7)] = $true }
  }
  if ($selfCommits.Count -eq 0) { return $out }
  $worse = 0
  try {
    foreach ($r in @(Read-MetricsJsonl)) {
      if ([string]$r.type -ne 'verdict' -or [string]$r.verdict -ne 'worse') { continue }
      $vc = [string]$r.commit
      if ([string]::IsNullOrWhiteSpace($vc)) { continue }
      if ($selfCommits.ContainsKey($vc) -or ($vc.Length -ge 7 -and $selfCommits.ContainsKey($vc.Substring(0, 7)))) { $worse++ }
    }
  } catch {}
  $out.worseCount = $worse
  if ($worse -ge $WorseThreshold) {
    $out.shouldDampen = $true
    $out.newDial = if ($cur -eq 'yellow') { 'green' } else { 'shadow' }
  }
  return $out
}

#endregion Operator batch reporting and self-execution safety
