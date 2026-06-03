# 11-workpack-classify.ps1 -- Workpack file inference, classification, and reclassification.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

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
  $rx = '(?im)(?:перепиши|создай|реализуй|оформлени[ея]|приведи)[^\n]{0,90}?((?:src|app|content|public|prisma|config|styles|components|pages|api|lib)[\\/][\w./\-\[\]]+\.\w{1,5})'
  $m = [regex]::Match($t, $rx)
  if ($m.Success) { return ($m.Groups[1].Value -replace '\\', '/') }
  return ''
}

function Get-BacklogWorkpackConflictGroup {
  param([string]$Text, [string[]]$Files = @())
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
  $fileList = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in @(Get-BacklogMentionedFiles -Text $text | Sort-Object)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
  foreach ($f in @(Get-BacklogInferredFiles -Text $text)) { Add-BacklogWorkpackFileCandidate -List $fileList -Path $f }
  $files = @($fileList.ToArray())
  $module = Get-BacklogWorkpackModule -Text $text -Files $files
  $touch = @()
  $key = ''
  if ($files.Count -gt 0) {
    # 2026-05-31 (Foundation #4): prefer the task's TARGET file (after the action verb) over an
    # эталон/reference path, so independent tasks land in distinct workpacks and run in parallel.
    $primary = Get-BacklogTaskTargetFile -Text $text
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
  $conflict = Get-BacklogWorkpackConflictGroup -Text $text -Files $files
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
