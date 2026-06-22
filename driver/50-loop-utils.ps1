function Get-MaxUserSeq {
  $u = Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' }
  if ($u) { return ([int]($u[-1].seq)) } else { return 0 }
}
function Next-Speaker {
  $msgs = Get-Messages -Since 0
  for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
    if ($msgs[$i].from -eq 'claude') { return 'codex' }
    if ($msgs[$i].from -eq 'codex')  { return 'claude' }
  }
  return 'claude'
}

function Get-StudySpeaker {
  param([int]$TaskTurn, [string]$StudySubtype, [string]$StudyPhase)
  if ($TaskTurn -le 0) { return 'claude' }
  if ($StudyPhase -eq 'synthesis' -or $TaskTurn -ge ($studyMaxTurns - 1)) { return 'claude' }
  if ($StudySubtype -eq 'local') {
    if ($TaskTurn -eq 1) { return 'codex' }
    return 'claude'
  }
  if ($TaskTurn -eq 2) { return (Next-Speaker) }
  return 'claude'
}

function Get-TaskTopic {
  param([string]$TaskText, [int]$MaxLen = 200)
  $clean = ($TaskText -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
  if ($clean.Length -le $MaxLen) { return $clean }
  return ($clean.Substring(0, $MaxLen).TrimEnd() + '...')
}

function Get-AgentStatusText {
  param([string]$Speaker, [string]$Mode, [string]$TaskText = '')
  $topic = if ($TaskText) { Get-TaskTopic $TaskText } else { '' }
  if ($topic) {
    if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return "Claude исследует источники: «$topic»" }
    if ($Speaker -eq 'claude' -and $Mode -eq 'synthesis') { return "Decision Synthesis принимает решение: «$topic»" }
    if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return "Claude обдумывает план: «$topic»" }
    if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return "Claude изучает и синтезирует: «$topic»" }
    if ($Speaker -eq 'claude') { return "Claude планирует: «$topic»" }
    if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return "Codex оценивает идею: «$topic»" }
    if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return "Codex собирает локальные находки: «$topic»" }
    if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
  }
  if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude ищет и сверяет внешние источники без Bash.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'synthesis') { return 'Decision Synthesis строит контракт, предложения, судью и итоговое решение.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет следующий шаг.' }
  if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return 'Claude ведёт web-трек study и готовит синтез.' }
  if ($Speaker -eq 'claude') { return 'Claude анализирует задачу и выбирает следующий шаг.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex оценивает план, риски и варианты без изменения файлов.' }
  if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return 'Codex изучает локальную структуру и фиксирует FINDING.' }
  if ($Speaker -eq 'codex') { return 'Codex выполняет правку и проверяет результат.' }
  return $null
}

function Get-AgentPhaseStatusText {
  param([string]$Speaker, [string]$Mode, [string]$Phase, [string]$TaskText = '')
  $who   = if ($Speaker -eq 'claude') { 'Claude' } elseif ($Speaker -eq 'codex') { 'Codex' } else { 'агент' }
  $topic = if ($TaskText) { Get-TaskTopic $TaskText } else { '' }
  switch ($Phase) {
    'summary' { return "Проверяю историю диалога перед ходом $who..." }
    'prompt'  { return "Готовлю контекст и промпт для $who..." }
    'invoke'  {
      if ($topic) {
        if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return "Claude ищет внешние источники: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'synthesis') { return "Decision Synthesis строит multi-model решение: «$topic»" }
        if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return "Codex оценивает идею: «$topic»" }
        if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return "Codex изучает локальный проект: «$topic»" }
        if ($Speaker -eq 'codex') { return "Codex реализует: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return "Claude обдумывает план: «$topic»" }
        if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return "Claude изучает источники и готовит отчёт: «$topic»" }
        return "Claude планирует: «$topic»"
      }
      if ($Speaker -eq 'codex' -and $Mode -eq 'discuss') { return 'Codex читает контекст и отвечает без изменения файлов.' }
      if ($Speaker -eq 'codex' -and $Mode -eq 'study') { return 'Codex собирает локальные FINDING-находки.' }
      if ($Speaker -eq 'codex') { return 'Codex работает с файлами и командами.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'research') { return 'Claude проверяет внешние источники без Bash.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'synthesis') { return 'Decision Synthesis вызывает модели и пишет артефакты решения.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'discuss') { return 'Claude сводит обсуждение и уточняет план.' }
      if ($Speaker -eq 'claude' -and $Mode -eq 'study') { return 'Claude ведёт study-исследование и синтезирует отчёт.' }
      return 'Claude анализирует задачу и выбирает следующий шаг.'
    }
    'post'    { return "Обрабатываю ответ $who, проверяю вложения..." }
    default   { return Get-AgentStatusText -Speaker $Speaker -Mode $Mode -TaskText $TaskText }
  }
}

function Set-BridgeStatusText {
  param([string]$Text)
  Update-State ({ param($s) $s.status_text=$Text; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
}

function Update-DriverHeartbeat {
  # Refresh ONLY the driver heartbeat timestamp (not status_text). Used by the DONE-gate heartbeat
  # pump (Wait-DriverDoneGateJobsWithHeartbeat) so a long but HEALTHY gate window keeps the watchdog
  # satisfied without clobbering the visible status line. Reuses the atomic Update-State write path
  # so the state integrity hash stays valid.
  Update-State ({ param($s) $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
}

function Write-TurnLog {
  param(
    [string]$Speaker,
    [string]$Model,
    [string]$Mode,
    [DateTime]$StartedAtUtc,
    [string]$Reply,
    [string]$Status = '',
    [switch]$FastLane
  )
  try {
    $turnStatus = $Status
    if ([string]::IsNullOrWhiteSpace($turnStatus)) {
      if ([string]$Reply -match 'timeout') { $turnStatus = 'timeout' }
      elseif ([string]::IsNullOrWhiteSpace($Reply)) { $turnStatus = 'empty' }
      else { $turnStatus = 'ok' }
    }
    $sec = [Math]::Round(([DateTime]::UtcNow - $StartedAtUtc).TotalSeconds, 3)
    $entry = [ordered]@{
      ts      = [DateTime]::UtcNow.ToString('o')
      speaker = $Speaker
      model   = $Model
      sec     = $sec
      status  = $turnStatus
      mode    = $Mode
      fast_lane = [bool]$FastLane
    }
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'turns.jsonl') -Value ($entry | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
    # Accumulate per-phase LLM latency
    try {
      $script:DriverTurnPhaseMs = [long][Math]::Round($sec * 1000)
      if ($Speaker -eq 'claude' -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) {
        Update-TaskPhaseTiming -Phase planner_ms -Ms $script:DriverTurnPhaseMs
      } elseif ($Speaker -eq 'codex' -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) {
        Update-TaskPhaseTiming -Phase worker_ms -Ms $script:DriverTurnPhaseMs
      }
    } catch {}
    try {
      $null = Add-UsageRecord -Kind prepaid -Provider $Speaker -Model $Model -Purpose $Mode -Sec $sec -Status $turnStatus
    } catch {}
  } catch {}
}

function Reset-TaskAgentDuration {
  param($State)
  $State | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue 0 -Force
}

function Complete-TaskAgentDuration {
  param($State)
  $totalSec = 0
  try { $totalSec = [int]$State.task_agent_duration_sec } catch {}
  $State | Add-Member -NotePropertyName last_task_agent_duration_sec -NotePropertyValue $totalSec -Force
  $State | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue 0 -Force
}

function Get-PushSnippet {
  param([string]$Text, [int]$Max = 120)
  $s = ([string]$Text).Trim() -replace '\s+', ' '
  if ($s.Length -gt $Max) { return ($s.Substring(0, $Max) + '...') }
  return $s
}

function Write-EvidenceLog {
  param(
    [string]$Agent,
    [string]$Task,
    [string]$Source,
    [string]$Summary,
    [string]$Confidence
  )
  try {
    $taskSnippet = ([string]$Task).Trim()
    if ($taskSnippet.Length -gt 100) { $taskSnippet = $taskSnippet.Substring(0, 100) }
    $entry = [ordered]@{
      ts         = [DateTime]::UtcNow.ToString('o')
      agent      = $Agent
      task       = $taskSnippet
      source     = $Source
      summary    = $Summary
      confidence = $Confidence
    }
    Add-Content -LiteralPath (Join-Path $bridgeRoot 'evidence.jsonl') -Value ($entry | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
    return $true
  } catch {
    return $false
  }
}
