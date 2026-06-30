# ==============================================================================
# lib/diffusion-planner.ps1  --  Ch1: SHADOW global wave planner (measurement only)
# ------------------------------------------------------------------------------
# Phase-1 of DIFFUSION_DESIGN.md: collect ALL atoms of a project, run the existing
# unified-graph builder GLOBALLY, level the graph into execution WAVES two ways --
#   * hard-only   : every contract edge is a hard prerequisite (today's behaviour;
#                   contract consumers wait for their provider to finish)
#   * soft        : a STABLE frozen contract turns provider->consumer into a SOFT
#                   edge, so the consumer can run in parallel against the contract
# -- classify each atom, and emit a durable PROJECT_WAVE_SCHEDULE.json + telemetry.
# This module changes NO execution. It only computes and writes the projected
# schedule so we can eyeball it on a real project before wiring real parallelism.
#
# Depends on functions defined in lib/backlog-autopilot.ps1 (New-ProjectAutopilotUnifiedGraph,
# ConvertTo-ProjectAutopilotSlug, Get-ProjectAutopilotTaskStringField). Source this AFTER it.
# ==============================================================================

function Get-ProjectAutopilotWaveLevels {
  # Kahn-style level assignment over HARD edges only. Soft edges never block (a stable contract lets the
  # consumer run against the stub). Returns @{ waves = @(@(slug,...),...); leveled = N; cyclic_leftover = @(slug,...) }.
  param([object[]]$Nodes = @(), [object[]]$Edges = @())
  $slugs = @($Nodes | ForEach-Object { [string]$_.slug } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $slugSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($s in $slugs) { [void]$slugSet.Add($s) }
  # distinct hard prerequisite pairs (from -> to); dedupe so duplicate edges don't double-count indegree
  $pairSet = New-Object 'System.Collections.Generic.HashSet[string]'
  $adj = @{}; $indeg = @{}
  foreach ($s in $slugs) { $adj[$s] = (New-Object 'System.Collections.Generic.List[string]'); $indeg[$s] = 0 }
  foreach ($e in @($Edges)) {
    if ([string]$e.edge_type -ne 'hard') { continue }
    $f = [string]$e.from; $t = [string]$e.to
    if (-not $slugSet.Contains($f) -or -not $slugSet.Contains($t) -or $f -eq $t) { continue }
    $key = $f + '>' + $t
    if (-not $pairSet.Add($key)) { continue }
    $adj[$f].Add($t) | Out-Null
    $indeg[$t] = [int]$indeg[$t] + 1
  }
  $remaining = @{}; foreach ($s in $slugs) { $remaining[$s] = [int]$indeg[$s] }
  $waves = New-Object 'System.Collections.Generic.List[object]'
  $current = @($slugs | Where-Object { [int]$indeg[$_] -eq 0 } | Sort-Object)
  $seen = 0
  while ($current.Count -gt 0) {
    $waves.Add(@($current)) | Out-Null
    $seen += $current.Count
    $next = New-Object 'System.Collections.Generic.List[string]'
    foreach ($u in $current) {
      foreach ($v in @($adj[$u])) {
        $remaining[$v] = [int]$remaining[$v] - 1
        if ([int]$remaining[$v] -eq 0) { $next.Add($v) | Out-Null }
      }
    }
    $current = @($next | Sort-Object)
  }
  $leftover = @($slugs | Where-Object { [int]$remaining[$_] -gt 0 })
  return [pscustomobject]@{ waves = @($waves.ToArray()); leveled = $seen; cyclic_leftover = @($leftover) }
}

function Get-ProjectAutopilotAtomClassification {
  # Classify each node from the unified graph (already built with the desired soft-edge policy):
  #   independent       -> no incoming edge of any kind
  #   contract-parallel -> no incoming HARD edge but >=1 incoming SOFT edge (runs in wave 1 vs a stub)
  #   hard-dependent    -> >=1 incoming HARD edge (must wait)
  # file_conflict is orthogonal (a node can be independent yet share a file with a sibling).
  param($Graph)
  $incHard = @{}; $incSoft = @{}
  foreach ($n in @($Graph.nodes)) { $incHard[[string]$n.slug] = 0; $incSoft[[string]$n.slug] = 0 }
  foreach ($e in @($Graph.edges)) {
    $t = [string]$e.to
    if (-not $incHard.ContainsKey($t)) { continue }
    if ([string]$e.edge_type -eq 'hard') { $incHard[$t] = [int]$incHard[$t] + 1 } else { $incSoft[$t] = [int]$incSoft[$t] + 1 }
  }
  $conflictSlugs = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($c in @($Graph.file_conflicts)) { [void]$conflictSlugs.Add([string]$c.left); [void]$conflictSlugs.Add([string]$c.right) }
  $independent = New-Object 'System.Collections.Generic.List[string]'
  $contractParallel = New-Object 'System.Collections.Generic.List[string]'
  $hardDependent = New-Object 'System.Collections.Generic.List[string]'
  $fileConflict = New-Object 'System.Collections.Generic.List[string]'
  foreach ($n in @($Graph.nodes)) {
    $s = [string]$n.slug
    if ([int]$incHard[$s] -gt 0) { $hardDependent.Add($s) | Out-Null }
    elseif ([int]$incSoft[$s] -gt 0) { $contractParallel.Add($s) | Out-Null }
    else { $independent.Add($s) | Out-Null }
    if ($conflictSlugs.Contains($s)) { $fileConflict.Add($s) | Out-Null }
  }
  return [pscustomobject]@{
    independent = @($independent.ToArray())
    contract_parallel = @($contractParallel.ToArray())
    hard_dependent = @($hardDependent.ToArray())
    file_conflict = @($fileConflict.ToArray())
  }
}

function Get-ProjectAutopilotWaveStats {
  param($Levels, [int]$AtomCount)
  $waves = @($Levels.waves)
  $sizes = @($waves | ForEach-Object { @($_).Count })
  $waveCount = $waves.Count
  $maxWave = if ($sizes.Count -gt 0) { ($sizes | Measure-Object -Maximum).Maximum } else { 0 }
  $firstWave = if ($sizes.Count -gt 0) { [int]$sizes[0] } else { 0 }
  # parallelism %: 100 = all atoms in one wave (fully parallel); 0 = one atom per wave (fully serial)
  $pct = 0
  if ($AtomCount -gt 1) { $pct = [int][math]::Round(100.0 * ($AtomCount - $waveCount) / ($AtomCount - 1)) }
  elseif ($AtomCount -eq 1) { $pct = 100 }
  return [pscustomobject]@{
    wave_count = [int]$waveCount
    wave_sizes = @($sizes)
    first_wave_size = [int]$firstWave
    max_wave_size = [int]$maxWave
    parallelism_pct = [int]$pct
    cyclic_leftover = @($Levels.cyclic_leftover)
  }
}

function New-ProjectAutopilotWaveSchedule {
  # Pure computation: build the unified graph BOTH ways and produce the projected schedule + the delta.
  param([object[]]$Tasks = @(), [object[]]$Contracts = @())
  $atomCount = @($Tasks).Count
  $hardGraph = New-ProjectAutopilotUnifiedGraph -Tasks @($Tasks) -Contracts @($Contracts) -AllowContractSoftEdges:$false
  $softGraph = New-ProjectAutopilotUnifiedGraph -Tasks @($Tasks) -Contracts @($Contracts) -AllowContractSoftEdges:$true
  $hardLevels = Get-ProjectAutopilotWaveLevels -Nodes @($hardGraph.nodes) -Edges @($hardGraph.edges)
  $softLevels = Get-ProjectAutopilotWaveLevels -Nodes @($softGraph.nodes) -Edges @($softGraph.edges)
  $hardStats = Get-ProjectAutopilotWaveStats -Levels $hardLevels -AtomCount $atomCount
  $softStats = Get-ProjectAutopilotWaveStats -Levels $softLevels -AtomCount $atomCount
  $classification = Get-ProjectAutopilotAtomClassification -Graph $softGraph
  $hardWaves = @(); $wn = 0; foreach ($w in @($hardLevels.waves)) { $wn++; $hardWaves += [pscustomobject]@{ wave = $wn; atoms = @($w) } }
  $softWaves = @(); $wn = 0; foreach ($w in @($softLevels.waves)) { $wn++; $softWaves += [pscustomobject]@{ wave = $wn; atoms = @($w) } }
  return [pscustomobject]@{
    atom_count = [int]$atomCount
    contract_count = @($Contracts).Count
    acyclic = [bool]$hardGraph.acyclic
    file_conflicts = @($hardGraph.file_conflicts)
    dangling_consumes = @($softGraph.dangling_consumes)
    classification = $classification
    hard = [pscustomobject]@{ stats = $hardStats; waves = @($hardWaves) }
    soft = [pscustomobject]@{ stats = $softStats; waves = @($softWaves) }
    projected = [pscustomobject]@{
      first_wave_gain = [int]$softStats.first_wave_size - [int]$hardStats.first_wave_size
      wave_count_reduction = [int]$hardStats.wave_count - [int]$softStats.wave_count
      parallelism_pct_hard = [int]$hardStats.parallelism_pct
      parallelism_pct_soft = [int]$softStats.parallelism_pct
    }
  }
}

function Write-ProjectAutopilotWaveSchedule {
  # Durable artifact: write PROJECT_WAVE_SCHEDULE.json into OutputDir. OutputDir MUST be outside the project
  # worktree (e.g. the channel runtime dir) so the schedule never dirties the project git and defeats the
  # clean-git diffusion gate. Returns the path written, or '' on failure. Pure I/O; never throws.
  param($Schedule, [string]$OutputDir, [string]$Channel = '')
  if ([string]::IsNullOrWhiteSpace($OutputDir)) { return '' }
  try {
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $payload = [ordered]@{
      schema = 'project-wave-schedule/v1'
      channel = [string]$Channel
      generated_at = (Get-Date).ToUniversalTime().ToString('o')
      schedule = $Schedule
    }
    $json = $payload | ConvertTo-Json -Depth 12
    $path = Join-Path $OutputDir 'PROJECT_WAVE_SCHEDULE.json'
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
  } catch { return '' }
}

function Invoke-ProjectAutopilotShadowPlanner {
  # Entry point for the shadow planner: compute the projected wave schedule for a batch of atoms and write
  # the durable artifact. Returns a compact summary for the telemetry marker. NEVER changes execution and
  # NEVER throws (a planner fault must not block the real one-chapter default).
  param([object[]]$Tasks = @(), [object[]]$Contracts = @(), [string]$OutputDir = '', [string]$Channel = '')
  try {
    if (@($Tasks).Count -eq 0) { return $null }
    $schedule = New-ProjectAutopilotWaveSchedule -Tasks @($Tasks) -Contracts @($Contracts)
    $path = Write-ProjectAutopilotWaveSchedule -Schedule $schedule -OutputDir $OutputDir -Channel $Channel
    return [pscustomobject]@{
      atom_count = [int]$schedule.atom_count
      acyclic = [bool]$schedule.acyclic
      hard_wave_count = [int]$schedule.hard.stats.wave_count
      soft_wave_count = [int]$schedule.soft.stats.wave_count
      hard_first_wave = [int]$schedule.hard.stats.first_wave_size
      soft_first_wave = [int]$schedule.soft.stats.first_wave_size
      parallelism_pct_hard = [int]$schedule.projected.parallelism_pct_hard
      parallelism_pct_soft = [int]$schedule.projected.parallelism_pct_soft
      independent = @($schedule.classification.independent).Count
      contract_parallel = @($schedule.classification.contract_parallel).Count
      hard_dependent = @($schedule.classification.hard_dependent).Count
      schedule_path = [string]$path
    }
  } catch { return $null }
}
