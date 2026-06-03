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
