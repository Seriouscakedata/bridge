# 12-workpack-exec.ps1 -- Workpack batch selection and batch task prompt creation.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

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
  try {
    if (Get-Command Get-BacklogTaskTargetFile -ErrorAction SilentlyContinue) {
      $tgt = [string](Get-BacklogTaskTargetFile -Text ([string]$Item.text))
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
      foreach ($f in @(Get-BacklogMentionedFiles -Text ([string]$Item.text))) {
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

function Get-NextBacklogWorkpackBatch {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogWorkpackExecConfig }
  if (-not [bool]$Config.enabled) { return $null }

  $allItems = @(Get-Backlog)
  $eligible = @(
    $allItems |
    Where-Object { Test-BacklogWorkpackExecEligible -Item $_ -Config $Config } |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}}
  )
  if ($eligible.Count -lt [int]$Config.minItems) { return $null }

  $statusBySlug = Get-BacklogSlugStatusMap -Items $allItems
  $selected = New-Object 'System.Collections.Generic.List[object]'
  $usedGroups = @{}
  $usedTouches = New-Object 'System.Collections.Generic.List[string]'
  $readyCount = 0
  $dependencyWait = 0
  $structuralWait = 0
  $conflictSkips = 0
  $touchSkips = 0
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

  if ($selected.Count -lt [int]$Config.minItems) { return $null }
  $ids = @($selected.ToArray() | ForEach-Object { [string]$_.id })
  $packs = @($selected.ToArray() | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
  $groups = @($selected.ToArray() | ForEach-Object { [string]$_.workpack_conflict_group } | Sort-Object -Unique)
  return [pscustomobject]@{
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
