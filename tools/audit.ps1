# audit.ps1 -- main bridge audit orchestrator.
# Runs security + functional auditors back-to-back, merges findings into a single
# daily report (JSON + Markdown), and feeds critical issues into the backlog.
# Designed to be invoked from tools/audit-runner.ps1 during idle windows.

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$script:AuditToolsRoot = $PSScriptRoot

# Audit implementation modules. Keep this orchestrator focused on Invoke-BridgeAudit.
. (Join-Path $script:AuditToolsRoot 'audit_modules\00-context-paths.ps1')
. (Join-Path $script:AuditToolsRoot 'audit_modules\10-lock-io.ps1')
. (Join-Path $script:AuditToolsRoot 'audit_modules\20-findings-ledger.ps1')
. (Join-Path $script:AuditToolsRoot 'audit_modules\30-usefulness-reports.ps1')
. (Join-Path $script:AuditToolsRoot 'audit_modules\40-backlog.ps1')
. (Join-Path $script:AuditToolsRoot 'audit_modules\90-wait-idle.ps1')

function Invoke-BridgeAudit {
  # 2026-05-28:
  #   -Channel          pick the channel the user is on; resolved to project_root via
  #                     Get-EffectiveProjectRoot. If empty, falls back to the pinned
  #                     (or 'main' / bridge) channel. The deep-audit phase scopes
  #                     codex.exe and claude.exe to that project_root.
  #   -ProjectRoot      override the auto-resolved project_root (escape hatch).
  #   -FunctionalAgent  functional-pass selector forwarded to deep-audit:
  #                     'gemini-only' (DEFAULT, 2026-05-28 A/B winner)
  #                     'auto'        — legacy claude.exe-primary path.
  param(
    [string]$BridgePath = $null,
    [string]$Channel = $null,
    [string]$ProjectRoot = $null,
    [int]$DeepAuditTimeoutSec = 420,
    [ValidateSet('auto','gemini-only')]
    [string]$FunctionalAgent = 'gemini-only'
  )
  if ($DeepAuditTimeoutSec -lt 1) { $DeepAuditTimeoutSec = 1 }
  $root = Get-AuditBridgeRoot -Hint $BridgePath
  try {
    $commonLib = Join-Path $root 'lib\common.ps1'
    if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
  } catch {}
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

  # Resolve target project root: explicit -ProjectRoot > Get-EffectiveScope($Channel).project_root > $root.
  $resolvedProject = $root
  $projectResolved = $false
  $resolvedChannel = if (-not [string]::IsNullOrWhiteSpace($Channel)) { $Channel } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if (Test-Path -LiteralPath $ProjectRoot -PathType Container) {
      try { $resolvedProject = [System.IO.Path]::GetFullPath($ProjectRoot) } catch { $resolvedProject = $ProjectRoot }
      $projectResolved = $true
    }
  } else {
    try {
      $commonLib = Join-Path $root 'lib\common.ps1'
      if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
      if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
          $resolvedChannel = [string](Get-EffectiveChannel)
        }
        $pr = ''
        try {
          $scope = Get-EffectiveScope -Slug $resolvedChannel
          $pr = [string]$scope.project_root
        } catch {}
        if (-not [string]::IsNullOrWhiteSpace($pr) -and (Test-Path -LiteralPath $pr -PathType Container)) {
          try { $resolvedProject = [System.IO.Path]::GetFullPath($pr) } catch { $resolvedProject = $pr }
          $projectResolved = $true
        }
      } elseif (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
          $resolvedChannel = [string](Get-EffectiveChannel)
        }
        $pr = ''
        try { $pr = [string](Get-EffectiveProjectRoot -Slug $resolvedChannel) } catch {}
        if (-not [string]::IsNullOrWhiteSpace($pr) -and (Test-Path -LiteralPath $pr -PathType Container)) {
          try { $resolvedProject = [System.IO.Path]::GetFullPath($pr) } catch { $resolvedProject = $pr }
          $projectResolved = $true
        }
      }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
    try { $resolvedChannel = [string](Get-EffectiveChannel) } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($resolvedChannel)) { $resolvedChannel = 'main' }
  $resolvedChannel = Normalize-AuditChannelSlug -Channel $resolvedChannel
  if ($resolvedChannel -ne 'main' -and -not $projectResolved) { $resolvedProject = '' }
  $auditCtx = New-AuditContext -BridgePath $root -Channel $resolvedChannel -ProjectRoot $resolvedProject
  $reportDir = [string]$auditCtx.report_root
  try { if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null } } catch {}

  # 1. lock
  $existing = Test-AuditLock -BridgePath $root
  if ($existing) {
    Write-AuditLog -BridgePath $root -Message "audit already running under PID $existing; abort"
    return @{ status = 'locked'; pid = $existing }
  }
  New-AuditLock -BridgePath $root
  $scopeLabel = "kind=$($auditCtx.kind) channel=$($auditCtx.channel) target=$($auditCtx.target_root)"
  Write-AuditLog -BridgePath $root -Message "audit start (root=$root, pid=$PID, scope=$scopeLabel)"
  # 2026-05-30: surface audit lifecycle in the chat so the user can SEE it run/finish
  # (previously the audit only wrote audit.log -> invisible in the UI).
  try { if (Get-Command Add-Message -ErrorAction SilentlyContinue) { [void](Add-Message -From system -Text '🔍 Аудит запущен (статика + deep multi-agent)…' -Kind event) } } catch {}
  # Collect telemetry signals before LLM agents (incident/speed/cost slices).
  try {
    $sigScript = Join-Path $PSScriptRoot 'audit-signals.ps1'
    if (Test-Path -LiteralPath $sigScript -PathType Leaf) {
      $sigPowerShell = Join-Path $PSHOME 'powershell.exe'
      if (-not (Test-Path -LiteralPath $sigPowerShell -PathType Leaf)) { throw "powershell.exe not found under PSHOME: $PSHOME" }
      $sigJob = $null
      try {
        $sigJob = Start-Job -ScriptBlock {
          param($PowerShellPath, $ScriptPath, $BridgeRoot)
          $output = & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -BridgePath $BridgeRoot -WindowHours 24 2>&1
          $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
          [pscustomobject]@{
            ExitCode = $exitCode
            Output = @($output | ForEach-Object { [string]$_ })
          }
        } -ArgumentList $sigPowerShell, $sigScript, $root

        if (-not (Wait-Job -Job $sigJob -Timeout 30)) {
          Stop-Job -Job $sigJob -ErrorAction SilentlyContinue
          Write-AuditLog -BridgePath $root -Message "signal-collector timeout after 30s; job stopped"
        } else {
          $sigResult = @(Receive-Job -Job $sigJob -ErrorAction SilentlyContinue)
          if ($sigResult.Count -gt 0) {
            $sigExitCode = [int]$sigResult[-1].ExitCode
            $sigText = (@($sigResult[-1].Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
          } else {
            $sigExitCode = 1
            $sigText = 'no output from signal collector job'
          }
          if ($sigExitCode -eq 0) {
            Write-AuditLog -BridgePath $root -Message "signals: $sigText"
          } else {
            Write-AuditLog -BridgePath $root -Message "signal-collector exit=${sigExitCode}: $sigText"
          }
        }
      } finally {
        if ($sigJob) { Remove-Job -Job $sigJob -Force -ErrorAction SilentlyContinue }
      }
    }
  } catch { Write-AuditLog -BridgePath $root -Message "signal-collector error: $_" }

  $errors = New-Object 'System.Collections.Generic.List[string]'
  $allFindings = New-Object 'System.Collections.Generic.List[object]'
  $secFindings = @()
  $fncFindings = @()
  try {
    # 5. security audit
    $sec = Invoke-AuditSubcomponent -BridgePath $root -ScriptName 'audit-security.ps1' -EntryFunction 'Invoke-SecurityAudit' -TargetRoot ([string]$auditCtx.target_root) -AuditKind ([string]$auditCtx.kind)
    if ($sec.error) { [void]$errors.Add("security: $($sec.error)") }
    foreach ($f in @($sec.findings)) {
      $norm = Format-AuditFindings -Source 'security' -Raw $f
      $secFindings += ,$norm
      [void]$allFindings.Add($norm)
    }

    # 6. functional audit
    $fnc = Invoke-AuditSubcomponent -BridgePath $root -ScriptName 'audit-functional.ps1' -EntryFunction 'Invoke-FunctionalAudit' -TargetRoot ([string]$auditCtx.target_root) -AuditKind ([string]$auditCtx.kind)
    if ($fnc.error) { [void]$errors.Add("functional: $($fnc.error)") }
    foreach ($f in @($fnc.findings)) {
      $norm = Format-AuditFindings -Source 'functional' -Raw $f
      $fncFindings += ,$norm
      [void]$allFindings.Add($norm)
    }

    $mergedFindings = Merge-AuditFindings -Findings $allFindings.ToArray()
    # findings-ledger suppresses known open findings while keeping critical/regressed visible.
    $ledgerSuppressedCount = 0
    $ledgerPrevOpenCount = 0
    $ledgerResult = $null
    try {
      $ledgerPath = Get-FindingsLedgerPath -BridgePath $root -AuditDir $reportDir
      $ledger = Read-FindingsLedger -LedgerPath $ledgerPath
      # snapshot open-signal count BEFORE update (Update mutates $ledger in place)
      try { $ledgerPrevOpenCount = @($ledger.Values | Where-Object { (Normalize-AuditLedgerToken -Value ([string]$_.state) -Fallback 'open') -in @('open','new','regressed') }).Count } catch {}
      $ledgerResult = Update-FindingsLedger -CurrentFindings $mergedFindings -Ledger $ledger -Now (Get-Date).ToUniversalTime()
      Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $ledgerResult.ledger
      $mergedFindings = @($ledgerResult.reportFindings)
      $ledgerSuppressedCount = [int]$ledgerResult.suppressedCount
      if ($ledgerSuppressedCount -gt 0) {
        Write-AuditLog -BridgePath $root -Message "findings-ledger: suppressed $ledgerSuppressedCount known open findings"
      }
    } catch {
      $msg = "findings-ledger failed: $($_.Exception.Message)"
      [void]$errors.Add($msg)
      Write-AuditLog -BridgePath $root -Message $msg
    }
    $secCounts = Get-AuditSeverityCounts -Findings @($mergedFindings | Where-Object { $_.source -eq 'security' })
    $fncCounts = Get-AuditSeverityCounts -Findings @($mergedFindings | Where-Object { $_.source -eq 'functional' })
    $generatedAtLocal = (Get-Date).ToString('o')
    $generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $runtimeSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

    $report = [pscustomobject]@{
      generated_at      = $generatedAtUtc
      bridge_root       = $root
      runtime_sec       = $runtimeSeconds
      metadata          = [ordered]@{
        bridge_path          = $root
        channel              = $resolvedChannel
        audit_kind           = [string]$auditCtx.kind
        project_root         = $resolvedProject
        target_root          = [string]$auditCtx.target_root
        report_root          = [string]$auditCtx.report_root
        backlog_channel      = [string]$auditCtx.backlog_channel
        profile              = [string]$auditCtx.profile
        generated_at         = $generatedAtLocal
        gen_timestamp        = $generatedAtUtc
        runtime_seconds      = $runtimeSeconds
        security_runtime_sec = $sec.runtime_sec
        functional_runtime_sec = $fnc.runtime_sec
        findings_ledger_suppressed_count = $ledgerSuppressedCount
      }
      security_counts   = $secCounts
      functional_counts = $fncCounts
      security_runtime_sec   = $sec.runtime_sec
      functional_runtime_sec = $fnc.runtime_sec
      audit_kind       = [string]$auditCtx.kind
      channel          = [string]$auditCtx.channel
      target_root      = [string]$auditCtx.target_root
      report_root      = [string]$auditCtx.report_root
      audit_context    = $auditCtx
      findings          = @($mergedFindings)
      errors            = @($errors.ToArray())
    }

    # 7-8. write reports
    $paths = Write-AuditReports -BridgePath $root -Report $report -AuditContext $auditCtx

    # 9. update audit.last
    try {
      $marker = Get-AuditLastMarker -BridgePath $root -AuditDir $reportDir
      [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}

    # 10. file critical findings into backlog
    $filed = 0
    if ($secCounts.critical -gt 0 -or $fncCounts.critical -gt 0) {
      $filed = Add-AuditCriticalsToBacklog -BridgePath $root -Findings $mergedFindings -AuditContext $auditCtx
    }

    # 10b. usefulness score (idea 11): record how useful this audit was
    try {
      $newLedgerForScore = $null
      if ($ledgerResult) { $newLedgerForScore = $ledgerResult.ledger }
      Write-AuditUsefulnessScore -BridgePath $root -ReportFindings $mergedFindings -FiledToBacklog $filed -SuppressedKnown $ledgerSuppressedCount -PrevOpenCount $ledgerPrevOpenCount -NewLedger $newLedgerForScore -Now (Get-Date) -AuditDir $reportDir | Out-Null
    } catch {}

    # 11. DEEP-AUDIT phase (Codex security + multi-agent model fan-out)
    # 2026-05-28: implements backlog item 90747e410b. Runs after the static+
    # deepseek pipeline because (a) static is fast and always-on as safety net,
    # (b) deep-audit is heavier (~3-5min) so we want it last. Each half is
    # individually skippable on timeout/spawn-fail — graceful degradation.
    $deepCodexResult = $null
    $deepClaudeResult = $null
    $deepModelAgentResults = @()
    $deepStatus = 'skipped'
    $deepRuntimeSec = 0.0
    $deepWatchdogFired = $false
    try {
      $deepScript = Join-Path $root 'tools\deep-audit.ps1'
      if (Test-Path -LiteralPath $deepScript -PathType Leaf) {
        Write-AuditLog -BridgePath $root -Message "deep-audit start (Codex+multi-agent phase, watchdog=${DeepAuditTimeoutSec}s)"
        $deepSw = [System.Diagnostics.Stopwatch]::StartNew()
        $deepStdout = ''
        $deepStderr = ''
        $deepExitCode = 0
        $deepTmpDir = Join-Path $reportDir 'tmp'
        if (-not (Test-Path -LiteralPath $deepTmpDir)) { New-Item -ItemType Directory -Path $deepTmpDir -Force | Out-Null }
        $deepStamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
        $deepOutPath = Join-Path $deepTmpDir ("audit-deep-stdout_$deepStamp.txt")
        $deepErrPath = Join-Path $deepTmpDir ("audit-deep-stderr_$deepStamp.txt")
        # 2026-05-28: explicit JSON output file. Required workaround for PS 5.1
        # Start-Process -RedirectStandardOutput -WindowStyle Hidden, which binds
        # the subprocess stdout to cp866 (Russian Windows OEM) BEFORE the script
        # can switch [Console]::OutputEncoding to UTF-8. Result: every Cyrillic
        # observation arrives as cp866 mojibake. Writing the result JSON to a
        # file via [System.IO.File]::WriteAllText UTF-8 NoBOM sidesteps the
        # console layer entirely.
        $deepResultPath = Join-Path $deepTmpDir ("audit-deep-result_$deepStamp.json")
        try {
          # 2026-05-28: pass -ProjectRoot so codex/claude scope to the active
          # channel's codebase (not the bridge). Parallel is the default;
          # add -Sequential to fall back to back-to-back execution.
          # Also pass -FunctionalAgent (auto/gemini-only) for A/B testing.
          $deepArgValues = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $deepScript,
            '-BridgePath', $root,
            '-ProjectRoot', ([string]$auditCtx.target_root),
            '-FunctionalAgent', $FunctionalAgent,
            '-OutputFile', $deepResultPath
          )
          $deepArgs = @($deepArgValues | ForEach-Object { Format-AuditNativeArg ([string]$_) })
          $startDeepProcess = {
            Start-Process -FilePath 'powershell.exe' `
              -ArgumentList $deepArgs `
              -WorkingDirectory $root -RedirectStandardOutput $deepOutPath -RedirectStandardError $deepErrPath `
              -WindowStyle Hidden -PassThru
          }
          if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
            $deepProc = Invoke-WithChannelEnv -Slug $resolvedChannel -Action $startDeepProcess
          } else {
            $deepProc = & $startDeepProcess
          }
          $deepWaited = $deepProc.WaitForExit([int]($DeepAuditTimeoutSec * 1000))
          if (-not $deepWaited) {
            $deepWatchdogFired = $true
            $deepStatus = 'deep_failed'
            try { $deepProc.Kill() } catch {}
            try { $deepProc.WaitForExit(5000) | Out-Null } catch {}
            [void]$errors.Add("deep-audit watchdog timeout after ${DeepAuditTimeoutSec}s; process killed")
            Write-AuditLog -BridgePath $root -Message "deep-audit watchdog timeout after ${DeepAuditTimeoutSec}s; pid=$($deepProc.Id) killed"
          } else {
            try { $deepExitCode = [int]$deepProc.ExitCode } catch { $deepExitCode = 0 }
          }
          # Prefer the explicit result file (UTF-8 guaranteed). Fall back to
          # stdout for older deep-audit.ps1 versions that don't write the file.
          if (Test-Path -LiteralPath $deepResultPath) {
            $deepStdout = [System.IO.File]::ReadAllText($deepResultPath, [System.Text.Encoding]::UTF8)
          } elseif (Test-Path -LiteralPath $deepOutPath) {
            $deepStdout = [System.IO.File]::ReadAllText($deepOutPath, [System.Text.Encoding]::UTF8)
          }
          if (Test-Path -LiteralPath $deepErrPath) { $deepStderr = [System.IO.File]::ReadAllText($deepErrPath, [System.Text.Encoding]::UTF8) }
        } finally {
          try {
            if ($deepSw) {
              $deepSw.Stop()
              $deepRuntimeSec = [math]::Round($deepSw.Elapsed.TotalSeconds, 2)
            }
          } catch {}
          try { Remove-Item -LiteralPath $deepOutPath,$deepErrPath,$deepResultPath -Force -ErrorAction SilentlyContinue } catch {}
        }
        if (-not $deepWatchdogFired -and $deepExitCode -ne 0) {
          $deepStatus = 'deep_failed'
          $stderrTail = (($deepStderr -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          [void]$errors.Add(("deep-audit exited with code {0}: {1}" -f $deepExitCode, $stderrTail))
        }
        # Extract last JSON line from stdout
        $deepJson = $null
        foreach ($ln in (($deepStdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
          $t = $ln.Trim().Trim([char]0xFEFF)
          if ($t.StartsWith('{') -and $t.EndsWith('}')) { $deepJson = $t }
        }
        if ($deepJson) {
          try {
            $deepParsed = $deepJson | ConvertFrom-Json
            $deepCodexResult  = $deepParsed.codex_security
            $deepClaudeResult = $deepParsed.claude_functional
            # 2026-05-30: orchestrator emits 'agents' (multi-agent path); older
            # versions used 'model_agents'. Read 'agents' first, fall back to the
            # legacy name -- the mismatch made every deep-audit report agents=0.
            if ($deepParsed.PSObject.Properties.Name -contains 'agents') {
              $deepModelAgentResults = @($deepParsed.agents)
            } elseif ($deepParsed.PSObject.Properties.Name -contains 'model_agents') {
              $deepModelAgentResults = @($deepParsed.model_agents)
            }
            if (-not $deepWatchdogFired -and $deepExitCode -eq 0) { $deepStatus = 'ok' }
          } catch {
            $deepStatus = 'deep_failed'
            $jsonSnippet = $deepJson
            if ($jsonSnippet.Length -gt 500) { $jsonSnippet = $jsonSnippet.Substring(0,500) + '...' }
            [void]$errors.Add('deep-audit JSON parse failed: ' + $_.Exception.Message + '; json_snippet=' + $jsonSnippet)
          }
        } elseif (-not $deepWatchdogFired) {
          $deepStatus = 'deep_failed'
          $stdoutTail = (($deepStdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          $stderrTail = (($deepStderr -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          [void]$errors.Add('deep-audit: no JSON in stdout; stdout_tail=' + $stdoutTail + '; stderr_tail=' + $stderrTail)
        }
      } else {
        $deepStatus = 'skipped'
      }
    } catch {
      $deepStatus = 'deep_failed'
      [void]$errors.Add('deep-audit invocation failed: ' + $_.Exception.Message)
    }

    # Merge deep findings into report + backlog
    $deepFiled = 0
    $deepCodexCount = 0
    $deepClaudeCount = 0
    $deepModelAgentCount = 0
    $addIdeaAvailable = $false
    $deepBacklogHelperWarned = $false
    try {
      # 2026-05-28: dot-source common.ps1 (not just backlog.ps1). Same bug class as
      # Start-BacklogCuratorJob hit earlier — Add-Idea internally references
      # Get-BacklogPath -> Get-ChannelBacklogPath (lib/channels.ps1) and the
      # write closure needs Use-BridgeLock (lib/common.ps1) + Get-Backlog
      # (lib/backlog.ps1). Loading common.ps1 brings the whole stack in the right
      # order so audit can actually file findings instead of throwing
      # "Get-BacklogPath not recognized".
      $addIdeaLoaded = [bool](Get-Command Add-Idea -ErrorAction SilentlyContinue)
      $getBacklogPathLoaded = [bool](Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)
      if (-not $addIdeaLoaded -or -not $getBacklogPathLoaded) {
        $commonLib = Join-Path $root 'lib\common.ps1'
        if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
      }
      $initializeChannelsLoaded = Get-Command Initialize-Channels -ErrorAction SilentlyContinue
      if ($initializeChannelsLoaded) {
        try {
          Initialize-Channels | Out-Null
        } catch {
          Write-Warning ("audit-self-diag: Initialize-Channels failed after common.ps1 load: " + $_.Exception.Message)
        }
      }
      # Pin the channel so Get-BacklogPath resolves to the active channel's
      # backlog.jsonl. 2026-05-28: was hard-pinned to 'main' — that meant a
      # travel-channel audit would file its findings into the bridge backlog,
      # not the travel one. Now we use $resolvedChannel (already computed at
      # the top of Invoke-BridgeAudit from -Channel / Get-EffectiveChannel),
      # so the findings land where the user actually triggered the audit.
      if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) {
        $pinSlug = if (-not [string]::IsNullOrWhiteSpace($resolvedChannel)) { $resolvedChannel } else { 'main' }
        try { Set-PinnedChannel $pinSlug } catch {}
      }
      if (-not (Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)) {
        Write-Warning 'audit-self-diag: Get-BacklogPath unavailable after common.ps1 load and Initialize-Channels; skipping Add-Idea filing for deep-audit findings'
      }
      $addIdeaAvailable = [bool](Get-Command Add-Idea -ErrorAction SilentlyContinue) -and [bool](Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)
    } catch {
      [void]$errors.Add('deep-audit backlog helper load failed: ' + $_.Exception.Message)
    }
    # Bridge deep-audit findings are pre-validated and go in approved. Project
    # deep-audit findings go in held so an external codebase is never changed
    # just because a tab-level audit found something.
    # 2026-05-28: diagnostic — earlier "deep[claude=10] backlog+=0+0" runs lost
    # findings silently because Write-AuditReports already ran and errors-list
    # had nowhere to go. Log every decision (filed/skipped/failed) directly to
    # audit.log so the next failure is debuggable from one place.
    $writeDiag = {
      param([string]$Source, [string]$Sev, [string]$Outcome, [string]$Detail)
      try {
        Write-AuditLog -BridgePath $root -Message ("deep-audit filing: source=$Source sev=$Sev outcome=$Outcome" + $(if ($Detail) { " detail=$Detail" } else { '' }))
      } catch {}
    }
    if (-not $addIdeaAvailable) {
      & $writeDiag 'init' '' 'add-idea-unavailable' ('add-idea-loaded=' + [bool](Get-Command Add-Idea -EA SilentlyContinue) + ' get-backlogpath-loaded=' + [bool](Get-Command Get-BacklogPath -EA SilentlyContinue))
    }
    $deepBacklogStatus = if ([string]$auditCtx.kind -eq 'project') { 'held' } else { 'approved' }
    $deepBacklogProject = [string]$auditCtx.backlog_channel
    $deepBacklogScope = [string]$auditCtx.kind
    $deepBaseTags = if ([string]$auditCtx.kind -eq 'project') { @('audit','project-audit',$deepBacklogProject,'deep-audit') } else { @('audit','deep-audit') }
    if ($deepCodexResult) {
      $cf = @($deepCodexResult.findings)
      $deepCodexCount = $cf.Count
      foreach ($f in $cf) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag 'codex' $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $bText = "[deep-codex/security] " + [string]$f.category + " (" + [string]$f.file + ":" + [string]$f.line + ") -- " + [string]$f.finding + " | Recommend: " + [string]$f.recommendation
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-codex' -Tags @($deepBaseTags + @('codex','security',$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag 'codex' $sev 'filed' "id=$bid"
            } else {
              & $writeDiag 'codex' $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$errors.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$errors.Add('deep-audit codex backlog filing failed: ' + $msg)
          & $writeDiag 'codex' $sev 'exception' $msg
        }
      }
    }
    if ($deepClaudeResult) {
      $cf = @($deepClaudeResult.findings)
      $deepClaudeCount = $cf.Count
      # Claude's findings (critical / warning / info) all go to backlog now —
      # severity controls picker order, info-level just lands last.
      foreach ($f in $cf) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag 'claude' $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $bText = "[deep-claude/" + [string]$f.category + "] " + [string]$f.feature_id + ": " + [string]$f.observation + " | Предлагает: " + [string]$f.recommendation
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-claude' -Tags @($deepBaseTags + @('claude','functional',$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag 'claude' $sev 'filed' "id=$bid"
            } else {
              & $writeDiag 'claude' $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$errors.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$errors.Add('deep-audit claude backlog filing failed: ' + $msg)
          & $writeDiag 'claude' $sev 'exception' $msg
        }
      }
    }
    foreach ($agent in @($deepModelAgentResults)) {
      if (-not $agent) { continue }
      $agentRole = [string]$agent.role
      $agentModel = [string]$agent.model
      $af = @($agent.findings)
      $deepModelAgentCount += $af.Count
      foreach ($f in $af) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag $agentRole $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $area = [string]$f.area
          $cat = [string]$f.category
          $obs = [string]$f.observation
          $rec = [string]$f.recommendation
          $bText = "[deep-agent/$agentRole/$agentModel] $cat"
          if (-not [string]::IsNullOrWhiteSpace($area)) { $bText += " ($area)" }
          $bText += " -- $obs | Recommend: $rec"
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-agent' -Tags @($deepBaseTags + @('agent',$agentRole,$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag $agentRole $sev 'filed' "id=$bid"
            } else {
              & $writeDiag $agentRole $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$errors.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$errors.Add('deep-audit model-agent backlog filing failed: ' + $msg)
          & $writeDiag $agentRole $sev 'exception' $msg
        }
      }
    }

    # Append deep-audit sections to the MD report (in-place edit)
    if ($paths -and $paths.md -and (Test-Path -LiteralPath $paths.md)) {
      try {
        $mdExisting = [System.IO.File]::ReadAllText($paths.md, [System.Text.Encoding]::UTF8)
        $deepBlock = New-Object 'System.Text.StringBuilder'
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine("## Deep Audit Status")
        [void]$deepBlock.AppendLine("- Status: $deepStatus")
        [void]$deepBlock.AppendLine("- Runtime: ${deepRuntimeSec}s")
        [void]$deepBlock.AppendLine("- Model agents: $(@($deepModelAgentResults).Count) agents, $deepModelAgentCount findings")
        if ($deepWatchdogFired) { [void]$deepBlock.AppendLine("- Watchdog: timeout after ${DeepAuditTimeoutSec}s") }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Codex Security (deep)')
        if (-not $deepCodexResult -or $deepCodexResult.skipped) {
          $reason = if ($deepCodexResult) { [string]$deepCodexResult.reason } else { 'не запущено' }
          [void]$deepBlock.AppendLine("_Пропущено: $reason_")
        } elseif ($deepCodexResult.error) {
          [void]$deepBlock.AppendLine("_Ошибка: $($deepCodexResult.error)_")
        } else {
          if ($deepCodexCount -eq 0) {
            [void]$deepBlock.AppendLine('_Codex не нашёл реальных уязвимостей в изменённых за 24ч файлах._')
          } else {
            foreach ($f in @($deepCodexResult.findings)) {
              if (-not $f) { continue }
              # 2026-05-28: was using backtick-escaped $(...) inside double quotes
              # to wrap file:line in markdown backticks. PowerShell read the backtick
              # as escape and the whole $([string]$f.file...) expression became a
              # literal in the report. Build via concatenation so the inline code
              # markers are literal but the expression runs.
              $codexFL = '`' + [string]$f.file + ':' + [string]$f.line + '`'
              [void]$deepBlock.AppendLine("- **$([string]$f.severity)** $([string]$f.category) _($codexFL)_: $([string]$f.finding)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("  - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Claude Functional (deep)')
        if (-not $deepClaudeResult -or $deepClaudeResult.skipped) {
          $reason = if ($deepClaudeResult) { [string]$deepClaudeResult.reason } else { 'не запущено' }
          [void]$deepBlock.AppendLine("_Пропущено: $reason_")
        } elseif ($deepClaudeResult.error) {
          [void]$deepBlock.AppendLine("_Ошибка: $($deepClaudeResult.error)_")
        } else {
          if ($deepClaudeCount -eq 0) {
            [void]$deepBlock.AppendLine('_Claude не нашёл архитектурных проблем — реестр консистентен с состоянием._')
          } else {
            foreach ($f in @($deepClaudeResult.findings)) {
              if (-not $f) { continue }
              # 2026-05-28: build the literal-backtick wrap via concat to avoid
              # the `$(...) escape-trap (same fix as the codex block above).
              $claudeFid = '`' + [string]$f.feature_id + '`'
              [void]$deepBlock.AppendLine("- **$([string]$f.severity)** $([string]$f.category) — фича $claudeFid : $([string]$f.observation)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("  - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Model Agents (deep)')
        if (@($deepModelAgentResults).Count -eq 0) {
          [void]$deepBlock.AppendLine('_Не запущены или не вернули результатов._')
        } else {
          foreach ($agent in @($deepModelAgentResults)) {
            if (-not $agent) { continue }
            $role = [string]$agent.role
            $model = [string]$agent.model
            if ($agent.skipped) {
              $reason = if ($agent.reason) { [string]$agent.reason } else { 'skipped' }
              [void]$deepBlock.AppendLine("- `$role` / `$model`: skipped ($reason)")
              continue
            }
            if ($agent.error) {
              [void]$deepBlock.AppendLine("- `$role` / `$model`: error $([string]$agent.error)")
              continue
            }
            $finds = @($agent.findings)
            if ($finds.Count -eq 0) {
              [void]$deepBlock.AppendLine("- `$role` / `$model`: findings=0")
              continue
            }
            [void]$deepBlock.AppendLine("- `$role` / `$model`: findings=$($finds.Count)")
            foreach ($f in $finds) {
              if (-not $f) { continue }
              $area = if ($f.area) { ' _(`' + [string]$f.area + '`)_ ' } else { ' ' }
              [void]$deepBlock.AppendLine("  - **$([string]$f.severity)** $([string]$f.category)$($area): $([string]$f.observation)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("    - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [System.IO.File]::WriteAllText($paths.md, $mdExisting + $deepBlock.ToString(), (New-Object System.Text.UTF8Encoding($false)))
      } catch {
        [void]$errors.Add('deep-audit md merge failed: ' + $_.Exception.Message)
      }
    }

    $finalStatus = if ($deepStatus -eq 'deep_failed') { 'partial' } else { 'ok' }
    try {
      $report | Add-Member -NotePropertyName status -NotePropertyValue $finalStatus -Force
      $report | Add-Member -NotePropertyName errors -NotePropertyValue @($errors.ToArray()) -Force
      $report | Add-Member -NotePropertyName deep_results -NotePropertyValue ([ordered]@{
        codex_security    = $deepCodexResult
        claude_functional = $deepClaudeResult
        model_agents      = @($deepModelAgentResults)
      }) -Force
      if ($report.metadata) {
        $report.metadata['deep_status'] = $deepStatus
        $report.metadata['deep_runtime_sec'] = $deepRuntimeSec
        $report.metadata['deep_watchdog_timeout_sec'] = $DeepAuditTimeoutSec
        $report.metadata['deep_watchdog_fired'] = $deepWatchdogFired
        $report.metadata['deep_model_agent_count'] = $deepModelAgentCount
      }
      if ($paths -and $paths.json) {
        Write-AuditAtomicFile -Path $paths.json -Content ($report | ConvertTo-Json -Depth 8)
      }
      Write-AuditIndexEntry -BridgePath $root -AuditContext $auditCtx -Paths $paths -Report $report
    } catch {
      [void]$errors.Add('audit report deep-status update failed: ' + $_.Exception.Message)
    }

    Write-AuditLog -BridgePath $root -Message ("audit {11} in {0}s — sec[{1}c/{2}w/{3}i] fnc[{4}c/{5}w/{6}i] deep[{12} codex={7} claude={8} agents={13}] backlog+={9}+{10}" -f `
      $report.runtime_sec, $secCounts.critical, $secCounts.warning, $secCounts.info, `
      $fncCounts.critical, $fncCounts.warning, $fncCounts.info, $deepCodexCount, $deepClaudeCount, $filed, $deepFiled, $finalStatus, $deepStatus, $deepModelAgentCount)

    # 2026-05-30: post a completion summary into the chat (visible audit finish)
    try {
      if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
        $auditIcon = if ($finalStatus -eq 'ok') { '✅' } else { '⚠️' }
        $totalFindings = [int]$secCounts.critical + [int]$secCounts.warning + [int]$secCounts.info + [int]$fncCounts.critical + [int]$fncCounts.warning + [int]$fncCounts.info
        $deepLabel = if ($deepStatus -eq 'ok') { "deep ok · агентов:$deepModelAgentCount" } else { "deep:$deepStatus" }
        $doneMsg = "$auditIcon Аудит завершён за $($report.runtime_sec)s · $deepLabel · находок:$totalFindings · в backlog:+$($filed + $deepFiled)"
        [void](Add-Message -From system -Text $doneMsg -Kind event)
      }
    } catch {}

    return [pscustomobject]@{
      status            = $finalStatus
      deep_status       = $deepStatus
      audit_kind        = [string]$auditCtx.kind
      channel           = [string]$auditCtx.channel
      target_root       = [string]$auditCtx.target_root
      report_json       = $paths.json
      report_md         = $paths.md
      security_counts   = $secCounts
      functional_counts = $fncCounts
      deep_codex_count  = $deepCodexCount
      deep_claude_count = $deepClaudeCount
      deep_model_agent_count = $deepModelAgentCount
      deep_runtime_sec  = $deepRuntimeSec
      backlog_added     = $filed + $deepFiled
      runtime_sec       = $report.runtime_sec
      errors            = @($errors.ToArray())
    }
  } finally {
    Remove-AuditLock -BridgePath $root
  }
}


# When invoked directly (powershell.exe -File tools\audit.ps1), run the audit
# immediately against the parent directory of tools/. Dot-source consumers
# (driver's Start-AuditIfDue Start-Job) just pull the functions and call
# Wait-BridgeIdle + Invoke-BridgeAudit themselves.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\.\s') {
  $defaultRoot = Get-AuditBridgeRoot -Hint $null
  Invoke-BridgeAudit -BridgePath $defaultRoot | Out-Null
}
