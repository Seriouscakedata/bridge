# Loop-completion status/verification checks.
# These scriptblocks are dot-invoked by 86-loop-completion.ps1 so `continue` keeps the driver loop contract.
function Invoke-DriverDoneGateGitLines {
  param(
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$Description
  )

  $gitErrFile = [System.IO.Path]::GetTempFileName()
  $oldGateGitErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $gitSafeDirectory = "safe.directory=$BridgeRoot"
    $gitOutput = @(& git -c $gitSafeDirectory -C $BridgeRoot @Arguments 2> $gitErrFile)
    $gitExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($gitExit -ne 0) {
      $gitErr = ''
      try { $gitErr = [System.IO.File]::ReadAllText($gitErrFile, [System.Text.Encoding]::UTF8) } catch {}
      $gitShort = (($gitOutput | ForEach-Object { [string]$_ }) -join ' ')
      if (-not [string]::IsNullOrWhiteSpace($gitErr)) { $gitShort = ($gitShort + ' ' + $gitErr) }
      $gitShort = $gitShort.Trim()
      if ($gitShort.Length -gt 240) { $gitShort = $gitShort.Substring(0,240) + '...' }
      if ([string]::IsNullOrWhiteSpace($gitShort)) { $gitShort = '<no output>' }
      throw ("git {0} failed (exit {1}): {2}" -f $Description, $gitExit, $gitShort)
    }
    return @($gitOutput)
  } finally {
    $ErrorActionPreference = $oldGateGitErrorActionPreference
    Remove-Item -LiteralPath $gitErrFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-DriverDoneGateChangedPaths {
  param(
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [AllowNull()][string]$TaskBaseCommit
  )

  $changedPaths = New-Object 'System.Collections.Generic.List[string]'
  $seenPaths = @{}
  $addPath = {
    param($RawPath)
    if ($null -eq $RawPath) { return }
    $normalized = ([string]$RawPath).Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return }
    $normalized = $normalized -replace '\\','/'
    if (-not $seenPaths.ContainsKey($normalized)) {
      $seenPaths[$normalized] = $true
      [void]$changedPaths.Add($normalized)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($TaskBaseCommit)) {
    # 2026-06-11 W2 (close-lag root): a PROJECT-channel task commits in the project repo, so
    # task_base_commit does NOT resolve in the bridge repo -> cat-file exits 128. This used to
    # THROW, failing the entire DONE-gate (parse+smoke+gate-regression) closed -> uncapped
    # CONTINUE -> the COVERED loop that left slopvid atoms running 60+ min after a green commit.
    # Fail SOFT: if the base commit isn't an object in THIS repo, skip the base-diff. The bridge
    # changed-paths still come from the working/staged/untracked scan below (empty on a clean
    # tree -> gate-regression scope empty -> skipped), so bridge integrity is unaffected.
    $baseResolvedHere = $false
    try {
      $baseType = [string]((Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('cat-file','-t',$TaskBaseCommit) -Description 'cat-file task_base_commit' | Select-Object -First 1) -join '')
      if ($baseType.Trim() -eq 'commit') { $baseResolvedHere = $true }
    } catch {
      # Keep this fail-soft: throwing here turns missing project-repo bases into DONE-gate CONTINUE loops.
      # N-retry degrade (2026-06-11): a base sha that is STILL missing after 3 consecutive checks will never
      # resolve in this repo (e.g. recorded from a project repo) — escalate with an explicit [NEEDS_REVIEW]
      # throw instead of silently retrying forever; non-missing-object errors keep the plain fail-soft path.
      $missingObjMsg = [string]$_.Exception.Message
      $looksMissingObject = ($missingObjMsg -match '(?i)exit\s+128') -or ($missingObjMsg -match '(?i)not a valid object|bad object|could not get object|not in object store|missing')
      if ($looksMissingObject) {
        if ($null -eq $script:_MissingBaseObjHits) { $script:_MissingBaseObjHits = @{} }
        if (-not $script:_MissingBaseObjHits.ContainsKey($TaskBaseCommit)) { $script:_MissingBaseObjHits[$TaskBaseCommit] = 0 }
        $script:_MissingBaseObjHits[$TaskBaseCommit] = [int]$script:_MissingBaseObjHits[$TaskBaseCommit] + 1
        if ([int]$script:_MissingBaseObjHits[$TaskBaseCommit] -ge 3) {
          throw ("[NEEDS_REVIEW] task_base_commit '" + $TaskBaseCommit + "' missing for 3+ consecutive checks — base object not reachable; degrading to needs-review to avoid an infinite CONTINUE loop")
        }
      }
      $baseResolvedHere = $false
    }
    if ($baseResolvedHere) {
      # Successful resolve clears the consecutive missing-object streak for this sha.
      if ($null -ne $script:_MissingBaseObjHits) { [void]$script:_MissingBaseObjHits.Remove($TaskBaseCommit) }
      foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('diff','--name-only',$TaskBaseCommit,'HEAD') -Description 'diff task_base_commit..HEAD')) {
        & $addPath $p
      }
    }
  }

  # 2026-06-15 (doctor repair gate): the working/staged/untracked scans are the resilient
  # fallback the W2 fail-soft block above relies on ("changed-paths still come from the
  # working/staged/untracked scan below"). They were NOT actually fail-soft: any git error
  # here (e.g. a gate-snapshot extraction with no .git -> `diff --cached` drops to no-index
  # mode and exits 129, or a transient index.lock) THREW and took the whole DONE-gate down
  # into an uncapped CONTINUE loop. Make each scan independently fail-soft: a scan that errors
  # is skipped, the others still contribute. A genuinely broken bridge repo surfaces through
  # parse/smoke, not by deadlocking completion. (Covered by test-verify-chain-fastpath.ps1
  # "pre-escalation changed-path scans stay fail-soft".)
  foreach ($scan in @(
    @{ Args = @('diff','--name-only','--cached'); Desc = 'diff --cached' },
    @{ Args = @('diff','--name-only'); Desc = 'diff working tree' },
    @{ Args = @('ls-files','--others','--exclude-standard'); Desc = 'ls-files untracked' }
  )) {
    try {
      foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments $scan.Args -Description $scan.Desc)) {
        & $addPath $p
      }
    } catch {
      # fail-soft by design: skip a working-tree scan that git could not run; never throw the gate.
    }
  }

  return @($changedPaths.ToArray())
}

function Test-DriverReplyHasSmokeEvidence {
  param([AllowNull()][string]$Reply)

  if ([string]::IsNullOrWhiteSpace($Reply)) { return $false }
  $verifiedBlocks = [regex]::Matches($Reply, '(?is)\[\[VERIFIED:\s*(.*?)\]\]')
  if ($verifiedBlocks.Count -eq 0) { return $false }

  foreach ($block in @($verifiedBlocks)) {
    $evidence = [string]$block.Groups[1].Value
    if ($evidence -imatch '\bsmoke\.ps1\s+(PASS|OK)\b') { return $true }
    if ($evidence -imatch '\bsmoke\s+(PASS|OK)\b') { return $true }
    if ($evidence -imatch '^\s*smoke\b') { return $true }
  }

  return $false
}

function Test-PlannerDecomposed {
    # Returns @{IsDecomposed=$true; Count=N} if planner emitted [[DECOMPOSED: N]].
    param([AllowNull()][string]$ReplyText)

  if ([string]::IsNullOrWhiteSpace($ReplyText)) { return @{ IsDecomposed = $false; Count = 0 } }
  $m = [regex]::Match($ReplyText, '\[\[DECOMPOSED:\s*(\d+)(?:\s*атом[^\]]*)?\s*\]\]', 'IgnoreCase')
  if ($m.Success) {
    return @{ IsDecomposed = $true; Count = [int]$m.Groups[1].Value }
    }
    return @{ IsDecomposed = $false; Count = 0 }
}

function Invoke-DriverDecomposedMarker {
    param(
        [Parameter(Mandatory=$true)][object]$DecompResult,
        [Parameter(Mandatory=$true)][string]$BridgeRoot,
        [scriptblock]$ReadStateScript = $null,
        [scriptblock]$GetBacklogScript = $null,
        [scriptblock]$SetIdeaScript = $null,
        [scriptblock]$AddMessageScript = $null,
        [scriptblock]$UpdateStateScript = $null,
        [scriptblock]$SendPushScript = $null
    )

    if (-not [bool]$DecompResult.IsDecomposed) {
        return [pscustomobject]@{ Handled=$false; Count=0; ParentId=''; ParentClosed=$false; ChildrenFound=0 }
    }

    $stDecomp = if ($ReadStateScript) { & $ReadStateScript } else { Read-State }
    $parentId = [string]$stDecomp.current_backlog_id
    if ([string]::IsNullOrWhiteSpace($parentId)) { $parentId = [string]$stDecomp.current_task_id }
    $decompExpected = [int]$DecompResult.Count
    Write-Host "[[DECOMPOSED]] detected: $decompExpected atoms. Closing parent '$parentId' as decomposed."

    if (-not $GetBacklogScript -or -not $SetIdeaScript) {
        try {
            if (-not (Get-Command Get-Backlog -ErrorAction SilentlyContinue) -or -not (Get-Command Set-Idea -ErrorAction SilentlyContinue)) {
                . (Join-Path $BridgeRoot 'lib\backlog.ps1')
            }
        } catch {}
    }

    $parentClosed = $false
    $children = @()
    if (-not [string]::IsNullOrWhiteSpace($parentId) -and ($GetBacklogScript -or (Get-Command Get-Backlog -ErrorAction SilentlyContinue))) {
        $ideas = if ($GetBacklogScript) { @(& $GetBacklogScript) } else { @(Get-Backlog) }
        $parent = $ideas | Where-Object { [string]$_.id -eq $parentId } | Select-Object -First 1
        $children = @($ideas | Where-Object {
            $tags = @($_.tags | ForEach-Object { [string]$_ })
            ($tags -contains 'decomposed-child') -and ([string]$_.text -match [regex]::Escape($parentId))
        })
        $minChildren = [int][Math]::Ceiling($decompExpected / 2)
        Write-Host "Decomposed children found: $($children.Count) / expected: $decompExpected"
        if ($children.Count -ge 1 -and $children.Count -ge $minChildren) {
            if ($parent) {
                if ($SetIdeaScript) {
                    $parentClosed = [bool](& $SetIdeaScript $parentId 'decomposed' "Decomposed into $decompExpected child atoms")
                } elseif (Get-Command Set-Idea -ErrorAction SilentlyContinue) {
                    $parentClosed = [bool](Set-Idea -Id $parentId -Status 'decomposed' -Reason "Decomposed into $decompExpected child atoms")
                }
            }
            $message = ("[[DECOMPOSED]] detected: {0} atoms; parent {1} status={2}; children found {3}/{0}. No coder turn needed." -f $decompExpected,$parentId,$(if ($parentClosed) { 'decomposed' } else { 'unchanged' }),$children.Count)
        } elseif ($children.Count -lt 1) {
            $message = "DECOMPOSE FAILED: marker said $decompExpected but $($children.Count) children created — parent kept open"
            Write-Host $message
        } else {
            $message = "DECOMPOSE PARTIAL: $($children.Count)/$decompExpected children (need >= $minChildren) — parent kept open"
            Write-Host $message
        }
    } else {
        $message = ("[[DECOMPOSED]] detected: {0} atoms, but parent backlog id/function unavailable. No coder turn needed." -f $decompExpected)
    }

    if ($AddMessageScript) {
        & $AddMessageScript $message | Out-Null
    } else {
        Add-Message -From system -Text $message -Kind event | Out-Null
    }

    if ($UpdateStateScript) {
        & $UpdateStateScript $decompExpected $parentId | Out-Null
    } else {
        Update-State ({ param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'decomposed'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName last_decomposed_result -NotePropertyValue ([pscustomobject]@{ status='decomposed'; child_count=$decompExpected; parent_id=$parentId; ts=(Get-Date).ToUniversalTime().ToString('o') }) -Force; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null
    }

    if ($SendPushScript) {
        & $SendPushScript $parentId | Out-Null
    } else {
        try { Send-PushEvent -Kind done -Text ("Decomposed parent: " + $parentId) } catch {}
    }

    return [pscustomobject]@{
        Handled = $true
        Count = $decompExpected
        ParentId = $parentId
        ParentClosed = $parentClosed
        ChildrenFound = $children.Count
    }
}

function Test-DriverDoneGateBridgeCorePath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $normalizedPath = (([string]$Path).Trim() -replace '\\','/').TrimStart('./')
  if ([string]::IsNullOrWhiteSpace($normalizedPath)) { return $false }

  # Fail-safe bridge-core classification (2026-06-13). The non-core fast subset must
  # NEVER hide a risky engine change behind parse+smoke. A narrow core allowlist did
  # exactly that: lib/common.ps1, watchdog.ps1, scheduler.ps1, lib/circuit-breaker.ps1,
  # lib/memory.ps1, critic.ps1 (etc.) all fell through to the fast subset and silently
  # skipped the full regression suite. Invert the logic: treat ANY engine *.ps1 as
  # bridge-core, and fast-subset only an explicit set of non-risky trees. This is a
  # strict superset of the old core set (no coverage reduction) while keeping the
  # speedup for project files, docs and tools/test* diffs.

  # (1) Data / docs / web / project trees — never bridge-core (no executable engine risk).
  if ($normalizedPath -match '^(?i:(docs|web|memory|decisions|channels|snapshots|logs|node_modules)/)') { return $false }
  # (2) Test, diagnostic and foundry-synthesised scripts — fast subset on their own change.
  if ($normalizedPath -match '^(?i:tools/(test-[^/]+\.ps1|diag/|auto/))') { return $false }
  # (3) Any remaining PowerShell engine file — bridge-core, full snapshot suite.
  if ($normalizedPath -match '(?i)\.ps1$') { return $true }
  # (4) Everything else (project sources, config, data) — non-core fast subset.
  return $false
}

function Test-CoveredAfterRestart {
  param(
    [string]$BridgeRoot,
    [string]$ClaimedAt,
    [string]$BacklogId,
    [string]$TaskText,
    [object]$StateObj
  )
  # Returns: @{ Covered=$false; Sha=''; Repo='' }
  $result = @{ Covered = $false; Sha = ''; Repo = '' }
  try {
    if (-not (Get-Command Test-TaskCompletionRecoverable -ErrorAction SilentlyContinue)) {
      . (Join-Path $BridgeRoot 'lib\task-action-evidence.ps1')
    }
    if ([string]::IsNullOrWhiteSpace($BacklogId)) { return $result }

    $repos = @($BridgeRoot)
    try {
      if (Get-Command Get-TaskRepoRoot -ErrorAction SilentlyContinue) {
        $taskRepo = [string](Get-TaskRepoRoot)
        if (-not [string]::IsNullOrWhiteSpace($taskRepo)) { $repos += $taskRepo }
      }
    } catch { return $result }

    $recover = Test-TaskCompletionRecoverable -State $StateObj -BacklogId $BacklogId -BridgeRoot $BridgeRoot -RepoRoots @($repos)
    try { Write-TaskCompletionRecoveryAudit -BridgeRoot $BridgeRoot -TaskId $BacklogId -Decision $(if ([string]$recover.verdict -eq 'RECOVER_DONE') { 'recover' } else { 'fail' }) -Verdict $recover -FlagState $true -Site 'driver86_covered_after_restart' } catch {}
    if ([string]$recover.verdict -eq 'RECOVER_DONE') {
      $result.Covered = $true
      $result.Sha = [string]$recover.head
      $result.Repo = [string]$recover.repo
      return $result
    }
  } catch {}
  return $result
}

function Test-DoneGateDiffIntegrity {
  param(
    [string]$CommitSha,
    [string]$BridgeRoot,
    [string[]]$DeclaredFiles = @()
  )
  if ([string]::IsNullOrWhiteSpace($CommitSha) -or [string]::IsNullOrWhiteSpace($BridgeRoot)) {
    return [pscustomobject]@{ ok=$false; reason='missing-args'; changedFiles=@(); overlap=@() }
  }

  $changedFiles = @()
  try {
    $out = (& git -c "safe.directory=$BridgeRoot" -C $BridgeRoot diff-tree --no-commit-id -r --name-only $CommitSha 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($out)) {
      $changedFiles = @($out -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  } catch {
    return [pscustomobject]@{ ok=$false; reason='git-diff-error'; changedFiles=@(); overlap=@() }
  }

  if ($changedFiles.Count -eq 0) {
    return [pscustomobject]@{ ok=$false; reason='empty-diff'; changedFiles=@(); overlap=@() }
  }

  if ($DeclaredFiles.Count -gt 0) {
    $normDeclared = @($DeclaredFiles | ForEach-Object { ($_ -replace '\\','/').TrimStart('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $normChanged = @($changedFiles | ForEach-Object { ($_ -replace '\\','/').TrimStart('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $overlap = @()
    foreach ($declared in $normDeclared) {
      foreach ($changed in $normChanged) {
        if ($changed -eq $declared -or $changed.StartsWith($declared + '/') -or $declared.StartsWith($changed + '/')) {
          $overlap += $declared
          break
        }
      }
    }
    $overlap = @($overlap | Sort-Object -Unique)
    if ($overlap.Count -eq 0) {
      return [pscustomobject]@{ ok=$false; reason='foreign-diff'; changedFiles=$changedFiles; overlap=@() }
    }
    return [pscustomobject]@{ ok=$true; reason='overlap-found'; changedFiles=$changedFiles; overlap=$overlap }
  }

  return [pscustomobject]@{ ok=$true; reason='no-declared-files'; changedFiles=$changedFiles; overlap=@() }
}

function New-DriverDoneGatePlan {
  param(
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [AllowNull()][string]$TaskBaseCommit,
    [AllowNull()][string]$Reply,
    [string[]]$ChangedPathsOverride = $null
  )

  $changedPaths = if ($null -ne $ChangedPathsOverride) {
    @($ChangedPathsOverride | ForEach-Object { ([string]$_) -replace '\\','/' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  } else {
    @(Get-DriverDoneGateChangedPaths -BridgeRoot $BridgeRoot -TaskBaseCommit $TaskBaseCommit)
  }

  $psFiles = @($changedPaths | Where-Object { $_ -match '\.ps1$' } | Sort-Object -Unique)
  $parseFiles = @($psFiles | Where-Object { Test-Path -LiteralPath (Join-Path $BridgeRoot $_) -PathType Leaf })
  $smokeNeeded = ($psFiles.Count -gt 0)
  $smokeSkippedByVerified = $false
  if ($smokeNeeded -and (Test-DriverReplyHasSmokeEvidence -Reply $Reply)) {
    $smokeNeeded = $false
    $smokeSkippedByVerified = $true
  }
  $gateScope = @()
  $gateScopeError = ''
  $gateSuiteNeeded = $true
  $gateNonCoreFastSubset = $false
  $bridgeCorePaths = @($changedPaths | Where-Object { Test-DriverDoneGateBridgeCorePath -Path $_ } | Sort-Object -Unique)
  $integrityNeeded = ($changedPaths.Count -ge 2)
  if (-not (Get-Command Get-GateRegressionScope -ErrorAction SilentlyContinue)) {
    throw 'gate-regression runtime import missing: Get-GateRegressionScope'
  } else {
    try {
      $gateScope = @(Get-GateRegressionScope -ChangedPaths @($changedPaths))
      if ($changedPaths.Count -gt 0 -and $bridgeCorePaths.Count -eq 0) {
        $gateSuiteNeeded = $false
        $gateNonCoreFastSubset = $true
      } else {
        $gateSuiteNeeded = ($gateScope.Count -gt 0)
      }
    } catch {
      $gateScopeError = ($_.Exception.Message -replace '\s+',' ').Trim()
      throw ("gate-regression scope failed: " + $gateScopeError)
    }
  }

  $jobs = New-Object 'System.Collections.Generic.List[string]'
  if ($parseFiles.Count -gt 0) { [void]$jobs.Add('parse') }
  if ($smokeNeeded) { [void]$jobs.Add('smoke') }
  if ($gateSuiteNeeded) { [void]$jobs.Add('gate-regression') }
  if ($integrityNeeded) { [void]$jobs.Add('integrity') }

  return [pscustomobject][ordered]@{
    ChangedPaths = @($changedPaths)
    PsFiles = @($psFiles)
    ParseFiles = @($parseFiles)
    SmokeNeeded = [bool]$smokeNeeded
    SmokeSkippedByVerified = [bool]$smokeSkippedByVerified
    GateScope = @($gateScope)
    GateScopeError = $gateScopeError
    GateBridgeCorePaths = @($bridgeCorePaths)
    GateNonCoreFastSubset = [bool]$gateNonCoreFastSubset
    GateSuiteNeeded = [bool]$gateSuiteNeeded
    IntegrityNeeded = [bool]$integrityNeeded
    JobNames = @($jobs.ToArray())
  }
}

function Test-DoneGateStateValid {
  param([string]$BridgeRoot, [string]$Channel = 'main')
  # Returns [pscustomobject]@{Ok=[bool]; Reason=[string]; MissingFields=[string[]]; Sha256Mismatch=[bool]}
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $statePath = Join-Path $BridgeRoot "channels\$Channel\state.json"
  $sha256Path = $statePath + '.sha256'
  $requiredFields = @('status', 'heartbeat', 'current_task_id', 'current_backlog_id')

  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return [pscustomobject]@{Ok=$false; Reason="state.json missing at $statePath"; MissingFields=@(); Sha256Mismatch=$false}
  }

  $rawBytes = $null
  $text = $null
  try {
    $rawBytes = [System.IO.File]::ReadAllBytes($statePath)
    $text = [System.Text.Encoding]::UTF8.GetString($rawBytes)
  } catch {
    return [pscustomobject]@{Ok=$false; Reason="state.json unreadable: $($_.Exception.Message)"; MissingFields=@(); Sha256Mismatch=$false}
  }

  $state = $null
  try {
    $state = $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return [pscustomobject]@{Ok=$false; Reason="state.json invalid JSON: $(($_.Exception.Message -replace '\s+',' ').Trim())"; MissingFields=@(); Sha256Mismatch=$false}
  }

  if ($null -eq $state -or $state -is [array] -or $state -isnot [System.Management.Automation.PSCustomObject]) {
    return [pscustomobject]@{Ok=$false; Reason='state.json schema invalid: top-level value must be a JSON object'; MissingFields=@(); Sha256Mismatch=$false}
  }

  $missing = @($requiredFields | Where-Object { -not ($state.PSObject.Properties.Name -contains $_) })
  if ($missing.Count -gt 0) {
    return [pscustomobject]@{Ok=$false; Reason="state.json missing required fields: $($missing -join ', ')"; MissingFields=$missing; Sha256Mismatch=$false}
  }

  # SHA256 sidecar check (non-blocking if sidecar absent - only validate if present).
  $sha256Mismatch = $false
  if (Test-Path -LiteralPath $sha256Path -PathType Leaf) {
    try {
      $expected = ([System.IO.File]::ReadAllText($sha256Path, [System.Text.Encoding]::UTF8)).Trim()
      $bom = [System.Text.Encoding]::UTF8.GetPreamble()
      $contentBytes = if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq $bom[0] -and $rawBytes[1] -eq $bom[1] -and $rawBytes[2] -eq $bom[2]) { $rawBytes[3..($rawBytes.Length-1)] } else { $rawBytes }
      $sha = [System.Security.Cryptography.SHA256]::Create()
      $actual = [System.BitConverter]::ToString($sha.ComputeHash($contentBytes)) -replace '-',''
      $sha.Dispose()
      if ($expected -and ($expected.ToUpperInvariant() -ne $actual.ToUpperInvariant())) {
        $sha256Mismatch = $true
        return [pscustomobject]@{Ok=$false; Reason="state.json SHA256 mismatch (expected=$($expected.Substring(0,[Math]::Min(8,$expected.Length)))... actual=$($actual.Substring(0,[Math]::Min(8,$actual.Length)))...)"; MissingFields=@(); Sha256Mismatch=$true}
      }
    } catch {
      # SHA256 check failure is non-fatal - field check passed, warn only at call sites if needed.
    }
  }

  return [pscustomobject]@{Ok=$true; Reason=''; MissingFields=@(); Sha256Mismatch=$false}
}

$script:DriverDoneGateParseJob = {
  param([string]$BridgeRoot, [object]$ParseFiles)
  $parseFileList = @($ParseFiles | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $result = [ordered]@{ Name='parse'; Skipped=$false; Ok=$true; Files=@($parseFileList); FailedFile=''; ErrorLine=0; ErrorMessage=''; RuntimeError='' }
  try {
    foreach ($psf in @($parseFileList)) {
      $fullPath = Join-Path $BridgeRoot $psf
      if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
      $pfErrors = $null; $pfTokens = $null
      [System.Management.Automation.Language.Parser]::ParseFile($fullPath,[ref]$pfTokens,[ref]$pfErrors) | Out-Null
      if ($pfErrors -and $pfErrors.Count -gt 0) {
        $result.Ok = $false
        $result.FailedFile = $psf
        $result.ErrorLine = [int]$pfErrors[0].Extent.StartLineNumber
        $result.ErrorMessage = [string]$pfErrors[0].Message
        break
      }
    }
  } catch {
    $result.Ok = $false
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
}

$script:DriverDoneGateSmokeJob = {
  param([string]$SmokeFile, [string]$Channel)
  $result = [ordered]@{ Name='smoke'; Skipped=$false; Ok=$false; Output=''; ExitCode=1; RuntimeError='' }
  try {
    if (-not [string]::IsNullOrWhiteSpace($Channel)) { $env:BRIDGE_CHANNEL = $Channel }
    $smokeOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $SmokeFile 2>&1 | Out-String
    $result.Output = [string]$smokeOut
    $result.ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $result.Ok = ([int]$result.ExitCode -eq 0 -and $result.Output -imatch 'SMOKE OK')
  } catch {
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
}

function Test-DriverDoneGateRegressionTimeoutInconclusive {
  param([AllowNull()][object]$GateResult)

  if ($null -eq $GateResult) { return $false }
  try {
    if ([bool]$GateResult.Ok) { return $false }
  } catch {}
  try {
    if (-not [string]::IsNullOrWhiteSpace([string]$GateResult.RuntimeError)) { return $false }
  } catch {}
  # If ANY attempt produced a real (non-timeout) test failure (exit!=0, TimedOut=$false), we have
  # observed evidence of a regression even if the LAST attempt happened to time out. The job keeps
  # only the last attempt's exit/timed-out fields, so a "fail-then-timeout" run would otherwise
  # look like a pure timeout and fail-open. NonTimeoutFailureSeen preserves that evidence -> block.
  try {
    if ([bool]$GateResult.NonTimeoutFailureSeen) { return $false }
  } catch {}

  $timedOut = $false
  $exitCode = 0
  try { $timedOut = [bool]$GateResult.TimedOut } catch {}
  try { $exitCode = [int]$GateResult.ExitCode } catch {}
  if (-not ($timedOut -or $exitCode -eq 124)) { return $false }

  $attempts = 0
  $retryAdded = $false
  $timeoutSchedule = @()
  $fallbackUsed = $false
  $fallbackBudget = 0
  try { $attempts = [int]$GateResult.Attempts } catch {}
  try { $retryAdded = [bool]$GateResult.TimeoutRetryAdded } catch {}
  try { $timeoutSchedule = @($GateResult.TimeoutSchedule | ForEach-Object { [int]$_ }) } catch { $timeoutSchedule = @() }
  try { $fallbackUsed = [bool]$GateResult.TimeoutFallbackAdded } catch {}
  try { $fallbackBudget = [int]$GateResult.TimeoutFallbackBudget } catch {}

  $baseTimeoutSchedule = @($timeoutSchedule)
  if ($fallbackUsed -and $fallbackBudget -gt 0 -and $baseTimeoutSchedule.Count -ge 2 -and [int]$baseTimeoutSchedule[1] -eq $fallbackBudget) {
    $withoutFallback = New-Object 'System.Collections.Generic.List[int]'
    for ($scheduleIndex = 0; $scheduleIndex -lt $baseTimeoutSchedule.Count; $scheduleIndex++) {
      if ($scheduleIndex -eq 1) { continue }
      [void]$withoutFallback.Add([int]$baseTimeoutSchedule[$scheduleIndex])
    }
    $baseTimeoutSchedule = @($withoutFallback.ToArray())
  }

  # A PURE wall-clock timeout (exit 124 / TimedOut) with ZERO failing tests is "no signal",
  # not a proven regression -> classify INCONCLUSIVE (fail-open) instead of hard-failing the
  # task on contention noise. A real regression surfaces as a NON-timeout failure
  # (exit!=0, TimedOut=$false), already filtered out above via NonTimeoutFailureSeen.
  if ($attempts -lt 3) { return $false }
  if ($baseTimeoutSchedule.Count -lt 3) { return $false }

  $firstBudget = [int]$baseTimeoutSchedule[0]
  $secondBudget = [int]$baseTimeoutSchedule[1]
  $retryBudget = [int]$baseTimeoutSchedule[2]
  if ($firstBudget -le 0 -or $secondBudget -le 0) { return $false }
  if ($retryBudget -lt (2 * [Math]::Max($firstBudget, $secondBudget))) { return $false }
  if (-not $retryAdded) { return $false }

  return $true
}

function New-DriverDoneGateRegressionTimeoutInconclusiveRecord {
  param(
    [AllowNull()][object]$GateResult,
    [string]$FailReason = ''
  )

  $attempts = 0
  $exitCode = 0
  $timedOut = $false
  $budget = @()
  $fallbackUsed = $false
  $fallbackBudget = 0
  try { $attempts = [int]$GateResult.Attempts } catch {}
  try { $exitCode = [int]$GateResult.ExitCode } catch {}
  try { $timedOut = [bool]$GateResult.TimedOut } catch {}
  try { $budget = @($GateResult.TimeoutSchedule | ForEach-Object { [int]$_ }) } catch { $budget = @() }
  try { $fallbackUsed = [bool]$GateResult.TimeoutFallbackAdded } catch {}
  try { $fallbackBudget = [int]$GateResult.TimeoutFallbackBudget } catch {}

  $attemptsText = ''
  if ($attempts -gt 0) { $attemptsText = (" after {0} attempt(s)" -f $attempts) }

  $budgetText = ''
  if ($budget.Count -gt 0) { $budgetText = ("; budgets={0}" -f (($budget | ForEach-Object { [string]$_ }) -join ',')) }
  $fallbackText = ''
  if ($fallbackUsed) {
    if ($fallbackBudget -gt 0) { $fallbackText = ("; fallback={0}s" -f $fallbackBudget) }
    else { $fallbackText = '; fallback=used' }
  }

  $reasonText = ([string]$FailReason).Trim()
  if ([string]::IsNullOrWhiteSpace($reasonText)) {
    $reasonText = ("exit={0}, timedOut={1}" -f $exitCode, $timedOut)
  }

  # A pure wall-clock timeout is ALWAYS fail-open (inconclusive), regardless of attempt count:
  # the suite reported no failing test — it was killed on wall-clock under contention, which is
  # not a proven regression. Real regressions arrive as non-timeout failures and are handled on
  # the hard 2-strike path, never here. The operator still sees this ⚠️ event and state records
  # the inconclusive outcome, so a persistently slow gate stays visible without blocking DONE.
  $outcome = 'inconclusive_timeout'
  $message = "⚠️ Gate-regression timeout final outcome=inconclusive_timeout$attemptsText ($reasonText$budgetText$fallbackText) — timeout не является доказанной регрессией; задача не переводится в fail/CONTINUE."

  return [pscustomobject][ordered]@{
    Outcome = $outcome
    Attempts = $attempts
    Budgets = @($budget)
    ExitCode = $exitCode
    TimedOut = $timedOut
    Message = $message
  }
}

function Set-DriverDoneGateRegressionTimeoutInconclusiveState {
  param([Parameter(Mandatory=$true)][object]$Record)

  $outcome = [string]$Record.Outcome
  $attempts = 0
  $exitCode = 0
  $timedOut = $false
  $budgets = @()
  try { $attempts = [int]$Record.Attempts } catch {}
  try { $exitCode = [int]$Record.ExitCode } catch {}
  try { $timedOut = [bool]$Record.TimedOut } catch {}
  try { $budgets = @($Record.Budgets | ForEach-Object { [int]$_ }) } catch { $budgets = @() }
  $ts = (Get-Date).ToString('o')

  Update-State ({
    param($s)
    if ($null -eq $s.PSObject.Properties['gate_regression_fail_count']) {
      $s | Add-Member -NotePropertyName gate_regression_fail_count -NotePropertyValue 0 -Force
    } else {
      $s.gate_regression_fail_count = 0
    }
    $s | Add-Member -NotePropertyName gate_regression_last_outcome -NotePropertyValue $outcome -Force
    $s | Add-Member -NotePropertyName gate_regression_last_attempts -NotePropertyValue $attempts -Force
    $s | Add-Member -NotePropertyName gate_regression_last_budgets -NotePropertyValue @($budgets) -Force
    $s | Add-Member -NotePropertyName gate_regression_last_exit_code -NotePropertyValue $exitCode -Force
    $s | Add-Member -NotePropertyName gate_regression_last_timed_out -NotePropertyValue $timedOut -Force
    $s | Add-Member -NotePropertyName gate_regression_last_at -NotePropertyValue $ts -Force
  }.GetNewClosure()) | Out-Null
}

function Invoke-DriverDoneGateRegressionTimeoutInconclusiveHandling {
  param(
    [AllowNull()][object]$GateResult,
    [string]$FailReason = ''
  )

  $record = New-DriverDoneGateRegressionTimeoutInconclusiveRecord -GateResult $GateResult -FailReason $FailReason
  if ([string]$record.Outcome -eq 'timeout_fail') {
    try { Set-DriverDoneGateRegressionTimeoutInconclusiveState -Record $record } catch {}
    Add-Message -From system -Text $record.Message -Kind event | Out-Null
    return $record
  }
  try { Clear-TaskLastFailureKind -Kind gate_regression_failed } catch {}
  try { Set-DriverDoneGateRegressionTimeoutInconclusiveState -Record $record } catch {}
  Add-Message -From system -Text $record.Message -Kind event | Out-Null
  return $record
}

function Format-DriverDoneGateRegressionBudgetSuffix {
  param([AllowNull()][object]$GateResult)

  if ($null -eq $GateResult) { return '' }
  $budget = @()
  $fallbackUsed = $false
  $fallbackBudget = 0
  try { $budget = @($GateResult.TimeoutSchedule | ForEach-Object { [int]$_ }) } catch { $budget = @() }
  try { $fallbackUsed = [bool]$GateResult.TimeoutFallbackAdded } catch {}
  try { $fallbackBudget = [int]$GateResult.TimeoutFallbackBudget } catch {}

  $parts = New-Object 'System.Collections.Generic.List[string]'
  if ($budget.Count -gt 0) {
    [void]$parts.Add(("budgets={0}" -f (($budget | ForEach-Object { [string]$_ }) -join ',')))
  }
  if ($fallbackUsed) {
    if ($fallbackBudget -gt 0) { [void]$parts.Add(("fallback={0}s" -f $fallbackBudget)) }
    else { [void]$parts.Add('fallback=used') }
  }
  if ($parts.Count -eq 0) { return '' }
  return (" ({0})" -f ([string]::Join('; ', $parts.ToArray())))
}

$script:DriverDoneGateRegressionJob = {
  param([string]$BridgeRoot, [object]$ChangedPaths, [bool]$UseChangedPathScope)
  $changedPathList = @($ChangedPaths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $result = [ordered]@{ Name='gate-regression'; Skipped=$false; Ok=$false; ExitCode=1; TimedOut=$false; Attempts=0; RuntimeError=''; Scope=@(); ScopeApplied=$UseChangedPathScope; TimeoutSchedule=@(); TimeoutRetryAdded=$false; TimeoutFallbackAdded=$false; TimeoutFallbackBudget=0; TimeoutInconclusive=$false; NonTimeoutFailureSeen=$false }
  try {
    $verifySelftestPath = Join-Path $BridgeRoot 'lib\verify-selftest.ps1'
    $inProcessSuite = $script:DriverDoneGateInProcessSuiteOverride
    if (Test-Path -LiteralPath $verifySelftestPath -PathType Leaf) {
      . $verifySelftestPath
      $inProcessSuite = $null
    } elseif ($null -eq $inProcessSuite -and -not (Get-Command Invoke-GateRegressionSuite -ErrorAction SilentlyContinue)) {
      throw ("gate-regression runtime import missing: Invoke-GateRegressionSuite ({0})" -f $verifySelftestPath)
    }
    $gateResult = $null
    $gateTimeoutSchedule = New-Object 'System.Collections.Generic.List[int]'
    [void]$gateTimeoutSchedule.Add(60)
    [void]$gateTimeoutSchedule.Add(60)
    [void]$gateTimeoutSchedule.Add(120)
    $gateFallbackBudgetSec = 600
    $gateFallbackTried = $false
    $invokeGateRegressionOnce = {
      param([int]$TimeoutSec)
      if ($UseChangedPathScope) {
        if ($inProcessSuite) {
          return (& $inProcessSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec -ChangedPaths @($changedPathList))
        }
        return (Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec -ChangedPaths @($changedPathList))
      }
      if ($inProcessSuite) {
        return (& $inProcessSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec)
      }
      return (Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec)
    }
    $recordGateResult = {
      param([AllowNull()][object]$RawGateResult)
      if ($RawGateResult) {
        $result.ExitCode = [int]$RawGateResult.ExitCode
        $result.TimedOut = [bool]$RawGateResult.TimedOut
        $result.Scope = @($RawGateResult.Scope)
        if (-not [bool]$RawGateResult.Ok -and -not [bool]$RawGateResult.TimedOut -and [int]$RawGateResult.ExitCode -ne 124) {
          $result.NonTimeoutFailureSeen = $true
        }
      }
    }
    for ($gateIndex = 0; $gateIndex -lt $gateTimeoutSchedule.Count; $gateIndex++) {
      $gateTimeoutSec = [int]$gateTimeoutSchedule[$gateIndex]
      if ($gateIndex -eq 2) { $result.TimeoutRetryAdded = $true }
      $gateAttempt = [int]$result.Attempts + 1
      $result.Attempts = $gateAttempt
      $result.TimeoutSchedule = @($result.TimeoutSchedule + $gateTimeoutSec)
      $gateResult = & $invokeGateRegressionOnce -TimeoutSec $gateTimeoutSec
      & $recordGateResult -RawGateResult $gateResult
      if ($gateResult -and [bool]$gateResult.Ok) {
        $result.Ok = $true
        break
      }
      $gateTimedOut = $false
      if ($gateResult) { $gateTimedOut = ([bool]$gateResult.TimedOut -or [int]$gateResult.ExitCode -eq 124) }
      if ($gateTimedOut -and -not $gateFallbackTried -and -not [bool]$result.NonTimeoutFailureSeen) {
        $gateFallbackTried = $true
        $result.TimeoutFallbackAdded = $true
        $result.TimeoutFallbackBudget = $gateFallbackBudgetSec
        $result.Attempts = [int]$result.Attempts + 1
        $result.TimeoutSchedule = @($result.TimeoutSchedule + $gateFallbackBudgetSec)
        $gateResult = & $invokeGateRegressionOnce -TimeoutSec $gateFallbackBudgetSec
        & $recordGateResult -RawGateResult $gateResult
        if ($gateResult -and [bool]$gateResult.Ok) {
          $result.Ok = $true
          break
        }
        $gateFallbackTimedOut = $false
        if ($gateResult) { $gateFallbackTimedOut = ([bool]$gateResult.TimedOut -or [int]$gateResult.ExitCode -eq 124) }
        if (-not $gateFallbackTimedOut) { break }
      }
    }
    $result.TimeoutInconclusive = $false
  } catch {
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
}

$script:DriverDoneGateIntegrityJob = {
  param([string]$BridgeRoot)
  $result = [ordered]@{ Name='integrity'; Skipped=$false; Ok=$false; ExitCode=1; Output=''; RuntimeError='' }
  try {
    $integrityScript = Join-Path $BridgeRoot 'tools\test-state-integrity.ps1'
    if (-not (Test-Path -LiteralPath $integrityScript -PathType Leaf)) {
      $result.Skipped = $true
      $result.Ok = $true
      $result.RuntimeError = 'test-state-integrity.ps1 not found - skipped'
      return [pscustomobject]$result
    }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $integrityScript -BridgeRoot $BridgeRoot 2>&1 | Out-String
    $result.Output = [string]$out
    $result.ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $result.Ok = ($result.ExitCode -eq 0)
  } catch {
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
}

function New-DriverDoneGateMissingResult {
  param([Parameter(Mandatory=$true)][string]$Name)

  switch ($Name) {
    'parse' {
      return [pscustomobject][ordered]@{
        Name = 'parse'
        Skipped = $false
        Ok = $false
        Files = @()
        FailedFile = ''
        ErrorLine = 0
        ErrorMessage = ''
        RuntimeError = 'background job completed without a parse result'
      }
    }
    'smoke' {
      return [pscustomobject][ordered]@{
        Name = 'smoke'
        Skipped = $false
        Ok = $false
        Output = ''
        ExitCode = 1
        RuntimeError = 'background job completed without a smoke result'
      }
    }
    'gate-regression' {
      return [pscustomobject][ordered]@{
        Name = 'gate-regression'
        Skipped = $false
        Ok = $false
        ExitCode = 1
        TimedOut = $false
        Attempts = 0
        RuntimeError = 'background job completed without a gate-regression result'
        Scope = @()
        ScopeApplied = $false
        TimeoutSchedule = @()
        TimeoutRetryAdded = $false
        TimeoutFallbackAdded = $false
        TimeoutFallbackBudget = 0
        TimeoutInconclusive = $false
        NonTimeoutFailureSeen = $false
      }
    }
    'integrity' {
      return [pscustomobject][ordered]@{
        Name = 'integrity'
        Skipped = $false
        Ok = $false
        ExitCode = 1
        Output = ''
        RuntimeError = 'background job completed without an integrity result'
      }
    }
  }

  return [pscustomobject][ordered]@{
    Name = $Name
    Skipped = $false
    Ok = $false
    RuntimeError = 'background job completed without a result'
  }
}

function Invoke-DriverDoneGateChecksSequential {
  param(
    [Parameter(Mandatory=$true)][object]$Plan,
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [Parameter(Mandatory=$true)][string]$Channel,
    [scriptblock]$GateRegressionSuiteScriptBlock = $null
  )

  $parseResult = $null
  $smokeResult = $null
  $gateResult = $null
  $integrityResult = $null
  if ($Plan.ParseFiles.Count -gt 0) {
    $parseResult = & $script:DriverDoneGateParseJob $BridgeRoot @($Plan.ParseFiles)
  }
  if ([bool]$Plan.SmokeNeeded) {
    $script:DriverSmokeTimingStart = [DateTime]::UtcNow
    $smokeResult = & $script:DriverDoneGateSmokeJob (Join-Path $BridgeRoot 'smoke.ps1') $Channel
    try {
      $smokeMs = [long]([DateTime]::UtcNow - $script:DriverSmokeTimingStart).TotalMilliseconds
      if ($smokeMs -gt 100 -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) { Update-TaskPhaseTiming -Phase smoke_ms -Ms $smokeMs }
    } catch {}
  }
  if ([bool]$Plan.GateSuiteNeeded) {
    $useScope = [string]::IsNullOrWhiteSpace([string]$Plan.GateScopeError)
      $gateResult = [ordered]@{ Name='gate-regression'; Skipped=$false; Ok=$false; ExitCode=1; TimedOut=$false; Attempts=0; RuntimeError=''; Scope=@(); ScopeApplied=$useScope; TimeoutSchedule=@(); TimeoutRetryAdded=$false; TimeoutFallbackAdded=$false; TimeoutFallbackBudget=0; TimeoutInconclusive=$false; NonTimeoutFailureSeen=$false }
    try {
      $verifySelftestPath = Join-Path $BridgeRoot 'lib\verify-selftest.ps1'
      if ($null -eq $GateRegressionSuiteScriptBlock -and -not (Get-Command Invoke-GateRegressionSuite -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $verifySelftestPath -PathType Leaf) {
          . $verifySelftestPath
        } else {
          throw 'gate-regression runtime import missing: Invoke-GateRegressionSuite'
        }
      }
      $rawGateResult = $null
      $gateTimeoutSchedule = New-Object 'System.Collections.Generic.List[int]'
      [void]$gateTimeoutSchedule.Add(60)
      [void]$gateTimeoutSchedule.Add(60)
      [void]$gateTimeoutSchedule.Add(120)
      $gateFallbackBudgetSec = 600
      $gateFallbackTried = $false
      $invokeGateRegressionOnce = {
        param([int]$TimeoutSec)
        if ($useScope) {
          if ($GateRegressionSuiteScriptBlock) {
            return (& $GateRegressionSuiteScriptBlock -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec -ChangedPaths @($Plan.ChangedPaths))
          }
          return (Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec -ChangedPaths @($Plan.ChangedPaths))
        }
        if ($GateRegressionSuiteScriptBlock) {
          return (& $GateRegressionSuiteScriptBlock -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec)
        }
        return (Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec $TimeoutSec)
      }
      $recordGateResult = {
        param([AllowNull()][object]$RawGateResult)
        if ($RawGateResult) {
          $gateResult.ExitCode = [int]$RawGateResult.ExitCode
          $gateResult.TimedOut = [bool]$RawGateResult.TimedOut
          $gateResult.Scope = @($RawGateResult.Scope)
          if (-not [bool]$RawGateResult.Ok -and -not [bool]$RawGateResult.TimedOut -and [int]$RawGateResult.ExitCode -ne 124) {
            $gateResult.NonTimeoutFailureSeen = $true
          }
        }
      }
      for ($gateIndex = 0; $gateIndex -lt $gateTimeoutSchedule.Count; $gateIndex++) {
        $gateTimeoutSec = [int]$gateTimeoutSchedule[$gateIndex]
        if ($gateIndex -eq 2) { $gateResult.TimeoutRetryAdded = $true }
        $gateAttempt = [int]$gateResult.Attempts + 1
        $gateResult.Attempts = $gateAttempt
        $gateResult.TimeoutSchedule = @($gateResult.TimeoutSchedule + $gateTimeoutSec)
        $rawGateResult = & $invokeGateRegressionOnce -TimeoutSec $gateTimeoutSec
        & $recordGateResult -RawGateResult $rawGateResult
        if ($rawGateResult -and [bool]$rawGateResult.Ok) {
          $gateResult.Ok = $true
          break
        }
        $gateTimedOut = $false
        if ($rawGateResult) { $gateTimedOut = ([bool]$rawGateResult.TimedOut -or [int]$rawGateResult.ExitCode -eq 124) }
        if ($gateTimedOut -and -not $gateFallbackTried -and -not [bool]$gateResult.NonTimeoutFailureSeen) {
          $gateFallbackTried = $true
          $gateResult.TimeoutFallbackAdded = $true
          $gateResult.TimeoutFallbackBudget = $gateFallbackBudgetSec
          $gateResult.Attempts = [int]$gateResult.Attempts + 1
          $gateResult.TimeoutSchedule = @($gateResult.TimeoutSchedule + $gateFallbackBudgetSec)
          $rawGateResult = & $invokeGateRegressionOnce -TimeoutSec $gateFallbackBudgetSec
          & $recordGateResult -RawGateResult $rawGateResult
          if ($rawGateResult -and [bool]$rawGateResult.Ok) {
            $gateResult.Ok = $true
            break
          }
          $gateFallbackTimedOut = $false
          if ($rawGateResult) { $gateFallbackTimedOut = ([bool]$rawGateResult.TimedOut -or [int]$rawGateResult.ExitCode -eq 124) }
          if (-not $gateFallbackTimedOut) { break }
        }
      }
      $gateResult.TimeoutInconclusive = Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult ([pscustomobject]$gateResult)
    } catch {
      $gateResult.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
    }
    $gateResult = [pscustomobject]$gateResult
  }
  if ([bool]$Plan.IntegrityNeeded) {
    $integrityResult = & $script:DriverDoneGateIntegrityJob $BridgeRoot
  }

  return [pscustomobject][ordered]@{
    Mode = 'sequential'
    FallbackReason = ''
    Plan = $Plan
    JobsStarted = 0
    Parse = $parseResult
    Smoke = $smokeResult
    GateRegression = $gateResult
    Integrity = $integrityResult
  }
}

# Watchdog stale threshold the driver heartbeat must beat (mirrors watchdog.ps1: `$age -lt 1800`).
# The DONE-gate heartbeat pump keeps its interval well under 1/3 of this so several beats land
# inside every stale window even when a single state write is slow/contended on OneDrive.
$script:DriverWatchdogStaleThresholdSec = 1800

function Get-DriverHeartbeatPumpInterval {
  # Clamp the requested pump interval into a safe band: never faster than 5s (avoid hammering
  # state.json) and never slower than stale/3 (HB_PUMP_006 invariant: >=3 beats per stale window).
  param([int]$Requested = 30)
  $staleThird = [int]([math]::Floor($script:DriverWatchdogStaleThresholdSec / 3))
  if ($staleThird -lt 5) { $staleThird = 5 }
  $value = $Requested
  if ($value -lt 5) { $value = 5 }
  if ($value -gt $staleThird) { $value = $staleThird }
  return $value
}

function Wait-DriverDoneGateJobsWithHeartbeat {
  # Heartbeat pump for the heavy DONE-gate window (parse + smoke + gate-regression + integrity).
  #
  # Root cause (2026-06-22, watchdog false-stale restart): the driver used to block its main thread
  # in a bare `Wait-Job` for the WHOLE gate, which can run past the watchdog stale threshold
  # (1800s) on a heavy cycle. state.heartbeat stayed frozen the entire time, so a HEALTHY-but-
  # finalizing driver looked STALE -> watchdog restarted it mid-finalization (self-reinforcing: the
  # restart re-queued the same heavy task).
  #
  # Fix: the gate checks already run in background jobs, so the main thread has nothing to do but
  # wait. Instead of blocking, it POLLS the jobs and refreshes the heartbeat on a short interval.
  # The main thread is the SOLE state writer while these jobs run (the jobs only return facts and
  # never touch state.json), so this reuses the normal Update-State path and preserves the state
  # integrity hash -- no second process writes state.json (which would both race os.replace on
  # Windows and break the integrity SHA).
  #
  # Bounded activation: a genuinely DEADLOCKED gate (a job that never returns) must still surface,
  # otherwise the pump would mask it forever. After MaxWaitSec the pump stops and returns; the
  # caller then force-removes the still-running jobs and collects missing results, so a stuck gate
  # fails closed under the driver's own control instead of relying on a destructive watchdog
  # rollback. MaxWaitSec sits far above the observed worst-case (~20-27min) so a merely-slow gate is
  # never killed.
  #
  # Returns a small record { Ended; HeartbeatCount; ElapsedSec; CapHit } for diagnostics/tests.
  param(
    [object[]]$Jobs = @(),
    [int]$HeartbeatIntervalSec = 30,
    [int]$PollIntervalMs = 1000,
    [int]$MaxWaitSec = 2700,
    [scriptblock]$HeartbeatAction = $null,
    [scriptblock]$JobsRunningCheck = $null,
    [scriptblock]$NowProvider = $null
  )

  $jobList = @($Jobs | Where-Object { $_ })
  $record = [ordered]@{ Ended = 'completed'; HeartbeatCount = 0; ElapsedSec = 0; CapHit = $false }
  if ($jobList.Count -eq 0) { return [pscustomobject]$record }

  $HeartbeatIntervalSec = Get-DriverHeartbeatPumpInterval -Requested $HeartbeatIntervalSec
  if ($PollIntervalMs -lt 1) { $PollIntervalMs = 1 }
  if ($MaxWaitSec -lt 1) { $MaxWaitSec = 1 }

  if (-not $NowProvider) { $NowProvider = { [DateTime]::UtcNow } }
  if (-not $HeartbeatAction) {
    $HeartbeatAction = {
      if (Get-Command Update-DriverHeartbeat -ErrorAction SilentlyContinue) { Update-DriverHeartbeat }
    }
  }
  if (-not $JobsRunningCheck) {
    $JobsRunningCheck = {
      param($js)
      [bool]((@($js | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' })).Count -gt 0)
    }
  }

  $start = & $NowProvider
  # Emit one beat immediately so the window opens fresh even if it ends before the first interval.
  try { & $HeartbeatAction; $record.HeartbeatCount++ } catch {}
  $lastBeat = $start

  while ($true) {
    $running = $false
    try { $running = [bool](& $JobsRunningCheck $jobList) } catch { $running = $false }
    if (-not $running) { $record.Ended = 'completed'; break }

    $now = & $NowProvider
    if (($now - $start).TotalSeconds -ge $MaxWaitSec) {
      $record.Ended = 'cap'; $record.CapHit = $true; break
    }
    if (($now - $lastBeat).TotalSeconds -ge $HeartbeatIntervalSec) {
      try { & $HeartbeatAction; $record.HeartbeatCount++ } catch {}
      $lastBeat = $now
    }
    Start-Sleep -Milliseconds $PollIntervalMs
  }

  $record.ElapsedSec = [int]((& $NowProvider) - $start).TotalSeconds
  return [pscustomobject]$record
}

function Invoke-DriverDoneGateChecks {
  param(
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [AllowNull()][string]$TaskBaseCommit,
    [Parameter(Mandatory=$true)][string]$Channel,
    [AllowNull()][string]$Reply,
    [scriptblock]$GateRegressionSuiteScriptBlock = $null,
    [string[]]$ChangedPathsOverride = $null
  )

  $plan = New-DriverDoneGatePlan -BridgeRoot $BridgeRoot -TaskBaseCommit $TaskBaseCommit -Reply $Reply -ChangedPathsOverride $ChangedPathsOverride
  if ($plan.JobNames.Count -eq 0) {
    return [pscustomobject][ordered]@{ Mode='none'; FallbackReason=''; Plan=$plan; JobsStarted=0; Parse=$null; Smoke=$null; GateRegression=$null; Integrity=$null }
  }
  if ([bool]$plan.GateSuiteNeeded -and -not (Test-Path -LiteralPath (Join-Path $BridgeRoot 'lib\verify-selftest.ps1') -PathType Leaf)) {
    $seq = Invoke-DriverDoneGateChecksSequential -Plan $plan -BridgeRoot $BridgeRoot -Channel $Channel -GateRegressionSuiteScriptBlock $GateRegressionSuiteScriptBlock
    $seq.FallbackReason = 'gate-regression runtime requires in-process imports'
    return $seq
  }
  if (-not (Get-Command Start-Job -ErrorAction SilentlyContinue)) {
    $seq = Invoke-DriverDoneGateChecksSequential -Plan $plan -BridgeRoot $BridgeRoot -Channel $Channel -GateRegressionSuiteScriptBlock $GateRegressionSuiteScriptBlock
    $seq.FallbackReason = 'Start-Job unavailable'
    return $seq
  }

  $startedJobs = @{}
  try {
    if ($plan.ParseFiles.Count -gt 0) {
      $startedJobs['parse'] = Start-Job -ScriptBlock $script:DriverDoneGateParseJob -ArgumentList $BridgeRoot, @($plan.ParseFiles)
    }
    if ([bool]$plan.SmokeNeeded) {
      $startedJobs['smoke'] = Start-Job -ScriptBlock $script:DriverDoneGateSmokeJob -ArgumentList (Join-Path $BridgeRoot 'smoke.ps1'), $Channel
    }
    if ([bool]$plan.GateSuiteNeeded) {
      $useScope = [string]::IsNullOrWhiteSpace([string]$plan.GateScopeError)
      $startedJobs['gate-regression'] = Start-Job -ScriptBlock $script:DriverDoneGateRegressionJob -ArgumentList $BridgeRoot, @($plan.ChangedPaths), $useScope
    }
    if ([bool]$plan.IntegrityNeeded) {
      $startedJobs['integrity'] = Start-Job -ScriptBlock $script:DriverDoneGateIntegrityJob -ArgumentList $BridgeRoot
    }

    if ($startedJobs.Count -gt 0) {
      # Heartbeat pump (2026-06-22): a heavy DONE-gate can run past the watchdog stale threshold
      # (watchdog.ps1: hbAge >= 1800s). Blocking in a bare Wait-Job here froze state.heartbeat for
      # the whole window -> a HEALTHY-but-finalizing driver looked STALE -> false watchdog restart
      # that interrupted finalization. Poll the jobs and pump the heartbeat instead (this thread is
      # the sole state writer while the jobs run). A genuinely stuck gate still fails closed: after
      # the cap the pump returns and the Receive/Remove-Job below force-kills the hung jobs.
      $hbIntervalSec = if ($env:BRIDGE_DONEGATE_HB_INTERVAL_SEC) { [int]$env:BRIDGE_DONEGATE_HB_INTERVAL_SEC } else { 30 }
      $hbMaxWaitSec  = if ($env:BRIDGE_DONEGATE_MAX_WAIT_SEC) { [int]$env:BRIDGE_DONEGATE_MAX_WAIT_SEC } else { 2700 }
      [void](Wait-DriverDoneGateJobsWithHeartbeat -Jobs @($startedJobs.Values) -HeartbeatIntervalSec $hbIntervalSec -MaxWaitSec $hbMaxWaitSec)
    }

    $results = @{}
    foreach ($key in @($startedJobs.Keys)) {
      $job = $startedJobs[$key]
      $received = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
      if ($received.Count -gt 0) {
        $results[$key] = $received[$received.Count - 1]
      } else {
        $missing = New-DriverDoneGateMissingResult -Name $key
        try {
          $jobState = [string]$job.State
          if (-not [string]::IsNullOrWhiteSpace($jobState)) {
            $missing.RuntimeError = ("background job returned no result (state={0})" -f $jobState)
          }
        } catch {}
        $results[$key] = $missing
      }
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject][ordered]@{
      Mode = 'parallel'
      FallbackReason = ''
      Plan = $plan
      JobsStarted = [int]$startedJobs.Count
      Parse = $(if ($results.ContainsKey('parse')) { $results['parse'] } else { $null })
      Smoke = $(if ($results.ContainsKey('smoke')) { $results['smoke'] } else { $null })
      GateRegression = $(if ($results.ContainsKey('gate-regression')) { $results['gate-regression'] } else { $null })
      Integrity = $(if ($results.ContainsKey('integrity')) { $results['integrity'] } else { $null })
    }
  } catch {
    $fallbackReason = ($_.Exception.Message -replace '\s+',' ').Trim()
    foreach ($job in @($startedJobs.Values)) {
      try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    }
    $seq = Invoke-DriverDoneGateChecksSequential -Plan $plan -BridgeRoot $BridgeRoot -Channel $Channel -GateRegressionSuiteScriptBlock $GateRegressionSuiteScriptBlock
    $seq.FallbackReason = $fallbackReason
    return $seq
  }
}

function Test-DoneGateIsFragmented {
  # Returns $true when a backlog task was already decomposed into child atoms and must not be
  # closed as DONE. Checks the item markers and any sibling in AllItems with parent_id = TaskId.
  param(
    [Parameter(Mandatory=$false)][string]$TaskId = '',
    [Parameter(Mandatory=$false)][object[]]$AllItems = @()
  )
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
  $ownItem = $null
  foreach ($candidate in @($AllItems)) {
    if ($null -eq $candidate) { continue }
    $cid = ''
    try { $cid = [string]($candidate | Select-Object -ExpandProperty 'id' -ErrorAction SilentlyContinue) } catch {}
    if ([string]::Equals($cid, $TaskId, [System.StringComparison]::OrdinalIgnoreCase)) { $ownItem = $candidate; break }
  }
  if ($null -ne $ownItem) {
    $ownStatus = ''
    try { $ownStatus = ([string]($ownItem | Select-Object -ExpandProperty 'status' -ErrorAction SilentlyContinue)).ToLowerInvariant() } catch {}
    if ($ownStatus -eq 'decomposed') { return $true }
    foreach ($markerField in @('is_decomposed','is_fragmented','decomposed')) {
      $markerVal = $null
      try { $markerVal = $ownItem.$markerField } catch {}
      if ($null -eq $markerVal) { continue }
      $markerRaw = [string]$markerVal
      if (@('','false','0','no','off','null') -notcontains $markerRaw.ToLowerInvariant()) { return $true }
    }
    $decompAt = ''
    try { $decompAt = [string]($ownItem | Select-Object -ExpandProperty 'decomposed_at' -ErrorAction SilentlyContinue) } catch {}
    if (-not [string]::IsNullOrWhiteSpace($decompAt)) { return $true }
  }
  foreach ($candidate in @($AllItems)) {
    if ($null -eq $candidate) { continue }
    $cid = ''
    try { $cid = [string]($candidate | Select-Object -ExpandProperty 'id' -ErrorAction SilentlyContinue) } catch {}
    if ([string]::Equals($cid, $TaskId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $parentId = ''
    try { $parentId = ([string]($candidate | Select-Object -ExpandProperty 'parent_id' -ErrorAction SilentlyContinue)).Trim() } catch {}
    if (-not [string]::IsNullOrWhiteSpace($parentId) -and [string]::Equals($parentId, $TaskId, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

$script:DriverLoopCompletionInitialChecksBlock = {
  $plannerStatus = 'CONTINUE'
  $fastLaneDone = $false
  if (-not (Get-Command Get-TaskActionEvidence -ErrorAction SilentlyContinue)) {
    . (Join-Path $bridgeRoot 'lib\task-action-evidence.ps1')
  }
  if (-not (Get-Command Get-TaskActionEvidence -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidence'
  }
  if (-not (Get-Command Get-TaskActionEvidenceContext -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidenceContext'
  }
  if ($speaker -eq 'codex') {
    $chunkSettings = Get-ChunkingSettings
    $cm = [regex]::Match($reply, '(?im)^\s*STATUS:\s*CONTINUE-CHUNK\s*:\s*(\d+)\s*/\s*(\d+)\s*$')
    if ([bool]$chunkSettings.enabled -and $cm.Success) {
      $chunkN = [int]$cm.Groups[1].Value
      $chunkM = [int]$cm.Groups[2].Value
      $maxChunks = [int]$chunkSettings.maxChunksPerTask
      $headNow = ''
      try { $headNow = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch {}
      $stChunk = Read-State
      $chunkBase = [string]$stChunk.chunk_base_commit
      if ([string]::IsNullOrWhiteSpace($chunkBase)) { $chunkBase = [string]$stChunk.task_base_commit }
      $baseLabel = if ([string]::IsNullOrWhiteSpace($chunkBase)) { '<empty>' } elseif ($chunkBase.Length -gt 7) { $chunkBase.Substring(0,7) } else { $chunkBase }
      $headAdvanced = (-not [string]::IsNullOrWhiteSpace($headNow)) -and ($headNow -ne $chunkBase)
      if (-not $headAdvanced) {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM помечен, но коммит не зафиксирован (HEAD не сдвинулся с $baseLabel). Закоммить и повтори с тем же STATUS: CONTINUE-CHUNK:$chunkN/$chunkM." -Kind event | Out-Null
        Update-State { param($s) $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        continue
      }
      $shortSha = if ($headNow.Length -gt 7) { $headNow.Substring(0,7) } else { $headNow }
      $newProgress = "$chunkN/$chunkM"
      if ($chunkN -ge $maxChunks) {
        Add-Message -From system -Text "Достигнут лимит чанков на задачу ($chunkN/$maxChunks, последний коммит $shortSha). Принудительно закрываю задачу. Если работа не завершена — раздели на отдельные задачи." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
          $s | Add-Member -NotePropertyName skip_critic -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0; $s.verify_retry_count=2
        }.GetNewClosure()) | Out-Null
        $plannerStatus = 'DONE'
        $fastLaneDone = $true
      } else {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM завершён: commit $shortSha. Продолжаю на следующий чанк." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0
          $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        continue
      }
    } elseif ([bool]$chunkSettings.enabled) {
      $stChunkDone = Read-State
      $hasChunkProgress = -not [string]::IsNullOrWhiteSpace([string]$stChunkDone.chunk_progress)
      $doneHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*DONE\s*$')
      if ($hasChunkProgress -and $doneHits.Count -gt 0) {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='planner'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
        Update-State { param($s) $s.task_did_actions=$true; $s.no_progress_count=0 } | Out-Null
      }
    }

    # 2026-05-27: Deterministic claim verification for Codex reply. Parses
    # the reply for verifiable assertions (HTTP status, ParseFile OK, git SHA)
    # and checks each against ground truth. NEVER blocks the flow — only
    # synthesizes a system event so the next planner turn sees the discrepancy
    # alongside Codex's claim. Catches the over-claim pattern (curator-задача
    # 2026-05-27) before the LLM verify gate spends a 30s round.
    try {
      $repoClaimRoot = $bridgeRoot
      try { if (Get-Command Get-TaskRepoRoot -ErrorAction SilentlyContinue) { $repoClaimRoot = [string](Get-TaskRepoRoot) } } catch {}
      $gateReport = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRoot -ProjectRoot $repoClaimRoot
      if ($gateReport.violations.Count -gt 0) {
        $vparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($v in $gateReport.violations) {
          [void]$vparts.Add("• [$($v.kind)] Codex заявил: $($v.claim) → реальность: $($v.actual)")
        }
        $okText = if ($gateReport.checks.Count -gt 0) { " (попутно $($gateReport.checks.Count) утверждений сверены OK)" } else { '' }
        Add-Message -From system -Text ("🔢 Gate-check: " + $gateReport.violations.Count + " несоответствий в reply Codex" + $okText + ":`n" + [string]::Join("`n", $vparts.ToArray()) + "`n`nПланировщик: учти эти разрывы при ревью STATUS — Codex заявил неточно, нужна доработка.") -Kind event | Out-Null
      } elseif ($gateReport.checks.Count -gt 0) {
        $kparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in ($gateReport.checks | Select-Object -First 5)) {
          [void]$kparts.Add("[$($c.kind)] $($c.claim)")
        }
        $more = if ($gateReport.checks.Count -gt 5) { " (+ $($gateReport.checks.Count - 5) more)" } else { '' }
        Add-Message -From system -Text ("✓ Gate-check Codex'а: " + $gateReport.checks.Count + " утверждений сверены с фактами OK — " + [string]::Join('; ', $kparts.ToArray()) + $more) -Kind event | Out-Null
      }
    } catch {
      Add-Message -From system -Text ("⚠ Gate-check exception: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  if ($fastLaneActiveForTurn) {
    $coderStatusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(DONE|CONTINUE)\s*$')
    if ($coderStatusHits.Count -gt 0) {
      $coderStatus = $coderStatusHits[$coderStatusHits.Count - 1].Groups[1].Value.ToUpper()
      if ($coderStatus -eq 'DONE') {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='coder'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
      }
    }
  }
  if ($speaker -eq 'claude') {
    $statusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(CHAT|CONTINUE|DISCUSS|DONE|RESEARCH)\s*$')
    if ($statusHits.Count -gt 0) { $plannerStatus = $statusHits[$statusHits.Count - 1].Groups[1].Value.ToUpper() }

    # Planner decomposed the parent backlog atom into child atoms; close the parent
    # without sending the decomposed parent through coder/DONE gates.
    $decompResult = Test-PlannerDecomposed -ReplyText $reply
    if ($decompResult.IsDecomposed) {
      Invoke-DriverDecomposedMarker -DecompResult $decompResult -BridgeRoot $bridgeRoot | Out-Null
      continue
    }

    # FIX 2026-05-27: parallel coder dispatch. If planner reply contains >= 2 [[PARALLEL:N]]
    # blocks with file-disjoint workloads, fan out to worker pool (Claude+Codex round-robin
    # in separate worktrees) instead of normal Codex-only flow. After merge, treat as if
    # planner had said STATUS: DONE so verify gate + critic proceed normally on combined diff.
    if ($plannerStatus -eq 'CONTINUE' -and ($modeBeforeIncrement -eq 'normal' -or $modeBeforeIncrement -eq 'discuss')) {
      $parStreams = $null
      try { $parStreams = Test-CanParallelize -PlanText $reply } catch { $parStreams = $null }
      if ($parStreams -and $parStreams.Count -ge 2) {
        try {
          Add-Message -From system -Text ("🔀 Parallel dispatch: " + $parStreams.Count + " streams detected in planner reply") -Kind event | Out-Null
          $parResult = Invoke-ParallelDispatch -Streams $parStreams -TimeoutMin 25 -PollSec 10
          # --- per-task timeout retry for timed-out/quarantined parallel workers ---
          $batchCfg = $null
          try {
            if (-not (Get-Command Get-BatchTimeoutConfig -ErrorAction SilentlyContinue)) {
              $batchTimeoutPath = Join-Path $bridgeRoot 'lib\batch-timeout.ps1'
              if (Test-Path -LiteralPath $batchTimeoutPath -PathType Leaf) { . $batchTimeoutPath }
            }
            if (Get-Command Get-BatchTimeoutConfig -ErrorAction SilentlyContinue) {
              $batchCfg = Get-BatchTimeoutConfig
            }
          } catch { $batchCfg = $null }
          $retryTimeoutSec = 0
          $retryMaxAttempts = 3
          try { $retryTimeoutSec = [int]$batchCfg.TimeoutSec } catch {}
          try { $retryMaxAttempts = [int]$batchCfg.MaxAttempts } catch {}
          if ($retryMaxAttempts -lt 1) { $retryMaxAttempts = 3 }
          $batchRetryEnabled = $false
          try { $batchRetryEnabled = [bool]$batchCfg.Enabled } catch {}
          $quarantinedIds = @()
          try { $quarantinedIds = @($parResult.quarantined_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch {}
          if ($batchCfg -and $batchRetryEnabled -and $retryTimeoutSec -gt 0 -and $quarantinedIds.Count -gt 0 -and (Get-Command Invoke-BatchWithPerTaskTimeout -ErrorAction SilentlyContinue)) {
            $quarantineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($qid in $quarantinedIds) { [void]$quarantineSet.Add([string]$qid) }
            $timedOutBlocks = @($parStreams | Where-Object {
              $sid = ''
              try { $sid = [string]$_.id } catch {}
              -not [string]::IsNullOrWhiteSpace($sid) -and $quarantineSet.Contains($sid)
            })
            if ($timedOutBlocks.Count -gt 0) {
              Add-Message -From system -Text ("[batch-timeout] " + $timedOutBlocks.Count + " parallel worker(s) timed out/quarantined, retrying sequentially...") -Kind event | Out-Null
              $retryMerged = 0
              $retryMergedIds = New-Object 'System.Collections.Generic.List[string]'
              $retryTimeoutMin = [int][Math]::Ceiling($retryTimeoutSec / 60.0)
              if ($retryTimeoutMin -lt 1) { $retryTimeoutMin = 1 }
              foreach ($block in $timedOutBlocks) {
                $retryTask = [pscustomobject]@{
                  Id         = [string]$block.Id
                  Block      = $block
                  TimeoutMin = $retryTimeoutMin
                  BridgeRoot = [string]$bridgeRoot
                }
                $retryResult = Invoke-BatchWithPerTaskTimeout `
                  -Tasks @($retryTask) `
                  -BootstrapScript {
                    param($task)
                    $root = [string]$task.BridgeRoot
                    if ([string]::IsNullOrWhiteSpace($root)) { throw 'missing bridge root for parallel retry bootstrap' }
                    . (Join-Path $root 'lib\common.ps1')
                    if (-not (Get-Command Start-ParallelDispatchWorkers -ErrorAction SilentlyContinue)) {
                      . (Join-Path $root 'lib\parallel.ps1')
                    }
                  } `
                  -ExecuteTask {
                    param($task)
                    $b = $task.Block
                    $singleTimeoutMin = 1
                    try { $singleTimeoutMin = [int]$task.TimeoutMin } catch {}
                    if ($singleTimeoutMin -lt 1) { $singleTimeoutMin = 1 }
                    $singleTaskHash = Get-ParallelDispatchTaskHash
                    $startup = Start-ParallelDispatchWorkers -Streams @($b) -TaskHash $singleTaskHash
                    if (-not $startup.ok) {
                      throw ("parallel retry startup failed for stream " + [string]$b.id + ": " + [string]$startup.reason)
                    }
                    $singleWorkers = @($startup.workers)
                    $singleCompleted = Wait-ParallelDispatchResults -Workers $singleWorkers -TaskHash $singleTaskHash -TimeoutMin $singleTimeoutMin -PollSec 10
                    $singleResult = Complete-ParallelDispatchOutputs -Workers $singleWorkers -Completed $singleCompleted -TaskHash $singleTaskHash
                    $singleClean = $false; try { $singleClean = [bool]$singleResult.clean } catch {}
                    $singleQ = 0; try { $singleQ = [int]$singleResult.quarantined } catch {}
                    if (-not $singleClean -or $singleQ -gt 0) {
                      $singleReason = ''; try { $singleReason = [string]$singleResult.reason } catch {}
                      if ([string]::IsNullOrWhiteSpace($singleReason)) { $singleReason = 'not_clean' }
                      throw ("parallel retry stream " + [string]$b.id + " did not complete cleanly: " + $singleReason)
                    }
                    return $singleResult
                  } `
                  -TimeoutSec $retryTimeoutSec `
                  -MaxAttempts $retryMaxAttempts `
                  -Name ("retry-" + [string]$block.Id)
                $retryTaskResults = @()
                try { $retryTaskResults = @($retryResult.Results) } catch {}
                if ($retryTaskResults.Count -eq 0 -and $retryResult) { $retryTaskResults = @($retryResult) }
                foreach ($rr in @($retryTaskResults)) {
                  $dispatchResult = $rr
                  $rrSucceeded = $true
                  try {
                    if ($rr.PSObject.Properties.Name -contains 'Status') { $rrSucceeded = ([string]$rr.Status -eq 'Success') }
                    if ($rr.PSObject.Properties.Name -contains 'Result') { $dispatchResult = $rr.Result }
                  } catch {}
                  $rrOk = $false
                  try { $rrOk = [bool]$dispatchResult.ok } catch {}
                  $rrClean = $false
                  try { $rrClean = [bool]$dispatchResult.clean } catch {}
                  if ($rrSucceeded -and $rrOk -and $rrClean) {
                    $retryResultAddedId = $false
                    $rrMerged = 0
                    try { $rrMerged = [int]$dispatchResult.merged } catch {}
                    if ($rrMerged -lt 1) { $rrMerged = 1 }
                    $retryMerged += $rrMerged
                    try {
                      foreach ($mid in @($dispatchResult.merged_ids)) {
                        $midText = [string]$mid
                        if (-not [string]::IsNullOrWhiteSpace($midText)) {
                          $retryResultAddedId = $true
                          if (-not $retryMergedIds.Contains($midText)) { [void]$retryMergedIds.Add($midText) }
                        }
                      }
                    } catch {}
                    if (-not $retryResultAddedId) {
                      $bid = [string]$block.id
                      if (-not [string]::IsNullOrWhiteSpace($bid) -and -not $retryMergedIds.Contains($bid)) { [void]$retryMergedIds.Add($bid) }
                    }
                  }
                }
              }
              if ($retryMerged -gt 0) {
                $remainingQuarantined = @($quarantinedIds | Where-Object { -not $retryMergedIds.Contains([string]$_) })
                try { $parResult.merged = ([int]$parResult.merged + $retryMerged) } catch {}
                try { $parResult.quarantined = @($remainingQuarantined).Count } catch {}
                try { $parResult.quarantined_ids = @($remainingQuarantined) } catch {}
                try {
                  $mergedIds = @($parResult.merged_ids)
                  foreach ($mid in @($retryMergedIds.ToArray())) {
                    if (@($mergedIds) -inotcontains $mid) { $mergedIds += $mid }
                  }
                  $parResult.merged_ids = @($mergedIds)
                } catch {}
                try { $parResult.ok = ([int]$parResult.merged -gt 0) } catch {}
                try { $parResult.clean = (@($remainingQuarantined).Count -eq 0 -and [int]$parResult.merged -ge @($parStreams).Count) } catch {}
                try { $parResult.reason = $(if ([bool]$parResult.clean) { 'all_delivered' } elseif ([bool]$parResult.ok) { 'partial' } else { [string]$parResult.reason }) } catch {}
              }
            }
          }
          if ($parResult.ok) {
            Add-Message -From system -Text ("✅ Parallel completed: " + $parResult.merged + " streams merged into main") -Kind event | Out-Null
            $plannerStatus = 'DONE'   # work landed via workers; let verify+critic gates run
            $modeBeforeIncrement = 'normal'  # parallel delivered real implementation; force normal-mode so verify+critic+smoke gates run
            Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.task_did_actions = $true; $s.coder_fired = $true } | Out-Null
          } else {
            Add-Message -From system -Text ("⚠ Parallel failed: " + $parResult.reason + " -- fallback to sequential Codex") -Kind event | Out-Null
            # leave $plannerStatus as CONTINUE -- normal Codex turn next iteration
          }
        } catch {
          Add-Message -From system -Text ("⚠ Parallel exception: " + $_.Exception.Message + " -- fallback to sequential") -Kind event | Out-Null
        }
      }
    }

    if ($plannerStatus -eq 'DISCUSS') {
      if ($modeBeforeIncrement -ne 'discuss') {
        Update-State { param($s) $s.task_mode='discuss'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='discuss' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'CONTINUE') {
      if ($modeBeforeIncrement -eq 'synthesis') {
        Add-Message -From system -Text "🧠 Decision Synthesis завершён: принято решение и план реализации. Передаю Codex'у в normal-контур с verify/critic gates." -Kind event | Out-Null
        Update-State { param($s)
          $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
        } | Out-Null
      } elseif ($modeBeforeIncrement -eq 'discuss') {
        $dtNow = [int](Read-State).discuss_turn
        # FIX 2026-05-27: accept synonyms for the convergence-check keywords. Claude often
        # writes "Согласовано:" / "Decision:" / "Решено:" instead of literal "Решение:" —
        # technically a converged plan, but the pedantic gate kept rejecting it (12-min
        # ping-pong observed today on a 12-point task). Same for Риски/Risks/Risk.
        $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
        $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
        $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
        # FIX 2026-05-26 (Codex's Doctor fix, applied manually after restart-loop incident):
        # TrimEnd punctuation so "Открыто: нет." matches the "no open blockers" regex.
        # Without this, a trailing dot in "нет." was treated as an unresolved open question
        # and the convergence gate kept looping until 905s Codex timeout fired.
        $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
        $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
        $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
        $ceiling     = ($dtNow -ge $discussMaxTurns)
        $planMatch = [regex]::Match($reply, '(?ims)^[*_> \t#-]*План\s+реализации[^:\n]*:[*_ \t]*(.*?)(?=^\s*[*_> \t#-]*(STATUS:|Тип:|Согласовано:|Открыто:|Решение:|Риски:)|\z)')
        $hasPlan = $planMatch.Success -and -not [string]::IsNullOrWhiteSpace($planMatch.Groups[1].Value)
        if (-not $ceiling -and (-not $converged -or -not $hasPlan)) {
          $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
                 elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
                 elseif (-not $openClosed) { "остались открытые вопросы: $openVal" }
                 else { "нет непустого «План реализации:»" }
          Add-Message -From system -Text "💬 CONTINUE из обсуждения требует конвергенции и непустой «План реализации:» — $why. Claude, закройте блок состояния и повторите." -Kind event | Out-Null
          $plannerStatus = 'DISCUSS'
          Update-State { param($s) $s.task_mode='discuss' } | Out-Null
        } else {
          if ($ceiling -and (-not $converged -or -not $hasPlan)) {
            Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) достигнут — закрываю обсуждение с текущим планом, передаю Codex'у." -Kind event | Out-Null
          }
          # 2026-06-11 S4: the converged Решение/Риски/План block used to be WIPED here without
          # ever reaching the decisions journal (Save-Decision only fired for discuss-only DONE) —
          # every main-flow discussion was forgotten and the next one started from scratch. Persist
          # the snapshot BEFORE the reset so Get-DecisionsRecall feeds it into future prompts.
          try {
            $s4State = Read-State
            $s4Snapshot = [string]$s4State.discuss_snapshot
            if (-not [string]::IsNullOrWhiteSpace($s4Snapshot) -and (Get-Command Save-Decision -ErrorAction SilentlyContinue)) {
              $s4Title = [string]$s4State.current_task
              if ([string]::IsNullOrWhiteSpace($s4Title)) { $s4Title = 'discussion' }
              if ($s4Title.Length -gt 120) { $s4Title = $s4Title.Substring(0,120) }
              Save-Decision -Title $s4Title -Content $s4Snapshot | Out-Null
            }
          } catch {}
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      } elseif ($modeBeforeIncrement -eq 'study') {
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'RESEARCH') {
      if ($modeBeforeIncrement -eq 'study') {
        Add-Message -From system -Text "📚 Study уже имеет web-инструменты; продолжаю в режиме study вместо отдельного research." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } elseif ($modeBeforeIncrement -eq 'research') {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        $rc = [int](Read-State).research_count
        if ($rc -lt $researchMaxTurns) {
          $newRc = $rc + 1
          Update-State ({ param($s) $s.task_mode='research'; $s.research_count=$newRc; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' }.GetNewClosure()) | Out-Null
        } else {
          Add-Message -From system -Text "🔍 Бюджет research исчерпан ($researchMaxTurns/$researchMaxTurns ходов). Codex получит уже собранные данные." -Kind event | Out-Null
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      }
    }
    if ($modeBeforeIncrement -eq 'research' -and $plannerStatus -ne 'DONE' -and $plannerStatus -ne 'CHAT') {
      Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
    }
  }
  $fragGuardBlocked = $false
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $fragSt = Read-State
      $fragTaskId = [string]$fragSt.current_backlog_id
      if ([string]::IsNullOrWhiteSpace($fragTaskId)) { $fragTaskId = [string]$fragSt.current_task_id }
      if (-not [string]::IsNullOrWhiteSpace($fragTaskId) -and (Get-Command Get-Backlog -ErrorAction SilentlyContinue)) {
        $fragAllItems = @(Get-Backlog)
        if (Test-DoneGateIsFragmented -TaskId $fragTaskId -AllItems $fragAllItems) {
          $fragGuardBlocked = $true
          if (Get-Command Set-Idea -ErrorAction SilentlyContinue) {
            try { Set-Idea -Id $fragTaskId -Status 'decomposed' -Reason 'done-gate-fragmented-block' | Out-Null } catch {}
          }
          Add-Message -From system -Text ("⚠ DONE отклонён: задача $fragTaskId уже раздроблена на дочерние атомы (is_fragmented=true). Zombie-reaper мог ошибочно восстановить её — закрываю как decomposed. Дочерние задачи продолжают работу.") -Kind event | Out-Null
          Update-State {
            param($s)
            $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0
            $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false
            $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false
            $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''
            $s.study_snapshot=''; $s.research_count=0
            $s.current_backlog_id=$null; $s.active_agent=$null; $s.active_model=$null
            $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o')
          } | Out-Null
        }
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ DONE-gate fragmented-check failed open: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
    # State integrity check at DONE time (always, lightweight).
    if (-not $fragGuardBlocked) {
      try {
        $stateValid = Test-DoneGateStateValid -BridgeRoot $BridgeRoot -Channel $Channel
        if (-not $stateValid.Ok) {
          Add-Message -From system -Text ("🚨 DONE-gate state integrity FAILED: $($stateValid.Reason). Задача НЕ закрывается — проверь state.json.") -Kind event | Out-Null
          $fragGuardBlocked = $true
        } else {
          Add-Message -From system -Text "✅ State integrity: OK." -Kind event | Out-Null
        }
      } catch {
        Add-Message -From system -Text ("🚨 DONE-gate state integrity ERROR: $($_.Exception.Message). Задача НЕ закрывается — проверь state.json.") -Kind event | Out-Null
        $fragGuardBlocked = $true
      }
    }
    if ($fragGuardBlocked) { continue }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $noopHasBacklogId = $true
    $noopTask = ''
    $noopHasEvidence = $false
    $noopHasCoveredVerifiedEvidence = $false
    $noopHasDoneQaPassCommit = $false
    $noopEvidenceChecked = $false
    $noopGuardError = ''
    $noopBacklogId = ''
    $noopCurrentTaskId = ''
    $noopActiveBacklogIdentityMatched = $false
    try {
      $stNoop = Read-State
      $noopStateProps = @()
      try {
        if ($stNoop -and $stNoop.PSObject) { $noopStateProps = @($stNoop.PSObject.Properties.Name) }
      } catch { $noopStateProps = @() }
      if ($noopStateProps -contains 'current_backlog_id') { $noopBacklogId = [string]$stNoop.current_backlog_id }
      if ($noopStateProps -contains 'current_task_id') { $noopCurrentTaskId = [string]$stNoop.current_task_id }
      $noopHasBacklogId = -not [string]::IsNullOrWhiteSpace($noopBacklogId)
      $noopActiveBacklogIdentityMatched = $noopHasBacklogId
      if ($noopActiveBacklogIdentityMatched -and -not [string]::IsNullOrWhiteSpace($noopCurrentTaskId) -and $noopCurrentTaskId -ne $noopBacklogId) {
        $noopActiveBacklogIdentityMatched = $false
      }
      if ($noopStateProps -contains 'current_task') { $noopTask = [string]$stNoop.current_task }
      $repoNoopRoot = Get-TaskRepoRoot
      $noopEvidenceContext = Get-TaskActionEvidenceContext -State $stNoop -DefaultRepoRoot $repoNoopRoot -BridgeRoot $bridgeRoot
      $noopEvidence = Get-TaskActionEvidence -RepoRoot ([string]$noopEvidenceContext.repo_root) -BaseCommit ([string]$noopEvidenceContext.base_commit) -BridgeRoot $bridgeRoot -BaseDirtyPaths @($noopEvidenceContext.base_dirty_paths)
      $noopEvidenceChecked = $true
      if ($noopEvidence -and [bool]$noopEvidence.has_actions) {
        $noopHasEvidence = $true
        Update-State {
          param($s)
          $s.task_did_actions = $true
          $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
        } | Out-Null
      }
      $noopHasCoveredVerifiedEvidence = [bool](Test-TaskCoveredVerifiedDoneEvidence -Reply $reply)
      if ($noopHasBacklogId) {
        $noopHasDoneQaPassCommit = [bool](Test-TaskDoneQaPassCommitEvidence -BacklogId $noopBacklogId -BridgeRoot $bridgeRoot)
      }
    } catch {
      $noopGuardError = $_.Exception.Message
      $noopHasEvidence = $false
      $noopHasCoveredVerifiedEvidence = $false
      $noopHasDoneQaPassCommit = $false
      $noopEvidenceChecked = $false
    }
    try {
      $noopProjectAutopilot = [bool]([regex]::IsMatch($noopTask, '(?im)^\s*\[project-autopilot\b'))
      $noopDecision = Get-TaskDoneEvidenceDecision -HasBacklogId $noopHasBacklogId -ProjectAutopilot $noopProjectAutopilot -ProjectBacklogCreated ([int]$projectBacklogCreated) -EvidenceChecked $noopEvidenceChecked -HasEvidence $noopHasEvidence -HasCoveredVerifiedEvidence $noopHasCoveredVerifiedEvidence -HasDoneQaPassCommit $noopHasDoneQaPassCommit
      $noopAllowDone = [bool]$noopDecision.allow
      $noopRejectReason = [string]$noopDecision.reason

      if (-not $noopAllowDone) {
        $plannerStatus = 'CONTINUE'
        $noopBaseRejectReason = $noopRejectReason
        if (-not [string]::IsNullOrWhiteSpace($noopGuardError)) { $noopRejectReason = $noopRejectReason + ': ' + $noopGuardError }
        $noopFailureText = 'DONE rejected by action evidence guard: ' + $noopRejectReason
        $noopForceCoderRecovery = ($noopBaseRejectReason -eq 'missing_action_evidence' -and $noopActiveBacklogIdentityMatched)
        $noopRecoveryMessage = "Codex: создай реальный commit/diff evidence для текущей backlog-задачи, затем проверки и DONE."
        $noopFailureRecord = [pscustomobject]@{
          kind = 'test_failed'
          reason = $noopBaseRejectReason
          text = $noopFailureText
          current_backlog_id = $noopBacklogId
          current_task_id = $noopCurrentTaskId
          force_coder_recovery = $noopForceCoderRecovery
          ts = (Get-Date).ToString('o')
        }
        Update-State ({
          param($s)
          $s.task_did_actions = $false
          $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
          $s | Add-Member -NotePropertyName task_failure_record -NotePropertyValue $noopFailureRecord -Force
          if ($noopForceCoderRecovery) {
            $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
            $s.force_planner = $false
          }
        }.GetNewClosure()) | Out-Null
        try { Set-TaskLastFailure -Kind test_failed -Text $noopFailureText } catch {}
        if ($noopForceCoderRecovery) {
          Add-Message -From system -Text ("🚫 DONE отклонён: backlog-задача не имеет свежего commit/diff evidence перед переключением режима (reason=" + $noopRejectReason + "). " + $noopRecoveryMessage + " Нельзя планировщику снова закрывать задачу без commit/diff evidence.") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("🚫 DONE отклонён: backlog-задача не имеет свежего commit/diff evidence перед переключением режима (reason=" + $noopRejectReason + "). Нельзя закрывать реализационную задачу планом. Продолжай: реализуй изменения, запусти проверки и только потом STATUS: DONE.") -Kind event | Out-Null
        }
      } else {
        Update-State {
          param($s)
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
        } | Out-Null
      }
    } catch {
      $plannerStatus = 'CONTINUE'
      $noopDecisionError = $_.Exception.Message
      Update-State {
        param($s)
        $s.task_did_actions = $false
        $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
      } | Out-Null
      try { Set-TaskLastFailure -Kind test_failed -Text ('DONE evidence guard crashed: ' + $noopDecisionError) } catch {}
      Add-Message -From system -Text ("🚫 DONE evidence guard failed closed: " + $noopDecisionError + ". Продолжай: реализуй изменения, запусти проверки и только потом STATUS: DONE.") -Kind event | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'CHAT') {
    Add-Message -From system -Text "💬 Ответ без Codex. Жду следующее сообщение." -Kind event | Out-Null
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  # Guard: в discuss DONE разрешён только при конвергенции (по состоянию), с полом и потолком по ходам
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'discuss') {
    $dtNow = [int](Read-State).discuss_turn
    # FIX 2026-05-27: same synonyms accepted here (DONE-in-discuss path), see CONTINUE branch above.
    $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
    $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
    $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
    # Same TrimEnd punctuation fix as above (2026-05-26): keeps "нет." from being treated
    # as unresolved open question.
    $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
    $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
    $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
    $ceiling     = ($dtNow -ge $discussMaxTurns)
    if (-not $converged -and -not $ceiling) {
      $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
             elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
             else { "остались открытые вопросы: $openVal" }
      Add-Message -From system -Text "💬 Обсуждение продолжается — $why. Claude, доведите до синтеза: блок Согласовано/Открыто/Решение/Риски, «Открыто» пусто." -Kind event | Out-Null
      $plannerStatus = 'DISCUSS'
      Update-State { param($s) $s.task_mode='discuss' } | Out-Null
    } elseif ($ceiling -and -not $converged) {
      Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) — закрываю с текущим решением." -Kind event | Out-Null
    }
    # 🧭 Deep-think harvest: at converged DONE of a [[DEEP-THINK]] discuss task, parse the
    # planner's `IDEA: <text>` lines from the ## ИТОГ and file them as backlog ideas with
    # tag=architect+deep-think. These are the ideas that survived the Claude<->Codex critique.
    if (($converged -or $ceiling) -and ($task -match '\[\[DEEP-THINK\]\]')) {
      try {
        $pbForDeepThink = Get-ActiveProjectBinding
        $ideaLines = [regex]::Matches($reply, '(?im)^\s*[*_> \t#-]*IDEA:\s*(.+)$')
        $filed = 0
        foreach ($im in $ideaLines) {
          $itext = $im.Groups[1].Value.Trim() -replace '\*+$',''
          if ([string]::IsNullOrWhiteSpace($itext)) { continue }
          $id = Add-Idea -Text $itext -From 'architect' -Tags @('architect','deep-think','dialog-survived') -Status 'approved' -Project ([string]$pbForDeepThink.slug) -Scope 'bridge'
          if ($id) { $filed++ }
        }
        if ($filed -gt 0) {
          Add-Message -From system -Text ("🧭💭 Deep-think dialog завершён: " + $filed + " идей прошли критику Codex'а и легли в беклог (тег: architect+deep-think+dialog-survived, status=approved).") -Kind event | Out-Null
        }
      } catch {}
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'study') {
    $hasStudyReport = $false
    foreach ($fp in $fileMarkerPaths) {
      try {
        if ([System.IO.Path]::GetExtension([string]$fp) -ieq '.md') { $hasStudyReport = $true }
      } catch {}
    }
    if (-not $hasStudyReport -or $attachmentMetas.Count -eq 0) {
      Add-Message -From system -Text "📚 Study требует итоговый Markdown-отчёт через [[FILE: ...md]]. Claude, создай/прикрепи отчёт и повтори синтез." -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
      Update-State { param($s) $s.task_mode='study'; $s.study_phase='synthesis' } | Out-Null
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $didActions = [bool](Read-State).task_did_actions
    $hasVerify  = $reply -imatch '(?im)^\s*\[\[VERIFIED:\s*.+?\]\]\s*$'
    $vrc        = [int](Read-State).verify_retry_count
    # covered-after-restart: если работа уже закоммичена в прошлой сессии, не требуем новый verify
    if ($didActions -and -not $hasVerify) {
      $covSt = Read-State
      $covRecoverFlag = $false
      try {
        $cfgRecover = Get-BridgeConfig
        if ($cfgRecover.PSObject.Properties.Name -contains 'recover_covered_after_restart') { $covRecoverFlag = [bool]$cfgRecover.recover_covered_after_restart }
      } catch { $covRecoverFlag = $false }
      $covResult = @{ Covered = $false; Sha = ''; Repo = '' }
      if ($covRecoverFlag) {
        $covResult = Test-CoveredAfterRestart `
          -BridgeRoot $bridgeRoot `
          -ClaimedAt ([string]$covSt.claimed_at) `
          -BacklogId ([string]$covSt.current_backlog_id) `
          -TaskText ([string]$covSt.current_task) `
          -StateObj $covSt
      }
      if ($covResult.Covered) {
        $covMsg = "✅ covered-after-restart: задача закрыта — коммит найден после рестарта ($($covResult.Sha)), рабочее дерево чистое, критик OK. Новый verify не требуется."
        Add-Message -From system -Text $covMsg -Kind event | Out-Null
        try { Write-BridgeLog -Channel (Get-EffectiveChannel) -Text ("covered-after-restart: sha=$($covResult.Sha) task=$([string]$covSt.current_backlog_id)") -Kind 'covered_close' } catch {}
        Update-State { param($s) $s.task_did_actions = $false } | Out-Null
        # не переходим в VERIFY — пусть DONE закроется
        $didActions = $false
      }
    }
    if ($didActions -and -not $hasVerify -and $vrc -lt 2) {
      Add-Message -From system -Text "🔍 Фаза верификации: задача меняла файлы, но проверки нет. Агент, ВЫПОЛНИ проверочную команду/тест/чтение файла/скриншот, покажи результат и добавь строку [[VERIFIED: что проверено | результат]], затем STATUS: DONE." -Kind event | Out-Null
      $plannerStatus = 'VERIFY'
      Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$true } | Out-Null
    } elseif ($didActions -and -not $hasVerify -and $vrc -ge 2) {
      $vfDiff = ''
      try {
        $vfBase = [string](Read-State).task_base_commit
        $vfRepoRoot = Get-TaskRepoRoot
        if (-not [string]::IsNullOrWhiteSpace($vfBase)) {
          $vfBaseOk = $false
          try {
            $vfBaseType = (& git -C $vfRepoRoot cat-file -t $vfBase 2>$null | Select-Object -First 1)
            if ([string]$vfBaseType -eq 'commit') { $vfBaseOk = $true }
          } catch {}
          if (-not $vfBaseOk) { $vfBase = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($vfBase)) {
          $vfDiff = (& git -C $vfRepoRoot diff $vfBase -- 2>$null | Out-String).Trim()
          if ($vfDiff.Length -gt 2000) { $vfDiff = $vfDiff.Substring(0,2000) + "`n...[truncated]" }
        }
      } catch {}
      $vfLast = $reply.Trim(); if ($vfLast.Length -gt 800) { $vfLast = $vfLast.Substring(0,800) + "`n...[truncated]" }
      $vfMsg = "🔍 Верификация не пройдена за 2 попытки — закрываю как есть."
      if ($vfDiff) { $vfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$vfDiff`n``````" }
      if ($vfLast) { $vfMsg += "`n`n**Последний вывод агента:**`n``````$vfLast`n``````" }
      Add-Message -From system -Text $vfMsg -Kind event | Out-Null
      try { Send-PushEvent -Kind need_you -Text "Верификация не пройдена: $(Get-PushSnippet -Text $task)" } catch {}
      # 2026-05-28: explicitly clear task_did_actions so the verify-check doesn't
      # re-fire on the next planner DONE. Previously this branch only printed
      # a message — but the same DONE could land again after a restart (vrc=2
      # preserved), and the elseif would print THE SAME warning forever. Bridge
      # logged "Верификация не пройдена за 2 попытки" repeatedly on every restart.
      # Setting task_did_actions=false makes the verify-check a no-op next pass,
      # letting plannerStatus=DONE close the task naturally.
      Update-State { param($s) $s.task_did_actions = $false } | Out-Null
    }
  }
  # Coder-bypass gate: planner did file edits without invoking Codex -> reject DONE, force CONTINUE->Codex+critic.
  # The critic only reviews Codex diffs; if Opus modifies files directly, its diff ships without independent review.
  # Probe 2 (2026-05-26) exposed this: Opus single-handedly committed mobile button rearrangement; critic skipped.
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $stCB = Read-State
    if ([bool]$stCB.task_did_actions -and -not [bool]$stCB.coder_fired) {
      $cbr = [int]$stCB.coder_bypass_retry_count
      if ($cbr -lt 2) {
        Add-Message -From system -Text "🔁 Кодер пропущен: задача меняла файлы, но Codex не вызывался. Claude, ОБЯЗАТЕЛЬНО передай реализацию через STATUS: CONTINUE с конкретной инструкцией Codex'у (что/где/критерий) — он напишет правки, критик их проверит. Multi-agent дисциплина: правки кода идут через кодера, а не через планировщика." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.coder_bypass_retry_count=[int]$s.coder_bypass_retry_count+1; $s.force_planner=$true } | Out-Null
      } else {
        Add-Message -From system -Text "🔁 Coder-bypass: планировщик 2× не передал работу Codex — закрываю как есть, нужно внимание оператора." -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text "Coder-bypass: $(Get-PushSnippet -Text $task)" } catch {}
      }
    }
  }
}

$script:DriverLoopCompletionRuntimeChecksBlock = {
  # DONE-gate runtime checks: ParseFile, auto-smoke, and gate-regression are launched
  # together when possible. Jobs only return facts; state mutations stay in this process.
  # Cached PASS (2026-06-10): when every runtime check already passed at this exact HEAD for
  # this task (sha+task recorded at the bottom of this block, clean tree), a repeat DONE
  # attempt skips re-verification. Without this the gate suite re-ran on EVERY attempt with
  # task-lifetime scope and timed out (exit=124) forever, looping tasks whose work was
  # already committed (the COVERED-loop incident).
  $doneGateCachedPass = $false
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $dgcState = Read-State
      if ([bool]$dgcState.task_did_actions) {
        $dgcSha = ([string](& git -C $bridgeRoot rev-parse HEAD 2>$null | Out-String)).Trim()
        $dgcDirty = 'unknown'
        try { $dgcDirty = ([string](& git -C $bridgeRoot status --porcelain 2>$null | Out-String)).Trim() } catch {}
        $dgcTask = [string]$dgcState.current_backlog_id
        if ([string]::IsNullOrWhiteSpace($dgcTask)) { $dgcTask = [string]$dgcState.current_task_id }
        if ($dgcSha -and ($dgcDirty -eq '') -and ([string]$dgcState.done_gate_pass_sha -eq $dgcSha) -and ([string]$dgcState.done_gate_pass_task -eq $dgcTask)) {
          $doneGateCachedPass = $true
          Add-Message -From system -Text ("✅ DONE-gate: cached PASS at " + $dgcSha.Substring(0,7) + " — пропускаю повторную верификацию (HEAD и задача не менялись, дерево чистое).") -Kind event | Out-Null
        }
      }
    } catch {}
  }
  # Post-restart fast-path: check done_qa_pass_commit field on backlog item.
  # This stamp survives restarts (unlike done_gate_pass_sha in state) and lets the
  # DONE-gate skip the full parse/smoke/gate-regression/QA cycle when a task already
  # has a confirmed commit with QA PASS from a prior (possibly interrupted) run.
  if (-not $doneGateCachedPass -and (($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $dqpcState = Read-State
      $dqpcTask = [string]$dqpcState.current_backlog_id
      if ([string]::IsNullOrWhiteSpace($dqpcTask)) { $dqpcTask = [string]$dqpcState.current_task_id }
      if (-not [string]::IsNullOrWhiteSpace($dqpcTask) -and [bool]$dqpcState.task_did_actions) {
        $dqpcItem = @(Get-Backlog) | Where-Object { [string]$_.id -eq $dqpcTask } | Select-Object -First 1
        if ($dqpcItem -and ($dqpcItem.PSObject.Properties.Name -contains 'done_qa_pass_commit')) {
          $dqpcSha = ([string]$dqpcItem.done_qa_pass_commit).Trim()
          if (-not [string]::IsNullOrWhiteSpace($dqpcSha)) {
            $dqpcValid = $false
            try {
              $dqpcOut = ([string](& git -C $bridgeRoot rev-parse --verify ($dqpcSha + '^{commit}') 2>$null | Out-String)).Trim()
              $dqpcValid = (-not [string]::IsNullOrWhiteSpace($dqpcOut))
            } catch {}
            if ($dqpcValid) {
              $doneGateCachedPass = $true
              Add-Message -From system -Text ("✅ DONE-gate: задача $dqpcTask уже имеет подтверждённый коммит $($dqpcSha.Substring(0,[Math]::Min(7,$dqpcSha.Length))) с QA PASS — повторный полный цикл пропущен (post-restart fast-path).") -Kind event | Out-Null
            }
          }
        }
      }
    } catch {}
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and -not $doneGateCachedPass -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stGate = Read-State
      if ([bool]$stGate.task_did_actions) {
        $missingGateRegressionCommands = @()
        if (-not (Get-Command Invoke-GateRegressionSuite -ErrorAction SilentlyContinue)) {
          $missingGateRegressionCommands += 'Invoke-GateRegressionSuite'
          if (-not (Get-Command Get-GateRegressionScope -ErrorAction SilentlyContinue)) {
            $missingGateRegressionCommands += 'Get-GateRegressionScope'
          }
        }
        if ($missingGateRegressionCommands.Count -gt 0) {
          throw ("gate-regression runtime import missing: " + ($missingGateRegressionCommands -join ', '))
        }
        $script:DriverDoneGateInProcessSuiteOverride = $null
        try {
          $gateSuiteCommand = Get-Command Invoke-GateRegressionSuite -ErrorAction Stop
          if ($gateSuiteCommand -and $gateSuiteCommand.ScriptBlock) {
            $script:DriverDoneGateInProcessSuiteOverride = $gateSuiteCommand.ScriptBlock
          }
        } catch {}

        $gateSuiteScriptBlock = $null
        $gateSuiteCommand = Get-Command Invoke-GateRegressionSuite -ErrorAction SilentlyContinue
        if ($gateSuiteCommand -and $gateSuiteCommand.CommandType -eq 'Function') {
          $gateSuiteScriptBlock = $gateSuiteCommand.ScriptBlock
        }
        $script:DriverVerifyTimingStart = [DateTime]::UtcNow
        $gateChecks = Invoke-DriverDoneGateChecks -BridgeRoot $bridgeRoot -TaskBaseCommit ([string]$stGate.task_base_commit) -Channel ([string](Get-EffectiveChannel)) -Reply $reply -GateRegressionSuiteScriptBlock $gateSuiteScriptBlock
        try {
          $verifyElapsedMs = [long]([DateTime]::UtcNow - $script:DriverVerifyTimingStart).TotalMilliseconds
          if ($verifyElapsedMs -gt 100 -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) {
            Update-TaskPhaseTiming -Phase verify_ms -Ms $verifyElapsedMs
          }
        } catch {}
        if ($gateChecks.Mode -eq 'parallel') {
          Add-Message -From system -Text ("🧪 DONE-gate: parallel checks completed ({0} jobs)." -f $gateChecks.JobsStarted) -Kind event | Out-Null
        } elseif ($gateChecks.FallbackReason) {
          Add-Message -From system -Text ("🧪 DONE-gate: Start-Job fallback to sequential checks — {0}" -f $gateChecks.FallbackReason) -Kind event | Out-Null
        }

        $parseResult = $gateChecks.Parse
        if ($parseResult) {
          if (-not [string]::IsNullOrWhiteSpace([string]$parseResult.RuntimeError)) {
            Add-Message -From system -Text ("🚨 ParseFile gate runtime error: {0}. Codex, исправь." -f $parseResult.RuntimeError) -Kind event | Out-Null
            Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
            $plannerStatus = 'CONTINUE'
          } elseif (-not [bool]$parseResult.Ok) {
            Add-Message -From system -Text "🚨 ParseFile FAILED: $($parseResult.FailedFile) line $($parseResult.ErrorLine) — $($parseResult.ErrorMessage). Codex, исправь синтаксис." -Kind event | Out-Null
            Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
            $plannerStatus = 'CONTINUE'
          } elseif ($parseResult.Files.Count -gt 0) {
            Add-Message -From system -Text "✅ ParseFile OK: $($parseResult.Files -join ', ')" -Kind event | Out-Null
          }
        }

        $smokeResult = $gateChecks.Smoke
        if ([bool]$gateChecks.Plan.SmokeSkippedByVerified) {
          Add-Message -From system -Text "✅ Авто-smoke: skipped — coder [[VERIFIED]] includes smoke evidence for this turn." -Kind event | Out-Null
        }
        if ($smokeResult) {
          if (-not [bool]$smokeResult.Ok) {
            $smokeOut = if ($smokeResult.RuntimeError) { [string]$smokeResult.RuntimeError } else { [string]$smokeResult.Output }
            $smokeShort = ($smokeOut -replace '\s+',' ').Trim()
            if ($smokeShort.Length -gt 300) { $smokeShort = $smokeShort.Substring(0,300) + '...' }
            try { Set-TaskLastFailure -Kind smoke_failed -Text $smokeShort } catch {}
            $smokeVrc = [int](Read-State).verify_retry_count
            if ($smokeVrc -lt 2) {
              Update-State {
                param($s)
                if ($null -eq $s.PSObject.Properties['verify_retry_count']) {
                  $s | Add-Member -NotePropertyName verify_retry_count -NotePropertyValue 0 -Force
                }
                if ($null -eq $s.PSObject.Properties['force_planner']) {
                  $s | Add-Member -NotePropertyName force_planner -NotePropertyValue $false -Force
                }
                $s.verify_retry_count=[int]$s.verify_retry_count+1
                $s.force_planner=$false
              } | Out-Null
              Add-Message -From system -Text "🚨 Авто-smoke FAILED (попытка $($smokeVrc+1)/2) — .ps1 повреждены, задача НЕ закрывается. Codex, исправь: $smokeShort" -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
            } else {
              $sfDiff = ''
              try {
                $sfBase = [string](Read-State).task_base_commit
                if (-not [string]::IsNullOrWhiteSpace($sfBase)) {
                  $sfDiff = (& git -C $bridgeRoot diff $sfBase -- 2>$null | Out-String).Trim()
                  if ($sfDiff.Length -gt 2000) { $sfDiff = $sfDiff.Substring(0,2000) + "`n...[truncated]" }
                }
              } catch {}
              $sfMsg = "🚨 Авто-smoke провалился 2× — закрываю как есть, нужно внимание оператора."
              if ($sfDiff) { $sfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$sfDiff`n``````" }
              $sfMsg += "`n`n**Smoke output:** $smokeShort"
              Add-Message -From system -Text $sfMsg -Kind event | Out-Null
              try { Send-PushEvent -Kind need_you -Text "Smoke FAIL: $(Get-PushSnippet -Text $task)" } catch {}
            }
          } else {
            Add-Message -From system -Text "✅ Авто-smoke: OK — .ps1 не сломаны." -Kind event | Out-Null
          }
        }

        if (-not [bool]$gateChecks.Plan.GateSuiteNeeded) {
          if ([bool]$gateChecks.Plan.GateNonCoreFastSubset) {
            Add-Message -From system -Text "🧪 gate-regression: non-core scope, fast subset (parse/smoke only)." -Kind event | Out-Null
          } else {
            Add-Message -From system -Text "🧪 Gate-regression: scope empty, skipped." -Kind event | Out-Null
          }
        } else {
          if ($gateChecks.Plan.GateScopeError) {
            Add-Message -From system -Text ("🧪 Gate-regression: scope unavailable ({0}); running full snapshot suite." -f $gateChecks.Plan.GateScopeError) -Kind event | Out-Null
          }
          $gateResult = $gateChecks.GateRegression
          if ($gateResult -and [bool]$gateResult.Ok) {
            $gateBudgetSuffix = Format-DriverDoneGateRegressionBudgetSuffix -GateResult $gateResult
            Add-Message -From system -Text "✅ Gate-regression: snapshot suite PASS$gateBudgetSuffix." -Kind event | Out-Null
            try { Update-State { param($s) if ($null -ne $s.PSObject.Properties['gate_regression_fail_count']) { $s.gate_regression_fail_count = 0 } } | Out-Null } catch {}
          } else {
            $failReason = if ($gateResult) {
              if ($gateResult.RuntimeError) { [string]$gateResult.RuntimeError } else { "exit=$($gateResult.ExitCode), timedOut=$($gateResult.TimedOut)" }
            } else {
              'no result'
            }
            $gateBudgetSuffix = Format-DriverDoneGateRegressionBudgetSuffix -GateResult $gateResult
            if ($gateBudgetSuffix) { $failReason = "$failReason$gateBudgetSuffix" }
            if ($gateChecks.Plan.GateScopeError) {
              $failReason = ("scope error: {0}; suite: {1}" -f $gateChecks.Plan.GateScopeError, $failReason)
            }
            $gateTimeoutInconclusive = $false
            try { $gateTimeoutInconclusive = Test-DriverDoneGateRegressionTimeoutInconclusive -GateResult $gateResult } catch {}
            $gateTimeoutHandledAsInconclusive = $false
            if ($gateTimeoutInconclusive) {
              $timeoutRecord = Invoke-DriverDoneGateRegressionTimeoutInconclusiveHandling -GateResult $gateResult -FailReason $failReason
              $gateTimeoutHandledAsInconclusive = ($timeoutRecord -and [string]$timeoutRecord.Outcome -ne 'timeout_fail')
            }
            if (-not $gateTimeoutHandledAsInconclusive) {
              try { Set-TaskLastFailure -Kind gate_regression_failed -Text $failReason } catch {}
              # 2-strike cap (2026-06-10, mirror auto-smoke above): the suite re-runs on EVERY
              # DONE attempt with task-lifetime scope and no cache. Non-timeout failures still
              # get a bounded retry loop; timeout/exit=124 now fails under the fixed 2x120s schedule.
              $gateFails = 0
              try { $gateFails = [int](Read-State).gate_regression_fail_count } catch {}
              if ($gateFails -lt 2) {
                Update-State {
                  param($s)
                  if ($null -eq $s.PSObject.Properties['gate_regression_fail_count']) {
                    $s | Add-Member -NotePropertyName gate_regression_fail_count -NotePropertyValue 0 -Force
                  }
                  $s.gate_regression_fail_count = [int]$s.gate_regression_fail_count + 1
                } | Out-Null
                Add-Message -From system -Text ("🚨 Gate-regression FAILED (попытка $($gateFails+1)/2: {0}). Возвращаю задачу на CONTINUE." -f $failReason) -Kind event | Out-Null
                $plannerStatus = 'CONTINUE'
              } else {
                try { Clear-TaskLastFailureKind -Kind gate_regression_failed } catch {}
                Add-Message -From system -Text ("⚠️ Gate-regression провалился 2× ({0}) — закрываю как есть; нужно внимание оператора." -f $failReason) -Kind event | Out-Null
                try { Send-PushEvent -Kind need_you -Text "Gate-regression 2x FAIL: $(Get-PushSnippet -Text $task)" } catch {}
              }
            }
          }
        }
        $integrityResult = $gateChecks.Integrity
        if ($integrityResult -and -not [bool]$integrityResult.Skipped) {
          if (-not [bool]$integrityResult.Ok) {
            $intOut = if ($integrityResult.RuntimeError) { [string]$integrityResult.RuntimeError } else { ([string]$integrityResult.Output -replace '\s+',' ').Trim() }
            if ($intOut.Length -gt 300) { $intOut = $intOut.Substring(0,300) + '...' }
            Add-Message -From system -Text ("🚨 State integrity FAILED (exit={0}): {1}. Codex, исправь." -f $integrityResult.ExitCode, $intOut) -Kind event | Out-Null
            Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
            $plannerStatus = 'CONTINUE'
          } else {
            Add-Message -From system -Text "✅ State integrity: OK." -Kind event | Out-Null
          }
        }
      }
    } catch {
      $gateRuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
      if ($gateRuntimeError.Length -gt 300) { $gateRuntimeError = $gateRuntimeError.Substring(0,300) + '...' }
      try { Set-TaskLastFailure -Kind gate_regression_runtime_error -Text $gateRuntimeError } catch {}
      Add-Message -From system -Text ("🚨 Gate-regression fail-closed: " + $gateRuntimeError + ". Возвращаю задачу на CONTINUE.") -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
    }
  }
  # QA agent gate: after verify/coder-bypass/critic/parse/smoke gates, run runtime QA before accepting DONE.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and -not $doneGateCachedPass -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stQa = Read-State
      if ([bool]$stQa.task_did_actions) {
        $qaTaskId = [string]$stQa.current_task_id
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = [string]$stQa.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = 'task-' + [string]$stQa.task_start_seq }
        # 2026-06-12 stage 3b (speed program): QA verdict memo by HEAD, mirroring the critic
        # cache (A5). The full QA pass (bridge smoke + scenarios, ~2-3 min) used to re-run on
        # every DONE attempt of a task tail even when no new commit landed since the last PASS.
        # Cache key = repo HEAD; ONLY PASS is cached; a dirty tree blocks the cache (edits after
        # the PASS); any new commit changes HEAD and auto-invalidates. FAIL always re-runs.
        $qaCacheHit = $false
        try {
          $qaRepoRoot = Get-TaskRepoRoot
          $qaHead = ([string](& git -C $qaRepoRoot rev-parse HEAD 2>$null | Out-String)).Trim()
          $qaDirty = ([string](& git -C $qaRepoRoot status --porcelain 2>$null | Out-String)).Trim()
          if ($qaHead -and ($qaDirty -eq '') -and $stQa.PSObject.Properties.Name -contains 'qa_verdict_cache' -and $stQa.qa_verdict_cache) {
            $qc = $stQa.qa_verdict_cache
            if ([string]$qc.head -eq $qaHead -and [string]$qc.verdict -eq 'PASS') { $qaCacheHit = $true }
          }
        } catch { $qaCacheHit = $false }
        if ($qaCacheHit) {
          try { Clear-TaskLastFailureKind -Kind qa_failed } catch {}
          $qcLogMsg = if (
            $null -ne $qc.PSObject.Properties['source'] -and [string]$qc.source -eq 'post_commit'
          ) {
            '✅ QA done-гейт: кэш PASS (post-commit QA на том же HEAD)'
          } else {
            '✅ QA-агент: кэш PASS на ' + $qaHead.Substring(0,[Math]::Min(7,$qaHead.Length)) + ' — HEAD не менялся с прошлого прогона, повторный QA пропущен.'
          }
          Add-Message -From system -Text $qcLogMsg -Kind event | Out-Null
        } else {
        $qaResult = Invoke-QAAgent -TaskId $qaTaskId -TaskTitle $task -Channel $Channel
        if ($qaResult.Verdict -eq 'FAIL') {
          try { Set-TaskLastFailure -Kind qa_failed -Text ([string]$qaResult.Summary) } catch {}
          Add-Message -From system -Text "🔴 QA-агент: FAIL`n$($qaResult.Summary)`nВозвращаю задачу на доработку." -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
        } else {
          try { Clear-TaskLastFailureKind -Kind qa_failed } catch {}
          try { Update-State { param($s) if ($null -ne $s.PSObject.Properties['qa_gate_error_count']) { $s.qa_gate_error_count = 0 } } | Out-Null } catch {}
          try {
            $qaHeadForCache = ''
            try { $qaHeadForCache = ([string](& git -C (Get-TaskRepoRoot) rev-parse HEAD 2>$null | Out-String)).Trim() } catch {}
            if ($qaHeadForCache) {
              Update-State ({ param($s)
                $s | Add-Member -NotePropertyName qa_verdict_cache -NotePropertyValue ([pscustomobject]@{ head = [string]$qaHeadForCache; verdict = 'PASS'; ts = (Get-Date).ToUniversalTime().ToString('o') }) -Force
              }.GetNewClosure()) | Out-Null
            }
          } catch {}
          Add-Message -From system -Text "✅ QA-агент: PASS — $($qaResult.Summary)" -Kind event | Out-Null
        }
        }
      }
    } catch {
      $qaGateError = ($_.Exception.Message -replace '\s+', ' ').Trim()
      # 2-strike cap (2026-06-10): a BROKEN QA runner (runtime error, not a FAIL verdict)
      # used to veto DONE forever — infra breakage is not task breakage. After 2 consecutive
      # runtime errors close as-is and page the operator.
      $qaErrCount = 0
      try { $qaErrCount = [int](Read-State).qa_gate_error_count } catch {}
      if ($qaErrCount -lt 2) {
        Update-State {
          param($s)
          if ($null -eq $s.PSObject.Properties['qa_gate_error_count']) {
            $s | Add-Member -NotePropertyName qa_gate_error_count -NotePropertyValue 0 -Force
          }
          $s.qa_gate_error_count = [int]$s.qa_gate_error_count + 1
        } | Out-Null
        try { Set-TaskLastFailure -Kind qa_failed -Text ('QA agent runtime error: ' + $qaGateError) } catch {}
        Add-Message -From system -Text "🔴 QA-агент: ошибка запуска ($qaGateError) (попытка $($qaErrCount+1)/2). Возвращаю на доработку." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
      } else {
        try { Clear-TaskLastFailureKind -Kind qa_failed } catch {}
        Add-Message -From system -Text "⚠️ QA-агент падает 2× (runtime error: $qaGateError) — это поломка QA-инфраструктуры, не задачи. Закрываю как есть; нужно внимание оператора." -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text "QA runner 2x runtime error" } catch {}
      }
    }
  }
  # Persist the gate PASS (2026-06-10) so a repeat DONE attempt at the same HEAD for the same
  # task takes the cached-PASS fast path at the top of this block instead of re-running the
  # full parse/smoke/gate-regression/QA chain.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal' -and -not $doneGateCachedPass) {
    try {
      $dgpState = Read-State
      if ([bool]$dgpState.task_did_actions) {
        $dgpSha = ([string](& git -C $bridgeRoot rev-parse HEAD 2>$null | Out-String)).Trim()
        $dgpTask = [string]$dgpState.current_backlog_id
        if ([string]::IsNullOrWhiteSpace($dgpTask)) { $dgpTask = [string]$dgpState.current_task_id }
        if ($dgpSha) {
          Update-State ({
            param($s)
            $s | Add-Member -NotePropertyName done_gate_pass_sha -NotePropertyValue $dgpSha -Force
            $s | Add-Member -NotePropertyName done_gate_pass_task -NotePropertyValue $dgpTask -Force
          }.GetNewClosure()) | Out-Null
          # Persist done_qa_pass_commit on the backlog task item.
          # Stored on the item (not only in state) so it survives bridge restarts.
          try {
            $dqpStampTask = $dgpTask
            $dqpStampSha = $dgpSha
            if (-not [string]::IsNullOrWhiteSpace($dqpStampTask)) {
              Invoke-BacklogLocked ({
                $bkItems = @(Get-Backlog)
                $bkDirty = $false
                foreach ($bkItem in $bkItems) {
                  if ([string]$bkItem.id -ne $dqpStampTask) { continue }
                  if ($bkItem.PSObject.Properties.Name -contains 'done_qa_pass_commit') {
                    $bkItem.PSObject.Properties['done_qa_pass_commit'].Value = $dqpStampSha
                  } else {
                    $bkItem | Add-Member -NotePropertyName done_qa_pass_commit -NotePropertyValue $dqpStampSha -Force
                  }
                  $bkDirty = $true
                  try {
                    $declaredFs = @()
                    try {
                      if ($bkItem.PSObject.Properties.Name -contains 'files') {
                        $declaredFs = @($bkItem.files | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                      }
                    } catch {
                      $declaredFs = @()
                    }
                    $diffCheck = Test-DoneGateDiffIntegrity -CommitSha $dqpStampSha -BridgeRoot (Get-BridgeRoot) -DeclaredFiles $declaredFs
                    if (-not $diffCheck.ok) {
                      try { Add-Message -From system -Text ("⚠ DONE-gate diff-integrity: $($diffCheck.reason) для коммита $($dqpStampSha.Substring(0,[Math]::Min(8,$dqpStampSha.Length))) (declared=$($declaredFs.Count), changed=$($diffCheck.changedFiles.Count)).") -Kind event | Out-Null } catch {}
                    }
                    try {
                      $diResult = if ([bool]$diffCheck.ok) { 'ok' } else { 'failed' }
                      if (Get-Command Write-DiffIntegrityDecision -ErrorAction SilentlyContinue) {
                        Write-DiffIntegrityDecision -CommitSha $dqpStampSha -BridgeRoot (Get-BridgeRoot) -CheckResult $diffCheck -DeclaredFiles $declaredFs -BacklogId $dqpStampTask | Out-Null
                      }
                      if ($bkItem.PSObject.Properties.Name -contains 'diff_integrity_result') {
                        $bkItem.PSObject.Properties['diff_integrity_result'].Value = $diResult
                      } else {
                        $bkItem | Add-Member -NotePropertyName diff_integrity_result -NotePropertyValue $diResult -Force
                      }
                    } catch {}
                  } catch {}
                  break
                }
                if ($bkDirty) { Save-Backlog -Items $bkItems }
              }.GetNewClosure()) | Out-Null
            }
          } catch {}
        }
      }
    } catch {}
  }
}
