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
  param([string]$Body)
  $m = [regex]::Match([string]$Body, '^\s*(?:complexity|сложность)\s*:\s*(?<c>simple|moderate|complex)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($m.Success) { return $m.Groups['c'].Value.ToLowerInvariant() }
  return 'moderate'
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

Разрешённые файлы:
$fileText

Подзадача:
$Body
"@
}

function Spawn-Worker {
  param([string]$StreamId, [string]$Coder, [string]$Model, [string]$Body, [string]$Worktree, [string]$BranchName)
  $sid = Normalize-ParallelId $StreamId
  $coderName = ([string]$Coder).ToLowerInvariant()
  if ($coderName -ne 'claude' -and $coderName -ne 'codex') { throw "parallel: unsupported coder '$Coder'" }
  if ([string]::IsNullOrWhiteSpace($Worktree) -or -not (Test-Path -LiteralPath $Worktree)) { throw "parallel: worktree not found for stream $sid" }

  $files = @(Get-ParallelFilesFromBody $Body)
  $jobs = Get-ParallelJobsDir
  $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,8))
  $prefix = Join-Path $jobs ("worker_${sid}_$stamp")
  $inF = "$prefix.in.txt"
  $msgF = "$prefix.msg.txt"
  $outF = "$prefix.out.txt"
  $errF = "$prefix.err.txt"
  $prompt = New-ParallelWorkerPrompt -Body $Body -Files $files -BranchName $BranchName
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $u8)

  $cfg = Get-BridgeConfig
  $proc = $null
  if ($coderName -eq 'codex') {
    $codex = Resolve-CodexExe $cfg
    $effort = if ($Model -match 'complex|xhigh') { 'xhigh' } else { 'high' }
    $reasonArg = "model_reasoning_effort=`"$effort`""
    $proc = Start-Process -FilePath $codex `
      -ArgumentList 'exec','--color','never','--skip-git-repo-check','-c',$reasonArg,'-s','danger-full-access','-C',$Worktree,'-o',$msgF,'-' `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
  } else {
    $claude = Resolve-ClaudeExe $cfg
    $claudeArgs = @('-p','--permission-mode','acceptEdits','--add-dir',$Worktree,'--allowedTools','Read','Grep','Glob','Bash','Edit','MultiEdit','Write')
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $claudeArgs += @('--model', $Model) }
    $proc = Start-Process -FilePath $claude -ArgumentList $claudeArgs `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
  }

  $ticks = [long]0
  try { $ticks = (Get-Process -Id $proc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
  return [pscustomobject]@{
    id        = $sid
    coder     = $coderName
    model     = [string]$Model
    status    = 'running'
    branch    = [string]$BranchName
    worktree  = [System.IO.Path]::GetFullPath($Worktree)
    pid       = $proc.Id
    pidTicks  = $ticks
    process   = $proc
    inFile    = $inF
    msgFile   = $msgF
    outFile   = $outF
    errFile   = $errF
    body      = [string]$Body
    files     = @($files)
    startedAt = (Get-Date).ToString('o')
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
  param($State, [object[]]$Streams)
  if (-not $State) { $State = Read-State }
  if (-not $State) { return }
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
  $State | Add-Member -NotePropertyName parallel_streams -NotePropertyValue @($flat.ToArray()) -Force
  Write-State -State $State
}

function Load-ParallelStreams {
  param($State)
  if (-not $State) { $State = Read-State }
  if (-not $State -or -not ($State.PSObject.Properties.Name -contains 'parallel_streams') -or $null -eq $State.parallel_streams) { return @() }
  return @($State.parallel_streams)
}
