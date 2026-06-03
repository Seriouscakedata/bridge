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
