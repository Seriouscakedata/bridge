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
    $commonLib = Join-Path $PSScriptRoot 'common.ps1'
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

function Resolve-BacklogPathValue {
  if (Get-Command Get-ChannelBacklogPath -ErrorAction SilentlyContinue) { return (Get-ChannelBacklogPath) }
  return (Join-Path (Get-BacklogFallbackBridgeRoot) 'backlog.jsonl')
}

function Ensure-BacklogPathFunction {
  # 2026-06-04 registry_drift fix: some inline/dynamic callers were keeping
  # Add-Idea / Invoke-BacklogCurator loaded while Get-BacklogPath had fallen out
  # of scope. Re-register the helper into script scope on demand so backlog
  # append/read/save paths stay callable even in a narrowed execution scope.
  if (Get-Command Get-BacklogPath -ErrorAction SilentlyContinue) { return }
  function script:Get-BacklogPath {
    return (Resolve-BacklogPathValue)
  }
}

function Get-BacklogPath {
  return (Resolve-BacklogPathValue)
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

function Get-BacklogPackObjectValue {
  param($Obj, [string]$Name, $Default = $null)
  try {
    if ($Obj -and ($Obj.PSObject.Properties.Name -contains $Name) -and $null -ne $Obj.PSObject.Properties[$Name].Value) {
      return $Obj.PSObject.Properties[$Name].Value
    }
  } catch {}
  return $Default
}

function ConvertTo-BacklogPackBool {
  param($Value, [bool]$Default = $true)
  try {
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (@('true','1','yes','on','enabled') -contains $s) { return $true }
    if (@('false','0','no','off','disabled') -contains $s) { return $false }
  } catch {}
  return $Default
}

function ConvertTo-BacklogPackInt {
  param($Value, [int]$Default, [int]$Min = 0, [int]$Max = 1000000)
  $n = 0.0
  try {
    if ([double]::TryParse([string]$Value, [ref]$n)) {
      $i = [int][Math]::Round($n)
      if ($i -lt $Min) { return $Min }
      if ($i -gt $Max) { return $Max }
      return $i
    }
  } catch {}
  return $Default
}

function Get-BacklogPackConfig {
  $cfg = [ordered]@{
    enabled            = $true
    burstCount         = 5
    windowMinutes      = 60
    unpackedOpenCount  = 8
    auditBurstCount    = 3
    auditWindowMinutes = 30
    cooldownMinutes    = 30
    minItems           = 2
  }
  $dotted = @{
    'backlogPack.enabled'            = 'enabled'
    'backlogPack.burstCount'         = 'burstCount'
    'backlogPack.windowMinutes'      = 'windowMinutes'
    'backlogPack.unpackedOpenCount'  = 'unpackedOpenCount'
    'backlogPack.auditBurstCount'    = 'auditBurstCount'
    'backlogPack.auditWindowMinutes' = 'auditWindowMinutes'
    'backlogPack.cooldownMinutes'    = 'cooldownMinutes'
    'backlogPack.minItems'           = 'minItems'
  }
  $flat = @{
    backlogPackEnabled            = 'enabled'
    backlogPackBurstCount         = 'burstCount'
    backlogPackWindowMinutes      = 'windowMinutes'
    backlogPackUnpackedOpenCount  = 'unpackedOpenCount'
    backlogPackAuditBurstCount    = 'auditBurstCount'
    backlogPackAuditWindowMinutes = 'auditWindowMinutes'
    backlogPackCooldownMinutes    = 'cooldownMinutes'
    backlogPackMinItems           = 'minItems'
  }
  try {
    if (Get-Command Get-AdvancedSettings -ErrorAction SilentlyContinue) {
      $adv = Get-AdvancedSettings
      foreach ($k in $dotted.Keys) {
        if ($adv -and $adv.Contains($k) -and $null -ne $adv[$k]) { $cfg[$dotted[$k]] = $adv[$k] }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.burstCount = ConvertTo-BacklogPackInt -Value $cfg.burstCount -Default 5 -Min 2 -Max 1000
  $cfg.windowMinutes = ConvertTo-BacklogPackInt -Value $cfg.windowMinutes -Default 60 -Min 1 -Max 1440
  $cfg.unpackedOpenCount = ConvertTo-BacklogPackInt -Value $cfg.unpackedOpenCount -Default 8 -Min 2 -Max 1000
  $cfg.auditBurstCount = ConvertTo-BacklogPackInt -Value $cfg.auditBurstCount -Default 3 -Min 2 -Max 1000
  $cfg.auditWindowMinutes = ConvertTo-BacklogPackInt -Value $cfg.auditWindowMinutes -Default 30 -Min 1 -Max 1440
  $cfg.cooldownMinutes = ConvertTo-BacklogPackInt -Value $cfg.cooldownMinutes -Default 30 -Min 1 -Max 1440
  $cfg.minItems = ConvertTo-BacklogPackInt -Value $cfg.minItems -Default 2 -Min 1 -Max 50
  return [pscustomobject]$cfg
}

function Get-BacklogPackChannel {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
      $slug = [string](Get-EffectiveChannel)
      if (-not [string]::IsNullOrWhiteSpace($slug)) { return $slug }
    }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-BacklogPackDir {
  $dir = $null
  try {
    if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
      $dir = Join-Path (Get-ChannelDir) 'workpacks'
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace([string]$dir)) {
    $dir = Join-Path (Get-BacklogControlDir) 'workpacks'
  }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Get-BacklogPackRequestPath { Join-Path (Get-BacklogPackDir) 'pack.request.json' }
function Get-BacklogPackLatestPath { Join-Path (Get-BacklogPackDir) 'latest.json' }
function Get-BacklogPackRunsPath { Join-Path (Get-BacklogPackDir) 'runs.jsonl' }

function Test-BacklogPackItemOpen {
  param($Item)
  $status = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')
  return ($status -in @('new','approved','held'))
}

function Test-BacklogPackItemUnpacked {
  param($Item)
  $packId = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default '')
  return [string]::IsNullOrWhiteSpace($packId)
}

function Test-BacklogPackItemAuditSource {
  param($Item)
  $from = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'from' -Default '')).ToLowerInvariant()
  if ($from -match 'audit') { return $true }
  $text = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')).ToLowerInvariant()
  if ($text -match '^\s*\[(deep-)?audit[/: -]') { return $true }
  try {
    $tags = @(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @() | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($tag in $tags) {
      if ($tag -match 'audit') { return $true }
    }
  } catch {}
  return $false
}

function Get-BacklogPackLastRun {
  $p = Get-BacklogPackLatestPath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-BacklogPackPressure {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  $now = (Get-Date).ToUniversalTime()
  $recentCut = $now.AddMinutes(-[Math]::Abs([int]$Config.windowMinutes))
  $auditCut = $now.AddMinutes(-[Math]::Abs([int]$Config.auditWindowMinutes))
  $recent = 0
  $auditRecent = 0
  $openUnpacked = 0
  $sample = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in @(Get-Backlog)) {
    if (-not (Test-BacklogPackItemOpen -Item $item)) { continue }
    if (-not (Test-BacklogPackItemUnpacked -Item $item)) { continue }
    $openUnpacked++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($id) -and $sample.Count -lt 10) { [void]$sample.Add($id) }
    $ts = $null
    try { $ts = [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $item -Name 'ts' -Default '')).ToUniversalTime() } catch { $ts = $null }
    if ($ts -and $ts -ge $recentCut) { $recent++ }
    if ($ts -and $ts -ge $auditCut -and (Test-BacklogPackItemAuditSource -Item $item)) { $auditRecent++ }
  }
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  if ($recent -ge [int]$Config.burstCount) { [void]$reasons.Add(("burst:{0}/{1}m" -f $recent, [int]$Config.windowMinutes)) }
  if ($openUnpacked -ge [int]$Config.unpackedOpenCount) { [void]$reasons.Add(("open-unpacked:{0}" -f $openUnpacked)) }
  if ($auditRecent -ge [int]$Config.auditBurstCount) { [void]$reasons.Add(("audit-burst:{0}/{1}m" -f $auditRecent, [int]$Config.auditWindowMinutes)) }
  return [pscustomobject]@{
    needed                = ($reasons.Count -gt 0)
    reasons               = @($reasons.ToArray())
    recent_unpacked_open  = $recent
    open_unpacked         = $openUnpacked
    recent_audit_unpacked = $auditRecent
    sample_ids            = @($sample.ToArray())
    channel               = Get-BacklogPackChannel
  }
}

function Request-BacklogPackIfNeeded {
  param([string]$NewItemId = '')
  try {
    $cfg = Get-BacklogPackConfig
    if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ requested=$false; reason='disabled' } }
    $pressure = Get-BacklogPackPressure -Config $cfg
    if (-not [bool]$pressure.needed) { return [pscustomobject]@{ requested=$false; reason='below-threshold'; pressure=$pressure } }
    $requestPath = Get-BacklogPackRequestPath
    if (Test-Path -LiteralPath $requestPath) {
      return [pscustomobject]@{ requested=$true; existing=$true; path=$requestPath; pressure=$pressure }
    }
    $last = Get-BacklogPackLastRun
    if ($last) {
      try {
        $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
        $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
        if ($ageMin -lt [int]$cfg.cooldownMinutes) {
          return [pscustomobject]@{ requested=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
        }
      } catch {}
    }
    $req = [ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      channel = [string]$pressure.channel
      reasons = @($pressure.reasons)
      counts = [ordered]@{
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        open_unpacked = [int]$pressure.open_unpacked
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
      }
      sample_ids = @($pressure.sample_ids)
      new_item_id = [string]$NewItemId
    }
    $json = ($req | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path $requestPath -Content $json
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $req.ts
        action = 'pack-request'
        channel = [string]$pressure.channel
        reasons = @($pressure.reasons)
        open_unpacked = [int]$pressure.open_unpacked
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
        new_item_id = [string]$NewItemId
      })
    } catch {}
    return [pscustomobject]@{ requested=$true; existing=$false; path=$requestPath; pressure=$pressure }
  } catch {
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='pack-request-error'; error=[string]$_.Exception.Message }) } catch {}
    return [pscustomobject]@{ requested=$false; reason='error'; error=[string]$_.Exception.Message }
  }
}

function Add-BacklogWorkpackFileCandidate {
  param([System.Collections.Generic.List[string]]$List, [string]$Path)
  if ($null -eq $List) { return }
  $v = ([string]$Path).Trim().Trim(" `t`r`n""'`.,;")
  if ([string]::IsNullOrWhiteSpace($v)) { return }
  if ($v.StartsWith('./') -or $v.StartsWith('.\')) { $v = $v.Substring(2) }
  $v = $v.Replace('\', '/').ToLowerInvariant()
  while ($v.StartsWith('/')) { $v = $v.Substring(1) }
  if ([string]::IsNullOrWhiteSpace($v)) { return }
  if (-not $List.Contains($v)) { [void]$List.Add($v) }
}

function Get-BacklogWorkpackSignalText {
  param([string]$Text)
  $v = [string]$Text
  return ([regex]::Replace($v, '^\s*(?:\[[^\]]+\]\s*)+', ''))
}

function Get-BacklogRelativeWorkpackPath {
  param([string]$Path)
  try {
    $root = [System.IO.Path]::GetFullPath((Get-BacklogFallbackBridgeRoot)).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ($full.Substring($root.Length).Replace('\', '/').ToLowerInvariant())
    }
  } catch {}
  return ((Split-Path -Leaf $Path).ToLowerInvariant())
}

function Get-BacklogFunctionFileMap {
  if ($script:BacklogFunctionFileMap) { return $script:BacklogFunctionFileMap }
  $map = @{}
  try {
    $root = Get-BacklogFallbackBridgeRoot
    $dirs = @($root, (Join-Path $root 'lib'), (Join-Path $root 'tools'))
    foreach ($dir in $dirs) {
      if (-not (Test-Path -LiteralPath $dir)) { continue }
      foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
        foreach ($m in [regex]::Matches($raw, '(?im)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b')) {
          $fn = $m.Groups[1].Value.ToLowerInvariant()
          if (-not $map.ContainsKey($fn)) { $map[$fn] = New-Object 'System.Collections.Generic.List[string]' }
          Add-BacklogWorkpackFileCandidate -List $map[$fn] -Path (Get-BacklogRelativeWorkpackPath -Path $file.FullName)
        }
      }
    }
  } catch {}
  $script:BacklogFunctionFileMap = $map
  return $script:BacklogFunctionFileMap
}

function Get-BacklogInferredFiles {
  param([string]$Text)
  $files = New-Object 'System.Collections.Generic.List[string]'
  $textRaw = Get-BacklogWorkpackSignalText -Text $Text
  $t = $textRaw.ToLowerInvariant()

  try {
    $fnMap = Get-BacklogFunctionFileMap
    foreach ($m in [regex]::Matches($textRaw, '\b[A-Z][A-Za-z0-9]+-[A-Za-z0-9][A-Za-z0-9-]*\b')) {
      $fn = $m.Value.ToLowerInvariant()
      if (-not $fnMap.ContainsKey($fn)) { continue }
      foreach ($p in @($fnMap[$fn].ToArray())) { Add-BacklogWorkpackFileCandidate -List $files -Path $p }
    }
  } catch {}

  if ($t -match '(start-srv|start-drv|reap-bloated|process[_ -]?supervision|private memory|tracked processes|redirect stdout|stderr|log file path|bloated pid)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '(supervisor|watchdog|restart\.flag|explicit-flag|recycle|circuit-breaker|cooldown)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '(orphan[- ]restart|restart attribution|restart mechanism|restarts? without associated task|without associated task activity|restarts\.jsonl|circuit-breaker|cb-loop)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/circuit-breaker.ps1'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match 'taskkill\s+/pid\s+\$_\.processid') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'supervisor.ps1'
  }
  if ($t -match '\bchannels\.ps1\b') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/channels.ps1'
  }
  if ($t -match '(get-backlogpath|add-idea|backlog path|backlog-curator|curator)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/backlog.ps1'
  }
  if (($t -match '(get-backlogpath|add-idea|backlog path)') -and ($t -match '(audit|deep-audit|audit-self-diag|drift analysis)')) {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'tools/audit.ps1'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/common.ps1'
  }
  if ($t -match '(backlog-add\.js|/api/backlog/add|post /api/backlog/add)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'tools/scenarios/backlog-add.js'
    Add-BacklogWorkpackFileCandidate -List $files -Path 'server.ps1'
  }
  if ($t -match '(memory\.html|/memory|settings cells|api\(\).*503|transient 503|transient 502|transient 504)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'web/memory.html'
  }
  if ($t -match '(librarian|embedding|recall|vector|cosine)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/memory.ps1'
  }
  if ($t -match '(parallel dispatch|parallel worker|trivial-fallback|\[\[parallel|worktree (cleanup|janitor|merge|isolation|lock)|\bworktrees?\b.*(parallel|worker|merge))') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'lib/parallel.ps1'
  }
  if ($t -match '(fast-lane|fast lane|intent classifier|классификатор намерений|detect-study|task_mode|discuss-mode|discuss prompt|discuss-промпт|codex exec.*unexpected argument|stdin-редирект|лишний [`''"]?-|explicit-инструкц|без дебатов)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'driver.ps1'
  }
  if ($t -match '(hardcoded[_ -]?secrets?|hardcoded paths?|configuration file|config file|environment variables|tool discovery|well-known installation)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'config.json'
  }
  if ($t -match '(feature verifier|features[/\\]state|features[/\\]registry|feature states|feature id|scenario_results)') {
    Add-BacklogWorkpackFileCandidate -List $files -Path 'features/state.js'
  }

  return @($files.ToArray())
}

function Get-BacklogPrimaryWorkpackFile {
  param([string[]]$Files)
  $arr = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($arr.Count -eq 0) { return '' }
  foreach ($preferred in @(
      'lib/circuit-breaker.ps1',
      'supervisor.ps1',
      'canary.ps1',
      'driver.ps1',
      'server.ps1',
      'watchdog.ps1',
      'lib/common.ps1',
      'lib/backlog.ps1',
      'lib/channels.ps1',
      'tools/audit.ps1',
      'lib/parallel.ps1',
      'lib/memory.ps1',
      'web/memory.html',
      'features/state.js',
      'tools/scenarios/backlog-add.js',
      'config.json'
    )) {
    if ($arr -contains $preferred) { return $preferred }
  }
  return [string]$arr[0]
}

function Get-BacklogWorkpackModule {
  param([string]$Text, [string[]]$Files = @())
  $t = (Get-BacklogWorkpackSignalText -Text $Text).ToLowerInvariant()
  $all = ((@($Files) + @($t)) -join ' ').ToLowerInvariant()
  if ($all -match 'lib/circuit-breaker\.ps1|orphan[- ]restart|restart attribution|restart mechanism|restarts? without associated task|restarts\.jsonl|cb-loop') { return 'safety' }
  if ($all -match 'supervisor\.ps1|start-srv|start-drv|reap-bloated|process[_ -]?supervision|private memory|tracked processes|bloated pid') { return 'supervisor' }
  if ($all -match 'watchdog|circuit|sandbox|security|preflight|permission|command[_ -]?injection|hardcoded[_ -]?secrets?|unsafe[_ -]?dynamic[_ -]?execution|dynamic execution|invoke-expression|taskkill|shelling out|sanitize|sanitise|allowlist|защит') { return 'safety' }
  if ($all -match 'features/state\.(js|json)|features/registry|feature states|feature id|scenario_results|state|snapshot|checkpoint|restart|resume') { return 'state' }
  if ($all -match 'audit|deep-audit|finding|scenario|doctor|аудит') { return 'audit' }
  if ($all -match 'backlog|curator|idea|approve|approval|held|workpack|беклог|бэклог') { return 'backlog' }
  if ($all -match 'memory|librarian|embedding|recall|памят') { return 'memory' }
  if ($all -match 'web/index\.html|web/memory\.html|\bui\b|badge|status badge|frontend|интерфейс') { return 'ui' }
  if ($all -match 'llm|codex|claude|gemini|deepseek|timeout|model') { return 'llm' }
  if ($all -match 'parallel|lane|worktree|concurrent|паралл') { return 'parallel' }
  if ($all -match 'readme|docs|documentation|runbook|guide|докум') { return 'docs' }
  return 'general'
}

function Get-BacklogTaskTargetFile {
  # 2026-05-31 (Foundation #4): the file a task is meant to EDIT — the path right after the action
  # verb (Перепиши/Создай/реализуй <file>), NOT a reference/эталон path cited later in the prompt.
  # Without this, redesign tasks that all referenced the same эталон (HeroSection.tsx) collapsed into
  # ONE workpack and ran serial. Returns '' if no clear target file.
  param([string]$Text)
  $t = [string]$Text
  if ([string]::IsNullOrWhiteSpace($t)) { return '' }
  $rx = '(?im)(?:перепиши|создай|реализуй|оформлени[ея]|приведи|измени|изменить|исправь|исправить|обнови|обновить|добавь|добавить|доработай|доработать|change|modify|update|edit|fix)[^\n]{0,90}?((?:src|app|content|public|prisma|config|styles|components|pages|api|lib|driver)[\\/][\w./\-\[\]]+\.\w{1,5})'
  $m = [regex]::Match($t, $rx)
  if ($m.Success) { return ($m.Groups[1].Value -replace '\\', '/') }
  return ''
}

function Get-BacklogWorkpackConflictGroup {
  param([string]$Text, [string[]]$Files = @())
  $Text = Get-BacklogTextOutsideForbiddenContexts -Text $Text
  # 2026-05-31 (Foundation #4 scale): for a PROJECT channel, group by the TARGET file FIRST — BEFORE
  # the bridge-module patterns below, which falsely match project text ("UI", "DESIGN.md", "frontend")
  # and collapsed redesign tasks into one 'ui'/'docs' group => serial. Different target files =>
  # different groups => parallel; same target file => same group => serial (correct).
  $isProjectCh = $false
  try {
    if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
      $prc = Get-EffectiveProjectRoot
      $isProjectCh = (-not [string]::IsNullOrWhiteSpace([string]$prc) -and ([string]$prc -ne (Get-BridgeRoot)))
    }
  } catch {}
  if ($isProjectCh) {
    $tgt = Get-BacklogTaskTargetFile -Text $Text
    if ([string]::IsNullOrWhiteSpace($tgt) -and @($Files).Count -gt 0) { $tgt = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object | Select-Object -First 1) }
    if ($tgt) { $n = ([string]$tgt).ToLowerInvariant() -replace '\\', '/'; return ('file:' + ($n -replace '[^a-z0-9/._-]+', '-')) }
    return 'general'
  }
  $signalText = Get-BacklogWorkpackSignalText -Text $Text
  $all = ((@($Files) + @([string]$signalText)) -join ' ').ToLowerInvariant()
  if ($all -match '(^|/)(driver|server)\.ps1|lib/common\.ps1|lib/channels\.ps1') { return 'core' }
  if ($all -match 'supervisor\.ps1|lib/circuit-breaker\.ps1|watchdog|supervisor|start-srv|start-drv|reap-bloated|orphan[- ]restart|restart attribution|circuit|sandbox|security|preflight|permissions|command[_ -]?injection|hardcoded[_ -]?secrets?|unsafe[_ -]?dynamic[_ -]?execution|dynamic execution|invoke-expression|taskkill|shelling out|sanitize|sanitise|allowlist|защит') { return 'safety' }
  if ($all -match 'features/state\.(js|json)|features/registry|feature states|feature id|scenario_results|state|checkpoint|restart') { return 'state' }
  if ($all -match 'audit|doctor|scenario') { return 'audit' }
  if ($all -match 'backlog|curator|workpack') { return 'backlog' }
  if ($all -match 'memory|librarian|embedding') { return 'memory' }
  if ($all -match 'web/|\bui\b|badge|frontend') { return 'ui' }
  if ($all -match 'llm|codex|claude|gemini|deepseek') { return 'llm' }
  if ($all -match 'parallel|worktree|lane') { return 'parallel' }
  if ($all -match '\.md|docs/|readme|runbook|guide') { return 'docs' }
  return 'general'
}

function New-BacklogWorkpackId {
  param([string]$Key)
  $slug = ([string]$Key).ToLowerInvariant() -replace '[^a-z0-9]+','-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'general' }
  if ($slug.Length -gt 36) { $slug = $slug.Substring(0, 36).Trim('-') }
  return ('wp-{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMddHHmmss'), $slug, ([guid]::NewGuid().ToString('N').Substring(0,6)))
}

function Get-BacklogWorkpackClassification {
  param($Item)
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  $signalText = Get-BacklogTextOutsideForbiddenContexts -Text $text
  $fileList = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in @(Get-BacklogMentionedFiles -Text $signalText | Sort-Object)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
  foreach ($f in @(Get-BacklogInferredFiles -Text $signalText)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
  $files = @($fileList.ToArray())
  $module = Get-BacklogWorkpackModule -Text $signalText -Files $files
  $touch = @()
  $key = ''
  if ($files.Count -gt 0) {
    # 2026-05-31 (Foundation #4): prefer the task's TARGET file (after the action verb) over an
    # эталон/reference path, so independent tasks land in distinct workpacks and run in parallel.
    $primary = Get-BacklogTaskTargetFile -Text $signalText
    if ([string]::IsNullOrWhiteSpace($primary)) { $primary = Get-BacklogPrimaryWorkpackFile -Files $files }
    $touch = @((@($primary) + @($files)) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Select-Object -First 8)
    # 2026-06-01 (Foundation #4 scale): for a PROJECT channel, key by the FULL file path so that N
    # tasks editing N different files form N workpacks (=> up to N parallel streams). Bridge keeps
    # dir-level-2 grouping (serial-by-module on a shared tree). Without this, e.g. docs/scale-test/*
    # all collapsed into ONE 'file:docs/scale-test' workpack and the batch took only ~2.
    $isProjectCh = $false
    try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $prk = Get-EffectiveProjectRoot; $isProjectCh = (-not [string]::IsNullOrWhiteSpace([string]$prk) -and ([string]$prk -ne (Get-BridgeRoot))) } } catch {}
    if ($isProjectCh) {
      $key = 'file:' + (([string]$primary).ToLowerInvariant())
    } elseif ($primary -match '^(lib|tools|web|memory|control|docs|channels)/') {
      $parts = $primary -split '/'
      if ($parts.Count -ge 2) { $key = 'file:' + $parts[0] + '/' + $parts[1] }
      else { $key = 'file:' + $primary }
    } else {
      $key = 'file:' + $primary
    }
  } else {
    $keywords = @(Get-BacklogIdeaKeywords -Text $text | Select-Object -First 2)
    if ($module -ne 'general') { $key = 'module:' + $module }
    elseif ($keywords.Count -gt 0) { $key = 'module:' + $module + ':' + (($keywords | ForEach-Object { [string]$_ }) -join '-') }
    else { $key = 'module:' + $module }
    $touch = @($module)
  }
  if ([string]::IsNullOrWhiteSpace($key)) { $key = 'module:general' }
  $conflict = Get-BacklogWorkpackConflictGroup -Text $signalText -Files $files
  return [pscustomobject]@{
    key            = $key.ToLowerInvariant()
    touch_set      = @($touch)
    conflict_group = $conflict
    lane_hint      = ('serial:' + $conflict)
  }
}

function Invoke-BacklogPacker {
  param([string[]]$Reason = @('manual'), $Config = $null)
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  if (-not [bool]$Config.enabled) { return [pscustomobject]@{ ran=$false; reason='disabled'; packed_items=0; workpack_count=0 } }

  return (Invoke-BacklogLocked {
    $items = @(Get-Backlog)
    $candidates = @($items | Where-Object { (Test-BacklogPackItemOpen -Item $_) -and (Test-BacklogPackItemUnpacked -Item $_) })
    if ($candidates.Count -lt [int]$Config.minItems) {
      return [pscustomobject]@{ ran=$true; reason='not-enough-items'; packed_items=0; workpack_count=0; candidate_count=$candidates.Count }
    }

    $groups = @{}
    $classes = @{}
    foreach ($item in $candidates) {
      $class = Get-BacklogWorkpackClassification -Item $item
      $key = [string]$class.key
      if ([string]::IsNullOrWhiteSpace($key)) { $key = 'module:general' }
      if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object 'System.Collections.Generic.List[object]' }
      [void]$groups[$key].Add($item)
      $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
      if (-not [string]::IsNullOrWhiteSpace($id)) { $classes[$id] = $class }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $packSummaries = New-Object 'System.Collections.Generic.List[object]'
    $packed = 0
    foreach ($key in @($groups.Keys | Sort-Object)) {
      $groupItems = @($groups[$key].ToArray())
      if ($groupItems.Count -eq 0) { continue }
      $packId = New-BacklogWorkpackId -Key $key
      $firstClass = $null
      foreach ($g in $groupItems) {
        $gid = [string](Get-BacklogPackObjectValue -Obj $g -Name 'id' -Default '')
        if ($classes.ContainsKey($gid)) { $firstClass = $classes[$gid]; break }
      }
      if (-not $firstClass) { $firstClass = [pscustomobject]@{ touch_set=@('general'); conflict_group='general'; lane_hint='serial:general' } }
      $ids = @()
      foreach ($g in $groupItems) {
        $gid = [string](Get-BacklogPackObjectValue -Obj $g -Name 'id' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($gid)) { $ids += $gid }
        $g | Add-Member -NotePropertyName workpack_id -NotePropertyValue $packId -Force
        $g | Add-Member -NotePropertyName workpack_ts -NotePropertyValue $now -Force
        $g | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue $key -Force
        $g | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($firstClass.touch_set) -Force
        $g | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$firstClass.conflict_group) -Force
        $g | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ([string]$firstClass.lane_hint) -Force
        $g | Add-Member -NotePropertyName workpack_status -NotePropertyValue 'planned' -Force
        $g | Add-Member -NotePropertyName workpack_reason -NotePropertyValue ((@($Reason) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ',') -Force
        $g | Add-Member -NotePropertyName workpack_size -NotePropertyValue $groupItems.Count -Force
        $packed++
      }
      [void]$packSummaries.Add([ordered]@{
        id = $packId
        key = $key
        size = $groupItems.Count
        conflict_group = [string]$firstClass.conflict_group
        touch_set = @($firstClass.touch_set)
        item_ids = @($ids)
      })
    }

    if ($packed -gt 0) { Save-Backlog $items }
    $summary = [ordered]@{
      ts = $now
      channel = Get-BacklogPackChannel
      reason = @($Reason)
      packed_items = $packed
      workpack_count = $packSummaries.Count
      workpacks = @($packSummaries.ToArray())
    }
    $latestJson = ($summary | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path (Get-BacklogPackLatestPath) -Content $latestJson
    $line = $summary | ConvertTo-Json -Compress -Depth 6
    [System.IO.File]::AppendAllText((Get-BacklogPackRunsPath), ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $now
        action = 'pack-run'
        channel = [string]$summary.channel
        reason = @($Reason)
        packed_items = $packed
        workpack_count = $packSummaries.Count
      })
    } catch {}
    return [pscustomobject]@{
      ran = $true
      packed_items = $packed
      workpack_count = $packSummaries.Count
      workpacks = @($packSummaries.ToArray())
    }
  }.GetNewClosure())
}

function Invoke-BacklogPackerIfDue {
  $cfg = Get-BacklogPackConfig
  if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ ran=$false; reason='disabled'; packed_items=0; workpack_count=0 } }
  $requestPath = Get-BacklogPackRequestPath
  if (-not (Test-Path -LiteralPath $requestPath)) { return [pscustomobject]@{ ran=$false; reason='no-request'; packed_items=0; workpack_count=0 } }
  $req = $null
  try { $req = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  $last = Get-BacklogPackLastRun
  if ($last) {
    try {
      $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
      if ((((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes) -lt [int]$cfg.cooldownMinutes) {
        return [pscustomobject]@{ ran=$false; reason='cooldown'; packed_items=0; workpack_count=0 }
      }
    } catch {}
  }
  $reason = @('request')
  try {
    if ($req -and ($req.PSObject.Properties.Name -contains 'reasons')) { $reason = @($req.reasons | ForEach-Object { [string]$_ }) }
  } catch {}
  if ($reason.Count -eq 0) { $reason = @('request') }
  $result = Invoke-BacklogPacker -Reason $reason -Config $cfg
  if ($result -and [bool]$result.ran) {
    try { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue } catch {}
  }
  return $result
}

function Update-BacklogWorkpackClassifications {
  param([string[]]$Statuses = @('new','approved','held'))
  $allowed = @{}
  foreach ($s in @($Statuses)) {
    $v = ([string]$s).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($v)) { $allowed[$v] = $true }
  }
  return (Invoke-BacklogLocked {
    $items = @(Get-Backlog)
    $updated = 0
    foreach ($item in $items) {
      $status = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).ToLowerInvariant()
      if (-not $allowed.ContainsKey($status)) { continue }
      if ([string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default ''))) { continue }
      $class = Get-BacklogWorkpackClassification -Item $item
      $newTouch = @($class.touch_set | ForEach-Object { [string]$_ })
      $oldTouch = @(Get-BacklogPackObjectValue -Obj $item -Name 'workpack_touch_set' -Default @() | ForEach-Object { [string]$_ })
      $oldKey = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_root_cause_key' -Default '')
      $oldGroup = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default '')
      $changed = $false
      if ($oldKey -ne [string]$class.key) { $changed = $true }
      if ($oldGroup -ne [string]$class.conflict_group) { $changed = $true }
      if ((@($oldTouch) -join '|') -ne ((@($newTouch)) -join '|')) { $changed = $true }
      if (-not $changed) { continue }
      $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue ([string]$class.key) -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($newTouch) -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ([string]$class.conflict_group) -Force
      $item | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ([string]$class.lane_hint) -Force
      $item | Add-Member -NotePropertyName workpack_reclassified_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $updated++
    }
    if ($updated -gt 0) {
      Save-Backlog $items
      try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='workpack-reclassify'; updated=$updated; statuses=@($Statuses) }) } catch {}
    }
    return $updated
  }.GetNewClosure())
}

function Get-BacklogWorkpackExecConfig {
  $cfg = [ordered]@{
    enabled          = $true
    minItems         = 2
    maxItems         = 6
    includeProtected = $false
  }
  $dotted = @{
    'workpackExec.enabled'          = 'enabled'
    'workpackExec.minItems'         = 'minItems'
    'workpackExec.maxItems'         = 'maxItems'
    'workpackExec.includeProtected' = 'includeProtected'
  }
  $flat = @{
    workpackExecEnabled          = 'enabled'
    workpackExecMinItems         = 'minItems'
    workpackExecMaxItems         = 'maxItems'
    workpackExecIncludeProtected = 'includeProtected'
  }
  try {
    if (Get-Command Get-AdvancedSettings -ErrorAction SilentlyContinue) {
      $adv = Get-AdvancedSettings
      foreach ($k in $dotted.Keys) {
        if ($adv -and $adv.Contains($k) -and $null -ne $adv[$k]) { $cfg[$dotted[$k]] = $adv[$k] }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.minItems = ConvertTo-BacklogPackInt -Value $cfg.minItems -Default 2 -Min 2 -Max 12
  $cfg.maxItems = ConvertTo-BacklogPackInt -Value $cfg.maxItems -Default 6 -Min 2 -Max 24
  $cfg.includeProtected = ConvertTo-BacklogPackBool -Value $cfg.includeProtected -Default $false
  if ([int]$cfg.maxItems -lt [int]$cfg.minItems) { $cfg.maxItems = [int]$cfg.minItems }
  return [pscustomobject]$cfg
}

function Get-BacklogWorkpackItemTouches {
  param($Item)
  $touches = New-Object 'System.Collections.Generic.List[string]'
  # 2026-06-01 ROOT FIX (parallelism / "bridge as a team"): prefer the SINGLE target file the task
  # actually EDITS (action verb + path), not every path it mentions. redesign tasks cite a shared
  # эталон (HeroSection.tsx) as a reference; the stored workpack_touch_set captured that эталон, so
  # EVERY task overlapped on herosection.ts and the packer treated 6 independent file edits as mutually
  # conflicting -> serial execution. The target file is the only path written, so overlap then reflects
  # REAL conflicts. Falls back to the stored touch_set / mentioned files when no clear target exists.
  $touchText = Get-BacklogTextOutsideForbiddenContexts -Text ([string]$Item.text)
  try {
    if (Get-Command Get-BacklogTaskTargetFile -ErrorAction SilentlyContinue) {
      $tgt = [string](Get-BacklogTaskTargetFile -Text $touchText)
      if (-not [string]::IsNullOrWhiteSpace($tgt)) {
        $tv = $tgt.Trim().ToLowerInvariant() -replace '\\','/'
        if (-not [string]::IsNullOrWhiteSpace($tv)) { return @($tv) }
      }
    }
  } catch {}
  try {
    foreach ($t in @(Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_touch_set' -Default @())) {
      $v = ([string]$t).Trim().ToLowerInvariant() -replace '\\','/'
      if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$touches.Add($v) }
    }
  } catch {}
  if ($touches.Count -eq 0) {
    try {
      foreach ($f in @(Get-BacklogMentionedFiles -Text $touchText)) {
        $v = ([string]$f).Trim().ToLowerInvariant() -replace '\\','/'
        if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$touches.Add($v) }
      }
    } catch {}
  }
  if ($touches.Count -eq 0) {
    $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($cg)) { [void]$touches.Add($cg) }
  }
  return @($touches.ToArray() | Sort-Object -Unique)
}

function Test-BacklogWorkpackTouchesOverlap {
  param([string[]]$Left, [string[]]$Right)
  $seen = @{}
  foreach ($l in @($Left)) {
    $v = ([string]$l).Trim().ToLowerInvariant() -replace '\\','/'
    if (-not [string]::IsNullOrWhiteSpace($v)) { $seen[$v] = $true }
  }
  foreach ($r in @($Right)) {
    $v = ([string]$r).Trim().ToLowerInvariant() -replace '\\','/'
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    if ($seen.ContainsKey($v)) { return $true }
  }
  return $false
}

function Test-BacklogWorkpackExecEligible {
  param($Item, $Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }
  if (-not [bool]$Config.enabled) { return $false }
  if (-not $Item) { return $false }
  if ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '') -ne 'approved') { return $false }
  if ([string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default ''))) { return $false }
  try { if (Test-IdeaExternal $Item) { return $false } } catch {}
  $cg = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
  if ((-not [bool]$Config.includeProtected) -and ($cg -in @('core','safety'))) { return $false }
  return $true
}

function Get-BacklogTaskDepSignal {
  # 2026-06-01 ERR-002 (dependency-aware packing). Atoms carry no explicit depends_on, so this infers
  # from task text whether a task is a structural BARRIER (must be serialized) vs a NEUTRAL independent
  # edit (safe to parallelize). Returns 'foundation' (creates structure later tasks build on -> must
  # precede them), 'dependent' (explicitly relies on another task's artifact -> must follow it), or
  # 'neutral'. Consumed by Get-NextBacklogWorkpackBatch to force sequential waves for dependent chains
  # (scaffold -> Prisma/User model -> admin seed -> auth) that the touch-set packer wrongly saw as
  # independent because their files differ — which generated incompatible code (ERR-005).
  param([string]$Text)
  $t = ([string]$Text)
  if ([string]::IsNullOrWhiteSpace($t)) { return 'neutral' }
  $t = $t.ToLowerInvariant()
  $foundation = @(
    'scaffold','boilerplate','каркас проект','инициализ','init project','project setup','настрой проект',
    'prisma','\bschema\b','schema\.prisma','миграци','migration','db schema','database','схему базы','схему бд',
    '\bmodel\b','data model','модель данных','модель данны','\bentity\b','\borm\b','create table','create\s+\w+\s+table','таблиц',
    'package\.json','next\.config','tsconfig','определи модель','define\s+\w+\s+model','create\s+\w+\s+model','set up\s+.{0,20}(project|schema|database)'
  )
  $dependent = @(
    'после того как','после создани','на основе созданн','поверх созданн','использует модель','использует схему','на базе модел','на базе схем',
    '\bseed\b','seed script','using\s+.{0,25}(model|schema|table|api|prisma)','uses\s+.{0,25}(model|schema|table)','based on\s+.{0,25}(model|schema|table)','extends?\s+.{0,25}(model|schema)','подключ.{0,20}(модель|схему|бд)',
    'depends on','requires\s+.{0,30}(to exist|exist|first)','once\s+.{0,30}exist','after\s+.{0,30}(is created|created|exists|set up|scaffold)','building on\s+.{0,30}(model|schema|scaffold)','расширяет существующ','интегрир.{0,30}с созданн'
  )
  foreach ($rx in $foundation) { if ($t -match $rx) { return 'foundation' } }
  foreach ($rx in $dependent)  { if ($t -match $rx) { return 'dependent' } }
  return 'neutral'
}

function Get-BacklogTaskSlug {
  param($Item)
  $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'slug' -Default '')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'title' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'id' -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($slug)) { return '' }
  try {
    if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) {
      return [string](ConvertTo-ProjectAutopilotSlug $slug)
    }
  } catch {}
  $v = $slug.Trim().ToLowerInvariant()
  $v = $v -replace '[^a-z0-9а-яё._-]+','-'
  return $v.Trim([char[]]@('-','_','.'))
}

function Get-BacklogTaskDependencySlugs {
  param($Item)
  $deps = New-Object 'System.Collections.Generic.List[string]'
  try {
    foreach ($d in @(Get-BacklogPackObjectValue -Obj $Item -Name 'depends_on' -Default @())) {
      $raw = [string]$d
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $slug = $raw
      try {
        if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) {
          $slug = [string](ConvertTo-ProjectAutopilotSlug $raw)
        } else {
          $slug = ($raw.Trim().ToLowerInvariant() -replace '[^a-z0-9а-яё._-]+','-').Trim([char[]]@('-','_','.'))
        }
      } catch {}
      if (-not [string]::IsNullOrWhiteSpace($slug)) { [void]$deps.Add($slug) }
    }
  } catch {}
  return @($deps.ToArray() | Sort-Object -Unique)
}

function Get-BacklogSlugStatusMap {
  param([object[]]$Items)
  $map = @{}
  foreach ($item in @($Items)) {
    $slug = Get-BacklogTaskSlug -Item $item
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    $map[$slug] = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).ToLowerInvariant()
  }
  return $map
}

function Test-BacklogTaskDependenciesReady {
  param($Item, $StatusBySlug)
  $deps = @(Get-BacklogTaskDependencySlugs -Item $Item)
  if ($deps.Count -eq 0) {
    return [pscustomobject]@{ ready=$true; deps=@(); unmet=@() }
  }
  $doneStatuses = @{ done=$true; 'auto-resolved'=$true }
  $unmet = New-Object 'System.Collections.Generic.List[string]'
  foreach ($dep in @($deps)) {
    $st = ''
    try { if ($StatusBySlug.ContainsKey($dep)) { $st = [string]$StatusBySlug[$dep] } } catch {}
    if ([string]::IsNullOrWhiteSpace($st) -or -not $doneStatuses.ContainsKey($st)) {
      $label = if ([string]::IsNullOrWhiteSpace($st)) { $dep + '(missing)' } else { $dep + '(' + $st + ')' }
      [void]$unmet.Add($label)
    }
  }
  return [pscustomobject]@{ ready=($unmet.Count -eq 0); deps=@($deps); unmet=@($unmet.ToArray()) }
}

function Resolve-BacklogWorkpackFrontier {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }

  $allItems = @(Get-Backlog)
  $approved = @(
    $allItems |
    Where-Object { [string](Get-BacklogPackObjectValue -Obj $_ -Name 'status' -Default '') -eq 'approved' }
  )
  $withWorkpack = @(
    $approved |
    Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_id' -Default '')) }
  )
  $withoutWorkpack = @(
    $approved |
    Where-Object { [string]::IsNullOrWhiteSpace([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_id' -Default '')) }
  )
  $protected = @(
    $withWorkpack |
    Where-Object {
      $cg = ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
      ($cg -in @('core','safety'))
    }
  )
  $eligible = @(
    $allItems |
    Where-Object { Test-BacklogWorkpackExecEligible -Item $_ -Config $Config } |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}}
  )

  $statusBySlug = Get-BacklogSlugStatusMap -Items $allItems
  $selected = New-Object 'System.Collections.Generic.List[object]'
  $usedGroups = @{}
  $usedTouches = New-Object 'System.Collections.Generic.List[string]'
  $readyCount = 0
  $dependencyWait = 0
  $structuralWait = 0
  $conflictSkips = 0
  $touchSkips = 0
  if ([bool]$Config.enabled -and $eligible.Count -ge [int]$Config.minItems) {
    foreach ($item in $eligible) {
      $selectionFull = ($selected.Count -ge [int]$Config.maxItems)
      $txt = [string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '')
      $depCheck = Test-BacklogTaskDependenciesReady -Item $item -StatusBySlug $statusBySlug
      $explicitDeps = @($depCheck.deps)
      if (-not [bool]$depCheck.ready) { $dependencyWait++; continue }

      # Dependency-aware frontier: one blocked/dependent item must not freeze the whole team.
      # Explicit depends_on is authoritative. Heuristic "foundation" without explicit deps stays a
      # serial barrier; explicit, already-satisfied deps can join the frontier if touch sets do not
      # overlap. This keeps scaffold/schema steps safe while allowing later ready lanes to fan out.
      $depSignal = Get-BacklogTaskDepSignal -Text $txt
      if ($depSignal -eq 'foundation' -and $explicitDeps.Count -eq 0) {
        $structuralWait++
        if (-not $selectionFull) { break }
        continue
      }
      if ($depSignal -eq 'dependent' -and $explicitDeps.Count -eq 0) { $dependencyWait++; continue }

      $readyCount++
      if ($selectionFull) { continue }
      $packId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default '')
      if ([string]::IsNullOrWhiteSpace($packId)) { continue }
      # 2026-06-01 ROOT FIX (parallelism / "bridge as a team"): do NOT dedupe by workpack_id. Truly
      # independent tasks (distinct conflict_group + non-overlapping touch-set) frequently share a STALE
      # workpack_id from an earlier packing pass — e.g. 5 redesign tasks for 5 different files all carried
      # one 'erosection-ts' pack id from when they were collapsed under a common эталон. Blocking by
      # workpack_id then capped real parallelism at 1-per-pack (6 independent file edits -> only 2
      # streams), so the bridge ran near-serial instead of as a team. Independence is fully decided by
      # conflict_group + touch overlap below; workpack_id is reporting-only.
      $group = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default 'general')).ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($group)) { $group = 'general' }
      if ($usedGroups.ContainsKey($group)) { $conflictSkips++; continue }

      $touches = @(Get-BacklogWorkpackItemTouches -Item $item)
      if (Test-BacklogWorkpackTouchesOverlap -Left @($usedTouches.ToArray()) -Right $touches) { $touchSkips++; continue }

      [void]$selected.Add($item)
      $usedGroups[$group] = $true
      foreach ($t in $touches) { [void]$usedTouches.Add($t) }
    }
  }

  $ids = @($selected.ToArray() | ForEach-Object { [string]$_.id })
  $packs = @($selected.ToArray() | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
  $groups = @($usedGroups.Keys | Sort-Object -Unique)
  $batchAvailable = ($selected.Count -ge [int]$Config.minItems)
  $reason = 'unknown'
  if (-not [bool]$Config.enabled) {
    $reason = 'disabled'
  } elseif ($approved.Count -lt [int]$Config.minItems) {
    $reason = 'not-enough-approved'
  } elseif ($withWorkpack.Count -lt [int]$Config.minItems) {
    $reason = 'not-enough-workpack'
  } elseif ($eligible.Count -lt [int]$Config.minItems) {
    if (($protected.Count -ge [int]$Config.minItems) -and (-not [bool]$Config.includeProtected)) {
      $reason = 'protected-dominant'
    } else {
      $reason = 'not-enough-eligible'
    }
  } elseif ($batchAvailable) {
    $reason = 'batch-available'
  } elseif ($readyCount -lt [int]$Config.minItems) {
    if ($dependencyWait -gt 0) { $reason = 'dependency-wait' }
    elseif ($structuralWait -gt 0) { $reason = 'structural-barrier' }
    else { $reason = 'not-enough-eligible' }
  } elseif (($conflictSkips + $touchSkips) -gt 0) {
    $reason = 'conflicts-or-touch-overlap'
  } elseif ($dependencyWait -gt 0) {
    $reason = 'dependency-wait'
  } elseif ($structuralWait -gt 0) {
    $reason = 'structural-barrier'
  }

  $report = [pscustomobject][ordered]@{
    enabled               = [bool]$Config.enabled
    approved_count        = [int]$approved.Count
    with_workpack_count   = [int]$withWorkpack.Count
    without_workpack_count = [int]$withoutWorkpack.Count
    eligible_count        = [int]$eligible.Count
    protected_count       = [int]$protected.Count
    ready_count           = [int]$readyCount
    selected_count        = [int]$selected.Count
    min_items             = [int]$Config.minItems
    max_items             = [int]$Config.maxItems
    dependency_wait_count = [int]$dependencyWait
    structural_wait_count = [int]$structuralWait
    conflict_skip_count   = [int]$conflictSkips
    touch_skip_count      = [int]$touchSkips
    batch_available       = [bool]$batchAvailable
    parallel_required     = [bool]$batchAvailable
    reason                = [string]$reason
    selected_ids          = @($ids)
    selected_groups       = @($groups)
  }

  return [pscustomobject][ordered]@{
    items = @($selected.ToArray())
    ids = @($ids)
    workpacks = @($packs)
    conflict_groups = @($groups)
    count = $selected.Count
    eligible_count = $eligible.Count
    ready_count = $readyCount
    dependency_wait_count = $dependencyWait
    structural_wait_count = $structuralWait
    conflict_skip_count = $conflictSkips
    touch_skip_count = $touchSkips
    report = $report
  }
}

function Get-BacklogWorkpackFrontierReport {
  param($Config = $null)
  $frontier = Resolve-BacklogWorkpackFrontier -Config $Config
  return $frontier.report
}

function Get-NextBacklogWorkpackBatch {
  param($Config = $null)
  $frontier = Resolve-BacklogWorkpackFrontier -Config $Config
  if (-not $frontier -or -not $frontier.report -or -not [bool]$frontier.report.batch_available) { return $null }
  return [pscustomobject]@{
    items = @($frontier.items)
    ids = @($frontier.ids)
    workpacks = @($frontier.workpacks)
    conflict_groups = @($frontier.conflict_groups)
    count = [int]$frontier.count
    eligible_count = [int]$frontier.eligible_count
    ready_count = [int]$frontier.ready_count
    dependency_wait_count = [int]$frontier.dependency_wait_count
    structural_wait_count = [int]$frontier.structural_wait_count
    conflict_skip_count = [int]$frontier.conflict_skip_count
    touch_skip_count = [int]$frontier.touch_skip_count
    frontier_report = $frontier.report
  }
}

function New-BacklogWorkpackBatchTaskText {
  param([object[]]$Items)
  $itemsArr = @($Items | Where-Object { $_ })
  $n = $itemsArr.Count
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("[Автозадача из workpack-batch] Выполни $n независимых approved задач бэклога одним проверяемым проходом.")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Цель слоя: не идти по очереди, а отдать независимые workpacks существующему parallel dispatcher.')
  [void]$sb.AppendLine('Правила:')
  [void]$sb.AppendLine('- Не обходи safety: если задача стала нерелевантной или опасной, явно скажи это в отчёте.')
  [void]$sb.AppendLine('- Для независимых пунктов в первом ходе выдай STATUS: CONTINUE и отдельные [[PARALLEL:<id>]] блоки.')
  [void]$sb.AppendLine('- В каждом [[PARALLEL]] блоке обязательно укажи Files: с разрешёнными файлами/touch set.')
  [void]$sb.AppendLine('- После merge обычные verify/critic/smoke gates должны подтвердить общий результат.')
  [void]$sb.AppendLine('- Каждый поток в конце должен оставить краткий итог и полезные PROJECT_* memory-маркеры, если появились новые решения/риски/проверки.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Шаблон первого ответа для planner-а: скопируй эти блоки, если задачи всё ещё независимы.')
  [void]$sb.AppendLine('')
  $idx = 0
  foreach ($item in $itemsArr) {
    $idx++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    $packId = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_id' -Default '')
    $group = [string](Get-BacklogPackObjectValue -Obj $item -Name 'workpack_conflict_group' -Default 'general')
    $touches = @(Get-BacklogWorkpackItemTouches -Item $item)
    if ($touches.Count -eq 0) { $touches = @($group) }
    $files = ($touches | Select-Object -First 8) -join ', '
    $deps = @(Get-BacklogTaskDependencySlugs -Item $item)
    $chapter = [string](Get-BacklogPackObjectValue -Obj $item -Name 'chapter' -Default '')
    $wave = [string](Get-BacklogPackObjectValue -Obj $item -Name 'wave' -Default '')
    $parallelGroup = [string](Get-BacklogPackObjectValue -Obj $item -Name 'parallel_group' -Default '')
    $checks = @()
    try { $checks = @(Get-BacklogPackObjectValue -Obj $item -Name 'verification_checks' -Default @() | ForEach-Object { [string]$_ }) } catch { $checks = @() }
    $acceptance = @()
    try { $acceptance = @(Get-BacklogPackObjectValue -Obj $item -Name 'acceptance_checks' -Default @() | ForEach-Object { [string]$_ }) } catch { $acceptance = @() }
    $text = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'text' -Default '') -replace '\s+', ' ').Trim()
    [void]$sb.AppendLine(("ITEM {0}: backlog_id={1}" -f $idx, $id))
    [void]$sb.AppendLine(("workpack={0}; conflict_group={1}" -f $packId, $group))
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$sb.AppendLine(("Chapter: {0}" -f $chapter)) }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$sb.AppendLine(("Wave: {0}" -f $wave)) }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$sb.AppendLine(("Parallel group: {0}" -f $parallelGroup)) }
    if ($deps.Count -gt 0) { [void]$sb.AppendLine(("Depends on: {0}" -f (($deps | Select-Object -First 8) -join ', '))) }
    [void]$sb.AppendLine(("Files: {0}" -f $files))
    if ($acceptance.Count -gt 0) { [void]$sb.AppendLine(("Acceptance: {0}" -f (($acceptance | Select-Object -First 4) -join ' ; '))) }
    if ($checks.Count -gt 0) { [void]$sb.AppendLine(("Checks: {0}" -f (($checks | Select-Object -First 4) -join ' ; '))) }
    [void]$sb.AppendLine(("Task: {0}" -f $text))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("[[PARALLEL:wp{0}]]" -f $idx))
    [void]$sb.AppendLine(("Files: {0}" -f $files))
    if ($checks.Count -gt 0) { [void]$sb.AppendLine(("Checks: {0}" -f (($checks | Select-Object -First 4) -join ' ; '))) }
    if ($acceptance.Count -gt 0) { [void]$sb.AppendLine(("Acceptance: {0}" -f (($acceptance | Select-Object -First 4) -join ' ; '))) }
    # 2026-06-01 AUTONOMY: complexity now inferred per-task (was hardcoded 'moderate' for every
    # stream, which made the worker router blind to real task difficulty). Drives Select-WorkerForStream.
    $cx = 'moderate'
    try { if (Get-Command Get-TaskComplexityHeuristic -ErrorAction SilentlyContinue) { $cx = Get-TaskComplexityHeuristic -Text $text -TouchCount (@($touches).Count) } } catch {}
    [void]$sb.AppendLine(("Complexity: {0}" -f $cx))
    [void]$sb.AppendLine(("Task: {0}" -f $text))
    [void]$sb.AppendLine(("[[/PARALLEL:wp{0}]]" -f $idx))
    [void]$sb.AppendLine('')
  }
  [void]$sb.AppendLine('STATUS: CONTINUE')
  return $sb.ToString().Trim()
}

function Add-Idea {
  # Append a backlog idea. Returns a string id. On dedup returns the matched existing id.
  param(
    [string]$Text,
    [string]$From = 'agent',
    [string[]]$Tags = @(),
    [string]$Status = 'new',
    [double]$Score = 0.0,
    [string]$Project = '',
    [string]$Scope = 'bridge',
    # 2026-05-28: severity ('critical' | 'warning' | 'info' | '') -- used by the picker
    # so audit findings outrank regular ideas (critical before warning before info before plain).
    [ValidateSet('critical','warning','info','')]
    [string]$Severity = '',
    [switch]$SkipCurator
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  Ensure-BacklogPathFunction
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

  # Anti-junk: refuse to re-file an idea near-identical to one the curator SUBSTANTIVELY rejected
  # within dedupDroppedDays — this kills the propose->drop->propose loop. Logged, not stored.
  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'rejected-recently') {
    Write-BacklogJsonLine ([ordered]@{ ts = $now; action = 'rejected-recently'; new_text = [string]$Text; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity })
    Write-LastAddIdeaMarker ([ordered]@{ ts = $now; rejected_recently = $true; matched_id = [string]$keep.matched_id; similarity = [double]$keep.similarity })
    return $null
  }

  $rec = [ordered]@{
    id       = [guid]::NewGuid().ToString('N')
    ts       = $now
    from     = $From
    status   = $Status
    tags     = @($Tags)
    attempts = 0
    score    = $Score
    project  = $Project
    scope    = $Scope
    text     = [string]$Text
  }
  if (-not [string]::IsNullOrWhiteSpace($Severity)) {
    $rec.severity = ([string]$Severity).ToLowerInvariant()
  }
  if (-not $SkipCurator -and $keep -and [string]$keep.action -eq 'similar') {
    $rec.similar_to = @($keep.similar_to)
  }
  # 2026-05-27: critic-flagged fix. Same BOM issue as in Write-BacklogJsonLine
  # plus a real risk: $rec is a hashtable here (fresh, not from ConvertFrom-Json
  # so no ETS-graph), but consumers re-read via Get-Backlog → PSCustomObject;
  # downstream Save-Backlog also uses Depth 10 — both lowered to 6.
  $line = ($rec | ConvertTo-Json -Compress -Depth 6)
  $u8NoBomA = New-Object System.Text.UTF8Encoding($false)
  # 2026-05-28: resolve the backlog path BEFORE building the closure. .GetNewClosure()
  # captures variables from the enclosing scope but NOT functions — when the
  # closure is later invoked via `& $ScriptBlock` from Invoke-BacklogLocked
  # (which runs in a child scope), Get-BacklogPath isn't visible there. Audit
  # findings dropped silently with "Get-BacklogPath not recognized" every time
  # the helper was loaded via inline dot-source (audit.ps1, curator launcher).
  # Resolving up-front captures the path as a value and sidesteps the lookup.
  $backlogPathForAppend = Resolve-BacklogPathValue
  Invoke-BacklogLocked ({ [System.IO.File]::AppendAllText($backlogPathForAppend, ($line + "`n"), $u8NoBomA) }.GetNewClosure()) | Out-Null

  $curatorStarted = $false
  if (-not $SkipCurator) {
    $curatorStarted = Start-BacklogCuratorJob -ItemId ([string]$rec.id)
  }
  Write-LastAddIdeaMarker ([ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    deduped = $false
    id = [string]$rec.id
    similar_to = @($rec.similar_to)
    curator_started = [bool]$curatorStarted
  })
  try { Request-BacklogPackIfNeeded -NewItemId ([string]$rec.id) | Out-Null } catch {}
  return [string]$rec.id
}

function Get-Backlog {
  # 2026-06-01 ROOT FIX (re-claim loop): backlog.jsonl is an append-log, so a task can have MULTIPLE
  # lines with the same id (status transitions: running -> approved -> done, plus operator re-adds /
  # concurrent writes from 3 drivers + curator + packer on the OneDrive-hosted file). The old reader
  # returned EVERY line as a separate item, so a stale 'approved' duplicate survived next to a fresh
  # 'done' line — the claim picker saw the 'approved' copy and re-ran an already-finished task forever
  # (observed: redesign-rest 16/18 delivered + closed, yet re-claimed every cycle; 23 duplicate ids in
  # the file). Fold by id with LAST-line-wins so each id collapses to its newest status. Save-Backlog
  # then rewrites the folded set, healing the duplicates on the next mutation.
  Ensure-BacklogPathFunction
  $p = Resolve-BacklogPathValue
  if (-not (Test-Path $p)) { return @() }
  $byId = New-Object 'System.Collections.Specialized.OrderedDictionary'
  $noId = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $i = $line | ConvertFrom-Json } catch { continue }
    $iid = ''
    try { $iid = [string]$i.id } catch { $iid = '' }
    if ([string]::IsNullOrWhiteSpace($iid)) { [void]$noId.Add($i); continue }
    # last line for this id wins; keep first-seen ORDER so the picker's ordering is stable
    if ($byId.Contains($iid)) { $byId[$iid] = $i } else { $byId.Add($iid, $i) }
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in $byId.Keys) { [void]$out.Add($byId[$k]) }
  foreach ($v in $noId) { [void]$out.Add($v) }
  return @($out.ToArray())
}

function Save-Backlog {
  # 2026-05-27: Depth 10 → 6. Items here come from Get-Backlog (PSCustomObject
  # from ConvertFrom-Json) — depth 10 on PSCO can recurse into ETS graph. Item
  # schema actual depth ≤ 3 (id/text/status/auto_curator{verdict/reason/...}),
  # so 6 is safe and gives margin.
  param($Items)
  Ensure-BacklogPathFunction
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  # 2026-05-28: resolve path before closure (see Add-Idea note about scope).
  $backlogPathForSave = Resolve-BacklogPathValue
  Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path $backlogPathForSave -Content $content }.GetNewClosure()) | Out-Null
}

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
    $cfg = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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

function Get-ProjectAutopilotConfig {
  $cfg = [ordered]@{
    enabled = $true
    cooldownMinutes = 5
    maxTasksPerBatch = 12
    emptyCoordinatorLimit = 3
  }
  $dotted = @{
    'projectAutopilot.enabled' = 'enabled'
    'projectAutopilot.cooldownMinutes' = 'cooldownMinutes'
    'projectAutopilot.maxTasksPerBatch' = 'maxTasksPerBatch'
    'projectAutopilot.emptyCoordinatorLimit' = 'emptyCoordinatorLimit'
  }
  $flat = @{
    projectAutopilotEnabled = 'enabled'
    projectAutopilotCooldownMinutes = 'cooldownMinutes'
    projectAutopilotMaxTasksPerBatch = 'maxTasksPerBatch'
    projectAutopilotEmptyCoordinatorLimit = 'emptyCoordinatorLimit'
  }
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.cooldownMinutes = ConvertTo-BacklogPackInt -Value $cfg.cooldownMinutes -Default 5 -Min 1 -Max 240
  $cfg.maxTasksPerBatch = ConvertTo-BacklogPackInt -Value $cfg.maxTasksPerBatch -Default 12 -Min 1 -Max 50
  $cfg.emptyCoordinatorLimit = ConvertTo-BacklogPackInt -Value $cfg.emptyCoordinatorLimit -Default 3 -Min 1 -Max 20
  return [pscustomobject]$cfg
}

function Get-ProjectAutopilotStatePath {
  $dir = ''
  try { $dir = Split-Path -Parent (Get-BacklogPath) } catch {}
  if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-BacklogFallbackBridgeRoot }
  return (Join-Path $dir 'project-autopilot.last.json')
}

function Read-ProjectAutopilotState {
  $p = Get-ProjectAutopilotStatePath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-ProjectAutopilotState {
  param($State)
  try {
    $json = ($State | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path (Get-ProjectAutopilotStatePath) -Content $json
  } catch {}
}

function Test-ProjectAutopilotCoordinatorItem {
  param($Item)
  if (-not $Item) { return $false }
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  return (Test-ProjectAutopilotCoordinatorText -Text $text)
}

function Test-ProjectAutopilotCoordinatorText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return [bool]($Text -match '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel')
}

function Test-ProjectAutopilotCoordinatorHasChildren {
  param(
    [string]$CoordinatorId,
    [object[]]$Items
  )
  if ([string]::IsNullOrWhiteSpace($CoordinatorId)) { return $false }
  foreach ($it in @($Items)) {
    $src = [string](Get-BacklogPackObjectValue -Obj $it -Name 'autopilot_source_task' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($src) -and $src -eq $CoordinatorId) { return $true }
  }
  return $false
}

function Get-ProjectAutopilotInferredEmptyCoordinatorStreak {
  param([string]$ExcludeCoordinatorId = '')
  $items = @(Get-Backlog)
  $coordinators = @($items |
    Where-Object {
      (Test-ProjectAutopilotCoordinatorItem -Item $_) -and
      ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'id' -Default '') -ne [string]$ExcludeCoordinatorId)
    } |
    Sort-Object {
      try { [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $_ -Name 'ts' -Default '')).ToUniversalTime() } catch { [datetime]::MinValue }
    } -Descending)

  $streak = 0
  foreach ($it in $coordinators) {
    $status = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($status -in @('approved','running','new')) { continue }
    if ($status -ne 'done') { break }
    $id = [string](Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default '')
    if (Test-ProjectAutopilotCoordinatorHasChildren -CoordinatorId $id -Items $items) { break }
    $streak++
  }
  return $streak
}

function Get-ProjectAutopilotStateInt {
  param($State, [string]$Name, [int]$Default = 0)
  if (-not $State) { return $Default }
  try {
    if ($State.PSObject.Properties.Name -contains $Name) {
      return [int]($State.$Name)
    }
  } catch {}
  return $Default
}

function Get-ProjectAutopilotRecentOutcomes {
  param($State)
  if (-not $State) { return @() }
  try { return @($State.recent_outcomes | Where-Object { $_ }) } catch { return @() }
}

function Record-ProjectAutopilotCoordinatorOutcome {
  param(
    [string]$Channel = '',
    [string]$ProjectRoot = '',
    [string]$CoordinatorId = '',
    [int]$Created = 0,
    [string]$Reason = 'coordinator-done'
  )
  $cfg = Get-ProjectAutopilotConfig
  $limit = [Math]::Max(1, [Math]::Min(20, [int]$cfg.emptyCoordinatorLimit))
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-ProjectAutopilotSlug }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    try {
      $binding = Get-ProjectAutopilotBinding
      if ($binding) { $ProjectRoot = [string]$binding.project_root }
    } catch {}
  }

  $last = Read-ProjectAutopilotState
  if (-not $last) { $last = [pscustomobject]@{} }
  $recent = @(Get-ProjectAutopilotRecentOutcomes -State $last)
  if (-not [string]::IsNullOrWhiteSpace($CoordinatorId)) {
    foreach ($r in $recent) {
      if ([string](Get-BacklogPackObjectValue -Obj $r -Name 'id' -Default '') -eq $CoordinatorId) {
        return [pscustomobject]@{
          recorded = $false
          reason = 'already-recorded'
          paused = [bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)
          empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
          limit = $limit
        }
      }
    }
  }

  $createdCount = [Math]::Max(0, [int]$Created)
  $hasStateStreak = $false
  try { $hasStateStreak = ($last.PSObject.Properties.Name -contains 'empty_coordinator_streak') } catch {}
  $streak = 0
  if ($hasStateStreak) {
    $streak = Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0
    try {
      $inferredForState = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak -ExcludeCoordinatorId $CoordinatorId)
      if ($inferredForState -gt $streak) { $streak = $inferredForState }
    } catch {}
  } else {
    try { $streak = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak -ExcludeCoordinatorId $CoordinatorId) } catch { $streak = 0 }
  }

  $wasPaused = [bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)
  $paused = $wasPaused
  $pauseReason = [string](Get-BacklogPackObjectValue -Obj $last -Name 'pause_reason' -Default '')
  $pausedAt = [string](Get-BacklogPackObjectValue -Obj $last -Name 'paused_at' -Default '')
  $outcome = 'empty'

  if ($createdCount -gt 0) {
    $streak = 0
    $paused = $false
    $pauseReason = ''
    $pausedAt = ''
    $outcome = 'created'
  } else {
    $streak++
    if ($streak -ge $limit) {
      $paused = $true
      if ([string]::IsNullOrWhiteSpace($pausedAt)) { $pausedAt = (Get-Date).ToUniversalTime().ToString('o') }
      $pauseReason = "empty coordinator streak reached $streak/$limit without PROJECT_BACKLOG"
    }
  }

  $now = (Get-Date).ToUniversalTime().ToString('o')
  $recent += [pscustomobject]@{
    id = [string]$CoordinatorId
    ts = $now
    created = $createdCount
    outcome = $outcome
  }
  $recent = @($recent | Select-Object -Last 10)

  $last | Add-Member -NotePropertyName ts -NotePropertyValue $now -Force
  $last | Add-Member -NotePropertyName channel -NotePropertyValue ([string]$Channel) -Force
  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $last | Add-Member -NotePropertyName project_root -NotePropertyValue ([string]$ProjectRoot) -Force }
  $last | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue ([int]$streak) -Force
  $last | Add-Member -NotePropertyName paused -NotePropertyValue ([bool]$paused) -Force
  $last | Add-Member -NotePropertyName paused_at -NotePropertyValue ([string]$pausedAt) -Force
  $last | Add-Member -NotePropertyName pause_reason -NotePropertyValue ([string]$pauseReason) -Force
  $last | Add-Member -NotePropertyName recent_outcomes -NotePropertyValue @($recent) -Force
  $last | Add-Member -NotePropertyName last_outcome_id -NotePropertyValue ([string]$CoordinatorId) -Force
  $last | Add-Member -NotePropertyName last_outcome_created -NotePropertyValue ([int]$createdCount) -Force
  $last | Add-Member -NotePropertyName last_outcome_reason -NotePropertyValue ([string]$Reason) -Force
  Write-ProjectAutopilotState $last

  try {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'project-autopilot-outcome'
      channel = [string]$Channel
      item_id = [string]$CoordinatorId
      created = [int]$createdCount
      empty_coordinator_streak = [int]$streak
      paused = [bool]$paused
      limit = [int]$limit
    })
  } catch {}

  if ($paused -and -not $wasPaused) {
    try {
      Write-BacklogJsonLine ([ordered]@{ ts=$now; action='project-autopilot-paused'; channel=[string]$Channel; item_id=[string]$CoordinatorId; reason=$pauseReason })
    } catch {}
    try {
      Add-Message -From system -Text ("⏸ Project Autopilot: проектный backlog исчерпан; последние " + [int]$streak + " coordinator-задачи не создали PROJECT_BACKLOG. Автопилот канала " + [string]$Channel + " поставлен на паузу. Нужно расширить PROJECT_PLAN/scope или вручную добавить задачи.") -Kind event | Out-Null
    } catch {}
  }

  return [pscustomobject]@{
    recorded = $true
    reason = $outcome
    created = [int]$createdCount
    paused = [bool]$paused
    empty_coordinator_streak = [int]$streak
    limit = [int]$limit
  }
}

function Get-ProjectAutopilotSlug {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { return [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-ProjectAutopilotBinding {
  $slug = Get-ProjectAutopilotSlug
  if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'main') { return $null }
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      $b = Get-ChannelProjectBinding -Slug $slug
      if ($b -and [bool]$b.ok -and -not [string]::IsNullOrWhiteSpace([string]$b.project_root)) { return $b }
    }
  } catch {}
  return $null
}

function Get-ProjectAutopilotBacklogPressure {
  $items = @(Get-Backlog)
  $approved = 0; $running = 0; $new = 0; $held = 0; $autopilotOpen = 0
  foreach ($it in $items) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    $tags = @()
    try { $tags = @($it.tags | ForEach-Object { [string]$_ }) } catch { $tags = @() }
    if ($st -eq 'approved') { $approved++ }
    elseif ($st -eq 'running') { $running++ }
    elseif ($st -eq 'new') { $new++ }
    elseif ($st -eq 'held') { $held++ }
    if (($st -eq 'approved' -or $st -eq 'running') -and ($tags -contains 'project-autopilot')) { $autopilotOpen++ }
  }
  return [pscustomobject]@{
    approved = $approved
    running = $running
    new = $new
    held = $held
    runnable = ($approved + $running)
    autopilot_open = $autopilotOpen
  }
}

function Test-ProjectAutopilotProjectClean {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $false }
  try {
    $git = 'git'
    try { if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { $git = Get-GitExe } } catch { $git = 'git' }
    $dirty = @(& $git -C $ProjectRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return ($dirty.Count -eq 0)
  } catch {
    return $false
  }
}

function Get-ProjectAutopilotPlanContractPath {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  return (Join-Path (Join-Path $ProjectRoot '.bridge') 'project-contract.json')
}

function Get-ProjectAutopilotPlanningStageDefinitions {
  return @(
    [pscustomobject]@{ id='brief';       path='PROJECT_BRIEF.md';       min_chars=800;  label='project brief' },
    [pscustomobject]@{ id='product';     path='DISCUSS_PRODUCT.md';     min_chars=900;  label='product discussion' },
    [pscustomobject]@{ id='ux';          path='DISCUSS_UX.md';          min_chars=900;  label='UX discussion' },
    [pscustomobject]@{ id='ui';          path='DISCUSS_UI.md';          min_chars=800;  label='UI discussion' },
    [pscustomobject]@{ id='backend';     path='DISCUSS_BACKEND.md';     min_chars=900;  label='backend discussion' },
    [pscustomobject]@{ id='qa';          path='DISCUSS_QA.md';          min_chars=800;  label='QA/acceptance discussion' },
    [pscustomobject]@{ id='integration'; path='DISCUSS_INTEGRATION.md'; min_chars=800;  label='cross-stage integration review' }
  )
}

function Get-ProjectAutopilotPlanSignatureFiles {
  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($stage in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    [void]$files.Add([string]$stage.path)
  }
  foreach ($rel in @('PROJECT_MAP.md','PROJECT_PLAN.md','.bridge\project-contract.json')) {
    [void]$files.Add([string]$rel)
  }
  return @($files.ToArray())
}

function Get-ProjectAutopilotFileText {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return '' }
}

function Get-ProjectAutopilotSha256 {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
  } catch {
    return ''
  }
}

function Get-ProjectAutopilotPlanSignature {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rel in @(Get-ProjectAutopilotPlanSignatureFiles)) {
    $path = Join-Path $ProjectRoot $rel
    [void]$parts.Add($rel.Replace('\','/') + "`n" + (Get-ProjectAutopilotFileText -Path $path))
  }
  return (Get-ProjectAutopilotSha256 -Text (($parts.ToArray()) -join "`n---bridge-plan-part---`n"))
}

function Get-ProjectAutopilotGitHead {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return '' }
  try {
    $head = (& git -C $ProjectRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string]$head).Trim()
  } catch {
    return ''
  }
}

function Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead {
  param([string]$ProjectRoot, [string]$GitHead)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($GitHead)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='missing-input' }
  }
  if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='project-root-missing' }
  }
  try {
    $verify = (& git -C $ProjectRoot rev-parse --verify ($GitHead + '^{commit}') 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$verify)) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='approval-git-head-not-found' }
    }
    $files = @(Get-ProjectAutopilotPlanSignatureFiles | ForEach-Object { ([string]$_).Replace('\','/') })
    if ($files.Count -eq 0) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='no-plan-files' }
    }
    $args = @('-C', $ProjectRoot, 'diff', '--quiet', $GitHead, '--') + $files
    & git @args 2>$null
    $exit = [int]$LASTEXITCODE
    if ($exit -eq 0) { return [pscustomobject]@{ ok=$true; unchanged=$true; reason='unchanged' } }
    if ($exit -eq 1) { return [pscustomobject]@{ ok=$true; unchanged=$false; reason='plan-files-changed' } }
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason=('git-diff-exit-' + [string]$exit) }
  } catch {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='git-diff-error' }
  }
}

function Get-ProjectAutopilotContractValue {
  param($Obj, [string[]]$Names = @(), $Default = $null)
  if (-not $Obj) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if ($Obj.PSObject.Properties.Name -contains $name) {
        $v = $Obj.PSObject.Properties[$name].Value
        if ($null -ne $v) { return $v }
      }
    } catch {}
  }
  return $Default
}

function Get-ProjectAutopilotContractCount {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return 0 }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return 0 }
      return 1
    }
    if ($v -is [System.Collections.IDictionary]) { return [int]$v.Count }
    $arr = @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($arr.Count -gt 0) { return [int]$arr.Count }
  } catch {}
  try {
    if ($v.PSObject.Properties.Count -gt 0) { return [int]$v.PSObject.Properties.Count }
  } catch {}
  return 0
}

function Get-ProjectAutopilotContractArray {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return @() }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return @() }
      return @([string]$v)
    }
    return @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotPlanningStageById {
  param($PlanningFlow)
  $map = @{}
  $stages = @(Get-ProjectAutopilotContractArray -Obj $PlanningFlow -Names @('stages','planning_stages','discussions'))
  foreach ($stage in @($stages)) {
    $id = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('id','stage','name') -Default '')).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $stage }
  }
  return $map
}

function Invoke-ProjectAutopilotDeliveryContractValidation {
  param($Contract, $Context = $null)
  if (Get-Command Test-DeliveryContract -ErrorAction SilentlyContinue) {
    return (Test-DeliveryContract -Contract $Contract -Context $Context)
  }

  $candidates = @()
  try {
    $root = Get-BacklogFallbackBridgeRoot
    if (-not [string]::IsNullOrWhiteSpace($root)) { $candidates += (Join-Path $root 'lib\delivery-contract.ps1') }
  } catch {}
  try {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidates += (Join-Path $PSScriptRoot 'delivery-contract.ps1') }
  } catch {}
  try {
    $cwd = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($cwd)) { $candidates += (Join-Path $cwd 'lib\delivery-contract.ps1') }
  } catch {}

  foreach ($candidate in @($candidates | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      . $candidate
      if (Get-Command Test-DeliveryContract -ErrorAction SilentlyContinue) {
        return (Test-DeliveryContract -Contract $Contract -Context $Context)
      }
    } catch {
      throw
    }
  }

  throw 'delivery-contract validator unavailable'
}

function Test-ProjectPlanContractReady {
  param([string]$ProjectRoot)
  $issues = New-Object 'System.Collections.Generic.List[string]'
  $mapPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_MAP.md' }
  $planPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_PLAN.md' }
  $contractPath = Get-ProjectAutopilotPlanContractPath -ProjectRoot $ProjectRoot
  $mapText = Get-ProjectAutopilotFileText -Path $mapPath
  $planText = Get-ProjectAutopilotFileText -Path $planPath
  $contract = $null
  $deliveryContractOk = $false
  $deliveryContractScore = $null
  $deliveryContractMissing = @()
  $deliveryContractWarnings = @()
  $deliveryContractBlockers = @()
  $deliveryContractRequiredSections = @()

  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    [void]$issues.Add('project_root is missing')
  }
  if ($mapText.Length -lt 1500) {
    [void]$issues.Add('PROJECT_MAP.md is missing or too shallow (<1500 chars)')
  }
  if ($planText.Length -lt 2000) {
    [void]$issues.Add('PROJECT_PLAN.md is missing or too shallow (<2000 chars)')
  }

  $stageDocLengths = [ordered]@{}
  foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    $stagePath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot ([string]$stageDef.path) }
    $stageText = Get-ProjectAutopilotFileText -Path $stagePath
    $stageDocLengths[[string]$stageDef.id] = [int]$stageText.Length
    if ($stageText.Length -lt [int]$stageDef.min_chars) {
      [void]$issues.Add(([string]$stageDef.path + ' is missing or too shallow (<' + [string]$stageDef.min_chars + ' chars)'))
    }
  }

  if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    [void]$issues.Add('.bridge/project-contract.json is missing')
  } else {
    try {
      $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      [void]$issues.Add('.bridge/project-contract.json is not valid JSON')
    }
  }

  $goalText = ''
  $reqCount = 0
  $surfaceCount = 0
  $journeyCount = 0
  $acceptanceCount = 0
  $interfaceCount = 0
  $planningStageCount = 0
  if ($contract) {
    try {
      $deliveryResult = Invoke-ProjectAutopilotDeliveryContractValidation -Contract $contract -Context @{
        RequireParallelPolicy = $true
        RequireExplicitProjectSections = $true
      }
      $deliveryContractOk = [bool]$deliveryResult.ok
      $deliveryContractScore = [int]$deliveryResult.score
      $deliveryContractMissing = @($deliveryResult.missing)
      $deliveryContractWarnings = @($deliveryResult.warnings)
      $deliveryContractBlockers = @($deliveryResult.blockers)
      $deliveryContractRequiredSections = @($deliveryResult.required_sections)
      if (-not $deliveryContractOk) {
        [void]$issues.Add('delivery-contract score=' + [string]$deliveryContractScore)
        if ($deliveryContractMissing.Count -gt 0) { [void]$issues.Add('delivery-contract missing: ' + ($deliveryContractMissing -join ', ')) }
        if ($deliveryContractBlockers.Count -gt 0) { [void]$issues.Add('delivery-contract blockers: ' + ($deliveryContractBlockers -join ', ')) }
        if ($deliveryContractWarnings.Count -gt 0) { [void]$issues.Add('delivery-contract warnings: ' + ($deliveryContractWarnings -join ', ')) }
      }
    } catch {
      $deliveryContractOk = $false
      $msg = [string]$_.Exception.Message
      if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'unavailable' }
      if ($msg -eq 'delivery-contract validator unavailable') {
        [void]$issues.Add('delivery-contract validator unavailable')
      } else {
        [void]$issues.Add('delivery-contract validator error: ' + $msg)
      }
    }

    $goalText = [string](Get-ProjectAutopilotContractValue -Obj $contract -Names @('project_goal','goal','mission','outcome') -Default '')
    $reqCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('requirements','capabilities','features','functional_requirements'))
    $surfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('screens','routes','views','surfaces','pages','endpoints','modules'))
    $journeyCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('user_journeys','journeys','flows','workflows','scenarios'))
    $acceptanceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('acceptance_scenarios','acceptance','done_criteria','checks','quality_gates'))
    $interfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('ux_contract','ux','interface_contract','experience_principles','interaction_model'))
    $planningFlow = Get-ProjectAutopilotContractValue -Obj $contract -Names @('planning_flow','planningFlow','discussion_flow') -Default $null
    $stageById = Get-ProjectAutopilotPlanningStageById -PlanningFlow $planningFlow
    $planningStageCount = [int]$stageById.Count
    if ($goalText.Trim().Length -lt 40) { [void]$issues.Add('project contract goal is missing or too short') }
    if ($reqCount -lt 3) { [void]$issues.Add('project contract needs at least 3 requirements/capabilities/features') }
    if ($surfaceCount -lt 2) { [void]$issues.Add('project contract needs at least 2 screens/routes/interfaces/modules') }
    if ($journeyCount -lt 2) { [void]$issues.Add('project contract needs at least 2 user journeys/workflows/scenarios') }
    if ($acceptanceCount -lt 3) { [void]$issues.Add('project contract needs at least 3 acceptance scenarios/checks') }
    if ($interfaceCount -lt 1) { [void]$issues.Add('project contract needs ux_contract or interface_contract') }
    if (-not $planningFlow) {
      [void]$issues.Add('project contract needs planning_flow with staged discussions')
    } else {
      foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
        $sid = [string]$stageDef.id
        if (-not $stageById.ContainsKey($sid)) {
          [void]$issues.Add('planning_flow missing stage: ' + $sid)
          continue
        }
        $stage = $stageById[$sid]
        $status = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('status','state') -Default '')).Trim().ToLowerInvariant()
        $summary = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('summary','outcome','decision_summary') -Default '')).Trim()
        if ($status -notin @('complete','approved','done')) { [void]$issues.Add('planning_flow stage not complete: ' + $sid) }
        if ($summary.Length -lt 40) { [void]$issues.Add('planning_flow stage summary too short: ' + $sid) }
      }
      $integration = $null
      try { if ($stageById.ContainsKey('integration')) { $integration = $stageById['integration'] } } catch {}
      $integrationDeps = @(Get-ProjectAutopilotContractArray -Obj $integration -Names @('depends_on','dependsOn','validated_stages'))
      if ($integrationDeps.Count -lt 5) { [void]$issues.Add('planning_flow integration stage must depend on/validate prior stages') }
    }
  }

  return [pscustomobject]@{
    ready = ($issues.Count -eq 0)
    issues = @($issues.ToArray())
    signature = (Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot)
    map_path = $mapPath
    plan_path = $planPath
    contract_path = $contractPath
    delivery_contract_ok = $deliveryContractOk
    delivery_contract_score = $deliveryContractScore
    delivery_contract_missing = @($deliveryContractMissing)
    delivery_contract_warnings = @($deliveryContractWarnings)
    delivery_contract_blockers = @($deliveryContractBlockers)
    delivery_contract_required_sections = @($deliveryContractRequiredSections)
    counts = [pscustomobject]@{
      requirements = $reqCount
      surfaces = $surfaceCount
      journeys = $journeyCount
      acceptance = $acceptanceCount
      interface_contract = $interfaceCount
      planning_stages = $planningStageCount
      stage_doc_lengths = [pscustomobject]$stageDocLengths
    }
  }
}

function New-ProjectAutopilotCoordinatorTaskText {
  param([string]$Slug, [string]$ProjectRoot, [int]$MaxTasks = 12)
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  return @"
[project-autopilot $Slug] [[NORMAL]]

Project Autopilot coordinator for channel '$Slug'.

Work only in $ProjectRoot.

Mission: keep this project moving without the operator manually feeding backlog items.

Plan gate status:
- This coordinator is queued only after the channel-level Discuss-First plan gate has approved the current PROJECT_PLAN signature.
- Treat channels/$Slug/channel.json plan_approved=true and its approved signature as the source of truth for execution permission.
- If PROJECT_PLAN.md, PROJECT_MAP.md, or .bridge/project-contract.json still contain pre-approval wording such as "not approved", "UNAPPROVED", or "planned, not approved", do not treat that wording as a blocker after this coordinator has been queued. Use those words as historical planning status unless the channel gate itself is not approved.

Rules:
- Do NOT implement feature code in this coordinator task, except small durable planning docs such as CHAPTER_N_ATOMS.md.
- Read PROJECT_BRIEF.md, DISCUSS_PRODUCT.md, DISCUSS_UX.md, DISCUSS_UI.md, DISCUSS_BACKEND.md, DISCUSS_QA.md, DISCUSS_INTEGRATION.md, PROJECT_MAP.md, PROJECT_PLAN.md, .bridge/project-contract.json, existing CHAPTER_*_ATOMS.md files, README, git log/status, and current code.
- Read the project memory/context supplied in the prompt. Preserve durable decisions, risks, invariants, tests, and open questions.
- Treat .bridge/project-contract.json as the machine-readable product/UX/acceptance contract. It must describe explicit scope plus explicit non_goals, explicit users/roles/personas, data/backend ownership, checks, risk, parallel_policy, requirements/capabilities, screens/routes/interfaces/modules, user journeys/workflows, ux_contract/interface_contract, and acceptance scenarios.
- requirements/capabilities/features do NOT replace explicit scope plus non_goals. user_journeys/journeys/flows/workflows do NOT replace explicit users/roles/personas/actors.
- Treat planning as staged: brief -> product -> UX -> UI -> backend -> QA -> integration. Every later stage must explicitly use decisions from earlier stages. The integration stage resolves cross-stage conflicts before implementation.
- If the stage docs, map, plan, or contract are shallow/missing/stale, do NOT emit implementation atoms. Emit durable memory about the gap and finish, or emit docs-only planning atoms that deepen PROJECT_BRIEF.md, DISCUSS_*.md, PROJECT_MAP.md, PROJECT_PLAN.md, and .bridge/project-contract.json.
- Determine the next approved/incomplete chapter from the contract and plan, not from a guessed feature list.
- Decompose only ONE next chapter/wave into small atomic implementation tasks. Prefer 3-$max tasks; fewer is OK if the chapter is small.
- Each atom must be a small verifiable change, with clear dependencies, files/touch-set, acceptance checks, and commit requirement.
- Model the execution DAG explicitly: independent atoms have empty depends_on; dependent atoms reference prerequisite slugs.
- Prefer a ready frontier: several independent atoms in the same wave, then dependent atoms in later waves.
- Use chapter, wave, parallel_group, files, depends_on, acceptance, checks, risk/severity, and serial_reason so the scheduler can run the team safely.
- Every atom acceptance must trace back to a project-contract requirement, journey, surface, or acceptance scenario. Do not use generic "looks good" UX checks.
- Before PROJECT_BACKLOG, emit durable project memory markers when useful:
  [[PROJECT_DECISION: ...]]
  [[PROJECT_RISK: ...]]
  [[PROJECT_INVARIANT: ...]]
  [[PROJECT_TEST: ...]]
  [[PROJECT_OPEN_QUESTION: ...]]
  Keep memory concise and durable; do not store transient progress noise.
- If a product decision is truly blocking, do not invent it: emit [[PROJECT_OPEN_QUESTION: ...]] and finish without PROJECT_BACKLOG.
- Never put real secrets, local DB files, uploads, .next, or node_modules in git.
- For Next.js/TypeScript work, each atom should normally require npm run typecheck and npm run build unless the atom is docs-only.

When you have the next atom batch, output it as STRICT JSON inside this exact marker:
[[PROJECT_BACKLOG]]
[
  {
    "slug": "short-stable-atom-id",
    "title": "Human readable atom title",
    "task": "Full task text for the worker. Include project path, dependencies, acceptance checks, and commit requirement.",
    "chapter": "approved chapter / project area",
    "wave": "wave-1",
    "parallel_group": "auth|gallery|chat|admin|docs|tests|...",
    "files": ["relative/path/or/directory"],
    "depends_on": ["slug-of-prerequisite-if-any"],
    "acceptance": ["observable acceptance criterion tied to the approved contract"],
    "checks": ["npm run typecheck", "npm run build"],
    "risk": "normal",
    "severity": "normal",
    "serial_reason": "",
    "workpack_touch_set": ["relative/path/or/directory"],
    "workpack_conflict_group": "file:relative/path/or/directory"
  }
]
[[/PROJECT_BACKLOG]]

depends_on may be []; serial_reason may be "" for parallel atoms. acceptance/checks must be concrete, not generic "looks good". files must be the real touch-set / scheduler-allowed paths. workpack_touch_set and workpack_conflict_group are optional explicit scheduler metadata; omit them unless files alone would be ambiguous. Incomplete atoms are rejected by the deterministic ingest gate.

The driver will add those atoms to approved project backlog automatically. Do not use operator-delegate and do not edit backlog.jsonl manually.

Finish with STATUS: DONE after emitting the marker, or STATUS: DONE without the marker if no work remains.
"@
}

function Test-ProjectPlanApproved {
  # 2026-06-02: Discuss-First gate for Project Autopilot. Autopilot only EXPANDS a PROJECT_PLAN the
  # operator has explicitly APPROVED (flow phase Ф4). Without approval the bridge stays in discuss/
  # planning and does NOT auto-generate/execute atoms — this keeps autopilot UNDER Discuss-First, not
  # instead of it, and prevents it from scaling an un-vetted plan into a frankenstein (observed on
  # private-community: 246 files build-green but product-incoherent because the plan skipped Ф1–Ф4).
  # Reads channels/<ch>/channel.json -> plan_approved. Default $false = safe (no approval => no autopilot).
  param([string]$Channel, [string]$ProjectRoot = '')
  try {
    $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
    if (-not (Test-Path -LiteralPath $cj)) { return $false }
    $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $raw -or -not ($raw.PSObject.Properties.Name -contains 'plan_approved') -or -not [bool]$raw.plan_approved) { return $false }
    $approvedSignature = ''
    try {
      if ($raw.PSObject.Properties.Name -contains 'plan_approved_signature') { $approvedSignature = [string]$raw.plan_approved_signature }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($approvedSignature) -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
      $currentSignature = Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot
      if ([string]::IsNullOrWhiteSpace($currentSignature)) { return $false }
      if ($currentSignature -ne $approvedSignature) {
        $approvedGitHead = ''
        try {
          if ($raw.PSObject.Properties.Name -contains 'plan_approved_git_head') { $approvedGitHead = [string]$raw.plan_approved_git_head }
        } catch {}
        $unchanged = Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead -ProjectRoot $ProjectRoot -GitHead $approvedGitHead
        if (-not ([bool]$unchanged.ok -and [bool]$unchanged.unchanged)) { return $false }
      }
    }
    return $true
  } catch {}
  return $false
}

function Set-ProjectPlanApproved {
  # Operator action at Discuss-First Ф4: mark a channel's PROJECT_PLAN approved so Project Autopilot may
  # begin executing it. Also stamps the approved time. To re-gate (force re-approval), pass -Approved:$false.
  param([string]$Channel, [bool]$Approved = $true)
  $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
  if (-not (Test-Path -LiteralPath $cj)) { throw "channel.json not found: $Channel" }
  $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $projectRoot = ''
  try {
    if ($raw -and ($raw.PSObject.Properties.Name -contains 'project_root')) { $projectRoot = [string]$raw.project_root }
  } catch {}
  try {
    if ([string]::IsNullOrWhiteSpace($projectRoot) -and (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue)) {
      $binding = Get-ChannelProjectBinding -Slug $Channel
      if ($binding -and [bool]$binding.ok) { $projectRoot = [string]$binding.project_root }
    }
  } catch {}
  $contractReady = $null
  if ($Approved) {
    $contractReady = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
    if (-not [bool]$contractReady.ready) {
      throw ("project plan contract is not ready: " + ((@($contractReady.issues) | Select-Object -First 8) -join '; '))
    }
  }
  $raw | Add-Member -NotePropertyName plan_approved -NotePropertyValue $Approved -Force
  $raw | Add-Member -NotePropertyName plan_approved_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
  if ($Approved -and $contractReady) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue ([string]$contractReady.signature) -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue 'staged-v1' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @(Get-ProjectAutopilotPlanSignatureFiles) -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue (Get-ProjectAutopilotGitHead -ProjectRoot $projectRoot) -Force
    $raw | Add-Member -NotePropertyName plan_contract_path -NotePropertyValue ([string]$contractReady.contract_path) -Force
    $raw | Add-Member -NotePropertyName plan_contract_score -NotePropertyValue $contractReady.delivery_contract_score -Force
    $raw | Add-Member -NotePropertyName plan_contract_required_sections -NotePropertyValue @($contractReady.delivery_contract_required_sections) -Force
  } elseif (-not $Approved) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @() -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue '' -Force
  }
  [System.IO.File]::WriteAllText($cj, (($raw | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  # clear the one-time gate-notified marker so a future re-gate (plan rewrite) notifies the operator again
  try { $gm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-gate-notified'; if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Force -ErrorAction SilentlyContinue } } catch {}
  try { $cm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-contract-gate-notified'; if (Test-Path -LiteralPath $cm) { Remove-Item -LiteralPath $cm -Force -ErrorAction SilentlyContinue } } catch {}
  return $Approved
}

function Start-ProjectAutopilotIfNeeded {
  param([string]$Reason = 'idle-empty-backlog')
  $cfg = Get-ProjectAutopilotConfig
  if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ queued=$false; reason='disabled' } }
  $binding = Get-ProjectAutopilotBinding
  if (-not $binding) { return [pscustomobject]@{ queued=$false; reason='not-project-channel' } }
  $slug = [string]$binding.slug
  $root = [string]$binding.project_root
  # 2026-06-02 DISCUSS-FIRST GATE: autopilot only executes an operator-APPROVED PROJECT_PLAN (Ф4).
  # Until the operator runs Set-ProjectPlanApproved for this channel, the bridge stays in discuss/
  # planning and autopilot does NOT auto-queue coordinator/atoms. This is the fix for autopilot
  # bypassing Ф1–Ф4 and scaling an un-vetted plan into a frankenstein.
  if (-not (Test-ProjectPlanApproved -Channel $slug -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='plan-not-approved'; channel=$slug }
  }
  $planContract = Test-ProjectPlanContractReady -ProjectRoot $root
  if (-not [bool]$planContract.ready) {
    return [pscustomobject]@{
      queued = $false
      reason = 'plan-contract-not-ready'
      channel = $slug
      project_root = $root
      issues = @($planContract.issues)
      contract_path = [string]$planContract.contract_path
      delivery_contract_ok = $planContract.delivery_contract_ok
      delivery_contract_score = $planContract.delivery_contract_score
      delivery_contract_missing = @($planContract.delivery_contract_missing)
      delivery_contract_warnings = @($planContract.delivery_contract_warnings)
      delivery_contract_blockers = @($planContract.delivery_contract_blockers)
      delivery_contract_required_sections = @($planContract.delivery_contract_required_sections)
    }
  }

  $pressure = Get-ProjectAutopilotBacklogPressure
  if ([int]$pressure.runnable -gt 0) { return [pscustomobject]@{ queued=$false; reason='backlog-not-empty'; pressure=$pressure } }
  if ([int]$pressure.autopilot_open -gt 0) { return [pscustomobject]@{ queued=$false; reason='autopilot-already-open'; pressure=$pressure } }

  $last = Read-ProjectAutopilotState
  if ($last) {
    try {
      if ([bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)) {
        return [pscustomobject]@{
          queued = $false
          reason = 'paused-empty-scope'
          empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
          pause_reason = [string](Get-BacklogPackObjectValue -Obj $last -Name 'pause_reason' -Default '')
          pressure = $pressure
        }
      }
    } catch {}
    try {
      $stateStreakExisting = Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0
      $inferredEmptyExisting = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmptyExisting -gt $stateStreakExisting) {
        if ($inferredEmptyExisting -ge [int]$cfg.emptyCoordinatorLimit) {
          $nowPauseExisting = (Get-Date).ToUniversalTime().ToString('o')
          $last | Add-Member -NotePropertyName ts -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName channel -NotePropertyValue $slug -Force
          $last | Add-Member -NotePropertyName project_root -NotePropertyValue $root -Force
          $last | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue $inferredEmptyExisting -Force
          $last | Add-Member -NotePropertyName paused -NotePropertyValue $true -Force
          $last | Add-Member -NotePropertyName paused_at -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName pause_reason -NotePropertyValue ("legacy empty coordinator streak reached $inferredEmptyExisting/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG") -Force
          if (-not ($last.PSObject.Properties.Name -contains 'recent_outcomes')) { $last | Add-Member -NotePropertyName recent_outcomes -NotePropertyValue @() -Force }
          Write-ProjectAutopilotState $last
          try {
            Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmptyExisting + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
          } catch {}
          return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmptyExisting; pressure=$pressure }
        }
      }
    } catch {}
    try {
      $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
      $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
      if ($ageMin -lt [int]$cfg.cooldownMinutes) {
        return [pscustomobject]@{ queued=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
      }
    } catch {}
  } else {
    try {
      $inferredEmpty = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmpty -ge [int]$cfg.emptyCoordinatorLimit) {
        $nowPause = (Get-Date).ToUniversalTime().ToString('o')
        $pauseState = [pscustomobject]@{
          ts = $nowPause
          channel = $slug
          project_root = $root
          queued_id = ''
          reason = [string]$Reason
          empty_coordinator_streak = $inferredEmpty
          paused = $true
          paused_at = $nowPause
          pause_reason = "legacy empty coordinator streak reached $inferredEmpty/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG"
          recent_outcomes = @()
        }
        Write-ProjectAutopilotState $pauseState
        try {
          Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmpty + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
        } catch {}
        return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmpty; pressure=$pressure }
      }
    } catch {}
  }

  if (-not (Test-ProjectAutopilotProjectClean -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='project-dirty-or-git-unavailable'; pressure=$pressure }
  }

  $task = New-ProjectAutopilotCoordinatorTaskText -Slug $slug -ProjectRoot $root -MaxTasks ([int]$cfg.maxTasksPerBatch)
  $id = Add-Idea -Text $task -From 'project-autopilot' -Tags @('project-autopilot','auto-generated') -Status 'approved' -Severity 'critical' -Project $slug -Scope 'project' -SkipCurator
  if ([string]::IsNullOrWhiteSpace([string]$id)) { return [pscustomobject]@{ queued=$false; reason='add-idea-failed'; pressure=$pressure } }

  $st = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    channel = $slug
    project_root = $root
    queued_id = [string]$id
    reason = [string]$Reason
    empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
    paused = $false
    paused_at = ''
    pause_reason = ''
    recent_outcomes = @(Get-ProjectAutopilotRecentOutcomes -State $last)
  }
  Write-ProjectAutopilotState ([pscustomobject]$st)
  try {
    Write-BacklogJsonLine ([ordered]@{ ts=$st.ts; action='project-autopilot-queued'; channel=$slug; item_id=[string]$id; reason=[string]$Reason })
  } catch {}
  try {
    Add-Message -From system -Text ("🧭 Project Autopilot: backlog пуст, поставил coordinator-задачу " + [string]$id + " для следующей главы проекта.") -Kind event | Out-Null
  } catch {}
  return [pscustomobject]@{ queued=$true; id=[string]$id; reason=[string]$Reason; pressure=$pressure }
}

function ConvertTo-ProjectAutopilotSlug {
  param([string]$Text)
  $v = ([string]$Text).Trim().ToLowerInvariant()
  $v = $v -replace '[^a-z0-9а-яё._-]+','-'
  $v = $v.Trim([char[]]@('-','_','.'))
  if ($v.Length -gt 80) { $v = $v.Substring(0,80).Trim([char[]]@('-','_','.')) }
  if ([string]::IsNullOrWhiteSpace($v)) {
    try {
      $sha = [System.Security.Cryptography.SHA1]::Create()
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
      $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
      $v = 'atom-' + $hash.Substring(0,10)
    } catch { $v = 'atom-' + ([guid]::NewGuid().ToString('N').Substring(0,10)) }
  }
  return $v
}

function Get-ProjectAutopilotTaskArrayFromMarker {
  param([string]$Block)
  $raw = ([string]$Block).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $raw = ($raw -replace '```json','' -replace '```','').Trim()
  $json = ''
  $arrMatch = [regex]::Match($raw, '(?s)\[.*\]')
  if ($arrMatch.Success) { $json = $arrMatch.Value }
  else {
    $objMatch = [regex]::Match($raw, '(?s)\{.*\}')
    if ($objMatch.Success) { $json = $objMatch.Value }
  }
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }
  try {
    $parsed = $json | ConvertFrom-Json
    if ($parsed -is [array]) { return @($parsed) }
    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'tasks') { return @($parsed.tasks) }
    return @($parsed)
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotTaskStringField {
  param($Task, [string[]]$Names = @())
  foreach ($name in @($Names)) {
    try {
      $v = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null
      if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    } catch {}
  }
  return ''
}

function Get-ProjectAutopilotTaskStringArray {
  param($Task, [string[]]$Names = @())
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @($Names)) {
    $raw = $null
    try { $raw = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null } catch { $raw = $null }
    if ($null -eq $raw) { continue }
    foreach ($v in @($raw)) {
      $s = ([string]$v).Trim()
      if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$out.Add($s) }
    }
    if ($out.Count -gt 0) { break }
  }
  return @($out.ToArray() | Sort-Object -Unique)
}

function ConvertTo-ProjectAutopilotPathArray {
  param($Values)
  return @(@($Values) |
    ForEach-Object { ([string]$_).Replace('\','/').Trim().ToLowerInvariant() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
}

function ConvertTo-ProjectAutopilotSlugArray {
  param($Values)
  return @(@($Values) |
    Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ConvertTo-ProjectAutopilotSlug ([string]$_) } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
}

function Get-ProjectAutopilotTaskRisk {
  param($Task)
  $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('risk')
  if ([string]::IsNullOrWhiteSpace($risk)) {
    $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('severity')
  }
  switch (([string]$risk).Trim().ToLowerInvariant()) {
    'critical' { return 'critical' }
    'high' { return 'high' }
    'warning' { return 'high' }
    'medium' { return 'normal' }
    'normal' { return 'normal' }
    'low' { return 'low' }
    'info' { return 'low' }
    default { return 'normal' }
  }
}

function Test-ProjectAutopilotTaskMetadata {
  param($Task)
  $missing = New-Object 'System.Collections.Generic.List[string]'
  $slug = ConvertTo-ProjectAutopilotSlug (Get-ProjectAutopilotTaskStringField -Task $Task -Names @('slug'))
  $title = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('title')
  $body = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('task')
  $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $Task -Name 'files' -Default @()))
  $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
  $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
  $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('risk','severity')

  if ([string]::IsNullOrWhiteSpace($slug)) { [void]$missing.Add('slug') }
  if ([string]::IsNullOrWhiteSpace($title)) { [void]$missing.Add('title') }
  if ([string]::IsNullOrWhiteSpace($body)) { [void]$missing.Add('task') }
  if ($files.Count -eq 0) { [void]$missing.Add('files') }
  if ($acceptance.Count -eq 0) { [void]$missing.Add('acceptance') }
  if ($checks.Count -eq 0) { [void]$missing.Add('checks') }
  if ([string]::IsNullOrWhiteSpace($risk)) { [void]$missing.Add('risk') }

  return [pscustomobject]@{
    ok      = ($missing.Count -eq 0)
    missing = @($missing.ToArray())
  }
}

function Set-ProjectAutopilotIdeaMetadata {
  param([string]$Id, $Task, [string]$SourceTaskId = '')
  if ([string]::IsNullOrWhiteSpace($Id) -or -not $Task) { return $false }
  return (Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    $found = $false
    foreach ($i in $items) {
      if ([string]$i.id -ne $Id) { continue }
      $found = $true
      $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $Task -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $Id)))
      $title = [string](Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $slug)
      $body = [string](Get-BacklogPackObjectValue -Obj $Task -Name 'task' -Default '')
      if ([string]::IsNullOrWhiteSpace($body)) { $body = $title }
      $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $Task -Name 'files' -Default @()))
      $deps = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $Task -Name 'depends_on' -Default @()))
      $chapter = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('chapter','phase','area')
      $wave = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('wave','milestone')
      $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('parallel_group','lane','workstream')
      $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
      $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
      $risk = Get-ProjectAutopilotTaskRisk -Task $Task
      $serialReason = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('serial_reason')
      $explicitTouch = @(ConvertTo-ProjectAutopilotPathArray (Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('workpack_touch_set','touch_set')))
      $explicitGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('workpack_conflict_group')
      $i | Add-Member -NotePropertyName slug -NotePropertyValue $slug -Force
      $i | Add-Member -NotePropertyName title -NotePropertyValue $title -Force
      $i | Add-Member -NotePropertyName task -NotePropertyValue $body -Force
      $i | Add-Member -NotePropertyName autopilot_generated -NotePropertyValue $true -Force
      $i | Add-Member -NotePropertyName autopilot_source_task -NotePropertyValue ([string]$SourceTaskId) -Force
      $i | Add-Member -NotePropertyName files -NotePropertyValue ([object[]]@($files)) -Force
      $i | Add-Member -NotePropertyName depends_on -NotePropertyValue ([object[]]@($deps)) -Force
      $i | Add-Member -NotePropertyName risk -NotePropertyValue $risk -Force
      $i | Add-Member -NotePropertyName serial_reason -NotePropertyValue $serialReason -Force
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $i | Add-Member -NotePropertyName chapter -NotePropertyValue $chapter -Force }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $i | Add-Member -NotePropertyName wave -NotePropertyValue $wave -Force }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $i | Add-Member -NotePropertyName parallel_group -NotePropertyValue $parallelGroup -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance_checks -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName verification_checks -NotePropertyValue @($checks) -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName checks -NotePropertyValue @($checks) -Force }
      $touchSet = if ($explicitTouch.Count -gt 0) { @($explicitTouch) } else { @($files) }
      if ($touchSet.Count -gt 0) {
        $group = if (-not [string]::IsNullOrWhiteSpace($explicitGroup)) { [string]$explicitGroup } else { 'file:' + [string]$touchSet[0] }
        $i | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue ([object[]]@($touchSet)) -Force
        $i | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue $group -Force
        $i | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ('serial:' + $group) -Force
      }
      $meta = [ordered]@{}
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $meta.chapter = $chapter }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $meta.wave = $wave }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $meta.parallel_group = $parallelGroup }
      $meta.depends_on = @($deps)
      if ($files.Count -gt 0) { $meta.files = @($files) }
      if ($acceptance.Count -gt 0) { $meta.acceptance = @($acceptance) }
      if ($checks.Count -gt 0) { $meta.checks = @($checks) }
      $meta.risk = $risk
      $meta.serial_reason = $serialReason
      if ($meta.Count -gt 0) { $i | Add-Member -NotePropertyName autopilot_meta -NotePropertyValue ([pscustomobject]$meta) -Force }
      break
    }
    if ($found) { Save-Backlog $items }
    return $found
  }.GetNewClosure()))
}

function Add-ProjectBacklogFromMarker {
  param(
    [string]$Block,
    [string]$Channel = '',
    [string]$Source = 'agent',
    [string]$SourceTaskId = '',
    [int]$MaxTasks = 12
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-ProjectAutopilotSlug }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $isBridgeSelfBacklog = (([string]$Channel).Trim().ToLowerInvariant() -eq 'main')
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  $tasks = @(Get-ProjectAutopilotTaskArrayFromMarker -Block $Block | Select-Object -First $max)
  if ($tasks.Count -eq 0) { return [pscustomobject]@{ created=0; skipped=0; errors=@('no valid JSON tasks found'); ids=@() } }

  $existing = @(Get-Backlog)
  $existingSlugs = @{}
  foreach ($it in $existing) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($st -in @('rejected','auto-dropped','failed')) { continue }
    $sl = [string](Get-BacklogPackObjectValue -Obj $it -Name 'slug' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sl)) { $existingSlugs[$sl] = $true }
  }

  $created = New-Object 'System.Collections.Generic.List[string]'
  $createdSlugs = New-Object 'System.Collections.Generic.List[string]'
  $createdChapters = New-Object 'System.Collections.Generic.List[string]'
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $skipped = 0
  foreach ($t in $tasks) {
    $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default '')))
    $metadataCheck = Test-ProjectAutopilotTaskMetadata -Task $t
    if (-not [bool]$metadataCheck.ok) {
      $label = if ([string]::IsNullOrWhiteSpace($slug)) { '(missing-slug)' } else { $slug }
      [void]$errors.Add(("incomplete PROJECT_BACKLOG atom '{0}': missing {1}" -f $label, ((@($metadataCheck.missing) | Sort-Object -Unique) -join ', ')))
      $skipped++
      continue
    }
    if ($existingSlugs.ContainsKey($slug)) { $skipped++; continue }
    $title = [string](Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default $slug)
    $body = [string](Get-BacklogPackObjectValue -Obj $t -Name 'task' -Default '')
    if ([string]::IsNullOrWhiteSpace($body)) { $body = $title }
    if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -lt 40) { [void]$errors.Add("task '$slug' too short"); continue }
    $severity = ([string](Get-BacklogPackObjectValue -Obj $t -Name 'severity' -Default '')).ToLowerInvariant()
    if ($severity -eq 'normal') { $severity = '' }
    if ($severity -notin @('critical','warning','info','')) { $severity = '' }
    $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $t -Name 'files' -Default @()))
    $deps = @(ConvertTo-ProjectAutopilotSlugArray (Get-ProjectAutopilotTaskStringArray -Task $t -Names @('depends_on','dependencies')))
    $chapter = Get-ProjectAutopilotTaskStringField -Task $t -Names @('chapter','phase','area')
    $wave = Get-ProjectAutopilotTaskStringField -Task $t -Names @('wave','milestone')
    $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $t -Names @('parallel_group','lane','workstream')
    $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('acceptance','acceptance_checks','criteria'))
    $checks = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('checks','verify','verification'))
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$detailLines.Add("Chapter: $chapter") }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$detailLines.Add("Wave: $wave") }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$detailLines.Add("Parallel group: $parallelGroup") }
    if ($deps.Count -gt 0) { [void]$detailLines.Add("Depends on: " + (($deps | Select-Object -First 12) -join ', ')) }
    if ($acceptance.Count -gt 0) { [void]$detailLines.Add("Acceptance: " + (($acceptance | Select-Object -First 6) -join ' ; ')) }
    if ($checks.Count -gt 0) { [void]$detailLines.Add("Checks: " + (($checks | Select-Object -First 6) -join ' ; ')) }
    $detailLine = if ($detailLines.Count -gt 0) { "`n`n" + (($detailLines.ToArray()) -join "`n") } else { '' }
    $fileLine = if ($files.Count -gt 0) { "`n`nFiles: " + (($files | Select-Object -First 12) -join ', ') } else { '' }
    $text = "[project-autopilot $slug] [[NORMAL]]`n`n$title`n`n$body$detailLine$fileLine"
    $ideaTags = @('project-autopilot','auto-generated','atom')
    $ideaProject = [string]$Channel
    $ideaScope = 'project'
    if ($isBridgeSelfBacklog) {
      $ideaTags = @('project-autopilot','auto-generated','atom','bridge-self')
      $ideaProject = 'main'
      $ideaScope = 'bridge'
    }
    $id = Add-Idea -Text $text -From 'project-autopilot' -Tags $ideaTags -Status 'approved' -Severity $severity -Project $ideaProject -Scope $ideaScope -SkipCurator
    if ([string]::IsNullOrWhiteSpace([string]$id)) { [void]$errors.Add("Add-Idea failed for '$slug'"); continue }
    try { Set-ProjectAutopilotIdeaMetadata -Id ([string]$id) -Task $t -SourceTaskId $SourceTaskId | Out-Null } catch {}
    $existingSlugs[$slug] = $true
    [void]$created.Add([string]$id)
    [void]$createdSlugs.Add($slug)
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$createdChapters.Add($chapter) }
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='project-backlog-add'; channel=$Channel; item_id=[string]$id; slug=$slug; source=$Source }) } catch {}
  }

  try { Request-BacklogPackIfNeeded | Out-Null } catch {}
  return [pscustomobject]@{ created=$created.Count; skipped=$skipped; errors=@($errors.ToArray()); ids=@($created.ToArray()); slugs=@($createdSlugs.ToArray()); chapters=@($createdChapters.ToArray() | Sort-Object -Unique) }
}

function Get-OperatorBatchProgress {
  # Progress of operator-delegated batches for the pulse: per batch id, how many done/total.
  $items = @(Get-Backlog | Where-Object { @($_.tags) -contains 'operator' })
  $byBatch = @{}
  foreach ($it in $items) {
    $bid = @($it.tags | Where-Object { $_ -like 'batch:*' } | Select-Object -First 1)
    $bid = if ($bid.Count) { [string]$bid[0] } else { 'batch:?' }
    if (-not $byBatch.ContainsKey($bid)) { $byBatch[$bid] = [pscustomobject]@{ total = 0; done = 0; failed = 0; running = 0 } }
    $byBatch[$bid].total++
    switch ([string]$it.status) {
      'done'         { $byBatch[$bid].done++ }
      'auto-resolved'{ $byBatch[$bid].done++ }
      'failed'       { $byBatch[$bid].failed++ }
      'running'      { $byBatch[$bid].running++ }
    }
  }
  return $byBatch
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
  # auto-claim of them unless the OPERATOR explicitly delegated (tag 'operator'). Deterministic.
  param($Idea)
  $t = ''
  try { $t = ([string]$Idea.text).ToLowerInvariant() } catch {}
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  $cpPat = '(watchdog|supervisor|process[_ -]?supervision|runtime[_ -]?incident|circuit[_ -]?break|restart[_ -]?limit|script[_ -]?integrit|concurrent.{0,4}driver|control[_ -]?plane|driver\.ps1|server\.ps1|supervisor\.ps1|watchdog\.ps1|circuit-breaker\.ps1|kill-bridge|self[_ -]?edit)'
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

function Get-IdeaById {
  param([string]$Id)
  foreach ($i in @(Get-Backlog)) { if ([string]$i.id -eq $Id) { return $i } }
  return $null
}
