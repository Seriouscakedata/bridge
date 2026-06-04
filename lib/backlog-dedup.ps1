# backlog-dedup.ps1 -- idea deduplication, learning, relevance, and queue hygiene helpers.
#region Idea deduplication, learning, relevance, and queue hygiene
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
    $dropDays = 30
    try { $dropDays = [int](Get-AutonomySettings).dedupDroppedDays } catch {}
    $dropCut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($dropDays))
    $dropNoise = '(?i)(mojibake|cleanup|a/b[- ]?test|rerun|pre-[a-z0-9]|encoding fix|scenario|\btest\b|времен)'
    $dirty = $false
    $bestId = $null
    $bestSim = 0.0
    $bestDropId = $null
    $bestDropSim = 0.0
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
      # SUBSTANTIVE recent curator rejections — tracked separately so we refuse to re-propose junk
      # the curator already refused. Housekeeping/manual/noise drops do NOT count (the idea was valid,
      # only the encoding/test-run was bad), so they never block a legitimate re-proposal.
      $isDrop = $false
      if (-not $eligible -and ($status -in @('auto-dropped','rejected')) -and $dropDays -gt 0) {
        $ac = $item.auto_curator
        if ($ac -and -not [string]::IsNullOrWhiteSpace([string]$ac.model) -and ([string]$ac.model -ne 'manual') -and (([string]$ac.reason) -notmatch $dropNoise)) {
          try { if ([datetime]::Parse([string]$item.ts).ToUniversalTime() -ge $dropCut) { $isDrop = $true } } catch {}
        }
      }
      if (-not $eligible -and -not $isDrop) { continue }
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
      if ($isDrop) {
        if ($sim -gt $bestDropSim) { $bestDropSim = $sim; $bestDropId = [string]$item.id }
      } else {
        if ($sim -gt $bestSim) { $bestSim = $sim; $bestId = [string]$item.id }
        if ($sim -ge 0.70 -and $sim -lt 0.88) { [void]$similarIds.Add([string]$item.id) }
      }
    }
    if ($dirty) { Save-Backlog $items }

    if ($bestId -and $bestSim -ge 0.88) {
      return [pscustomobject]@{ action = 'dedup'; matched_id = $bestId; similarity = $bestSim; similar_to = @() }
    }
    if ($bestDropId -and $bestDropSim -ge 0.85) {
      return [pscustomobject]@{ action = 'rejected-recently'; matched_id = $bestDropId; similarity = $bestDropSim; similar_to = @() }
    }
    if ($similarIds.Count -gt 0) {
      return [pscustomobject]@{ action = 'similar'; matched_id = $bestId; similarity = $bestSim; similar_to = @($similarIds.ToArray()) }
    }
    return $ok
  } catch {
    return $ok
  }
}

function Get-IdeaOutcomeStats {
  # Learning-loop aggregate: distills the FATE of past ideas so a generator (Architect/reflect)
  # can calibrate -- propose more of what survives, less of what the curator rejects. Read-only.
  # Sources: backlog (status/from/auto_curator/self_exec_commit) + metrics verdicts. Housekeeping
  # drops (manual cleanup, mojibake, A/B reruns) are filtered out so only SUBSTANTIVE curator
  # rejections inform the generator. Returns a pscustomobject; safe on empty/cold data.
  param([int]$RecentWinDays = 30, [int]$MaxDropReasons = 6, [int]$MaxWins = 6)
  $bl = @(Get-Backlog)
  $doneSt = @('done','auto-resolved')
  $dropSt = @('auto-dropped','rejected')
  $noise  = '(?i)(mojibake|cleanup|a/b[- ]?test|rerun|pre-[a-z0-9]|encoding fix|scenario|\btest\b|времен)'
  $moji   = '[�]|[À-ÿ]{3,}'   # broken-encoding artifacts (pre-7163c88 UTF-8/CP1251 mojibake)

  $perSource = [ordered]@{}
  foreach ($g in ($bl | Group-Object { [string]$_.from })) {
    $grp = $g.Group
    $done = @($grp | Where-Object { $doneSt -contains [string]$_.status }).Count
    $drop = @($grp | Where-Object { $dropSt -contains [string]$_.status }).Count
    $perSource[[string]$g.Name] = [pscustomobject]@{
      total = $g.Count; done = $done; dropped = $drop
      drop_rate = if ($g.Count -gt 0) { [Math]::Round($drop / [double]$g.Count, 2) } else { 0 }
    }
  }

  $reasons = New-Object 'System.Collections.Generic.List[string]'
  foreach ($i in $bl) {
    if ($dropSt -notcontains [string]$i.status) { continue }
    $ac = $i.auto_curator
    if (-not $ac) { continue }
    $model = [string]$ac.model
    if ($model -eq 'manual' -or [string]::IsNullOrWhiteSpace($model)) { continue }   # housekeeping, not a judgment
    $r = ([string]$ac.reason).Trim()
    if ([string]::IsNullOrWhiteSpace($r) -or ($r -match $noise) -or ($r -match $moji)) { continue }
    $r = ($r -replace '\s*\(low confidence\)\s*$','').Trim()
    if ($r.Length -gt 90) { $r = $r.Substring(0,90) + '…' }
    [void]$reasons.Add($r)
  }
  $topDrop = @($reasons | Group-Object | Sort-Object Count -Descending | Select-Object -First $MaxDropReasons |
              ForEach-Object { [pscustomobject]@{ reason = $_.Name; count = $_.Count } })

  $wins = New-Object 'System.Collections.Generic.List[string]'
  foreach ($i in ($bl | Where-Object { [string]$_.status -eq 'done' } | Sort-Object { [string]$_.ts } -Descending)) {
    $t = ([string]$i.text -replace '\s+',' ').Trim()
    if ($t -match $noise -or $t -match $moji) { continue }
    if ($t.Length -gt 90) { $t = $t.Substring(0,90) + '…' }
    [void]$wins.Add($t)
    if ($wins.Count -ge $MaxWins) { break }
  }

  $worked = 0; $worse = 0
  try {
    $sc = @{}
    foreach ($i in $bl) { $c = [string]$i.self_exec_commit; if ($c) { $sc[$c] = $true; if ($c.Length -ge 7) { $sc[$c.Substring(0,7)] = $true } } }
    if ($sc.Count -gt 0 -and (Get-Command Read-MetricsJsonl -ErrorAction SilentlyContinue)) {
      foreach ($r in @(Read-MetricsJsonl)) {
        if ([string]$r.type -ne 'verdict') { continue }
        $vc = [string]$r.commit; if (-not $vc) { continue }
        if (-not ($sc.ContainsKey($vc) -or ($vc.Length -ge 7 -and $sc.ContainsKey($vc.Substring(0,7))))) { continue }
        if ([string]$r.verdict -eq 'worked') { $worked++ } elseif ([string]$r.verdict -eq 'worse') { $worse++ }
      }
    }
  } catch {}

  return [pscustomobject]@{
    perSource      = $perSource
    topDropReasons = $topDrop
    recentWins     = @($wins.ToArray())
    selfExec       = [pscustomobject]@{ worked = $worked; worse = $worse }
  }
}

function Format-IdeaLearningGuidance {
  # Render Get-IdeaOutcomeStats into a compact prompt block so a generator LEARNS from the fate of
  # past ideas. Returns '' when there's nothing useful yet (cold start) so callers can skip it.
  param([int]$RecentWinDays = 30, [int]$MinSourceVolume = 3)
  $st = $null
  try { $st = Get-IdeaOutcomeStats -RecentWinDays $RecentWinDays } catch { return '' }
  if (-not $st) { return '' }
  $sb = New-Object System.Text.StringBuilder
  $had = $false
  $srcLines = @()
  foreach ($k in $st.perSource.Keys) {
    $v = $st.perSource[$k]
    if ([int]$v.total -lt $MinSourceVolume) { continue }
    $srcLines += ("- {0}: предложено {1}, done {2}, отклонено {3} (drop-rate {4})" -f $k, $v.total, $v.done, $v.dropped, $v.drop_rate)
  }
  if ($srcLines.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Источники идей по исходам (высокий drop-rate = источник генерит много мусора):')
    foreach ($l in $srcLines) { [void]$sb.AppendLine($l) }
  }
  if ($st.topDropReasons.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Частые СОДЕРЖАТЕЛЬНЫЕ причины отказа куратора (НЕ предлагай идеи с такими свойствами):')
    foreach ($d in $st.topDropReasons) { [void]$sb.AppendLine(("- «{0}» ×{1}" -f $d.reason, $d.count)) }
  }
  if ($st.recentWins.Count -gt 0) {
    $had = $true
    [void]$sb.AppendLine('Недавно принятые и сделанные идеи (вот формат/масштаб, который заходит):')
    foreach ($w in $st.recentWins) { [void]$sb.AppendLine("- $w") }
  }
  if (([int]$st.selfExec.worked + [int]$st.selfExec.worse) -gt 0) {
    $had = $true
    [void]$sb.AppendLine(("Авто-исполненные идеи по 24ч-вердикту: сработали {0}, ухудшили {1}." -f $st.selfExec.worked, $st.selfExec.worse))
  }
  if (-not $had) { return '' }
  return ('=== СУДЬБА ПРОШЛЫХ ИДЕЙ (учись на ней) ===' + "`n" + $sb.ToString().Trim())
}

function Get-OpenIdeaCount {
  # Count of ideas still "in flight" — proposed but not yet resolved/dropped/archived. Drives the
  # WIP budget so proactive generators don't pile on while the queue is already full.
  return @(Get-Backlog | Where-Object { [string]$_.status -in @('new','approved','running','inprogress') }).Count
}

function Test-BacklogHasCapacity {
  # WIP gate for PROACTIVE generators (reflect/architect). $true if open ideas are under maxOpenIdeas
  # (so the generator may add more); $false means "drain the queue first". Reactive generators
  # (deep-audit filing real bugs) must NOT call this. Fail-open on any error.
  $cap = 12
  try { $cap = [int](Get-AutonomySettings).maxOpenIdeas } catch {}
  if ($cap -le 0) { return $true }   # 0 / unset = unlimited
  try { return ((Get-OpenIdeaCount) -lt $cap) } catch { return $true }
}

function Invoke-BacklogStaleSweep {
  # Anti-junk hygiene: archive 'new' ideas nobody ever claimed. A 'new' idea older than ideaStaleDays
  # (not approved/running, and not external/radar — those await manual review) -> status 'auto-stale'.
  # Caller throttles cadence. Returns count archived.
  param([int]$MaxAgeDays = 0)
  $days = $MaxAgeDays
  if ($days -le 0) { try { $days = [int](Get-AutonomySettings).ideaStaleDays } catch { $days = 14 } }
  if ($days -le 0) { return 0 }
  $cut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($days))
  $items = @(Get-Backlog)
  $n = 0
  foreach ($i in $items) {
    if ([string]$i.status -ne 'new') { continue }
    try { if (Test-IdeaExternal $i) { continue } } catch {}   # radar/web await human review by design
    $ts = $null
    try { $ts = [datetime]::Parse([string]$i.ts).ToUniversalTime() } catch { continue }
    if ($ts -ge $cut) { continue }
    $i | Add-Member -NotePropertyName status   -NotePropertyValue 'auto-stale' -Force
    $i | Add-Member -NotePropertyName stale_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $n++
  }
  if ($n -gt 0) {
    Save-Backlog $items
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='stale-sweep'; archived=$n; older_than_days=$days }) } catch {}
  }
  return $n
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

function Get-BacklogForbiddenMentionPattern {
  return "(?i)(?:не\s+трогать|не\s+трогай|do\s+not\s+touch|don't\s+touch|forbidden|запрещено)"
}

function Get-BacklogTextOutsideForbiddenContexts {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $rx = Get-BacklogForbiddenMentionPattern
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in [regex]::Split([string]$Text, "\r?\n")) {
    $m = [regex]::Match([string]$line, $rx)
    if ($m.Success) {
      $safe = ([string]$line).Substring(0, $m.Index)
      if (-not [string]::IsNullOrWhiteSpace($safe)) { [void]$out.Add($safe) }
      continue
    }
    [void]$out.Add([string]$line)
  }
  return (($out.ToArray()) -join "`n")
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

#endregion Idea deduplication, learning, relevance, and queue hygiene