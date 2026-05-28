# Auto post-mortem for repair commits. This file intentionally keeps the older
# timeout/safety Invoke-PostMortem call shape compatible with lib/metrics.ps1.

function Write-PostMortemWarning {
  param([string]$Message)
  try { Write-Warning $Message } catch { [void]$Message }
}

function Limit-PostMortemText {
  param(
    [AllowNull()][object]$Value,
    [int]$MaxChars = 1000
  )
  $text = if ($null -eq $Value) { '' } else { [string]$Value }
  if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) {
    return ($text.Substring(0, $MaxChars) + "`n[...truncated]")
  }
  return $text
}

function Get-PostMortemFailureInfo {
  param([AllowNull()][object]$State)
  $kind = 'не зафиксирована'
  $ts = ''
  $text = ''
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'task_last_failure') -and $null -ne $State.task_last_failure) {
      $f = $State.task_last_failure
      if ($f.PSObject.Properties.Name -contains 'kind' -and -not [string]::IsNullOrWhiteSpace([string]$f.kind)) { $kind = [string]$f.kind }
      if ($f.PSObject.Properties.Name -contains 'ts') { $ts = [string]$f.ts }
      if ($f.PSObject.Properties.Name -contains 'text') { $text = [string]$f.text }
    }
  } catch {
    Write-PostMortemWarning ("task_last_failure parse failed: " + $_.Exception.Message)
  }
  return [pscustomobject]@{ kind=$kind; ts=$ts; text=$text }
}

function Get-PostMortemTurnsTail {
  param(
    [string]$RepoRoot,
    [int]$LastLines = 15
  )
  $turnsPath = Join-Path $RepoRoot 'turns.jsonl'
  if (-not (Test-Path -LiteralPath $turnsPath)) { return [pscustomobject]@{ text='(turns.jsonl отсутствует)'; count=0 } }
  $items = New-Object 'System.Collections.Generic.List[string]'
  $count = 0
  try {
    $lines = [System.IO.File]::ReadAllLines($turnsPath, [System.Text.Encoding]::UTF8)
    $tail = @($lines | Select-Object -Last $LastLines)
    foreach ($raw in $tail) {
      $line = ([string]$raw).Trim()
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        if ($line.Length -gt 0 -and [int][char]$line[0] -eq 0xFEFF) { $line = $line.Substring(1) }
        $o = $line | ConvertFrom-Json
        $ts = if ($o.PSObject.Properties.Name -contains 'ts') { [string]$o.ts } else { '' }
        $speaker = if ($o.PSObject.Properties.Name -contains 'speaker') { [string]$o.speaker } elseif ($o.PSObject.Properties.Name -contains 'role') { [string]$o.role } else { '' }
        $model = if ($o.PSObject.Properties.Name -contains 'model') { [string]$o.model } else { '' }
        $sec = if ($o.PSObject.Properties.Name -contains 'sec') { [string]$o.sec } elseif ($o.PSObject.Properties.Name -contains 'duration') { [string]$o.duration } else { '' }
        $status = if ($o.PSObject.Properties.Name -contains 'status') { [string]$o.status } else { '' }
        [void]$items.Add("[$ts] $speaker | $model | ${sec}s | $status")
        $count++
      } catch {
        [void]$items.Add("[unparsed] " + (Limit-PostMortemText -Value $line -MaxChars 180))
        $count++
      }
    }
  } catch {
    return [pscustomobject]@{ text=("Не удалось прочитать turns.jsonl: " + $_.Exception.Message); count=0 }
  }
  if ($items.Count -eq 0) { return [pscustomobject]@{ text='(нет строк turns)'; count=0 } }
  return [pscustomobject]@{ text=([string]::Join("`n", $items.ToArray())); count=$count }
}

function Get-PostMortemGitContext {
  param(
    [string]$CommitSha,
    [string]$RepoRoot
  )
  $stat = ''
  $diff = ''
  try {
    $stat = ((& git -C $RepoRoot show --stat $CommitSha 2>$null) | Out-String).Trim()
  } catch {
    $stat = "Не удалось прочитать git stat: " + $_.Exception.Message
  }
  try {
    $null = & git -C $RepoRoot rev-parse "$CommitSha^" 2>$null
    if ($LASTEXITCODE -eq 0) {
      $diff = ((& git -C $RepoRoot diff "$CommitSha^..$CommitSha" -- '*.ps1' '*.js' '*.html' 2>$null) | Out-String).Trim()
    } else {
      $diff = ((& git -C $RepoRoot show $CommitSha 2>$null) | Out-String).Trim()
    }
  } catch {
    try { $diff = ((& git -C $RepoRoot show $CommitSha 2>$null) | Out-String).Trim() } catch { $diff = "Не удалось прочитать git diff: " + $_.Exception.Message }
  }
  return [pscustomobject]@{
    stat = (Limit-PostMortemText -Value $stat -MaxChars 500)
    diff = (Limit-PostMortemText -Value $diff -MaxChars 3000)
  }
}

function Invoke-GeminiPostMortem {
  param([string]$Prompt)
  if ($env:POSTMORTEM_TEST -eq '1') {
    return "FAKE_LLM_RESPONSE`n`n## Корневая причина`nТестовая причина.`n`n## Что исправлено`nТестовое исправление.`n`n## Рекомендации`n- Тестовая рекомендация.`n`n## Идея в бэклог`nno"
  }
  $model = 'gemini-2.0-flash-lite'
  try {
    if (Get-Command Invoke-GeminiChat -ErrorAction SilentlyContinue) {
      return Invoke-GeminiChat -Model $model -Prompt $Prompt -TimeoutSec 30 -Temperature 0.2 -Purpose 'postmortem'
    }
  } catch {
    Write-Warning ("Invoke-GeminiChat post-mortem failed: " + $_.Exception.Message)
  }
  try {
    $secretPath = Join-Path (Get-BridgeRoot) 'secrets.json'
    if (-not (Test-Path -LiteralPath $secretPath)) { Write-Warning 'secrets.json не найден'; return $null }
    $secrets = [System.IO.File]::ReadAllText($secretPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $key = ''
    if ($secrets.PSObject.Properties.Name -contains 'geminiApiKey') { $key = [string]$secrets.geminiApiKey }
    if ([string]::IsNullOrWhiteSpace($key) -and ($secrets.PSObject.Properties.Name -contains 'GEMINI_API_KEY')) { $key = [string]$secrets.GEMINI_API_KEY }
    if ([string]::IsNullOrWhiteSpace($key)) { Write-Warning 'Gemini API key не найден'; return $null }
    $url = "https://generativelanguage.googleapis.com/v1beta/models/$($model):generateContent?key=$key"
    $body = @{
      contents = @(@{ parts = @(@{ text = $Prompt }) })
      generationConfig = @{ maxOutputTokens = 1024; temperature = 0.2 }
    }
    $json = $body | ConvertTo-Json -Depth 8
    $response = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec 30
    return [string]$response.candidates[0].content.parts[0].text
  } catch {
    Write-Warning ("Gemini post-mortem failed: " + $_.Exception.Message)
    return $null
  }
}

function Add-PostMortemLedgerEvent {
  param(
    [string]$CommitSha,
    [string]$RelativePath,
    [string]$FailureKind,
    [AllowNull()][object]$State,
    [string]$RepoRoot
  )
  $channel = 'main'
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'current_channel') -and -not [string]::IsNullOrWhiteSpace([string]$State.current_channel)) { $channel = [string]$State.current_channel }
    elseif ($State -and ($State.PSObject.Properties.Name -contains 'channel') -and -not [string]::IsNullOrWhiteSpace([string]$State.channel)) { $channel = [string]$State.channel }
  } catch {
    Write-PostMortemWarning ("channel resolve failed: " + $_.Exception.Message)
  }
  $meta = @{ sha=$CommitSha; path=$RelativePath; failure_kind=$FailureKind }
  try {
    if (Get-Command Add-SessionDecisionEvent -ErrorAction SilentlyContinue) {
      Add-SessionDecisionEvent -EventType 'post_mortem' -Meta $meta -Channel $channel
      return
    }
  } catch {
    Write-Warning ("Add-SessionDecisionEvent post_mortem failed: " + $_.Exception.Message)
  }
  try {
    $dir = Join-Path $RepoRoot 'decisions'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entry = [ordered]@{ ts=(Get-Date).ToString('o'); event='post_mortem'; channel=$channel; sha=$CommitSha; path=$RelativePath; failure_kind=$FailureKind }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText((Join-Path $dir 'session-ledger.jsonl'), $line + [Environment]::NewLine, $u8NoBom)
  } catch {
    Write-Warning ("post_mortem ledger append failed: " + $_.Exception.Message)
  }
}

function Invoke-RepairCommitPostMortem {
  param(
    [string]$CommitSha,
    [AllowNull()][object]$State,
    [string]$RepoRoot
  )
  if ([string]::IsNullOrWhiteSpace($CommitSha)) { return $null }
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-BridgeRoot }
  $fullSha = $CommitSha
  try {
    $resolved = ((& git -C $RepoRoot rev-parse $CommitSha 2>$null) | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) { $fullSha = ([string]$resolved).Trim() }
  } catch {
    Write-PostMortemWarning ("commit resolve failed: " + $_.Exception.Message)
  }
  $sha8 = if ($fullSha.Length -gt 8) { $fullSha.Substring(0, 8) } else { $fullSha }
  $decisionsDir = Join-Path $RepoRoot 'decisions'
  if (-not (Test-Path -LiteralPath $decisionsDir)) { New-Item -ItemType Directory -Path $decisionsDir -Force | Out-Null }
  $outPath = Join-Path $decisionsDir ("post-mortem-$sha8.md")
  if (Test-Path -LiteralPath $outPath) { return $outPath }

  $gitCtx = Get-PostMortemGitContext -CommitSha $fullSha -RepoRoot $RepoRoot
  $failure = Get-PostMortemFailureInfo -State $State
  $turns = Get-PostMortemTurnsTail -RepoRoot $RepoRoot -LastLines 15
  $prompt = @"
Ты ассистент по ретроспективному анализу автономных ИИ-агентов.

Тебе предоставлены данные после "repair-коммита" - коммита, исправляющего ошибку в ходе автономной задачи.

## Данные коммита ($fullSha)
### Stat
$($gitCtx.stat)

### Diff (фрагмент)
$($gitCtx.diff)

## Последняя зафиксированная ошибка задачи
kind: $($failure.kind)
ts: $($failure.ts)
text: $($failure.text)

## Последние turns агентов
$($turns.text)

## Задача
1. Определи вероятную КОРНЕВУЮ ПРИЧИНУ ошибки (1-2 предложения).
2. Опиши, что именно исправил коммит и насколько полно.
3. Дай 1-2 КОНКРЕТНЫЕ рекомендации для предотвращения подобного в будущем.
4. Укажи, нужно ли добавить идею в бэклог (yes/no + текст идеи если yes).

Формат ответа: markdown, 4 секции: ## Корневая причина / ## Что исправлено / ## Рекомендации / ## Идея в бэклог
"@
  $llmResponse = Invoke-GeminiPostMortem -Prompt $prompt
  if ([string]::IsNullOrWhiteSpace($llmResponse)) { return $null }
  $stamp = (Get-Date).ToString('o')
  $content = @"
# Post-mortem: $sha8
_Создан автоматически: ${stamp}_

$llmResponse

---
**Контекст**: task_last_failure.kind=$($failure.kind), turns=$($turns.count)
"@
  $u8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($outPath, $content, $u8NoBom)
  Add-PostMortemLedgerEvent -CommitSha $fullSha -RelativePath ("decisions/post-mortem-$sha8.md") -FailureKind ([string]$failure.kind) -State $State -RepoRoot $RepoRoot
  return $outPath
}

function Invoke-LegacyFailurePostMortem {
  param([string]$FailureType, [string]$Task = '', [string]$Context = '', [string]$Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Task)) { return }
  $shortTask = if ($Task.Length -gt 120) { $Task.Substring(0, 120) + '...' } else { $Task }
  $prompt = @"
Ты анализируешь сбой задачи в системе AI-агентов (мост Claude+Codex).
Тип сбоя: $FailureType
Задача: $shortTask
Контекст: $Context

Ответь ТОЛЬКО в таком формате (без пояснений):
УРОК: <одно-два предложения - почему упало и что делать иначе в будущем>
ИДЕЯ: <одна строка - конкретная идея в бэклог для устранения причины, или NONE>
НЕ_ПОВТОРЯТЬ: <КОНТЕКСТ: что и при каких условиях пробовали | ПРОВАЛ: что именно пошло не так> или NONE
"@
  $raw = try { Invoke-LLM -Purpose 'postmortem' -Prompt $prompt -TimeoutSec 45 -Temperature 0.3 } catch { $null }
  if ([string]::IsNullOrWhiteSpace($raw)) { return }
  $lessonM = [regex]::Match($raw, '(?im)^УРОК:\s*(.+)$')
  $ideaM = [regex]::Match($raw, '(?im)^ИДЕЯ:\s*(.+)$')
  $negativeM = [regex]::Match($raw, '(?im)^НЕ_ПОВТОРЯТЬ:\s*(.+)$')
  if ($lessonM.Success) {
    $lesson = $lessonM.Groups[1].Value.Trim()
    $memText = "[$FailureType] Задача: $shortTask - Урок: $lesson"
    try { Add-Memory -Channel $Channel -Text $memText -Tags @('lesson', $FailureType) -Source 'postmortem' -Importance 0.7 | Out-Null } catch { Write-PostMortemWarning ("legacy lesson memory failed: " + $_.Exception.Message) }
    try { Add-Message -From system -Text "Post-mortem ($FailureType): $lesson" -Kind event | Out-Null } catch { Write-PostMortemWarning ("legacy lesson message failed: " + $_.Exception.Message) }
  }
  if ($ideaM.Success) {
    $ideaText = $ideaM.Groups[1].Value.Trim()
    if ($ideaText -and $ideaText -notmatch '(?i)^none$') {
      try { Add-Idea -Text $ideaText -From 'postmortem' -Tags @('lesson','postmortem') -Status 'new' | Out-Null } catch { Write-PostMortemWarning ("legacy idea failed: " + $_.Exception.Message) }
    }
  }
  if ($negativeM.Success) {
    $negative = $negativeM.Groups[1].Value.Trim()
    if ($negative -and $negative -notmatch '(?i)^none$' -and $negative -match 'КОНТЕКСТ:' -and $negative -match 'ПРОВАЛ:') {
      $negative = ($negative -replace '[\x00-\x1F\x7F]', ' ' -replace '\s+', ' ').Trim()
      if ($negative.Length -gt 700) { $negative = $negative.Substring(0, 700).Trim() }
      try { Add-Memory -Channel $Channel -Text $negative -Tags @('skill-rejected', $FailureType) -Source 'postmortem-negative' -Importance 0.65 | Out-Null } catch { Write-PostMortemWarning ("legacy negative memory failed: " + $_.Exception.Message) }
    }
  }
  try { Add-FailureRecord -Class $FailureType -Task $shortTask -Context $Context -Channel $Channel } catch { Write-PostMortemWarning ("legacy failure record failed: " + $_.Exception.Message) }
}

function Invoke-PostMortem {
  param(
    [string]$CommitSha,
    [AllowNull()][object]$State,
    [string]$RepoRoot,
    [string]$FailureType,
    [string]$Task = '',
    [string]$Context = '',
    [string]$Channel = $null
  )
  if (-not [string]::IsNullOrWhiteSpace($CommitSha)) {
    return Invoke-RepairCommitPostMortem -CommitSha $CommitSha -State $State -RepoRoot $RepoRoot
  }
  return Invoke-LegacyFailurePostMortem -FailureType $FailureType -Task $Task -Context $Context -Channel $Channel
}
