# doctor.ps1 -- the bridge auto-repair agent ("Doctor").
# When a task hits a hard failure (planner-timeout-exhausted, watchdog rollback, etc.),
# Doctor holds the original task, diagnoses the root cause, writes a minimal fix, verifies
# it, commits it, then resumes the original task -- without operator intervention. The
# Doctor uses the normal planner->coder->critic pipeline (mode='doctor' changes the prompt).
#
# State fields owned by Doctor (initialized in Initialize-Bridge):
#   held_task          -- text of the original task being suspended
#   doctor_active      -- bool, Doctor is currently triaging/fixing
#   doctor_attempts    -- 0/1; MVP allows only one repair attempt per held task
#   doctor_reason      -- short reason string (planner_timeout, watchdog_rollback, ...)
#   doctor_started_at  -- ISO timestamp the Doctor activated

function Get-DoctorMaxAttempts { return 1 }   # MVP: one shot per held task

function Activate-Doctor {
  # Called by the driver when a hard failure is detected. Suspends the current task into
  # held_task, flags Doctor active, leaves current_task null so the next loop iteration
  # picks up the Doctor task.
  param([string]$Reason, [string]$Detail = '')
  $st = Read-State
  $cur = [string]$st.current_task
  $already = [bool]$st.doctor_active
  if ($already) {
    # Doctor failure or recursion -- don't double-activate
    try { Add-Message -From system -Text ("🩺 Доктор уже активен; повторного вызова не делаю. Reason: " + $Reason) -Kind event | Out-Null } catch {}
    return $false
  }
  $now = (Get-Date).ToString('o')
  Update-State ({ param($s)
    $s.held_task         = $cur
    $s.doctor_active     = $true
    $s.doctor_attempts   = 0
    $s.doctor_reason     = $Reason
    $s.doctor_started_at = $now
    $s.current_task      = $null
    $s.task_turn         = 0
    $s.task_mode         = 'normal'
    $s.no_progress_count = 0
    $s.timeout_retry_count = 0
    $s.task_did_actions  = $false
    $s.coder_fired       = $false
    $s.coder_bypass_retry_count = 0
    $s.verify_retry_count = 0
    $s.critic_retry_count = 0
    $s.force_planner     = $false
    Clear-AuditorSuppressedHashes -State $s
    $s.active_agent = $null; $s.active_model = $null; $s.status_text = $null
  }.GetNewClosure()) | Out-Null
  $snippet = $cur
  if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0,80) + '...' }
  $detailMsg = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { " — $Detail" }
  try { Add-Message -From system -Text ("🩺 Доктор активирован: " + $Reason + $detailMsg + ". Задача приостановлена: «" + $snippet + "». Диагностика и фикс пойдут отдельной задачей.") -Kind event | Out-Null } catch {}
  try { Append-DoctorEvent -Event 'activate' -Reason $Reason } catch {}
  return $true
}

function Get-DoctorContext {
  # Compact diagnostic dump for the Doctor prompt: recent system events (last 15), watchdog
  # log tail, supervisor log tail, git log (last 5), git status. Strings only -- no ETS.
  $root = Get-BridgeRoot
  $sb = New-Object System.Text.StringBuilder
  # Recent system events
  try {
    $msgs = @(Get-Messages -Since 0) | Where-Object { $_.from -eq 'system' } | Select-Object -Last 15
    [void]$sb.AppendLine("=== Recent system events (last 15) ===")
    foreach ($m in $msgs) {
      $t = [string]$m.text
      if ($t.Length -gt 220) { $t = $t.Substring(0,220) + '...' }
      [void]$sb.AppendLine("[seq $($m.seq)] $t")
    }
  } catch {}
  # Watchdog log tail
  try {
    $wd = Join-Path $root 'control\watchdog.log'
    if (Test-Path $wd) {
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== watchdog.log (tail 10) ===")
      $tail = [System.IO.File]::ReadAllLines($wd) | Select-Object -Last 10
      foreach ($l in $tail) { [void]$sb.AppendLine($l) }
    }
  } catch {}
  # Supervisor log tail
  try {
    $sup = Join-Path $root 'control\supervisor.log'
    if (Test-Path $sup) {
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== supervisor.log (tail 10) ===")
      $tail = [System.IO.File]::ReadAllLines($sup) | Select-Object -Last 10
      foreach ($l in $tail) { [void]$sb.AppendLine($l) }
    }
  } catch {}
  # Git log + status
  try {
    $git = 'C:\Program Files\Git\cmd\git.exe'
    if (Test-Path $git) {
      $logOut = & $git -C $root log --oneline -6 2>$null
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== git log -6 ===")
      foreach ($l in @($logOut)) { [void]$sb.AppendLine([string]$l) }
      $statOut = & $git -C $root status --short 2>$null
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== git status --short ===")
      foreach ($l in @($statOut)) { [void]$sb.AppendLine([string]$l) }
    }
  } catch {}
  return $sb.ToString()
}

function Get-DoctorTaskText {
  # Compose the "task" the Doctor sees as its current_task. This is plugged into the normal
  # planner->coder pipeline; mode='doctor' tells Build-Prompt to use a special intro.
  $st = Read-State
  $held = [string]$st.held_task
  $reason = [string]$st.doctor_reason
  $heldShort = $held; if ($heldShort.Length -gt 400) { $heldShort = $heldShort.Substring(0,400) + '...[truncated]' }
  $ctx = Get-DoctorContext
  return @"
🩺 ДОКТОР — задача саморемонта моста.

ПРИЧИНА ВЫЗОВА: $reason

ПРИОСТАНОВЛЕННАЯ ЗАДАЧА (восстановим после фикса; не выполняй её саму!):
---
$heldShort
---

ДИАГНОСТИЧЕСКИЙ КОНТЕКСТ:
$ctx

ЧТО ОТ ТЕБЯ НУЖНО:
1) Диагноз: одним абзацем — какой корневой причиной задача упала. Сошлись на конкретные строки логов / commit / state-поля.
2) Минимальный фикс: только то, что устранит первопричину. НЕ переделывай систему, НЕ оптимизируй смежные модули.
3) Реализация через STATUS: CONTINUE → Codex (multi-agent дисциплина: правки кода идут через кодера).
4) Верификация: smoke OK + конкретная проверка, что то самое больше не падает (например, если был planner_timeout — кэп в конфиге/коде увеличен; если ETS-OOM — sanitize применён).
5) Коммит с префиксом `repair(<область>):` и в теле описание корня + фикса.
6) STATUS: DONE с [[VERIFIED: ...]]. После твоего DONE я (driver) автоматически восстановлю приостановленную задачу.

ОГРАНИЧЕНИЯ (строго):
- НЕ трогать `watchdog.ps1`, `supervisor.ps1`, `.git/*`, `secrets.json`, `auth.json`.
- НЕ трогать структуру state-полей.
- Если корень требует ручного решения оператора (повреждение данных, потеря секретов) — STATUS: DONE с маркером `[[ESCALATE: оператор]]` и кратким описанием; я уведомлю пользователя.
- Maximum 1 попытка (это MVP) — если не справишься, я эскалирую.

Начинай.
"@
}

function Complete-Doctor {
  # Called when Doctor reports STATUS: DONE successfully. Restore the held task as the new
  # current_task with mode='normal' and fresh counters; clear Doctor state.
  $st = Read-State
  $held = [string]$st.held_task
  if ([string]::IsNullOrWhiteSpace($held)) {
    try { Add-Message -From system -Text "🩺 Доктор завершил, но held_task пуст — нечего возобновлять. Возвращаюсь в idle." -Kind event | Out-Null } catch {}
    # FIX 2026-05-26: clear current_task and counters too, else the loop keeps running the
    # doctor diagnostic prompt as a normal task (caught on first wiring test).
    Update-State ({ param($s)
      $s.doctor_active=$false; $s.held_task=$null; $s.doctor_reason=''; $s.doctor_started_at=$null; $s.doctor_attempts=0
      $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'
      $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false
      $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.critic_retry_count=0
      $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''
      $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
      Clear-AuditorSuppressedHashes -State $s
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
      $s.status='idle'
    }.GetNewClosure()) | Out-Null
    return
  }
  Update-State ({ param($s)
    $s.current_task         = $held
    $s.held_task            = $null
    $s.doctor_active        = $false
    $s.doctor_reason        = ''
    $s.doctor_started_at    = $null
    $s.doctor_attempts      = 0
    $s.task_turn            = 0
    $s.task_mode            = 'normal'
    $s.no_progress_count    = 0
    $s.timeout_retry_count  = 0
    $s.task_did_actions     = $false
    $s.coder_fired          = $false
    $s.coder_bypass_retry_count = 0
    $s.verify_retry_count   = 0
    $s.critic_retry_count   = 0
    $s.force_planner        = $false
    Clear-AuditorSuppressedHashes -State $s
  }.GetNewClosure()) | Out-Null
  $snippet = $held; if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0,80) + '...' }
  try { Add-Message -From system -Text ("🩺 Доктор закончил — фикс применён и проверен. Возобновляю приостановленную задачу: «" + $snippet + "».") -Kind event | Out-Null } catch {}
  try { Append-DoctorEvent -Event 'complete' } catch {}
}

function Abort-Doctor {
  # Called when Doctor attempts are exhausted or Doctor itself fails. Keep held_task in
  # state (operator decides what to do); clear active/attempts so loop won't retry.
  param([string]$Reason = 'attempts exhausted')
  Update-State { param($s) $s.doctor_active=$false; $s.doctor_attempts=0; $s.doctor_reason=''; $s.doctor_started_at=$null; $s.current_task=$null; $s.task_turn=0; Clear-AuditorSuppressedHashes -State $s } | Out-Null
  try { Add-Message -From system -Text ("🩺 Доктор не справился (" + $Reason + "). Held-task сохранён в state. Жду оператора.") -Kind event | Out-Null } catch {}
  try { Send-PushEvent -Kind need_you -Text "Doctor failed: $Reason" } catch {}
  try { Append-DoctorEvent -Event 'abort' -Reason $Reason } catch {}
}

function Test-RestartLoop {
  # Detect "many restarts in a short window with no successful turn" — symptom of a stall the
  # current trigger set (timeout/rollback) misses. User reported 2026-05-26: bridge restarted
  # 4 times in 4 min while Doctor stayed silent. Returns reason string if triggered, else $null.
  #
  # FIX 2026-05-26: previously [datetime]$m.ts (where $m.ts ends in "Z") returned a LOCAL
  # DateTime in PowerShell (the cast auto-converts UTC->Local and sets Kind=Local). The
  # resulting comparison against a UTC cutoff used raw ticks, so a UTC timestamp from hours
  # ago was treated as "recent" by the timezone-offset amount. Result: every historical
  # restart event passed the cutoff filter forever → Doctor false-positive on every fresh
  # boot. Fix: ((Get-Date $m.ts).ToUniversalTime()) normalizes back to UTC for the compare.
  param([int]$WindowMinutes = 5, [int]$RestartThreshold = 3)
  $root = Get-BridgeRoot
  $cutoff = (Get-Date).AddMinutes(-[Math]::Abs($WindowMinutes)).ToUniversalTime()
  # 1) count "Перезапуск по запросу" system events in conversation.jsonl since cutoff
  $restarts = 0
  try {
    $msgs = @(Get-Messages -Since 0) | Where-Object { $_.from -eq 'system' -and ([string]$_.text) -match 'Перезапуск по запросу' }
    foreach ($m in $msgs) {
      try { if (([datetime]$m.ts).ToUniversalTime() -ge $cutoff) { $restarts++ } } catch {}
    }
  } catch {}
  if ($restarts -lt $RestartThreshold) { return $null }
  # 2) check turns.jsonl: was there ANY ok turn in the same window? If yes, restarts are
  #    just self-test recycles (legitimate) — don't fire Doctor.
  $okTurns = 0
  try {
    $tp = Join-Path $root 'turns.jsonl'
    if (Test-Path $tp) {
      foreach ($line in [System.IO.File]::ReadAllLines($tp, [System.Text.Encoding]::UTF8) | Select-Object -Last 50) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        try { if (([datetime]$r.ts).ToUniversalTime() -ge $cutoff -and [string]$r.status -eq 'ok') { $okTurns++ } } catch {}
      }
    }
  } catch {}
  if ($okTurns -ge 1) { return $null }   # there IS progress, restarts are self-tests
  return "restart_loop_no_progress (${restarts} restarts/${WindowMinutes}min, 0 ok-turns)"
}

function Test-DoctorSignal {
  # Watchdog leaves control/repair.signal after a rollback. We pick it up on the next loop
  # iteration, activate Doctor, and consume the signal. File contains a short reason string.
  $sig = Join-Path (Get-BridgeRoot) 'control\repair.signal'
  if (-not (Test-Path $sig)) { return $null }
  $reason = 'watchdog_rollback'
  try { $txt = [System.IO.File]::ReadAllText($sig); if ($txt) { $reason = $txt.Trim() } } catch {}
  try { Remove-Item -LiteralPath $sig -Force -ErrorAction SilentlyContinue } catch {}
  return $reason
}
