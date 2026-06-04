$script:DriverLoopIdleClaimBlock = {
  if (-not $state.current_task) {
    if ($maxUser -gt [int]$state.last_user_seq) {
      $script:idleStreak = 0   # user activity -> restore snappy idle cadence
      # 🤖 Autonomy metric (Foundation #3): operator stepped in -> the "no-intervention" streak ends.
      # Best is already captured at done-time; just reset the running counter.
      try { Update-State { param($s) $s | Add-Member -NotePropertyName autonomy_streak -NotePropertyValue 0 -Force } | Out-Null } catch {}
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      $projectBindingForTask = Get-ActiveProjectBinding
      if ($projectBindingForTask -and ([string]$projectBindingForTask.slug -ne 'main') -and -not [bool]$projectBindingForTask.ok) {
        $slugForTask = [string]$projectBindingForTask.slug
        $reasonForTask = [string]$projectBindingForTask.error
        if ([string]::IsNullOrWhiteSpace($reasonForTask)) { $reasonForTask = "Канал '$slugForTask' не привязан к проекту" }
        $msg = @"
⚠ Канал '$slugForTask' не привязан к проекту. Задачу не запускаю, чтобы не уйти в bridge.

Добавь привязку в settings.json:
{
  "channels": {
    "$slugForTask": {
      "projectPath": "C:\\путь\\к\\проекту",
      "projectType": "тип проекта",
      "projectDescription": "краткое описание"
    }
  }
}

Причина: $reasonForTask
Затем повтори задачу.
"@
        Add-Message -From system -Text $msg -Kind event | Out-Null
        Update-State ({ param($s)
          $s.last_user_seq=$maxUser
          $s.current_task=$null
          $s.current_task_id=$null
          $s.status='idle'
          $s.active_agent=$null
          $s.active_model=$null
          $s.status_text=$null
          $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        Start-Sleep -Seconds $loopDelay
        continue
      }
      $studyDetect = Detect-StudyMode -TaskText $taskMsg
      # 🧭 [[DEEP-THINK]] marker forces discuss-mode dialog (Claude↔Codex back-and-forth)
      # instead of normal planner->coder. Used by Start-DeepThinkDialog on Sat/Sun nights.
      #
      # FIX 2026-05-27: anchor the marker to its own line at start (multi-line ^). Previously
      # the regex matched the literal anywhere in the task text -- so if a spec MENTIONED the
      # marker in an example or referenced it in instructions to Codex, the task itself
      # got routed to discuss-mode. Now requires marker to be alone on a line (with optional
      # leading whitespace) -- can't be inside code blocks, quotes, or prose.
      $deepThinkMark = [bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[DEEP-THINK\]\]\s*$'))
      # 2026-05-28: ALSO trigger discuss-mode if task contains explicit discussion
      # verbs anywhere in text. This is a deterministic override BEFORE the LLM
      # intent classifier — was needed because classifier weighs by overall
      # task topic and silently drops "обсудите коротко" sections in mostly-
      # implementation tasks. Forces discuss when user explicitly asks for it,
      # regardless of how much implementation spec is attached.
      $discussVerbRegex = '(?im)\b(обсуди(?:м|те|ть)?|обсудим(?:те)?|посоветуйс(?:я|е)|согласуй(?:те|тесь)?|давайте\s+обсудим|подумайте\s+вместе|перед(?:\s+тем)?\s+(?:чем|как)[^.]{0,80}обсуд|coordinate\s+with\s+codex|discuss\s+with\s+codex)'
      $discussVerbMark = [bool]([regex]::IsMatch($taskMsg, $discussVerbRegex))
      # [[NORMAL]] override forces task_mode=normal even if other auto-detect would route
      # elsewhere (study/discuss). For operators who know "obsuzhdat' nechego, delay".
      # [[NORMAL]] OR an explicit operator "finish / don't loop / this is recon" instruction wins
      # over the LLM intent classifier. FIX 2026-05-29: the classifier forced discuss on an audit
      # task that literally said "STATUS: DONE, без дебатов, не зацикливайся" -> it then looped on
      # the already-finished work. Operator phrasing must override the heuristic.
      $normalOverride = ([bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[NORMAL\]\]\s*$'))) -or ([bool]([regex]::IsMatch($taskMsg, '(?i)(не\s+зациклив|без\s+дебат|не\s+обсужда|не\s+уходи\s+в\s+обсужд|status:\s*done\b|это\s+разведка,?\s+не\s+стройка|один\s+сфокусированн\w*\s+проход)')))
      $fastLaneCfg = Get-FastLaneSettings
      # Control markers are commands only in the task header. Long prompts often
      # contain marker names in feature descriptions/examples.
      $fastMark = Test-TaskControlMarker -TaskText $taskMsg -Marker 'FAST'
      $reasoningHighMark = [bool]([regex]::IsMatch($taskMsg, '\[\[REASONING:high\]\]'))
      $autoFastLane = $false
      if (-not $fastMark -and -not $reasoningHighMark -and [bool]$fastLaneCfg.autoDetect) {
        $autoFastLane = Test-IsTrivialTask -TaskText $taskMsg -MinChars ([int]$fastLaneCfg.minChars)
      }
      $fastLaneReason = ''
      if ($fastMark -and -not $reasoningHighMark) { $fastLaneReason = 'marker' }
      elseif ($autoFastLane) { $fastLaneReason = 'auto' }

      # 2026-05-28: LLM intent classifier. Replaces hardcoded [[DEEP-THINK]] regex
      # with semantic understanding of the user's task. Explicit markers
      # ([[FAST]], [[NORMAL]], [[DEEP-THINK]]) always win; the LLM call only
      # fires when no marker forces a mode. Confidence threshold 0.7 prevents
      # acting on uncertain classifications (falls through to legacy detection).
      # Decomposed subtasks are surfaced to the planner via Format-IntentForPrompt
      # in Build-PromptHistory so the planner sees the structured breakdown,
      # not just a single mode tag.
      $taskIntent = $null
      if (-not $fastLaneReason -and -not $normalOverride -and -not $deepThinkMark -and (Get-Command Test-TaskIntent -ErrorAction SilentlyContinue)) {
        try { $taskIntent = Test-TaskIntent -TaskText $taskMsg -TimeoutSec 25 } catch { $taskIntent = $null }
      }
      $intentMode = ''
      if ($taskIntent -and [double]$taskIntent.confidence -ge 0.7) {
        $intentMode = [string]$taskIntent.primary_mode
      }
      # Convert intent into legacy mode flags so the existing switch below stays simple.
      $intentForcedFastLane = ($intentMode -eq 'fast')
      $intentForcedDiscuss  = ($intentMode -eq 'discuss')
      $intentForcedStudy    = ($intentMode -eq 'study')
      # 2026-05-29 complexity throttle: even when the classifier routed to a
      # heavy mode (e.g. discuss) by topic, a CONFIDENT trivial/simple verdict
      # means the task does not warrant the full ceremony. Test-IntentLowComplexity
      # gates on confidence>=0.7 + complexity in {trivial,simple} + turns<=4.
      # This is the fix for "show a desktop screenshot" being routed to a ~7-min
      # discuss debate. Honour the operator's autoDetect switch so the throttle
      # can be disabled wholesale; explicit markers already suppress $taskIntent.
      $intentLowComplexity = $false
      if ($taskIntent -and [bool]$fastLaneCfg.autoDetect -and (Get-Command Test-IntentLowComplexity -ErrorAction SilentlyContinue)) {
        try { $intentLowComplexity = [bool](Test-IntentLowComplexity -Intent $taskIntent) } catch { $intentLowComplexity = $false }
      }
      # Fast-lane skips planner/critic/reflect, so auto-routed intent fast paths
      # are limited to safe reversible OS/UI/read commands. Explicit [[FAST]]
      # remains an operator opt-in via $fastLaneReason='marker'.
      $fastLaneSafe = $false
      try { $fastLaneSafe = [bool](Test-IsSafeOsFastLaneTask -TaskText $taskMsg) } catch { $fastLaneSafe = $false }
      if (-not $fastLaneSafe) { $intentForcedFastLane = $false; $intentLowComplexity = $false }

      $taskProjectRoot = Get-ActiveProjectRoot
      if ([string]::IsNullOrWhiteSpace($taskProjectRoot)) { $taskProjectRoot = $bridgeRoot }
      $baseCommit = try { (& git -C $taskProjectRoot rev-parse HEAD 2>$null).Trim() } catch { '' }

      # Snapshot intent for the state mutator closure.
      $intentRecord = $null
      if ($taskIntent) {
        $intentRecord = [pscustomobject]@{
          primary_mode = [string]$taskIntent.primary_mode
          mode = [string]$taskIntent.primary_mode
          confidence = [double]$taskIntent.confidence
          reasoning = [string]$taskIntent.reasoning
          user_wants_dialogue = [bool]$taskIntent.user_wants_dialogue
          complexity = [string]$taskIntent.complexity
          estimated_turns = [int]$taskIntent.estimated_turns
          subtasks = @($taskIntent.subtasks)
          model = [string]$taskIntent.model
          ts = (Get-Date).ToUniversalTime().ToString('o')
        }
      }
      $intentForcedFastLaneClosure = $intentForcedFastLane
      $intentForcedDiscussClosure  = $intentForcedDiscuss
      $intentForcedStudyClosure    = $intentForcedStudy
      $discussVerbClosure          = $discussVerbMark
      $intentLowComplexityClosure  = $intentLowComplexity

      Update-State ({ param($s)
        $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'
        Start-ReplayForStateTask -State $s -TaskText $taskMsg -ChannelName $Channel
        $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
        Clear-FastLaneFlags $s
        # Precedence: explicit markers > discuss-verb regex > LLM intent (high conf) > legacy detection.
        # discuss-verb is BEFORE the LLM intent fork: deterministic catch for
        # "обсуди" в любом месте текста, не зависит от того что классификатор
        # решил по доминирующей теме задачи (он часто прозевает discuss-секции
        # в задачах с большим implementation-спеком).
        # 2026-05-29: a CONFIDENT trivial/simple verdict ($intentLowComplexityClosure)
        # neuters the two "discuss" branches so a 1-line change can't be dragged into
        # a multi-turn Claude<->Codex debate; it then lands on the new fast-lane catch
        # below (after study, which keeps its own output contract). Markers/normal/
        # deep-think still win because they suppress $taskIntent upstream.
        if ($fastLaneReason) { Set-FastLaneFlags -State $s -Reason $fastLaneReason; $s.task_mode='normal' }
        elseif ($normalOverride) { $s.task_mode='normal' }  # explicit operator force
        elseif ($deepThinkMark) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($discussVerbClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedFastLaneClosure) { Set-FastLaneFlags -State $s -Reason 'llm-intent'; $s.task_mode='normal' }
        elseif ($intentForcedDiscussClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedStudyClosure) { $s.task_mode='study'; $s.study_subtype='external'; $s.study_phase='plan' }
        elseif ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
        elseif ($intentLowComplexityClosure) { Set-FastLaneFlags -State $s -Reason 'llm-simple'; $s.task_mode='normal' }
        $s.task_start_seq=$maxUser; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$null; $s.status='working'; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
        $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
        # 2026-05-28: reset restart-counter when a new task arrives. Counter
        # tracks "this task survived N driver restarts without closing" and
        # auto-fails the task at $maxRestarts (boot.ps1 resume block).
        $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force
        Clear-AuditorSuppressedHashes -State $s
        Clear-ChunkingState $s
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
        $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
        # Persist intent so planner can render it via Format-IntentForPrompt on later turns too.
        $s | Add-Member -NotePropertyName task_intent -NotePropertyValue $intentRecord -Force
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      # 2026-06-03 slimming Atom 4b (SHADOW): Intent Decision Shadow at the REAL decision site.
      # Record what Test-TaskIntent PROPOSED vs the mode the guard precedence ACTUALLY applied just
      # above. Pure logging — routing already happened in the closure; nothing here changes it. The
      # effective_mode/effective_reason cascade below MIRRORS the precedence at L162-170; keep in sync
      # if that precedence changes. Guarded so it can never break claim.
      try {
        if (Get-Command Write-IntentShadow -ErrorAction SilentlyContinue) {
          $effMode = 'normal'; $effReason = 'default-normal'
          if ($fastLaneReason) { $effMode = 'fast'; $effReason = "fastlane:$fastLaneReason" }
          elseif ($normalOverride) { $effMode = 'normal'; $effReason = 'normal-override' }
          elseif ($deepThinkMark) { $effMode = 'discuss'; $effReason = 'deep-think-marker' }
          elseif ($discussVerbMark -and -not $intentLowComplexity) { $effMode = 'discuss'; $effReason = 'discuss-verb' }
          elseif ($intentForcedFastLane) { $effMode = 'fast'; $effReason = 'llm-intent-fast' }
          elseif ($intentForcedDiscuss -and -not $intentLowComplexity) { $effMode = 'discuss'; $effReason = 'llm-intent-discuss' }
          elseif ($intentForcedStudy) { $effMode = 'study'; $effReason = 'llm-intent-study' }
          elseif ($studyDetect) { $effMode = 'study'; $effReason = 'legacy-study' }
          elseif ($intentLowComplexity) { $effMode = 'fast'; $effReason = 'llm-simple' }
          $guardOverrides = @{
            marker_fast             = [bool]$fastMark
            marker_normal           = [bool]$normalOverride
            marker_deepthink        = [bool]$deepThinkMark
            discuss_verb            = [bool]$discussVerbMark
            low_confidence          = [bool]($taskIntent -and ([double]$taskIntent.confidence -lt 0.7))
            unsafe_fastlane_blocked = [bool]($taskIntent -and ([string]$taskIntent.primary_mode -eq 'fast') -and (-not $fastLaneSafe))
            study_detect            = [bool]$studyDetect
            low_complexity          = [bool]$intentLowComplexity
          }
          $mPrimary = if ($taskIntent) { [string]$taskIntent.primary_mode } else { '' }
          $mConf    = if ($taskIntent) { [double]$taskIntent.confidence } else { $null }
          $mCplx    = if ($taskIntent) { [string]$taskIntent.complexity } else { '' }
          $mTurns   = if ($taskIntent) { [int]$taskIntent.estimated_turns } else { $null }
          Write-IntentShadow -Channel $Channel -ModelPrimaryMode $mPrimary -ModelConfidence $mConf -ModelComplexity $mCplx -ModelEstimatedTurns $mTurns -ModelConsulted ([bool]$taskIntent) -EffectiveMode $effMode -EffectiveReason $effReason -GuardOverrides $guardOverrides | Out-Null
        }
      } catch {}
      try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
      try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
      Add-Message -From system -Text "📥 Новая задача принята в работу." -Kind event | Out-Null
      if ($fastLaneReason -eq 'marker') { Add-Message -From system -Text "🚀 Fast-lane активирован ([[FAST]])" -Kind event | Out-Null }
      elseif ($fastLaneReason -eq 'auto') { Add-Message -From system -Text "🚀 Auto fast-lane detected (короткая императивная задача)" -Kind event | Out-Null }
      if ($normalOverride -and -not $fastLaneReason) { Add-Message -From system -Text "📐 [[NORMAL]] override -- task_mode=normal forced (auto-detect bypassed)." -Kind event | Out-Null }
      if ($deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) { Add-Message -From system -Text "🧭💭 Deep-think dialog detected — режим: discuss (Claude↔Codex до сходимости, max 6 ходов)." -Kind event | Out-Null }
      if ($discussVerbMark -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentLowComplexity) { Add-Message -From system -Text "🗣 Discuss-verb detected (обсуди/согласуйте/...) — режим: discuss (Claude↔Codex до сходимости, max 6 ходов). Хочешь обычный режим без обсуждения — добавь [[NORMAL]] в начало задачи." -Kind event | Out-Null }
      if ($studyDetect -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentForcedDiscuss -and -not $intentForcedStudy -and -not $intentForcedFastLane) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: user" -Kind event | Out-Null }
      # 2026-05-28: announce LLM-classifier verdict so user sees what mode was inferred and why.
      if ($taskIntent -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) {
        $confPct = [int]([double]$taskIntent.confidence * 100)
        $verdictText = "🧠 LLM-классификатор намерения ($([string]$taskIntent.model)): mode=" + [string]$taskIntent.primary_mode + ", confidence=$confPct%"
        if (-not [string]::IsNullOrWhiteSpace([string]$taskIntent.reasoning)) { $verdictText += "`n   причина: " + [string]$taskIntent.reasoning }
        if ([bool]$taskIntent.user_wants_dialogue) { $verdictText += "`n   ⚠ пользователь явно хочет диалог" }
        if ($intentLowComplexity) { $verdictText += "`n   → режим: fast-lane (простая задача — пропускаю планировщик/критика/обсуждение). Нужен полный разбор — добавь [[DEEP-THINK]]." }
        elseif ($intentForcedDiscuss) { $verdictText += "`n   → режим: discuss (Claude↔Codex)" }
        elseif ($intentForcedStudy) { $verdictText += "`n   → режим: study" }
        elseif ($intentForcedFastLane) { $verdictText += "`n   → режим: fast-lane (skip planner)" }
        elseif ([double]$taskIntent.confidence -lt 0.7) { $verdictText += "`n   (confidence < 70% → не применён, режим normal)" }
        Add-Message -From system -Text $verdictText -Kind event | Out-Null
      }
      $state = Read-State
    } else {
      # Reconcile: a backlog task that ended without success leaves current_backlog_id set.
      $leftBid = [string]$state.current_backlog_id
      $leftBatchIds = @()
      try {
        if ($state.PSObject.Properties.Name -contains 'workpack_batch_ids' -and $null -ne $state.workpack_batch_ids) {
          $leftBatchIds = @($state.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
      } catch { $leftBatchIds = @() }
      $leftIds = @(@($leftBid) + @($leftBatchIds) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
      if ($leftIds.Count -gt 0) {
        $failedN = 0
        foreach ($leftId in $leftIds) {
          try {
            if ((Get-IdeaById -Id $leftId).status -eq 'running') {
              Set-Idea -Id $leftId -Status 'failed' | Out-Null
              $failedN++
            }
          } catch {}
        }
        if ($failedN -gt 0) {
          Add-Message -From system -Text "⚠ Автозадача из бэклога не завершилась успешно — помечено failed: $failedN." -Kind event | Out-Null
        }
        Update-State { param($s) $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force } | Out-Null
        $state = Read-State
      }
      # Learning loop: metric snapshot during idle every 3 hours, plus hypothesis reflection.
      $_lastSnap = try { Get-LastMetricsSnapshot } catch { $null }
      $_snapAgeH = if ($_lastSnap) { ([DateTime]::UtcNow - [DateTime]$_lastSnap.ts).TotalHours } else { 999 }
      # Snapshot every 3h (cheap, just stats from turns.jsonl).
      if ($_snapAgeH -ge 3) { try { Write-MetricsSnapshot } catch {} }
      # Hypothesis verdict closure runs ONLY in the nightly quiet window 02:00-06:00 local
      # (user feedback 2026-05-26: "по будильнику, когда я точно сплю"). Heavier I/O + Add-Memory
      # call doesn't bother the user, and we still close verdicts within ~24h.
      try { if (Test-WithinQuietHours -StartHour 2 -EndHour 6) { Invoke-MetricsReflection } } catch {}

      # 🧭 Architect (meta-improvement): cron-style, fires when idle if 24h passed OR 10
      # closed tasks accumulated since last run. Architect proposes STRUCTURAL gaps as
      # backlog ideas (tag=architect status=new -> needs user approval). Different from
      # reflect.ps1 (leaf-level tweaks) and Doctor (acute repair).
      try { Start-ArchitectIfDue -Mode 'normal' } catch {}
      try { Start-DeepThinkIfDue } catch {}
      try { Start-ThinkingReflectionIfDue } catch {}   # internal-thinking step 3: deep reflection -> one insight -> journal
      try { Start-AuditorIfDue } catch {}
      try {
        if ([string]$Channel -eq 'main') {
          if ($null -eq $script:LastTestCleanupTick) { $script:LastTestCleanupTick = 0 }
          $script:LastTestCleanupTick = [int]$script:LastTestCleanupTick + 1
          if ($script:LastTestCleanupTick -ge 30) {
            $script:LastTestCleanupTick = 0
            $cleaned = @(Invoke-TestChannelCleanup -GraceMinutes 10)
            if ($cleaned.Count -gt 0) {
              Write-Host ("[cleanup] processed test channels: " + (($cleaned | ForEach-Object { $_.Name }) -join ', '))
            }
          }
        }
      } catch {}

      # Backlog packer: when many ideas arrived in a short window, annotate them into workpacks
      # before the autonomy picker starts draining the queue one task at a time. This only groups
      # metadata; approval/preflight/execution stay in the existing backlog pipeline.
      try {
        Request-BacklogPackIfNeeded | Out-Null
        $packRun = Invoke-BacklogPackerIfDue
        if ($packRun -and [bool]$packRun.ran -and [int]$packRun.packed_items -gt 0) {
          Add-Message -From system -Text ("📦 Бэклог упакован: {0} задач → {1} workpack(s). Исполнение не меняю: approval и pre-flight остаются обязательными." -f [int]$packRun.packed_items, [int]$packRun.workpack_count) -Kind event | Out-Null
        }
        $reclassifyDue = $false
        $reclassifyNow = [DateTime]::UtcNow
        if ($packRun -and [bool]$packRun.ran -and [int]$packRun.packed_items -gt 0) { $reclassifyDue = $true }
        if ($null -eq $script:LastBacklogWorkpackReclassifyAt) {
          $reclassifyDue = $true
        } elseif (($reclassifyNow - [DateTime]$script:LastBacklogWorkpackReclassifyAt).TotalMinutes -ge 10) {
          $reclassifyDue = $true
        }
        if ($reclassifyDue) {
          $script:LastBacklogWorkpackReclassifyAt = $reclassifyNow
          $reclassified = Update-BacklogWorkpackClassifications
          if ([int]$reclassified -gt 0) {
            Add-Message -From system -Text ("🧭 Workpack classification refreshed: {0} open packed task(s)." -f [int]$reclassified) -Kind event | Out-Null
          }
        }
        $dedupeRun = $null
        try {
          if ($packRun -and ($packRun.PSObject.Properties.Name -contains 'duplicate_compactor')) {
            $dedupeRun = $packRun.duplicate_compactor
          }
        } catch {}
        if ((-not $dedupeRun) -and ($reclassifyDue -or ($packRun -and [bool]$packRun.ran))) {
          try { $dedupeRun = Invoke-BacklogDuplicateCompactor -Reason @('idle-maintenance') } catch { $dedupeRun = $null }
        }
        if ($dedupeRun -and [int]$dedupeRun.duplicates_rejected -gt 0) {
          Add-Message -From system -Text ("🧹 Бэклог очищен от дублей: {0} audit-задач помечены как duplicate-of-root-cause в {1} группе(ах)." -f [int]$dedupeRun.duplicates_rejected, [int]$dedupeRun.group_count) -Kind event | Out-Null
        }
      } catch {}

      # Autonomy: after enough idle quiet, take the next approved backlog idea and run it
      # as a self-task. Freshness skips are logged by backlog/curator and surfaced via poll.
      $claimedIdea = $null
      $claimedIdeaSelection = $null
      $claimedWorkpackBatch = $false
      $workpackFrontierReport = $null
      $auditBusyForAutonomy = $false
      try { $auditBusyForAutonomy = Test-AuditMaintenanceBusy } catch {}
      if ((-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        # Project Autopilot: project-bound channels should not need the operator to keep
        # feeding atoms. When their runnable backlog is empty, enqueue a coordinator task
        # that reads the durable project plan and emits the next [[PROJECT_BACKLOG]] batch.
        try {
          $paStart = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
          if ($paStart -and [string]$paStart.reason -eq 'paused-empty-scope') {
            Start-ProjectAcceptanceIfDue -Channel $Channel -Trigger 'autopilot-empty-scope' | Out-Null
          }
          elseif ($paStart -and [string]$paStart.reason -eq 'plan-not-approved') {
            # 2026-06-02 Discuss-First gate: notify ONCE (marker file) that autopilot is held until the
            # operator approves the PROJECT_PLAN (Ф4). No spam: the marker is cleared by Set-ProjectPlanApproved.
            try {
              $gateMark = Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') $Channel) '.plan-gate-notified'
              if (-not (Test-Path -LiteralPath $gateMark)) {
                Add-Message -From system -Text ("⏸ Project Autopilot ждёт утверждения PROJECT_PLAN (Discuss-First Ф4). Backlog пуст, но автогенерация атомов НЕ запускается без одобрения видения оператором. Когда план обсуждён и утверждён — выполни: Set-ProjectPlanApproved -Channel '" + $Channel + "'.") -Kind event | Out-Null
                Set-Content -LiteralPath $gateMark -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
              }
            } catch {}
          }
          elseif ($paStart -and [string]$paStart.reason -eq 'plan-contract-not-ready') {
            # Plan approval is not enough if the durable map/plan/UX contract is missing, shallow, or stale.
            # Notify once; Set-ProjectPlanApproved clears this marker after a valid contract is approved.
            try {
              $contractMark = Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') $Channel) '.plan-contract-gate-notified'
              if (-not (Test-Path -LiteralPath $contractMark)) {
                $issueText = ''
                try { $issueText = ((@($paStart.issues) | Select-Object -First 4) -join '; ') } catch { $issueText = '' }
                if ([string]::IsNullOrWhiteSpace($issueText)) { $issueText = 'project contract is not ready' }
                Add-Message -From system -Text ("Project Autopilot paused: approved plan is not implementation-ready. Need deep PROJECT_MAP.md, PROJECT_PLAN.md, and .bridge/project-contract.json before atom generation. Issues: " + $issueText) -Kind event | Out-Null
                Set-Content -LiteralPath $contractMark -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
              }
            } catch {}
          }
        } catch {}
      }
      if ((-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        # Workpack execution layer: before claiming a single backlog item, try to claim a small
        # batch of already-approved, non-conflicting workpack items. The batch still enters the
        # normal task pipeline, so planner parallel-dispatch, critic, smoke, and pre-flight gates
        # remain the authority.
        try {
          $wpBatch = Get-NextBacklogWorkpackBatch
          if ($wpBatch -and ($wpBatch.PSObject.Properties.Name -contains 'frontier_report')) { $workpackFrontierReport = $wpBatch.frontier_report }
          if (-not $workpackFrontierReport -and (Get-Command Get-BacklogWorkpackFrontierReport -ErrorAction SilentlyContinue)) { $workpackFrontierReport = Get-BacklogWorkpackFrontierReport }
          if ($wpBatch -and [int]$wpBatch.count -ge 2) {
            $wpCfg = Get-BacklogWorkpackExecConfig
            $safeItems = New-Object 'System.Collections.Generic.List[object]'
            foreach ($wpItem in @($wpBatch.items)) {
              $wpId = [string]$wpItem.id
              $wpGate = $null
              try { $wpGate = Test-AutonomousTaskSafe -TaskText ('[Автозадача из workpack] ' + [string]$wpItem.text) -BridgeRoot $bridgeRoot } catch { $wpGate = [pscustomobject]@{ safe=$true; risk='unknown'; reason='gate exception fail-open' } }
              if ($wpGate -and -not [bool]$wpGate.safe) {
                try { Set-Idea -Id $wpId -Status 'held' | Out-Null } catch {}
                Add-Message -From system -Text ("🛑 Workpack pre-flight: item " + $wpId + " заблокирован (риск=" + [string]$wpGate.risk + "): " + [string]$wpGate.reason) -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='workpack-preflight-blocked'; item_id=$wpId; risk=[string]$wpGate.risk; reason=[string]$wpGate.reason }) } catch {}
                continue
              }
              [void]$safeItems.Add($wpItem)
            }
            if ($safeItems.Count -ge [int]$wpCfg.minItems) {
              $safeArr = @($safeItems.ToArray())
              $batchText = New-BacklogWorkpackBatchTaskText -Items $safeArr
              $batchIds = @($safeArr | ForEach-Object { [string]$_.id })
              $claimedIdea = [pscustomobject]@{
                id = [string]$batchIds[0]
                text = $batchText
                workpack_batch = $true
                workpack_batch_ids = @($batchIds)
                workpack_batch_count = $safeArr.Count
                preflight_checked = $true
                workpack_frontier = [pscustomobject]@{
                  eligible = [int]$wpBatch.eligible_count
                  ready = [int]$wpBatch.ready_count
                  dependency_wait = [int]$wpBatch.dependency_wait_count
                  structural_wait = [int]$wpBatch.structural_wait_count
                  conflict_skips = [int]$wpBatch.conflict_skip_count
                  touch_skips = [int]$wpBatch.touch_skip_count
                  reason = if ($workpackFrontierReport) { [string]$workpackFrontierReport.reason } else { 'batch-available' }
                  approved = if ($workpackFrontierReport) { [int]$workpackFrontierReport.approved_count } else { 0 }
                  with_workpack = if ($workpackFrontierReport) { [int]$workpackFrontierReport.with_workpack_count } else { 0 }
                  without_workpack = if ($workpackFrontierReport) { [int]$workpackFrontierReport.without_workpack_count } else { 0 }
                  protected = if ($workpackFrontierReport) { [int]$workpackFrontierReport.protected_count } else { 0 }
                }
              }
              $claimedWorkpackBatch = $true
              try {
                Write-BacklogJsonLine ([ordered]@{
                  ts=(Get-Date).ToUniversalTime().ToString('o')
                  action='workpack-batch-claim'
                  item_ids=@($batchIds)
                  count=$safeArr.Count
                  workpacks=@($safeArr | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
                  conflict_groups=@($safeArr | ForEach-Object { [string]$_.workpack_conflict_group } | Sort-Object -Unique)
                  eligible=[int]$wpBatch.eligible_count
                  ready=[int]$wpBatch.ready_count
                  reason=if ($workpackFrontierReport) { [string]$workpackFrontierReport.reason } else { 'batch-available' }
                  approved=if ($workpackFrontierReport) { [int]$workpackFrontierReport.approved_count } else { 0 }
                  with_workpack=if ($workpackFrontierReport) { [int]$workpackFrontierReport.with_workpack_count } else { 0 }
                  without_workpack=if ($workpackFrontierReport) { [int]$workpackFrontierReport.without_workpack_count } else { 0 }
                  protected=if ($workpackFrontierReport) { [int]$workpackFrontierReport.protected_count } else { 0 }
                  dependency_wait=[int]$wpBatch.dependency_wait_count
                  structural_wait=[int]$wpBatch.structural_wait_count
                  conflict_skips=[int]$wpBatch.conflict_skip_count
                  touch_skips=[int]$wpBatch.touch_skip_count
                })
              } catch {}
            }
          }
        } catch {}
      }
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        # Protected serial batch: safety/core findings are intentionally excluded from the
        # independent parallel frontier. When many approved protected items share one root cause,
        # close them as ONE sequential task instead of wasting a full turn per duplicate finding.
        try {
          $serialBatch = Get-NextBacklogProtectedSerialBatch
          if ($serialBatch -and [int]$serialBatch.count -ge 2) {
            $wpCfg = Get-BacklogWorkpackExecConfig
            $safeItems = New-Object 'System.Collections.Generic.List[object]'
            foreach ($wpItem in @($serialBatch.items)) {
              $wpId = [string]$wpItem.id
              $wpGate = $null
              try { $wpGate = Test-AutonomousTaskSafe -TaskText ('[Автозадача из protected serial workpack] ' + [string]$wpItem.text) -BridgeRoot $bridgeRoot } catch { $wpGate = [pscustomobject]@{ safe=$true; risk='unknown'; reason='gate exception fail-open' } }
              if ($wpGate -and -not [bool]$wpGate.safe) {
                try { Set-Idea -Id $wpId -Status 'held' | Out-Null } catch {}
                Add-Message -From system -Text ("🛑 Protected serial pre-flight: item " + $wpId + " заблокирован (риск=" + [string]$wpGate.risk + "): " + [string]$wpGate.reason) -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='protected-serial-preflight-blocked'; item_id=$wpId; risk=[string]$wpGate.risk; reason=[string]$wpGate.reason }) } catch {}
                continue
              }
              [void]$safeItems.Add($wpItem)
            }
            if ($safeItems.Count -ge [int]$wpCfg.serialProtectedMinItems) {
              $safeArr = @($safeItems.ToArray())
              $batchText = New-BacklogProtectedSerialBatchTaskText -Items $safeArr -Root ([string]$serialBatch.selected_root)
              $batchIds = @($safeArr | ForEach-Object { [string]$_.id })
              $claimedIdea = [pscustomobject]@{
                id = [string]$batchIds[0]
                text = $batchText
                workpack_batch = $true
                workpack_batch_mode = 'serial'
                protected_serial_batch = $true
                workpack_batch_ids = @($batchIds)
                workpack_batch_count = $safeArr.Count
                preflight_checked = $true
                workpack_frontier = [pscustomobject]@{
                  eligible = [int]$serialBatch.eligible_count
                  ready = [int]$serialBatch.eligible_count
                  dependency_wait = [int]$serialBatch.dependency_wait_count
                  structural_wait = [int]$serialBatch.structural_wait_count
                  conflict_skips = 0
                  touch_skips = 0
                  reason = if ($serialBatch.frontier_report) { [string]$serialBatch.frontier_report.reason } else { 'serial-batch-available' }
                  approved = if ($serialBatch.frontier_report) { [int]$serialBatch.frontier_report.approved_count } else { 0 }
                  with_workpack = if ($serialBatch.frontier_report) { [int]$serialBatch.frontier_report.protected_count } else { 0 }
                  without_workpack = 0
                  protected = [int]$serialBatch.protected_count
                  root = [string]$serialBatch.selected_root
                  mode = 'serial'
                }
              }
              $claimedWorkpackBatch = $true
              try {
                Write-BacklogJsonLine ([ordered]@{
                  ts=(Get-Date).ToUniversalTime().ToString('o')
                  action='protected-serial-batch-claim'
                  item_ids=@($batchIds)
                  count=$safeArr.Count
                  root=[string]$serialBatch.selected_root
                  workpacks=@($safeArr | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
                  conflict_groups=@($safeArr | ForEach-Object { [string]$_.workpack_conflict_group } | Sort-Object -Unique)
                  touches=@($serialBatch.touches)
                  eligible=[int]$serialBatch.eligible_count
                  protected=[int]$serialBatch.protected_count
                  reason=if ($serialBatch.frontier_report) { [string]$serialBatch.frontier_report.reason } else { 'serial-batch-available' }
                  dependency_wait=[int]$serialBatch.dependency_wait_count
                  structural_wait=[int]$serialBatch.structural_wait_count
                })
              } catch {}
            }
          }
        } catch {}
      }
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        try {
          if (-not $workpackFrontierReport -and (Get-Command Get-BacklogWorkpackFrontierReport -ErrorAction SilentlyContinue)) {
            $workpackFrontierReport = Get-BacklogWorkpackFrontierReport
          }
          if ($workpackFrontierReport) {
            $frontierVisible = ([int]$workpackFrontierReport.approved_count -ge [Math]::Max(10, ([int]$workpackFrontierReport.min_items * 4))) -or ([int]$workpackFrontierReport.with_workpack_count -gt 0) -or ([int]$workpackFrontierReport.eligible_count -gt 0)
            if ($frontierVisible) {
              $frontierSig = ([string]::Join(':', @(
                [string]$workpackFrontierReport.reason,
                [string][int]$workpackFrontierReport.selected_count,
                [string][int]$workpackFrontierReport.eligible_count,
                [string][int]$workpackFrontierReport.protected_count,
                [string][int]$workpackFrontierReport.with_workpack_count,
                [string][int]$workpackFrontierReport.without_workpack_count
              )))
              $frontierNow = [DateTime]::UtcNow
              $frontierDue = $false
              if ([string]$script:LastWorkpackFrontierReportSignature -ne $frontierSig) {
                $frontierDue = $true
              } elseif ($null -eq $script:LastWorkpackFrontierReportAt) {
                $frontierDue = $true
              } elseif (($frontierNow - [DateTime]$script:LastWorkpackFrontierReportAt).TotalMinutes -ge 15) {
                $frontierDue = $true
              }
              if ($frontierDue) {
                $script:LastWorkpackFrontierReportSignature = $frontierSig
                $script:LastWorkpackFrontierReportAt = $frontierNow
                Write-BacklogJsonLine ([ordered]@{
                  ts=$frontierNow.ToString('o')
                  action='workpack-frontier-report'
                  reason=[string]$workpackFrontierReport.reason
                  batch_available=[bool]$workpackFrontierReport.batch_available
                  parallel_required=[bool]$workpackFrontierReport.parallel_required
                  approved=[int]$workpackFrontierReport.approved_count
                  with_workpack=[int]$workpackFrontierReport.with_workpack_count
                  without_workpack=[int]$workpackFrontierReport.without_workpack_count
                  eligible=[int]$workpackFrontierReport.eligible_count
                  protected=[int]$workpackFrontierReport.protected_count
                  ready=[int]$workpackFrontierReport.ready_count
                  selected=[int]$workpackFrontierReport.selected_count
                  min_items=[int]$workpackFrontierReport.min_items
                  dependency_wait=[int]$workpackFrontierReport.dependency_wait_count
                  structural_wait=[int]$workpackFrontierReport.structural_wait_count
                  conflict_skips=[int]$workpackFrontierReport.conflict_skip_count
                  touch_skips=[int]$workpackFrontierReport.touch_skip_count
                  selected_ids=@($workpackFrontierReport.selected_ids)
                  selected_groups=@($workpackFrontierReport.selected_groups)
                })
                Add-Message -From system -Text ("🧭 Workpack frontier: batch не claim-ится; reason=" + [string]$workpackFrontierReport.reason + ", approved=" + [int]$workpackFrontierReport.approved_count + ", with_workpack=" + [int]$workpackFrontierReport.with_workpack_count + ", eligible=" + [int]$workpackFrontierReport.eligible_count + ", selected=" + [int]$workpackFrontierReport.selected_count + "/" + [int]$workpackFrontierReport.min_items + ".") -Kind event | Out-Null
              }
            }
          }
        } catch {}
      }
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        try {
          $claimedIdeaSelection = Get-NextApprovedIdea
          if ($claimedIdeaSelection -and ($claimedIdeaSelection.PSObject.Properties.Name -contains 'skipped')) {
            $skipDecisions = @($claimedIdeaSelection.skipped)
            if ($skipDecisions.Count -gt 0) { Publish-CuratorDecisionEvents -Decisions $skipDecisions }
          }
          if ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'idea') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'item'))) {
            $claimedIdea = Get-ObjectValue $claimedIdeaSelection @('idea','item')
          } elseif ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'id') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'text'))) {
            $claimedIdea = $claimedIdeaSelection
          }
        } catch {}
      }
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        try {
          if (Get-Command Get-ApprovedBacklogClaimabilityReport -ErrorAction SilentlyContinue) {
            $claimability = Get-ApprovedBacklogClaimabilityReport
            if ($claimability -and [int]$claimability.approved_count -gt 0 -and [int]$claimability.runnable_count -eq 0) {
              $ids = @()
              try { $ids += @($claimability.control_plane_ids | ForEach-Object { [string]$_ }) } catch {}
              try { $ids += @($claimability.project_scope_ids | ForEach-Object { [string]$_ }) } catch {}
              $sig = ([string]$Channel + ':' + [int]$claimability.approved_count + ':' + [int]$claimability.control_plane_blocked + ':' + [int]$claimability.project_scope_blocked + ':' + ([string]::Join(',', @($ids | Select-Object -First 8))))
              $nowClaimability = [DateTime]::UtcNow
              $dueClaimability = $false
              if ([string]$script:LastBacklogClaimabilitySignature -ne $sig) {
                $dueClaimability = $true
              } elseif ($null -eq $script:LastBacklogClaimabilityAt) {
                $dueClaimability = $true
              } elseif (($nowClaimability - [DateTime]$script:LastBacklogClaimabilityAt).TotalMinutes -ge 15) {
                $dueClaimability = $true
              }
              if ($dueClaimability) {
                $script:LastBacklogClaimabilitySignature = $sig
                $script:LastBacklogClaimabilityAt = $nowClaimability
                Write-BacklogJsonLine ([ordered]@{
                  ts = $nowClaimability.ToString('o')
                  action = 'approved-claimability-blocked'
                  channel = [string]$Channel
                  approved = [int]$claimability.approved_count
                  runnable = [int]$claimability.runnable_count
                  control_plane = [int]$claimability.control_plane_blocked
                  project_scope = [int]$claimability.project_scope_blocked
                  other = [int]$claimability.other_blocked
                  control_plane_ids = @($claimability.control_plane_ids)
                  project_scope_ids = @($claimability.project_scope_ids)
                })
                Add-Message -From system -Text ("🧭 Backlog claimability: approved=" + [int]$claimability.approved_count + ", runnable=0; control-plane blocked=" + [int]$claimability.control_plane_blocked + ", project-scope blocked=" + [int]$claimability.project_scope_blocked + ". Обычная автономия не исполняет эти задачи без operator tag / bridge-self canary gate.") -Kind event | Out-Null
              }
            }
          }
        } catch {}
      }
      if ($claimedIdea -and (-not $claimedWorkpackBatch) -and $workpackFrontierReport -and [bool]$workpackFrontierReport.parallel_required) {
        try {
          $serialReason = [string](Get-BacklogPackObjectValue -Obj $claimedIdea -Name 'serial_reason' -Default '')
          $validSerialReason = $false
          if (-not [string]::IsNullOrWhiteSpace($serialReason)) {
            if (Get-Command Test-WorkpackValidSerialReason -ErrorAction SilentlyContinue) {
              $validSerialReason = [bool](Test-WorkpackValidSerialReason -SerialReason $serialReason -AllowEmpty:$false)
            } else {
              $validSerialReason = $true
            }
          }
          if (-not $validSerialReason) {
            $warnSig = ([string]$claimedIdea.id + ':' + [string]$workpackFrontierReport.reason + ':' + ([string]::Join(',', @($workpackFrontierReport.selected_ids))))
            $warnNow = [DateTime]::UtcNow
            $warnDue = $false
            if ([string]$script:LastParallelObligationWarningSignature -ne $warnSig) {
              $warnDue = $true
            } elseif ($null -eq $script:LastParallelObligationWarningAt) {
              $warnDue = $true
            } elseif (($warnNow - [DateTime]$script:LastParallelObligationWarningAt).TotalMinutes -ge 15) {
              $warnDue = $true
            }
            if ($warnDue) {
              $script:LastParallelObligationWarningSignature = $warnSig
              $script:LastParallelObligationWarningAt = $warnNow
              Write-BacklogJsonLine ([ordered]@{
                ts=$warnNow.ToString('o')
                action='parallel-obligation-warning'
                item_id=[string]$claimedIdea.id
                reason=[string]$workpackFrontierReport.reason
                selected=[int]$workpackFrontierReport.selected_count
                min_items=[int]$workpackFrontierReport.min_items
                selected_ids=@($workpackFrontierReport.selected_ids)
                selected_groups=@($workpackFrontierReport.selected_groups)
                serial_reason=$serialReason
              })
              Add-Message -From system -Text ("⚠ Parallel obligation warning: frontier требует parallel (selected=" + [int]$workpackFrontierReport.selected_count + "/" + [int]$workpackFrontierReport.min_items + "), но выбран single-task без valid serial_reason. Не блокирую выполнение; пишу диагностику.") -Kind event | Out-Null
            }
          }
        } catch {}
      }
      # 🌱 Increment B -- graduated self-development: AUTO-CLAIM of an UNapproved 'new' idea within
      # the operator's selfExecuteTier dial. When no human/curator-approved idea is queued and the
      # dial is 'green'/'yellow', take the next runnable 'new' idea whose risk tier is within the
      # dial (Get-NextSelfExecIdea excludes external/radar and red-tier, and skips past out-of-dial
      # items so the queue can't wedge). It is promoted into $claimedIdea HERE -- BEFORE the dirty
      # guard -- so it runs the IDENTICAL pipeline as approved ideas (dirty guard, smoke+critic
      # gates, verdict auto-revert). $selfDev* are read by the shadow-observability block below.
      $selfDevTier = 'off'
      $selfDevClaimed = $false
      $selfDevPick = $null
      $selfDevTierOfPick = ''
      $selfDevReason = ''
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main') -and (Test-AutonomyReady)) {
        try { $selfDevTier = ([string](Get-AutonomySettings).selfExecuteTier).ToLowerInvariant() } catch { $selfDevTier = 'shadow' }
        # 🛡 Safety reflex: if recent self-exec commits regressed (verdict 'worse'), dial DOWN one
        # notch BEFORE picking again, so the system throttles its own autonomy after regressions.
        try {
          $reflex = Test-SelfDevSafetyReflex -CurrentDial $selfDevTier
          if ($reflex -and $reflex.shouldDampen) {
            try { Set-AutonomySetting @{ selfExecuteTier = [string]$reflex.newDial } | Out-Null } catch {}
            Add-Message -From system -Text ("🛡 Само-защита: понижаю диск само-развития $($reflex.fromDial)→$($reflex.newDial) — недавние авто-коммиты дали регресс (worse=$($reflex.worseCount)). Система притормаживает сама.") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-dev-dampen'; from=[string]$reflex.fromDial; to=[string]$reflex.newDial; worse=[int]$reflex.worseCount }) } catch {}
            $selfDevTier = [string]$reflex.newDial
          }
        } catch {}
        if ($selfDevTier -eq 'green' -or $selfDevTier -eq 'yellow') {
          try { $selfDevPick = Get-NextSelfExecIdea -Dial $selfDevTier } catch { $selfDevPick = $null }
          if ($selfDevPick) {
            $rt = Get-IdeaRiskTier -Idea $selfDevPick
            $selfDevTierOfPick = [string]$rt.tier
            $selfDevReason = [string]$rt.reason
            try { Set-IdeaRiskTier -Id ([string]$selfDevPick.id) -Tier $selfDevTierOfPick -Reason $selfDevReason | Out-Null } catch {}
            $claimedIdea = $selfDevPick
            $selfDevClaimed = $true
            try { Set-IdeaSelfExec -Id ([string]$selfDevPick.id) -Dial $selfDevTier | Out-Null } catch {}
            $script:lastShadowIdeaId = [string]$selfDevPick.id
            $ideaPrev = [string]$selfDevPick.text
            if ($ideaPrev.Length -gt 80) { $ideaPrev = $ideaPrev.Substring(0,80) + '…' }
            Add-Message -From system -Text ("🌱 Само-развитие [диск=$selfDevTier]: беру НОВУЮ идею автономно (риск=$selfDevTierOfPick · $selfDevReason): «$ideaPrev»") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-exec-claim'; item_id=[string]$selfDevPick.id; tier=$selfDevTierOfPick; reason=$selfDevReason; dial=$selfDevTier }) } catch {}
          }
        }
      }
      # 2026-05-28: dirty-state guard. Before starting an autonomous task,
      # verify the bridge's working tree is clean. Starting work on top of
      # uncommitted edits leads to two bad outcomes: (a) Codex/Claude's diff
      # mixes its changes with whatever was sitting in the tree, making
      # rollback impossible; (b) a watchdog restart loses everything that
      # wasn't committed. Hold the task and ping the operator instead.
      if ($claimedIdea) {
        try {
          # 2026-05-31 (Foundation #4 lesson): per-channel dirty-guard. For a PROJECT
          # channel, check ITS OWN repo (project_root), NOT the bridge -- otherwise an
          # operator edit to the bridge control plane falsely freezes unrelated project
          # channels (this happened twice during the YoungChef run). Bridge channel keeps
          # the original bridge-root check + autosave filter.
          $guardRoot = $bridgeRoot
          $isProjectChannel = $false
          try {
            $pr = Get-EffectiveProjectRoot
            if (-not [string]::IsNullOrWhiteSpace([string]$pr) -and ([string]$pr -ne [string]$bridgeRoot)) { $guardRoot = [string]$pr; $isProjectChannel = $true }
          } catch {}
          $dirty = (& git -C $guardRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          if (-not $isProjectChannel) {
            # Bridge-only: filter out the perennial autosaved files that aren't real edits
            $dirty = @($dirty | Where-Object {
              $line = ([string]$_).Substring(3).Trim()
              $line -notmatch '^(decisions/session-ledger\.jsonl|turns\.jsonl|channels/[^/]+/state\.json|channels/[^/]+/conversation\.jsonl|features/state\.json|control/.*\.log|audit/.*\.md|audit/.*\.json|logs/.*)$'
            })
          }
          if ($dirty.Count -gt 0) {
            # Dirty tree is a TRANSIENT condition (uncommitted edits), so do NOT change the idea's
            # status -- marking it 'held' would STRAND it, since the selectors only pick 'new'/
            # 'approved' (this silently wedged self-/backlog tasks whenever a stray file sat in the
            # tree). Leave the idea in the queue and just skip this tick; it gets re-picked once the
            # tree is clean. Dedupe the notice by idea id so idle ticks don't spam while it stays dirty.
            if ([string]$claimedIdea.id -ne [string]$script:lastDirtyDeferId) {
              $script:lastDirtyDeferId = [string]$claimedIdea.id
              $preview = ($dirty | Select-Object -First 5 | ForEach-Object { ([string]$_).Trim() }) -join '; '
              Add-Message -From system -Text ("🚧 Автозадача отложена: рабочее дерево не чистое ($($dirty.Count) файлов). Закоммить или сделай stash; мост возьмёт задачу как только дерево станет чистым (идея остаётся в очереди). Превью: $preview") -Kind event | Out-Null
            }
            $claimedIdea = $null
          }
        } catch {
          # If git itself errors, fail open — better to start the task than wedge
          # the loop. The watchdog/critic will catch a bad commit downstream.
        }
      }
      # 🌒 Shadow observability (graduated autonomy; autonomy.selfExecuteTier). When an UNapproved
      # 'new' idea WOULD be the next self-pick but is NOT being executed this tick -- either the dial
      # is 'shadow' (observe-only) or the top idea's risk tier exceeds the dial -- surface it in chat
      # WITHOUT running it. (When the dial DID auto-claim an in-dial idea, $selfDevClaimed is set and
      # the claim path above already announced it.) Posts only when the would-pick CHANGES, so idle
      # ticks don't spam. main channel only.
      if ((-not $claimedIdea) -and (-not $selfDevClaimed) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main')) {
        try {
          $selfTier = if ($selfDevTier) { $selfDevTier } else { 'shadow' }
          if ($selfTier -and $selfTier -ne 'off' -and (Test-AutonomyReady)) {
            $shadowPick = $null
            try { $shadowPick = Get-NextRunnableIdea -IncludeNew $true } catch {}
            $shadowId = if ($shadowPick) { [string]$shadowPick.id } else { '' }
            # Only act when the would-pick CHANGES, so we don't repost every idle tick.
            if ($shadowId -ne [string]$script:lastShadowIdeaId) {
              $script:lastShadowIdeaId = $shadowId
              if ($shadowPick -and ([string]$shadowPick.status -eq 'new')) {
                $rt = Get-IdeaRiskTier -Idea $shadowPick
                $tier = [string]$rt.tier; $why = [string]$rt.reason
                try { Set-IdeaRiskTier -Id $shadowId -Tier $tier -Reason $why | Out-Null } catch {}
                $verb = if ($selfTier -eq 'shadow') { 'взяла бы (shadow, без запуска)' }
                        else { "НЕ запускает (риск=$tier выше диска=$selfTier)" }
                $ideaText = [string]$shadowPick.text
                if ($ideaText.Length -gt 80) { $ideaText = $ideaText.Substring(0,80) + '…' }
                Add-Message -From system -Text ("🌒 Само-развитие [диск=$selfTier]: $verb новую идею «$ideaText» · риск=$tier · $why") -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='shadow-pick'; item_id=$shadowId; tier=$tier; reason=$why; dial=$selfTier; would_execute=$false }) } catch {}
              }
            }
          }
        } catch {}
      }
      if ($claimedIdea) {
        # 2026-05-30 PRE-EXECUTION SAFETY GATE: vet the TASK itself before running it.
        # Critic/QA validate the resulting code, not whether the task is harmful (a task
        # to delete a still-used file passes smoke). Blocked tasks -> 'held' (selectors
        # only pick new/approved, so they won't be re-claimed) + operator escalation.
        try {
          $preflightChecked = $false
          try {
            if ($claimedIdea.PSObject.Properties.Name -contains 'preflight_checked') { $preflightChecked = [bool]$claimedIdea.preflight_checked }
          } catch {}
          if (-not $preflightChecked) {
            $gate = Test-AutonomousTaskSafe -TaskText ('[Автозадача из бэклога] ' + [string]$claimedIdea.text) -BridgeRoot $bridgeRoot
            if (-not $gate.safe) {
              $gid = [string]$claimedIdea.id
              try { Set-Idea -Id $gid -Status 'held' | Out-Null } catch {}
              Add-Message -From system -Text ("🛑 Pre-flight gate: автозадача ЗАБЛОКИРОВАНА (риск=" + [string]$gate.risk + "): " + [string]$gate.reason + ". Помечена 'held' — нужна проверка оператора, мост её НЕ исполняет.") -Kind event | Out-Null
              try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='preflight-blocked'; item_id=$gid; risk=[string]$gate.risk; reason=[string]$gate.reason }) } catch {}
              $claimedIdea = $null
            }
          }
        } catch {}
      }
      if ($claimedIdea) {
        $script:idleStreak = 0   # autonomous task claimed -> snappy idle again once it finishes
        $bid = [string]$claimedIdea.id
        $batchIdsForState = @()
        try {
          if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_batch_ids') {
            $batchIdsForState = @($claimedIdea.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          }
        } catch { $batchIdsForState = @() }
        $isWorkpackBatch = ($batchIdsForState.Count -ge 2)
        $workpackBatchMode = ''
        try {
          if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_batch_mode') { $workpackBatchMode = [string]$claimedIdea.workpack_batch_mode }
        } catch { $workpackBatchMode = '' }
        $btext = if ($isWorkpackBatch) { [string]$claimedIdea.text } else { '[Автозадача из бэклога] ' + [string]$claimedIdea.text }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $studyDetect = Detect-StudyMode -TaskText $btext -IsAutonomous
        $taskRepoRootForBacklog = Get-TaskRepoRoot
        $baseCommit = try { (& git -C $taskRepoRootForBacklog rev-parse HEAD 2>$null).Trim() } catch { '' }
        $taskManagementSnapshot = $null
        try {
          $tmTouched = New-Object 'System.Collections.Generic.List[string]'
          foreach ($propName in @('workpack_touch_set','files','touch_set')) {
            if ($claimedIdea.PSObject.Properties.Name -contains $propName) {
              foreach ($file in @($claimedIdea.$propName)) {
                $fs = ([string]$file).Trim()
                if (-not [string]::IsNullOrWhiteSpace($fs) -and -not $tmTouched.Contains($fs)) { [void]$tmTouched.Add($fs) }
              }
            }
          }
          $tmFrontier = $null
          if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_frontier' -and $claimedIdea.workpack_frontier) {
            $tmFrontier = $claimedIdea.workpack_frontier
          } elseif ($workpackFrontierReport) {
            $tmFrontier = $workpackFrontierReport
          }
          if ($isWorkpackBatch -and $tmFrontier) {
            try {
              if ($null -eq $tmFrontier.PSObject.Properties['selected']) { $tmFrontier | Add-Member -NotePropertyName selected -NotePropertyValue $batchIdsForState.Count -Force }
              if ($null -eq $tmFrontier.PSObject.Properties['selected_ids']) { $tmFrontier | Add-Member -NotePropertyName selected_ids -NotePropertyValue @($batchIdsForState) -Force }
            } catch {}
          }
          $tmChannelType = 'project'
          if ([string]$Channel -eq 'main') { $tmChannelType = 'bridge' }
          $tmKind = 'backlog'
          if ($isWorkpackBatch) { $tmKind = 'workpack_batch' }
          elseif ([string]$claimedIdea.from -match 'audit') { $tmKind = 'audit_backlog' }
          $tmChannelFacts = [pscustomobject]@{
            Channel = [string]$Channel
            ChannelType = $tmChannelType
            IsExternalProject = ([string]$Channel -ne 'main')
          }
          $tmContext = [ordered]@{
            Kind = $tmKind
            IsBacklog = $true
            IsWorkpackBatch = $isWorkpackBatch
            WorkpackBatchMode = [string]$workpackBatchMode
            BatchCount = [int]$batchIdsForState.Count
          }
          $taskManagementSnapshot = New-TaskManagementSnapshot -TaskId $bid -TaskText $btext -Channel $Channel -TouchedFiles @($tmTouched.ToArray()) -BatchIds @($batchIdsForState) -WorkpackBatchMode $workpackBatchMode -WorkpackFrontier $tmFrontier -ChannelFacts $tmChannelFacts -Context $tmContext
          Write-TaskManagementShadowRecord -BridgeRoot $bridgeRoot -Channel $Channel -TaskId $bid -Snapshot $taskManagementSnapshot -Note 'idle-claim' | Out-Null
        } catch {}
        Update-State ({ param($s)
          $s.current_task=$btext; $s.task_turn=0; $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
          Start-ReplayForStateTask -State $s -TaskText $btext -ChannelName $Channel
          Clear-FastLaneFlags $s
          if ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
          $s.task_start_seq=[int]$s.lastSeq; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$bid; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o')
          $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
          $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @($batchIdsForState) -Force
          $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $isWorkpackBatch -Force
          $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force  # ERR-006: fresh batch, not yet dispatched
          $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue $workpackBatchMode -Force
          $s | Add-Member -NotePropertyName task_management_snapshot -NotePropertyValue $taskManagementSnapshot -Force
          Clear-AuditorSuppressedHashes -State $s
          Clear-ChunkingState $s
          $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
          $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
          Reset-TaskAgentDuration $s
          if ([string]$s.autonomous_day -eq $today) { $s.autonomous_count=[int]$s.autonomous_count+1 } else { $s.autonomous_day=$today; $s.autonomous_count=1 }
        }.GetNewClosure()) | Out-Null
        try {
          $taskText = [string]$btext
          $taskForLedger = if ($taskText.Length -gt 120) { $taskText.Substring(0,120) } else { $taskText }
          Add-SessionDecisionEvent -EventType 'task_start' -Meta @{ task=$taskForLedger } -Channel $Channel
          $mGoal = if ($taskText.Length -gt 600) { $taskText.Substring(0,600) } else { $taskText }
          Update-State ({ param($s)
            $s.session_mission = [pscustomobject]@{ goal=$mGoal; next_step=''; accepted_decisions=@(); constraints=@(); recent_done=@(); blockers=@() }
          }.GetNewClosure()) | Out-Null
        } catch {}
        try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
        try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
        try {
          if ($isWorkpackBatch) {
            foreach ($batchId in $batchIdsForState) { Set-Idea -Id $batchId -Status 'running' -IncrementAttempts $true | Out-Null }
          } else {
            Set-Idea -Id $bid -Status 'running' -IncrementAttempts $true | Out-Null
          }
        } catch {}
        if ($isWorkpackBatch) {
          $frontierText = ''
          try {
            if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_frontier' -and $claimedIdea.workpack_frontier) {
              $wf = $claimedIdea.workpack_frontier
              $frontierText = " Фронт: selected=" + $batchIdsForState.Count + ", ready=" + [int]$wf.ready + "/" + [int]$wf.eligible + ", ждут deps=" + [int]$wf.dependency_wait + ", barrier=" + [int]$wf.structural_wait + ", conflicts=" + ([int]$wf.conflict_skips + [int]$wf.touch_skips) + "."
              if (-not [string]::IsNullOrWhiteSpace([string]$wf.reason)) { $frontierText += " reason=" + [string]$wf.reason + "." }
              if (-not [string]::IsNullOrWhiteSpace([string]$wf.root)) { $frontierText += " root=" + [string]$wf.root + "." }
            }
          } catch {}
          if ([string]$workpackBatchMode -eq 'serial') {
            Add-Message -From system -Text ("🧵 Беру protected serial-batch автономно: " + $batchIdsForState.Count + " approved safety/core задач одним последовательным проходом." + $frontierText + " Параллель для этой пачки запрещена; дальше обычный planner/Codex/critic/smoke контур.") -Kind event | Out-Null
          } else {
            Add-Message -From system -Text ("🤖 Беру workpack-batch автономно: " + $batchIdsForState.Count + " approved задач из независимых workpacks." + $frontierText + " Дальше обычный planner/parallel/critic/smoke контур.") -Kind event | Out-Null
          }
        } else {
          Add-Message -From system -Text "🤖 Беру задачу из бэклога в работу (автономно): $([string]$claimedIdea.text)" -Kind event | Out-Null
        }
        try {
          $tmSummary = Format-TaskManagementSummary -Snapshot $taskManagementSnapshot
          if (-not [string]::IsNullOrWhiteSpace($tmSummary)) {
            Add-Message -From system -Text ("🧭 " + $tmSummary) -Kind event | Out-Null
          }
        } catch {}
        if ($studyDetect) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: backlog" -Kind event | Out-Null }
        $state = Read-State
      } else {
        Update-State { param($s) $s.status='idle'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        try { Start-LibrarianIfDue } catch {}
        try { Start-AuditIfDue } catch {}
        try { Start-FeatureVerifierIfDue } catch {}
        try { Update-FeatureActivations | Out-Null } catch {}
        try { Start-ReflectIfDue } catch {}
        try { Start-TechRadarIfDue } catch {}
        try { Start-CanaryIfDue } catch {}
        # 🧹 Anti-junk hygiene: archive unclaimed 'new' ideas older than ideaStaleDays. Throttled to
        # once per 24h via control/stale-sweep.last so it's near-free on the idle path.
        try {
          $ssMarker = Join-Path (Get-BridgeRoot) 'control\stale-sweep.last'
          $ssDue = $true
          if (Test-Path $ssMarker) { try { $ssDue = (((Get-Date) - [datetime]((Get-Content $ssMarker -Raw -Encoding UTF8).Trim())).TotalHours -ge 24) } catch {} }
          if ($ssDue) {
            [System.IO.File]::WriteAllText($ssMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $staleN = Invoke-BacklogStaleSweep
            if ($staleN -gt 0) { Add-Message -From system -Text "🧹 Гигиена бэклога: $staleN неразобранных идей старше срока → авто-архив (auto-stale)." -Kind event | Out-Null }
          }
        } catch {}
        # 🗄 Archive hygiene: weekly prune of conversation.archive.jsonl (lines older than 7 days).
        # Only the archive sidecar is touched — never the live chat or summary — so this can NOT
        # affect the bridge's context. Throttled via control/archive-prune.last (~7d).
        try {
          $apMarker = Join-Path (Get-BridgeRoot) 'control\archive-prune.last'
          $apDue = $true
          if (Test-Path $apMarker) { try { $apDue = (((Get-Date) - [datetime]((Get-Content $apMarker -Raw -Encoding UTF8).Trim())).TotalDays -ge 7) } catch {} }
          if ($apDue) {
            [System.IO.File]::WriteAllText($apMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $prunedN = Invoke-ConversationArchivePrune -MaxAgeDays 7
            if ($prunedN -gt 0) { Add-Message -From system -Text "🗄 Архив чата почищен: удалено $prunedN сообщений старше 7 дней (из архива, не из чата)." -Kind event | Out-Null }
          }
        } catch {}
        # 2026-05-27v6: log rotation every idle tick (cheap — Rotate-LogIfBig
        # is O(1) when file is under limit). 2MB cap = ~1 month of metrics.
        try {
          $brRoot = Get-BridgeRoot
          Rotate-LogIfBig -Path (Join-Path $brRoot 'metrics.jsonl')      -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'usage.jsonl')        -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'bridge-lock.log')    -MaxKB 512  -Keep 2 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'critic.log')         -MaxKB 1024 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-leak.log')  -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-sweep.log') -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\children.jsonl') -MaxKB 256 -Keep 1 | Out-Null
        } catch {}
        # 2026-05-27v6: sweep registered child processes (audit P2 -- detect crashed children)
        try { Sweep-ChildProcesses -MaxAgeMin 30 | Out-Null } catch {}
        # 2026-05-28: sweep orphan codex.exe processes (real incident: 11 zombies
        # accumulated, one 22h old, 360MB resident). NEVER touches claude.exe
        # (user IDE is also claude.exe). Configurable cutoff via config.json
        # orphanSweep.codexMaxIdleMin, default 30 minutes.
        try {
          $orphMax = 30
          try {
            $cfgO = Get-BridgeConfig
            if ($cfgO -and $cfgO.PSObject.Properties.Name -contains 'orphanSweep' -and $cfgO.orphanSweep -and $cfgO.orphanSweep.codexMaxIdleMin) {
              $orphMax = [int]$cfgO.orphanSweep.codexMaxIdleMin
            }
          } catch {}
          if ($orphMax -lt 5) { $orphMax = 5 }
          $ores = Sweep-OrphanAgentProcesses -MaxIdleMin $orphMax
          if ($ores -and [int]$ores.killed -gt 0) {
            Add-Message -From system -Text ("🧹 Auto-sweep: убит " + $ores.killed + " orphan codex.exe (старше " + $orphMax + " мин, не привязан к активному агенту)") -Kind event | Out-Null
          }
        } catch {}
        # Adaptive backoff: snappy for the first $idleFastTicks ticks after activity, then
        # +1s per extra consecutive idle tick, capped at $idleMaxPoll. Cuts redundant ~1Hz wakeups.
        $script:idleStreak = [int]$script:idleStreak + 1
        $sleepSec = $idlePoll
        if ($script:idleStreak -gt $idleFastTicks) { $sleepSec = [Math]::Min($idleMaxPoll, $idlePoll + ($script:idleStreak - $idleFastTicks)) }
        Start-Sleep -Seconds $sleepSec; continue
      }
    }
  } else {
    # Active task fence (Atom 14): while a task is running, do NOT advance last_user_seq.
    # User messages that arrived after task_start_seq stay pending in the queue and will be
    # claimed as the next task when the channel returns to idle. Advancing here would consume
    # them silently, so they'd never be picked up.
  }
}
