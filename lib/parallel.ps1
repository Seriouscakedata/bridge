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
