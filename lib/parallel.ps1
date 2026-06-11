# parallel.ps1 -- run several workers IN PARALLEL, each in its own git worktree of a
# PROJECT repo, then merge each back (conflict-safe). The core of Скачок №1 (команда).
# Refuses to parallelize the bridge's own repo (self-modification must stay serial/safe).
# Dot-sourced from common.ps1.

function Invoke-ParallelWorkers {
  # $Workers: array of @{ name; command } -- command runs in that worker's worktree (cmd /c).
  # $OnTick: optional scriptblock run each poll (driver passes a heartbeat refresher).
  # Returns @{ results=@(@{name;mergeOk;conflict;tail}); merged; conflicts; error }.
  param([string]$RepoRoot, [object[]]$Workers, [int]$TimeoutSec = 1800, [scriptblock]$OnTick = $null)
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path (Join-Path $RepoRoot '.git'))) { return @{ error = 'not a git repo'; results=@(); merged=0; conflicts=0 } }
  $bridge = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\')
  if ([System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') -eq $bridge) { return @{ error = 'refuse: cannot parallelize the bridge repo itself'; results=@(); merged=0; conflicts=0 } }
  if (-not $Workers -or @($Workers).Count -eq 0) { return @{ error = 'no workers'; results=@(); merged=0; conflicts=0 } }
  $jobsDir = Get-JobsDir; if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null }
  $u8 = New-Object System.Text.UTF8Encoding($false)
  $units = @()
  # 1) launch every worker in parallel, each in its own worktree
  foreach ($w in @($Workers)) {
    $name = [string]$w.name; if ([string]::IsNullOrWhiteSpace($name)) { $name = [guid]::NewGuid().ToString('N').Substring(0,6) }
    $wt = New-Worktree -RepoRoot $RepoRoot -Name $name
    if (-not $wt) { $units += @{ w=$w; wt=$null; proc=$null; out=$null }; continue }
    $out = Join-Path $jobsDir ('par_' + ($wt.branch -replace '[\\/]','_') + '.log')
    $cmdF = "$out.cmd"; [System.IO.File]::WriteAllText($cmdF, [string]$w.command, $u8)
    $runner = "$out.run.ps1"
    $rs = @"
`$ErrorActionPreference='Continue'
try { Set-Location -LiteralPath '$($wt.path)' } catch {}
`$c = Get-Content -LiteralPath '$cmdF' -Raw
try { & `$env:ComSpec /c `$c *>> '$out' 2>&1 } catch { `$_ | Out-File -Append -LiteralPath '$out' }
"@
    [System.IO.File]::WriteAllText($runner, $rs, (New-Object System.Text.UTF8Encoding($true)))
    $proc = $null
    try {
      $proc = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$runner -WindowStyle Hidden -PassThru
      }
      $null = $proc.Handle
    } catch {}
    $units += @{ w=$w; wt=$wt; proc=$proc; out=$out }
  }
  # 2) wait for ALL to finish (heartbeat via OnTick so the watchdog stays calm)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $alive = @($units | Where-Object { $_.proc -and -not $_.proc.HasExited })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 3
    if ($OnTick) { try { & $OnTick } catch {} }
  }
  # 3) merge each worktree back (sequential, conflict-safe), then clean up
  $results = New-Object System.Collections.Generic.List[object]
  $merged = 0; $conflicts = 0
  foreach ($u in $units) {
    if (-not $u.wt) { [void]$results.Add(@{ name=[string]$u.w.name; mergeOk=$false; conflict=$false; tail='(worktree creation failed)' }); continue }
    try { if ($u.proc -and -not $u.proc.HasExited) { Stop-BridgeJob @{ pid=$u.proc.Id; startTicks=0 } } } catch {}
    $tail = ''; try { $tail = Get-Content -LiteralPath $u.out -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    if ($null -eq $tail) { $tail = '' }
    if ($tail.Length -gt 800) { $tail = '...' + $tail.Substring($tail.Length - 800) }
    $m = Merge-Worktree -Wt $u.wt -Message ('bridge parallel: ' + [string]$u.w.name)
    if ($m.ok) { $merged++ } elseif ($m.conflict) { $conflicts++ }
    Remove-Worktree $u.wt
    [void]$results.Add(@{ name=[string]$u.w.name; mergeOk=$m.ok; conflict=$m.conflict; tail=$tail })
  }
  return @{ results = @($results.ToArray()); merged = $merged; conflicts = $conflicts; error = '' }
}

function Invoke-CodexParallel {
  # Dispatch independent sub-tasks to PARALLEL Codex workers, each in its own worktree of
  # $RepoRoot, then merge each back. $Subtasks = string[]. Returns
  # @{ results=@(@{name;subtask;mergeOk;conflict;tail}); merged; conflicts; error }.
  param([string]$RepoRoot, [string[]]$Subtasks, [scriptblock]$OnTick = $null, [int]$TimeoutSec = 3600)
  $ErrorActionPreference = 'Continue'
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path (Join-Path $RepoRoot '.git'))) { return @{ error='not a git repo'; results=@(); merged=0; conflicts=0 } }
  $bridge = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\')
  if ([System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') -eq $bridge) { return @{ error='refuse: cannot parallelize the bridge repo itself'; results=@(); merged=0; conflicts=0 } }
  $subs = @($Subtasks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($subs.Count -eq 0) { return @{ error='no subtasks'; results=@(); merged=0; conflicts=0 } }
  $codex = $null
  try { $codex = Resolve-CodexExe (Get-BridgeConfig) } catch { return @{ error='codex.exe not found'; results=@(); merged=0; conflicts=0 } }
  $jobsDir = Get-JobsDir; if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null }
  $u8 = New-Object System.Text.UTF8Encoding($false)
  $units = @(); $idx = 0
  foreach ($st in $subs) {
    $idx++
    $wt = New-Worktree -RepoRoot $RepoRoot -Name ("w$idx-" + ([guid]::NewGuid().ToString('N').Substring(0,4)))
    if (-not $wt) { $units += @{ name="w$idx"; wt=$null; proc=$null; subtask=$st }; continue }
    $g = [guid]::NewGuid().ToString('N').Substring(0,8)
    $inF=Join-Path $jobsDir "pin_$g.txt"; $msgF=Join-Path $jobsDir "pmsg_$g.txt"; $outF=Join-Path $jobsDir "pout_$g.txt"; $errF=Join-Path $jobsDir "perr_$g.txt"
    $wprompt = "Ты — воркер в параллельной команде разработчиков. Работаешь в ИЗОЛИРОВАННОЙ копии репозитория (текущая папка). Выполни ТОЛЬКО свою под-задачу: реально (файлы/команды), проверь результат запуском, кратко отчитайся по-русски. НЕ трогай лишнее.`n`nПОД-ЗАДАЧА:`n$st"
    [System.IO.File]::WriteAllText($inF, $wprompt, $u8)
    $proc = $null
    try {
      # SECURITY (Ф2): honor config-driven sandbox instead of hardcoded danger-full-access.
      # See Invoke-ParallelCodexCli for the full rationale (on Windows workspace-write IS an OS jail:
      # Codex shell runs as a separate restricted user, so the worker cannot write linked-worktree git
      # metadata; Project Foundry uses host-managed commit. --add-dir still helps where it CAN write).
      $cpSandbox = 'workspace-write'
      try { if (Get-Command Get-CoderSandboxMode -ErrorAction SilentlyContinue) { $cpSandbox = [string](Get-CoderSandboxMode) } } catch {}
      if ([string]::IsNullOrWhiteSpace($cpSandbox)) { $cpSandbox = 'workspace-write' }
      $cpArgs = @('exec','--color','never','--skip-git-repo-check','-c','model_reasoning_effort="xhigh"','-s',$cpSandbox)
      if ($cpSandbox -eq 'workspace-write') {
        $cpGit = $null
        try { if (Get-Command Get-WorktreeGitDir -ErrorAction SilentlyContinue) { $cpGit = Get-WorktreeGitDir $wt.path } } catch {}
        if ($cpGit) { $cpArgs += @('--add-dir', $cpGit) }
      }
      $cpArgs += @('-C',$wt.path,'-o',$msgF,'-')
      $proc = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
        Start-Process -FilePath $codex -ArgumentList $cpArgs `
          -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
      }
      $null = $proc.Handle
    } catch {}
    $units += @{ name="w$idx"; wt=$wt; proc=$proc; inF=$inF; msgF=$msgF; outF=$outF; errF=$errF; subtask=$st }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $alive = @($units | Where-Object { $_.proc -and -not $_.proc.HasExited })
    if ($alive.Count -eq 0) { break }
    Start-Sleep -Seconds 5
    if ($OnTick) { try { & $OnTick } catch {} }
  }
  $results = New-Object System.Collections.Generic.List[object]; $merged=0; $conflicts=0
  foreach ($u in $units) {
    if (-not $u.wt) { [void]$results.Add(@{ name=$u.name; subtask=$u.subtask; mergeOk=$false; conflict=$false; tail='(worktree creation failed)' }); continue }
    try { if ($u.proc -and -not $u.proc.HasExited) { & taskkill /PID $u.proc.Id /T /F 2>$null | Out-Null } } catch {}
    $tail = ''
    try { $tail = Get-Content -LiteralPath $u.msgF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    if ([string]::IsNullOrWhiteSpace($tail)) { try { $tail = Get-Content -LiteralPath $u.outF -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch {} }
    if ($null -eq $tail) { $tail = '' }
    if ($tail.Length -gt 700) { $tail = '...' + $tail.Substring($tail.Length - 700) }
    $m = Merge-Worktree -Wt $u.wt -Message ('parallel: ' + $u.name)
    if ($m.ok) { $merged++ } elseif ($m.conflict) { $conflicts++ }
    Remove-Worktree $u.wt
    [void]$results.Add(@{ name=$u.name; subtask=$u.subtask; mergeOk=$m.ok; conflict=$m.conflict; tail=$tail })
    try { Remove-Item $u.inF,$u.msgF,$u.outF,$u.errF -Force -ErrorAction SilentlyContinue } catch {}
  }
  return @{ results = @($results.ToArray()); merged = $merged; conflicts = $conflicts; error = '' }
}

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
  # files -> 'architectural' (unlocks premium Claude via Select-WorkerForStream).
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

function Test-ParallelPremiumClaudeWorker {
  param([object]$Worker)
  if (-not $Worker) { return $false }
  if ([string]$Worker.cli -ne 'claude') { return $false }
  $label = (([string]$Worker.id) + ' ' + ([string]$Worker.model)).ToLowerInvariant()
  return ($label -match '(opus|fable|mythos)')
}

function Select-WorkerForStream {
  # Returns the best worker for a stream given an already-used set (no double
  # booking unless pool is exhausted). Algorithm:
  #   1. Explicit `worker: ID` override wins immediately if id exists in pool.
  #   2. Filter pool by strength >= complexityFloor[complexity].
  #   3. Remove already-used buckets (unless pool gets empty).
  #   4. Protect premium Claude models: skip Opus/Fable/Mythos unless complexity=architectural OR
  #      stream has an explicit premium marker.
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
  $premiumClaudeOk = ($complexity -eq 'architectural') -or ([bool]$Stream.opus) -or ([bool]$Stream.premium)

  # 2. Strength floor
  $candidates = @($pool | Where-Object { [int]$_.strength -ge $floor })
  if ($candidates.Count -eq 0) {
    # No worker meets the floor — caller asked for too much. Fall back to the
    # strongest workers we have (don't reject).
    $maxStr = ($pool | Measure-Object -Property strength -Maximum).Maximum
    $candidates = @($pool | Where-Object { [int]$_.strength -eq [int]$maxStr })
  }

  # 4. Premium Claude guard
  if (-not $premiumClaudeOk) {
    $woPremiumClaude = @($candidates | Where-Object { -not (Test-ParallelPremiumClaudeWorker $_) })
    if ($woPremiumClaude.Count -gt 0) { $candidates = $woPremiumClaude }
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

# --- Per-CLI invocation functions ---

function Invoke-ParallelCodexCli {
  # Launch codex.exe with -m <model> -c model_reasoning_effort="<level>".
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $cfg = Get-BridgeConfig
  $codex = Resolve-CodexExe $cfg
  $model = [string]$Worker.model
  $effort = [string]$Worker.reasoning
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'gpt-5.5' }
  if ([string]::IsNullOrWhiteSpace($effort)) { $effort = 'high' }
  # SECURITY (Ф2): parallel/foundry workers used to hardcode -s danger-full-access, which fully
  # disables Codex's own command guards. Honor the same config-driven sandbox as the serial coder
  # (Get-CoderSandboxMode -> default 'workspace-write', fail-closed). EMPIRICAL CORRECTION
  # (Gate C, 2026-05-29 -- supersedes an earlier wrong note that said "not OS-enforced on Windows"):
  # workspace-write IS OS-enforced on this Windows host. Codex runs shell commands as a SEPARATE
  # restricted user account 'CodexSandboxOffline' (SID ...-1003), distinct from the repo owner
  # 'rafie' (SID ...-1001). Consequence for LINKED worktrees: even though --add-dir puts the shared
  # <project>/.git in Codex's writable-roots, the NTFS ACL still denies the sandbox user write to
  # .git/worktrees/<id>/, so it cannot create index.lock and therefore cannot 'git add'/'git commit'
  # (verified: jobs/parallel/worker_s1_*.err.txt -> "Unable to create ...index.lock: Permission
  # denied"). FIX: Project Foundry workers run in HOST-MANAGED-COMMIT mode -- the worker only PRODUCES
  # files in its worktree cwd (which the sandbox CAN write) and the trusted host (repo owner) does the
  # git add/commit afterwards (see Get-FoundryDefaultOps Result Op + Spawn-Worker -HostManagedCommit).
  # --add-dir below stays: harmless for the host-commit path, and still useful where the sandbox CAN
  # write git metadata (Temp-rooted repos / Linux/macOS), so workers there can still commit directly.
  $sandbox = 'workspace-write'
  try { if (Get-Command Get-CoderSandboxMode -ErrorAction SilentlyContinue) { $sandbox = [string](Get-CoderSandboxMode) } } catch {}
  if ([string]::IsNullOrWhiteSpace($sandbox)) { $sandbox = 'workspace-write' }
  $cliArgs = @(
    'exec','--color','never','--skip-git-repo-check',
    '-c', "model=`"$model`"",
    '-c', "model_reasoning_effort=`"$effort`"",
    '-s', $sandbox
  )
  if ($sandbox -eq 'workspace-write') {
    $gitDir = $null
    try { if (Get-Command Get-WorktreeGitDir -ErrorAction SilentlyContinue) { $gitDir = Get-WorktreeGitDir $Worktree } } catch {}
    if ($gitDir) { $cliArgs += @('--add-dir', $gitDir) }
  }
  $cliArgs += @('-C',$Worktree,'-o',$MsgFile,'-')
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath $codex -ArgumentList $cliArgs `
      -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
      -NoNewWindow -PassThru
  }
}

function Invoke-ParallelClaudeCli {
  # Launch claude.exe in the worktree. Claude CLI has NO --cwd flag; use
  # Start-Process -WorkingDirectory to set the process cwd, then --add-dir
  # to grant tool access to that path (in case CLAUDE.md/AGENTS.md lookup
  # cares). 2026-05-27 fix: previous version used --cwd which Claude CLI
  # rejected with "unknown option" → every claude-* worker failed silently.
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $cfg = Get-BridgeConfig
  $claude = Resolve-ClaudeExe $cfg
  $model = [string]$Worker.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'sonnet' }
  $cliArgs = @(
    '-p','--permission-mode','acceptEdits',
    '--add-dir', $Worktree,
    '--allowedTools','Read','Grep','Glob','Bash','Edit','MultiEdit','Write',
    '--model', $model
  )
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath $claude -ArgumentList $cliArgs `
      -WorkingDirectory $Worktree `
      -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
      -NoNewWindow -PassThru
  }
}

function Invoke-ParallelLLMCli {
  # 2026-06-01 (Foundation #4 scale): parallel worker backed by an API LLM (DeepSeek/Gemini) which has
  # NO agentic CLI. Launches a powershell process running tools/parallel-llm-worker.ps1 — it asks the
  # model for full file contents, writes them into the worktree, and commits. Same contract as the
  # codex/claude CLIs (returns System.Diagnostics.Process).
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $model = [string]$Worker.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-v4-pro' }
  $script = Join-Path (Get-BridgeRoot) 'tools\parallel-llm-worker.ps1'
  $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Model', $model, '-Worktree', $Worktree, '-InFile', $InFile, '-MsgFile', $MsgFile)
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cliArgs `
      -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -NoNewWindow -PassThru
  }.GetNewClosure()
}

# To add another CLI/LLM: implement Invoke-ParallelXxxCli with the same signature
# (returns System.Diagnostics.Process), then add to $Script:ParallelCliRegistry above
# and add worker entries to config.json.

function Get-ParallelRoot {
  Join-Path (Get-BridgeRoot) 'worktrees\parallel'
}

function Get-ParallelJobsDir {
  $dir = Join-Path (Get-BridgeRoot) 'jobs\parallel'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Normalize-ParallelId {
  param([string]$Value)
  $safe = ([string]$Value).Trim() -replace '[^A-Za-z0-9_.-]+','-'
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = [guid]::NewGuid().ToString('N').Substring(0,8) }
  return $safe
}

function Normalize-ParallelFilePath {
  param([string]$Path)
  $p = ([string]$Path).Trim()
  $p = $p.Trim(" `t`r`n""'`.,;")
  if ($p.StartsWith('./') -or $p.StartsWith('.\')) { $p = $p.Substring(2) }
  $p = $p -replace '\\','/'
  while ($p.StartsWith('/')) { $p = $p.Substring(1) }
  return $p.ToLowerInvariant()
}

function Split-ParallelFileList {
  param([string]$Text)
  $items = New-Object System.Collections.Generic.List[string]
  $raw = ([string]$Text).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $raw = $raw -replace '\[\[/?FILES?\]\]',''
  foreach ($part in ($raw -split '[,;]')) {
    $p = ([string]$part).Trim()
    $p = $p -replace '^\s*[-*]\s+',''
    $p = $p.Trim(" `t`r`n""'`.,;")
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($p -match '\s+#') { $p = ($p -split '\s+#',2)[0].Trim() }
    $n = Normalize-ParallelFilePath $p
    if (-not [string]::IsNullOrWhiteSpace($n)) { [void]$items.Add($n) }
  }
  return @($items.ToArray() | Sort-Object -Unique)
}

function Get-ParallelFilesFromBody {
  param([string]$Body)
  $files = New-Object System.Collections.Generic.List[string]
  $text = [string]$Body

  foreach ($m in [regex]::Matches($text, '\[\[FILES?:(?<files>[^\]]+)\]\]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    foreach ($f in (Split-ParallelFileList $m.Groups['files'].Value)) { [void]$files.Add($f) }
  }

  $lines = $text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    $m = [regex]::Match($line, '^\s*(?:files?|touches|allowed\s+files|файлы)\s*:\s*(?<files>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }
    $tail = ([string]$m.Groups['files'].Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($tail)) {
      foreach ($f in (Split-ParallelFileList $tail)) { [void]$files.Add($f) }
      continue
    }
    $j = $i + 1
    while ($j -lt $lines.Count) {
      $next = [string]$lines[$j]
      if ([string]::IsNullOrWhiteSpace($next)) { break }
      if ($next -match '^\s*(?:complexity|сложность|body|task|задача)\s*:') { break }
      if ($next -match '^\s*[-*]\s+(?<file>.+)$') {
        foreach ($f in (Split-ParallelFileList $Matches['file'])) { [void]$files.Add($f) }
      } else {
        break
      }
      $j++
    }
  }

  return @($files.ToArray() | Sort-Object -Unique)
}

function Get-ParallelComplexityFromBody {
  # Accepts: simple, moderate, complex, architectural (English) or
  #          простая, умеренная, сложная, архитектурная (Russian, mapped).
  # Default 'moderate' if not specified.
  param([string]$Body)
  $m = [regex]::Match([string]$Body, '^\s*(?:complexity|сложность)\s*:\s*(?<c>simple|moderate|complex|architectural|простая|умеренная|сложная|архитектурная)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $m.Success) { return 'moderate' }
  $c = $m.Groups['c'].Value.ToLowerInvariant()
  switch ($c) {
    'простая'       { return 'simple' }
    'умеренная'     { return 'moderate' }
    'сложная'       { return 'complex' }
    'архитектурная' { return 'architectural' }
    default         { return $c }
  }
}

function Test-CanParallelize {
  param([string]$PlanText)
  if ([string]::IsNullOrWhiteSpace($PlanText)) { return $null }

  $matches = [regex]::Matches(
    [string]$PlanText,
    '\[\[PARALLEL:(?<id>[A-Za-z0-9_.-]+)\]\](?<body>.*?)\[\[/PARALLEL:\k<id>\]\]',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($matches.Count -lt 2) { return $null }

  # 2026-06-11 A3 (speed program): this used to be ALL-OR-NOTHING — one block without Files:
  # or one file shared by two streams returned $null and collapsed the ENTIRE wave to serial
  # (N -> 0 from a single malformed block). Now the offending stream is DROPPED and the rest
  # still parallelize (>=2 survivors); dropped blocks stay in the plan text, so the planner
  # sees their results missing after the wave and finishes them via the normal mixed path.
  $streams = New-Object System.Collections.Generic.List[object]
  $owners = @{}
  $droppedStreams = New-Object System.Collections.Generic.List[string]
  foreach ($m in $matches) {
    $id = Normalize-ParallelId $m.Groups['id'].Value
    $body = ([string]$m.Groups['body'].Value).Trim()
    $files = @(Get-ParallelFilesFromBody $body)
    if ($files.Count -eq 0) {
      [void]$droppedStreams.Add($id + ' (no Files: declared)')
      continue
    }

    $conflictFile = ''
    foreach ($f in $files) {
      if ($owners.ContainsKey($f) -and [string]$owners[$f] -ne $id) { $conflictFile = [string]$f; break }
    }
    if (-not [string]::IsNullOrWhiteSpace($conflictFile)) {
      [void]$droppedStreams.Add($id + " (file '" + $conflictFile + "' already owned by " + [string]$owners[$conflictFile] + ')')
      continue
    }
    foreach ($f in $files) { $owners[$f] = $id }

    [void]$streams.Add([pscustomobject]@{
      id         = $id
      files      = @($files)
      complexity = Get-ParallelComplexityFromBody $body
      opus       = ([string]$body -match '\[\[(OPUS|FABLE|PREMIUM)\]\]')
      premium    = ([string]$body -match '\[\[(OPUS|FABLE|PREMIUM)\]\]')
      body       = $body
    })
  }

  if ($droppedStreams.Count -gt 0 -and $streams.Count -ge 2 -and (Get-Command Add-Message -ErrorAction SilentlyContinue)) {
    try { Add-Message -From system -Text ("⚠ Parallel: исключены стримы (" + ($droppedStreams -join '; ') + ") — остальные " + $streams.Count + " идут параллельно; выпавшие доделает планировщик после волны.") -Kind event | Out-Null } catch {}
  }
  if ($streams.Count -lt 2) { return $null }
  return @($streams.ToArray())
}

function Get-ParallelRepoRoot {
  # 2026-05-31 (Foundation #4 scale): the git repo a parallel worker's worktree branches from.
  # PROJECT channel -> its project_root (isolated git) => safe high-fan-out parallelism with no
  # cross-worker conflicts. main/bridge channel -> the bridge root (unchanged behaviour).
  try {
    if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
      $pr = Get-EffectiveProjectRoot
      if (-not [string]::IsNullOrWhiteSpace([string]$pr) -and (Test-Path (Join-Path ([string]$pr) '.git'))) { return [string]$pr }
    }
  } catch {}
  return (Get-BridgeRoot)
}

function Get-ParallelTaskBaseCommit {
  $ErrorActionPreference = 'Continue'
  $base = ''
  try {
    $st = Read-State
    if ($st -and ($st.PSObject.Properties.Name -contains 'task_base_commit')) { $base = [string]$st.task_base_commit }
  } catch {}
  $repoRoot = Get-ParallelRepoRoot
  # 2026-06-01 (Foundation #4): the base commit MUST exist in the repo the worktree branches from.
  # For a PROJECT channel that's project_root, but task_base_commit was set to the BRIDGE HEAD ->
  # 'git worktree add <path> <bridge-sha>' fails ("invalid reference"), which killed EVERY parallel
  # run and forced serial fallback (worktrees=0). Drop a base that doesn't exist in this repo and
  # fall back to its real HEAD.
  if (-not [string]::IsNullOrWhiteSpace($base)) {
    $baseOk = $false
    try { $baseOk = ((& git -C $repoRoot cat-file -t $base 2>$null) -match 'commit') } catch {}
    if (-not $baseOk) { $base = '' }
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    try { $base = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1) } catch {}
  }
  $baseText = [string]$base
  if ($null -eq $baseText) { return '' }
  return $baseText.Trim()
}

function Get-WorkerWorktree {
  param([string]$StreamId, [string]$TaskHash)
  $ErrorActionPreference = 'Continue'
  $sid = Normalize-ParallelId $StreamId
  $hash = Normalize-ParallelId $TaskHash
  $root = Join-Path (Get-ParallelRoot) $hash
  $path = Join-Path $root $sid
  if (Test-Path -LiteralPath $path) { return [System.IO.Path]::GetFullPath($path) }

  if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
  $branch = "wip/parallel/$hash/$sid"
  $base = Get-ParallelTaskBaseCommit
  if ([string]::IsNullOrWhiteSpace($base)) { throw 'parallel: cannot resolve task_base_commit or HEAD' }
  $git = Get-GitExe

  $repoRoot = Get-ParallelRepoRoot
  $branchExists = $false
  try {
    & $git -C $repoRoot show-ref --verify --quiet "refs/heads/$branch"
    $branchExists = ($LASTEXITCODE -eq 0)
  } catch { $branchExists = $false }

  if ($branchExists) {
    & $git -C $repoRoot worktree add $path $branch 2>&1 | Out-Null
  } else {
    & $git -C $repoRoot worktree add -b $branch $path $base 2>&1 | Out-Null
  }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path)) { throw "parallel: git worktree add failed for $branch" }
  return [System.IO.Path]::GetFullPath($path)
}

function Cleanup-WorkerWorktree {
  param([string]$StreamId, [string]$TaskHash)
  $ErrorActionPreference = 'Continue'
  $sid = Normalize-ParallelId $StreamId
  $hash = Normalize-ParallelId $TaskHash
  $root = [System.IO.Path]::GetFullPath((Get-ParallelRoot)).TrimEnd('\')
  $path = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $root $hash) $sid))
  if (-not $path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { throw "parallel: unsafe worktree path $path" }

  $git = Get-GitExe
  try { & $git -C (Get-ParallelRepoRoot) worktree remove --force $path 2>&1 | Out-Null } catch {}
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
  # L2 (load audit): also reap this worker's job files (worker_<sid>_*.{in,msg,out,err}.txt).
  # Invoke-ParallelDispatch leaked them (only Invoke-CodexParallel cleaned up) -- 4 files/spawn x
  # respawns x 100s of tasks bloated jobs/parallel and inflated the jobs-weighted adaptive probe
  # timeout. Cleanup-WorkerWorktree runs on every exit path, so this reaps them everywhere.
  try {
    $jobsDir = Get-ParallelJobsDir
    if (Test-Path -LiteralPath $jobsDir) {
      Get-ChildItem -LiteralPath $jobsDir -Filter ("worker_${sid}_*") -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}

function New-ParallelWorkerPrompt {
  param([string]$Body, [string[]]$Files, [string]$BranchName)
  $fileText = if ($Files -and $Files.Count -gt 0) { ($Files | ForEach-Object { "- $_" }) -join "`n" } else { "- (files not declared)" }
  return @"
Ты параллельный coder-worker внутри bridge task. Работаешь в отдельном git worktree и своей ветке `$BranchName`.

Жёсткие правила:
- Меняй только разрешённые файлы ниже.
- Не трогай файлы вне текущего worktree.
- Не откатывай чужие изменения и не меняй соседние parallel streams.
- После правок запусти короткую проверку, затем сделай git add/commit в своей ветке.
- Финальная строка должна быть STATUS: DONE, STATUS: FAILED, STATUS: PARTIAL ИЛИ STATUS: CONTINUE-CHUNK:N/M (см. ниже).
- ЗАПРЕЩЕНО создавать файл control/restart.flag (ни в своём worktree, ни в основном репо по любому пути). Это убивает соседние параллельные потоки. Драйвер решит про restart сам после merge.
- ЗАПРЕЩЕНО менять файлы вне своего worktree (даже если путь технически доступен).

ЧАНКИНГ ВНУТРИ ПОТОКА (опция для больших подзадач):
Если твоя подзадача естественно делится на 3+ независимых коммита и есть риск таймаута за один проход — разбей её на этапы:
  1. Сделай первый этап работы, ОБЯЗАТЕЛЬНО git add + git commit в своей ветке.
  2. Финальная строка ровно: `STATUS: CONTINUE-CHUNK:N/M` (N — номер только что закрытого этапа, 1-based; M — всего этапов).
  3. Драйвер проверит что твой коммит появился, перезапустит тебя В ТОМ ЖЕ worktree с контекстом следующего этапа.
  4. Когда все этапы готовы — обычный `STATUS: DONE`.
Лимит: 10 чанков на воркера (защита от runaway). Для мелких подзадач (1 коммит) чанкинг НЕ нужен — обычный `STATUS: DONE`. Используй чанки только когда видишь явное многоэтапное деление работы.

🔢 ПРАВИЛО ПРОВЕРКИ ЧИСЛЕННЫХ УТВЕРЖДЕНИЙ:
Если в своём STATUS-отчёте пишешь число («обработал N items», «X из Y файлов», «N/M прошли») — ОБЯЗАТЕЛЬНО приложи вывод реальной команды-доказательства. Без proof'а драйвер автоматически (через Test-CoderClaims gate) поймает несоответствие и заявит несостыковку планировщику. Шаблон: «N=51 → `<cmd>` → `<actual output>`».

Разрешённые файлы:
$fileText

Подзадача:
$Body
"@
}

function New-ParallelWorkerContinuationPrompt {
  # Used when a worker emitted STATUS: CONTINUE-CHUNK:N/M and driver respawns
  # it in the SAME worktree for the next chunk. The body is preserved, but
  # we add chunk context so the worker knows where it is in the sequence.
  param([string]$Body, [string[]]$Files, [string]$BranchName, [int]$NextChunk, [int]$TotalChunks, [string]$LastCommitSha)
  $fileText = if ($Files -and $Files.Count -gt 0) { ($Files | ForEach-Object { "- $_" }) -join "`n" } else { "- (files not declared)" }
  $shortSha = if ($LastCommitSha.Length -gt 7) { $LastCommitSha.Substring(0,7) } else { $LastCommitSha }
  return @"
Ты параллельный coder-worker. ПРОДОЛЖАЕШЬ работу в том же git worktree (ветка `$BranchName`).

ПРЕДЫДУЩИЙ ЭТАП завершён: chunk $($NextChunk - 1)/$TotalChunks, последний коммит: $shortSha.
ТЕКУЩИЙ ЭТАП: chunk $NextChunk/$TotalChunks.

Жёсткие правила (те же что и в первом запуске):
- Меняй только разрешённые файлы ниже.
- Не трогай файлы вне текущего worktree.
- После правок текущего этапа ОБЯЗАТЕЛЬНО git add + git commit в своей ветке.
- ЗАПРЕЩЕНО создавать control/restart.flag.
- Финальная строка ровно:
    • `STATUS: CONTINUE-CHUNK:$NextChunk/$TotalChunks` — если впереди ещё этап;
    • `STATUS: DONE` — если этот этап последний и вся подзадача завершена;
    • `STATUS: FAILED` или `STATUS: PARTIAL` — при провале.

Разрешённые файлы:
$fileText

Подзадача (целиком — продолжай выполнять с этапа $NextChunk):
$Body
"@
}

function _NormalizeRelPath {
  param([string]$Rel)
  if ([string]::IsNullOrWhiteSpace($Rel)) { return $null }
  $raw = ([string]$Rel).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  if ([System.IO.Path]::IsPathRooted($raw)) { return $null }
  $n = $raw.Replace('\','/')
  if ($n.StartsWith('./')) { $n = $n.Substring(2) }
  if ($n.StartsWith('/') -or $n.StartsWith('\')) { return $null }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($segment in ($n -split '/+')) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
    if ($segment -eq '..') { return $null }
    [void]$parts.Add($segment)
  }
  if ($parts.Count -eq 0) { return $null }
  return ($parts -join '/')
}

function Test-ParallelCollectedPathAllowed {
  param(
    [string]$RelativePath,
    [string[]]$DeclaredFiles
  )

  $rel = _NormalizeRelPath $RelativePath
  if ($null -eq $rel) { return $false }
  if ($rel -eq '.git' -or $rel.StartsWith('.git/')) { return $false }
  if (-not $DeclaredFiles -or @($DeclaredFiles).Count -eq 0) { return $false }

  foreach ($d in @($DeclaredFiles)) {
    $dn = _NormalizeRelPath $d
    if ($null -eq $dn) { continue }
    if ($dn -eq '.git' -or $dn.StartsWith('.git/')) { continue }
    if ([string]::Equals($rel, $dn, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($rel.StartsWith($dn + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Test-ParallelCollectedPathAllowedSelfCheck {
  $cases = @(
    @{ name='exact';     rel='lib/parallel.ps1';                 declared=@('lib/parallel.ps1'); expect=$true  }
    @{ name='child';     rel='lib/subdir/file.ps1';             declared=@('lib');              expect=$true  }
    @{ name='outside';   rel='scripts/build.ps1';               declared=@('lib');              expect=$false }
    @{ name='dotgit';    rel='.git/config';                     declared=@('.git', 'lib');      expect=$false }
    @{ name='traversal'; rel='../outside.ps1';                  declared=@('lib');              expect=$false }
    @{ name='blank';     rel='';                                declared=@('lib');              expect=$false }
  )

  foreach ($case in $cases) {
    $actual = Test-ParallelCollectedPathAllowed -RelativePath $case.rel -DeclaredFiles $case.declared
    if ([bool]$actual -ne [bool]$case.expect) {
      throw ("parallel collection guard self-check failed for case '" + $case.name + "' (rel=" + $case.rel + ", expected=" + $case.expect + ", actual=" + $actual + ")")
    }
  }

  return $true
}

function Invoke-ParallelOutsideFilesCheckout {
  param(
    [string]$RepoRoot,
    [string[]]$OutsideFiles,
    [string[]]$DeclaredFiles = @(),
    [string]$GitExe = '',
    [scriptblock]$GitRunner = $null
  )

  $result = [pscustomobject]@{
    ok = $true
    paths = @()
    exitCodes = @()
    output = @()
    message = ''
  }

  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) {
    $result.ok = $false
    $result.message = 'repo root is missing'
    return $result
  }

  $safePaths = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in @($OutsideFiles)) {
    $rel = _NormalizeRelPath $p
    if ($null -eq $rel) { continue }
    if ($rel -eq '.git' -or $rel.StartsWith('.git/')) { continue }
    if (Test-ParallelCollectedPathAllowed -RelativePath $rel -DeclaredFiles $DeclaredFiles) { continue }
    if (-not $safePaths.Contains($rel)) { [void]$safePaths.Add($rel) }
  }

  if ($safePaths.Count -eq 0) {
    $result.paths = @()
    $result.message = 'no safe outside paths to checkout'
    return $result
  }

  if ([string]::IsNullOrWhiteSpace($GitExe)) { $GitExe = Get-GitExe }
  $result.paths = @($safePaths)

  $commands = New-Object 'System.Collections.Generic.List[object]'
  [void]$commands.Add([string[]](@('reset', '-q', '--') + @($safePaths)))
  [void]$commands.Add([string[]](@('checkout', '--') + @($safePaths)))

  foreach ($cmdArgs in $commands) {
    $gitArgs = [string[]]@($cmdArgs)
    $exitCode = 0
    $output = @()
    if ($null -ne $GitRunner) {
      $runResult = & $GitRunner $GitExe $RepoRoot (,$gitArgs)
      if ($null -ne $runResult -and ($runResult.PSObject.Properties.Name -contains 'ExitCode')) {
        $exitCode = [int]$runResult.ExitCode
        try { $output = @($runResult.Output) } catch { $output = @() }
      } else {
        $exitCode = $LASTEXITCODE
        $output = @($runResult)
      }
    } else {
      $output = @(& $GitExe -C $RepoRoot @gitArgs 2>&1)
      $exitCode = $LASTEXITCODE
    }

    $result.exitCodes += $exitCode
    if ($output.Count -gt 0) {
      $result.output += @($output | ForEach-Object { [string]$_ })
    }
    if ($exitCode -ne 0) { $result.ok = $false }
  }

  if (-not $result.ok -and [string]::IsNullOrWhiteSpace($result.message)) {
    $result.message = 'git cleanup failed for outside path(s)'
  }

  return $result
}

function Spawn-Worker {
  # Refactored 2026-05-27: now takes a $WorkerSpec object (one entry from
  # Get-ParallelWorkerPool) and dispatches via $Script:ParallelCliRegistry.
  # Old signature (-Coder $name -Model $name) kept as a thin shim for any
  # callers we missed -- it synthesizes a minimal WorkerSpec.
  [CmdletBinding(DefaultParameterSetName='Spec')]
  param(
    [Parameter(Mandatory=$true)] [string]$StreamId,
    [Parameter(Mandatory=$true)] [string]$Body,
    [Parameter(Mandatory=$true)] [string]$Worktree,
    [Parameter(Mandatory=$true)] [string]$BranchName,
    # Host-managed-commit mode: the worker only PRODUCES files (does not git
    # add/commit); the host commits afterwards. Required where the codex sandbox
    # runs as a separate OS user that cannot write linked-worktree git metadata
    # (Windows). Set by Project Foundry's Prepare Op. Belongs to every param set.
    [switch]$HostManagedCommit,
    [Parameter(ParameterSetName='Spec',  Position=4)] [object]$WorkerSpec,
    [Parameter(ParameterSetName='Legacy')] [string]$Coder,
    [Parameter(ParameterSetName='Legacy')] [string]$Model
  )

  # Back-compat shim: synthesize a WorkerSpec from -Coder/-Model
  if ($PSCmdlet.ParameterSetName -eq 'Legacy') {
    $cName = ([string]$Coder).ToLowerInvariant()
    if ($cName -ne 'claude' -and $cName -ne 'codex') { throw "parallel: unsupported coder '$Coder'" }
    $effort = if ([string]$Model -match 'complex|xhigh') { 'xhigh' } else { 'high' }
    $synthModel = if ($cName -eq 'codex') { 'gpt-5.5' } else { [string]$Model }
    if ([string]::IsNullOrWhiteSpace($synthModel)) { $synthModel = if ($cName -eq 'codex') { 'gpt-5.5' } else { 'sonnet' } }
    $WorkerSpec = [pscustomobject]@{
      id        = "$cName-legacy"
      cli       = $cName
      model     = $synthModel
      reasoning = if ($cName -eq 'codex') { $effort } else { '' }
      strength  = 3; speed = 3; cost = 3
      domains   = @('any')
    }
  }

  if (-not $WorkerSpec) { throw 'parallel: Spawn-Worker requires -WorkerSpec' }
  $sid = Normalize-ParallelId $StreamId
  if ([string]::IsNullOrWhiteSpace($Worktree) -or -not (Test-Path -LiteralPath $Worktree)) {
    throw "parallel: worktree not found for stream $sid"
  }
  $cli = ([string]$WorkerSpec.cli).ToLowerInvariant()
  $handler = $Script:ParallelCliRegistry[$cli]
  if (-not $handler) { throw "parallel: no CLI handler registered for '$cli' (worker $($WorkerSpec.id))" }

  $files = @(Get-ParallelFilesFromBody $Body)
  $jobs = Get-ParallelJobsDir
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,8))
  $prefix = Join-Path $jobs ("worker_${sid}_$stamp")
  $inF  = "$prefix.in.txt"
  $msgF = "$prefix.msg.txt"
  $outF = "$prefix.out.txt"
  $errF = "$prefix.err.txt"
  $prompt = New-ParallelWorkerPrompt -Body $Body -Files $files -BranchName $BranchName
  if ($HostManagedCommit) {
    # Override the prompt's "git add/commit" rule for sandboxes that cannot write
    # linked-worktree git metadata (Windows codex workspace-write runs as a separate
    # restricted user). The worker must NOT commit; the host commits its files.
    $prompt += "`n`nВАЖНО — режим host-managed commit (ПЕРЕОПРЕДЕЛЯЕТ правило про git выше):`n- НЕ выполняй git add и git commit. Фиксацию в git сделает система (host) автоматически после твоего завершения.`n- Просто создай/измени нужные файлы в рабочей папке и убедись, что они корректны.`n- Когда файлы готовы — верни ровно STATUS: DONE (НЕ PARTIAL и НЕ FAILED из-за невозможности закоммитить)."
  }
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $u8)

  # Dispatch to the CLI-specific handler
  $proc = & $handler -Worker $WorkerSpec -Worktree $Worktree -InFile $inF -MsgFile $msgF -OutFile $outF -ErrFile $errF
  if (-not $proc) { throw "parallel: CLI handler '$handler' returned no process for worker $($WorkerSpec.id)" }

  $ticks = [long]0
  try { $ticks = (Get-Process -Id $proc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
  # Initial chunk-base SHA: HEAD of the worker's branch at spawn time. Used by
  # the dispatch poll to detect whether the worker actually committed before
  # claiming CONTINUE-CHUNK:N/M (no advance = worker lied, kill).
  $startSha = ''
  try { $startSha = ((& git -C (Get-ParallelRepoRoot) rev-parse $BranchName 2>$null) | Select-Object -First 1).Trim() } catch {}
  return [pscustomobject]@{
    id            = $sid
    coder         = $cli                       # back-compat field (= CLI)
    cli           = $cli
    workerId      = [string]$WorkerSpec.id
    workerSpec    = $WorkerSpec                # full spec — reused by Respawn-WorkerForChunk
    model         = [string]$WorkerSpec.model
    reasoning     = [string]$WorkerSpec.reasoning
    status        = 'running'
    branch        = [string]$BranchName
    worktree      = [System.IO.Path]::GetFullPath($Worktree)
    pid           = $proc.Id
    pidTicks      = $ticks
    process       = $proc
    inFile        = $inF
    msgFile       = $msgF
    outFile       = $outF
    errFile       = $errF
    body          = [string]$Body
    files         = @($files)
    startedAt     = (Get-Date).ToString('o')
    # Chunk state (initial spawn = no chunks completed yet)
    chunksDone    = 0
    chunkBaseSha  = $startSha   # SHA before any chunk
    chunkLastSha  = $startSha   # SHA after last completed chunk
    chunkTotalM   = 0            # set when worker first declares M
  }
}

function Respawn-WorkerForChunk {
  # After a worker emitted STATUS: CONTINUE-CHUNK:N/M and committed, we respawn
  # the SAME logical worker in the SAME worktree on the SAME wip-branch with a
  # continuation prompt referencing the next chunk. Mutates the $Worker object
  # in-place: new process, new pid/files, updated chunkLastSha/chunksDone.
  # The git worktree state is preserved (the just-committed work stays).
  param([object]$Worker, [int]$NextChunk, [int]$TotalChunks, [string]$LastCommitSha)
  if (-not $Worker) { throw 'Respawn-WorkerForChunk: $Worker is null' }
  if (-not $Worker.workerSpec) { throw "Respawn-WorkerForChunk: worker $($Worker.id) has no workerSpec — cannot respawn" }

  $cli = ([string]$Worker.workerSpec.cli).ToLowerInvariant()
  $handler = $Script:ParallelCliRegistry[$cli]
  if (-not $handler) { throw "Respawn-WorkerForChunk: no CLI handler for '$cli'" }

  $jobs = Get-ParallelJobsDir
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_chunk' + $NextChunk
  $prefix = Join-Path $jobs ("worker_$($Worker.id)_$stamp")
  $inF  = "$prefix.in.txt"
  $msgF = "$prefix.msg.txt"
  $outF = "$prefix.out.txt"
  $errF = "$prefix.err.txt"

  $prompt = New-ParallelWorkerContinuationPrompt `
    -Body $Worker.body -Files @($Worker.files) -BranchName $Worker.branch `
    -NextChunk $NextChunk -TotalChunks $TotalChunks -LastCommitSha $LastCommitSha
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $u8)

  $proc = & $handler -Worker $Worker.workerSpec -Worktree $Worker.worktree -InFile $inF -MsgFile $msgF -OutFile $outF -ErrFile $errF
  if (-not $proc) { throw "Respawn-WorkerForChunk: CLI handler returned no process" }

  $ticks = [long]0
  try { $ticks = (Get-Process -Id $proc.Id -ErrorAction Stop).StartTime.Ticks } catch {}

  # Mutate worker in-place
  $Worker.process     = $proc
  $Worker.pid         = $proc.Id
  $Worker.pidTicks    = $ticks
  $Worker.inFile      = $inF
  $Worker.msgFile     = $msgF
  $Worker.outFile     = $outF
  $Worker.errFile     = $errF
  $Worker.status      = 'running'
  $Worker.chunksDone  = ($NextChunk - 1)
  $Worker.chunkLastSha = $LastCommitSha
  $Worker.chunkTotalM = $TotalChunks
  return $Worker
}

function Get-WorkerReplyText {
  param($Worker)
  $reply = ''
  foreach ($p in @([string]$Worker.msgFile, [string]$Worker.outFile, [string]$Worker.errFile)) {
    if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p)) { continue }
    try { $reply = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } catch { $reply = '' }
    if (-not [string]::IsNullOrWhiteSpace($reply)) { break }
  }
  if ($null -eq $reply) { $reply = '' }
  return [string]$reply
}

function Get-WorkerCommits {
  param($Worker)
  $ErrorActionPreference = 'Continue'
  $branch = [string]$Worker.branch
  if ([string]::IsNullOrWhiteSpace($branch)) { return @() }
  $base = Get-ParallelTaskBaseCommit
  $range = if ([string]::IsNullOrWhiteSpace($base)) { $branch } else { "$base..$branch" }
  try {
    return @(& git -C (Get-ParallelRepoRoot) rev-list --reverse $range 2>$null | ForEach-Object { [string]$_ })
  } catch {
    return @()
  }
}

function Get-WorkerResult {
  param($Worker)
  if (-not $Worker) { return [pscustomobject]@{ status='failed'; reply=''; commits=@(); error='missing worker' } }

  $alive = $false
  $workerPid = 0; try { $workerPid = [int]$Worker.pid } catch {}
  $ticks = [long]0; try { $ticks = [long]$Worker.pidTicks } catch {}
  if ($workerPid -gt 0) {
    $p = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
    if ($p) {
      try {
        if ($ticks -le 0 -or $p.StartTime.Ticks -eq $ticks) { $alive = -not $p.HasExited }
      } catch { $alive = $true }
    }
  }
  if ($alive) { return [pscustomobject]@{ status='running'; reply=''; commits=@(); error='' } }

  $reply = Get-WorkerReplyText $Worker
  $status = 'failed'
  $chunkN = 0; $chunkM = 0

  # First try chunk-progress marker (specific shape: CONTINUE-CHUNK:N/M)
  $cm = [regex]::Match($reply, '(?im)^\s*STATUS:\s*CONTINUE-CHUNK\s*:\s*(\d+)\s*/\s*(\d+)\s*$')
  if ($cm.Success) {
    $chunkN = [int]$cm.Groups[1].Value
    $chunkM = [int]$cm.Groups[2].Value
    return [pscustomobject]@{
      status  = 'chunk-progress'
      reply   = $reply
      commits = @(Get-WorkerCommits $Worker)
      chunkN  = $chunkN
      chunkM  = $chunkM
      error   = ''
    }
  }

  # Generic STATUS matcher (any status word)
  $m = [regex]::Match($reply, '^\s*STATUS:\s*(?<s>[A-Z][A-Z0-9_-]*)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($m.Success) {
    $s = $m.Groups['s'].Value.ToUpperInvariant()
    if ($s -eq 'DONE') { $status = 'done' }
    elseif ($s -eq 'PARTIAL') { $status = 'paused-for-restart' }
    elseif ($s -eq 'CONTINUE') { $status = 'done' }
    elseif ($s -eq 'CONTINUE-CHUNK') {
      # Malformed CONTINUE-CHUNK (didn't match strict N/M shape above) — treat as failed
      # so worker is forced to re-emit cleanly.
      $status = 'failed'
    }
    else { $status = 'failed' }
  }
  return [pscustomobject]@{
    status  = $status
    reply   = $reply
    commits = @(Get-WorkerCommits $Worker)
    chunkN  = 0
    chunkM  = 0
    error   = ''
  }
}

function Save-ParallelStreams {
  # FIX 2026-05-27 (hardening): ignore $State parameter, always read fresh under lock via
  # Update-State. The 2026-05-27 state-wipe came from this function trusting a caller-passed
  # $State that turned out to be a fragment object (only parallel_streams field). Add-Member
  # added the field again, Write-State serialized the fragment as full state -- wipe. Now
  # the function ONLY does Add-Member on the live state under lock, so it can NEVER replace
  # other fields. $State param kept for back-compat but ignored.
  param($State, [object[]]$Streams)
  $flat = New-Object System.Collections.Generic.List[object]
  foreach ($w in @($Streams)) {
    [void]$flat.Add([pscustomobject]@{
      id        = [string]$w.id
      coder     = [string]$w.coder
      model     = [string]$w.model
      status    = if ($w.status) { [string]$w.status } else { 'running' }
      branch    = [string]$w.branch
      worktree  = [string]$w.worktree
      pid       = [int]$w.pid
      pidTicks  = [long]$w.pidTicks
      inFile    = [string]$w.inFile
      msgFile   = [string]$w.msgFile
      outFile   = [string]$w.outFile
      errFile   = [string]$w.errFile
      body      = [string]$w.body
      files     = @($w.files)
      startedAt = [string]$w.startedAt
    })
  }
  $flatArr = @($flat.ToArray())
  try {
    Update-State ({ param($s) $s | Add-Member -NotePropertyName parallel_streams -NotePropertyValue $flatArr -Force }.GetNewClosure()) | Out-Null
  } catch {
    # Update-State throws "state.json missing" if Read-State returns null (broken state).
    # Driver loop will auto-recover (Initialize-Bridge); we just bail without writing.
    try { Add-Message -From system -Text ("⚠ Save-ParallelStreams skipped: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
  }
}

function Load-ParallelStreams {
  param($State)
  if (-not $State) { $State = Read-State }
  if (-not $State -or -not ($State.PSObject.Properties.Name -contains 'parallel_streams') -or $null -eq $State.parallel_streams) { return @() }
  return @($State.parallel_streams)
}

function Get-TrivialWorkerDiffInfo {
  param([object]$Worker)
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $files = New-Object 'System.Collections.Generic.List[string]'
  $changedLines = 0
  $worktree = if ($Worker) { [string]$Worker.worktree } else { '' }
  if (-not $Worker -or [string]::IsNullOrWhiteSpace($worktree) -or -not (Test-Path -LiteralPath $worktree)) {
    $ErrorActionPreference = $oldEap
    return [pscustomobject]@{ FileCount=0; ChangedLines=0; IsTrivial=$false; Summary='missing worktree' }
  }
  try {
    $cmdWorktree = '"' + ($worktree -replace '"','') + '"'
    $numstat = @(& cmd.exe /d /c ('git -C ' + $cmdWorktree + ' diff --numstat HEAD -- 2>NUL'))
    foreach ($line in $numstat) {
      $parts = ([string]$line) -split "`t"
      if ($parts.Count -lt 3) { continue }
      [void]$files.Add([string]$parts[2])
      $add = 0; $del = 0
      if ([int]::TryParse([string]$parts[0], [ref]$add)) { $changedLines += $add }
      if ([int]::TryParse([string]$parts[1], [ref]$del)) { $changedLines += $del }
    }
    $untracked = @(& cmd.exe /d /c ('git -C ' + $cmdWorktree + ' ls-files --others --exclude-standard 2>NUL'))
    foreach ($f in $untracked) { if (-not [string]::IsNullOrWhiteSpace([string]$f)) { [void]$files.Add([string]$f); $changedLines = 5 } }
  } catch {}
  $ErrorActionPreference = $oldEap
  $unique = @($files | Sort-Object -Unique)
  $declared = @($Worker.files)
  $effectiveFileCount = if ($unique.Count -gt 0) { $unique.Count } else { $declared.Count }
  $isTrivial = ($declared.Count -eq 1) -and ($effectiveFileCount -eq 1) -and ($changedLines -lt 5)
  return [pscustomobject]@{
    FileCount    = [int]$unique.Count
    EffectiveFileCount = [int]$effectiveFileCount
    ChangedLines = [int]$changedLines
    IsTrivial    = [bool]$isTrivial
    Summary      = ("declared=" + $declared.Count + ", diffFiles=" + $unique.Count + ", effectiveFiles=" + $effectiveFileCount + ", diffLines=" + $changedLines)
  }
}

function Invoke-TrivialFallbackWorker {
  # Called when a Claude worker failed on a trivial single-file stream.
  # Finds the cheapest available codex worker, respawns it in the same worktree/branch,
  # waits synchronously (up to 10 min), returns Get-WorkerResult or $null on failure.
  param(
    [object]$Worker,
    [string]$TaskHash
  )

  $diffInfo = Get-TrivialWorkerDiffInfo -Worker $Worker
  if (-not $diffInfo.IsTrivial) {
    try { Add-Message -From system -Text ("⚠ trivial-fallback skipped for stream " + $Worker.id + ": not trivial (" + $diffInfo.Summary + ")") -Kind event | Out-Null } catch {}
    return $null
  }

  $pool = @(Get-ParallelWorkerPool | Where-Object { ([string]$_.cli).ToLowerInvariant() -eq 'codex' })
  if ($pool.Count -eq 0) {
    try { Add-Message -From system -Text ("⚠ trivial-fallback: no codex workers in pool for stream " + $Worker.id) -Kind event | Out-Null } catch {}
    return $null
  }
  $fbSpec = @($pool | Sort-Object @{Expression={ try { [int]$_.cost } catch { 999 } };Descending=$false} | Select-Object -First 1)[0]

  try {
    Add-Message -From system -Text ("🔄 Trivial-fallback: re-routing stream " + $Worker.id + " (claude/" + $Worker.model + " failed, " + $diffInfo.Summary + ") → " + $fbSpec.id + " (" + $fbSpec.cli + "/" + $fbSpec.model + ")") -Kind event | Out-Null
  } catch {}

  $fbWorker = $null
  try {
    $fbWorker = Spawn-Worker -StreamId ($Worker.id + '_fb') -Body ([string]$Worker.body) -Worktree ([string]$Worker.worktree) -BranchName ([string]$Worker.branch) -WorkerSpec $fbSpec
  } catch {
    try { Add-Message -From system -Text ("⚠ trivial-fallback spawn failed for stream " + $Worker.id + ": " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    return $null
  }

  $deadline = (Get-Date).AddMinutes(10)
  $fbRes = $null
  while ($true) {
    if ((Get-Date) -ge $deadline) {
      try {
        if ($fbWorker.process -and -not $fbWorker.process.HasExited) {
          Start-Process taskkill -ArgumentList '/PID',([string]$fbWorker.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue
        }
      } catch {}
      try { Add-Message -From system -Text ("⏱ Trivial-fallback timeout (10 min) for stream " + $Worker.id) -Kind event | Out-Null } catch {}
      break
    }
    Start-Sleep -Seconds 10
    $fbRes = Get-WorkerResult $fbWorker
    if ($fbRes.status -ne 'running') { break }
  }

  if ($fbRes -and $fbRes.status -eq 'done' -and $fbRes.commits.Count -gt 0) {
    try { Add-Message -From system -Text ("✅ Trivial-fallback succeeded for stream " + $Worker.id + ": " + $fbRes.commits.Count + " commits by " + $fbSpec.id) -Kind event | Out-Null } catch {}
  } elseif ($fbRes) {
    try { Add-Message -From system -Text ("❌ Trivial-fallback also failed for stream " + $Worker.id + ": status=" + $fbRes.status) -Kind event | Out-Null } catch {}
  }
  return $fbRes
}

function Get-ParallelDispatchTaskHash {
  # Stable task hash from current_task text so worktree paths are reproducible across restarts.
  $taskHash = 'task'
  try {
    $st = Read-State
    $taskText = if ($st -and $st.current_task) { [string]$st.current_task } else { 'task' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($taskText)
    $hash = $sha.ComputeHash($bytes)
    $taskHash = (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0,12)
  } catch {}
  return $taskHash
}

function Stop-ParallelDispatchWorkers {
  param(
    [object[]]$Workers,
    [string]$TaskHash
  )
  foreach ($w0 in @($Workers)) {
    try {
      if ($w0.process -and -not $w0.process.HasExited) {
        Start-Process taskkill -ArgumentList '/PID',([string]$w0.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue
      }
    } catch {}
    try { Cleanup-WorkerWorktree -StreamId $w0.id -TaskHash $TaskHash } catch {}
  }
}

function Write-ParallelDispatchTeamPlan {
  param([object[]]$Streams)
  try {
    $planLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$planLines.Add("🔀 Запускаю команду из " + @($Streams).Count + " параллельных потоков:")
    foreach ($s0 in @($Streams)) {
      $body0 = ''
      try { $body0 = ([string]$s0.body -replace '\s+', ' ').Trim() } catch {}
      if ([string]::IsNullOrWhiteSpace($body0)) { try { $body0 = ([string]$s0.task -replace '\s+',' ').Trim() } catch {} }
      if ($body0.Length -gt 100) { $body0 = $body0.Substring(0, 100) + '…' }
      $files0 = ''
      try { $files0 = (@($s0.files) -join ', ') } catch {}
      $filePart = ''
      if (-not [string]::IsNullOrWhiteSpace($files0)) { $filePart = " [" + $files0 + "]" }
      [void]$planLines.Add("  • поток " + [string]$s0.id + $filePart + ": " + $body0)
    }
    Add-Message -From system -Text ($planLines -join "`n") -Kind event | Out-Null
  } catch {}
}

function Resolve-ParallelDispatchWorkerSpec {
  param(
    [object]$Stream,
    [string[]]$AlreadyUsedIds
  )

  $spec = $null
  try { $spec = Select-WorkerForStream -Stream $Stream -AlreadyUsedIds @($AlreadyUsedIds) } catch {
    try { Add-Message -From system -Text ("⚠ parallel: router error for stream " + $Stream.id + ": " + $_.Exception.Message + " -- using fallback") -Kind event | Out-Null } catch {}
  }

  if (-not $spec) {
    $pool = @(Get-ParallelWorkerPool)
    if ($pool.Count -gt 0) { $spec = $pool[0] }
  }

  return $spec
}

function Write-ParallelDispatchSpawnMessage {
  param(
    [object]$Stream,
    [object]$WorkerSpec
  )

  try {
    $complexity = Get-StreamComplexity $Stream
    $domain = Get-StreamDomain $Stream
    Add-Message -From system -Text ("🔀 Spawned worker: stream=" + $Stream.id + " worker=" + $WorkerSpec.id + " (" + $WorkerSpec.cli + "/" + $WorkerSpec.model + ($(if($WorkerSpec.reasoning){'/' + $WorkerSpec.reasoning}else{''})) + ") complexity=" + $complexity + " domain=" + $domain + " files=[" + (($Stream.files) -join ',') + "]") -Kind event
  } catch {}
}

function Start-ParallelDispatchWorker {
  param(
    [object]$Stream,
    [string]$TaskHash,
    [string[]]$AlreadyUsedIds
  )

  $spec = Resolve-ParallelDispatchWorkerSpec -Stream $Stream -AlreadyUsedIds $AlreadyUsedIds
  if (-not $spec) {
    try { Add-Message -From system -Text ("❌ parallel: no worker pool available for stream " + $Stream.id) -Kind event } catch {}
    return @{ ok=$false; worker=$null; workerSpec=$null; reason='no worker pool' }
  }

  $branch = "wip/parallel/$TaskHash/$($Stream.id)"
  try {
    $worktree = Get-WorkerWorktree -StreamId $Stream.id -TaskHash $TaskHash
    $worker = Spawn-Worker -StreamId $Stream.id -Body $Stream.body -Worktree $worktree -BranchName $branch -WorkerSpec $spec
    Write-ParallelDispatchSpawnMessage -Stream $Stream -WorkerSpec $spec
    return @{ ok=$true; worker=$worker; workerSpec=$spec; reason='' }
  } catch {
    try { Add-Message -From system -Text ("❌ Parallel spawn failed for stream " + $Stream.id + ": " + $_.Exception.Message) -Kind event } catch {}
    return @{ ok=$false; worker=$null; workerSpec=$spec; reason=("spawn failed: " + $_.Exception.Message) }
  }
}

function Start-ParallelDispatchWorkers {
  param(
    [object[]]$Streams,
    [string]$TaskHash
  )

  $workers = New-Object 'System.Collections.Generic.List[object]'
  $usedIds = New-Object 'System.Collections.Generic.List[string]'

  Write-ParallelDispatchTeamPlan -Streams @($Streams)

  foreach ($s in @($Streams)) {
    $started = Start-ParallelDispatchWorker -Stream $s -TaskHash $TaskHash -AlreadyUsedIds @($usedIds.ToArray())
    if (-not $started.ok) {
      Stop-ParallelDispatchWorkers -Workers @($workers.ToArray()) -TaskHash $TaskHash
      return @{ ok=$false; workers=@($workers.ToArray()); reason=$started.reason }
    }

    [void]$workers.Add($started.worker)
    [void]$usedIds.Add([string]$started.workerSpec.id)
  }

  try { Save-ParallelStreams -State (Read-State) -Streams $workers } catch {}
  return @{ ok=$true; workers=@($workers.ToArray()); reason='' }
}

function Stop-ParallelDispatchTimedOutWorkers {
  param(
    [object[]]$Workers,
    [hashtable]$Completed,
    [int]$TimeoutMin
  )

  foreach ($w in @($Workers)) {
    if ($Completed.ContainsKey($w.id)) { continue }
    try {
      if ($w.process -and -not $w.process.HasExited) {
        Start-Process taskkill -ArgumentList '/PID',([string]$w.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue
      }
    } catch {}
  }
  try { Add-Message -From system -Text ("⏱ Parallel timeout (" + $TimeoutMin + " min) -- killing in-flight workers") -Kind event } catch {}
}

function Update-ParallelDispatchHeartbeat {
  # H1 FIX (2026-05-31 load audit): refresh the channel heartbeat each poll. A parallel run can
  # last up to $TimeoutMin (25m); without this the heartbeat goes stale past the watchdog's 300s
  # window -> watchdog sees "driver dead" -> git reset --hard stable WHILE workers are mid-merge,
  # destroying in-flight work (the exact false-rollback class, re-introduced by parallel mode).
  # Sibling poll loops (Invoke-ParallelWorkers/CodexParallel) already tick via $OnTick; this one
  # didn't. Inline refresh keeps the watchdog calm; the parallel $deadline still bounds a true hang.
  try { Update-State { param($s) $s.heartbeat = (Get-Date).ToString('o') } | Out-Null } catch {}
}

function Get-ParallelDispatchBranchHead {
  param([object]$Worker)

  try {
    return ((& git -C (Get-ParallelRepoRoot) rev-parse $Worker.branch 2>$null) | Select-Object -First 1).Trim()
  } catch {}
  return ''
}

function Complete-ParallelDispatchWorkerResult {
  param(
    [hashtable]$Completed,
    [object]$Worker,
    [object]$Result,
    [switch]$SkipMessage
  )

  $Completed[$Worker.id] = $Result
  if ($SkipMessage) { return }
  $chunkSummary = if ([int]$Worker.chunksDone -gt 0) { (" via " + [int]$Worker.chunksDone + " chunks") } else { '' }
  try { Add-Message -From system -Text ("🔀 Worker " + $Worker.id + " (" + $Worker.coder + ") finished: status=" + $Result.status + ", commits=" + $Result.commits.Count + $chunkSummary) -Kind event } catch {}
}

function Resolve-ParallelDispatchChunkProgress {
  param(
    [hashtable]$Completed,
    [object]$Worker,
    [object]$Result
  )

  $chunkN = [int]$Result.chunkN
  $chunkM = [int]$Result.chunkM
  $branchHead = Get-ParallelDispatchBranchHead -Worker $Worker
  $advanced = (-not [string]::IsNullOrWhiteSpace($branchHead)) -and ($branchHead -ne [string]$Worker.chunkLastSha)
  if (-not $advanced) {
    Complete-ParallelDispatchWorkerResult -Completed $Completed -Worker $Worker -SkipMessage -Result ([pscustomobject]@{
      status = 'failed'
      reply  = $Result.reply
      commits = $Result.commits
      chunkN = $chunkN
      chunkM = $chunkM
      error  = 'chunk emitted but branch did not advance'
    })
    try { Add-Message -From system -Text ("❌ Worker " + $Worker.id + " emitted CONTINUE-CHUNK:" + $chunkN + "/" + $chunkM + " but branch " + $Worker.branch + " did not advance (no commit). Killing.") -Kind event } catch {}
    return
  }

  if ($chunkN -ge 10) {
    Complete-ParallelDispatchWorkerResult -Completed $Completed -Worker $Worker -SkipMessage -Result ([pscustomobject]@{
      status = 'done'
      reply  = $Result.reply
      commits = $Result.commits
      chunkN = $chunkN
      chunkM = $chunkM
      error  = 'chunk limit reached (10)'
    })
    try { Add-Message -From system -Text ("⚠ Worker " + $Worker.id + " reached chunk limit (10/" + $chunkM + ") -- closing as done.") -Kind event } catch {}
    return
  }

  $shortLast = if ($branchHead.Length -gt 7) { $branchHead.Substring(0,7) } else { $branchHead }
  try {
    $null = Respawn-WorkerForChunk -Worker $Worker -NextChunk ($chunkN + 1) -TotalChunks $chunkM -LastCommitSha $branchHead
    try { Add-Message -From system -Text ("🔂 Worker " + $Worker.id + " chunk " + $chunkN + "/" + $chunkM + " committed " + $shortLast + " -- respawned on chunk " + ($chunkN + 1) + "/" + $chunkM) -Kind event } catch {}
  } catch {
    Complete-ParallelDispatchWorkerResult -Completed $Completed -Worker $Worker -SkipMessage -Result ([pscustomobject]@{
      status = 'failed'
      reply  = $Result.reply
      commits = $Result.commits
      chunkN = $chunkN
      chunkM = $chunkM
      error  = ("respawn failed: " + $_.Exception.Message)
    })
    try { Add-Message -From system -Text ("❌ Worker " + $Worker.id + " respawn failed at chunk " + ($chunkN + 1) + "/" + $chunkM + ": " + $_.Exception.Message) -Kind event } catch {}
  }
}

function Wait-ParallelDispatchPollWorker {
  param(
    [hashtable]$Completed,
    [object]$Worker
  )

  if ($Completed.ContainsKey($Worker.id)) { return }
  $res = Get-WorkerResult $Worker
  if ($res.status -eq 'running') { return }
  if ($res.status -eq 'chunk-progress') {
    Resolve-ParallelDispatchChunkProgress -Completed $Completed -Worker $Worker -Result $res
    return
  }

  Complete-ParallelDispatchWorkerResult -Completed $Completed -Worker $Worker -Result $res
}

function Wait-ParallelDispatchResults {
  param(
    [object[]]$Workers,
    [string]$TaskHash,
    [int]$TimeoutMin = 25,
    [int]$PollSec = 10
  )

  $workers = @($Workers)
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  $completed = @{}
  while ($completed.Count -lt $workers.Count) {
    if ((Get-Date) -ge $deadline) {
      Stop-ParallelDispatchTimedOutWorkers -Workers $workers -Completed $completed -TimeoutMin $TimeoutMin
      break
    }
    # Operator veto (2026-06-10): this poll used to be blind for the whole TimeoutMin window —
    # an abort/stop set mid-dispatch was invisible until the deadline. Honor it per tick.
    $pollAbort = $false
    try { $pollAbort = [bool](Read-State).abort } catch {}
    if ($pollAbort) {
      try { Add-Message -From system -Text "🛑 Parallel dispatch: получен abort — останавливаю незавершённые потоки и выхожу из ожидания." -Kind event | Out-Null } catch {}
      Stop-ParallelDispatchTimedOutWorkers -Workers $workers -Completed $completed -TimeoutMin $TimeoutMin
      break
    }
    Start-Sleep -Seconds $PollSec
    Update-ParallelDispatchHeartbeat
    foreach ($w in $workers) {
      Wait-ParallelDispatchPollWorker -Completed $completed -Worker $w
    }
  }

  return $completed
}

function ConvertTo-ParallelDispatchCompletedMap {
  param([object]$Completed)

  $map = @{}
  if ($null -eq $Completed) { return $map }

  if ($Completed -is [hashtable]) {
    foreach ($key in $Completed.Keys) { $map[[string]$key] = $Completed[$key] }
    return $map
  }

  if ($Completed -is [System.Collections.IDictionary]) {
    foreach ($key in $Completed.Keys) { $map[[string]$key] = $Completed[$key] }
    return $map
  }

  if ($Completed -is [array]) {
    foreach ($item in @($Completed)) {
      $itemMap = ConvertTo-ParallelDispatchCompletedMap -Completed $item
      foreach ($key in $itemMap.Keys) { $map[[string]$key] = $itemMap[$key] }
    }
    return $map
  }

  if ($Completed -is [pscustomobject]) {
    foreach ($prop in $Completed.PSObject.Properties) {
      $map[[string]$prop.Name] = $prop.Value
    }
  }

  return $map
}

function New-ParallelDispatchAggregationContext {
  param(
    [object[]]$Workers,
    [object]$Completed,
    [string]$TaskHash
  )

  $completedMap = ConvertTo-ParallelDispatchCompletedMap -Completed $Completed

  return @{
    workers = @($Workers)
    completed = $completedMap
    taskHash = $TaskHash
    merged = 0
    bridgeRoot = Get-ParallelRepoRoot
    collected = 0
    collectedStreams = 0
    quarantined = (New-Object 'System.Collections.Generic.List[string]')
    mergedStreams = (New-Object 'System.Collections.Generic.List[string]')
    baseCommit = Get-ParallelTaskBaseCommit
    gitExe = Get-GitExe
    deliveredPaths = (New-Object 'System.Collections.Generic.List[string]')
    allowedTerminalStatuses = @('done', 'paused-for-restart')
  }
}

function Add-ParallelDispatchQuarantine {
  param(
    [hashtable]$Context,
    [string]$StreamId
  )

  if ([string]::IsNullOrWhiteSpace($StreamId)) { return }
  if (-not $Context.quarantined.Contains($StreamId)) {
    [void]$Context.quarantined.Add($StreamId)
  }
}

function Add-ParallelDispatchIncompleteWorkersToQuarantine {
  param([hashtable]$Context)

  foreach ($w in $Context.workers) {
    if ($Context.completed.ContainsKey($w.id)) { continue }
    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$w.id)
    try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": worker не завершился до timeout/kill, stream не доставлен") -Kind event | Out-Null } catch {}
  }
}

function Collect-ParallelDispatchWorkerOutput {
  param(
    [hashtable]$Context,
    [object]$Worker
  )

  if (-not $Context.completed.ContainsKey($Worker.id)) { return }

  $workerStatus = ''
  try { $workerStatus = [string]$Context.completed[$Worker.id].status } catch {}

  if ($workerStatus -eq 'failed' -or $Context.allowedTerminalStatuses -notcontains $workerStatus) {
    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
    return
  }

  $declaredFiles = @()
  try { $declaredFiles = @($Worker.files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch {}
  if ($declaredFiles.Count -eq 0) {
    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
    try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": нет объявленных файлов (w.files пуст) — сбор невозможен") -Kind event | Out-Null } catch {}
    return
  }

  try {
    $wtPath = Get-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash
    if (-not (Test-Path -LiteralPath $wtPath)) {
      Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
      return
    }

    $changed = New-Object System.Collections.Generic.HashSet[string]
    if (-not [string]::IsNullOrWhiteSpace($Context.baseCommit)) {
      try { @(& $Context.gitExe -C $wtPath diff --name-only $Context.baseCommit 2>$null) | Where-Object { $_ } | ForEach-Object { $rel = ($_.Trim() -replace '"',''); if ($rel -notmatch '(^|[\\/])\.git([\\/]|-alt)') { [void]$changed.Add($rel) } } } catch {}
    }
    try { @(& $Context.gitExe -C $wtPath status --porcelain 2>$null) | Where-Object { $_ } | ForEach-Object { $p = ($_.Substring([Math]::Min(3,$_.Length))).Trim().Trim('"'); if ($p -and $p -notmatch '->' -and $p -notmatch '(^|[\\/])\.git([\\/]|-alt)') { [void]$changed.Add($p) } } } catch {}

    $streamCommits = 0
    try { $streamCommits = @($Context.completed[$Worker.id].commits).Count } catch {}
    if ($changed.Count -eq 0 -and $streamCommits -eq 0) {
      # Covered-credit (2026-06-10): a no-change stream whose DECLARED files already changed
      # in the MAIN repo since the batch base means the work was merged by an earlier pass or
      # session — the stream is DONE, not broken. Quarantining it sent genuinely-finished
      # backlog ids to held at giveup (the batch-wedge incident). Credit it as merged.
      $coveredHit = $false
      if (-not [string]::IsNullOrWhiteSpace($Context.baseCommit)) {
        try {
          $mainChanged = @(& $Context.gitExe -C $Context.bridgeRoot diff --name-only $Context.baseCommit 2>$null | Where-Object { $_ } | ForEach-Object { (([string]$_).Trim() -replace '"','' -replace '\\','/').TrimStart('/') })
          foreach ($df in $declaredFiles) {
            $dfn = (([string]$df).Trim() -replace '\\','/').TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($dfn)) { continue }
            if (@($mainChanged) -icontains $dfn) { $coveredHit = $true; break }
          }
        } catch {}
      }
      if ($coveredHit) {
        $Context.merged++
        [void]$Context.mergedStreams.Add([string]$Worker.id)
        try { $Context.completed[$Worker.id] | Add-Member -NotePropertyName _covered -NotePropertyValue $true -Force } catch {}
        try { Add-Message -From system -Text ("✅ Поток " + $Worker.id + ": нового diff нет, но объявленные файлы уже изменены в репо с базы батча — работа покрыта ранее, кредитую как merged (covered).") -Kind event | Out-Null } catch {}
        return
      }
      Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
      try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": нет изменённых файлов и нет коммитов (no-change stream)") -Kind event | Out-Null } catch {}
      return
    }

    if (@($Context.workers).Count -eq 1) {
      $seqCheck = Invoke-SequentialTouchSetCheck `
        -RepoRoot $wtPath `
        -DeclaredFiles $declaredFiles `
        -BaseCommit ([string]$Context.baseCommit) `
        -IsOperatorAuthorized (Test-SequentialTouchSetOperatorAuthorized -Worker $Worker) `
        -GitExe ([string]$Context.gitExe) `
        -ChangedFiles @($changed)
      if (-not [bool]$seqCheck.ok) {
        $violatingFile = ''
        try { $violatingFile = [string]$seqCheck.violatingFile } catch {}
        if (-not [string]::IsNullOrWhiteSpace($violatingFile)) {
          [void](Invoke-ParallelOutsideFilesCheckout -RepoRoot $wtPath -OutsideFiles @($violatingFile) -DeclaredFiles $declaredFiles -GitExe $Context.gitExe)
        }
        Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
        try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": " + [string]$seqCheck.reason + $(if ($violatingFile) { " (" + $violatingFile + ")" } else { "" })) -Kind event | Out-Null } catch {}
        return
      }
    }

    $allowedPaths = New-Object 'System.Collections.Generic.List[string]'
    $deniedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rel in $changed) {
      if ([string]::IsNullOrWhiteSpace($rel)) { continue }
      if (Test-ParallelCollectedPathAllowed -RelativePath $rel -DeclaredFiles $declaredFiles) {
        [void]$allowedPaths.Add($rel)
      } else {
        [void]$deniedPaths.Add($rel)
      }
    }

    if ($deniedPaths.Count -gt 0) {
      $checkoutResult = Invoke-ParallelOutsideFilesCheckout -RepoRoot $wtPath -OutsideFiles @($deniedPaths) -DeclaredFiles $declaredFiles -GitExe $Context.gitExe
      if (-not [bool]$checkoutResult.ok) {
        $tail = ''
        try { $tail = (@($checkoutResult.output) | Select-Object -Last 3) -join ' | ' } catch {}
        $tailText = ''
        if (-not [string]::IsNullOrWhiteSpace($tail)) { $tailText = " (" + $tail + ")" }
        try { Add-Message -From system -Text ("⚠️ Outside touch-set cleanup failed before quarantine for stream " + $Worker.id + ": " + $checkoutResult.message + $tailText) -Kind event | Out-Null } catch {}
      }
      Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
      try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": stream quarantined because outside touch-set path(s) were changed: " + ($deniedPaths -join ', ')) -Kind event | Out-Null } catch {}
      return
    }

    if ($allowedPaths.Count -eq 0) {
      Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
      try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": нет разрешённых путей (все вне touch-set или пустые)") -Kind event | Out-Null } catch {}
      return
    }

    $copiedHere = 0
    $actuallyDelivered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rel in $allowedPaths) {
      $src = Join-Path $wtPath $rel
      if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }

      $dst = Join-Path $Context.bridgeRoot $rel
      $dstDir = Split-Path $dst -Parent
      if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
      Copy-Item -LiteralPath $src -Destination $dst -Force
      $copiedHere++

      $gitDiffOut = @(& $Context.gitExe -C $Context.bridgeRoot status --porcelain -- $rel 2>$null | Where-Object { $_ })
      if ($gitDiffOut.Count -gt 0) {
        [void]$actuallyDelivered.Add($rel)
        [void]$Context.deliveredPaths.Add($rel)
      }
    }

    if ($actuallyDelivered.Count -gt 0) {
      $Context.collected += $actuallyDelivered.Count
      $Context.collectedStreams++
      try { $Context.completed[$Worker.id] | Add-Member -NotePropertyName _collected -NotePropertyValue $true -Force } catch {}
      try { $Context.completed[$Worker.id] | Add-Member -NotePropertyName _deliveredPaths -NotePropertyValue @($actuallyDelivered) -Force } catch {}
      return
    }

    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
    try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": скопировано " + $copiedHere + " файл(ов), но git diff пуст — изменений нет") -Kind event | Out-Null } catch {}
  } catch {
    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
    try { Add-Message -From system -Text ("⚠️ Карантин поток " + $Worker.id + ": исключение при сборе: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
  }
}

function Invoke-ParallelDispatchCollectPhase {
  param([hashtable]$Context)

  Add-ParallelDispatchIncompleteWorkersToQuarantine -Context $Context
  foreach ($w in $Context.workers) {
    Collect-ParallelDispatchWorkerOutput -Context $Context -Worker $w
  }
}

function Quarantine-ParallelDispatchCollectedWorkers {
  param([hashtable]$Context)

  foreach ($cw in $Context.workers) {
    if (-not $Context.completed.ContainsKey($cw.id)) { continue }
    $cres = $Context.completed[$cw.id]
    if (($cres.PSObject.Properties.Name -contains '_collected') -and $cres._collected) {
      Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$cw.id)
    }
  }
}

function Get-ParallelDispatchGitDir {
  param(
    [string]$RepoRoot,
    [string]$GitExe = ''
  )

  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) { return '' }

  $dotGit = Join-Path $RepoRoot '.git'
  if (Test-Path -LiteralPath $dotGit -PathType Container) { return $dotGit }
  if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
    try {
      $text = [System.IO.File]::ReadAllText($dotGit)
      if ($text -match '(?im)^\s*gitdir:\s*(.+?)\s*$') {
        $gitDir = [string]$Matches[1]
        if ([System.IO.Path]::IsPathRooted($gitDir)) { return $gitDir }
        return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $gitDir))
      }
    } catch {}
  }

  if ([string]::IsNullOrWhiteSpace($GitExe)) {
    try { $GitExe = Get-GitExe } catch { $GitExe = 'git' }
  }
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& $GitExe -C $RepoRoot rev-parse --git-dir 2>$null)
    if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) {
      $gitDir = ([string]($out | Select-Object -First 1)).Trim()
      if ([string]::IsNullOrWhiteSpace($gitDir)) { return '' }
      if ([System.IO.Path]::IsPathRooted($gitDir)) { return $gitDir }
      return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $gitDir))
    }
  } catch {
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return ''
}

function Remove-StaleIndexLock {
  param(
    [string]$RepoRoot,
    [string]$GitExe = ''
  )

  $gitDir = Get-ParallelDispatchGitDir -RepoRoot $RepoRoot -GitExe $GitExe
  if ([string]::IsNullOrWhiteSpace($gitDir)) { return $false }
  $lockPath = Join-Path $gitDir 'index.lock'
  if (-not (Test-Path -LiteralPath $lockPath)) { return $false }
  $gitProcs = @(Get-Process -Name 'git' -ErrorAction SilentlyContinue | Where-Object { $_ })
  if ($gitProcs.Count -gt 0) { return $false }
  $lockItem = $null
  try { $lockItem = Get-Item -LiteralPath $lockPath -ErrorAction Stop } catch { return $false }
  $lockAge = ((Get-Date) - $lockItem.LastWriteTime).TotalSeconds
  if ($lockAge -lt 30) { return $false }
  try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop; return $true } catch { return $false }
}

function Invoke-SequentialTouchSetCheck {
  param(
    [string]$RepoRoot,
    [string[]]$DeclaredFiles = @(),
    [string]$BaseCommit = '',
    [bool]$IsOperatorAuthorized = $false,
    [string]$GitExe = '',
    [string[]]$ChangedFiles = @()
  )

  if ($IsOperatorAuthorized) { return @{ ok = $true; reason = 'operator-authorized' } }

  if (-not (Get-Command Test-PolicyControlPlanePath -ErrorAction SilentlyContinue)) {
    try {
      $policyPath = Join-Path $PSScriptRoot 'policy.ps1'
      if (Test-Path -LiteralPath $policyPath) { . $policyPath }
    } catch {}
  }

  if (-not (Get-Command Test-PolicyControlPlanePath -ErrorAction SilentlyContinue)) {
    return @{ ok = $false; reason = 'policy-helper-missing'; violatingFile = '' }
  }

  $changed = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($p in @($ChangedFiles)) {
    $rel = _NormalizeRelPath ([string]$p)
    if ($null -ne $rel -and -not $changed.Contains($rel)) { [void]$changed.Add($rel) }
  }

  if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and (Test-Path -LiteralPath $RepoRoot)) {
    if ([string]::IsNullOrWhiteSpace($GitExe)) {
      try { $GitExe = Get-GitExe } catch { $GitExe = 'git' }
    }
    $gitListFailed = $false
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
        try {
          $diffLines = @(& $GitExe -C $RepoRoot diff --name-only $BaseCommit -- 2>$null)
          if ($LASTEXITCODE -ne 0) { $gitListFailed = $true }
          foreach ($line in $diffLines) {
            $rel = _NormalizeRelPath ([string]$line)
            if ($null -ne $rel -and -not $changed.Contains($rel)) { [void]$changed.Add($rel) }
          }
        } catch { $gitListFailed = $true }
      }
      try {
        $statusLines = @(& $GitExe -C $RepoRoot status --porcelain -uall 2>$null)
        if ($LASTEXITCODE -ne 0) { $gitListFailed = $true }
        foreach ($line in $statusLines) {
          $txt = [string]$line
          if ([string]::IsNullOrWhiteSpace($txt)) { continue }
          $pathText = if ($txt.Length -gt 3) { $txt.Substring(3).Trim() } else { $txt.Trim() }
          if ($pathText -match '\s+->\s+') { $pathText = (($pathText -split '\s+->\s+') | Select-Object -Last 1) }
          $rel = _NormalizeRelPath ($pathText.Trim('"'))
          if ($null -ne $rel -and -not $changed.Contains($rel)) { [void]$changed.Add($rel) }
        }
      } catch { $gitListFailed = $true }
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($gitListFailed) {
      return @{ ok = $false; violatingFile = ''; reason = 'changed-files-unavailable'; changedFiles = @($changed) }
    }
  }

  foreach ($file in @($changed)) {
    if (Test-ParallelCollectedPathAllowed -RelativePath $file -DeclaredFiles $DeclaredFiles) { continue }
    if (Test-PolicyControlPlanePath -Path $file) {
      return @{ ok = $false; violatingFile = $file; reason = 'undeclared-control-plane-edit'; changedFiles = @($changed) }
    }
  }

  return @{ ok = $true; changedFiles = @($changed) }
}

function Test-SequentialTouchSetOperatorAuthorized {
  param([object]$Worker)

  if (-not $Worker) { return $false }
  foreach ($name in @('operator_authorized','is_operator_authorized','operatorAuthorized')) {
    try {
      if ($Worker.PSObject -and ($Worker.PSObject.Properties.Name -contains $name) -and [bool]$Worker.$name) { return $true }
    } catch {}
  }
  try {
    if (Get-Command Get-PolicyItemAuthorization -ErrorAction SilentlyContinue) {
      return ([string](Get-PolicyItemAuthorization -Item $Worker) -eq 'operator')
    }
  } catch {}
  try {
    foreach ($tag in @($Worker.tags)) {
      if ([string]$tag -and ([string]$tag).Trim().ToLowerInvariant() -eq 'operator') { return $true }
    }
  } catch {}
  try {
    $from = ([string]$Worker.from).Trim().ToLowerInvariant()
    if ($from -eq 'operator') { return $true }
  } catch {}
  return $false
}

function Test-ParallelDispatchGitLockContention {
  param([object]$Output)

  $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
  return ($text -match '(?i)(index\.lock|Permission|unable to create|Access is denied)')
}

function Invoke-ParallelDispatchCommitHeartbeat {
  try {
    $cmd = Get-Command Update-ChannelHeartbeat -ErrorAction SilentlyContinue
    if ($cmd) {
      try {
        if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
          Update-ChannelHeartbeat -Slug (Get-EffectiveChannel) | Out-Null
          return
        }
      } catch {}
      try { Update-ChannelHeartbeat | Out-Null } catch {}
    }
  } catch {}
}

function Invoke-ParallelDispatchGitCommitWithRetry {
  param(
    [string]$RepoRoot,
    [scriptblock]$Operation,
    [int]$MaxRetries = 2,
    [int]$BackoffSeconds = 5
  )

  $attempt = 0
  $last = $null
  $preRemovedLock = $false
  try { $preRemovedLock = Remove-StaleIndexLock -RepoRoot $RepoRoot } catch {}
  if ($preRemovedLock) { Invoke-ParallelDispatchCommitHeartbeat }
  while ($attempt -le $MaxRetries) {
    $attempt++
    try {
      $raw = @(& $Operation)
      $last = @($raw | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') } | Select-Object -Last 1)[0]
      if ($null -eq $last) {
        $last = [pscustomobject]@{ ExitCode = 1; Output = @($raw); Attempts = $attempt; RemovedLock = $false }
      }
    } catch {
      $last = [pscustomobject]@{ ExitCode = 1; Output = @($_.Exception.Message); Attempts = $attempt; RemovedLock = $false }
    }

    $exitCode = 1
    try { $exitCode = [int]$last.ExitCode } catch {}
    if ($exitCode -eq 0) {
      try { $last | Add-Member -NotePropertyName Attempts -NotePropertyValue $attempt -Force } catch {}
      try { $last | Add-Member -NotePropertyName PreRemovedLock -NotePropertyValue $preRemovedLock -Force } catch {}
      return $last
    }

    if ($attempt -gt $MaxRetries -or -not (Test-ParallelDispatchGitLockContention -Output $last.Output)) {
      try { $last | Add-Member -NotePropertyName Attempts -NotePropertyValue $attempt -Force } catch {}
      try { $last | Add-Member -NotePropertyName PreRemovedLock -NotePropertyValue $preRemovedLock -Force } catch {}
      return $last
    }

    $removed = $false
    try { $removed = Remove-StaleIndexLock -RepoRoot $RepoRoot } catch {}
    try { $last | Add-Member -NotePropertyName RemovedLock -NotePropertyValue $removed -Force } catch {}
    Invoke-ParallelDispatchCommitHeartbeat
    Start-Sleep -Seconds $BackoffSeconds
  }

  return $last
}

function Commit-ParallelDispatchCollectedOutputs {
  param([hashtable]$Context)

  if ($Context.collectedStreams -le 0 -or $Context.deliveredPaths.Count -le 0) { return }

  try {
    $commitResult = Invoke-ParallelDispatchGitCommitWithRetry -RepoRoot $Context.bridgeRoot -Operation {
      $oldErrorActionPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $out = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $Context.deliveredPaths) {
          $addResult = Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('add','--',[string]$p)
          foreach ($line in @($addResult.Output)) { [void]$out.Add($line) }
          if ([int]$addResult.ExitCode -ne 0) {
            return [pscustomobject]@{ ExitCode = ([int]$addResult.ExitCode); Output = @($out.ToArray()) }
          }
        }
        $actualFiles = $Context.deliveredPaths.Count
        $commitResult = Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('commit','-m',("parallel collect: " + $Context.collectedStreams + " streams, " + $actualFiles + " actual changed files"))
        foreach ($line in @($commitResult.Output)) { [void]$out.Add($line) }
        return [pscustomobject]@{ ExitCode = ([int]$commitResult.ExitCode); Output = @($out.ToArray()) }
      } finally {
        $ErrorActionPreference = $oldErrorActionPreference
      }
    }

    $actualFiles = $Context.deliveredPaths.Count
    $commitExitCode = 1
    try {
      $commitResultObj = @($commitResult | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains 'ExitCode') } | Select-Object -Last 1)[0]
      $commitExitCode = [int]$commitResultObj.ExitCode
    } catch {}
    if ($commitExitCode -eq 0) {
      $Context.merged += $Context.collectedStreams
      foreach ($cw in $Context.workers) {
        if (-not $Context.completed.ContainsKey($cw.id)) { continue }
        $cres = $Context.completed[$cw.id]
        if (($cres.PSObject.Properties.Name -contains '_collected') -and $cres._collected) {
          [void]$Context.mergedStreams.Add([string]$cw.id)
        }
      }
      try { Add-Message -From system -Text ("📦 Collect-commit: " + $actualFiles + " реально изменённых файлов из " + $Context.collectedStreams + " потоков (только staged actual diff, не git add -A)") -Kind event | Out-Null } catch {}
      return
    }

    Quarantine-ParallelDispatchCollectedWorkers -Context $Context
    try { Add-Message -From system -Text ("❌ Collect-commit failed; collected streams quarantined") -Kind event | Out-Null } catch {}
  } catch {
    Quarantine-ParallelDispatchCollectedWorkers -Context $Context
    try { Add-Message -From system -Text ("❌ Collect-commit exception: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
  }
}

function Resolve-ParallelDispatchWorkerResult {
  param(
    [hashtable]$Context,
    [object]$Worker,
    [object]$Result
  )

  $res = $Result
  if (@($res.commits).Count -eq 0) {
    try {
      $origStatus = [string]$res.status
      $wtPath = Get-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash
      $dirtyWt = @(& $Context.gitExe -C $wtPath status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if (@($dirtyWt).Count -gt 0) {
        [void](Invoke-ParallelDispatchGitCommitWithRetry -RepoRoot $wtPath -Operation {
          $oldErrorActionPreference = $ErrorActionPreference
          $ErrorActionPreference = 'Continue'
          try {
            $out = New-Object 'System.Collections.Generic.List[object]'
            $addResult = Invoke-ParallelDispatchGitProcess -RepoRoot $wtPath -GitExe $Context.gitExe -GitArgs @('add','-A')
            foreach ($line in @($addResult.Output)) { [void]$out.Add($line) }
            if ([int]$addResult.ExitCode -ne 0) {
              return [pscustomobject]@{ ExitCode = ([int]$addResult.ExitCode); Output = @($out.ToArray()) }
            }
            $commitResult = Invoke-ParallelDispatchGitProcess -RepoRoot $wtPath -GitExe $Context.gitExe -GitArgs @('commit','-m',("host-commit parallel stream " + $Worker.id))
            foreach ($line in @($commitResult.Output)) { [void]$out.Add($line) }
            return [pscustomobject]@{ ExitCode = ([int]$commitResult.ExitCode); Output = @($out.ToArray()) }
          } finally {
            $ErrorActionPreference = $oldErrorActionPreference
          }
        })
        $hc = @(Get-WorkerCommits -Worker $Worker)
        if (@($hc).Count -gt 0) {
          $res = [pscustomobject]@{ status = 'done'; reply = $res.reply; commits = $hc }
          $Context.completed[$Worker.id] = $res
          try { Add-Message -From system -Text ("💾 Host закоммитил файлы воркера " + $Worker.id + " (" + @($hc).Count + " commit, был " + $dirtyWt.Count + " файл, статус CLI=" + $origStatus + ") — стрим спасён от потери") -Kind event | Out-Null } catch {}
        }
      }
    } catch {}
  }

  if ($res.status -eq 'done' -and $res.commits.Count -gt 0) {
    return $res
  }

  $fbRes = $null
  if (([string]$Worker.cli -eq 'claude') -and (@($Worker.files).Count -eq 1)) {
    try { $fbRes = Invoke-TrivialFallbackWorker -Worker $Worker -TaskHash $Context.taskHash } catch {
      try { Add-Message -From system -Text ("⚠ trivial-fallback exception for stream " + $Worker.id + ": " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  if ($null -ne $fbRes -and $fbRes.status -eq 'done' -and $fbRes.commits.Count -gt 0) {
    $Context.completed[$Worker.id] = $fbRes
    return $fbRes
  }

  Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
  try { Cleanup-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash } catch {}
  return $null
}

function Join-ParallelDispatchNativeArguments {
  param([object[]]$Arguments)

  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($arg in @($Arguments)) {
    if ($null -eq $arg) { continue }
    $s = [string]$arg
    if ($s.Length -eq 0) {
      [void]$parts.Add('""')
    } elseif ($s -notmatch '[\s"]') {
      [void]$parts.Add($s)
    } else {
      [void]$parts.Add('"' + ($s -replace '"','\"') + '"')
    }
  }
  return ($parts.ToArray() -join ' ')
}

function Invoke-ParallelDispatchGitProcess {
  param(
    [string]$RepoRoot,
    [object[]]$GitArgs,
    [string]$GitExe = ''
  )

  if ([string]::IsNullOrWhiteSpace($GitExe)) {
    try { $GitExe = Get-GitExe } catch { $GitExe = 'git' }
  }
  $args = @('-C', [string]$RepoRoot) + @($GitArgs)
  $exitCode = 1
  $output = @()
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitExe
    $psi.Arguments = Join-ParallelDispatchNativeArguments -Arguments $args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $exitCode = [int]$proc.ExitCode
    $combined = @($stdout, $stderr) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($combined)) {
      $output = @($combined -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = @($output | ForEach-Object { [string]$_ })
    Args     = @($args)
  }
}

function Merge-ParallelDispatchWorkerOutput {
  param(
    [hashtable]$Context,
    [object]$Worker
  )

  if ($Context.quarantined.Contains([string]$Worker.id)) {
    try { Cleanup-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash } catch {}
    return
  }
  if (-not $Context.completed.ContainsKey($Worker.id)) { return }

  $res = $Context.completed[$Worker.id]
  if (($res.PSObject.Properties.Name -contains '_collected') -and $res._collected) {
    try { Cleanup-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash } catch {}
    return
  }
  # Covered streams were credited as merged at collect time (work already in HEAD from an
  # earlier pass/session) — nothing to merge, and merging the empty branch would double-count.
  if (($res.PSObject.Properties.Name -contains '_covered') -and $res._covered) {
    try { Cleanup-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash } catch {}
    return
  }

  $res = Resolve-ParallelDispatchWorkerResult -Context $Context -Worker $Worker -Result $res
  if ($null -eq $res) { return }

  try {
    $mergeOut = Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--ff-only',[string]$Worker.branch)
    if ([int]$mergeOut.ExitCode -eq 0) {
      $Context.merged++
      [void]$Context.mergedStreams.Add([string]$Worker.id)
      Add-Message -From system -Text ("✅ Merged stream " + $Worker.id + " (" + $res.commits.Count + " commits, branch " + $Worker.branch + ")") -Kind event | Out-Null
    } else {
      $mergeOut2 = Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--no-ff','-m',("merge parallel stream " + $Worker.id),[string]$Worker.branch)
      if ([int]$mergeOut2.ExitCode -eq 0) {
        $Context.merged++
        [void]$Context.mergedStreams.Add([string]$Worker.id)
        Add-Message -From system -Text ("✅ Merged stream " + $Worker.id + " (non-ff fallback)") -Kind event | Out-Null
      } else {
        try { [void](Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--abort')) } catch {}
        $mergeOut3 = Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--no-ff','-X','ours','-m',("merge parallel stream " + $Worker.id + " (auto-resolve: ours)"),[string]$Worker.branch)
        if ([int]$mergeOut3.ExitCode -eq 0) {
          $Context.merged++
          [void]$Context.mergedStreams.Add([string]$Worker.id)
          Add-Message -From system -Text ("✅ Merged stream " + $Worker.id + " (конфликт авто-разрешён: сохранена уже слитая версия; ветка " + $Worker.branch + ")") -Kind event | Out-Null
        } else {
          try { [void](Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--abort')) } catch {}
          Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
          Add-Message -From system -Text ("⚠ Поток " + $Worker.id + " не слит (конфликт не разрешился авто). Дерево очищено — остальные потоки сливаются нормально. Ветка " + $Worker.branch + " сохранена для ручного разбора.") -Kind event | Out-Null
        }
      }
    }
  } catch {
    try { [void](Invoke-ParallelDispatchGitProcess -RepoRoot $Context.bridgeRoot -GitExe $Context.gitExe -GitArgs @('merge','--abort')) } catch {}
    Add-ParallelDispatchQuarantine -Context $Context -StreamId ([string]$Worker.id)
    Add-Message -From system -Text ("❌ Merge exception for stream " + $Worker.id + " (дерево очищено): " + $_.Exception.Message) -Kind event | Out-Null
  }

  try { Cleanup-WorkerWorktree -StreamId $Worker.id -TaskHash $Context.taskHash } catch {}
}

function Invoke-ParallelDispatchMergePhase {
  param([hashtable]$Context)

  foreach ($w in $Context.workers) {
    Merge-ParallelDispatchWorkerOutput -Context $Context -Worker $w
  }
}

function Complete-ParallelDispatchResult {
  param([hashtable]$Context)

  $quarantinedStreams = @($Context.quarantined)
  if ($quarantinedStreams.Count -gt 0) {
    try { Add-Message -From system -Text ("⚠️ Карантин: " + $quarantinedStreams.Count + " поток(ов) не собраны в репо (failed/unknown/no-touch/no-change/outside-touch/no-diff/exception/merge-failed/not-completed): " + ($quarantinedStreams -join ', ') + ". Требуется повторный прогон этих потоков.") -Kind event | Out-Null } catch {}
  }

  try {
    Update-State { param($s) $s | Add-Member -NotePropertyName parallel_streams -NotePropertyValue @() -Force } | Out-Null
  } catch {}

  $qCount = 0; try { $qCount = @($quarantinedStreams).Count } catch {}
  $totalStreams = 0; try { $totalStreams = @($Context.workers).Count } catch {}
  $mergedStreamIds = @()
  try {
    if ($Context.ContainsKey('mergedStreams') -and $null -ne $Context.mergedStreams) {
      $mergedStreamIds = @($Context.mergedStreams.ToArray())
    }
  } catch { $mergedStreamIds = @() }
  $cleanComplete = ($Context.merged -eq $totalStreams -and $qCount -eq 0 -and $totalStreams -gt 0)
  $anyDelivered = ($Context.merged -ge 1)
  return @{
    ok          = $anyDelivered
    merged      = $Context.merged
    merged_ids  = @($mergedStreamIds)
    quarantined = $qCount
    quarantined_ids = @($quarantinedStreams)
    total       = $totalStreams
    clean       = $cleanComplete
    reason      = $(if ($cleanComplete) { 'all_delivered' } elseif ($anyDelivered) { 'partial' } else { 'all_failed' })
  }
}

function Complete-ParallelDispatchOutputs {
  param(
    [object[]]$Workers,
    [object]$Completed,
    [string]$TaskHash
  )

  $context = New-ParallelDispatchAggregationContext -Workers $Workers -Completed $Completed -TaskHash $TaskHash
  Invoke-ParallelDispatchCollectPhase -Context $context
  Commit-ParallelDispatchCollectedOutputs -Context $context
  Invoke-ParallelDispatchMergePhase -Context $context
  return Complete-ParallelDispatchResult -Context $context
}

function Get-ParallelDispatchMapValue {
  param([object]$Map, [string]$Name, [object]$Default = $null)
  if ($null -eq $Map -or [string]::IsNullOrWhiteSpace($Name)) { return $Default }
  if ($Map -is [hashtable] -or $Map -is [System.Collections.IDictionary]) {
    if ($Map.Contains($Name)) { return $Map[$Name] }
    return $Default
  }
  try {
    if ($Map.PSObject -and ($Map.PSObject.Properties.Name -contains $Name)) { return $Map.$Name }
  } catch {}
  return $Default
}

function ConvertTo-ParallelDispatchStringArray {
  param([object]$Value)
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($v in @($Value)) {
    $s = ([string]$v).Trim()
    if (-not [string]::IsNullOrWhiteSpace($s) -and -not $out.Contains($s)) { [void]$out.Add($s) }
  }
  return @($out.ToArray())
}

function ConvertTo-ParallelDispatchCountMap {
  param([object]$Counts)
  $map = @{}
  if ($null -eq $Counts) { return $map }
  if ($Counts -is [hashtable] -or $Counts -is [System.Collections.IDictionary]) {
    foreach ($key in $Counts.Keys) {
      $v = 0
      if ([int]::TryParse([string]$Counts[$key], [ref]$v)) { $map[[string]$key] = [int]$v }
    }
    return $map
  }
  try {
    foreach ($prop in $Counts.PSObject.Properties) {
      $v = 0
      if ([int]::TryParse([string]$prop.Value, [ref]$v)) { $map[[string]$prop.Name] = [int]$v }
    }
  } catch {}
  return $map
}

function Update-ParallelDispatchQuarantineCountsSnapshot {
  param(
    [object]$Counts,
    [object]$GiveupIds,
    [object[]]$Streams,
    [string[]]$QuarantinedIds,
    [int]$Limit = 3
  )

  if ($Limit -lt 1) { $Limit = 3 }
  $countsMap = ConvertTo-ParallelDispatchCountMap -Counts $Counts
  $giveup = New-Object 'System.Collections.Generic.List[string]'
  foreach ($gid in @(ConvertTo-ParallelDispatchStringArray -Value $GiveupIds)) {
    if (-not $giveup.Contains($gid)) { [void]$giveup.Add($gid) }
  }

  $qSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($qid in @(ConvertTo-ParallelDispatchStringArray -Value $QuarantinedIds)) { [void]$qSet.Add($qid) }

  $newGiveup = New-Object 'System.Collections.Generic.List[string]'
  foreach ($stream in @($Streams)) {
    $sid = ''
    try { $sid = ([string]$stream.id).Trim() } catch {}
    if ([string]::IsNullOrWhiteSpace($sid)) { continue }

    if ($qSet.Contains($sid)) {
      $prev = 0
      if ($countsMap.ContainsKey($sid)) { $prev = [int]$countsMap[$sid] }
      $next = $prev + 1
      $countsMap[$sid] = $next
      if ($next -ge $Limit -and -not $giveup.Contains($sid)) {
        [void]$giveup.Add($sid)
        [void]$newGiveup.Add($sid)
      }
    } else {
      if ($countsMap.ContainsKey($sid)) { $countsMap.Remove($sid) }
    }
  }

  return [pscustomobject]@{
    counts = $countsMap
    giveup_ids = @($giveup.ToArray())
    new_giveup_ids = @($newGiveup.ToArray())
  }
}

function Get-ParallelDispatchQuarantineLimit {
  $limit = 3
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and $cfg.parallel -and ($cfg.parallel.PSObject.Properties.Name -contains 'batchQuarantineGiveup')) {
      $candidate = [int]$cfg.parallel.batchQuarantineGiveup
      if ($candidate -gt 0) { $limit = $candidate }
    }
  } catch {}
  return $limit
}

function Get-ParallelDispatchGiveupIds {
  param([string]$TaskHash = '')
  $st = $null
  try { $st = Read-State } catch {}
  if (-not $st) { return @() }
  if (-not [string]::IsNullOrWhiteSpace($TaskHash)) {
    $stateTaskHash = [string](Get-ParallelDispatchMapValue -Map $st -Name 'workpack_batch_quarantine_task_hash' -Default '')
    if ($stateTaskHash -and $stateTaskHash -ne $TaskHash) { return @() }
  }
  return @(ConvertTo-ParallelDispatchStringArray -Value (Get-ParallelDispatchMapValue -Map $st -Name 'workpack_batch_quarantine_giveup_ids' -Default @()))
}

function Get-ParallelDispatchBatchIdByStream {
  param([object[]]$Streams)
  $map = @{}
  $st = $null
  try { $st = Read-State } catch {}
  $batchIds = @()
  if ($st) { $batchIds = @(ConvertTo-ParallelDispatchStringArray -Value (Get-ParallelDispatchMapValue -Map $st -Name 'workpack_batch_ids' -Default @())) }
  $i = 0
  foreach ($stream in @($Streams)) {
    $sid = ''
    try { $sid = ([string]$stream.id).Trim() } catch {}
    if ([string]::IsNullOrWhiteSpace($sid)) { $i++; continue }
    if ($i -lt $batchIds.Count) { $map[$sid] = [string]$batchIds[$i] }
    $i++
  }
  return $map
}

function Set-ParallelDispatchBacklogHeldReason {
  param([string]$Id, [string]$Reason)

  if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Reason)) { return $false }
  $getBacklogCmd = Get-Command Get-Backlog -CommandType Function -ErrorAction SilentlyContinue
  $saveBacklogCmd = Get-Command Save-Backlog -CommandType Function -ErrorAction SilentlyContinue
  if (-not $getBacklogCmd -or -not $saveBacklogCmd) { return $false }
  $getBacklogFn = $getBacklogCmd.ScriptBlock
  $saveBacklogFn = $saveBacklogCmd.ScriptBlock
  $update = {
    $items = @(& $getBacklogFn)
    $found = $false
    foreach ($item in $items) {
      if ([string]$item.id -ne $Id) { continue }
      $item | Add-Member -NotePropertyName status -NotePropertyValue 'held' -Force
      $item | Add-Member -NotePropertyName held_reason -NotePropertyValue $Reason -Force
      $found = $true
      break
    }
    if ($found) { & $saveBacklogFn $items | Out-Null }
    return $found
  }.GetNewClosure()
  try {
    if (Get-Command Invoke-BacklogLocked -ErrorAction SilentlyContinue) {
      return [bool](Invoke-BacklogLocked $update)
    }
    return [bool](& $update)
  } catch {
    return $false
  }
}

function Set-ParallelDispatchGiveupBacklogItemsHeld {
  param(
    [string[]]$StreamIds,
    [hashtable]$StreamToBacklogId
  )

  if (-not $StreamIds -or @($StreamIds).Count -eq 0) { return @() }
  $held = New-Object 'System.Collections.Generic.List[string]'
  foreach ($sid in @(ConvertTo-ParallelDispatchStringArray -Value $StreamIds)) {
    if (-not $StreamToBacklogId.ContainsKey($sid)) { continue }
    $bid = [string]$StreamToBacklogId[$sid]
    if ([string]::IsNullOrWhiteSpace($bid)) { continue }
    if (Set-ParallelDispatchBacklogHeldReason -Id $bid -Reason 'batch-quarantine-giveup') {
      [void]$held.Add($bid)
    }
  }
  return @($held.ToArray())
}

function Get-ParallelDispatchBatchFinalizePlan {
  param(
    [object]$Result,
    [hashtable]$StreamToBacklogId,
    [string[]]$GiveupStreamIds
  )

  $giveupSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($sid in @(ConvertTo-ParallelDispatchStringArray -Value $GiveupStreamIds)) { [void]$giveupSet.Add($sid) }

  $doneIds = New-Object 'System.Collections.Generic.List[string]'
  $mergedIds = @()
  try { $mergedIds = @(ConvertTo-ParallelDispatchStringArray -Value $Result.merged_ids) } catch {}
  foreach ($sid in $mergedIds) {
    if ($giveupSet.Contains($sid)) { continue }
    if (-not $StreamToBacklogId.ContainsKey($sid)) { continue }
    $bid = ([string]$StreamToBacklogId[$sid]).Trim()
    if ([string]::IsNullOrWhiteSpace($bid)) { continue }
    if (-not $doneIds.Contains($bid)) { [void]$doneIds.Add($bid) }
  }

  return [pscustomobject]@{
    done_backlog_ids = @($doneIds.ToArray())
    held_stream_ids = @(ConvertTo-ParallelDispatchStringArray -Value $GiveupStreamIds)
    close_batch = ($giveupSet.Count -gt 0)
  }
}

function Update-ParallelDispatchBatchQuarantineState {
  param(
    [object[]]$Streams,
    [object]$Result,
    [hashtable]$StreamToBacklogId,
    [string]$TaskHash = ''
  )

  $quarantinedIds = @()
  try { $quarantinedIds = @(ConvertTo-ParallelDispatchStringArray -Value $Result.quarantined_ids) } catch {}
  $limit = Get-ParallelDispatchQuarantineLimit
  $snapshot = $null
  $heldIds = @()
  $finalizePlan = [pscustomobject]@{ done_backlog_ids = @(); held_stream_ids = @(); close_batch = $false }
  try {
    Update-State ({
      param($s)
      $stateTaskHash = [string](Get-ParallelDispatchMapValue -Map $s -Name 'workpack_batch_quarantine_task_hash' -Default '')
      if ($stateTaskHash -and $stateTaskHash -ne $TaskHash) {
        $s | Add-Member -NotePropertyName workpack_batch_quarantine_counts -NotePropertyValue @{} -Force
        $s | Add-Member -NotePropertyName workpack_batch_quarantine_giveup_ids -NotePropertyValue @() -Force
      }
      $counts = Get-ParallelDispatchMapValue -Map $s -Name 'workpack_batch_quarantine_counts' -Default @{}
      $giveup = Get-ParallelDispatchMapValue -Map $s -Name 'workpack_batch_quarantine_giveup_ids' -Default @()
      $script:ParallelDispatchLastQuarantineSnapshot = Update-ParallelDispatchQuarantineCountsSnapshot -Counts $counts -GiveupIds $giveup -Streams $Streams -QuarantinedIds $quarantinedIds -Limit $limit
      $s | Add-Member -NotePropertyName workpack_batch_quarantine_counts -NotePropertyValue $script:ParallelDispatchLastQuarantineSnapshot.counts -Force
      $s | Add-Member -NotePropertyName workpack_batch_quarantine_giveup_ids -NotePropertyValue @($script:ParallelDispatchLastQuarantineSnapshot.giveup_ids) -Force
      $s | Add-Member -NotePropertyName workpack_batch_quarantine_limit -NotePropertyValue $limit -Force
      $s | Add-Member -NotePropertyName workpack_batch_quarantine_task_hash -NotePropertyValue $TaskHash -Force
    }.GetNewClosure()) | Out-Null
    $snapshot = $script:ParallelDispatchLastQuarantineSnapshot
  } catch {}

  $newGiveupIds = @()
  try { $newGiveupIds = @(ConvertTo-ParallelDispatchStringArray -Value $snapshot.new_giveup_ids) } catch {}
  if ($newGiveupIds.Count -gt 0) {
    $finalizePlan = Get-ParallelDispatchBatchFinalizePlan -Result $Result -StreamToBacklogId $StreamToBacklogId -GiveupStreamIds $newGiveupIds
    $heldIds = @(Set-ParallelDispatchGiveupBacklogItemsHeld -StreamIds $newGiveupIds -StreamToBacklogId $StreamToBacklogId)
    try {
      Update-State ({
        param($s)
        $doneBacklogIds = @($finalizePlan.done_backlog_ids)
        try { Complete-TaskAgentDuration $s } catch {}
        try { Close-ReplayForStateTask -State $s -Status 'partial' } catch {}
        $s.current_task = $null
        $s.current_task_id = $null
        $s.current_backlog_id = $null
        $s.task_turn = 0
        $s.task_mode = 'normal'
        $s.no_progress_count = 0
        $s.timeout_retry_count = 0
        $s.task_did_actions = $true
        $s.coder_fired = $true
        $s.force_planner = $false
        $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force
        $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force
        $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force
        $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @($doneBacklogIds) -Force
        $s | Add-Member -NotePropertyName workpack_batch_quarantine_counts -NotePropertyValue @{} -Force
        $s | Add-Member -NotePropertyName workpack_batch_quarantine_giveup_ids -NotePropertyValue @() -Force
        $s | Add-Member -NotePropertyName workpack_batch_quarantine_task_hash -NotePropertyValue '' -Force
        $s.active_agent = $null
        $s.active_model = $null
        $s.status_text = $null
        $s.status = 'idle'
      }.GetNewClosure()) | Out-Null
    } catch {}
    try { Add-Message -From system -Text ("🛑 Parallel batch partial finalized: streams gave up after " + $limit + " consecutive quarantines: " + ($newGiveupIds -join ', ') + $(if ($heldIds.Count -gt 0) { "; held backlog ids: " + ($heldIds -join ', ') } else { "" })) -Kind event | Out-Null } catch {}
  }

  return [pscustomobject]@{
    limit = $limit
    quarantined_ids = @($quarantinedIds)
    giveup_ids = @($snapshot.giveup_ids)
    new_giveup_ids = @($newGiveupIds)
    held_backlog_ids = @($heldIds)
    done_backlog_ids = @($finalizePlan.done_backlog_ids)
  }
}

function Test-ParallelDispatchQuarantineGiveupSelfCheck {
  $streams = @(
    [pscustomobject]@{ id='good' },
    [pscustomobject]@{ id='bad' }
  )
  $first = Update-ParallelDispatchQuarantineCountsSnapshot -Counts @{} -GiveupIds @() -Streams $streams -QuarantinedIds @('bad') -Limit 3
  if ([int]$first.counts['bad'] -ne 1 -or @($first.new_giveup_ids).Count -ne 0) { throw 'quarantine giveup self-check failed: first strike' }
  $second = Update-ParallelDispatchQuarantineCountsSnapshot -Counts $first.counts -GiveupIds $first.giveup_ids -Streams $streams -QuarantinedIds @('bad') -Limit 3
  if ([int]$second.counts['bad'] -ne 2 -or @($second.new_giveup_ids).Count -ne 0) { throw 'quarantine giveup self-check failed: second strike' }
  $third = Update-ParallelDispatchQuarantineCountsSnapshot -Counts $second.counts -GiveupIds $second.giveup_ids -Streams $streams -QuarantinedIds @('bad') -Limit 3
  if ([int]$third.counts['bad'] -ne 3 -or @($third.new_giveup_ids).Count -ne 1 -or @($third.new_giveup_ids)[0] -ne 'bad') { throw 'quarantine giveup self-check failed: giveup threshold' }
  $reset = Update-ParallelDispatchQuarantineCountsSnapshot -Counts $third.counts -GiveupIds $third.giveup_ids -Streams $streams -QuarantinedIds @() -Limit 3
  if ($reset.counts.ContainsKey('bad')) { throw 'quarantine giveup self-check failed: success reset' }
  return $true
}

function Invoke-ParallelDispatch {
  # End-to-end orchestration for a parallel split detected in planner reply.
  # FIX 2026-05-27 (manual implementation, replaces Codex's chunk-2 that state-wiped).
  # Spawns workers in worktrees, polls until all done or timeout, fast-forward merges
  # their wip-branches into main, cleans up. Returns @{ok=$bool; merged=$count; reason=...}.
  param(
    [object[]]$Streams,
    [int]$TimeoutMin = 25,
    [int]$PollSec = 10
  )
  if (-not $Streams -or $Streams.Count -lt 2) {
    return @{ ok=$false; merged=0; reason='need >= 2 streams' }
  }

  # Use task_base_commit as starting point. Each worker gets its own worktree off this.
  $base = Get-ParallelTaskBaseCommit
  if ([string]::IsNullOrWhiteSpace($base)) {
    return @{ ok=$false; merged=0; reason='no task_base_commit' }
  }

  $allStreams = @($Streams)
  $taskHash = Get-ParallelDispatchTaskHash
  $giveupBefore = @(Get-ParallelDispatchGiveupIds -TaskHash $taskHash)
  if ($giveupBefore.Count -gt 0) {
    $blocked = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($gid in $giveupBefore) { [void]$blocked.Add($gid) }
    $Streams = @($allStreams | Where-Object { -not $blocked.Contains([string]$_.id) })
    if ($Streams.Count -lt $allStreams.Count) {
      try { Add-Message -From system -Text ("⏭ Parallel batch: пропускаю persistently-quarantined stream(s): " + ($giveupBefore -join ', ')) -Kind event | Out-Null } catch {}
    }
    if ($Streams.Count -eq 0) {
      return @{ ok=$false; merged=0; quarantined=0; quarantined_ids=@(); total=@($allStreams).Count; clean=$false; reason='all_streams_quarantine_giveup' }
    }
  }

  $streamToBacklogId = Get-ParallelDispatchBatchIdByStream -Streams @($allStreams)

  # 2026-05-27 refactor: route each stream through Select-WorkerForStream
  # (strength-floor + domain affinity + no double-booking). Falls back to
  # built-in default pool if config.parallel.workers is missing.
  $startup = Start-ParallelDispatchWorkers -Streams @($Streams) -TaskHash $taskHash
  if (-not $startup.ok) {
    return @{ ok=$false; merged=0; reason=$startup.reason }
  }

  $workers = @($startup.workers)
  $completed = Wait-ParallelDispatchResults -Workers $workers -TaskHash $taskHash -TimeoutMin $TimeoutMin -PollSec $PollSec
  $result = Complete-ParallelDispatchOutputs -Workers $workers -Completed $completed -TaskHash $taskHash
  $qState = Update-ParallelDispatchBatchQuarantineState -Streams @($allStreams) -Result $result -StreamToBacklogId $streamToBacklogId -TaskHash $taskHash
  try {
    $newGiveupCount = @($qState.new_giveup_ids).Count
    if ($newGiveupCount -gt 0) {
      $result.reason = 'partial_quarantine_giveup'
      $result.ok = $true
      $result.clean = $false
      $result.quarantined = 0
      $result.quarantined_ids = @()
      $result | Add-Member -NotePropertyName quarantine_giveup_ids -NotePropertyValue @($qState.new_giveup_ids) -Force
      $result | Add-Member -NotePropertyName held_backlog_ids -NotePropertyValue @($qState.held_backlog_ids) -Force
      $result | Add-Member -NotePropertyName done_backlog_ids -NotePropertyValue @($qState.done_backlog_ids) -Force
    }
  } catch {}
  return $result
}
