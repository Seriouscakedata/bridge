# parallel.ps1 -- run several workers IN PARALLEL, each in its own git worktree of a
# PROJECT repo, then merge each back (conflict-safe). The core of Скачок №1 (команда).
# Refuses to parallelize the bridge's own repo (self-modification must stay serial/safe).
# Dot-sourced from common.ps1.

# Parallel implementation modules. Keep this loader focused on Invoke-ParallelDispatch.
. (Join-Path $PSScriptRoot 'parallel\00-legacy-workers.ps1')
. (Join-Path $PSScriptRoot 'parallel\10-router.ps1')
. (Join-Path $PSScriptRoot 'parallel\20-cli.ps1')
. (Join-Path $PSScriptRoot 'parallel\30-parse-root.ps1')
. (Join-Path $PSScriptRoot 'parallel\40-worker-lifecycle.ps1')
. (Join-Path $PSScriptRoot 'parallel\50-state-fallback.ps1')

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

  # 2026-06-01 VISIBILITY: announce the TEAM PLAN in chat BEFORE spawning, so the operator sees WHAT
  # each parallel stream actually does. The deterministic/batch dispatch had hidden this — the planner
  # discussion was skipped for speed, leaving only aggregate "N streams" + per-worker system lines, so
  # the operator could no longer see the task content. This restores the pre-parallel transparency
  # ("какая задача, кто делает") without giving up the parallel speed-up.
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
  $base0 = Get-ParallelTaskBaseCommit
  $gitC = Get-GitExe
  function Normalize-ParallelRelPath {
    param([string]$Path)
    $p = ([string]$Path).Trim().Trim('"').Trim("'") -replace '\\','/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p = $p.TrimStart('/')
    return $p
  }
  function Test-ParallelChangedPathAllowed {
    param([string]$ChangedPath, [string[]]$AllowedPaths)
    $rel = Normalize-ParallelRelPath -Path $ChangedPath
    if ([string]::IsNullOrWhiteSpace($rel)) { return $false }
    if ($rel -match '(^|/)\.\.($|/)' -or $rel -match '(^|/)\.git($|/)') { return $false }
    foreach ($raw in @($AllowedPaths)) {
      $allow = Normalize-ParallelRelPath -Path ([string]$raw)
      if ([string]::IsNullOrWhiteSpace($allow)) { continue }
      if ($allow -in @('*','any','all')) { return $true }
      $allow = $allow.TrimEnd('/')
      if ($rel.Equals($allow, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
      $leaf = [System.IO.Path]::GetFileName($allow)
      $looksLikeFile = ($leaf -match '\.[A-Za-z0-9]{1,12}$')
      if (-not $looksLikeFile -and $rel.StartsWith($allow + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
  }
  foreach ($w in $workers) {
    if (-not $completed.ContainsKey($w.id)) { continue }
    # 2026-06-01 ERR-004 fix: QUARANTINE failed streams — never collect a failed worker's worktree
    # files into the main repo. Before the ERR-003 CRLF fix, workers were falsely marked 'failed' even
    # though their files were valid, so collecting-regardless was a (lossy) safety net. Now that 003
    # removed the false-failure path, a 'failed' status means a REAL failure (LLM error, empty reply,
    # no FILE blocks, trap) — collecting those is exactly how broken/unverified code (e.g. the
    # inconsistent auth baseline, ERR-005) entered main. Collect only non-failed terminal statuses
    # (done / paused-for-restart); failed streams are skipped and reported for re-dispatch/verify.
    $wst = ''
    try { $wst = [string]$completed[$w.id].status } catch {}
    if ($wst -eq 'failed') {
      $quarantined.Add([string]$w.id)
      try { $completed[$w.id] | Add-Member -NotePropertyName _quarantined -NotePropertyValue $true -Force } catch {}
      continue
    }
    try {
      $wtPath = Get-WorkerWorktree -StreamId $w.id -TaskHash $taskHash
      if (-not (Test-Path -LiteralPath $wtPath)) { continue }
      $changed = New-Object System.Collections.Generic.HashSet[string]
      if (-not [string]::IsNullOrWhiteSpace($base0)) {
        try { @(& $gitC -C $wtPath diff --name-only $base0 2>$null) | Where-Object { $_ } | ForEach-Object { [void]$changed.Add(($_.Trim() -replace '"','')) } } catch {}
      }
      try { @(& $gitC -C $wtPath status --porcelain 2>$null) | Where-Object { $_ } | ForEach-Object { $p = ($_.Substring([Math]::Min(3,$_.Length))).Trim().Trim('"'); if ($p -and $p -notmatch '->') { [void]$changed.Add($p) } } } catch {}
      if ($changed.Count -eq 0) { continue }
      $allowed = @($w.files | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($allowed.Count -gt 0) {
        $outOfScope = @($changed | Where-Object { -not (Test-ParallelChangedPathAllowed -ChangedPath ([string]$_) -AllowedPaths $allowed) })
        if ($outOfScope.Count -gt 0) {
          $quarantined.Add([string]$w.id)
          try { $completed[$w.id] | Add-Member -NotePropertyName _quarantined -NotePropertyValue $true -Force } catch {}
          try {
            Add-Message -From system -Text ("⚠️ Карантин: worker " + [string]$w.id + " изменил файлы вне declared touch-set. Разрешено=[" + ($allowed -join ', ') + "], лишнее=[" + (($outOfScope | Select-Object -First 8) -join ', ') + "]. Stream НЕ собран и НЕ слит в репо.") -Kind event | Out-Null
          } catch {}
          continue
        }
      }
      $copiedHere = 0
      foreach ($rel in $changed) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $src = Join-Path $wtPath $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $bridgeRoot $rel
        $dstDir = Split-Path $dst -Parent
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copiedHere++
      }
      if ($copiedHere -gt 0) {
        $collected += $copiedHere; $collectedStreams++
        try { $completed[$w.id] | Add-Member -NotePropertyName _collected -NotePropertyValue $true -Force } catch {}
      }
    } catch {}
  }
  if ($collected -gt 0) {
    try {
      & $gitC -C $bridgeRoot add -A 2>$null | Out-Null
      & $gitC -C $bridgeRoot commit -m ("parallel collect: " + $collectedStreams + " streams, " + $collected + " files") 2>$null | Out-Null
      $merged += $collectedStreams
      Add-Message -From system -Text ("📦 Collect-commit: собрано " + $collected + " файлов из " + $collectedStreams + " потоков напрямую в репо (надёжный путь, не зависит от git-поведения воркеров)") -Kind event | Out-Null
    } catch {}
  }
  # 2026-06-01 ERR-004: surface quarantined (failed) streams so the operator/driver knows their work
  # was deliberately NOT merged. $quarantinedStreams is also consumed by the terminal-result logic
  # (ERR-006) so a batch with failures is finalized as 'partial' (needs re-dispatch), not silently
  # repeated as a generic "parallel completed".
  $quarantinedStreams = @($quarantined)
  if ($quarantinedStreams.Count -gt 0) {
    try { Add-Message -From system -Text ("⚠️ Карантин: " + $quarantinedStreams.Count + " поток(ов) со статусом failed НЕ собраны в репо (защита от непроверенного/битого кода, ERR-004): " + ($quarantinedStreams -join ', ') + ". Требуется повторный прогон этих потоков.") -Kind event | Out-Null } catch {}
  }

  foreach ($w in $workers) {
    if (-not $completed.ContainsKey($w.id)) { continue }
    $res = $completed[$w.id]
    if (($res.PSObject.Properties.Name -contains '_quarantined') -and $res._quarantined) {
      try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
      continue
    }
    # Already delivered by collect-then-commit above — just clean its worktree and skip branch merge.
    if (($res.PSObject.Properties.Name -contains '_collected') -and $res._collected) {
      try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
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
        $wtPath = Get-WorkerWorktree -StreamId $w.id -TaskHash $taskHash
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
        try { $fbRes = Invoke-TrivialFallbackWorker -Worker $w -TaskHash $taskHash } catch {
          try { Add-Message -From system -Text ("⚠ trivial-fallback exception for stream " + $w.id + ": " + $_.Exception.Message) -Kind event | Out-Null } catch {}
        }
      }
      if ($null -ne $fbRes -and $fbRes.status -eq 'done' -and $fbRes.commits.Count -gt 0) {
        $res = $fbRes
        $completed[$w.id] = $fbRes
      } else {
        try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
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
            Add-Message -From system -Text ("⚠ Поток " + $w.id + " не слит (конфликт не разрешился авто). Дерево очищено — остальные потоки сливаются нормально. Ветка " + $w.branch + " сохранена для ручного разбора.") -Kind event | Out-Null
          }
        }
      }
    } catch {
      try { & git -C $bridgeRoot merge --abort 2>&1 | Out-Null } catch {}
      Add-Message -From system -Text ("❌ Merge exception for stream " + $w.id + " (дерево очищено): " + $_.Exception.Message) -Kind event | Out-Null
    }
    try { Cleanup-WorkerWorktree -StreamId $w.id -TaskHash $taskHash } catch {}
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
  return @{ ok=($merged -ge 1); merged=$merged; quarantined=$qCount; total=$totalStreams; reason='' }
}
