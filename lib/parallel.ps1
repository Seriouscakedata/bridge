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

  $streams = New-Object System.Collections.Generic.List[object]
  $owners = @{}
  foreach ($m in $matches) {
    $id = Normalize-ParallelId $m.Groups['id'].Value
    $body = ([string]$m.Groups['body'].Value).Trim()
    $files = @(Get-ParallelFilesFromBody $body)
    if ($files.Count -eq 0) { return $null }

    foreach ($f in $files) {
      if ($owners.ContainsKey($f) -and [string]$owners[$f] -ne $id) { return $null }
      $owners[$f] = $id
    }

    [void]$streams.Add([pscustomobject]@{
      id         = $id
      files      = @($files)
      complexity = Get-ParallelComplexityFromBody $body
      opus       = ([string]$body -match '\[\[OPUS\]\]')
      body       = $body
    })
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
  return ([string]$base).Trim()
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
    if ($rel -eq $dn) { return $true }
    if ($rel.StartsWith($dn + '/')) { return $true }
  }
  return $false
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

function Start-ParallelDispatchWorkers {
  param(
    [object[]]$Streams,
    [string]$TaskHash
  )

  $workers = New-Object 'System.Collections.Generic.List[object]'
  $usedIds = New-Object 'System.Collections.Generic.List[string]'

  Write-ParallelDispatchTeamPlan -Streams @($Streams)

  foreach ($s in @($Streams)) {
    $spec = $null
    try { $spec = Select-WorkerForStream -Stream $s -AlreadyUsedIds @($usedIds.ToArray()) } catch {
      try { Add-Message -From system -Text ("⚠ parallel: router error for stream " + $s.id + ": " + $_.Exception.Message + " -- using fallback") -Kind event | Out-Null } catch {}
    }
    if (-not $spec) {
      # Total fallback: first item from pool (or built-in default)
      $pool = @(Get-ParallelWorkerPool)
      if ($pool.Count -gt 0) { $spec = $pool[0] }
    }
    if (-not $spec) {
      try { Add-Message -From system -Text ("❌ parallel: no worker pool available for stream " + $s.id) -Kind event } catch {}
      Stop-ParallelDispatchWorkers -Workers @($workers.ToArray()) -TaskHash $TaskHash
      return @{ ok=$false; workers=@($workers.ToArray()); reason='no worker pool' }
    }

    $branch = "wip/parallel/$TaskHash/$($s.id)"
    try {
      $worktree = Get-WorkerWorktree -StreamId $s.id -TaskHash $TaskHash
      $w = Spawn-Worker -StreamId $s.id -Body $s.body -Worktree $worktree -BranchName $branch -WorkerSpec $spec
      [void]$workers.Add($w)
      [void]$usedIds.Add([string]$spec.id)
      try {
        $complexity = Get-StreamComplexity $s
        $domain = Get-StreamDomain $s
        Add-Message -From system -Text ("🔀 Spawned worker: stream=" + $s.id + " worker=" + $spec.id + " (" + $spec.cli + "/" + $spec.model + ($(if($spec.reasoning){'/' + $spec.reasoning}else{''})) + ") complexity=" + $complexity + " domain=" + $domain + " files=[" + (($s.files) -join ',') + "]") -Kind event
      } catch {}
    } catch {
      try { Add-Message -From system -Text ("❌ Parallel spawn failed for stream " + $s.id + ": " + $_.Exception.Message) -Kind event } catch {}
      Stop-ParallelDispatchWorkers -Workers @($workers.ToArray()) -TaskHash $TaskHash
      return @{ ok=$false; workers=@($workers.ToArray()); reason="spawn failed: $($_.Exception.Message)" }
    }
  }

  try { Save-ParallelStreams -State (Read-State) -Streams $workers } catch {}
  return @{ ok=$true; workers=@($workers.ToArray()); reason='' }
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
      # Timeout: kill remaining, report partial
      foreach ($w in $workers) {
        if ($completed.ContainsKey($w.id)) { continue }
        try { if ($w.process -and -not $w.process.HasExited) { Start-Process taskkill -ArgumentList '/PID',([string]$w.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue } } catch {}
      }
      try { Add-Message -From system -Text ("⏱ Parallel timeout (" + $TimeoutMin + " min) -- killing in-flight workers") -Kind event } catch {}
      break
    }
    Start-Sleep -Seconds $PollSec
    # H1 FIX (2026-05-31 load audit): refresh the channel heartbeat each poll. A parallel run can
    # last up to $TimeoutMin (25m); without this the heartbeat goes stale past the watchdog's 300s
    # window -> watchdog sees "driver dead" -> git reset --hard stable WHILE workers are mid-merge,
    # destroying in-flight work (the exact false-rollback class, re-introduced by parallel mode).
    # Sibling poll loops (Invoke-ParallelWorkers/CodexParallel) already tick via $OnTick; this one
    # didn't. Inline refresh keeps the watchdog calm; the parallel $deadline still bounds a true hang.
    try { Update-State { param($s) $s.heartbeat = (Get-Date).ToString('o') } | Out-Null } catch {}
    foreach ($w in $workers) {
      if ($completed.ContainsKey($w.id)) { continue }
      $res = Get-WorkerResult $w
      if ($res.status -eq 'running') { continue }

      # 2026-05-27: chunk-progress handling. Worker emitted CONTINUE-CHUNK:N/M.
      # Verify the worker's branch actually advanced (commit landed), then
      # respawn the same worker on the next chunk in the same worktree.
      # If branch didn't advance or chunk limit hit -- close the worker.
      if ($res.status -eq 'chunk-progress') {
        $chunkN = [int]$res.chunkN
        $chunkM = [int]$res.chunkM
        $branchHead = ''
        try { $branchHead = ((& git -C (Get-ParallelRepoRoot) rev-parse $w.branch 2>$null) | Select-Object -First 1).Trim() } catch {}
        $advanced = (-not [string]::IsNullOrWhiteSpace($branchHead)) -and ($branchHead -ne [string]$w.chunkLastSha)
        if (-not $advanced) {
          # No commit since last chunk — worker lied / forgot to commit. Mark failed.
          $completed[$w.id] = [pscustomobject]@{ status='failed'; reply=$res.reply; commits=$res.commits; chunkN=$chunkN; chunkM=$chunkM; error='chunk emitted but branch did not advance' }
          try { Add-Message -From system -Text ("❌ Worker " + $w.id + " emitted CONTINUE-CHUNK:" + $chunkN + "/" + $chunkM + " but branch " + $w.branch + " did not advance (no commit). Killing.") -Kind event } catch {}
          continue
        }
        if ($chunkN -ge 10) {
          # Chunk limit reached — close as done with what we have
          $completed[$w.id] = [pscustomobject]@{ status='done'; reply=$res.reply; commits=$res.commits; chunkN=$chunkN; chunkM=$chunkM; error='chunk limit reached (10)' }
          try { Add-Message -From system -Text ("⚠ Worker " + $w.id + " reached chunk limit (10/" + $chunkM + ") -- closing as done.") -Kind event } catch {}
          continue
        }
        # Respawn for next chunk
        $shortLast = if ($branchHead.Length -gt 7) { $branchHead.Substring(0,7) } else { $branchHead }
        try {
          $null = Respawn-WorkerForChunk -Worker $w -NextChunk ($chunkN + 1) -TotalChunks $chunkM -LastCommitSha $branchHead
          try { Add-Message -From system -Text ("🔂 Worker " + $w.id + " chunk " + $chunkN + "/" + $chunkM + " committed " + $shortLast + " -- respawned on chunk " + ($chunkN + 1) + "/" + $chunkM) -Kind event } catch {}
        } catch {
          $completed[$w.id] = [pscustomobject]@{ status='failed'; reply=$res.reply; commits=$res.commits; chunkN=$chunkN; chunkM=$chunkM; error=("respawn failed: " + $_.Exception.Message) }
          try { Add-Message -From system -Text ("❌ Worker " + $w.id + " respawn failed at chunk " + ($chunkN + 1) + "/" + $chunkM + ": " + $_.Exception.Message) -Kind event } catch {}
        }
        continue
      }

      # Terminal status (done / paused-for-restart / failed)
      $completed[$w.id] = $res
      $chunkSummary = if ([int]$w.chunksDone -gt 0) { (" via " + [int]$w.chunksDone + " chunks") } else { '' }
      try { Add-Message -From system -Text ("🔀 Worker " + $w.id + " (" + $w.coder + ") finished: status=" + $res.status + ", commits=" + $res.commits.Count + $chunkSummary) -Kind event } catch {}
    }
  }

  return $completed
}

function Complete-ParallelDispatchOutputs {
  param(
    [object[]]$Workers,
    [hashtable]$Completed,
    [string]$TaskHash
  )

  $workers = @($Workers)
  $completed = $Completed

  # Merge phase: fast-forward each wip-branch into HEAD on the channel's repo (project_root for
  # project channels, bridge for main). 2026-05-31 Foundation #4 scale.
  $merged = 0
  $bridgeRoot = Get-ParallelRepoRoot

  # 2026-06-01 COLLECT-THEN-COMMIT (root reliability fix). Empirically (probe3, 20 streams): workers
  # RELIABLY produce files in their worktree working-tree, but UNreliably commit them — codex exits
  # 'paused-for-restart' (sandbox user can't write linked .git), the LLM/claude workers often finish
  # 'done' with commits=0, and the per-branch ff/merge path below then races Cleanup, so only ~7/20
  # files survived a single pass (the rest were recovered only by repeated re-dispatch passes). FIX:
  # before any branch operation, the HOST directly collects every worker's changed files (committed-
  # vs-base + untracked/modified) straight into the repo working-tree and commits them in ONE pass.
  # Each stream owns a disjoint touch-set (workpack conflict_group), so there are no add/add conflicts.
  # This makes delivery independent of each CLI's git behaviour and of merge/cleanup timing.
  $collected = 0; $collectedStreams = 0
  $quarantined = New-Object System.Collections.Generic.List[string]
  $addQuarantine = {
    param([string]$StreamId)
    if ([string]::IsNullOrWhiteSpace($StreamId)) { return }
    if (-not $quarantined.Contains($StreamId)) { [void]$quarantined.Add($StreamId) }
  }
  $base0 = Get-ParallelTaskBaseCommit
  $gitC = Get-GitExe
  $deliveredPaths = New-Object System.Collections.Generic.List[string]  # actually staged paths

  $allowedTerminalStatuses = @('done', 'paused-for-restart')

  foreach ($w in $workers) {
    if ($completed.ContainsKey($w.id)) { continue }
    & $addQuarantine ([string]$w.id)
    try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": worker не завершился до timeout/kill, stream не доставлен") -Kind event | Out-Null } catch {}
  }

  foreach ($w in $workers) {
    if (-not $completed.ContainsKey($w.id)) { continue }
    $wst = ''
    try { $wst = [string]$completed[$w.id].status } catch {}

    # Quarantine: failed or unknown terminal status
    if ($wst -eq 'failed' -or $allowedTerminalStatuses -notcontains $wst) {
      & $addQuarantine ([string]$w.id)
      continue
    }

    # Declared touch-set for this stream
    $declaredFiles = @()
    try { $declaredFiles = @($w.files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch {}

    # Quarantine: no declared files (no touch-set -> cannot validate what to copy)
    if ($declaredFiles.Count -eq 0) {
      & $addQuarantine ([string]$w.id)
      try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": нет объявленных файлов (w.files пуст) — сбор невозможен") -Kind event | Out-Null } catch {}
      continue
    }

    try {
      $wtPath = Get-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash
      if (-not (Test-Path -LiteralPath $wtPath)) {
        & $addQuarantine ([string]$w.id)
        continue
      }

      # Collect changed paths from worktree
      $changed = New-Object System.Collections.Generic.HashSet[string]
      if (-not [string]::IsNullOrWhiteSpace($base0)) {
        try { @(& $gitC -C $wtPath diff --name-only $base0 2>$null) | Where-Object { $_ } | ForEach-Object { [void]$changed.Add(($_.Trim() -replace '"','')) } } catch {}
      }
      try { @(& $gitC -C $wtPath status --porcelain 2>$null) | Where-Object { $_ } | ForEach-Object { $p = ($_.Substring([Math]::Min(3,$_.Length))).Trim().Trim('"'); if ($p -and $p -notmatch '->') { [void]$changed.Add($p) } } } catch {}

      # No changed files AND no commits: quarantine (no-change stream)
      $streamCommits = 0
      try { $streamCommits = @($completed[$w.id].commits).Count } catch {}
      if ($changed.Count -eq 0 -and $streamCommits -eq 0) {
        & $addQuarantine ([string]$w.id)
        try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": нет изменённых файлов и нет коммитов (no-change stream)") -Kind event | Out-Null } catch {}
        continue
      }

      # Validate ALL changed paths against declared touch-set BEFORE copying
      $allowedPaths = New-Object System.Collections.Generic.List[string]
      $deniedPaths  = New-Object System.Collections.Generic.List[string]
      foreach ($rel in $changed) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if (Test-ParallelCollectedPathAllowed -RelativePath $rel -DeclaredFiles $declaredFiles) {
          $allowedPaths.Add($rel)
        } else {
          $deniedPaths.Add($rel)
        }
      }

      if ($deniedPaths.Count -gt 0) {
        & $addQuarantine ([string]$w.id)
        try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": stream quarantined because outside touch-set path(s) were changed: " + ($deniedPaths -join ', ')) -Kind event | Out-Null } catch {}
        continue
      }

      if ($allowedPaths.Count -eq 0) {
        & $addQuarantine ([string]$w.id)
        try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": нет разрешённых путей (все вне touch-set или пустые)") -Kind event | Out-Null } catch {}
        continue
      }

      # Copy allowed paths, then verify actual git diff in root
      $copiedHere = 0
      $actuallyDelivered = New-Object System.Collections.Generic.List[string]
      foreach ($rel in $allowedPaths) {
        $src = Join-Path $wtPath $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $bridgeRoot $rel
        $dstDir = Split-Path $dst -Parent
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copiedHere++

        # Post-copy: verify git sees a real diff for this path in root
        $gitDiffOut = @(& $gitC -C $bridgeRoot status --porcelain -- $rel 2>$null | Where-Object { $_ })
        if ($gitDiffOut.Count -gt 0) {
          $actuallyDelivered.Add($rel)
          $deliveredPaths.Add($rel)
        }
      }

      if ($actuallyDelivered.Count -gt 0) {
        $collected += $actuallyDelivered.Count
        $collectedStreams++
        try { $completed[$w.id] | Add-Member -NotePropertyName _collected -NotePropertyValue $true -Force } catch {}
        try { $completed[$w.id] | Add-Member -NotePropertyName _deliveredPaths -NotePropertyValue @($actuallyDelivered) -Force } catch {}
      } else {
        # Copied files but git sees no diff (e.g. files identical to root)
        & $addQuarantine ([string]$w.id)
        try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": скопировано " + $copiedHere + " файл(ов), но git diff пуст — изменений нет") -Kind event | Out-Null } catch {}
      }
    } catch {
      & $addQuarantine ([string]$w.id)
      try { Add-Message -From system -Text ("⚠️ Карантин поток " + $w.id + ": исключение при сборе: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }

  # Commit only actually-delivered paths (not git add -A)
  if ($collectedStreams -gt 0 -and $deliveredPaths.Count -gt 0) {
    try {
      foreach ($p in $deliveredPaths) {
        & $gitC -C $bridgeRoot add -- $p 2>$null | Out-Null
      }
      $actualFiles = $deliveredPaths.Count
      & $gitC -C $bridgeRoot commit -m ("parallel collect: " + $collectedStreams + " streams, " + $actualFiles + " actual changed files") 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        $merged += $collectedStreams
        try { Add-Message -From system -Text ("📦 Collect-commit: " + $actualFiles + " реально изменённых файлов из " + $collectedStreams + " потоков (только staged actual diff, не git add -A)") -Kind event | Out-Null } catch {}
      } else {
        foreach ($cw in $workers) {
          if (-not $completed.ContainsKey($cw.id)) { continue }
          $cres = $completed[$cw.id]
          if (($cres.PSObject.Properties.Name -contains '_collected') -and $cres._collected) { & $addQuarantine ([string]$cw.id) }
        }
        try { Add-Message -From system -Text ("❌ Collect-commit failed; collected streams quarantined") -Kind event | Out-Null } catch {}
      }
    } catch {
      foreach ($cw in $workers) {
        if (-not $completed.ContainsKey($cw.id)) { continue }
        $cres = $completed[$cw.id]
        if (($cres.PSObject.Properties.Name -contains '_collected') -and $cres._collected) { & $addQuarantine ([string]$cw.id) }
      }
      try { Add-Message -From system -Text ("❌ Collect-commit exception: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }

  foreach ($w in $workers) {
    if ($quarantined.Contains([string]$w.id)) {
      try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash } catch {}
      continue
    }
    if (-not $completed.ContainsKey($w.id)) { continue }
    $res = $completed[$w.id]
    # Already delivered by collect-then-commit above — just clean its worktree and skip branch merge.
    if (($res.PSObject.Properties.Name -contains '_collected') -and $res._collected) {
      try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash } catch {}
      continue
    }
    # 2026-06-01: HOST-COMMIT RECOVERY. A worker (especially codex in the Windows sandbox, but also
    # the new DeepSeek/Gemini LLM-workers if their own commit didn't register) PRODUCES files in its
    # worktree yet often can't git-commit them (sandbox user has no write to the linked .git), so
    # commits=0 and the work was silently lost in the cleanup branch below (observed: only 9/19
    # streams merged). If the worktree has uncommitted changes, the host (repo owner) commits them
    # now and re-reads commits -> the stream still merges. This recovers ALL clis, not just claude.
    # 2026-06-01 ROOT FIX: recovery must fire for ANY terminal status when commits=0, NOT just
    # status='done'. Codex on Windows exits the sandbox in status='paused-for-restart' (the restricted
    # CodexSandboxOffline user can't create .git/worktrees/<id>/index.lock, so codex aborts its own
    # commit and reports paused-for-restart) — yet it HAS already written the files into the worktree
    # cwd (which the sandbox CAN write). The old `status -eq 'done'` guard skipped exactly these
    # workers, so they fell through to Cleanup below and their files were deleted (observed: only
    # 9-13/20 streams merged, host-commit fired 0 times even though codex produced every file). Now the
    # host (repo owner, full write) commits the worktree's pending changes regardless of how the CLI
    # exited. If the worktree is genuinely empty (real failure), dirtyWt=0 and this is a safe no-op.
    if (@($res.commits).Count -eq 0) {
      try {
        $origStatus = [string]$res.status
        $wtPath = Get-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash
        $gitX = Get-GitExe
        $dirtyWt = @(& $gitX -C $wtPath status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (@($dirtyWt).Count -gt 0) {
          & $gitX -C $wtPath add -A 2>$null | Out-Null
          & $gitX -C $wtPath commit -m ("host-commit parallel stream " + $w.id) 2>$null | Out-Null
          $hc = @(Get-WorkerCommits -Worker $w)
          if (@($hc).Count -gt 0) {
            $res = [pscustomobject]@{ status = 'done'; reply = $res.reply; commits = $hc }
            $completed[$w.id] = $res
            try { Add-Message -From system -Text ("💾 Host закоммитил файлы воркера " + $w.id + " (" + @($hc).Count + " commit, был " + $dirtyWt.Count + " файл, статус CLI=" + $origStatus + ") — стрим спасён от потери") -Kind event | Out-Null } catch {}
          }
        }
      } catch {}
    }
    if ($res.status -ne 'done' -or $res.commits.Count -eq 0) {
      $fbRes = $null
      if (([string]$w.cli -eq 'claude') -and (@($w.files).Count -eq 1)) {
        try { $fbRes = Invoke-TrivialFallbackWorker -Worker $w -TaskHash $TaskHash } catch {
          try { Add-Message -From system -Text ("⚠ trivial-fallback exception for stream " + $w.id + ": " + $_.Exception.Message) -Kind event | Out-Null } catch {}
        }
      }
      if ($null -ne $fbRes -and $fbRes.status -eq 'done' -and $fbRes.commits.Count -gt 0) {
        $res = $fbRes
        $completed[$w.id] = $fbRes
      } else {
        & $addQuarantine ([string]$w.id)
        try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash } catch {}
        continue
      }
    }
    try {
      # 1) ff-only merge (clean, no merge commit)
      $mergeOut = & git -C $bridgeRoot merge --ff-only $w.branch 2>&1
      if ($LASTEXITCODE -eq 0) {
        $merged++
        Add-Message -From system -Text ("✅ Merged stream " + $w.id + " (" + $res.commits.Count + " commits, branch " + $w.branch + ")") -Kind event | Out-Null
      } else {
        # 2) non-ff merge commit
        $mergeOut2 = & git -C $bridgeRoot merge --no-ff -m ("merge parallel stream " + $w.id) $w.branch 2>&1
        if ($LASTEXITCODE -eq 0) {
          $merged++
          Add-Message -From system -Text ("✅ Merged stream " + $w.id + " (non-ff fallback)") -Kind event | Out-Null
        } else {
          # 3) CONFLICT (e.g. two workers created the same new file = add/add). ROOT-CAUSE FIX 2026-05-29:
          # NEVER leave the tree in an unmerged state -- that blocks EVERY sibling stream ("Merging is not
          # possible: unmerged files") and sinks the whole parallel run (this is why parallel "failed" and
          # fell back to sequential, losing the speed-up). Abort to free the tree, then retry with a
          # conflict-tolerant strategy: -X ours keeps the already-merged side on conflict, while NEW
          # non-conflicting files from this stream still merge in. If even that fails, abort again so the
          # tree stays CLEAN and the remaining streams can still merge; the branch is kept for review.
          try { & git -C $bridgeRoot merge --abort 2>&1 | Out-Null } catch {}
          $mergeOut3 = & git -C $bridgeRoot merge --no-ff -X ours -m ("merge parallel stream " + $w.id + " (auto-resolve: ours)") $w.branch 2>&1
          if ($LASTEXITCODE -eq 0) {
            $merged++
            Add-Message -From system -Text ("✅ Merged stream " + $w.id + " (конфликт авто-разрешён: сохранена уже слитая версия; ветка " + $w.branch + ")") -Kind event | Out-Null
          } else {
            try { & git -C $bridgeRoot merge --abort 2>&1 | Out-Null } catch {}
            & $addQuarantine ([string]$w.id)
            Add-Message -From system -Text ("⚠ Поток " + $w.id + " не слит (конфликт не разрешился авто). Дерево очищено — остальные потоки сливаются нормально. Ветка " + $w.branch + " сохранена для ручного разбора.") -Kind event | Out-Null
          }
        }
      }
    } catch {
      try { & git -C $bridgeRoot merge --abort 2>&1 | Out-Null } catch {}
      & $addQuarantine ([string]$w.id)
      Add-Message -From system -Text ("❌ Merge exception for stream " + $w.id + " (дерево очищено): " + $_.Exception.Message) -Kind event | Out-Null
    }
    try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $TaskHash } catch {}
  }

  # 2026-06-01 ERR-004: surface quarantined (failed) streams so the operator/driver knows their work
  # was deliberately NOT merged. $quarantinedStreams is also consumed by the terminal-result logic
  # (ERR-006) so a batch with failures is finalized as 'partial' (needs re-dispatch), not silently
  # repeated as a generic "parallel completed".
  $quarantinedStreams = @($quarantined)
  if ($quarantinedStreams.Count -gt 0) {
    try { Add-Message -From system -Text ("⚠️ Карантин: " + $quarantinedStreams.Count + " поток(ов) не собраны в репо (failed/unknown/no-touch/no-change/outside-touch/no-diff/exception/merge-failed/not-completed): " + ($quarantinedStreams -join ', ') + ". Требуется повторный прогон этих потоков.") -Kind event | Out-Null } catch {}
  }

  # Clear parallel_streams from state -- via Update-State (Add-Member preserves other fields)
  try {
    Update-State { param($s) $s | Add-Member -NotePropertyName parallel_streams -NotePropertyValue @() -Force } | Out-Null
  } catch {}

  # 2026-06-01 ERR-009: surface quarantined (failed) stream count + total so the driver can tell a
  # CLEAN all-streams-merged result apart from a MIXED one (e.g. 4 failed + 1 done). A mixed result
  # must NOT be reported to the user as a plain "DONE: N потоков" — the caller bounces it for rework.
  $qCount = 0; try { $qCount = @($quarantinedStreams).Count } catch {}
  $totalStreams = 0; try { $totalStreams = @($workers).Count } catch {}
  # Determine ok:
  # - all delivered (merged == total) and quarantined == 0 -> clean complete, ok=true
  # - mixed (some delivered, some quarantined) -> ok=true + quarantined>0 (driver enters partial repair)
  # - none delivered -> ok=false
  $cleanComplete = ($merged -eq $totalStreams -and $qCount -eq 0 -and $totalStreams -gt 0)
  $anyDelivered  = ($merged -ge 1)
  return @{
    ok          = $anyDelivered
    merged      = $merged
    quarantined = $qCount
    total       = $totalStreams
    clean       = $cleanComplete
    reason      = $(if ($cleanComplete) { 'all_delivered' } elseif ($anyDelivered) { 'partial' } else { 'all_failed' })
  }
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

  $taskHash = Get-ParallelDispatchTaskHash

  # 2026-05-27 refactor: route each stream through Select-WorkerForStream
  # (strength-floor + domain affinity + no double-booking). Falls back to
  # built-in default pool if config.parallel.workers is missing.
  $startup = Start-ParallelDispatchWorkers -Streams @($Streams) -TaskHash $taskHash
  if (-not $startup.ok) {
    return @{ ok=$false; merged=0; reason=$startup.reason }
  }

  $workers = @($startup.workers)
  $completed = Wait-ParallelDispatchResults -Workers $workers -TaskHash $taskHash -TimeoutMin $TimeoutMin -PollSec $PollSec
  return Complete-ParallelDispatchOutputs -Workers $workers -Completed $completed -TaskHash $taskHash
}
