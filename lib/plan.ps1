$script:PlanStatuses = @('pending','in_progress','done','blocked','skipped')

function Get-PlanPath {
  if (Get-Command Get-ChannelPlanPath -ErrorAction SilentlyContinue) { return (Get-ChannelPlanPath) }
  return (Join-Path (Get-BridgeRoot) 'plan.jsonl')
}
function Get-PlanArchivePath {
  if (Get-Command Get-ChannelPlanArchivePath -ErrorAction SilentlyContinue) { return (Get-ChannelPlanArchivePath) }
  return (Join-Path (Get-BridgeRoot) 'plan.archive.jsonl')
}

function Normalize-PlanText {
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  return (($Text -replace '\s+', ' ').Trim())
}

function Normalize-PlanStatus {
  param([string]$Status)
  $s = (Normalize-PlanText $Status).ToLowerInvariant()
  if ($script:PlanStatuses -contains $s) { return $s }
  return 'pending'
}

function Get-PlanProperty {
  param($Object, [string]$Name, $Default = $null)
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $Default
}

function Set-PlanProperty {
  param($Object, [string]$Name, $Value)
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-PlanParentFromId {
  param([string]$Id, [string]$Fallback)
  $id2 = Normalize-PlanText $Id
  $idx = $id2.LastIndexOf('.')
  if ($idx -gt 0) { return $id2.Substring(0, $idx) }
  if ([string]::IsNullOrWhiteSpace($Fallback)) { return $null }
  return $Fallback
}

function ConvertFrom-PlanBlock {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  $match = [regex]::Match($Text, '(?is)\[\[PLAN\]\](.*?)\[\[/PLAN\]\]')
  if (-not $match.Success) { return $null }

  $nodes = New-Object 'System.Collections.Generic.List[object]'
  $seen = @{}
  $currentEpic = $null
  $currentTask = $null

  foreach ($rawLine in ($match.Groups[1].Value -split "\r?\n")) {
    $line = (Normalize-PlanText $rawLine)
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $m = [regex]::Match($line, '^(?i:(EPIC|TASK|STEP))\s+([A-Za-z0-9._-]+)\s*:\s*(.*)$')
    if (-not $m.Success) { continue }

    $kind = $m.Groups[1].Value.ToLowerInvariant()
    $id = Normalize-PlanText $m.Groups[2].Value
    if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }

    $parts = @($m.Groups[3].Value -split '\|' | ForEach-Object { Normalize-PlanText $_ })
    $depsList = New-Object 'System.Collections.Generic.List[string]'
    $contentParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in $parts) {
      if ([string]::IsNullOrWhiteSpace($part)) { continue }
      $dm = [regex]::Match($part, '^(?i:deps)\s*:\s*(.*)$')
      if ($dm.Success) {
        foreach ($depRaw in ($dm.Groups[1].Value -split ',')) {
          $dep = Normalize-PlanText $depRaw
          if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $depsList.Contains($dep)) { [void]$depsList.Add($dep) }
        }
      } else {
        [void]$contentParts.Add($part)
      }
    }

    $title = ''
    if ($contentParts.Count -gt 0) { $title = $contentParts[0] }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $id }

    $criteria = ''
    if ($kind -ne 'epic' -and $contentParts.Count -gt 1) {
      $criteriaParts = New-Object 'System.Collections.Generic.List[string]'
      for ($i = 1; $i -lt $contentParts.Count; $i++) { [void]$criteriaParts.Add($contentParts[$i]) }
      $criteria = Normalize-PlanText ($criteriaParts.ToArray() -join ' | ')
    }

    $parent = $null
    if ($kind -eq 'epic') {
      $currentEpic = $id
      $currentTask = $null
    } elseif ($kind -eq 'task') {
      $parent = Get-PlanParentFromId -Id $id -Fallback $currentEpic
      $currentTask = $id
    } else {
      $parent = Get-PlanParentFromId -Id $id -Fallback $currentTask
    }

    [void]$seen.Add($id, $true)
    [void]$nodes.Add([pscustomobject][ordered]@{
      type     = $kind
      id       = $id
      parent   = $parent
      title    = $title
      criteria = $criteria
      deps     = [object[]]@($depsList.ToArray())
      status   = 'pending'
      result   = ''
      ts       = ''
    })
  }

  if ($nodes.Count -eq 0) { return $null }
  return @($nodes.ToArray())
}

function Read-PlanRecordsUnlocked {
  $path = Get-PlanPath
  if (-not (Test-Path -LiteralPath $path)) { return @() }

  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $rec = $line | ConvertFrom-Json
      if ($null -ne $rec) { [void]$records.Add($rec) }
    } catch {}
  }
  return @($records.ToArray())
}

function Write-PlanRecordsUnlocked {
  param($Records)
  $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
  $content = if ($lines.Count -gt 0) { ($lines -join "`n") + "`n" } else { '' }
  Write-AtomicFile -Path (Get-PlanPath) -Content $content
}

function Get-RolledPlanStatus {
  param([string[]]$ChildStatuses, [string]$FallbackStatus)
  $statuses = @($ChildStatuses | ForEach-Object { Normalize-PlanStatus $_ })
  if ($statuses.Count -eq 0) { return (Normalize-PlanStatus $FallbackStatus) }
  if (@($statuses | Where-Object { $_ -ne 'done' }).Count -eq 0) { return 'done' }
  if (@($statuses | Where-Object { $_ -eq 'blocked' }).Count -gt 0 -and @($statuses | Where-Object { $_ -eq 'done' -or $_ -eq 'in_progress' }).Count -eq 0) { return 'blocked' }
  if (@($statuses | Where-Object { $_ -eq 'in_progress' -or $_ -eq 'done' -or $_ -eq 'blocked' -or $_ -eq 'skipped' }).Count -gt 0) { return 'in_progress' }
  return 'pending'
}

function ConvertTo-PlanNode {
  param($Record, [string]$Status)
  $parent = Get-PlanProperty $Record 'parent' $null
  $deps = @()
  $rawDeps = Get-PlanProperty $Record 'deps' @()
  if ($null -ne $rawDeps) { $deps = @($rawDeps | ForEach-Object { [string]$_ }) }

  return [pscustomobject][ordered]@{
    type     = [string](Get-PlanProperty $Record 'type' '')
    id       = [string](Get-PlanProperty $Record 'id' '')
    parent   = $parent
    title    = [string](Get-PlanProperty $Record 'title' '')
    criteria = [string](Get-PlanProperty $Record 'criteria' '')
    deps     = [object[]]$deps
    status   = (Normalize-PlanStatus $Status)
    result   = [string](Get-PlanProperty $Record 'result' '')
    ts       = [string](Get-PlanProperty $Record 'ts' '')
  }
}

function ConvertTo-PlanObject {
  param($Records)
  $meta = $null
  $rawNodes = New-Object 'System.Collections.Generic.List[object]'

  foreach ($rec in @($Records)) {
    $type = ([string](Get-PlanProperty $rec 'type' '')).ToLowerInvariant()
    if ($type -eq 'meta' -and $null -eq $meta) { $meta = $rec; continue }
    if ($type -eq 'epic' -or $type -eq 'task' -or $type -eq 'step') { [void]$rawNodes.Add($rec) }
  }
  if ($null -eq $meta) { return $null }

  $statusById = @{}
  for ($i = $rawNodes.Count - 1; $i -ge 0; $i--) {
    $node = $rawNodes[$i]
    $id = [string](Get-PlanProperty $node 'id' '')
    $type = ([string](Get-PlanProperty $node 'type' '')).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($id)) { continue }

    if ($type -eq 'step') {
      $statusById[$id] = Normalize-PlanStatus ([string](Get-PlanProperty $node 'status' 'pending'))
      continue
    }

    $childStatuses = New-Object 'System.Collections.Generic.List[string]'
    foreach ($child in $rawNodes) {
      if ([string](Get-PlanProperty $child 'parent' '') -ne $id) { continue }
      $childId = [string](Get-PlanProperty $child 'id' '')
      if ($statusById.ContainsKey($childId)) { [void]$childStatuses.Add([string]$statusById[$childId]) }
      else { [void]$childStatuses.Add([string](Get-PlanProperty $child 'status' 'pending')) }
    }
    $statusById[$id] = Get-RolledPlanStatus -ChildStatuses $childStatuses.ToArray() -FallbackStatus ([string](Get-PlanProperty $node 'status' 'pending'))
  }

  $nodes = New-Object 'System.Collections.Generic.List[object]'
  foreach ($node in $rawNodes) {
    $id = [string](Get-PlanProperty $node 'id' '')
    $status = if ($statusById.ContainsKey($id)) { [string]$statusById[$id] } else { [string](Get-PlanProperty $node 'status' 'pending') }
    [void]$nodes.Add((ConvertTo-PlanNode -Record $node -Status $status))
  }

  return [pscustomobject][ordered]@{
    meta  = $meta
    nodes = @($nodes.ToArray())
  }
}

function New-Plan {
  param([string]$Task, $Nodes)
  $nodeArray = @($Nodes)
  $now = (Get-Date).ToUniversalTime().ToString('o')

  return Use-BridgeLock ({
    $records = New-Object 'System.Collections.Generic.List[object]'
    [void]$records.Add([pscustomobject][ordered]@{
      type    = 'meta'
      task    = [string]$Task
      created = $now
      updated = $now
      version = 1
    })

    $seen = @{}
    $stepCount = 0
    foreach ($node in $nodeArray) {
      $type = ([string](Get-PlanProperty $node 'type' '')).ToLowerInvariant()
      if ($type -ne 'epic' -and $type -ne 'task' -and $type -ne 'step') { continue }

      $id = Normalize-PlanText ([string](Get-PlanProperty $node 'id' ''))
      if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
      [void]$seen.Add($id, $true)

      $parent = Get-PlanProperty $node 'parent' $null
      $deps = @()
      $rawDeps = Get-PlanProperty $node 'deps' @()
      if ($null -ne $rawDeps) {
        $depSeen = @{}
        foreach ($depRaw in @($rawDeps)) {
          $dep = Normalize-PlanText ([string]$depRaw)
          if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $depSeen.ContainsKey($dep)) {
            [void]$depSeen.Add($dep, $true)
            $deps += $dep
          }
        }
      }

      if ($type -eq 'step') { $stepCount++ }
      [void]$records.Add([pscustomobject][ordered]@{
        type     = $type
        id       = $id
        parent   = $parent
        title    = Normalize-PlanText ([string](Get-PlanProperty $node 'title' $id))
        criteria = Normalize-PlanText ([string](Get-PlanProperty $node 'criteria' ''))
        deps     = [object[]]$deps
        status   = 'pending'
        result   = ''
        ts       = $now
      })
    }

    Write-PlanRecordsUnlocked $records
    return $stepCount
  }.GetNewClosure())
}

function Get-Plan {
  $path = Get-PlanPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $records = @(Use-BridgeLock { Read-PlanRecordsUnlocked })
  if ($records.Count -eq 0) { return $null }
  return (ConvertTo-PlanObject $records)
}

function Set-PlanStepStatus {
  param(
    [string]$Id,
    [ValidateSet('pending','in_progress','done','blocked','skipped')] [string]$Status,
    [string]$Result
  )
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $status2 = Normalize-PlanStatus $Status
  $hasResult = $PSBoundParameters.ContainsKey('Result')

  return [bool](Use-BridgeLock ({
    $records = @(Read-PlanRecordsUnlocked)
    if ($records.Count -eq 0) { return $false }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $found = $false
    foreach ($rec in $records) {
      $type = ([string](Get-PlanProperty $rec 'type' '')).ToLowerInvariant()
      if ($type -eq 'meta') {
        Set-PlanProperty -Object $rec -Name 'updated' -Value $now
        continue
      }
      if ($type -eq 'step' -and [string](Get-PlanProperty $rec 'id' '') -eq $Id) {
        Set-PlanProperty -Object $rec -Name 'status' -Value $status2
        Set-PlanProperty -Object $rec -Name 'ts' -Value $now
        if ($hasResult) { Set-PlanProperty -Object $rec -Name 'result' -Value ([string]$Result) }
        $found = $true
      }
    }

    if (-not $found) { return $false }
    Write-PlanRecordsUnlocked $records
    return $true
  }.GetNewClosure()))
}

function Get-NextPlanStep {
  $plan = Get-Plan
  if ($null -eq $plan) { return $null }

  $statusById = @{}
  foreach ($node in @($plan.nodes)) { $statusById[[string]$node.id] = [string]$node.status }

  foreach ($node in @($plan.nodes)) {
    if ([string]$node.type -ne 'step') { continue }
    $status = Normalize-PlanStatus ([string]$node.status)
    if ($status -ne 'pending' -and $status -ne 'in_progress') { continue }

    $depsReady = $true
    foreach ($dep in @($node.deps)) {
      $depId = [string]$dep
      if ([string]::IsNullOrWhiteSpace($depId)) { continue }
      if (-not $statusById.ContainsKey($depId) -or [string]$statusById[$depId] -ne 'done') {
        $depsReady = $false
        break
      }
    }
    if ($depsReady) { return $node }
  }

  return $null
}

function Get-ReadyPlanSteps {
  # The "ready frontier" of the DAG: every STEP node that is 'pending' and whose
  # deps are ALL 'done' — i.e. every step that can be dispatched to a worker
  # RIGHT NOW. Unlike Get-NextPlanStep (returns ONE step, and also returns
  # in_progress ones), this returns the whole runnable set and EXCLUDES
  # in_progress steps (those are already in flight). The executor marks a step
  # 'in_progress' the moment it hands it to a worker, so the next call won't
  # re-dispatch it. Returns node objects (caller needs title/criteria/parent).
  param([int]$Max = 0)   # 0 = unlimited
  $plan = Get-Plan
  if ($null -eq $plan) { return @() }

  $statusById = @{}
  foreach ($node in @($plan.nodes)) { $statusById[[string]$node.id] = (Normalize-PlanStatus ([string]$node.status)) }

  $ready = New-Object 'System.Collections.Generic.List[object]'
  foreach ($node in @($plan.nodes)) {
    if ([string]$node.type -ne 'step') { continue }
    if ((Normalize-PlanStatus ([string]$node.status)) -ne 'pending') { continue }
    $depsReady = $true
    foreach ($dep in @($node.deps)) {
      $depId = [string]$dep
      if ([string]::IsNullOrWhiteSpace($depId)) { continue }
      if (-not $statusById.ContainsKey($depId) -or $statusById[$depId] -ne 'done') { $depsReady = $false; break }
    }
    if ($depsReady) {
      [void]$ready.Add($node)
      if ($Max -gt 0 -and $ready.Count -ge $Max) { break }
    }
  }
  return @($ready.ToArray())
}

function Get-PlanScheduleState {
  # The scheduler's per-tick snapshot. The DAG executor calls this each loop to
  # decide: dispatch more (ready>0), keep polling (inflight>0), finish
  # (complete), or abort (deadlocked). Statuses are rolled up by ConvertTo-
  # PlanObject so a step depending on a TASK/EPIC waits for the whole subtree.
  #
  #   complete   = no pending and no in_progress steps remain
  #   deadlocked = work remains, but nothing is runnable AND nothing is in
  #                flight -> a dependency cycle, a dangling dep id, or a dep on a
  #                blocked/skipped step. The frontier can never advance, so the
  #                executor must stop and post-mortem instead of spinning.
  #   blockers   = per stuck step, the unmet deps with their status, e.g.
  #                "s3" -> @("s2(blocked)","s9(missing)") — actionable diagnosis.
  $plan = Get-Plan
  if ($null -eq $plan) {
    return [pscustomobject][ordered]@{
      total = 0; done = 0; pending = 0; in_progress = 0; blocked = 0; skipped = 0
      ready = @(); inflight = @(); waiting = @()
      complete = $true; deadlocked = $false; reason = 'no-plan'; blockers = @{}
    }
  }

  $steps = @($plan.nodes | Where-Object { [string]$_.type -eq 'step' })
  $statusById = @{}
  foreach ($node in @($plan.nodes)) { $statusById[[string]$node.id] = (Normalize-PlanStatus ([string]$node.status)) }

  $ready    = New-Object 'System.Collections.Generic.List[string]'
  $inflight = New-Object 'System.Collections.Generic.List[string]'
  $waiting  = New-Object 'System.Collections.Generic.List[string]'
  $blockers = @{}
  $counts = @{ pending = 0; in_progress = 0; done = 0; blocked = 0; skipped = 0 }

  foreach ($s in $steps) {
    $st = Normalize-PlanStatus ([string]$s.status)
    $counts[$st] = [int]$counts[$st] + 1
    if ($st -eq 'in_progress') { [void]$inflight.Add([string]$s.id); continue }
    if ($st -ne 'pending') { continue }

    $unmet = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dep in @($s.deps)) {
      $depId = [string]$dep
      if ([string]::IsNullOrWhiteSpace($depId)) { continue }
      $depStatus = if ($statusById.ContainsKey($depId)) { [string]$statusById[$depId] } else { 'missing' }
      if ($depStatus -ne 'done') { [void]$unmet.Add(("{0}({1})" -f $depId, $depStatus)) }
    }
    if ($unmet.Count -eq 0) { [void]$ready.Add([string]$s.id) }
    else { [void]$waiting.Add([string]$s.id); $blockers[[string]$s.id] = @($unmet.ToArray()) }
  }

  $total = $steps.Count
  $remaining = [int]$counts['pending'] + [int]$counts['in_progress']
  $complete = ($remaining -eq 0)
  $deadlocked = (-not $complete) -and ($ready.Count -eq 0) -and ($inflight.Count -eq 0)
  $reason =
    if ($complete) { 'complete' }
    elseif ($ready.Count -gt 0) { 'runnable' }
    elseif ($inflight.Count -gt 0) { 'awaiting-inflight' }
    else { 'deadlocked' }

  return [pscustomobject][ordered]@{
    total = $total; done = [int]$counts['done']; pending = [int]$counts['pending']
    in_progress = [int]$counts['in_progress']; blocked = [int]$counts['blocked']; skipped = [int]$counts['skipped']
    ready = @($ready.ToArray()); inflight = @($inflight.ToArray()); waiting = @($waiting.ToArray())
    complete = $complete; deadlocked = $deadlocked; reason = $reason; blockers = $blockers
  }
}

function Get-PlanProgress {
  $plan = Get-Plan
  if ($null -eq $plan) {
    return [ordered]@{ total = 0; done = 0; percent = 0 }
  }

  $steps = @($plan.nodes | Where-Object { [string]$_.type -eq 'step' })
  $total = $steps.Count
  $done = @($steps | Where-Object { [string]$_.status -eq 'done' }).Count
  $percent = 0
  if ($total -gt 0) { $percent = [int][Math]::Round(($done * 100.0) / $total) }
  return [ordered]@{ total = $total; done = $done; percent = $percent }
}

function Get-PlanStatusIcon {
  param([string]$Status)
  switch (Normalize-PlanStatus $Status) {
    'pending'     { return '⬜' }
    'in_progress' { return '🔄' }
    'done'        { return '✅' }
    'blocked'     { return '⛔' }
    'skipped'     { return '⤬' }
  }
  return '⬜'
}

function Format-PlanForPrompt {
  $plan = Get-Plan
  if ($null -eq $plan) { return '' }

  $progress = Get-PlanProgress
  $lines = New-Object 'System.Collections.Generic.List[string]'
  [void]$lines.Add(("Прогресс: {0}/{1} ({2}%)" -f $progress.done, $progress.total, $progress.percent))

  $rendered = @{}
  $renderNode = {
    param($Node, [string]$Label, [string]$Indent)
    $icon = Get-PlanStatusIcon ([string]$Node.status)
    $criteria = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Node.criteria)) { $criteria = " (критерий: $($Node.criteria))" }
    $deps = ''
    if (@($Node.deps).Count -gt 0) { $deps = " [deps: $((@($Node.deps) | ForEach-Object { [string]$_ }) -join ', ')]" }
    $result = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Node.result)) { $result = " — $($Node.result)" }
    [void]$lines.Add(("{0}{1} {2} {3}: {4}{5}{6}{7}" -f $Indent, $icon, $Label, $Node.id, $Node.title, $criteria, $deps, $result))
    $rendered[[string]$Node.id] = $true
  }

  foreach ($epic in @($plan.nodes | Where-Object { [string]$_.type -eq 'epic' })) {
    & $renderNode $epic 'EPIC' ''
    foreach ($task in @($plan.nodes | Where-Object { [string]$_.type -eq 'task' -and [string]$_.parent -eq [string]$epic.id })) {
      & $renderNode $task 'TASK' '  '
      foreach ($step in @($plan.nodes | Where-Object { [string]$_.type -eq 'step' -and [string]$_.parent -eq [string]$task.id })) {
        & $renderNode $step 'STEP' '    '
      }
    }
  }

  foreach ($node in @($plan.nodes)) {
    if (-not $rendered.ContainsKey([string]$node.id)) {
      $label = ([string]$node.type).ToUpperInvariant()
      & $renderNode $node $label ''
    }
  }

  $next = Get-NextPlanStep
  if ($null -ne $next) {
    $crit = if ([string]::IsNullOrWhiteSpace([string]$next.criteria)) { 'нет' } else { [string]$next.criteria }
    [void]$lines.Add(("ТЕКУЩИЙ ШАГ: {0} — {1} (критерий: {2})" -f $next.id, $next.title, $crit))
  } else {
    [void]$lines.Add('ТЕКУЩИЙ ШАГ: нет доступных pending/in_progress шагов')
  }

  return (($lines.ToArray()) -join "`n")
}

function Get-PlanForApi {
  $plan = Get-Plan
  if ($null -eq $plan) {
    return [ordered]@{
      meta     = $null
      progress = [ordered]@{ total = 0; done = 0; percent = 0 }
      nodes    = @()
    }
  }

  return [ordered]@{
    meta     = $plan.meta
    progress = Get-PlanProgress
    nodes    = @($plan.nodes)
  }
}

function Archive-Plan {
  return [bool](Use-BridgeLock {
    $path = Get-PlanPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $archive = Get-PlanArchivePath
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Move-Item -LiteralPath $path -Destination $archive -Force
    return $true
  })
}
