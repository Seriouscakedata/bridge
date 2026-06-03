# 30-claim.ps1 -- Relevance checks, runnable selection, and operator batch insertion.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

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
    # 2026-05-31 (Foundation #4 scale): added web/project extensions (ts/tsx/jsx/prisma/sql/scss/vue...)
    # and project dirs (src/app/components/pages/api/prisma...) so PROJECT-channel tasks get their
    # touched files extracted -> per-file conflict groups -> independent tasks batch in PARALLEL.
    # Bridge extensions/dirs preserved, so bridge classification is unchanged.
    '(?i)(?:[\w.-]+[\\/])*[\w.-]+\.(?:jsonl|json|psm1|ps1|html|css|scss|sass|less|js|jsx|ts|tsx|mjs|cjs|vue|svelte|prisma|sql|yaml|yml|md|txt|env)',
    '(?i)(?:lib|web|memory|control|tools|docs|channels|src|app|components|pages|api|prisma|config|content|public|styles|server|hooks|utils)[\\/][\w.\\/:-]*'
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
    $gitLog = Get-BacklogGitOutput -GitArgs $logArgs
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

Сделано ли это уже одним из коммитов?

Жёсткие правила:
- Коммит считается реализующим item ТОЛЬКО если в commit message явно упоминается конкретный элемент из item.text: имя функции, файла, класса, эндпоинта, точная фича или чёткая концепция.
- Recency сама по себе НЕ сигнал. Самый свежий или последний коммит нельзя считать доказательством выполнения.
- Если есть только пересечение общих слов вроде "backlog", "driver", "fix", "task", "agent", "bridge" без специфики item.text — верни done=false.
- При сомнении — done=false.
- Если done=true, sha должен быть SHA конкретного коммита из списка выше, а reason должен быть не короче 30 символов и цитировать связанную фразу из commit message.

Верни СТРОГО JSON:
{"done": true|false, "sha": "<sha если done>" или null, "reason": "фраза >=30 символов с цитатой commit message"}
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
    if ($done) {
      if ([string]::IsNullOrWhiteSpace($sha) -or -not $lowerLog.Contains(([string]$sha).ToLowerInvariant()) -or $reason.Length -lt 30) {
        return [pscustomobject]@{ done = $false; sha = $null; reason = 'freshness LLM returned weak done evidence' }
      }
    }
    return [pscustomobject]@{ done = $done; sha = $sha; reason = $reason }
  } catch {
    return $failOpen
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

function Get-NextApprovedIdea {
  # Next approved item, checking whether recent commits already resolved stale work.
  # 2026-05-28: sort key chain is severity rank (critical=0 / warning=1 / info=2 / none=3)
  # first, then score desc, then ts asc. So audit criticals get pulled before warnings,
  # warnings before info, info before plain ideas.
  $skipped = New-Object 'System.Collections.Generic.List[string]'
  while ($true) {
    # SYSTEMIC GUARD 2026-05-31: even an APPROVED control-plane task does not auto-run unless the
    # operator delegated it (tag 'operator'). Auto-approved deep-audit self-edits deadlocked the bridge.
    $items = @(Get-Backlog | Where-Object { ([string]$_.status -eq 'approved') -and ((@($_.tags) -contains 'operator') -or -not (Test-IdeaTouchesControlPlane -Idea $_)) } |
      Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                  @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                  @{Expression={[string]$_.ts}})
    try {
      if (-not (Test-ProjectScopedApprovedBacklogAllowed)) {
        $items = @($items | Where-Object {
          -not ($_.PSObject.Properties.Name -contains 'scope') -or ([string]$_.scope -ne 'project')
        })
      }
    } catch {}
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
    $cfg = Get-Content (Join-Path (Get-BacklogFallbackBridgeRoot) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'backlog' -and $cfg.backlog) {
      try { $useLLMPriority = [bool]$cfg.backlog.useLLMPriority } catch {}
    }
  } catch {}
  if ($useLLMPriority -or $env:BRIDGE_LLM_PRIORITY -eq '1') {
    $priorityChannel = [string]$env:BRIDGE_CHANNEL
    if ([string]::IsNullOrWhiteSpace($priorityChannel)) { $priorityChannel = 'main' }
    try { Invoke-BacklogLLMPrioritize -MaxItems 15 -Channel $priorityChannel | Out-Null } catch {}
  }
  # 2026-05-28: sort key chain is (1) status approved-before-new, (2) severity rank
  # critical=0 / warning=1 / info=2 / none=3, (3) score desc, (4) ts asc.
  # Audit criticals always outrank warnings, warnings outrank info, info outranks plain ideas.
  $items = @(Get-Backlog | Where-Object {
      $st = [string]$_.status
      # SYSTEMIC GUARD 2026-05-31: never AUTO-claim a task that edits the bridge's own control plane
      # (supervisor/watchdog/circuit-breaker/...). Those repeatedly deadlocked the bridge. Only the
      # OPERATOR (tag 'operator') may delegate control-plane work; auto-generated ones are skipped.
      if ((Test-IdeaTouchesControlPlane -Idea $_) -and -not (@($_.tags) -contains 'operator')) { $false }
      elseif ($st -eq 'approved') { $true }
      elseif ($IncludeNew -and $st -eq 'new' -and -not (Test-IdeaExternal $_)) { $true }
      else { $false }
    } |
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
