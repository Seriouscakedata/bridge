# backlog.ps1 -- the bridge's self-improvement backlog (ideas/observations the agents
# raise themselves). Dot-sourced from common.ps1. Stored in backlog.jsonl at the root.
# Statuses: new (proposed) -> approved (user OK'd, eligible to auto-run) -> running -> done
#           also: rejected, failed, held, auto-dropped, auto-resolved.

$script:BacklogCuratorModel = 'gemini-2.5-flash-lite'

function Get-BacklogFallbackBridgeRoot {
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { return (Get-BridgeRoot) }
  return (Split-Path -Parent $PSScriptRoot)
}

function Invoke-BacklogLocked {
  param([scriptblock]$ScriptBlock)
  if (Get-Command Use-BridgeLock -ErrorAction SilentlyContinue) { return (Use-BridgeLock $ScriptBlock) }
  return (& $ScriptBlock)
}

function Write-BacklogAtomicFile {
  param([string]$Path, [string]$Content)
  if (Get-Command Write-AtomicFile -ErrorAction SilentlyContinue) { Write-AtomicFile -Path $Path -Content $Content; return }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
  else { Move-Item -LiteralPath $tmp -Destination $Path }
}

function Get-BacklogControlDir {
  Join-Path (Get-BacklogFallbackBridgeRoot) 'control'
}

function Write-BacklogJsonLine {
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'curator-decisions.jsonl'
    $line = $Record | ConvertTo-Json -Compress -Depth 10
    Invoke-BacklogLocked ({ Add-Content -LiteralPath $path -Value $line -Encoding UTF8 }.GetNewClosure()) | Out-Null
  } catch {}
}

function Write-LastAddIdeaMarker {
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'last-add-idea.json'
    $json = ($Record | ConvertTo-Json -Compress -Depth 10) + "`n"
    Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path $path -Content $json }.GetNewClosure()) | Out-Null
  } catch {}
}

function Ensure-BacklogMemoryLoaded {
  if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) {
    $p = Join-Path $PSScriptRoot 'memory.ps1'
    if (Test-Path -LiteralPath $p) { . $p }
  }
}

function Ensure-BacklogLLMLoaded {
  Ensure-BacklogMemoryLoaded
  if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
    $p = Join-Path $PSScriptRoot 'llm.ps1'
    if (Test-Path -LiteralPath $p) { . $p }
  }
}

function ConvertFrom-BacklogStrictJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ([string]$Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  $mt = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mt.Success) { return $null }
  try { return ($mt.Value | ConvertFrom-Json) } catch { return $null }
}

function Get-BacklogGitOutput {
  param([string[]]$Args)
  try {
    $root = Get-BacklogFallbackBridgeRoot
    $out = & git -C $root @Args 2>$null
    if ($null -eq $out) { return '' }
    return (($out | Out-String).Trim())
  } catch { return '' }
}

function Get-BacklogCurrentSha {
  $sha = Get-BacklogGitOutput -Args @('rev-parse', 'HEAD')
  return ([string]$sha).Trim()
}

function Get-BacklogStatusSummary {
  try {
    $p = Join-Path (Get-BacklogControlDir) 'status.json'
    if (-not (Test-Path -LiteralPath $p)) { return 'status.json missing' }
    $raw = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
    if ($raw.Length -gt 1200) { $raw = $raw.Substring(0, 1200) + '...' }
    return $raw
  } catch { return 'status unavailable' }
}

function Get-BacklogPath {
  if (Get-Command Get-ChannelBacklogPath -ErrorAction SilentlyContinue) { return (Get-ChannelBacklogPath) }
  return (Join-Path (Get-BacklogFallbackBridgeRoot) 'backlog.jsonl')
}

function Test-IdeaShouldKeep {
  param([string]$Text)
  $ok = [pscustomobject]@{ action = 'ok'; matched_id = $null; similarity = 0.0; similar_to = @() }
  try {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $ok }
    Ensure-BacklogMemoryLoaded
    if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) { return $ok }
    if (-not (Get-Command Get-CosineSimilarity -ErrorAction SilentlyContinue)) { return $ok }

    $qvec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_QUERY'
    if (-not $qvec) { return $ok }

    $items = @(Get-Backlog)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-30)
    $dirty = $false
    $bestId = $null
    $bestSim = 0.0
    $similarIds = New-Object 'System.Collections.Generic.List[string]'

    foreach ($item in $items) {
      $status = [string]$item.status
      $eligible = ($status -in @('new', 'approved', 'held'))
      if (-not $eligible -and $status -eq 'done') {
        try {
          $its = [datetime]::Parse([string]$item.ts).ToUniversalTime()
          $eligible = ($its -ge $cutoff)
        } catch { $eligible = $false }
      }
      if (-not $eligible) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$item.text)) { continue }

      $ivec = $null
      try {
        if ($item.PSObject.Properties.Name -contains 'embedding' -and $item.embedding) { $ivec = @($item.embedding) }
      } catch {}
      if (-not $ivec -or $ivec.Count -eq 0) {
        $ivec = Get-Embedding -Text ([string]$item.text) -TaskType 'RETRIEVAL_DOCUMENT'
        if (-not $ivec) { continue }
        $item | Add-Member -NotePropertyName embedding -NotePropertyValue (@($ivec)) -Force
        $dirty = $true
      }
      $sim = [double](Get-CosineSimilarity -A $qvec -B $ivec)
      if ($sim -gt $bestSim) {
        $bestSim = $sim
        $bestId = [string]$item.id
      }
      if ($sim -ge 0.70 -and $sim -lt 0.88) { [void]$similarIds.Add([string]$item.id) }
    }
    if ($dirty) { Save-Backlog $items }

    if ($bestId -and $bestSim -ge 0.88) {
      return [pscustomobject]@{ action = 'dedup'; matched_id = $bestId; similarity = $bestSim; similar_to = @() }
    }
    if ($similarIds.Count -gt 0) {
      return [pscustomobject]@{ action = 'similar'; matched_id = $bestId; similarity = $bestSim; similar_to = @($similarIds.ToArray()) }
    }
    return $ok
  } catch {
    return $ok
  }
}

function Add-Idea {
  # Append a backlog idea. Returns a string id. On dedup returns the matched existing id.
  param(
    [string]$Text,
    [string]$From = 'agent',
    [string[]]$Tags = @(),
    [string]$Status = 'new',
    [double]$Score = 0.0,
    [switch]$SkipCurator
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $now = (Get-Date).ToUniversalTime().ToString('o')

  $keep = [pscustomobject]@{ action = 'ok'; matched_id = $null; similarity = 0.0; similar_to = @() }
  if (-not $SkipCurator) {
    try { $keep = Test-IdeaShouldKeep -Text $Text } catch {}
  }

  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'dedup' -and -not [string]::IsNullOrWhiteSpace([string]$keep.matched_id)) {
    $items = @(Get-Backlog)
    $matched = $null
    foreach ($i in $items) {
      if ([string]$i.id -eq [string]$keep.matched_id) { $matched = $i; break }
    }
    if ($matched) {
      $matched | Add-Member -NotePropertyName ts -NotePropertyValue $now -Force
      $count = 0
      try {
        if ($matched.PSObject.Properties.Name -contains 'seen_again_count' -and $null -ne $matched.seen_again_count) {
          $count = [int]$matched.seen_again_count
        }
      } catch { $count = 0 }
      $matched | Add-Member -NotePropertyName seen_again_count -NotePropertyValue ($count + 1) -Force
      Save-Backlog $items
    }
    Write-BacklogJsonLine ([ordered]@{
      ts = $now; action = 'dedup'; new_text = [string]$Text; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity
    })
    Write-LastAddIdeaMarker ([ordered]@{
      ts = $now; deduped = $true; id = [string]$keep.matched_id; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity
    })
    return [string]$keep.matched_id
  }

  $rec = [ordered]@{
    id       = [guid]::NewGuid().ToString('N')
    ts       = $now
    from     = $From
    status   = $Status
    tags     = @($Tags)
    attempts = 0
    score    = $Score
    text     = [string]$Text
  }
  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'similar') {
    $rec.similar_to = @($keep.similar_to)
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 10)
  Invoke-BacklogLocked ({ Add-Content -LiteralPath (Get-BacklogPath) -Value $line -Encoding UTF8 }.GetNewClosure()) | Out-Null

  $judge = $null
  if (-not $SkipCurator) {
    try { $judge = Invoke-BacklogCurator -ItemId ([string]$rec.id) } catch {}
  }
  Write-LastAddIdeaMarker ([ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    deduped = $false
    id = [string]$rec.id
    similar_to = @($rec.similar_to)
    curator = $judge
  })
  return [string]$rec.id
}

function Get-Backlog {
  $p = Get-BacklogPath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $i = $line | ConvertFrom-Json } catch { continue }
    [void]$out.Add($i)
  }
  return @($out.ToArray())
}

function Save-Backlog {
  param($Items)
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path (Get-BacklogPath) -Content $content }.GetNewClosure()) | Out-Null
}

function Set-Idea {
  # Edit a backlog item. Pass $null to leave a field unchanged.
  param([string]$Id, $Status = $null, $Text = $null, $IncrementAttempts = $false)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $found = $true
    if ($null -ne $Status) { $i | Add-Member -NotePropertyName status -NotePropertyValue ([string]$Status) -Force }
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

    $gitLog = Get-BacklogGitOutput -Args @('log', '-5', '--oneline')
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

function Get-BacklogIdeaKeywords {
  param([string]$Text)
  $stop = @{
    'the'=$true; 'a'=$true; 'of'=$true;
    'and'=$true; 'with'=$true; 'this'=$true; 'that'=$true; 'from'=$true;
  }
  $counts = @{}
  foreach ($m in [regex]::Matches([string]$Text, '[\p{L}\p{Nd}_-]{4,}')) {
    $w = $m.Value.ToLowerInvariant()
    if ($stop.ContainsKey($w)) { continue }
    if ($counts.ContainsKey($w)) { $counts[$w] = [int]$counts[$w] + 1 } else { $counts[$w] = 1 }
  }
  return @($counts.GetEnumerator() | Sort-Object -Property @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false} | Select-Object -First 10 | ForEach-Object { [string]$_.Key })
}

function Get-BacklogMentionedFiles {
  param([string]$Text)
  $set = @{}
  $patterns = @(
    '(?i)(?:[\w.-]+[\\/])*[\w.-]+\.(?:ps1|psm1|html|js|css|json|jsonl|md|yml|yaml|txt)',
    '(?i)(?:lib|web|memory|control|tools|docs|channels)[\\/][\w.\\/:-]*'
  )
  foreach ($pat in $patterns) {
    foreach ($m in [regex]::Matches([string]$Text, $pat)) {
      $v = $m.Value.Replace('\', '/').Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($v)) { $set[$v] = $true }
    }
  }
  return @($set.Keys)
}

function Test-IdeaStillRelevant {
  param([string]$ItemId)
  $failOpen = [pscustomobject]@{ done = $false; sha = $null; reason = 'check-failed' }
  try {
    if ([string]::IsNullOrWhiteSpace($ItemId)) { return $failOpen }
    $item = Get-IdeaById -Id $ItemId
    if (-not $item) { return [pscustomobject]@{ done = $false; sha = $null; reason = 'not-found' } }

    $logArgs = @()
    $approvedSha = ''
    try {
      if ($item.PSObject.Properties.Name -contains 'approved_at_sha') { $approvedSha = [string]$item.approved_at_sha }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($approvedSha)) {
      $logArgs = @('log', "$approvedSha..HEAD", '--oneline', '-50')
    } else {
      $since = [string]$item.ts
      if ([string]::IsNullOrWhiteSpace($since)) { $since = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o') }
      $logArgs = @('log', "--since=$since", '--oneline', '-50')
    }
    $gitLog = Get-BacklogGitOutput -Args $logArgs
    if ([string]::IsNullOrWhiteSpace($gitLog)) {
      return [pscustomobject]@{ done = $false; sha = $null; reason = 'no-commits' }
    }

    $lowerLog = $gitLog.ToLowerInvariant()
    $keywords = @(Get-BacklogIdeaKeywords -Text ([string]$item.text))
    $keywordHits = 0
    foreach ($kw in $keywords) {
      if ($lowerLog.Contains($kw.ToLowerInvariant())) { $keywordHits++ }
    }
    $files = @(Get-BacklogMentionedFiles -Text ([string]$item.text))
    $fileHit = $false
    foreach ($f in $files) {
      if (-not [string]::IsNullOrWhiteSpace($f) -and $lowerLog.Contains($f.ToLowerInvariant())) { $fileHit = $true; break }
      $leaf = Split-Path -Leaf $f
      if (-not [string]::IsNullOrWhiteSpace($leaf) -and $lowerLog.Contains($leaf.ToLowerInvariant())) { $fileHit = $true; break }
    }
    if ($keywordHits -lt 2 -and -not $fileHit) {
      return [pscustomobject]@{ done = $false; sha = $null; reason = 'no-quick-signal' }
    }

    Ensure-BacklogLLMLoaded
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) { return $failOpen }
    $prompt = @"
Item беклога: $([string]$item.text)
Commits с момента создания/одобрения:
$gitLog

Сделано ли это уже одним из коммитов? Верни СТРОГО JSON:
{"done": true|false, "sha": "<sha если done>" или null, "reason": "короткая фраза"}
"@
    $raw = Invoke-LLM -Purpose 'backlog-freshness' -Model $script:BacklogCuratorModel -Prompt $prompt -TimeoutSec 60 -Temperature 0.1
    $obj = ConvertFrom-BacklogStrictJson -Text ([string]$raw)
    if (-not $obj) { return $failOpen }
    $done = $false
    try { $done = [bool]$obj.done } catch { $done = $false }
    $sha = $null
    if ($obj.PSObject.Properties.Name -contains 'sha' -and $null -ne $obj.sha) { $sha = [string]$obj.sha }
    $reason = ([string]$obj.reason).Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = if ($done) { 'done' } else { 'not done' } }
    return [pscustomobject]@{ done = $done; sha = $sha; reason = $reason }
  } catch {
    return $failOpen
  }
}

function Get-NextApprovedIdea {
  # Next approved item, checking whether recent commits already resolved stale work.
  $skipped = New-Object 'System.Collections.Generic.List[string]'
  while ($true) {
    $items = @(Get-Backlog | Where-Object { [string]$_.status -eq 'approved' } |
      Sort-Object @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
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
        action = 'freshness-auto-resolved'
        item_id = [string]$candidate.id
        sha = $result.sha
        reason = [string]$result.reason
      })
      if ($skipped.Count -ge 3) {
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'freshness-skip-limit'
          skipped_ids = @($skipped.ToArray())
        })
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
  $items = @(Get-Backlog | Where-Object {
      $st = [string]$_.status
      if ($st -eq 'approved') { $true }
      elseif ($IncludeNew -and $st -eq 'new' -and -not (Test-IdeaExternal $_)) { $true }
      else { $false }
    } |
    Sort-Object @{Expression={ if ([string]$_.status -eq 'approved') {0} else {1} }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}})
  if ($items.Count -gt 0) { return $items[0] }
  return $null
}

function Get-IdeaById {
  param([string]$Id)
  foreach ($i in @(Get-Backlog)) { if ([string]$i.id -eq $Id) { return $i } }
  return $null
}
