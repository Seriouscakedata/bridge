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
    $baseType = [string]((Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('cat-file','-t',$TaskBaseCommit) -Description 'cat-file task_base_commit' | Select-Object -First 1) -join '')
    if ($baseType.Trim() -ne 'commit') {
      throw ("git task_base_commit is not a commit: {0}" -f $TaskBaseCommit)
    }
    foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('diff','--name-only',$TaskBaseCommit,'HEAD') -Description 'diff task_base_commit..HEAD')) {
      & $addPath $p
    }
  }

  foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('diff','--name-only','--cached') -Description 'diff --cached')) {
    & $addPath $p
  }
  foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('diff','--name-only') -Description 'diff working tree')) {
    & $addPath $p
  }
  foreach ($p in @(Invoke-DriverDoneGateGitLines -BridgeRoot $BridgeRoot -Arguments @('ls-files','--others','--exclude-standard') -Description 'ls-files untracked')) {
    & $addPath $p
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
  if (-not (Get-Command Get-GateRegressionScope -ErrorAction SilentlyContinue)) {
    throw 'gate-regression runtime import missing: Get-GateRegressionScope'
  } else {
    try {
      $gateScope = @(Get-GateRegressionScope -ChangedPaths @($changedPaths))
      $gateSuiteNeeded = ($gateScope.Count -gt 0)
    } catch {
      $gateScopeError = ($_.Exception.Message -replace '\s+',' ').Trim()
      throw ("gate-regression scope failed: " + $gateScopeError)
    }
  }

  $jobs = New-Object 'System.Collections.Generic.List[string]'
  if ($parseFiles.Count -gt 0) { [void]$jobs.Add('parse') }
  if ($smokeNeeded) { [void]$jobs.Add('smoke') }
  if ($gateSuiteNeeded) { [void]$jobs.Add('gate-regression') }

  return [pscustomobject][ordered]@{
    ChangedPaths = @($changedPaths)
    PsFiles = @($psFiles)
    ParseFiles = @($parseFiles)
    SmokeNeeded = [bool]$smokeNeeded
    SmokeSkippedByVerified = [bool]$smokeSkippedByVerified
    GateScope = @($gateScope)
    GateScopeError = $gateScopeError
    GateSuiteNeeded = [bool]$gateSuiteNeeded
    JobNames = @($jobs.ToArray())
  }
}

$script:DriverDoneGateParseJob = {
  param([string]$BridgeRoot, [string[]]$ParseFiles)
  $result = [ordered]@{ Name='parse'; Skipped=$false; Ok=$true; Files=@($ParseFiles); FailedFile=''; ErrorLine=0; ErrorMessage=''; RuntimeError='' }
  try {
    foreach ($psf in @($ParseFiles)) {
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
    $result.Ok = ($result.Output -imatch 'SMOKE OK')
  } catch {
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
}

$script:DriverDoneGateRegressionJob = {
  param([string]$BridgeRoot, [string[]]$ChangedPaths, [bool]$UseChangedPathScope)
  $result = [ordered]@{ Name='gate-regression'; Skipped=$false; Ok=$false; ExitCode=1; TimedOut=$false; Attempts=0; RuntimeError=''; Scope=@(); ScopeApplied=$UseChangedPathScope }
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
    for ($gateAttempt = 1; $gateAttempt -le 2; $gateAttempt++) {
      $result.Attempts = $gateAttempt
      if ($UseChangedPathScope) {
        if ($inProcessSuite) {
          $gateResult = & $inProcessSuite -BridgeRoot $BridgeRoot -TimeoutSec 180 -ChangedPaths @($ChangedPaths)
        } else {
          $gateResult = Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec 180 -ChangedPaths @($ChangedPaths)
        }
      } else {
        if ($inProcessSuite) {
          $gateResult = & $inProcessSuite -BridgeRoot $BridgeRoot -TimeoutSec 180
        } else {
          $gateResult = Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec 180
        }
      }
      if ($gateResult) {
        $result.ExitCode = [int]$gateResult.ExitCode
        $result.TimedOut = [bool]$gateResult.TimedOut
        $result.Scope = @($gateResult.Scope)
      }
      if ($gateResult -and [bool]$gateResult.Ok) {
        $result.Ok = $true
        break
      }
    }
  } catch {
    $result.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
  }
  [pscustomobject]$result
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
  if ($Plan.ParseFiles.Count -gt 0) {
    $parseResult = & $script:DriverDoneGateParseJob $BridgeRoot @($Plan.ParseFiles)
  }
  if ([bool]$Plan.SmokeNeeded) {
    $smokeResult = & $script:DriverDoneGateSmokeJob (Join-Path $BridgeRoot 'smoke.ps1') $Channel
  }
  if ([bool]$Plan.GateSuiteNeeded) {
    $useScope = [string]::IsNullOrWhiteSpace([string]$Plan.GateScopeError)
    $gateResult = [ordered]@{ Name='gate-regression'; Skipped=$false; Ok=$false; ExitCode=1; TimedOut=$false; Attempts=0; RuntimeError=''; Scope=@(); ScopeApplied=$useScope }
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
      for ($gateAttempt = 1; $gateAttempt -le 2; $gateAttempt++) {
        $gateResult.Attempts = $gateAttempt
        if ($useScope) {
          if ($GateRegressionSuiteScriptBlock) {
            $rawGateResult = & $GateRegressionSuiteScriptBlock -BridgeRoot $BridgeRoot -TimeoutSec 180 -ChangedPaths @($Plan.ChangedPaths)
          } else {
            $rawGateResult = Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec 180 -ChangedPaths @($Plan.ChangedPaths)
          }
        } else {
          if ($GateRegressionSuiteScriptBlock) {
            $rawGateResult = & $GateRegressionSuiteScriptBlock -BridgeRoot $BridgeRoot -TimeoutSec 180
          } else {
            $rawGateResult = Invoke-GateRegressionSuite -BridgeRoot $BridgeRoot -TimeoutSec 180
          }
        }
        if ($rawGateResult) {
          $gateResult.ExitCode = [int]$rawGateResult.ExitCode
          $gateResult.TimedOut = [bool]$rawGateResult.TimedOut
          $gateResult.Scope = @($rawGateResult.Scope)
        }
        if ($rawGateResult -and [bool]$rawGateResult.Ok) {
          $gateResult.Ok = $true
          break
        }
      }
    } catch {
      $gateResult.RuntimeError = ($_.Exception.Message -replace '\s+',' ').Trim()
    }
    $gateResult = [pscustomobject]$gateResult
  }

  return [pscustomobject][ordered]@{
    Mode = 'sequential'
    FallbackReason = ''
    Plan = $Plan
    JobsStarted = 0
    Parse = $parseResult
    Smoke = $smokeResult
    GateRegression = $gateResult
  }
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
    return [pscustomobject][ordered]@{ Mode='none'; FallbackReason=''; Plan=$plan; JobsStarted=0; Parse=$null; Smoke=$null; GateRegression=$null }
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

    if ($startedJobs.Count -gt 0) {
      Wait-Job -Job @($startedJobs.Values) | Out-Null
    }

    $results = @{}
    foreach ($key in @($startedJobs.Keys)) {
      $received = @(Receive-Job -Job $startedJobs[$key] -ErrorAction SilentlyContinue)
      if ($received.Count -gt 0) {
        $results[$key] = $received[$received.Count - 1]
      }
      Remove-Job -Job $startedJobs[$key] -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject][ordered]@{
      Mode = 'parallel'
      FallbackReason = ''
      Plan = $plan
      JobsStarted = [int]$startedJobs.Count
      Parse = $(if ($results.ContainsKey('parse')) { $results['parse'] } else { $null })
      Smoke = $(if ($results.ContainsKey('smoke')) { $results['smoke'] } else { $null })
      GateRegression = $(if ($results.ContainsKey('gate-regression')) { $results['gate-regression'] } else { $null })
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

$script:DriverLoopCompletionInitialChecksBlock = {
  $plannerStatus = 'CONTINUE'
  $fastLaneDone = $false
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
      if ($modeBeforeIncrement -eq 'discuss') {
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
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
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
        $gateChecks = Invoke-DriverDoneGateChecks -BridgeRoot $bridgeRoot -TaskBaseCommit ([string]$stGate.task_base_commit) -Channel ([string](Get-EffectiveChannel)) -Reply $reply -GateRegressionSuiteScriptBlock $gateSuiteScriptBlock
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
          Add-Message -From system -Text "🧪 Gate-regression: scope empty, skipped." -Kind event | Out-Null
        } else {
          if ($gateChecks.Plan.GateScopeError) {
            Add-Message -From system -Text ("🧪 Gate-regression: scope unavailable ({0}); running full snapshot suite." -f $gateChecks.Plan.GateScopeError) -Kind event | Out-Null
          }
          $gateResult = $gateChecks.GateRegression
          if ($gateResult -and [bool]$gateResult.Ok) {
            Add-Message -From system -Text "✅ Gate-regression: snapshot suite PASS." -Kind event | Out-Null
          } else {
            $failReason = if ($gateResult) {
              if ($gateResult.RuntimeError) { [string]$gateResult.RuntimeError } else { "exit=$($gateResult.ExitCode), timedOut=$($gateResult.TimedOut)" }
            } else {
              'no result'
            }
            if ($gateChecks.Plan.GateScopeError) {
              $failReason = ("scope error: {0}; suite: {1}" -f $gateChecks.Plan.GateScopeError, $failReason)
            }
            try { Set-TaskLastFailure -Kind gate_regression_failed -Text $failReason } catch {}
            Add-Message -From system -Text ("🚨 Gate-regression FAILED after retry ({0}). Gate/control-plane scope is fail-closed; возвращаю задачу на CONTINUE." -f $failReason) -Kind event | Out-Null
            $plannerStatus = 'CONTINUE'
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
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stQa = Read-State
      if ([bool]$stQa.task_did_actions) {
        $qaTaskId = [string]$stQa.current_task_id
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = [string]$stQa.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = 'task-' + [string]$stQa.task_start_seq }
        $qaResult = Invoke-QAAgent -TaskId $qaTaskId -TaskTitle $task -Channel $Channel
        if ($qaResult.Verdict -eq 'FAIL') {
          try { Set-TaskLastFailure -Kind qa_failed -Text ([string]$qaResult.Summary) } catch {}
          Add-Message -From system -Text "🔴 QA-агент: FAIL`n$($qaResult.Summary)`nВозвращаю задачу на доработку." -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
        } else {
          try { Clear-TaskLastFailureKind -Kind qa_failed } catch {}
          Add-Message -From system -Text "✅ QA-агент: PASS — $($qaResult.Summary)" -Kind event | Out-Null
        }
      }
    } catch {
      $qaGateError = ($_.Exception.Message -replace '\s+', ' ').Trim()
      try { Set-TaskLastFailure -Kind qa_failed -Text ('QA agent runtime error: ' + $qaGateError) } catch {}
      Add-Message -From system -Text "🔴 QA-агент: ошибка запуска ($qaGateError). Задача НЕ закрывается; возвращаю на доработку." -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
    }
  }
}
