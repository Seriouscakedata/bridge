$script:DriverLoopReplyMarkersBlock = {
  $fastLaneActiveForTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  # 2026-06-03 slimming Atom 1 (SHADOW): capture optional [[DECISION:{json}]] from the model reply and
  # log it against the legacy intent for later model-vs-heuristic comparison. Pure logging — nothing
  # here changes execution; legacy intent/routing still drive the turn. Promote out of shadow only
  # after real-run evidence (SLIMMING_PLAN.md).
  try {
    if (Get-Command Read-DecisionFromReply -ErrorAction SilentlyContinue) {
      $shadowDecision = Read-DecisionFromReply -Reply $reply
      if ($shadowDecision) {
        $legacyIntent = $null; try { $legacyIntent = (Read-State).task_intent } catch {}
        Write-DecisionShadow -Stage 'planner-turn' -ModelDecision $shadowDecision -LegacyDecision $legacyIntent -Note ("speaker=" + [string]$speaker + " mode=" + [string]$mode) | Out-Null
      }
    }
  } catch {}
  $attachmentMetas = @()
  $failedAttachmentPaths = @()
  $fileMarkerPaths = @()
  $fileMarkerPattern = '(?m)^\s*\[\[FILE:\s*(.+?)\s*\]\]\s*$'
  foreach ($match in [regex]::Matches($reply, $fileMarkerPattern)) {
    $sourcePath = $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    if ($sourcePath.StartsWith('<') -and $sourcePath.EndsWith('>') -and $sourcePath.Length -gt 2) {
      $sourcePath = $sourcePath.Substring(1, $sourcePath.Length - 2).Trim()
    }
    $fileMarkerPaths += $sourcePath
    $meta = Register-AttachmentPath -SourcePath $sourcePath
    if ($meta) { $attachmentMetas += $meta }
    else { $failedAttachmentPaths += $sourcePath }
  }
  # Auto-detect image file paths from markdown links: [name](</C:/path.png>)
  $imgMdPattern = '\[[^\]]*\]\(<\/?([^>]+\.(?:png|jpg|jpeg|gif|bmp|webp))>\)'
  foreach ($mdMatch in [regex]::Matches($reply, $imgMdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $mdMatch.Groups[1].Value.Trim()
    if ($imgPath -match '^/([A-Za-z]:.*)') { $imgPath = $Matches[1] }
    $imgPath = $imgPath.Replace('/', '\')
    $normalized = $imgPath
    if ($normalized -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # Best-effort: bare Windows paths (no spaces supported)
  $imgBarePattern = '([A-Za-z]:\\[^\s\[\]<>"'']+\.(?:png|jpg|jpeg|gif|bmp|webp))'
  foreach ($bareMatch in [regex]::Matches($reply, $imgBarePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $bareMatch.Groups[1].Value.Trim()
    if ($imgPath -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # [[SAVE: title]] ... [[/SAVE]] -> durable decision note
  $savePattern = '(?s)\[\[SAVE:\s*(.+?)\s*\]\](.*?)\[\[/SAVE\]\]'
  $savedPaths = @()
  foreach ($m in [regex]::Matches($reply, $savePattern)) {
    $st = $m.Groups[1].Value.Trim(); $sc = $m.Groups[2].Value.Trim()
    if ($sc) { $savedPaths += (Save-Decision -Title $st -Content $sc) }
  }
  $evidencePattern = '(?m)^\s*\[\[EVIDENCE:\s*(.+?)\s*\]\]\s*$'
  $verifiedPattern = '(?m)^\s*\[\[VERIFIED:\s*(.+?)\s*\]\]\s*$'
  $evidenceSources = @()
  foreach ($m in [regex]::Matches($reply, $evidencePattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $source = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $summary = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $confidence = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($source)) { continue }
    if (Write-EvidenceLog -Agent $speaker -Task $task -Source $source -Summary $summary -Confidence $confidence) {
      $evidenceSources += $source
    }
  }
  foreach ($m in [regex]::Matches($reply, $verifiedPattern)) {
    $vtext = $m.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($vtext)) {
      try { Add-SessionDecisionEvent -EventType 'verified_commit' -Meta @{ what=$vtext.Substring(0,[Math]::Min(100,$vtext.Length)) } -Channel $Channel } catch {}
    }
  }
  $findingPattern = '(?m)^\s*\[\[FINDING:\s*(.+?)\s*\]\]\s*$'
  $studyFindings = @()
  foreach ($m in [regex]::Matches($reply, $findingPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 2)
    $fsrc = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $ffact = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($fsrc)) { $studyFindings += "$fsrc | $ffact" }
  }
  $studyFallbackPattern = '(?m)^\s*\[\[STUDY_FALLBACK:\s*external\s*\]\]\s*$'
  if ($reply -imatch '\[\[STUDY_FALLBACK:\s*external\s*\]\]') {
    Update-State { param($s) $s.study_subtype='external'; $s.study_phase='gather-web' } | Out-Null
    Add-Message -From system -Text "📚 Study: путь не является репозиторием — переключаюсь на external." -Kind event | Out-Null
  }
  $pbForMarkers = Get-ActiveProjectBinding
  $channelIsMainMarkers = ($pbForMarkers -and ([string]$pbForMarkers.slug -eq 'main'))

  # [[REMEMBER: fact]] -> agent deliberately pushes a durable memory (no gate -- the agent chose).
  $rememberPattern = '(?m)^\s*\[\[REMEMBER:\s*(.+?)\s*\]\]\s*$'
  $rememberedFacts = @()
  foreach ($m in [regex]::Matches($reply, $rememberPattern)) {
    $fact = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($fact)) { continue }
    try {
      $rid = Add-Memory -Text $fact -Tags @('explicit', $speaker) -Source ('explicit:' + $speaker) -Importance 0.75 -Channel ([string]$pbForMarkers.slug)
      if ($rid) { $rememberedFacts += $fact }
    } catch {}
  }
  # [[PROJECT_FACT: ...]] / [[PROJECT_TEST: ...]] / ... -> typed, evidence-backed
  # per-channel project memory. This stays in the same memory.jsonl store and is
  # retrieved by Get-ProjectContextPack before future tasks.
  $projectMemoryPattern = '(?m)^\s*\[\[PROJECT_(FACT|DECISION|RISK|TEST|INVARIANT|WORKLOG|OPEN_QUESTION):\s*(.+?)\s*\]\]\s*$'
  $projectMemoryCount = 0
  foreach ($pm in [regex]::Matches($reply, $projectMemoryPattern)) {
    $kindToken = $pm.Groups[1].Value.Trim().ToUpperInvariant()
    $rawProjectMemory = $pm.Groups[2].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($rawProjectMemory)) { continue }
    $kindMap = @{
      FACT = 'project_fact'
      DECISION = 'project_decision'
      RISK = 'project_risk'
      TEST = 'project_test'
      INVARIANT = 'project_invariant'
      WORKLOG = 'project_worklog'
      OPEN_QUESTION = 'project_open_question'
    }
    if (-not $kindMap.ContainsKey($kindToken)) { continue }
    try {
      if (Get-Command Add-ProjectMemoryFromMarker -ErrorAction SilentlyContinue) {
        $pid = Add-ProjectMemoryFromMarker -Kind ([string]$kindMap[$kindToken]) -RawText $rawProjectMemory -Channel ([string]$pbForMarkers.slug) -Source ('project-marker:' + $speaker)
        if ($pid) { $projectMemoryCount++ }
      }
    } catch {}
  }
  if ($projectMemoryCount -gt 0) {
    try { Add-Message -From system -Text ("🧠 Проектная память: сохранено typed-записей " + $projectMemoryCount) -Kind event | Out-Null } catch {}
  }
  # [[PROJECT_BACKLOG]] JSON [[/PROJECT_BACKLOG]] -> Project Autopilot atom batch.
  # The coordinator task thinks/decomposes; the driver owns durable backlog mutation.
  $projectBacklogPattern = '(?is)\[\[PROJECT_BACKLOG\]\](.*?)\[\[/PROJECT_BACKLOG\]\]'
  $projectBacklogCreated = 0
  foreach ($pbm in [regex]::Matches($reply, $projectBacklogPattern)) {
    $pbBlock = [string]$pbm.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($pbBlock)) { continue }
    try {
      if (Get-Command Add-ProjectBacklogFromMarker -ErrorAction SilentlyContinue) {
        $pbMax = 12
        try { $pbMax = [int](Get-ProjectAutopilotConfig).maxTasksPerBatch } catch { $pbMax = 12 }
        $sourceTaskId = ''
        try {
          $stPb = Read-State
          $sourceTaskId = [string]$stPb.current_task_id
          if ([string]::IsNullOrWhiteSpace($sourceTaskId)) { $sourceTaskId = [string]$stPb.current_backlog_id }
        } catch {}
        $pbResult = Add-ProjectBacklogFromMarker -Block $pbBlock -Channel ([string]$pbForMarkers.slug) -Source $speaker -SourceTaskId $sourceTaskId -MaxTasks $pbMax
        $projectBacklogCreated += [int]$pbResult.created
        if ([int]$pbResult.created -gt 0) {
          $pbDetails = ''
          try {
            $ch = @($pbResult.chapters | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 3)
            $sl = @($pbResult.slugs | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5)
            $bits = New-Object 'System.Collections.Generic.List[string]'
            if ($ch.Count -gt 0) { [void]$bits.Add('главы: ' + ($ch -join ', ')) }
            if ($sl.Count -gt 0) { [void]$bits.Add('atoms: ' + ($sl -join ', ')) }
            if ($bits.Count -gt 0) { $pbDetails = ' — ' + (($bits.ToArray()) -join '; ') }
          } catch {}
          Add-Message -From system -Text ("🧭 Project Autopilot: добавлено approved atom-задач: " + [int]$pbResult.created + $(if([int]$pbResult.skipped -gt 0){" (пропущено дублей: " + [int]$pbResult.skipped + ")"}else{""}) + $pbDetails) -Kind event | Out-Null
        } else {
          $errText = ''
          try { $errText = (@($pbResult.errors) -join '; ') } catch {}
          if ([string]::IsNullOrWhiteSpace($errText)) { $errText = 'валидных новых атомов нет' }
          Add-Message -From system -Text ("🧭 Project Autopilot: atom batch не добавлен — " + $errText) -Kind event | Out-Null
        }
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Project Autopilot marker parse failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  # [[IDEA: ...]] -> agent raises a self-improvement idea into the backlog (status 'new').
  $ideaPattern = '(?m)^\s*\[\[IDEA:\s*(.+?)\s*\]\]\s*$'
  $proposedIdeas = New-Object System.Collections.Generic.List[string]
  # 2026-05-28: suppress mid-task echoing of the user spec back as "ideas".
  # Real incident: my Phase 1 task spec mentioned "Этап 2: Test-FeatureSimilarity",
  # the planner emitted [[IDEA: добавить Test-FeatureSimilarity...]] in turn 1 as
  # a sincere idea — but it's just the user's roadmap restated. We compare each
  # idea-text against the current task text by word-overlap; >50% → suppress.
  # Also gather words from current task for cheap overlap check.
  $taskTextForSuppress = ''
  try { $taskTextForSuppress = [string](Read-State).current_task } catch {}
  $taskNorm = ''
  $taskWords = @()
  if (-not [string]::IsNullOrWhiteSpace($taskTextForSuppress)) {
    $taskNorm = ($taskTextForSuppress -replace '\s+',' ').Trim().ToLowerInvariant()
    $taskWords = @($taskNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
  }
  foreach ($m in [regex]::Matches($reply, $ideaPattern)) {
    $idea = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($idea)) { continue }
    # Mid-task echo guard
    if ($taskWords.Count -gt 5) {
      try {
        $ideaNorm = ($idea -replace '\s+',' ').Trim().ToLowerInvariant()
        $ideaWords = @($ideaNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
        if ($ideaWords.Count -gt 2) {
          $shared = ($ideaWords | Where-Object { $taskWords -contains $_ }).Count
          $ratio = $shared / [Math]::Max(1, $ideaWords.Count)
          if ($ratio -gt 0.5) {
            Add-Message -From system -Text ("💡 Идея пропущена (повтор текста задачи, overlap " + ('{0:N2}' -f $ratio) + "): " + ($idea.Substring(0,[Math]::Min(80,$idea.Length)))) -Kind event | Out-Null
            continue
          }
        }
      } catch {}
    }
    try {
      $ideaScope = if ($channelIsMainMarkers) { 'bridge' } else { 'project' }
      $addIdeaResult = Add-Idea -Text $idea -From $speaker -Tags @($speaker) -Status 'new' -Project ([string]$pbForMarkers.slug) -Scope $ideaScope
      $ideaOutcome = Resolve-AddIdeaOutcome -AddResult $addIdeaResult -IdeaText $idea -From $speaker
      if ($ideaOutcome.deduped) {
        $cosineText = 'n/a'
        if ($null -ne $ideaOutcome.cosine) {
          try { $cosineText = ('{0:N2}' -f ([double]$ideaOutcome.cosine)) } catch {}
        }
        $dedupId = if ([string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) { 'unknown' } else { [string]$ideaOutcome.itemId }
        Add-Message -From system -Text "💡 Идея уже в беклоге (cosine $cosineText): id=$dedupId" -Kind event | Out-Null
      } elseif ($ideaOutcome.created -and -not [string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) {
        [void]$proposedIdeas.Add($idea)
      } elseif ($addIdeaResult) {
        [void]$proposedIdeas.Add($idea)
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Add-Idea failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  # [[RUNJOB: команда | папка]] -> запустить долгую команду в фоне (без таймаута хода).
  $runjobPattern = '(?m)^\s*\[\[RUNJOB:\s*(.+?)\s*\]\]\s*$'
  $startedJobs = @()
  foreach ($m in [regex]::Matches($reply, $runjobPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    # Split on the LAST '|' only if the right-hand side looks like a workdir path.
    # This keeps PowerShell pipelines intact, e.g. "Get-Content x | Where-Object {...}".
    $lastPipe = $spec.LastIndexOf('|')
    $jcmd = $spec.Trim()
    $jdir = ''
    if ($lastPipe -ge 0) {
      $candidate = $spec.Substring($lastPipe + 1).Trim()
      # Plausible workdir: Windows abs (C:\...), UNC (\\...), relative (./, ..\), or tilde (~).
      $isPath = $candidate -match '^([A-Za-z]:\\|\\\\|~[\\\/]|\.\.?[\\\/]|\.\.?$)'
      $hasMeta = $candidate -match '[{}$;()|]'
      if ($isPath -and -not $hasMeta) {
        $jcmd = $spec.Substring(0, $lastPipe).Trim()
        $jdir = $candidate
      }
    }
    if ([string]::IsNullOrWhiteSpace($jcmd)) { continue }
    # IDEMPOTENCY (2026-05-29): do NOT relaunch a job whose command is ALREADY running, or that ran in
    # the last 15 min. ROOT CAUSE of "аудит запустился 3-й раз без команды": a discuss-loop + resume +
    # history-compaction made the agent re-emit [[RUNJOB: ...audit.ps1]] on almost every turn, and each
    # emit spawned a fresh audit. Dedupe by normalized command so a burst collapses to ONE run.
    $jnorm = ($jcmd -replace '\s+',' ').Trim().ToLowerInvariant()
    $dupRunning = $false
    try { foreach ($aj in @((Read-State).active_jobs)) { if ((([string]$aj.cmd) -replace '\s+',' ').Trim().ToLowerInvariant() -eq $jnorm) { $dupRunning = $true; break } } } catch {}
    $dupRecent = $false
    if (-not $dupRunning) {
      try {
        $jobsD = Join-Path $bridgeRoot 'jobs'
        $cutoff = (Get-Date).AddMinutes(-15)
        # 2026-06-01 ERR-014 fix (generalizes ERR-012): a deduped RUNJOB result is only valid if the
        # repo state it depended on hasn't changed since the prior run. The first attempt may have run
        # BEFORE its target existed (e.g. `npx tsx scripts/seed-admin.ts` before the script was created,
        # or `npm run build` before `npm install`) and failed; deduping the retry against that stale
        # failure reused a precondition-invalid result. So INVALIDATE the dedupe when the project's git
        # HEAD (last commit) OR node_modules/lockfile is NEWER than the prior run -> precondition changed
        # -> allow the rerun. General (every command), not just build/verify (that was ERR-012's gap).
        $pdir = $jdir
        if ([string]::IsNullOrWhiteSpace($pdir)) { try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $pdir = [string](Get-EffectiveProjectRoot) } } catch {} }
        $precondMtime = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($pdir)) {
          # (a) last commit time — covers committed target creation (seed script, generated routes, etc.)
          try {
            $gitX = Get-GitExe
            $ct = & $gitX -C $pdir log -1 --format=%cI 2>$null
            if ($ct) { $dt = [datetime]::Parse(([string]$ct).Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind); if ($dt -gt $precondMtime) { $precondMtime = $dt } }
          } catch {}
          # (b) node_modules / lockfile — covers `npm install` (not committed)
          foreach ($dep in @('node_modules','package-lock.json','pnpm-lock.yaml','yarn.lock')) {
            try { $dp = Join-Path $pdir $dep; if (Test-Path -LiteralPath $dp) { $dt = (Get-Item -LiteralPath $dp).LastWriteTime; if ($dt -gt $precondMtime) { $precondMtime = $dt } } } catch {}
          }
        }
        foreach ($cf in @(Get-ChildItem $jobsD -Filter '*.cmd' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoff })) {
          $cc = (([string]([System.IO.File]::ReadAllText($cf.FullName))) -replace '\s+',' ').Trim().ToLowerInvariant()
          if ($cc -eq $jnorm) {
            # ERR-014: repo/deps changed AFTER this prior run => prior result precondition-invalid => rerun.
            if ($precondMtime -gt $cf.LastWriteTime) { continue }
            $dupRecent = $true; break
          }
        }
      } catch {}
    }
    if ($dupRunning -or $dupRecent) {
      $why = if ($dupRunning) { 'уже выполняется' } else { 'уже запускалась в последние 15 минут' }
      Add-Message -From system -Text ("⏭ Не дублирую фоновую задачу ($why): $jcmd`nИспользуй предыдущий результат вместо повторного запуска.") -Kind event | Out-Null
      continue
    }
    # 2026-05-30 RUNJOB SAFETY GATE: this is the SECOND autonomous execution path (agent-emitted
    # background command), so it gets the same danger-class vetting as the backlog pre-flight gate.
    try {
      $jGate = Test-RunjobCommandSafe -Command $jcmd -BridgeRoot $bridgeRoot
      if (-not $jGate.safe) {
        Add-Message -From system -Text ("🛑 Фоновая команда ЗАБЛОКИРОВАНА (риск=" + [string]$jGate.risk + "): " + [string]$jGate.reason + ".`nКоманда: " + $jcmd + "`nНужна проверка оператора — мост её НЕ запускает.") -Kind event | Out-Null
        try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='runjob-blocked'; cmd=$jcmd; risk=[string]$jGate.risk; reason=[string]$jGate.reason }) } catch {}
        continue
      }
    } catch {}
    try { $job = Start-BridgeJob -Command $jcmd -WorkDir $jdir; if ($job) { $startedJobs += $job } } catch {}
  }
  if ($startedJobs.Count -gt 0) {
    $sj = $startedJobs
    Update-State ({ param($s) $cur=@(); if ($s.active_jobs) { $cur=@($s.active_jobs) }; $s.active_jobs=@($cur + $sj) }.GetNewClosure()) | Out-Null
    foreach ($job in $sj) { Add-Message -From system -Text "🛠 Запущена фоновая задача [$($job.id)]: $($job.cmd)`nЖду завершения (без таймаута), результат придёт сюда." -Kind event | Out-Null }
  }
  # [[NEED-TOOL: имя | контракт]] -> синтез инструмента на лету (Tool Foundry, Ф1). Сборка
  # идёт в песочнице (Build-AutoTool: parse -> smoke в ДОЧЕРНЕМ процессе -> критик на ДРУГОЙ
  # модели); зелёный инструмент пишется в tools/auto/<имя>.ps1 и СРАЗУ dot-source'ится здесь
  # (мы в script-scope верхнеуровневого while-цикла), поэтому Invoke-<имя> доступен и этому
  # ходу, и всем следующим. Reuse-before-rebuild: активный одноимённый инструмент не пересобираем.
  $needToolPattern = '(?m)^\s*\[\[NEED-TOOL:\s*(.+?)\s*\]\]\s*$'
  foreach ($m in [regex]::Matches($reply, $needToolPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    $ntParts = $spec -split '\|', 2
    $ntName = $ntParts[0].Trim()
    $ntContract = if ($ntParts.Count -ge 2) { $ntParts[1].Trim() } else { '' }
    $ntSafe = $null
    try { $ntSafe = Test-AutoToolName -Name $ntName } catch {}
    if (-not $ntSafe) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL]] отклонён: недопустимое имя '" + $ntName + "'. Нужно латиницей: буква, далее буквы/цифры/_ и дефис.") -Kind event | Out-Null
      continue
    }
    if ([string]::IsNullOrWhiteSpace($ntContract)) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL: " + $ntSafe + "]] без контракта. Формат: [[NEED-TOOL: имя | что инструмент делает]].") -Kind event | Out-Null
      continue
    }
    $ntExisting = $null
    try { $ntExisting = Get-AutoTool -Name $ntSafe } catch {}
    if ($ntExisting -and ([string]$ntExisting.status -eq 'active')) {
      Add-Message -From system -Text ("🔧 Инструмент '" + $ntSafe + "' уже есть (вызов: Invoke-" + $ntSafe + "). Переиспользуй — не пересобираю.") -Kind event | Out-Null
      continue
    }
    Add-Message -From system -Text ("🏗 Tool Foundry: синтез '" + $ntSafe + "' в песочнице (parse → smoke → критик)…") -Kind event | Out-Null
    $ntBuilt = $null
    try { $ntBuilt = Build-AutoTool -Name $ntSafe -Contract $ntContract } catch { $ntBuilt = $null }
    if ($ntBuilt -and $ntBuilt.ok) {
      try {
        $ntFile = Join-Path (Get-ToolForgeRoot) ($ntBuilt.name + '.ps1')
        if (Test-Path -LiteralPath $ntFile) { . $ntFile }   # load into engine script-scope NOW
      } catch {}
      Add-Message -From system -Text ("✅ Инструмент готов: '" + $ntBuilt.name + "' (вызов: " + $ntBuilt.entry + "). Контракт: " + $ntContract + ". Доступен сразу и на следующих ходах.") -Kind event | Out-Null
    } else {
      $ntWhy = if ($ntBuilt) { [string]$ntBuilt.reason } else { 'сборка упала (исключение)' }
      Add-Message -From system -Text ("⚠ Не построил '" + $ntSafe + "' → карантин. Причина: " + $ntWhy + ". Сделай задачу без него или уточни контракт и повтори [[NEED-TOOL]].") -Kind event | Out-Null
    }
  }
  # [[PLAN]] ... [[/PLAN]] -> создать persisted план-доску для текущей задачи.
  $planBlockPattern = '(?is)\[\[PLAN\]\].*?\[\[/PLAN\]\]'
  $planCreatedStepCount = $null
  try {
    $planNodes = ConvertFrom-PlanBlock -Text $reply
    if ($planNodes) {
      $planCreatedStepCount = New-Plan -Task $task -Nodes $planNodes
    }
  } catch {
    Add-Message -From system -Text ("⚠ Не удалось создать план-доску: " + $_.Exception.Message) -Kind event | Out-Null
  }

  # [[DISPATCH-DAG]] / [[DISPATCH-DAG: N]] -> исполнить ТЕКУЩУЮ план-доску как реально
  # диспетчеризуемый DAG (Project Foundry, Ф2): готовые шаги веером уходят в параллельных
  # воркеров в worktree'ах ПРИВЯЗАННОГО ПРОЕКТА, каждый шаг гейтится (done + >=1 commit) и
  # мёрджится-или-откатывается, волна за волной. Статусы шагов план-доски пишет сам
  # Invoke-PlanDag (через Set-PlanStepStatus), поэтому после диспатча доска отражает факт.
  # Жёстко отказываемся работать над самим bridge-репозиторием (foundry-слой тоже откажет).
  $dispatchDagPattern = '(?m)^\s*\[\[DISPATCH-DAG(?::\s*(\d+))?\]\]\s*$'
  $dispatchHit = [regex]::Match($reply, $dispatchDagPattern)
  if ($dispatchHit.Success) {
    $reqPar = 0
    if ($dispatchHit.Groups[1].Success) { try { $reqPar = [int]$dispatchHit.Groups[1].Value } catch { $reqPar = 0 } }
    $binding = $null
    try { $binding = Get-ChannelProjectBinding -Slug $Channel } catch { $binding = $null }
    if (-not $binding -or -not [bool]$binding.ok) {
      $bwhy = if ($binding) { [string]$binding.error } else { 'нет привязки' }
      Add-Message -From system -Text ("⚠ [[DISPATCH-DAG]] пропущен: канал не привязан к проекту ($bwhy). Сначала создай проект (New-Project) и привяжи канал.") -Kind event | Out-Null
    } else {
      $projRoot = [string]$binding.project_root
      $bridgeFull = ''; try { $bridgeFull = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\','/') } catch {}
      $projFull = $projRoot; try { $projFull = [System.IO.Path]::GetFullPath($projRoot).TrimEnd('\','/') } catch {}
      if ($projFull -and $bridgeFull -and $projFull.Equals($bridgeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Message -From system -Text "⚠ [[DISPATCH-DAG]] отклонён: канал указывает на сам bridge-репозиторий. DAG-исполнение работает только над отдельным проектом." -Kind event | Out-Null
      } else {
        $parNote = if ($reqPar -gt 0) { " (parallel=$reqPar)" } else { "" }
        Add-Message -From system -Text ("🧭 DISPATCH-DAG: исполняю план-доску как DAG над проектом " + $projFull + $parNote + "…") -Kind event | Out-Null
        $dag = $null
        try {
          if ($reqPar -gt 0) { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot -MaxParallel $reqPar -Channel $Channel }
          else               { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot -Channel $Channel }
        } catch {
          Add-Message -From system -Text ("⚠ DISPATCH-DAG исключение: " + $_.Exception.Message) -Kind event | Out-Null
        }
        if ($dag) {
          $icon = if ([bool]$dag.ok) { "✅" } else { "⚠" }
          $dmsg = $icon + " DISPATCH-DAG: " + [string]$dag.summary
          if (-not [bool]$dag.ok -and $dag.blockers -and $dag.blockers.Count -gt 0) {
            $blines = @($dag.blockers.GetEnumerator() | ForEach-Object { [string]$_.Key + ' <- ' + ((@($_.Value) -join ', ')) }) -join '; '
            if (-not [string]::IsNullOrWhiteSpace($blines)) { $dmsg += ("`nБлокеры: " + $blines) }
          }
          Add-Message -From system -Text $dmsg -Kind event | Out-Null
        }
      }
    }
  }

  # [[STEP-DONE: id | результат]] и [[STEP: id | status | результат]] -> обновить шаги плана.
  $stepDonePattern = '(?m)^\s*\[\[STEP-DONE:\s*([^|\]]+?)(?:\s*\|\s*(.*?))?\s*\]\]\s*$'
  $stepPattern = '(?m)^\s*\[\[STEP:\s*(.+?)\s*\]\]\s*$'
  $planStepUpdates = @()
  foreach ($m in [regex]::Matches($reply, $stepDonePattern)) {
    $stepId = $m.Groups[1].Value.Trim()
    $stepResult = if ($m.Groups.Count -gt 2) { $m.Groups[2].Value.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId)) { continue }
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status done -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → done" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  foreach ($m in [regex]::Matches($reply, $stepPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $stepId = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $rawStepStatus = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $stepStatus = if ($parts.Count -ge 2) { Normalize-PlanStatus -Status $rawStepStatus } else { '' }
    $stepResult = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId) -or [string]::IsNullOrWhiteSpace($stepStatus)) { continue }
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status $stepStatus -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → $stepStatus" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  $visibleReply = [regex]::Replace($reply, $fileMarkerPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $savePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $evidencePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $verifiedPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $findingPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $projectBacklogPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $studyFallbackPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $rememberPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $ideaPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $runjobPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $needToolPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, '(?s)\[\[PARALLEL:.+?\]\]', '')
  $visibleReply = [regex]::Replace($visibleReply, $planBlockPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $dispatchDagPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepDonePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepPattern, '')
  # 2026-06-03 slimming Atom 1 fix (Codex review): strip the shadow [[DECISION:{...}]] block so the
  # technical JSON never reaches visible chat/memory.
  $visibleReply = [regex]::Replace($visibleReply, '(?s)\[\[DECISION:\s*\{.*?\}\s*\]\]', '')
  if ($speaker -eq 'claude' -or [string]$turnResult.fallback -eq 'claude_as_coder' -or $fastLaneActiveForTurn) {
    $visibleReply = [regex]::Replace($visibleReply, '(?im)^\s*STATUS:\s*\w+\s*$', '')
  }
  # ── [[ЛАПА: skill | key=val | key=val]] — лапа as a first-class bridge SERVICE ──
  # An agent delegates a GUI / manual-input / visual-confirm / send-to-human action to лапа
  # (the operator's hands). The bridge invokes it AUTONOMOUSLY — the operator authorized full
  # autonomy, no per-action confirmation; лапа keeps its OWN fail-closed gates (chat-identity
  # wrong-contact safety, risk ladder, STOP). Safeguards here: a file kill-switch
  # (tmp/lapa-disabled.flag) disables the whole channel; an in-reply + 10-min recent-run dedup
  # stops a RE-EMITTED marker from firing the same action twice (critical so a re-emit never
  # double-sends to a human). Never throws — лапа-control returns a typed result, not exceptions.
  $lapaPattern = '(?m)^\s*\[\[(?:ЛАПА|LAPA(?:-SKILL)?)\s*:\s*(.+?)\s*\]\]\s*$'
  $lapaDisabled = Test-Path -LiteralPath (Join-Path $bridgeRoot 'tmp\lapa-disabled.flag')
  $lapaSeen = @{}
  foreach ($lm in [regex]::Matches($reply, $lapaPattern)) {
    $lspec = $lm.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($lspec)) { continue }
    $lparts = $lspec -split '\s*\|\s*'
    $lskill = ([string]$lparts[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($lskill)) { continue }
    $lparams = @{}
    for ($li = 1; $li -lt $lparts.Count; $li++) {
      $kv = [string]$lparts[$li]; $eq = $kv.IndexOf('=')
      if ($eq -lt 1) { continue }
      $lparams[$kv.Substring(0, $eq).Trim()] = $kv.Substring($eq + 1).Trim()
    }
    $lkey = ($lskill + '|' + (($lparams.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join '|')).ToLowerInvariant()
    if ($lapaSeen.ContainsKey($lkey)) { continue }
    $lapaSeen[$lkey] = $true
    if ($lapaDisabled) { try { Add-Message -From system -Text "🎛 лапа выключена (tmp/lapa-disabled.flag) — маркер пропущен: $lskill" -Kind event | Out-Null } catch {}; continue }
    $lapaLogDir = Join-Path $bridgeRoot 'tmp\lapa-marker-log'
    $lapaDup = $false
    try {
      if (Test-Path -LiteralPath $lapaLogDir) {
        $lcut = (Get-Date).AddMinutes(-10)
        foreach ($lf in @(Get-ChildItem $lapaLogDir -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $lcut })) {
          if ((([string]([System.IO.File]::ReadAllText($lf.FullName))).Trim().ToLowerInvariant()) -eq $lkey) { $lapaDup = $true; break }
        }
      }
    } catch {}
    if ($lapaDup) { try { Add-Message -From system -Text "🎛 лапа: то же действие уже выполнялось за 10 мин — пропущено ($lskill)." -Kind event | Out-Null } catch {}; continue }
    try {
      if (-not $lparams.ContainsKey('stop_flag')) { $lparams['stop_flag'] = (Join-Path $bridgeRoot 'tmp\lapa-stop.flag') }
      . (Join-Path $bridgeRoot 'tools\lapa-control.ps1')
      $lres = Invoke-LapaSkill -Skill $lskill -Params $lparams
      try { New-Item -ItemType Directory -Force -Path $lapaLogDir | Out-Null; [System.IO.File]::WriteAllText((Join-Path $lapaLogDir ((Get-Date -Format 'yyyyMMddHHmmssfff') + '.txt')), $lkey) } catch {}
      $ltxt = "🎛 лапа/$lskill → " + ([string]$lres.status)
      if ((-not $lres.ok) -and $lres.error) { $ltxt += " — " + ([string]$lres.error) }
      if ($lres.proof_path) { $ltxt += " (пруф: " + ([string]$lres.proof_path) + ")" }
      Add-Message -From system -Text $ltxt -Kind event | Out-Null
    } catch {
      try { Add-Message -From system -Text ("⚠ лапа: вызов не удался — " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }

  $visibleReply = $visibleReply.Trim()
  if ($failedAttachmentPaths.Count -gt 0) {
    $failLines = ($failedAttachmentPaths | ForEach-Object { "- $_" }) -join "`n"
    $fileWarning = "⚠ Не удалось прикрепить файл:`n$failLines"
    if ([string]::IsNullOrWhiteSpace($visibleReply)) { $visibleReply = $fileWarning }
    else { $visibleReply = $visibleReply.TrimEnd() + "`n`n" + $fileWarning }
  }
  if ([string]::IsNullOrWhiteSpace($visibleReply) -and $attachmentMetas.Count -eq 0) { $visibleReply = "(нет ответа от $speaker)" }
  Add-Message -From $speaker -Text $visibleReply -Attachments $attachmentMetas -Model $activeModel | Out-Null
  foreach ($sp in $savedPaths) { Add-Message -From system -Text "📝 Заметка сохранена: $sp" -Kind event | Out-Null }
  foreach ($source in $evidenceSources) { Add-Message -From system -Text "📊 Evidence записан: $source" -Kind event | Out-Null }
  if ($null -ne $planCreatedStepCount) { Add-Message -From system -Text "🗂 План-доска создана: шагов $planCreatedStepCount" -Kind event | Out-Null }
  foreach ($pu in $planStepUpdates) { Add-Message -From system -Text "🗂 Шаг плана обновлён: $pu" -Kind event | Out-Null }
  if ($studyFindings.Count -gt 0) {
    $snap = [string](Read-State).study_snapshot
    $snapParts = @()
    if (-not [string]::IsNullOrWhiteSpace($snap)) { $snapParts += $snap.Trim() }
    $snapParts += ($studyFindings -join "`n")
    $newSnap = ($snapParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    Update-State ({ param($s) $s.study_snapshot = $newSnap }.GetNewClosure()) | Out-Null
  }
  foreach ($rf in $rememberedFacts) { Add-Message -From system -Text "🧠 Запомнено агентом: $rf" -Kind event | Out-Null }
  foreach ($pi in $proposedIdeas) { Add-Message -From system -Text "💡 Идея в бэклог (от $speaker): $pi" -Kind event | Out-Null }
}
