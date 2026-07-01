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
  if ($null -eq $Levels) {
    return [pscustomobject]@{ wave_count = 0; wave_sizes = @(); first_wave_size = 0; max_wave_size = 0; parallelism_pct = 0; scheduled = 0; cyclic_leftover = @() }
  }
  $waves = @($Levels.waves)
  $sizes = @($waves | ForEach-Object { @($_).Count })
  $waveCount = $waves.Count
  $maxWave = if ($sizes.Count -gt 0) { ($sizes | Measure-Object -Maximum).Maximum } else { 0 }
  $firstWave = if ($sizes.Count -gt 0) { [int]$sizes[0] } else { 0 }
  # parallelism % is computed over the SCHEDULED atoms (those actually placed in waves), NOT the raw atom
  # count: a cyclic/unschedulable atom lands in cyclic_leftover and must not inflate the parallelism score.
  # 100 = every scheduled atom in one wave (fully parallel); 0 = one atom per wave (fully serial).
  $scheduled = 0; foreach ($s in @($sizes)) { $scheduled += [int]$s }
  $pct = 0
  if ($scheduled -gt 1) { $pct = [int][math]::Round(100.0 * ($scheduled - $waveCount) / ($scheduled - 1)) }
  elseif ($scheduled -eq 1) { $pct = 100 }
  return [pscustomobject]@{
    wave_count = [int]$waveCount
    wave_sizes = @($sizes)
    first_wave_size = [int]$firstWave
    max_wave_size = [int]$maxWave
    parallelism_pct = [int]$pct
    scheduled = [int]$scheduled
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

function New-ProjectAutopilotContractStub {
  # Ch2 of the diffusion engine: DETERMINISTIC interface-stub generator.
  # Renders an interface-contract object into a compiling-shaped source stub that a CONSUMER atom can
  # build against BEFORE the real provider exists. Pure rendering -- NO behavior change to the engine,
  # NO I/O, NO timestamps, NO randomness. The same contract always renders byte-identical source.
  # Returns @{ language; name; owned_file; ext; source; hash }. NEVER throws (falls back to a generic
  # stub with whatever name is available, or 'Unknown').
  param($Contract)

  # ---- defensive field reader: present-but-null treated as missing, never assumes a field exists ----
  $get = {
    param($Obj, [string[]]$Names, $Def = $null)
    if ($null -eq $Obj) { return $Def }
    if (Get-Command Get-BacklogPackObjectValue -ErrorAction SilentlyContinue) {
      foreach ($n in @($Names)) {
        $v = Get-BacklogPackObjectValue -Obj $Obj -Name $n -Default $null
        if ($null -ne $v) { return $v }
      }
      return $Def
    }
    # Fallback if the bridge helper is not loaded.
    foreach ($n in @($Names)) {
      try {
        if ($Obj -is [System.Collections.IDictionary]) {
          foreach ($k in @($Obj.Keys)) { if ([string]::Equals([string]$k, [string]$n, 'OrdinalIgnoreCase')) { if ($null -ne $Obj[$k]) { return $Obj[$k] } } }
        } else {
          $p = @($Obj.PSObject.Properties | Where-Object { [string]::Equals([string]$_.Name, [string]$n, 'OrdinalIgnoreCase') } | Select-Object -First 1)
          if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
        }
      } catch {}
    }
    return $Def
  }

  $asArray = {
    param($V)
    if ($null -eq $V) { return @() }
    if ($V -is [string]) { return @($V) }
    if ($V -is [System.Collections.IEnumerable]) { return @($V) }
    return @($V)
  }

  # sanitize an arbitrary contract name into a legal PascalCase identifier (deterministic). Used wherever the
  # name goes into a class/interface/variable position; the raw human name stays only in comments.
  $toIdent = {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return 'ContractStub' }
    $parts = @([regex]::Split($Raw, '[^A-Za-z0-9]+') | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($parts.Count -eq 0) { return 'ContractStub' }
    $acc = ''
    foreach ($p in $parts) { $first = $p.Substring(0,1).ToUpperInvariant(); $rest = ''; if ($p.Length -gt 1) { $rest = $p.Substring(1) }; $acc = $acc + $first + $rest }
    if ($acc -match '^[0-9]') { $acc = '_' + $acc }
    if ([string]::IsNullOrWhiteSpace($acc)) { return 'ContractStub' }
    return $acc
  }
  $name = 'Unknown'; $ext = ''; $ownedFile = ''; $language = 'generic'; $version = ''; $id = ''; $ident = 'ContractStub'
  $source = ''

  try {
    # ---- name / id / version ----
    $rawName = (& $get $Contract @('name') $null)
    $rawId   = (& $get $Contract @('id') $null)
    if (-not [string]::IsNullOrWhiteSpace([string]$rawName)) {
      $name = [string]$rawName
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$rawId)) {
      if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) { $name = ConvertTo-ProjectAutopilotSlug -Text ([string]$rawId) } else { $name = [string]$rawId }
    }
    if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = 'Unknown' }
    $id = if (-not [string]::IsNullOrWhiteSpace([string]$rawId)) { [string]$rawId } else { [string]$name }
    $version = [string](& $get $Contract @('version','contract_version') '')

    # ---- owned_file -> language ----
    $ownedFiles = (& $asArray (& $get $Contract @('owned_files') $null))
    if (@($ownedFiles).Count -gt 0) { $ownedFile = [string]@($ownedFiles)[0] }
    if ([string]::IsNullOrWhiteSpace($ownedFile)) { $ownedFile = [string](& $get $Contract @('owned_file') '') }

    if (-not [string]::IsNullOrWhiteSpace($ownedFile)) {
      $ext = [string][System.IO.Path]::GetExtension($ownedFile).ToLowerInvariant()
      switch ($ext) {
        '.py'  { $language = 'python' }
        '.kt'  { $language = 'kotlin' }
        '.kts' { $language = 'kotlin' }
        '.ts'  { $language = 'typescript' }
        '.tsx' { $language = 'typescript' }
        default { $language = 'generic' }
      }
    }

    # ---- structured signature ----
    $signature = (& $get $Contract @('signature') $null)
    $sigType   = [string](& $get $signature @('type') '')
    $sigModule = [string](& $get $signature @('module') '')

    # language hint from signature when no decisive file extension
    if ($language -eq 'generic') {
      $hint = ($sigType + ' ' + $sigModule)
      if ($sigType -match '(?i)abstract_base_class|module' -or (-not [string]::IsNullOrWhiteSpace($sigModule))) { $language = 'python' }
    }

    $imports = (& $asArray (& $get $signature @('imports') $null))
    $classAttrs = (& $asArray (& $get $signature @('class_attributes') $null))
    # abstract_methods is canonical; some contracts expose 'methods'
    $methods = (& $asArray (& $get $signature @('abstract_methods') $null))
    if (@($methods).Count -eq 0) { $methods = (& $asArray (& $get $signature @('methods') $null)) }

    $isAbc = ($sigType -match '(?i)abstract_base_class') -or (@($imports) | Where-Object { [string]$_ -match '(?i)\bABC\b' }).Count -gt 0
    $ident = & $toIdent $name

    $nl = "`n"
    $sb = New-Object System.Text.StringBuilder

    if ($language -eq 'python') {
      [void]$sb.Append("# AUTO-GENERATED CONTRACT STUB (deterministic) -- contract $id v$version" + $nl)
      $effImports = @(@($imports) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
      # an ABC stub references ABC/@abstractmethod -- auto-inject the import when the contract omits it, else
      # the stub raises NameError at import time. De-dupe against any contract-provided abc import.
      if ($isAbc -and (@($effImports | Where-Object { $_ -match '(?i)from\s+abc\s+import' }).Count -eq 0)) { $effImports = @('from abc import ABC, abstractmethod') + $effImports }
      foreach ($imp in @($effImports)) { [void]$sb.Append([string]$imp + $nl) }
      if (@($effImports).Count -gt 0) { [void]$sb.Append($nl) }
      if ($isAbc) { [void]$sb.Append("class $ident(ABC):" + $nl) } else { [void]$sb.Append("class ${ident}:" + $nl) }
      $emittedBody = $false
      foreach ($a in @($classAttrs)) {
        $an = [string](& $get $a @('name') '')
        $at = [string](& $get $a @('type') '')
        if ([string]::IsNullOrWhiteSpace($an)) { continue }
        $line = if (-not [string]::IsNullOrWhiteSpace($at)) { "    ${an}: $at" } else { "    $an" }
        [void]$sb.Append($line + $nl)
        $emittedBody = $true
      }
      foreach ($m in @($methods)) {
        $msig = [string](& $get $m @('signature') '')
        $mname = [string](& $get $m @('name') '')
        if ([string]::IsNullOrWhiteSpace($msig)) {
          if ([string]::IsNullOrWhiteSpace($mname)) { continue }
          $msig = "$mname(self)"
        }
        if ($isAbc) { [void]$sb.Append("    @abstractmethod" + $nl) }
        [void]$sb.Append("    def ${msig}:" + $nl)
        [void]$sb.Append("        raise NotImplementedError(`"contract stub: $id`")" + $nl)
        $emittedBody = $true
      }
      if (-not $emittedBody) { [void]$sb.Append("    pass" + $nl) }
      $source = $sb.ToString()
    }
    elseif ($language -eq 'kotlin') {
      [void]$sb.Append("// AUTO-GENERATED CONTRACT STUB (deterministic) -- contract $id v$version" + $nl)
      [void]$sb.Append("interface $ident {" + $nl)
      foreach ($m in @($methods)) {
        $msig = [string](& $get $m @('signature') '')
        $mname = [string](& $get $m @('name') '')
        if ([string]::IsNullOrWhiteSpace($msig)) {
          if ([string]::IsNullOrWhiteSpace($mname)) { continue }
          $msig = "fun $mname()"
        }
        [void]$sb.Append("    $msig" + $nl)
      }
      [void]$sb.Append("}" + $nl)
      $source = $sb.ToString()
    }
    elseif ($language -eq 'typescript') {
      [void]$sb.Append("// AUTO-GENERATED CONTRACT STUB (deterministic) -- contract $id v$version" + $nl)
      [void]$sb.Append("export interface $ident {" + $nl)
      foreach ($m in @($methods)) {
        $msig = [string](& $get $m @('signature') '')
        $mname = [string](& $get $m @('name') '')
        if ([string]::IsNullOrWhiteSpace($msig)) {
          if ([string]::IsNullOrWhiteSpace($mname)) { continue }
          $msig = "$mname(): void"
        }
        [void]$sb.Append("    $msig;" + $nl)
      }
      [void]$sb.Append("}" + $nl)
      $source = $sb.ToString()
    }
    else {
      # generic: commented block + a single placeholder declaration
      [void]$sb.Append("# AUTO-GENERATED CONTRACT STUB (deterministic) -- contract $id v$version" + $nl)
      [void]$sb.Append("# interface contract: $name" + $nl)
      foreach ($a in @($classAttrs)) {
        $an = [string](& $get $a @('name') '')
        $at = [string](& $get $a @('type') '')
        if ([string]::IsNullOrWhiteSpace($an)) { continue }
        $desc = if (-not [string]::IsNullOrWhiteSpace($at)) { "$an : $at" } else { $an }
        [void]$sb.Append("#   attribute: $desc" + $nl)
      }
      foreach ($m in @($methods)) {
        $msig = [string](& $get $m @('signature') '')
        $mname = [string](& $get $m @('name') '')
        if ([string]::IsNullOrWhiteSpace($msig)) { $msig = $mname }
        if ([string]::IsNullOrWhiteSpace($msig)) { continue }
        [void]$sb.Append("#   method: $msig" + $nl)
      }
      [void]$sb.Append("# contract stub not implemented -- placeholder for contract $id" + $nl)
      [void]$sb.Append("CONTRACT_STUB_${ident} = `"contract stub: $id`"" + $nl)
      $source = $sb.ToString()
    }
  } catch {
    # Hard fallback: never throw on a malformed/empty contract.
    $language = 'generic'
    if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = 'Unknown' }
    if ([string]::IsNullOrWhiteSpace([string]$id)) { $id = [string]$name }
    $ident = & $toIdent $name
    $source = "# AUTO-GENERATED CONTRACT STUB (deterministic) -- contract $id v$version`n" +
              "# contract stub not implemented -- malformed or empty contract`n" +
              "CONTRACT_STUB_${ident} = `"contract stub: $id`"`n"
    $ext = ''
  }

  $hash = ''
  try { if (Get-Command Get-ProjectAutopilotSha256 -ErrorAction SilentlyContinue) { $hash = Get-ProjectAutopilotSha256 -Text $source } } catch { $hash = '' }

  return [pscustomobject]@{
    language   = $language
    name       = $name
    owned_file = [string]$ownedFile
    ext        = [string]$ext
    source     = [string]$source
    hash       = [string]$hash
  }
}

function New-ProjectAutopilotSynthesizedContracts {
  # Cold-start reliability floor for wide diffusion. The coordinator emits atoms carrying `provides`/
  # `consumes` slug arrays but NO contract files on disk, so Get-ProjectAutopilotInterfaceContracts returns
  # EMPTY -> the diffusion gate goes red -> the whole project builds serially. This function synthesizes a
  # MINIMAL, VALID, FREEZABLE interface contract IN MEMORY for every id that has BOTH a provider atom and a
  # consumer atom, then runs each through the REAL validator (Test-ProjectAutopilotInterfaceContract) so the
  # returned entries are byte-for-byte the same shape Get-ProjectAutopilotInterfaceContracts returns and can
  # be handed straight to the freeze manifest / soft-edge graph.
  #
  # PURE: NO I/O, NO timestamp, NO randomness. Every synthesized contract uses fixed strings and a fixed
  # version ('0.0.0-synth'), so two calls on identical $Tasks serialize byte-identically -- the downstream
  # freeze canonical_hash must not churn. NEVER throws: any fault returns the empty shape.
  #
  # Returns [pscustomobject]@{ synthesized=@(<processed contract entries>); skipped=@(@{id;reason}); covered_ids=@(<ids>) }.
  param([object[]]$Tasks = @(), [object[]]$ExistingContracts = @())

  $empty = { return [pscustomobject]@{ synthesized = @(); skipped = @(); covered_ids = @() } }

  try {
    # ---- defensive readers (mirror the other planner functions; present-but-null == missing) ----
    $get = {
      param($Obj, [string[]]$Names, $Def = $null)
      if ($null -eq $Obj) { return $Def }
      if (Get-Command Get-BacklogPackObjectValue -ErrorAction SilentlyContinue) {
        foreach ($n in @($Names)) {
          $v = Get-BacklogPackObjectValue -Obj $Obj -Name $n -Default $null
          if ($null -ne $v) { return $v }
        }
        return $Def
      }
      foreach ($n in @($Names)) {
        try {
          if ($Obj -is [System.Collections.IDictionary]) {
            foreach ($k in @($Obj.Keys)) { if ([string]::Equals([string]$k, [string]$n, 'OrdinalIgnoreCase')) { if ($null -ne $Obj[$k]) { return $Obj[$k] } } }
          } else {
            $p = @($Obj.PSObject.Properties | Where-Object { [string]::Equals([string]$_.Name, [string]$n, 'OrdinalIgnoreCase') } | Select-Object -First 1)
            if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
          }
        } catch {}
      }
      return $Def
    }

    $slugArr = {
      param($V)
      if (Get-Command ConvertTo-ProjectAutopilotSlugArray -ErrorAction SilentlyContinue) { return @(ConvertTo-ProjectAutopilotSlugArray $V) }
      return @(@($V) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    }
    $pathArr = {
      param($V)
      if (Get-Command ConvertTo-ProjectAutopilotPathArray -ErrorAction SilentlyContinue) { return @(ConvertTo-ProjectAutopilotPathArray $V) }
      return @(@($V) | ForEach-Object { ([string]$_).Replace('\','/').Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    $overlap = {
      param($Left, $Right)
      if (Get-Command Test-ProjectAutopilotPathOverlap -ErrorAction SilentlyContinue) { return [bool](Test-ProjectAutopilotPathOverlap -Left @($Left) -Right @($Right)) }
      foreach ($l in @($Left)) { foreach ($r in @($Right)) { if ([string]$l -eq [string]$r) { return $true } } }
      return $false
    }

    # ---- 1. provider / consumer maps keyed by contract id (stable id order) ----
    $providerMap = @{}   # id -> List[atom]
    $consumerMap = @{}   # id -> List[atom]
    foreach ($t in @($Tasks)) {
      if ($null -eq $t) { continue }
      foreach ($provSlug in @(& $slugArr (& $get $t @('provides') @()))) {
        if ([string]::IsNullOrWhiteSpace($provSlug)) { continue }
        if (-not $providerMap.ContainsKey($provSlug)) { $providerMap[$provSlug] = (New-Object 'System.Collections.Generic.List[object]') }
        $providerMap[$provSlug].Add($t) | Out-Null
      }
      foreach ($consSlug in @(& $slugArr (& $get $t @('consumes') @()))) {
        if ([string]::IsNullOrWhiteSpace($consSlug)) { continue }
        if (-not $consumerMap.ContainsKey($consSlug)) { $consumerMap[$consSlug] = (New-Object 'System.Collections.Generic.List[object]') }
        $consumerMap[$consSlug].Add($t) | Out-Null
      }
    }

    # ---- 2. ids of ExistingContracts that are already VALID (never re-synthesize a real one) ----
    $existingValidIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ec in @($ExistingContracts)) {
      if ($null -eq $ec) { continue }
      if (-not [bool](& $get $ec @('valid') $false)) { continue }
      $eid = & $slugArr (@(& $get $ec @('id') ''))
      foreach ($e in @($eid)) { if (-not [string]::IsNullOrWhiteSpace($e)) { [void]$existingValidIds.Add($e) } }
    }

    # ---- 3. candidate ids: BOTH a provider and a consumer atom, iterated in STABLE (sorted) order ----
    $allIds = @($providerMap.Keys + $consumerMap.Keys | Sort-Object -Unique)
    $candidateIds = @($allIds | Where-Object { $providerMap.ContainsKey($_) -and $consumerMap.ContainsKey($_) })

    # precompute owned_files per candidate (from its provider atoms) for the overlap check
    $ownedByCandidate = @{}
    foreach ($id in @($candidateIds)) {
      $files = New-Object 'System.Collections.Generic.List[string]'
      foreach ($p in @($providerMap[$id].ToArray())) {
        foreach ($f in @(& $pathArr (& $get $p @('files') @()))) { if (-not $files.Contains($f)) { [void]$files.Add($f) } }
      }
      $ownedByCandidate[$id] = @($files.ToArray() | Sort-Object)
    }

    $synthesized = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    $coveredIds = New-Object 'System.Collections.Generic.List[string]'
    $acceptedFiles = @{}   # id -> owned_files that were actually synthesized (for deterministic overlap skip)

    foreach ($id in @($candidateIds)) {
      # a. real contract already present and valid -> leave it alone
      if ($existingValidIds.Contains($id)) {
        $skipped.Add([pscustomobject]@{ id = $id; reason = 'real-contract-present' }) | Out-Null
        continue
      }

      $ownedFiles = @($ownedByCandidate[$id])

      # b. owned-files overlap with an EARLIER accepted candidate -> skip the LATER id (deterministic:
      #    candidateIds is sorted, and we only compare against ids we already accepted this pass).
      $overlapHit = $false
      foreach ($priorId in @($acceptedFiles.Keys | Sort-Object)) {
        if (& $overlap @($ownedFiles) @($acceptedFiles[$priorId])) { $overlapHit = $true; break }
      }
      if ($overlapHit) {
        $skipped.Add([pscustomobject]@{ id = $id; reason = 'owned-files-overlap' }) | Out-Null
        continue
      }

      # c. module name = basename (no extension) of the first provider file, else the id.
      $firstFile = if (@($ownedFiles).Count -gt 0) { [string]@($ownedFiles)[0] } else { '' }
      $moduleName = $id
      if (-not [string]::IsNullOrWhiteSpace($firstFile)) {
        try { $bn = [System.IO.Path]::GetFileNameWithoutExtension($firstFile); if (-not [string]::IsNullOrWhiteSpace($bn)) { $moduleName = $bn } } catch {}
      }

      # d. RAW minimal contract -- deterministic, fixed strings, both errors + error_taxonomy, well-formed
      #    golden example (non-empty input AND output so Test-ProjectAutopilotGoldenExamplesWellFormed passes).
      $raw = [ordered]@{
        id = $id
        version = '0.0.0-synth'
        signature = @{ type = 'module'; module = $moduleName; methods = @() }
        behavior = @{
          preconditions = @('synthesized from declaration')
          postconditions = @('provider satisfies consumer expectations')
          side_effects = @()
          idempotency = 'unknown'
        }
        invariants = @('interface stable within release')
        errors = @{ unspecified = 'synthesized placeholder error taxonomy' }
        error_taxonomy = @{ unspecified = 'synthesized placeholder error taxonomy' }
        golden_examples = @(@{ input = @{ note = 'synthesized' }; output = @{ note = 'synthesized-placeholder' } })
        owned_files = @($ownedFiles)
        owned_regions = @()
        synthesized = $true
        synthesis_reason = 'declared-provides-consumes-without-contract'
      }
      $rawObj = [pscustomobject]$raw

      # e. run through the REAL validator to prove valid=$true / raw_mature=$true (the payoff: freezable).
      #    Path/ProjectRoot/Channel are '' so no open-question block. NOTE: the validator still resolves an
      #    AMBIENT freeze-lock dir from Get-EffectiveChannel/Get-BridgeRoot and, if a lock for this id happens
      #    to exist on disk from a prior run/other channel, would report stable/lock_* from THAT stale lock.
      #    A freshly synthesized in-memory contract is by definition UNFROZEN, so we take valid/raw_mature/
      #    hash from the validator but PIN the lock-derived fields to the unfrozen state -- the freeze manifest
      #    is the only legitimate way to freeze it, and this keeps determinism independent of ambient disk.
      $check = Test-ProjectAutopilotInterfaceContract -Contract $rawObj -Path '' -ProjectRoot '' -Channel '' -OpenQuestionText ''

      # f. processed entry mirroring Get-ProjectAutopilotInterfaceContracts (lines 641-664). owned_files /
      #    owned_regions come from the canonical payload so they match the disk reader exactly.
      $payload = Get-ProjectAutopilotInterfaceContractCanonicalPayload -Contract $rawObj
      $entry = [pscustomobject]@{
        id = [string](& $get $check @('id') $id)
        path = ''
        contract = $rawObj
        valid = [bool](& $get $check @('valid') $false)
        stable = $false
        raw_mature = [bool](& $get $check @('raw_mature') $false)
        version = [string](& $get $check @('version') '0.0.0-synth')
        canonical_hash = [string](& $get $check @('canonical_hash') '')
        hash = [string](& $get $check @('hash') '')
        lock_path = ''
        lock_present = $false
        lock_stable = $false
        lock_hash = ''
        lock_version = ''
        hash_matches_lock = $false
        version_matches_lock = $false
        has_golden_example = [bool](& $get $check @('has_golden_example') $true)
        open_question_blocked = [bool](& $get $check @('open_question_blocked') $false)
        owned_files = @($payload.owned_files)
        owned_regions = @($payload.owned_regions)
        missing = @(& $get $check @('missing') @())
        maturity_reasons = @(@(& $get $check @('maturity_reasons') @()) | Where-Object { $_ -notin @('freeze-lock-hash-mismatch','freeze-lock-version-mismatch') })
        synthesized = $true
      }
      $synthesized.Add($entry) | Out-Null
      $coveredIds.Add($id) | Out-Null
      $acceptedFiles[$id] = @($ownedFiles)
    }

    # ---- 4. dangling consumes: a consumer with NO provider (in stable id order) ----
    foreach ($id in @($consumerMap.Keys | Sort-Object)) {
      if ($providerMap.ContainsKey($id)) { continue }
      $skipped.Add([pscustomobject]@{ id = $id; reason = 'dangling-consume' }) | Out-Null
    }

    return [pscustomobject]@{
      synthesized = @($synthesized.ToArray())
      skipped = @($skipped.ToArray())
      covered_ids = @($coveredIds.ToArray())
    }
  } catch {
    return (& $empty)
  }
}

function New-ProjectAutopilotShapedBatch {
  # Ch3 of the diffusion engine: ADDITIVE EMIT-SHAPING.
  # Given a just-emitted atom batch and a freeze manifest, RESHAPE the batch so contract-CONSUMER atoms
  # run in PARALLEL with their PROVIDER (built against a frozen stub) using ONLY the existing hard
  # `depends_on` scheduler -- no scheduler change. For each STABLE frozen contract we:
  #   * append a FREEZE-MARKER atom (independent -> wave 1) that writes the deterministic stub file;
  #   * rewrite each consumer's depends_on to drop the real provider slug and depend on the marker instead;
  #   * append ONE STITCH/consolidation atom that depends on every provider + consumer to wire the reals.
  # Pure planning transform -- NO I/O, NO timestamps, NO randomness; same inputs -> byte-identical tasks.
  # Does NOT mutate the caller's task objects (rebuilds each as a fresh pscustomobject preserving all
  # original NoteProperties). NEVER throws: on ANY error returns the no-op shape (applied=$false) so the
  # caller falls back to a serial slice.
  param([object[]]$Tasks = @(), [object[]]$Contracts = @(), $FreezeManifest = $null, [string]$ProjectRoot = '', [string]$Channel = '')

  $noop = {
    return [pscustomobject]@{
      tasks = @($Tasks)
      markers_added = 0
      consumers_rewritten = 0
      stitch_added = 0
      stub_paths = @()
      applied = $false
    }
  }

  try {
    # ---- defensive field reader (present-but-null treated as missing) ----
    $get = {
      param($Obj, [string[]]$Names, $Def = $null)
      if ($null -eq $Obj) { return $Def }
      if (Get-Command Get-BacklogPackObjectValue -ErrorAction SilentlyContinue) {
        foreach ($n in @($Names)) {
          $v = Get-BacklogPackObjectValue -Obj $Obj -Name $n -Default $null
          if ($null -ne $v) { return $v }
        }
        return $Def
      }
      foreach ($n in @($Names)) {
        try {
          if ($Obj -is [System.Collections.IDictionary]) {
            foreach ($k in @($Obj.Keys)) { if ([string]::Equals([string]$k, [string]$n, 'OrdinalIgnoreCase')) { if ($null -ne $Obj[$k]) { return $Obj[$k] } } }
          } else {
            $p = @($Obj.PSObject.Properties | Where-Object { [string]::Equals([string]$_.Name, [string]$n, 'OrdinalIgnoreCase') } | Select-Object -First 1)
            if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
          }
        } catch {}
      }
      return $Def
    }

    $asArray = {
      param($V)
      if ($null -eq $V) { return @() }
      if ($V -is [string]) { return @($V) }
      if ($V -is [System.Collections.IEnumerable]) { return @($V) }
      return @($V)
    }

    $slugify = {
      param([string]$Text)
      if (Get-Command ConvertTo-ProjectAutopilotSlug -ErrorAction SilentlyContinue) { return [string](ConvertTo-ProjectAutopilotSlug -Text ([string]$Text)) }
      return ([string]$Text).Trim().ToLowerInvariant()
    }

    # ---- 1. collect STABLE frozen contracts (freeze_ready AND lock_written) ----
    if ($null -eq $FreezeManifest) { return (& $noop) }
    $manifestContracts = @(& $asArray (& $get $FreezeManifest @('contracts') @()))
    $stable = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in $manifestContracts) {
      $fr = [bool](& $get $c @('freeze_ready') $false)
      $lw = [bool](& $get $c @('lock_written') $false)
      if ($fr -and $lw) { $stable.Add($c) | Out-Null }
    }
    if ($stable.Count -eq 0) { return (& $noop) }

    # ---- 2. working COPY of the tasks (rebuild each preserving ALL original NoteProperties) ----
    $work = New-Object 'System.Collections.Generic.List[object]'
    $slugIndex = @{}          # slug -> working pscustomobject (first wins)
    $slugOrder = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in @($Tasks)) {
      $od = [ordered]@{}
      if ($null -ne $t) {
        if ($t -is [System.Collections.IDictionary]) {
          foreach ($k in @($t.Keys)) { $od[[string]$k] = $t[$k] }
        } else {
          foreach ($p in @($t.PSObject.Properties)) { $od[[string]$p.Name] = $p.Value }
        }
      }
      $obj = [pscustomobject]$od
      $work.Add($obj) | Out-Null
      $slug = & $slugify ([string](& $get $obj @('slug','id','title') ''))
      if (-not [string]::IsNullOrWhiteSpace($slug)) {
        if (-not $slugIndex.ContainsKey($slug)) { $slugIndex[$slug] = $obj; $slugOrder.Add($slug) | Out-Null }
      }
    }

    # helper: read a working task's chapter
    $chapterOf = {
      param($Obj)
      [string](& $get $Obj @('chapter','phase','area') '')
    }

    # helper: set/replace a NoteProperty on a working pscustomobject
    $setProp = {
      param($Obj, [string]$Name, $Value)
      if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties.Remove($Name) }
      $Obj | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }

    $markersAdded = 0
    $consumersRewritten = 0
    $stubPaths = New-Object 'System.Collections.Generic.List[string]'
    $allProviderSlugs = New-Object 'System.Collections.Generic.List[string]'
    $allConsumerSlugs = New-Object 'System.Collections.Generic.List[string]'
    $existingFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in @($work.ToArray())) {
      foreach ($f in @(& $asArray (& $get $t @('files') @()))) {
        $fn = ([string]$f).Replace('\','/').Trim()
        if (-not [string]::IsNullOrWhiteSpace($fn)) { [void]$existingFiles.Add($fn.ToLowerInvariant()) }
      }
    }

    # ---- 3. per stable contract: freeze-marker + consumer rewrite ----
    foreach ($C in @($stable.ToArray())) {
      $id = [string](& $get $C @('id') '')
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      $idSlug = & $slugify $id
      $providers = @(& $asArray (& $get $C @('provider_atoms') @()) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $consumers = @(& $asArray (& $get $C @('consumer_atoms') @()) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $stubLang = [string](& $get $C @('generated_stub_language') '')
      $stubSource = [string](& $get $C @('generated_stub_source') '')

      # a. ext + stub path (forward slashes, relative, ephemeral consumer-side file)
      $ext = switch (([string]$stubLang).Trim().ToLowerInvariant()) {
        'python'     { '.py' }
        'kotlin'     { '.kt' }
        'typescript' { '.ts' }
        default      { '.txt' }
      }
      $stubBase = ".bridge/stubs/$idSlug"
      $stubPath = $stubBase + $ext
      if ($existingFiles.Contains($stubPath.ToLowerInvariant())) { $stubPath = $stubBase + '-stub' + $ext }
      [void]$existingFiles.Add($stubPath.ToLowerInvariant())

      # chapter for the marker: first provider's chapter in tasks, else first consumer's, else 'Chapter 1'
      $markerChapter = ''
      foreach ($ps in $providers) { if ($slugIndex.ContainsKey($ps)) { $markerChapter = & $chapterOf $slugIndex[$ps]; if (-not [string]::IsNullOrWhiteSpace($markerChapter)) { break } } }
      if ([string]::IsNullOrWhiteSpace($markerChapter)) {
        foreach ($ks in $consumers) { if ($slugIndex.ContainsKey($ks)) { $markerChapter = & $chapterOf $slugIndex[$ks]; if (-not [string]::IsNullOrWhiteSpace($markerChapter)) { break } } }
      }
      if ([string]::IsNullOrWhiteSpace($markerChapter)) { $markerChapter = 'Chapter 1' }

      $firstProvider = if (@($providers).Count -gt 0) { [string]@($providers)[0] } else { '' }

      # b. FREEZE-MARKER atom (independent -> dispatches in wave 1)
      $markerSlug = & $slugify ("freeze-$id")
      $markerTask = "Write the deterministic frozen contract stub for contract '$id' to $stubPath, with EXACTLY this content (do not alter the interface):`n`n$stubSource`n`nThis is a temporary stub that the integration/stitch atom will replace with the real implementation. Create the file and commit."
      $marker = [pscustomobject]([ordered]@{
        slug = $markerSlug
        title = "Freeze contract stub: $id"
        chapter = $markerChapter
        kind = 'infra'
        wave = 'wave-1'
        parallel_group = 'contracts'
        files = @($stubPath)
        depends_on = @()
        provides = @()
        consumes = @()
        task = $markerTask
        acceptance = @("$stubPath exists and contains the frozen contract interface")
        checks = @("verify $stubPath exists and is non-empty")
        severity = 'normal'
        risk = 'normal'
        serial_reason = ''
      })
      $work.Add($marker) | Out-Null
      if (-not $slugIndex.ContainsKey($markerSlug)) { $slugIndex[$markerSlug] = $marker; $slugOrder.Add($markerSlug) | Out-Null }
      [void]$stubPaths.Add($stubPath)
      $markersAdded++

      # c. rewrite each consumer: drop provider slugs from depends_on, append marker; build against stub.
      $providerSet = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($ps in $providers) { [void]$providerSet.Add($ps); if (-not ($allProviderSlugs -contains $ps)) { $allProviderSlugs.Add($ps) | Out-Null } }
      foreach ($ks in $consumers) {
        if (-not $slugIndex.ContainsKey($ks)) { continue }
        $cons = $slugIndex[$ks]
        # existing non-provider deps first, then the marker; dedupe, preserve order
        $newDeps = New-Object 'System.Collections.Generic.List[string]'
        $depSeen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($d in @(& $asArray (& $get $cons @('depends_on') @()))) {
          $ds = [string]$d
          if ([string]::IsNullOrWhiteSpace($ds)) { continue }
          if ($providerSet.Contains($ds)) { continue }
          if ($depSeen.Add($ds)) { $newDeps.Add($ds) | Out-Null }
        }
        if ($depSeen.Add($markerSlug)) { $newDeps.Add($markerSlug) | Out-Null }
        & $setProp $cons 'depends_on' @($newDeps.ToArray())

        # drop the direct live-contract consume so the soft/hard graph no longer draws a provider->consumer
        # hard edge: the consumer now depends ONLY on the fast freeze marker (the stub it builds against).
        $newConsumes = New-Object 'System.Collections.Generic.List[string]'
        foreach ($cm in @(& $asArray (& $get $cons @('consumes') @()))) {
          $cmS = [string]$cm
          if ([string]::IsNullOrWhiteSpace($cmS)) { continue }
          if ((& $slugify $cmS) -eq $idSlug) { continue }
          $newConsumes.Add($cmS) | Out-Null
        }
        & $setProp $cons 'consumes' @($newConsumes.ToArray())

        # append guidance to the task text + mark acceptance scope
        $existingTask = [string](& $get $cons @('task') '')
        $augmented = $existingTask + "`n`n[diffusion] Build against the frozen stub at $stubPath (provider '$firstProvider' is built in parallel and wired at integration). acceptance_scope=contract."
        & $setProp $cons 'task' $augmented
        & $setProp $cons 'acceptance_scope' 'contract'

        if (-not ($allConsumerSlugs -contains $ks)) { $allConsumerSlugs.Add($ks) | Out-Null }
        $consumersRewritten++
      }
    }

    # ---- 4. STITCH atom (only if at least one marker was added) ----
    $stitchAdded = 0
    if ($markersAdded -gt 0) {
      # last chapter ordinal present among tasks (highest leading number), else 'Chapter 9'
      $maxOrd = -1; $maxChapter = ''
      foreach ($t in @($work.ToArray())) {
        $ch = & $chapterOf $t
        if ([string]::IsNullOrWhiteSpace($ch)) { continue }
        $m = [regex]::Match($ch, '(\d+)')
        if ($m.Success) {
          $ord = [int]$m.Groups[1].Value
          if ($ord -gt $maxOrd) { $maxOrd = $ord; $maxChapter = $ch }
        }
      }
      $stitchChapter = if (-not [string]::IsNullOrWhiteSpace($maxChapter)) { $maxChapter } else { 'Chapter 9' }

      # depends_on = ALL provider + consumer slugs that ACTUALLY exist as tasks (deduped, ordered)
      $stitchDeps = New-Object 'System.Collections.Generic.List[string]'
      $stitchSeen = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($ps in @($allProviderSlugs.ToArray())) { if ($slugIndex.ContainsKey($ps) -and $stitchSeen.Add($ps)) { $stitchDeps.Add($ps) | Out-Null } }
      foreach ($ks in @($allConsumerSlugs.ToArray())) { if ($slugIndex.ContainsKey($ks) -and $stitchSeen.Add($ks)) { $stitchDeps.Add($ks) | Out-Null } }

      $stubList = [string]::Join(', ', @($stubPaths.ToArray()))
      $stitchTask = "Integration/stitch: replace each contract stub ($stubList) with the real provider implementation, verify each contract's frozen interface matches its real implementation, and RE-RUN every consumer's acceptance against the REAL provider (NOT the stub). Then run full integration acceptance. If any contract drifted from its frozen interface, FAIL -- do not ship the consumers against the stub. Remove the temporary stub files."
      # Deterministic, collision-resistant slug from the stub set so a second shaped batch's stitch is not
      # silently de-duped against a prior (possibly done/failed) 'stitch-integration'.
      $stitchSlug = 'stitch-integration'
      try { if (Get-Command Get-ProjectAutopilotSha256 -ErrorAction SilentlyContinue) { $stitchSlug = 'stitch-integration-' + (Get-ProjectAutopilotSha256 -Text ([string]::Join('|', @($stubPaths.ToArray() | Sort-Object)))).Substring(0,8) } } catch {}
      $stitch = [pscustomobject]([ordered]@{
        slug = $stitchSlug
        title = 'Integration stitch: wire real providers + remove contract stubs'
        chapter = $stitchChapter
        kind = 'consolidation'
        wave = 'wave-final'
        parallel_group = 'integration'
        files = @($stubPaths.ToArray())
        depends_on = @($stitchDeps.ToArray())
        provides = @()
        consumes = @()
        task = $stitchTask
        acceptance = @("the application builds and runs against the REAL providers with no remaining contract stubs")
        checks = @("integration build", "integration acceptance")
        severity = 'normal'
        risk = 'normal'
        serial_reason = 'contract integration'
      })
      $work.Add($stitch) | Out-Null
      $stitchAdded = 1
    }

    # ---- 5. return reshaped batch ----
    return [pscustomobject]@{
      tasks = @($work.ToArray())
      markers_added = [int]$markersAdded
      consumers_rewritten = [int]$consumersRewritten
      stitch_added = [int]$stitchAdded
      stub_paths = @($stubPaths.ToArray())
      applied = $true
    }
  } catch {
    return (& $noop)
  }
}
