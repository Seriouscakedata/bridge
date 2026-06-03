# 21-priority-curator.ps1 -- LLM prioritization, item mutation, removal, and curator.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function New-BacklogLLMPriorityPrompt {
  param([object[]]$Ideas)

  $promptBuilder = New-Object System.Text.StringBuilder
  [void]$promptBuilder.AppendLine('Ты — приоритизатор задач для автономного ИИ-моста.')
  [void]$promptBuilder.AppendLine('Ниже список задач. Оцени каждую по шкале 0-100 с учётом:')
  [void]$promptBuilder.AppendLine('- Практической ценности (насколько улучшит работу моста)')
  [void]$promptBuilder.AppendLine('- Срочности (блокирует ли что-то прямо сейчас)')
  [void]$promptBuilder.AppendLine('- Сложности реализации (более простые — выше при прочих равных)')
  [void]$promptBuilder.AppendLine('- Безопасности (задачи, снижающие риски — приоритет)')
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

    $ideaIds = @{}
    foreach ($idea in $ideas) {
      $ideaId = ''
      try { $ideaId = [string]$idea.id } catch { $ideaId = '' }
      if (-not [string]::IsNullOrWhiteSpace($ideaId)) { $ideaIds[$ideaId] = $true }
    }
    $idToIndex = @{}
    for ($idx = 0; $idx -lt $allItems.Count; $idx++) {
      $itemId = ''
      try { $itemId = [string]$allItems[$idx].id } catch { $itemId = '' }
      if (-not [string]::IsNullOrWhiteSpace($itemId)) { $idToIndex[$itemId] = $idx }
    }

    $updated = 0
    foreach ($rank in $ranked) {
      $id = ''
      try { $id = [string]$rank.id } catch { $id = '' }
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if (-not $ideaIds.ContainsKey($id)) { continue }
      if (-not $idToIndex.ContainsKey($id)) { continue }

      $score100 = 0.0
      try { $score100 = [double]$rank.score } catch { continue }
      if ($score100 -lt 0) { $score100 = 0.0 }
      if ($score100 -gt 100) { $score100 = 100.0 }
      $reason = ''
      try { $reason = ([string]$rank.reason).Trim() } catch { $reason = '' }

      $targetIndex = [int]$idToIndex[$id]
      $target = $allItems[$targetIndex]
      $target | Add-Member -NotePropertyName score -NotePropertyValue ([Math]::Round($score100 / 10.0, 2)) -Force
      $target | Add-Member -NotePropertyName llm_priority_reason -NotePropertyValue $reason -Force
      $allItems[$targetIndex] = $target
      $updated++
    }

    if ($updated -gt 0) { Save-Backlog $allItems }
    Write-Host "🧠 LLM-приоритизация: обновлено $($updated) идей из $($ideas.Count)"
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

function Set-Idea {
  # Edit a backlog item. Pass $null to leave a field unchanged.
  param([string]$Id, $Status = $null, $Text = $null, $IncrementAttempts = $false, [bool]$ClearAutoCurator = $false, [string]$Reason = $null)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  # H2 FIX (2026-05-31 load audit): the read-modify-write was NOT transactional. Get-Backlog (read)
  # and Save-Backlog (write) each took the lock independently, so a concurrent Set-Idea / curator /
  # packer landing between them caused a LOST UPDATE -- a status mutation (approved->running, or a
  # curator approval) silently overwritten, leaving a task re-claimed twice or stuck forever. Under
  # 100 queued items the rewrite window is large and collisions frequent. Hold the bridge lock across
  # the WHOLE RMW; the named mutex is thread-reentrant so Save-Backlog's nested lock is safe.
  return (Invoke-BacklogLocked ({
  $items = @(Get-Backlog)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $found = $true
    if ($ClearAutoCurator) {
      foreach ($prop in @('auto_curator', 'resolved_by_sha', 'resolved_reason')) {
        try {
          if ($i.PSObject.Properties.Name -contains $prop) { $i.PSObject.Properties.Remove($prop) }
        } catch {}
      }
    }
    if ($null -ne $Status) {
      $statusText = [string]$Status
      $i | Add-Member -NotePropertyName status -NotePropertyValue $statusText -Force
      if ($statusText -eq 'approved') {
        $i | Add-Member -NotePropertyName approved_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $i | Add-Member -NotePropertyName approved_at_sha -NotePropertyValue (Get-BacklogCurrentSha) -Force
      } elseif ($statusText -eq 'auto-dropped' -and -not [string]::IsNullOrWhiteSpace($Reason)) {
        $manual = [ordered]@{
          verdict = 'drop'
          confidence = 1.0
          reason = [string]$Reason
          model = 'manual'
          ts = (Get-Date).ToUniversalTime().ToString('o')
          judged_at_sha = (Get-BacklogCurrentSha)
        }
        $i | Add-Member -NotePropertyName auto_curator -NotePropertyValue ([pscustomobject]$manual) -Force
      }
    }
    if ($null -ne $Text -and -not [string]::IsNullOrWhiteSpace([string]$Text)) { $i | Add-Member -NotePropertyName text -NotePropertyValue ([string]$Text) -Force }
    if ($IncrementAttempts) {
      $a = 0; try { $a = [int]$i.attempts } catch {}
      $i | Add-Member -NotePropertyName attempts -NotePropertyValue ($a + 1) -Force
    }
    break
  }
  if (-not $found) { return $false }
  Save-Backlog $items
  return $true
  }.GetNewClosure()))
}

function Remove-Idea {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $i | Add-Member -NotePropertyName status -NotePropertyValue 'rejected' -Force
    $i | Add-Member -NotePropertyName rejected_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $found = $true
    break
  }
  if (-not $found) { return $false }
  Save-Backlog $items
  return $true
}

function Invoke-BacklogCurator {
  param([string]$ItemId)
  if ([string]::IsNullOrWhiteSpace($ItemId)) { return $null }
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
