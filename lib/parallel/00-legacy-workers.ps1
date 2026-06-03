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
