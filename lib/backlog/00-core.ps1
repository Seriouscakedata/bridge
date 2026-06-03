# 00-core.ps1 -- Backlog core helpers, logging, dedup, capacity, stale sweep.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

# backlog.ps1 -- the bridge's self-improvement backlog (ideas/observations the agents
# raise themselves). Dot-sourced from common.ps1. Stored in backlog.jsonl at the root.
# Statuses: new (proposed) -> approved (user OK'd, eligible to auto-run) -> running -> done
#           also: rejected, failed, held, auto-dropped, auto-resolved.

$script:BacklogCuratorModel = 'gemini-2.5-flash-lite'

function Get-BacklogLibRoot {
  if ((Split-Path -Leaf $PSScriptRoot) -eq 'backlog') { return (Split-Path -Parent $PSScriptRoot) }
  return $PSScriptRoot
}

function Get-BacklogFallbackBridgeRoot {
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { return (Get-BridgeRoot) }
  return (Split-Path -Parent (Get-BacklogLibRoot))
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
  # 2026-05-27: critic-flagged fix. Add-Content -Encoding UTF8 on PS 5.1 writes
  # UTF-8 WITH BOM on first call (when file is created), breaking strict JSONL
  # parsers. ConvertTo-Json -Depth 10 on a hashtable Record is shallow-safe but
  # we reduce to Depth 6 (matches memory rule "Depth<=10 OK, prefer flat DTOs").
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'curator-decisions.jsonl'
    $line = $Record | ConvertTo-Json -Compress -Depth 6
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    Invoke-BacklogLocked ({ [System.IO.File]::AppendAllText($path, ($line + "`n"), $u8NoBom) }.GetNewClosure()) | Out-Null
  } catch {}
}

function Write-LastAddIdeaMarker {
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'last-add-idea.json'
    $json = ($Record | ConvertTo-Json -Compress -Depth 6) + "`n"
    Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path $path -Content $json }.GetNewClosure()) | Out-Null
  } catch {}
}

function Start-BacklogCuratorJob {
  param([string]$ItemId)
  if ([string]::IsNullOrWhiteSpace($ItemId)) { return $false }
  try {
    $root = Get-BacklogFallbackBridgeRoot
    # 2026-05-28 BUG-fix (backlog item c825502cba): the launcher previously
    # dot-sourced ONLY `lib/backlog.ps1`. But Invoke-BacklogCurator -> Get-Backlog
    # -> Get-BacklogPath, which needs Get-ChannelBacklogPath defined in
    # lib/channels.ps1 to resolve channels/<slug>/backlog.jsonl. Without
    # channels.ps1 loaded, Get-BacklogPath fell back to <root>/backlog.jsonl
    # (doesn't exist) -> Get-Backlog returned empty -> curator returned $null
    # silently -> EVERY new item since 2026-05-27 12:26 stayed at status=new
    # with no auto_curator verdict.
    # Fix: dot-source lib/common.ps1 (which itself dot-sources channels.ps1 +
    # backlog.ps1 + memory.ps1 + llm.ps1 in the right order). Pin the active
    # channel before invoking so Get-EffectiveChannel resolves correctly.
    $commonLib = Join-Path (Get-BacklogLibRoot) 'common.ps1'
    $log = Join-Path (Get-BacklogControlDir) 'curator.log'
    $launcherDir = Join-Path (Get-BacklogControlDir) 'curator-launchers'
    if (-not (Test-Path -LiteralPath $launcherDir)) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }
    $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
    $launcher = Join-Path $launcherDir ("curator_" + $stamp + ".ps1")
    # Capture the channel slug at launch time so the launcher pins to it
    # (matches the channel whose backlog the item lives in).
    $channelSlug = 'main'
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
        $channelSlug = [string](Get-EffectiveChannel)
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($channelSlug)) { $channelSlug = 'main' }
    $launcherBody = @"
`$ErrorActionPreference = 'Continue'
try {
  . '$($commonLib.Replace("'", "''"))'
  if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) {
    Set-PinnedChannel '$($channelSlug.Replace("'", "''"))'
  }
  `$result = Invoke-BacklogCurator -ItemId '$($ItemId.Replace("'", "''"))' 2>`$null
  `$line = (Get-Date).ToString('o') + " | item=$($ItemId.Replace("'", "''")) | channel=$($channelSlug.Replace("'", "''")) | result=" + (`$result | ConvertTo-Json -Compress -Depth 4) + "`n"
  [System.IO.File]::AppendAllText('$($log.Replace("'", "''"))', `$line, (New-Object System.Text.UTF8Encoding(`$false)))
} catch {
  `$err = (Get-Date).ToString('o') + " | item=$($ItemId.Replace("'", "''")) | error=" + `$_.Exception.Message + "`n"
  [System.IO.File]::AppendAllText('$($log.Replace("'", "''"))', `$err, (New-Object System.Text.UTF8Encoding(`$false)))
}
"@
    $u8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($launcher, $launcherBody, $u8Bom)
    Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
      Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher) -WorkingDirectory $root -WindowStyle Hidden | Out-Null
    }
    return $true
  } catch {
    Write-BacklogJsonLine ([ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      action = 'judge-launch-error'
      item_id = $ItemId
      error = [string]$_.Exception.Message
    })
    return $false
  }
}

function Ensure-BacklogMemoryLoaded {
  if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) {
    $p = Join-Path (Get-BacklogLibRoot) 'memory.ps1'
    if (Test-Path -LiteralPath $p) { . $p }
  }
}

function Ensure-BacklogLLMLoaded {
  Ensure-BacklogMemoryLoaded
  if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
    $p = Join-Path (Get-BacklogLibRoot) 'llm.ps1'
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
  param([string[]]$GitArgs)
  try {
    if ($null -eq $GitArgs -or $GitArgs.Count -eq 0) { return '' }
    $root = Get-BacklogFallbackBridgeRoot
    $out = & git -C $root @GitArgs 2>$null
    if ($null -eq $out) { return '' }
    return (($out | Out-String).Trim())
  } catch { return '' }
}

function Get-BacklogCurrentSha {
  $sha = Get-BacklogGitOutput -GitArgs @('rev-parse', 'HEAD')
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
