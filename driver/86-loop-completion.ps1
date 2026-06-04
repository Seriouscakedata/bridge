function Invoke-PostTaskSelfModelRefresh {
  [CmdletBinding()]
  param(
    [string]$Channel,
    [string]$BridgeRoot
  )

  $result = [ordered]@{
    attempted = $false
    ok        = $false
    skipped   = $false
    error     = ''
  }

  function Write-PostTaskSelfModelRefreshFailure {
    param([string]$Message)

    try {
      if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
        Add-Message -From system -Text ("⚠ Self-model refresh skipped/failed: " + $Message) -Kind event | Out-Null
      }
    } catch {}
    try {
      $logRoot = $BridgeRoot
      if ([string]::IsNullOrWhiteSpace($logRoot)) { $logRoot = (Get-Location).Path }
      Add-Content -LiteralPath (Join-Path $logRoot 'self-model-refresh.log') -Value ((Get-Date).ToString('s') + '  post-task-refresh: ' + $Message) -Encoding UTF8
    } catch {}
  }

  try {
    $effectiveChannel = [string]$Channel
    if ([string]::IsNullOrWhiteSpace($effectiveChannel)) {
      try {
        if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
          $effectiveChannel = [string](Get-EffectiveChannel)
        }
      } catch {}
    }
    if ($effectiveChannel -ne 'main') {
      $result.skipped = $true
      $result.error = 'channel is not main'
      return [pscustomobject]$result
    }

    $root = [string]$BridgeRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
      try { $root = Split-Path -Parent $PSScriptRoot } catch { $root = (Get-Location).Path }
    }
    $refreshTool = Join-Path $root 'tools\refresh-self-model.ps1'
    if (-not (Test-Path -LiteralPath $refreshTool)) {
      $result.skipped = $true
      $result.error = 'refresh tool missing'
      Write-PostTaskSelfModelRefreshFailure -Message $result.error
      return [pscustomobject]$result
    }

    $result.attempted = $true
    & $refreshTool -BridgeRoot $root -NoOutput | Out-Null
    $result.ok = $true
    return [pscustomobject]$result
  } catch {
    $result.error = $_.Exception.Message
    Write-PostTaskSelfModelRefreshFailure -Message $result.error
    return [pscustomobject]$result
  }
}

$script:DriverLoopCompletionBlock = {
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
      $gateReport = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRoot
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
          $id = Add-Idea -Text $itext -From 'architect' -Tags @('architect','deep-think','dialog-survived') -Status 'new' -Project ([string]$pbForDeepThink.slug) -Scope 'bridge'
          if ($id) { $filed++ }
        }
        if ($filed -gt 0) {
          Add-Message -From system -Text ("🧭💭 Deep-think dialog завершён: " + $filed + " идей прошли критику Codex'а и легли в беклог (тег: architect+deep-think+dialog-survived, status=new).") -Kind event | Out-Null
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
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    # Независимый критик: перед закрытием ревьюим git-дифф задачи на другой модели.
    # Серьёзное -> возврат Codex на доработку; сбои критика не блокируют завершение.
    try {
      $stC = Read-State
      if ([bool]$stC.task_did_actions) {
        if ([bool]$stC.skip_critic) {
          Add-Message -From system -Text "⏭ Critic пропущен (fast-lane)" -Kind event | Out-Null
        } else {
        $criticMaxRetries = 2
        try { $cfgCr = Get-BridgeConfig; if ($cfgCr.PSObject.Properties.Name -contains 'criticMaxRetries') { $criticMaxRetries = [int]$cfgCr.criticMaxRetries } } catch {}
        $crc  = [int]$stC.critic_retry_count
        $base = [string]$stC.task_base_commit
        $criticRepoRoot = Get-TaskRepoRoot
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          $baseOkForCritic = $false
          try {
            $baseTypeForCritic = (& git -C $criticRepoRoot cat-file -t $base 2>$null | Select-Object -First 1)
            if ([string]$baseTypeForCritic -eq 'commit') { $baseOkForCritic = $true }
          } catch {}
          if (-not $baseOkForCritic) { $base = '' }
        }
        $diff = ''
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          try { $diff = (& git -C $criticRepoRoot diff $base -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if ([string]::IsNullOrWhiteSpace($diff)) {
          try { $diff = (& git -C $criticRepoRoot diff HEAD -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($diff)) {
          if ($crc -ge $criticMaxRetries) {
            Add-Message -From system -Text "🔎 Критик: лимит доработок ($criticMaxRetries) исчерпан — закрываю задачу как есть, нужно внимание оператора." -Kind event | Out-Null
            try { Send-PushEvent -Kind need_you -Text "Критик исчерпал лимит доработок: $(Get-PushSnippet -Text $task)" } catch {}
          } else {
            $llmCfg = $null
            try { $llmCfg = Get-LLMConfig } catch {}
            $criticLight = if ($llmCfg -and $llmCfg.ContainsKey('critic')) { [string]$llmCfg['critic'] } else { 'deepseek-v4-flash' }
            $criticHeavy = if ($llmCfg -and $llmCfg.ContainsKey('criticHeavy')) { [string]$llmCfg['criticHeavy'] } else { 'deepseek-v4-pro' }
            $diffNames = @()
            try {
              if (-not [string]::IsNullOrWhiteSpace($base)) { $diffNames = @(& git -C $criticRepoRoot diff --name-only $base -- 2>$null) }
              if (@($diffNames).Count -eq 0) { $diffNames = @(& git -C $criticRepoRoot diff --name-only HEAD -- 2>$null) }
            } catch {}
            $linesChanged = 0
            try {
              $numstat = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $numstat = @(& git -C $criticRepoRoot diff --numstat $base -- 2>$null) }
              if (@($numstat).Count -eq 0) { $numstat = @(& git -C $criticRepoRoot diff --numstat HEAD -- 2>$null) }
              foreach ($lnStat in @($numstat)) {
                $parts = @(([string]$lnStat) -split '\s+')
                if ($parts.Count -ge 2) {
                  $adds = 0; $dels = 0
                  [int]::TryParse($parts[0], [ref]$adds) | Out-Null
                  [int]::TryParse($parts[1], [ref]$dels) | Out-Null
                  $linesChanged += ($adds + $dels)
                }
              }
            } catch {}
            $heavyRegex = '(?i)security|auth|secret|crypto|race|mutex|lock|concurr(en|ency)?|sql\s*injection|inject(ion)?|csrf|xss'
            $isHeavyCritic = (@($diffNames).Count -gt 3) -or ($linesChanged -gt 100) -or ($diff -match $heavyRegex)
            $crcNow = 0
            try { $crcNow = [int](Read-State).critic_retry_count } catch {}
            if ($crcNow -ge 1) { $isHeavyCritic = $true }
            $criticModelName = if ($isHeavyCritic) { $criticHeavy } else { $criticLight }

            # 2026-05-27: deterministic CLI-flag check BEFORE the LLM critic.
            # The LLM critic (deepseek) approved a non-existent --cwd flag for
            # claude.exe in the prior Wave-C-tails task because it has no way
            # to run the CLI. This pre-check actually invokes `cli --help` and
            # rejects diffs that introduce unknown flags. Findings here are
            # treated as serious and prepended to LLM issues -- they cannot be
            # talked away by the LLM.
            $cliFlagIssues = @()
            try { $cliFlagIssues = @(Test-CliFlagsInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ CLI-flag check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $cliFlagIssuesText = ''
            if ($cliFlagIssues.Count -gt 0) {
              $parts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $cliFlagIssues) {
                [void]$parts.Add(("$($iss.cli).exe не знает флага '$($iss.flag)' (в --help отсутствует). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $cliFlagIssuesText = [string]::Join(' ; ', $parts.ToArray())
              Add-Message -From system -Text ("🔎 CLI-flag-check: " + $cliFlagIssuesText) -Kind event | Out-Null
            }

            $qualityBypassIssues = @()
            try { $qualityBypassIssues = @(Test-QualityBypassesInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ Quality-bypass check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $qualityBypassIssuesText = ''
            if ($qualityBypassIssues.Count -gt 0) {
              $qbParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $qualityBypassIssues) {
                [void]$qbParts.Add(("$($iss.reason). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $qualityBypassIssuesText = [string]::Join(' ; ', $qbParts.ToArray())
              Add-Message -From system -Text ("🔎 Quality-bypass-check: " + $qualityBypassIssuesText) -Kind event | Out-Null
            }

            $diffWasTruncated = $false
            $diffBytes = 0
            try { $diffBytes = [Text.Encoding]::UTF8.GetByteCount($diff) } catch { $diffBytes = $diff.Length }
            if ($diff.Length -gt 16000) {
              $diffWasTruncated = $true
              $diff = $diff.Substring(0,16000) + "`n...[дифф обрезан]..."
            }
            $truncationNote = if ($diffWasTruncated) {
              "ВАЖНО: diff ниже обрезан по лимиту контекста. Не считай сам факт обрезки синтаксической ошибкой, потерей кода или доказательством обрезанной функции; проверяй только реально видимые изменения. Синтаксис .ps1 и BOM проверяются отдельными командами."
            } else { "" }
            $diffTruncatedText = ([string]$diffWasTruncated).ToLowerInvariant()
            $changedFilesText = ''
            try {
              $changedLines = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $changedLines = @(& git -C $criticRepoRoot diff --name-status $base -- 2>$null) }
              if (@($changedLines).Count -eq 0) { $changedLines = @(& git -C $criticRepoRoot diff --name-status HEAD -- 2>$null) }
              $changedFilesText = [string]::Join("`n", @($changedLines))
              if ($changedFilesText.Length -gt 3000) { $changedFilesText = $changedFilesText.Substring(0, 3000) + "`n...[changed-files truncated]..." }
            } catch {
              $changedFilesText = "(changed-files unavailable: $($_.Exception.Message))"
            }
            $taskHistory = ''
            if (-not [string]::IsNullOrWhiteSpace($base)) {
              try {
                $histLines = @(& git -C $criticRepoRoot log --oneline --name-status "$base..HEAD" 2>$null)
                $taskHistory = [string]::Join("`n", @($histLines))
                if ($taskHistory.Length -gt 6000) {
                  $taskHistory = $taskHistory.Substring(0, 6000) + "`n...[история обрезана]..."
                }
              } catch {
                $taskHistory = "(task-history unavailable: $($_.Exception.Message))"
              }
            }
            # HEAD context lets the critic distinguish "not in this diff" from "not in repo".
            $headContext = ''
            $symbolEvidence = ''
            try {
              $repoPs1Files = @()
              try { $repoPs1Files = @(& git -C $criticRepoRoot ls-files --cached '*.ps1' 2>$null) } catch { $repoPs1Files = @() }
              $repoPs1List = if ($repoPs1Files.Count -gt 0) { [string]::Join(', ', $repoPs1Files) } else { '(none)' }

              $funcLines = New-Object 'System.Collections.Generic.List[string]'
              $diffPs1Names = @($diffNames | Where-Object { $_ -match '\.ps1$' })
              $diffPs1Set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
              foreach ($relDiffPs1 in $diffPs1Names) { [void]$diffPs1Set.Add([string]$relDiffPs1) }
              foreach ($relf in $diffPs1Names) {
                $fullF = Join-Path $criticRepoRoot $relf
                if (Test-Path $fullF) {
                  $fns = @()
                  try {
                    $fns = @(& git -C $criticRepoRoot show ('HEAD:' + ($relf -replace '\\','/')) 2>$null |
                      Select-String -Pattern '^\s*function\s+([A-Za-z][\w-]*)' -AllMatches |
                      ForEach-Object { $_.Matches | ForEach-Object { $_.Groups[1].Value } })
                  } catch { $fns = @() }
                  if ($fns.Count -gt 0) {
                    [void]$funcLines.Add(($relf + ': ' + [string]::Join(', ', $fns)))
                  }
                }
              }

              $allFuncsInDiffedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
              foreach ($ln in @($funcLines)) {
                $parts2 = $ln -split ': ', 2
                if ($parts2.Count -eq 2) {
                  foreach ($fn in ($parts2[1] -split ', ')) {
                    [void]$allFuncsInDiffedFiles.Add($fn.Trim())
                  }
                }
              }

              $calledInDiff = @()
              try {
                $cmdNamePattern = '(?:Invoke-|Get-|Set-|Add-|Remove-|Test-|New-|Write-|Read-|Send-|Update-|Save-|Load-|Build-|Find-|Format-|Start-|Stop-)[A-Za-z][\w-]*'
                $calledSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($dln in ($diff -split "`r?`n")) {
                  if ($dln -notmatch '^[\+\- ]') { continue }
                  if ($dln -match '^(?:\+\+\+|---)') { continue }
                  $codeLine = if ($dln.Length -gt 0) { $dln.Substring(1) } else { '' }
                  if ($codeLine -match '^\s*#') { continue }
                  foreach ($m in [regex]::Matches($codeLine, "(?<![\w-])$cmdNamePattern(?![\w-])")) {
                    [void]$calledSet.Add($m.Value)
                  }
                }
                $calledInDiff = @($calledSet | Sort-Object)
              } catch { $calledInDiff = @() }

              $crossRefs = New-Object 'System.Collections.Generic.List[string]'
              $symbolEvidenceParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($fn in $calledInDiff) {
                if ($allFuncsInDiffedFiles.Contains($fn)) { continue }
                $fnFiles = New-Object 'System.Collections.Generic.List[string]'
                foreach ($rf in $repoPs1Files) {
                  $fullRf = Join-Path $criticRepoRoot $rf
                  if (-not (Test-Path $fullRf)) { continue }
                  if ($diffPs1Set.Contains([string]$rf)) { continue }
                  try {
                    $headLines = @(& git -C $criticRepoRoot show ('HEAD:' + ($rf -replace '\\','/')) 2>$null)
                    $fnPattern = '^\s*function\s+' + [regex]::Escape($fn) + '\b'
                    $hitIndex = -1
                    for ($idx = 0; $idx -lt $headLines.Count; $idx++) {
                      if ([string]$headLines[$idx] -match $fnPattern) { $hitIndex = $idx; break }
                    }
                    $hit = ($hitIndex -ge 0)
                    if ($hit) {
                      [void]$fnFiles.Add($rf)
                      if ($symbolEvidence.Length -lt 8000) {
                        $endIdx = [Math]::Min($headLines.Count - 1, $hitIndex + 10)
                        $bodyLines = New-Object 'System.Collections.Generic.List[string]'
                        for ($bodyIdx = $hitIndex; $bodyIdx -le $endIdx; $bodyIdx++) {
                          [void]$bodyLines.Add([string]$headLines[$bodyIdx])
                        }
                        $snippet = ("### {0} -> {1}`n{2}" -f $fn, $rf, [string]::Join("`n", $bodyLines.ToArray()))
                        [void]$symbolEvidenceParts.Add($snippet)
                        $symbolEvidence = [string]::Join("`n`n", $symbolEvidenceParts.ToArray())
                        if ($symbolEvidence.Length -gt 8000) {
                          $symbolEvidence = $symbolEvidence.Substring(0, 8000) + "`n...[symbol-evidence truncated]..."
                          break
                        }
                      }
                    }
                  } catch { $hit = $false }
                }
                if ($fnFiles.Count -gt 0) {
                  [void]$crossRefs.Add($fn + ' -> ' + [string]::Join(', ', $fnFiles.ToArray()))
                }
                if ($symbolEvidence.Length -gt 8000) { break }
              }

              $hcParts = New-Object 'System.Collections.Generic.List[string]'
              if ($funcLines.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ:`n" + [string]::Join("`n", $funcLines.ToArray()))
              }
              if ($crossRefs.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ ИЗ DIFF, ОПРЕДЕЛЁННЫЕ В ДРУГИХ ФАЙЛАХ:`n" + [string]::Join("`n", $crossRefs.ToArray()))
              }
              [void]$hcParts.Add("ВСЕ .ps1 ФАЙЛЫ РЕПО: $repoPs1List")
              $headContext = [string]::Join("`n`n", $hcParts.ToArray())
              if ($headContext.Length -gt 8000) { $headContext = $headContext.Substring(0, 8000) + "`n...[контекст обрезан]..." }
              if ([string]::IsNullOrWhiteSpace($symbolEvidence)) { $symbolEvidence = "(no cross-file symbol evidence)" }
            } catch {
              $headContext = "(head-context unavailable: $($_.Exception.Message))"
              $symbolEvidence = "(symbol-evidence unavailable: $($_.Exception.Message))"
            }
            $criticPrompt = @"
Ты — независимый код-критик. Другой ИИ (Codex) внёс изменения в проект на PowerShell (автономный мост Claude<->Codex на Windows). Проверь git-дифф на СЕРЬЁЗНЫЕ проблемы: баги, уязвимости безопасности, регрессии, потеря данных, падения, синтаксические ошибки, нарушение инвариантов (каждый .ps1 в UTF-8 с BOM; не трогать watchdog/supervisor/.git; не выводить секреты).
НЕ придирайся к стилю, именованию и форматированию — отмечай только то, что реально сломает работу или создаёт риск.

ОСОБО ПРОВЕРЬ ИЗВЕСТНЫЕ ГРАБЛИ POWERSHELL (частые причины аварий в этом проекте — при наличии ставь severity=serious):
- ConvertTo-Json по строке из `Get-Content -Raw` (или по сырым объектам из ConvertFrom-Json), особенно с -Depth>=12 → рекурсия по ETS-графу провайдера (PSProvider/PSDrive) → OOM ~70ГБ и краш хоста. Должно быть [IO.File]::ReadAllText или `("" + $s)` + ПЛОСКИЕ DTO + -Depth<=10. (это уже роняло мост — /api/radar)
- .ps1 без BOM (PS 5.1 ломает кириллицу); вызов нативного exe (git и т.п.) под $ErrorActionPreference='Stop' (stderr бросит исключение).
- Новый/изменённый API-эндпоинт или UI БЕЗ реальной проверки по HTTP/загрузке страницы.
- Бесконечные циклы / отсутствие таймаута; убийство процессов по возрасту/эвристике; чтение или вывод secrets.json.
- `param([string[]]$Args)` или другие зарезервированные имена параметров (Args/Input/PSCmdlet/MyInvocation/PSScriptRoot) — silent override автоматическими переменными, функция получит пусто или мусор (2026-05-27: Get-BacklogGitOutput с `$Args` вернула git help-страницу 2335 символов вместо коммитов, freshness-check 18 items работал на мусоре).
- `Add-Content -Encoding UTF8` в PS 5.1 пишет BOM при создании файла — JSONL с BOM ломает строгие парсеры. Для JSONL нужно `[IO.File]::AppendAllText($path,$line+"`n",(New-Object Text.UTF8Encoding($false)))`.
- Native command stderr через `2>&1` под PS 5.1 — каждая stderr-строка оборачивается в NativeCommandError ErrorRecord, что часто валит скрипт. Используй `2>$null` отдельно или `cmd /c "... 2>NUL"`.

🔢 ОТДЕЛЬНО — OVER-CLAIM ПАТТЕРН (это уже было причиной 1-часового цикла verify-reject):
Если в коммит-сообщениях или в обвязке кода Codex ЗАЯВЛЯЕТ численный результат («backfill для 51 items», «обновлено N файлов», «все 4 теста OK», «merged 3 streams») БЕЗ инкорпорированной команды-доказательства в самом коде/коммите — это RED FLAG. Помечай severity=serious с конкретикой:
- «commit message заявляет 51 items, но в коде только цикл foreach без проверки итогового count»
- «комментарий говорит "all parsed OK", но parse-проверка не возвращается / не логируется»
Это родилось из curator-задачи 2026-05-27 где Codex 3 раза подряд заявлял «backfill 51» при реальных 3/19/35.

🩺 ПРОВЕРКА: ЗАКРЫВАЕТ ЛИ ФИКС СИМПТОМ ИЛИ ТОЛЬКО МАСКИРУЕТ?
Задача обычно описывает симптом от пользователя («X мигает», «Y тормозит», «не могу Z»). Прежде чем дать OK:
1. Восстанови по тексту задачи: что именно увидел пользователь? Какой конкретный сценарий ломался?
2. Спроси сам себя: ЕСЛИ пользователь повторит этот сценарий после применения этого диффа — симптом ИСЧЕЗНЕТ или просто станет менее частым/будет глотаться guard'ом?
3. Если диф добавляет защиту (guard / try-catch / timeout / retry / epoch check / abort signal / debounce) — это часто МАСКА, а не фикс. Корень обычно лежит на этаж глубже: данные испорчены в источнике, а guard ловит их уже на выходе. Помечай severity=serious с пометкой «patches symptom, not root cause» и предложи где искать корень.
4. Особо для UI/HTTP пар: если диф меняет КЛИЕНТ (web/), но НЕ ТРОГАЕТ серверный эндпоинт, который этот клиент дёргает — это сильный сигнал маскировки. Перечисли эндпоинты, упомянутые в diff клиента, и спроси «их серверная сторона была пересмотрена в этом дифе?». Если нет — severity=serious с конкретным эндпоинтом для проверки.
5. Слова в комментариях кода и в коммит-сообщении: «race», «flicker», «stale», «timing», «debounce», «throttle», «retry» — это часто сигнал, что чинят временной симптом, а не источник несоответствия. Спроси «есть ли источник правды или два потока данных, которые расходятся?»

🔁 ПРОВЕРКА: ЭТО НЕ ПЕРВАЯ ПОПЫТКА?
Если в тексте задачи (или в HEAD-контексте ниже) есть признаки «уже исправляли», «повторяется», «снова», «опять», «ещё раз», «несмотря на <SHA>», ссылки на предыдущие коммиты-фиксы в этой же области — это RECURRENCE. Тогда:
- Назови явно, чем этот диф ОТЛИЧАЕТСЯ от прошлых попыток на уровне рут-каузы (а не имени файла).
- Если диф структурно ПОХОЖ на прошлые (тот же файл, та же функция, добавлен ещё один guard/epoch/abort/timeout) — severity=serious с подписью «N-th attempt, structurally similar to previous fix, root cause likely elsewhere».
- Если этот диф впервые трогает СОВСЕМ ДРУГОЙ слой (UI→server, client→config, lib→tests) — это хороший знак, не флаг.

ЗАДАЧА: $task

=== КОНТЕКСТ ЗАДАЧИ ===
DIFF_META: repo=$criticRepoRoot | base=$base | diff_truncated=$diffTruncatedText | diff_bytes=$diffBytes
DIFF ниже — полный диф от начала задачи до HEAD. Если diff_truncated=true — файлы за пределом могут быть изменены; их отсутствие в DIFF не доказывает, что они не менялись.
TASK_HISTORY показывает все коммиты задачи — используй его для проверки полноты фаз и файлов.
SYMBOL_EVIDENCE — сигнатуры и первые строки функций, вызванных в DIFF, но определённых в других файлах. Если функция есть в SYMBOL_EVIDENCE или в блоке "ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ" из HEAD-контекста — не флагируй её как отсутствующую. Duplicate/drift флагируй только если изменённые строки DIFF реально вводят конфликтующую реализацию.
Аудируй только строки DIFF со знаком + или -. Не аудируй unchanged код из SYMBOL_EVIDENCE, TASK_HISTORY или HEAD-контекста.

=== CHANGED_FILES ===
$changedFilesText

=== TASK_HISTORY ===
$taskHistory

=== SYMBOL_EVIDENCE ===
$symbolEvidence

КОНТЕКСТ HEAD (для проверки over-claim: функции, упомянутые в diff, существуют в этих файлах — не помечай их как несуществующие):
$headContext

$truncationNote

GIT-ДИФФ:
$diff

Верни СТРОГО JSON без markdown и без пояснений:
{"verdict":"OK","severity":"none","issues":[],"summary":"одна фраза по-русски"}
Где severity = "serious" ТОЛЬКО если есть баг/уязвимость/регрессия, которую обязательно исправить до закрытия; иначе "minor" или "none".
"@
            $rawC = Invoke-LLM -Purpose 'critic' -Model $criticModelName -Prompt $criticPrompt -TimeoutSec 90 -Temperature 0.1
            $verdict='OK'; $severity='none'; $summary=''; $issuesText=''
            if (-not [string]::IsNullOrWhiteSpace($rawC)) {
              $cleanC = ($rawC -replace '```json','' -replace '```','').Trim()
              $mC = [regex]::Match($cleanC, '(?s)\{.*\}')
              if ($mC.Success) {
                try {
                  $cv = $mC.Value | ConvertFrom-Json
                  if ($cv.verdict)  { $verdict  = [string]$cv.verdict }
                  if ($cv.severity) { $severity = ([string]$cv.severity).Trim().ToLower() }
                  if ($cv.summary)  { $summary  = [string]$cv.summary }
                  if ($cv.issues) {
                    $issueParts = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($issue in @($cv.issues)) {
                      if ($null -eq $issue) { continue }
                      if ($issue -is [string]) {
                        $txtIssue = ([string]$issue).Trim()
                      } else {
                        $fields = New-Object 'System.Collections.Generic.List[string]'
                        foreach ($pn in @('file','line','severity','issue','problem','message','summary','fix')) {
                          try {
                            if ($issue.PSObject.Properties.Name -contains $pn) {
                              $pv = [string]$issue.$pn
                              if (-not [string]::IsNullOrWhiteSpace($pv)) { [void]$fields.Add(("{0}={1}" -f $pn,$pv)) }
                            }
                          } catch {}
                        }
                        if ($fields.Count -gt 0) { $txtIssue = [string]::Join(' | ', [string[]]@($fields.ToArray())) }
                        else { $txtIssue = ($issue | ConvertTo-Json -Compress -Depth 4) }
                      }
                      if (-not [string]::IsNullOrWhiteSpace($txtIssue)) { [void]$issueParts.Add($txtIssue) }
                    }
                    $issuesText = [string]::Join('; ', [string[]]@($issueParts.ToArray()))
                  }
                } catch {}
              }
            }
            if ([string]::IsNullOrWhiteSpace($issuesText) -and -not [string]::IsNullOrWhiteSpace($summary)) { $issuesText = $summary }

            # 2026-06-02: quality-bypass findings ALWAYS escalate to 'serious'.
            # Passing build by disabling build/type/lint checks is not an implementation;
            # project autonomy must fix the actual code and keep gates meaningful.
            if ($qualityBypassIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $qbPrefix = "Отключение проверок качества (ground-truth diff check): " + $qualityBypassIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $qbPrefix }
              else { $issuesText = $qbPrefix + ' ; ' + $issuesText }
            }

            # 2026-05-27: CLI-flag findings ALWAYS escalate to 'serious' regardless
            # of what the LLM critic decided. Deterministic checks override LLM
            # opinion (the LLM cannot run the CLI, so trust ground truth).
            if ($cliFlagIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $prefix = "Неверные CLI-флаги (ground-truth check, --help проверен реально): " + $cliFlagIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $prefix }
              else { $issuesText = $prefix + ' ; ' + $issuesText }
            }

            $taskShort = ($task -replace '\s+',' ').Trim()
            if ($taskShort.Length -gt 80) { $taskShort = $taskShort.Substring(0,80) }
            try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + "  model=$criticModelName verdict=$verdict severity=$severity crc=$crc | $taskShort | $summary | $issuesText") -Encoding UTF8 } catch {}
            if ($severity -eq 'serious') {
              $newCrc = $crc + 1
              Update-State ({ param($s) $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue $newCrc -Force }.GetNewClosure()) | Out-Null
              try { Set-TaskLastFailure -Kind critic_rejected -Text $issuesText } catch {}
              Add-Message -From system -Text "🔎 Независимый критик ($criticModelName) нашёл серьёзное (попытка $newCrc/$criticMaxRetries): $issuesText`n`nCodex, исправь это и снова доведи до STATUS: DONE — задачу НЕ закрываю." -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
              Update-State { param($s) $s.task_mode='normal' } | Out-Null
            } else {
              Add-Message -From system -Text "🔎 Критик ($criticModelName): $verdict / $severity — $summary" -Kind event | Out-Null
            }
          }
        }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + '  critic-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Fast ParseFile gate: syntax-check each changed .ps1 individually before slow smoke.
  # Gives specific file+line errors instantly; also catches newly-created .ps1 not yet in smoke list.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $pfFiles = @()
        try { $pfFiles = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { $_ -match '\.ps1$' }) } catch {}
        $pfFailed = $false
        foreach ($psf in $pfFiles) {
          $fullPath = Join-Path $bridgeRoot $psf
          if (Test-Path $fullPath) {
            $pfErrors = $null; $pfTokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($fullPath,[ref]$pfTokens,[ref]$pfErrors) | Out-Null
            if ($pfErrors -and $pfErrors.Count -gt 0) {
              $errLine = $pfErrors[0].Extent.StartLineNumber; $errMsg = $pfErrors[0].Message
              Add-Message -From system -Text "🚨 ParseFile FAILED: $psf line $errLine — $errMsg. Codex, исправь синтаксис." -Kind event | Out-Null
              Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
              $plannerStatus = 'CONTINUE'; $pfFailed = $true; break
            }
          }
        }
        if (-not $pfFailed -and $pfFiles.Count -gt 0) {
          Add-Message -From system -Text "✅ ParseFile OK: $($pfFiles -join ', ')" -Kind event | Out-Null
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  parsefile-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Auto-smoke gate: after critic passes, if .ps1 files changed vs HEAD, run smoke.ps1 to catch
  # broken masts before accepting DONE. Reuses verify_retry_count so no new state field needed.
  # Catches cases where [[VERIFIED: smoke OK]] is claimed but smoke actually fails.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $psChanged = $false
        try {
          $gitSmFiles = & git -C $bridgeRoot diff --name-only HEAD 2>$null
          $psChanged = (@($gitSmFiles | Where-Object { $_ -match '\.ps1$' })).Count -gt 0
        } catch {}
        if ($psChanged) {
          $smokeFile = Join-Path $bridgeRoot 'smoke.ps1'
          if (Test-Path $smokeFile) {
            $launch = [pscustomobject]@{ File = $smokeFile; Channel = (Get-EffectiveChannel) }
            $smokeOut = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
              param($Launch)
              & powershell -NoProfile -ExecutionPolicy Bypass -File ([string]$Launch.File) 2>&1 | Out-String
            }
            $smokeOk  = $smokeOut -imatch 'SMOKE OK'
            $smokeVrc = [int](Read-State).verify_retry_count
            if (-not $smokeOk) {
              $smokeShort = ($smokeOut -replace '\s+',' ').Trim()
              if ($smokeShort.Length -gt 300) { $smokeShort = $smokeShort.Substring(0,300) + '...' }
              try { Set-TaskLastFailure -Kind smoke_failed -Text $smokeShort } catch {}
              if ($smokeVrc -lt 2) {
                Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$false } | Out-Null
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
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  auto-smoke-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
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
          Add-Message -From system -Text "🔴 QA-агент: FAIL`n$($qaResult.Summary)`nВозвращаю задачу на доработку." -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
        } else {
          Add-Message -From system -Text "✅ QA-агент: PASS — $($qaResult.Summary)" -Kind event | Out-Null
        }
      }
    } catch {
      Add-Message -From system -Text "⚠ QA-агент: ошибка запуска ($($_.Exception.Message)), пропускаю." -Kind event | Out-Null
    }
  }

  # Project Autopilot stop-condition: record the coordinator outcome only after
  # STATUS/COVERED/verification gates have settled the final planner status.
  if ($plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stPaOutcome = Read-State
      $paTask = [string]$stPaOutcome.current_task
      $paBacklogId = [string]$stPaOutcome.current_backlog_id
      if (Get-Command Test-ProjectAutopilotCoordinatorText -ErrorAction SilentlyContinue) {
        $paIsCoordinator = [bool](Test-ProjectAutopilotCoordinatorText -Text $paTask)
      } else {
        $paIsCoordinator = [bool]([regex]::IsMatch($paTask, '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel'))
      }
      if ($paIsCoordinator -and (Get-Command Record-ProjectAutopilotCoordinatorOutcome -ErrorAction SilentlyContinue)) {
        $paChannel = ''
        $paRoot = ''
        try { $paChannel = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'slug' -Default '') } catch {}
        try { $paRoot = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'project_root' -Default '') } catch {}
        Record-ProjectAutopilotCoordinatorOutcome -Channel $paChannel -ProjectRoot $paRoot -CoordinatorId $paBacklogId -Created ([int]$projectBacklogCreated) -Reason 'final-planner-status-done' | Out-Null
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Project Autopilot outcome tracking failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }

  if ($plannerStatus -eq 'CONTINUE') {
    try {
      $stCp = Read-State
      $cpTaskId = [string]$stCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = [string]$stCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = 'task-' + [string]$stCp.task_start_seq }
      $cpStep = 0
      try { $cpStep = [int]$stCp.task_turn } catch { $cpStep = 0 }
      $conversationSummary = ''
      try {
        $conversationSummary = [string](Read-Summary)
      } catch {
        try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  summary-read-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
      }
      $cpSummary = if ($conversationSummary) { $conversationSummary.Substring(0, [Math]::Min(500, $conversationSummary.Length)) } else { '' }
      Write-TaskCheckpoint -TaskId $cpTaskId -TaskTitle $task -Step $cpStep -LastSummary $cpSummary -Channel $Channel
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  checkpoint-write-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE') {
    if ($mode -eq 'discuss') {
      try {
        $startSeqD = [int](Read-State).task_start_seq
        $thread = (Get-Messages -Since ($startSeqD - 1) | ForEach-Object { "**$($_.from):** $($_.text)" }) -join "`n`n"
        $dpath = Save-Decision -Title $task -Content $thread
        Add-Message -From system -Text "📝 Итог обсуждения сохранён: $dpath" -Kind event | Out-Null
      } catch {}
    }
    try {
      $memId = Add-TaskMemory -TaskText $task -Outcome $visibleReply -Source ('task:' + $mode)
      if ($memId) { Add-Message -From system -Text "🧠 Запомнено в долговременную память." -Kind event | Out-Null }
    } catch {}
    try {
      $stWorklog = Read-State
      $didWorklogActions = [bool]$stWorklog.task_did_actions
      if (($didWorklogActions -or $mode -eq 'study') -and (Get-Command Update-ProjectMemoryAfterTask -ErrorAction SilentlyContinue)) {
        $commitForWorklog = ''
        try {
          $rootForWorklog = Get-ActiveProjectRoot
          if (-not [string]::IsNullOrWhiteSpace($rootForWorklog)) {
            $commitForWorklog = (& git -C $rootForWorklog rev-parse --short HEAD 2>$null).Trim()
          }
        } catch {}
        $worklogId = Update-ProjectMemoryAfterTask -TaskText $task -Outcome $visibleReply -Channel $Channel -Commit $commitForWorklog
        if ($worklogId) { Add-Message -From system -Text "🧠 Проектная память: worklog обновлён." -Kind event | Out-Null }
      }
    } catch {}
    try {
      $stMem = Read-State
      $turnForSkill = [int]$stMem.task_turn
      $didActionsForSkill = [bool]$stMem.task_did_actions
      if ($turnForSkill -ge 2 -and $didActionsForSkill -and $modeBeforeIncrement -ne 'study') {
        $startSeqSkill = [int]$stMem.task_start_seq
        $thread = (Get-Messages -Since ($startSeqSkill - 1) | ForEach-Object {
          "**$($_.from):** $($_.text)"
        }) -join "`n`n"
        $skillId = Add-SkillMemory -TaskText $task -Transcript $thread
        if ($skillId) { Add-Message -From system -Text "📘 плейбук сохранён." -Kind event | Out-Null }
      }
    } catch {}
    try {
      if ($modeBeforeIncrement -eq 'study') {
        $studyReportPath = $null
        foreach ($fp in $fileMarkerPaths) {
          try {
            $candidate = [string]$fp
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.md' -and (Test-Path -LiteralPath $candidate)) {
              $studyReportPath = $candidate
              break
            }
          } catch {}
        }
        if ($studyReportPath) {
          $lessonCount = Add-StudyLessons -ReportPath $studyReportPath -TaskText $task
          Add-Message -From system -Text "🎓 уроков: $lessonCount" -Kind event | Out-Null
        }
      }
    } catch {}
    # If this was an autonomous backlog task, close it out.
    try {
      $stDoneBacklog = Read-State
      $doneBid = [string]$stDoneBacklog.current_backlog_id
      $doneBatchIds = @()
      try {
        if ($stDoneBacklog.PSObject.Properties.Name -contains 'workpack_batch_ids' -and $null -ne $stDoneBacklog.workpack_batch_ids) {
          $doneBatchIds = @($stDoneBacklog.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
      } catch { $doneBatchIds = @() }
      $doneIds = if ($doneBatchIds.Count -gt 0) { @($doneBatchIds) } elseif ($doneBid) { @($doneBid) } else { @() }
      if ($doneIds.Count -gt 0) {
        foreach ($doneId in $doneIds) { Set-Idea -Id $doneId -Status 'done' | Out-Null }
        # 🤖 Autonomy metric (Foundation #3): the honest self-sufficiency number — autonomous backlog
        # tasks closed IN A ROW with zero operator messages between them. Increment on each autonomous
        # done; the user-message handler resets the running streak to 0 (best is preserved here).
        $doneIncrement = [Math]::Max(1, [int]$doneIds.Count)
        Update-State ({ param($s)
          $cur = 0; try { $cur = [int]$s.autonomy_streak } catch {}
          $cur += $doneIncrement
          $best = 0; try { $best = [int]$s.autonomy_streak_best } catch {}
          if ($cur -gt $best) { $best = $cur }
          $s | Add-Member -NotePropertyName autonomy_streak      -NotePropertyValue $cur  -Force
          $s | Add-Member -NotePropertyName autonomy_streak_best -NotePropertyValue $best -Force
        }.GetNewClosure()) | Out-Null
        $stk = Read-State
        $sNow = 0; try { $sNow = [int]$stk.autonomy_streak } catch {}
        $sBest = 0; try { $sBest = [int]$stk.autonomy_streak_best } catch {}
        $bestTxt = if ($sBest -gt $sNow) { " (рекорд: $sBest)" } else { '' }
        if ($doneIds.Count -gt 1) {
          Add-Message -From system -Text ("✅ Workpack-batch выполнен: закрыто задач бэклога: " + $doneIds.Count + ". 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Автозадача из бэклога выполнена и закрыта. 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        }
      }
    } catch {}
    # Mark ANY self-improvement commit as a hypothesis for the 24h verdict cycle (was previously
    # only autonomous backlog tasks -> we missed user-injected tasks and Doctor fixes entirely).
    # Wave 3 widening: any task that changed HEAD vs task_base_commit gets a baseline+commit row.
    try {
      $stEnd = Read-State
      $baseC = [string]$stEnd.task_base_commit
      $headC = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
      if ($baseC -and $headC -and $baseC -ne $headC) {
        Write-Hypothesis -CommitHash $headC -TaskText ([string]$task)
      }
    } catch {}
    # 🌱 Self-dev attribution: stamp the resulting commit on a self-executed idea so the safety
    # reflex can later correlate it to the 24h verdict (worse -> auto-dampen the dial). Read-mostly.
    try {
      $stSd = Read-State
      $sdBid = [string]$stSd.current_backlog_id
      if ($sdBid) {
        $sdIdea = Get-IdeaById $sdBid
        if ($sdIdea -and ([bool]$sdIdea.self_exec)) {
          $sdHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
          if ($sdHead) { Set-IdeaSelfExec -Id $sdBid -Dial ([string]$sdIdea.self_exec_dial) -Commit $sdHead | Out-Null }
        }
      }
    } catch {}
    try { Invoke-PostTaskSelfModelRefresh -Channel $Channel -BridgeRoot $bridgeRoot | Out-Null } catch {}
    # Delivery gate shadow: evidence-only report, never blocks DONE or release.
    if ($modeBeforeIncrement -eq 'normal') {
      try {
        $stDg = Read-State
        $dgTaskId = [string]$stDg.current_task_id
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = [string]$stDg.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = 'task-' + [string]$stDg.task_start_seq }
        $dgBase = [string]$stDg.task_base_commit
        $dgHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
        $dgEvents = @(@{ text = [string]$visibleReply })
        $dgAcceptancePassed = Get-DeliveryGateAcceptanceFact `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents
        $dgFacts = New-DeliveryGateInputFacts `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents `
          -QaPassed $true `
          -CriticPassed $true `
          -ParsePassed $true `
          -SmokePassed $true `
          -AcceptancePassed $dgAcceptancePassed `
          -MemoryUpdated $true `
          -SelfModelRefreshed $true `
          -ParallelObligationOk $true
        $dgResult = Get-DeliveryGateResult -InputFacts $dgFacts
        $dgWrite = Write-DeliveryGateShadowRecord `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskId $dgTaskId `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Facts $dgFacts `
          -Result $dgResult `
          -Note 'shadow-only; no DONE/release blocking'
        $dgReason = [string]$dgResult.reason
        if ($dgReason.Length -gt 160) { $dgReason = $dgReason.Substring(0,160) + '...' }
        Add-Message -From system -Text ("🧪 Delivery gate shadow: ok=$($dgResult.ok) risk=$($dgResult.risk) release=$($dgResult.release_allowed) reason=$dgReason") -Kind event | Out-Null
        if (-not [bool]$dgWrite.ok) {
          Add-Message -From system -Text ("⚠ Delivery gate shadow write failed: " + [string]$dgWrite.error) -Kind event | Out-Null
        }
      } catch {
        try { Add-Message -From system -Text ("⚠ Delivery gate shadow failed open: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      }
    }
    # Delivery gate shadow end.
    # 🩺 If Doctor just finished a repair, restore the held task instead of going idle.
    if ([bool](Read-State).doctor_active) {
      try { Complete-Doctor } catch { try { Add-Message -From system -Text ("🩺 Complete-Doctor: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
      try { Send-PushEvent -Kind done -Text "🩺 Doctor fix shipped; resuming held task." } catch {}
      continue
    }
    try { Send-PushEvent -Kind done -Text "Задача: $(Get-PushSnippet -Text $task)" } catch {}
    Add-Message -From system -Text "✅ Задача выполнена. Жду следующую." -Kind event | Out-Null
    try {
      $stDoneCp = Read-State
      $doneCpTaskId = [string]$stDoneCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = [string]$stDoneCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = 'task-' + [string]$stDoneCp.task_start_seq }
      Clear-TaskCheckpoint -TaskId $doneCpTaskId -Channel $Channel
    } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s -PreserveReflectSkip; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
}
