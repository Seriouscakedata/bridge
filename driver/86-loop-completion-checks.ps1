# Loop-completion status/verification checks.
# These scriptblocks are dot-invoked by 86-loop-completion.ps1 so `continue` keeps the driver loop contract.
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
  # Gate-regression gate: before DONE promotion, run the full snapshot suite only
  # when this task touched gate/control-plane paths. Docs/HTML/config-only edits
  # intentionally produce an empty scope and must not block promotion.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stGate = Read-State
      if ([bool]$stGate.task_did_actions) {
        $gateChangedPaths = New-Object 'System.Collections.Generic.List[string]'
        $gateSeenPaths = @{}
        $addGatePath = {
          param($RawPath)
          if ($null -eq $RawPath) { return }
          $normalized = ([string]$RawPath).Trim()
          if ([string]::IsNullOrWhiteSpace($normalized)) { return }
          $normalized = $normalized -replace '\\','/'
          if (-not $gateSeenPaths.ContainsKey($normalized)) {
            $gateSeenPaths[$normalized] = $true
            [void]$gateChangedPaths.Add($normalized)
          }
        }

        $gitSafeDirectory = "safe.directory=$bridgeRoot"
        $gateBase = [string]$stGate.task_base_commit
        if (-not [string]::IsNullOrWhiteSpace($gateBase)) {
          $gateBaseType = ''
          try { $gateBaseType = [string]((& git -c $gitSafeDirectory -C $bridgeRoot cat-file -t $gateBase 2>$null | Select-Object -First 1) -join '') } catch { $gateBaseType = '' }
          if ($gateBaseType.Trim() -eq 'commit') {
            try {
              foreach ($p in @(& git -c $gitSafeDirectory -C $bridgeRoot diff --name-only $gateBase HEAD 2>$null)) {
                & $addGatePath $p
              }
            } catch {}
          }
        }

        try {
          foreach ($p in @(& git -c $gitSafeDirectory -C $bridgeRoot diff --name-only --cached 2>$null)) {
            & $addGatePath $p
          }
        } catch {}
        try {
          foreach ($p in @(& git -c $gitSafeDirectory -C $bridgeRoot diff --name-only 2>$null)) {
            & $addGatePath $p
          }
        } catch {}
        try {
          foreach ($p in @(& git -c $gitSafeDirectory -C $bridgeRoot ls-files --others --exclude-standard 2>$null)) {
            & $addGatePath $p
          }
        } catch {}

        $gateScope = @(Get-GateRegressionScope -ChangedPaths @($gateChangedPaths.ToArray()))
        if ($gateScope.Count -eq 0) {
          Add-Message -From system -Text "🧪 Gate-regression: scope empty, skipped." -Kind event | Out-Null
        } else {
          $gateResult = $null
          $gateOk = $false
          for ($gateAttempt = 1; $gateAttempt -le 2; $gateAttempt++) {
            Add-Message -From system -Text ("🧪 Gate-regression: running snapshot suite (attempt {0}/2, timeout 180s)." -f $gateAttempt) -Kind event | Out-Null
            $gateResult = Invoke-GateRegressionSuite -BridgeRoot $bridgeRoot -TimeoutSec 180
            if ($gateResult -and [bool]$gateResult.Ok) {
              $gateOk = $true
              Add-Message -From system -Text "✅ Gate-regression: snapshot suite PASS." -Kind event | Out-Null
              break
            }
            if ($gateAttempt -lt 2) {
              $retryReason = if ($gateResult) { "exit=$($gateResult.ExitCode), timedOut=$($gateResult.TimedOut)" } else { 'no result' }
              Add-Message -From system -Text ("🚨 Gate-regression failed ({0}); retrying once." -f $retryReason) -Kind event | Out-Null
            }
          }
          if (-not $gateOk) {
            $failReason = if ($gateResult) { "exit=$($gateResult.ExitCode), timedOut=$($gateResult.TimedOut)" } else { 'no result' }
            try { Set-TaskLastFailure -Kind gate_regression_failed -Text $failReason } catch {}
            Add-Message -From system -Text ("🚨 Gate-regression FAILED after retry ({0}). Gate/control-plane scope is fail-closed; возвращаю задачу на CONTINUE." -f $failReason) -Kind event | Out-Null
            $plannerStatus = 'CONTINUE'
          }
        }
      }
    } catch {
      Add-Message -From system -Text ("⚠ Gate-regression: exception before scoped run (" + $_.Exception.Message + "), skipped.") -Kind event | Out-Null
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
}
