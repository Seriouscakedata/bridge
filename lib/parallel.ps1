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
    try { $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$runner -WindowStyle Hidden -PassThru; $null = $proc.Handle } catch {}
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
      $proc = Start-Process -FilePath $codex -ArgumentList 'exec','--color','never','--skip-git-repo-check','-c','model_reasoning_effort="xhigh"','-s','danger-full-access','-C',$wt.path,'-o',$msgF,'-' `
        -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
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
  'codex'  = 'Invoke-ParallelCodexCli'
  'claude' = 'Invoke-ParallelClaudeCli'
  # 'gemini'   = 'Invoke-ParallelGeminiCli'    # future
  # 'deepseek' = 'Invoke-ParallelDeepSeekCli'  # future
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
    $woOpus = @($candidates | Where-Object { -not (([string]$_.cli -eq 'claude') -and ([string]$_.model -eq 'opus')) })
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
  $pick = $candidates | Sort-Object @{Expression={[int]$_.cost}; Descending=$false}, @{Expression={[int]$_.speed}; Descending=$true} | Select-Object -First 1
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
  $cliArgs = @(
    'exec','--color','never','--skip-git-repo-check',
    '-c', "model=`"$model`"",
    '-c', "model_reasoning_effort=`"$effort`"",
    '-s','danger-full-access','-C',$Worktree,'-o',$MsgFile,'-'
  )
  return Start-Process -FilePath $codex -ArgumentList $cliArgs `
    -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
    -NoNewWindow -PassThru
}

function Invoke-ParallelClaudeCli {
  # Launch claude.exe with --model and --cwd $Worktree.
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $cfg = Get-BridgeConfig
  $claude = Resolve-ClaudeExe $cfg
  $model = [string]$Worker.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'sonnet' }
  $cliArgs = @(
    '-p','--permission-mode','acceptEdits',
    '--cwd', $Worktree,
    '--allowedTools','Read','Grep','Glob','Bash','Edit','MultiEdit','Write',
    '--model', $model
  )
  return Start-Process -FilePath $claude -ArgumentList $cliArgs `
    -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
    -NoNewWindow -PassThru
}

# To add Gemini/DeepSeek/etc: implement Invoke-ParallelXxxCli with the same
# signature (returns System.Diagnostics.Process), then add to
# $Script:ParallelCliRegistry above and add worker entries to config.json.

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

function Get-ParallelTaskBaseCommit {
  $ErrorActionPreference = 'Continue'
  $base = ''
  try {
    $st = Read-State
    if ($st -and ($st.PSObject.Properties.Name -contains 'task_base_commit')) { $base = [string]$st.task_base_commit }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($base)) {
    try { $base = ((& git -C (Get-BridgeRoot) rev-parse HEAD 2>$null) | Select-Object -First 1) } catch {}
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

  $branchExists = $false
  try {
    & $git -C (Get-BridgeRoot) show-ref --verify --quiet "refs/heads/$branch"
    $branchExists = ($LASTEXITCODE -eq 0)
  } catch { $branchExists = $false }

  if ($branchExists) {
    & $git -C (Get-BridgeRoot) worktree add $path $branch 2>&1 | Out-Null
  } else {
    & $git -C (Get-BridgeRoot) worktree add -b $branch $path $base 2>&1 | Out-Null
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
  try { & $git -C (Get-BridgeRoot) worktree remove --force $path 2>&1 | Out-Null } catch {}
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
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
- Финальная строка должна быть STATUS: DONE, STATUS: FAILED или STATUS: PARTIAL.
- ЗАПРЕЩЕНО создавать файл control/restart.flag (ни в своём worktree, ни в основном репо по любому пути). Это убивает соседние параллельные потоки. Драйвер решит про restart сам после merge.
- ЗАПРЕЩЕНО менять файлы вне своего worktree (даже если путь технически доступен).

Разрешённые файлы:
$fileText

Подзадача:
$Body
"@
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
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $u8)

  # Dispatch to the CLI-specific handler
  $proc = & $handler -Worker $WorkerSpec -Worktree $Worktree -InFile $inF -MsgFile $msgF -OutFile $outF -ErrFile $errF
  if (-not $proc) { throw "parallel: CLI handler '$handler' returned no process for worker $($WorkerSpec.id)" }

  $ticks = [long]0
  try { $ticks = (Get-Process -Id $proc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
  return [pscustomobject]@{
    id         = $sid
    coder      = $cli                       # back-compat field (= CLI)
    cli        = $cli
    workerId   = [string]$WorkerSpec.id
    model      = [string]$WorkerSpec.model
    reasoning  = [string]$WorkerSpec.reasoning
    status     = 'running'
    branch     = [string]$BranchName
    worktree   = [System.IO.Path]::GetFullPath($Worktree)
    pid        = $proc.Id
    pidTicks   = $ticks
    process    = $proc
    inFile     = $inF
    msgFile    = $msgF
    outFile    = $outF
    errFile    = $errF
    body       = [string]$Body
    files      = @($files)
    startedAt  = (Get-Date).ToString('o')
  }
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
    return @(& git -C (Get-BridgeRoot) rev-list --reverse $range 2>$null | ForEach-Object { [string]$_ })
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
  $m = [regex]::Match($reply, '^\s*STATUS:\s*(?<s>[A-Z][A-Z0-9_-]*)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($m.Success) {
    $s = $m.Groups['s'].Value.ToUpperInvariant()
    if ($s -eq 'DONE') { $status = 'done' }
    elseif ($s -eq 'PARTIAL') { $status = 'paused-for-restart' }
    elseif ($s -eq 'CONTINUE' -or $s -eq 'CONTINUE-CHUNK') { $status = 'done' }
    else { $status = 'failed' }
  }
  return [pscustomobject]@{ status=$status; reply=$reply; commits=@(Get-WorkerCommits $Worker); error='' }
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

  # Stable task hash from current_task text so worktree paths are reproducible across
  # restarts (resume-safe).
  $taskHash = 'task'
  try {
    $st = Read-State
    $taskText = if ($st -and $st.current_task) { [string]$st.current_task } else { 'task' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($taskText)
    $hash = $sha.ComputeHash($bytes)
    $taskHash = (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0,12)
  } catch {}

  # 2026-05-27 refactor: route each stream through Select-WorkerForStream
  # (strength-floor + domain affinity + no double-booking). Falls back to
  # built-in default pool if config.parallel.workers is missing.
  $workers = New-Object 'System.Collections.Generic.List[object]'
  $usedIds = New-Object 'System.Collections.Generic.List[string]'
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
      foreach ($w0 in $workers) {
        try { if ($w0.process -and -not $w0.process.HasExited) { Start-Process taskkill -ArgumentList '/PID',([string]$w0.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue } } catch {}
        try { Cleanup-WorkerWorktree -StreamId $w0.id -TaskHash $taskHash } catch {}
      }
      return @{ ok=$false; merged=0; reason='no worker pool' }
    }

    $branch = "wip/parallel/$taskHash/$($s.id)"
    try {
      $worktree = Get-WorkerWorktree -StreamId $s.id -TaskHash $taskHash
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
      foreach ($w0 in $workers) {
        try { if ($w0.process -and -not $w0.process.HasExited) { Start-Process taskkill -ArgumentList '/PID',([string]$w0.pid),'/F','/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue } } catch {}
        try { Cleanup-WorkerWorktree -StreamId $w0.id -TaskHash $taskHash } catch {}
      }
      return @{ ok=$false; merged=0; reason="spawn failed: $($_.Exception.Message)" }
    }
  }

  # Persist to state (channel-aware via current Read-State)
  try { Save-ParallelStreams -State (Read-State) -Streams $workers } catch {}

  # Poll until all done or timeout
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
    foreach ($w in $workers) {
      if ($completed.ContainsKey($w.id)) { continue }
      $res = Get-WorkerResult $w
      if ($res.status -ne 'running') {
        $completed[$w.id] = $res
        try { Add-Message -From system -Text ("🔀 Worker " + $w.id + " (" + $w.coder + ") finished: status=" + $res.status + ", commits=" + $res.commits.Count) -Kind event } catch {}
      }
    }
  }

  # Merge phase: fast-forward each wip-branch into HEAD on main worktree
  $merged = 0
  $bridgeRoot = Get-BridgeRoot
  foreach ($w in $workers) {
    if (-not $completed.ContainsKey($w.id)) { continue }
    $res = $completed[$w.id]
    if ($res.status -ne 'done' -or $res.commits.Count -eq 0) {
      try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
      continue
    }
    try {
      # ff-only merge
      $mergeOut = & git -C $bridgeRoot merge --ff-only $w.branch 2>&1
      if ($LASTEXITCODE -eq 0) {
        $merged++
        Add-Message -From system -Text ("✅ Merged stream " + $w.id + " (" + $res.commits.Count + " commits, branch " + $w.branch + ")") -Kind event | Out-Null
      } else {
        # Fallback: non-ff merge with no-edit message
        $mergeOut2 = & git -C $bridgeRoot merge --no-ff -m ("merge parallel stream " + $w.id) $w.branch 2>&1
        if ($LASTEXITCODE -eq 0) {
          $merged++
          Add-Message -From system -Text ("✅ Merged stream " + $w.id + " (non-ff fallback)") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("❌ Merge failed for stream " + $w.id + ": " + ($mergeOut2 -join '; ')) -Kind event | Out-Null
        }
      }
    } catch {
      Add-Message -From system -Text ("❌ Merge exception for stream " + $w.id + ": " + $_.Exception.Message) -Kind event | Out-Null
    }
    try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
  }

  # Clear parallel_streams from state -- via Update-State (Add-Member preserves other fields)
  try {
    Update-State { param($s) $s | Add-Member -NotePropertyName parallel_streams -NotePropertyValue @() -Force } | Out-Null
  } catch {}

  return @{ ok=($merged -ge 1); merged=$merged; reason='' }
}
