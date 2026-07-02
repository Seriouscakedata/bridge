# Background project-autopilot decompose worker.
#
# Purpose: decompose the NEXT undecomposed project chapter into backlog atoms
# OUT-OF-BAND, in a detached process, so the channel's main driver loop keeps
# claiming and executing already-planned atoms WHILE this planning turn runs.
# This removes the "stop-the-world" gap where a foreground coordinator turn
# monopolizes the single channel slot for ~15 min and nothing executes.
#
# Safety model:
#  - Runs codex in READ-ONLY sandbox: this is a planning turn that only reads the
#    durable plan/backlog and emits a [[PROJECT_BACKLOG]] marker. It writes no
#    repo files, so it cannot race executor worktrees on the filesystem.
#  - Does NOT acquire the serial codex.lock (like lib/parallel.ps1 workers), so it
#    runs concurrently with execution instead of serializing behind it.
#  - Does NOT mutate the channel's live agent state (no Set-AgentPid / Read-State
#    writes), so it cannot confuse the main loop's liveness/watchdog bookkeeping.
#  - Backlog mutation goes through the locked Add-ProjectBacklogFromMarker, the
#    same durable path the foreground driver uses, so the diffusion gate, dedup,
#    and file-ownership repair all still apply.
#
# Flag-gated: the driver only spawns this when projectAutopilot.decomposeAheadLimit
# > 1 (default 1 = off). codex authenticates with its own CLI login, so this
# detached process does NOT depend on inheriting the driver's secrets env.
param(
  [Parameter(Mandatory=$true)][string]$Channel
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logPath  = Join-Path $repoRoot ('jobs\decompose\' + $Channel + '\worker.log')
function Write-WLog {
  param([string]$Message)
  try {
    $dir = Split-Path -Parent $logPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('s') + ' ' + $Message) -Encoding UTF8
  } catch {}
}
function Remove-WorkerLock {
  try {
    $lock = Join-Path (Join-Path (Join-Path $repoRoot 'channels') $Channel) '.decompose-worker.lock'
    if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
  } catch {}
}
function Remove-WorkerTemp {
  # Delete THIS run's prompt/msg/out/err files (problem-hunt defect #6: unbounded jobs\decompose growth +
  # OneDrive sync churn). Script-scoped so it works from any exit path.
  foreach ($f in @($script:inF, $script:msgF, $script:outF, $script:errF)) {
    try { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch {}
  }
}
function Clear-OldWorkerTemp {
  # Backstop retention: prune leftover prompt/msg/out/err files older than 2 days (e.g. from externally
  # killed runs that skipped Remove-WorkerTemp), so the dir cannot grow without bound.
  try {
    $dir = Join-Path (Join-Path $repoRoot 'jobs\decompose') $Channel
    if (Test-Path -LiteralPath $dir) {
      $cut = (Get-Date).AddDays(-2)
      Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -like 'prompt-*' -or $_.Name -like 'msg-*' -or $_.Name -like 'out-*' -or $_.Name -like 'err-*') -and $_.LastWriteTime -lt $cut } |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }
    }
  } catch {}
}

try {
  Write-WLog "START channel=$Channel pid=$PID"
  . (Join-Path $repoRoot 'lib\common.ps1')
} catch {
  Write-WLog ("FATAL bootstrap failed: " + $_.Exception.Message)
  Remove-WorkerLock
  exit 1
}

# Pin this detached process to the target channel so binding/context helpers resolve.
[Environment]::SetEnvironmentVariable('BRIDGE_CHANNEL', $Channel, 'Process')
$env:BRIDGE_CHANNEL = $Channel

try {
  # 1) Resolve the bound project root.
  $projectRoot = ''
  try {
    $binding = Get-ChannelProjectBinding -Slug $Channel
    if ($binding -and [bool](Get-BacklogPackObjectValue -Obj $binding -Name 'ok' -Default $false)) {
      $projectRoot = [string](Get-BacklogPackObjectValue -Obj $binding -Name 'project_root' -Default '')
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($projectRoot) -or -not (Test-Path -LiteralPath $projectRoot)) {
    Write-WLog "ABORT no bound project root for channel=$Channel"
    Remove-WorkerLock
    exit 1
  }

  # 2) Coordinator config (max atoms per batch, diffusion mode).
  $maxTasks = 12
  $diffusionMode = 'off'
  try {
    $paCfg = Get-ProjectAutopilotConfig
    if ([int]$paCfg.maxTasksPerBatch -gt 0) { $maxTasks = [int]$paCfg.maxTasksPerBatch }
    $dm = ([string]$paCfg.diffusionMode).Trim().ToLowerInvariant()
    if ($dm -in @('off','shadow','diffusion')) { $diffusionMode = $dm }
  } catch {}

  # 3) Build the SAME coordinator prompt the foreground path uses. It already
  #    computes the next undecomposed chapter from PROJECT_PLAN.md + the live backlog.
  $prompt = New-ProjectAutopilotCoordinatorTaskText -Slug $Channel -ProjectRoot $projectRoot -MaxTasks $maxTasks -DiffusionMode $diffusionMode
  if ([string]::IsNullOrWhiteSpace($prompt)) {
    Write-WLog "ABORT empty coordinator prompt"
    Remove-WorkerLock
    exit 1
  }

  # 4) Resolve codex + model.
  $cfg = Get-BridgeConfig
  $codex = Resolve-CodexExe $cfg
  if ([string]::IsNullOrWhiteSpace($codex) -or -not (Test-Path -LiteralPath $codex)) {
    Write-WLog "ABORT codex.exe not found"
    Remove-WorkerLock
    exit 1
  }
  $model = [string]$cfg.coderModel
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'gpt-5.5' }
  $effort = 'high'

  # 5) IO files.
  $tmpBase = Join-Path $repoRoot ('jobs\decompose\' + $Channel)
  if (-not (Test-Path -LiteralPath $tmpBase)) { New-Item -ItemType Directory -Force -Path $tmpBase | Out-Null }
  Clear-OldWorkerTemp
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $script:inF  = Join-Path $tmpBase "prompt-$stamp.txt"
  $script:msgF = Join-Path $tmpBase "msg-$stamp.txt"
  $script:outF = Join-Path $tmpBase "out-$stamp.txt"
  $script:errF = Join-Path $tmpBase "err-$stamp.txt"
  $inF = $script:inF; $msgF = $script:msgF; $outF = $script:outF; $errF = $script:errF
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($inF, $prompt, $Utf8NoBom)

  # 6) Launch codex in READ-ONLY sandbox (planning turn: no repo writes).
  $cliArgs = @(
    'exec','--color','never','--skip-git-repo-check',
    '-c', "model=`"$model`"",
    '-c', "model_reasoning_effort=`"$effort`"",
    '-s','read-only',
    '-C',$projectRoot,'-o',$msgF,'-'
  )
  Write-WLog ("LAUNCH codex model=$model effort=$effort root=$projectRoot maxTasks=$maxTasks diffusion=$diffusionMode")
  $proc = Start-Process -FilePath $codex -ArgumentList $cliArgs `
    -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF `
    -NoNewWindow -PassThru

  $timeoutMs = 1500000  # 25 min hard cap
  $exited = $proc.WaitForExit($timeoutMs)
  if (-not $exited) {
    # Tree-kill (defect #3): bare $proc.Kill() can orphan the codex child + its grandchildren. Use
    # taskkill /T /F like lib/parallel.ps1, then fall back to .Kill() if the process still lingers.
    try { Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$proc.Id, '/T', '/F') -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
    Write-WLog "TIMEOUT after ${timeoutMs}ms; tree-killed codex pid=$($proc.Id)"
    Remove-WorkerTemp
    Remove-WorkerLock
    exit 2
  }
  Write-WLog ("codex exited code=" + $proc.ExitCode)

  # 7) Read the agent reply (marker output file, fallback to stdout).
  $reply = ''
  try { if (Test-Path -LiteralPath $msgF) { $reply = [System.IO.File]::ReadAllText($msgF, [System.Text.Encoding]::UTF8) } } catch {}
  if ([string]::IsNullOrWhiteSpace($reply)) {
    try { if (Test-Path -LiteralPath $outF) { $reply = Get-Content -LiteralPath $outF -Raw -Encoding UTF8 } } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($reply)) {
    Write-WLog "ABORT empty codex reply"
    Remove-WorkerTemp
    Remove-WorkerLock
    exit 3
  }

  # 8) Extract [[PROJECT_BACKLOG]] blocks and enqueue atoms via the locked durable path.
  $pattern = '(?is)\[\[PROJECT_BACKLOG\]\](.*?)\[\[/PROJECT_BACKLOG\]\]'
  $created = 0
  $matched = 0
  foreach ($m in [regex]::Matches($reply, $pattern)) {
    $block = [string]$m.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($block)) { continue }
    $matched++
    try {
      $res = Add-ProjectBacklogFromMarker -Block $block -Channel $Channel -Source 'background-coordinator' -MaxTasks $maxTasks
      $created += [int]$res.created
      Write-WLog ("Add-ProjectBacklogFromMarker created=$([int]$res.created) skipped=$([int]$res.skipped) errors=" + ((@($res.errors) | Where-Object { $_ }) -join '; '))
    } catch {
      Write-WLog ("Add-ProjectBacklogFromMarker threw: " + $_.Exception.Message)
    }
  }
  if ($matched -eq 0) { Write-WLog "no PROJECT_BACKLOG marker in reply (coordinator likely judged release complete or emitted an open-question)" }

  if ($created -gt 0) {
    try { Add-Message -From system -Text ("Background planner: pre-decomposed next chapter -- added $created approved atom-task(s) for channel '$Channel' without blocking execution.") -Kind event | Out-Null } catch {}
  }
  Write-WLog "DONE channel=$Channel created=$created"
  Remove-WorkerTemp
  Remove-WorkerLock
  exit 0
} catch {
  Write-WLog ("FATAL " + $_.Exception.Message)
  Remove-WorkerTemp
  Remove-WorkerLock
  exit 1
}
