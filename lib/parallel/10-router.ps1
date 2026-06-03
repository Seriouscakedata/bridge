# ============================================================================
# WORKER POOL + ROUTER (extensible)
# Config-driven worker pool with strength-floor routing. To add a new CLI
# backend (gemini, deepseek, etc.):
#   1. Add Invoke-XxxCli function below (signature: param($Worker,$Worktree,$InFile,$MsgFile,$OutFile,$ErrFile) -> System.Diagnostics.Process)
#   2. Register it in $Script:ParallelCliRegistry
#   3. Add worker entries with cli='xxx' to config.json -> parallel.workers
# Routing rules: Select-WorkerForStream filters by complexity-floor (no weak
# model on complex code), then by domain affinity (claude→frontend, codex→
# scripts), then by cost (cheapest available wins). Same bucket isn't double-
# booked unless pool is exhausted.
# ============================================================================

# CLI registry: dispatch table. Each handler must accept the same params and
# return a System.Diagnostics.Process. Keep -Script scope so we can extend
# at runtime if needed.
$Script:ParallelCliRegistry = @{
  'codex'    = 'Invoke-ParallelCodexCli'
  'claude'   = 'Invoke-ParallelClaudeCli'
  'gemini'   = 'Invoke-ParallelLLMCli'   # 2026-06-01: API-LLM worker (no agentic CLI)
  'deepseek' = 'Invoke-ParallelLLMCli'   # 2026-06-01: API-LLM worker (no agentic CLI)
}

function Get-ParallelWorkerPool {
  # Returns @($worker, ...) read from config.json. Each worker is a hashtable:
  #   { id; cli; model; reasoning?; strength; speed; cost; domains[]; purpose? }
  # If config.parallel.workers is missing or empty, returns a built-in default
  # pool (back-compat: equivalent to old round-robin sonnet+codex-high).
  $cfg = $null
  try { $cfg = Get-BridgeConfig } catch {}
  $workers = @()
  try {
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'parallel')) {
      $pcfg = $cfg.parallel
      if ($pcfg -and ($pcfg.PSObject.Properties.Name -contains 'workers')) {
        $workers = @($pcfg.workers)
      }
    }
  } catch {}
  if (-not $workers -or $workers.Count -eq 0) {
    # Built-in default (matches old behaviour: sonnet + codex-high)
    return @(
      [pscustomobject]@{ id='claude-sonnet'; cli='claude'; model='sonnet'; strength=3; speed=3; cost=3; domains=@('frontend','docs','any'); purpose='Default Claude coder.' },
      [pscustomobject]@{ id='codex-high';    cli='codex';  model='gpt-5.5'; reasoning='high'; strength=4; speed=2; cost=4; domains=@('any','backend','scripts'); purpose='Default Codex coder.' }
    )
  }
  return $workers
}

function Get-ParallelComplexityFloor {
  param([string]$Complexity)
  $cfg = $null
  try { $cfg = Get-BridgeConfig } catch {}
  $defaults = @{ simple=2; moderate=3; complex=4; architectural=5 }
  try {
    if ($cfg -and $cfg.parallel -and $cfg.parallel.complexityFloor) {
      $cf = $cfg.parallel.complexityFloor
      $name = ([string]$Complexity).ToLowerInvariant()
      if ($cf.PSObject.Properties.Name -contains $name) { return [int]$cf.$name }
    }
  } catch {}
  $name = ([string]$Complexity).ToLowerInvariant()
  if ($defaults.ContainsKey($name)) { return [int]$defaults[$name] }
  return 3
}

function Get-StreamDomain {
  # Heuristic: pick the domain whose file-extension hint set best matches the
  # stream's declared files. Returns 'any' if nothing matches or no files.
  param([object]$Stream)
  $files = @()
  try { $files = @($Stream.files) } catch {}
  if ($files.Count -eq 0) { return 'any' }

  $exts = @($files | ForEach-Object {
    $e = [System.IO.Path]::GetExtension([string]$_)
    if ($e) { $e.TrimStart('.').ToLowerInvariant() }
  } | Where-Object { $_ } | Sort-Object -Unique)
  if ($exts.Count -eq 0) { return 'any' }

  $hints = $null
  try { $hints = (Get-BridgeConfig).parallel.domainHints } catch {}
  if (-not $hints) { return 'any' }

  $best = 'any'; $bestScore = 0
  foreach ($dom in $hints.PSObject.Properties.Name) {
    $hintExts = @($hints.$dom)
    $score = 0
    foreach ($ext in $exts) { if ($hintExts -contains $ext) { $score++ } }
    if ($score -gt $bestScore) { $bestScore = $score; $best = $dom }
  }
  return $best
}

function Get-StreamComplexity {
  # complexity comes from the planner's body line `complexity: ...`. If missing
  # we infer 'moderate' as a safe middle.
  param([object]$Stream)
  $c = ''
  try { $c = [string]$Stream.complexity } catch {}
  if ([string]::IsNullOrWhiteSpace($c)) { $c = 'moderate' }
  return $c.ToLowerInvariant()
}

function Get-TaskComplexityHeuristic {
  # 2026-06-01 AUTONOMY FIX: infer routing complexity from the task TEXT + touch-set size, so the
  # parallel dispatcher assigns the RIGHT worker tier AUTOMATICALLY. Previously every workpack-batch
  # stream was hardcoded 'Complexity: moderate' (New-BacklogWorkpackBatchTaskText), so a trivial
  # one-line probe and a full component redesign got the same worker pool — routing never
  # differentiated. Now: trivial one-liners -> 'simple' (cheap/fast gemini/deepseek/codex-medium),
  # rewrites/refactors/integrations -> 'complex' (codex-xhigh), design/schema/migration or many
  # files -> 'architectural' (unlocks opus via the existing opus-guard at Select-WorkerForStream).
  # Returns simple|moderate|complex|architectural. Cyrillic + English keywords (project tasks are RU).
  param([string]$Text, [int]$TouchCount = 1)
  $t = ([string]$Text).ToLowerInvariant()
  $len = $t.Length
  if ($t -match 'архитектур|спроектируй|design system|схем[аы]\s+(бд|базы|данных)|миграци|migration|redesign\s+(всего|сайта|all)|переработа(й|ть)\s+вс[юё]' -or $TouchCount -ge 6) { return 'architectural' }
  if ($t -match 'перепиш|переписать|рефактор|refactor|реализуй\s+полностью|полностью\s+реализ|интеграци|integrat|оркестрац|перепроектир|сложн|многошаг|end-to-end|переделай\s+полностью' -or $TouchCount -ge 3 -or $len -ge 600) { return 'complex' }
  # simple ONLY on explicit trivial markers — a short task WITHOUT such a marker (e.g. "добавь кнопку
  # в Hero") is a real component edit and must stay 'moderate', not drop to a weak worker.
  if ($t -match 'одной строк|одну строку|export const|переименуй|^\s*rename\b|добавь строку|опечатк|typo|удали строку|закомментируй|smoke[- ]?тест|smoke check') { return 'simple' }
  return 'moderate'
}

function Get-StreamExplicitWorkerId {
  # Planner can override routing with `worker: <id>` on its own line in body.
  param([object]$Stream)
  $body = ''
  try { $body = [string]$Stream.body } catch {}
  $m = [regex]::Match($body, '(?im)^\s*worker\s*:\s*([A-Za-z0-9_.-]+)\s*$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Select-WorkerForStream {
  # Returns the best worker for a stream given an already-used set (no double
  # booking unless pool is exhausted). Algorithm:
  #   1. Explicit `worker: ID` override wins immediately if id exists in pool.
  #   2. Filter pool by strength >= complexityFloor[complexity].
  #   3. Remove already-used buckets (unless pool gets empty).
  #   4. Protect opus: skip claude+opus unless complexity=architectural OR
  #      stream has [[OPUS]] marker.
  #   5. Prefer workers whose `domains` array contains the detected domain.
  #   6. Sort: cheapest cost asc, then fastest speed desc.
  # Returns $null only if pool is completely empty (caller falls back).
  param([object]$Stream, [string[]]$AlreadyUsedIds = @())

  $pool = @(Get-ParallelWorkerPool)
  if ($pool.Count -eq 0) { return $null }

  # 1. Explicit override
  $explicitId = Get-StreamExplicitWorkerId $Stream
  if (-not [string]::IsNullOrWhiteSpace($explicitId)) {
    $w = $pool | Where-Object { [string]$_.id -eq $explicitId } | Select-Object -First 1
    if ($w) { return $w }
    try { Add-Message -From system -Text ("⚠ parallel: explicit worker '" + $explicitId + "' not in pool, falling back to auto-route") -Kind event | Out-Null } catch {}
  }

  $complexity = Get-StreamComplexity $Stream
  $floor = Get-ParallelComplexityFloor -Complexity $complexity
  $domain = Get-StreamDomain $Stream
  $opusOk = ($complexity -eq 'architectural') -or ([bool]$Stream.opus)

  # 2. Strength floor
  $candidates = @($pool | Where-Object { [int]$_.strength -ge $floor })
  if ($candidates.Count -eq 0) {
    # No worker meets the floor — caller asked for too much. Fall back to the
    # strongest workers we have (don't reject).
    $maxStr = ($pool | Measure-Object -Property strength -Maximum).Maximum
    $candidates = @($pool | Where-Object { [int]$_.strength -eq [int]$maxStr })
  }

  # 4. Opus guard
  if (-not $opusOk) {
    $woOpus = @($candidates | Where-Object { -not (([string]$_.cli -eq 'claude') -and ([string]$_.model -match 'opus')) })
    if ($woOpus.Count -gt 0) { $candidates = $woOpus }
  }

  # 3. Avoid double-booking
  $unused = @($candidates | Where-Object { $AlreadyUsedIds -notcontains [string]$_.id })
  if ($unused.Count -gt 0) { $candidates = $unused }

  # 5. Domain preference
  $domainMatch = @($candidates | Where-Object { @($_.domains) -contains $domain -or @($_.domains) -contains 'any' })
  if ($domainMatch.Count -gt 0) { $candidates = $domainMatch }
  # Also try a stricter domain match (without 'any') to prefer specialists
  $strictDomain = @($candidates | Where-Object { @($_.domains) -contains $domain })
  if ($strictDomain.Count -gt 0) { $candidates = $strictDomain }

  # 6. Pick cheapest + fastest
  # 2026-05-27v6: tie-breaker visibility (audit #11). Sort by cost asc, then speed
  # desc, then id alphabetic for deterministic tie-break. If multiple candidates
  # have equal (cost, speed) after sort, log the tie so we can detect routing surprises.
  $sorted = @($candidates | Sort-Object @{Expression={[int]$_.cost}; Descending=$false}, @{Expression={[int]$_.speed}; Descending=$true}, @{Expression={[string]$_.id}; Descending=$false})
  $pick = $sorted | Select-Object -First 1
  if ($pick -and $sorted.Count -ge 2) {
    $second = $sorted[1]
    if ([int]$pick.cost -eq [int]$second.cost -and [int]$pick.speed -eq [int]$second.speed) {
      try {
        $tieIds = ($sorted | Where-Object { [int]$_.cost -eq [int]$pick.cost -and [int]$_.speed -eq [int]$pick.speed } | ForEach-Object { $_.id }) -join ','
        Add-Message -From system -Text ("🔀 Router tie-break: picked " + $pick.id + " from equal candidates [" + $tieIds + "] (cost=" + $pick.cost + ", speed=" + $pick.speed + ", id-alphabet).") -Kind event | Out-Null
      } catch {}
    }
  }
  return $pick
}
