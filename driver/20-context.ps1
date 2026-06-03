function Test-AutonomyReady {
  # True if the bridge may START autonomous backlog work right now (reads merged settings).
  $a = $null
  try { $a = Get-AutonomySettings } catch { return $false }
  if (-not $a) { return $false }
  if (-not [bool]$a.enabled) { return $false }
  # 2026-05-30: per-channel autonomy gate. Channels in autonomyDisabledChannels do
  # not auto-claim backlog work (travel is off by default so it doesn't compete with
  # main for the single shared Codex). Explicit user messages are unaffected.
  try {
    $curCh = ''
    try { $curCh = [string](Get-PinnedChannel) } catch {}
    if ([string]::IsNullOrWhiteSpace($curCh)) { $curCh = 'main' }
    if (@($a.autonomyDisabledChannels) -contains $curCh) { return $false }
  } catch {}
  $quietMin = [double]$a.idleQuietMinutes
  if ((Get-LastUserActivityMinutes) -lt $quietMin) { return $false }
  $cap = [int]$a.maxAutonomousTasksPerDay
  if ($cap -gt 0) {
    $st = Read-State
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $cnt = 0
    if (($st.PSObject.Properties.Name -contains 'autonomous_day') -and ([string]$st.autonomous_day -eq $today)) { $cnt = [int]$st.autonomous_count }
    if ($cnt -ge $cap) { return $false }
  }
  return $true
}

function Get-AutonomyIdleReason {
  # 2026-05-31 (Foundation #4): human-readable reason WHY the channel is not claiming an
  # autonomous task right now. Mirrors Test-AutonomyReady but returns a string for the operator
  # (surfaced by pulse / why-idle) so diagnosing a stalled channel no longer means reading driver.ps1.
  $a = $null
  try { $a = Get-AutonomySettings } catch { return 'settings-error' }
  if (-not $a) { return 'no-settings' }
  if (-not [bool]$a.enabled) { return 'autonomy disabled (settings.enabled=false)' }
  $curCh = ''
  try { $curCh = [string](Get-PinnedChannel) } catch {}
  if ([string]::IsNullOrWhiteSpace($curCh)) { $curCh = 'main' }
  if (@($a.autonomyDisabledChannels) -contains $curCh) { return ("channel '" + $curCh + "' is paused (autonomyDisabledChannels)") }
  $quietMin = [double]$a.idleQuietMinutes
  $lua = 99999.0
  try { $lua = [double](Get-LastUserActivityMinutes) } catch {}
  if ($lua -lt $quietMin) { return ("idle-quiet: last activity {0:N1}m < required {1}m" -f $lua, $quietMin) }
  $cap = [int]$a.maxAutonomousTasksPerDay
  if ($cap -gt 0) {
    $st = Read-State
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $cnt = 0
    if (($st.PSObject.Properties.Name -contains 'autonomous_day') -and ([string]$st.autonomous_day -eq $today)) { $cnt = [int]$st.autonomous_count }
    if ($cnt -ge $cap) { return ("daily cap reached (" + $cnt + "/" + $cap + ")") }
  }
  return 'ready (will claim next runnable/approved idea)'
}

function Invoke-AutoPush {
  # 2026-05-30: after the driver commits work, push it to origin so everything
  # lands on GitHub automatically. Non-fatal: only runs if a remote + upstream
  # exist and HEAD is ahead. Never force-pushes; a push failure is swallowed so
  # it can never block the autonomous loop.
  param([string]$Root)
  try {
    $remote = & git -C $Root remote 2>$null
    if (-not $remote) { return }                       # no remote -> nothing to push
    $ahead = (& git -C $Root rev-list --count '@{upstream}..HEAD' 2>$null)
    $aheadN = 0; [void][int]::TryParse((([string]$ahead).Trim()), [ref]$aheadN)
    if ($aheadN -le 0) { return }
    & git -C $Root push 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host ("auto-push: pushed " + $aheadN + " commit(s) to origin") }
    else { Write-Host ("auto-push: push failed (exit " + $LASTEXITCODE + "); will retry next commit") }
  } catch {}
}

function Get-FileReferenceCount {
  # How many times $FileName appears across core code (driver/server/lib/tools),
  # excluding the file itself. >0 means the file is USED (launched/called/referenced).
  param([string]$FileName, [string]$BridgeRoot)
  $refs = 0
  try {
    foreach ($d in @($BridgeRoot, (Join-Path $BridgeRoot 'lib'), (Join-Path $BridgeRoot 'tools'))) {
      foreach ($sf in @(Get-ChildItem -LiteralPath $d -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {
        if ($sf.Name -eq $FileName) { continue }
        try { if (([System.IO.File]::ReadAllText($sf.FullName)) -match [regex]::Escape($FileName)) { $refs++ } } catch {}
      }
    }
  } catch {}
  return $refs
}

function Test-AutonomousTaskSafe {
  # 2026-05-30 GENERIC PRE-EXECUTION SAFETY GATE (deliberately NOT tuned to one bug).
  # Critic/QA validate the RESULTING code, not whether the TASK itself is destructive
  # (deleting a used file / dropping data / breaking a feature passes smoke). This gate
  # vets the task by CLASS of danger so it catches ANY critical mistake -- deleting
  # critical files of any type, wiping data/history, disabling protection, removing or
  # breaking existing features, irreversible ops. The orphaned-tool case is just one
  # instance of "destructive op on a still-used file". Returns @{ safe; risk; reason }.
  # Fail-OPEN on internal error (never wedge the loop); block on any confirmed danger.
  param([string]$TaskText, [string]$BridgeRoot)
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $txt = [string]$TaskText
  try {
    $coreRe = '^(driver|server|supervisor|watchdog|circuit-breaker|common|backlog|audit|deep-audit|deep-audit-agent|audit-runner|audit-functional|audit-security|audit-signals|parallel|foundry|memory|project-context|doctor|channels|settings|metrics|plan|toolforge|intent|postmortem|llm|usage|notify|replay|radar|features|codemem)'
    # any code/config/data file the task names -- NOT just .ps1
    $files = @([regex]::Matches($txt, '([\w\-]+\.(ps1|psm1|json|html|js|md|jsonl))') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)

    # --- A. Irreversible operations (any class, deterministic) ---
    $irrev = @(
      @{ re='(?i)git\s+reset\s+--hard';                         why='git reset --hard (необратимая потеря правок)' },
      @{ re='(?i)git\s+push\b[^\n]*--force';                    why='git push --force (перезапись истории)' },
      @{ re='(?i)git\s+branch\s+-D|git\s+clean\s+-[a-z]*[fdx]'; why='удаление веток / git clean -fd (необратимо)' },
      @{ re='(?i)\brm\s+-[a-z]*[rf]|Remove-Item[^\n]*-Recurse'; why='рекурсивное/принудительное удаление' },
      @{ re='(?i)drop\s+(table|database)|truncate\s+table';     why='drop/truncate (удаление данных)' },
      @{ re='(?i)(удал|снес|очист|wipe|purge)\w*\s+(вс[её]|базу|таблиц|истори|реестр|memory|память|backlog|бэклог|логи)'; why='массовое удаление данных/истории' }
    )
    foreach ($p in $irrev) { if ($txt -match $p.re) { [void]$reasons.Add($p.why) } }

    # --- B. Disabling / bypassing ANY protection or safety mechanism ---
    if ($txt -match '(?i)(disable|remove|удал|отключ|снес|убер|обойти|bypass|skip|drop)\w*') {
      if ($txt -match '(?i)(watchdog|circuit.?breaker|supervisor|security|\bauth\b|sandbox|guard|validator|safety|secret|tripwire|preflight|pre-flight|защит|предохранитель|проверк|валидат)') {
        [void]$reasons.Add('отключение/обход защитного или проверочного механизма')
      }
    }

    # --- C. Destructive op on a CORE, critical-config/state, or still-USED file (ANY type) ---
    $isDestructive = ($txt -match '(?i)(\bdelete\b|\bremove\b|удал|\brm\s|Remove-Item|снес|\bdrop\b|очист\w*\s+(файл|таблиц))')
    if ($isDestructive) {
      if ($txt -match '(?i)(config\.json|secrets\.json|auth\.json|settings\.json|\.git\b|web[\\/]index\.html|registry\.json|state\.json|backlog\.jsonl)') {
        [void]$reasons.Add('деструктив над критическим файлом конфигурации/состояния/данных')
      }
      foreach ($fn in $files) {
        if ($fn -match $coreRe) { [void]$reasons.Add("деструктив над CORE-файлом ($fn)"); continue }
        if ($fn -match '(?i)\.ps1$') { $rc = Get-FileReferenceCount -FileName $fn -BridgeRoot $BridgeRoot; if ($rc -gt 0) { [void]$reasons.Add("деструктив над используемым файлом $fn (ссылок: $rc)") } }
      }
    }
    # Orphaned-claim is a special case of C: 'orphaned X.ps1' where X is actually referenced.
    if ($txt -match '(?i)orphan') {
      foreach ($fn in $files) { if ($fn -match '(?i)\.ps1$') { $rc = Get-FileReferenceCount -FileName $fn -BridgeRoot $BridgeRoot; if ($rc -gt 0) { [void]$reasons.Add("ложная orphaned-предпосылка: $fn используется (ссылок: $rc)") } } }
    }

    if ($reasons.Count -gt 0) { return [pscustomobject]@{ safe=$false; risk='high'; reason=(@($reasons | Select-Object -Unique) -join '; ') } }

    # --- D. Generic LLM pre-flight: covers ANY harm the rules miss -- breaking/removing
    #        existing features (regressions), subtle destruction, irreversibility, wide blast radius. ---
    try {
      if (Get-Command Invoke-LLM -ErrorAction SilentlyContinue) {
        $q = "Ты — предохранитель автономного агента (мост Claude+Codex). Агент собирается ВЫПОЛНИТЬ БЕЗ ЧЕЛОВЕКА задачу из бэклога:`n`n""$txt""`n`nЗаблокируй (RISKY) ТОЛЬКО если задача ЯВНО содержит опасное или необратимое действие: (1) УДАЛЕНИЕ нужного кода/файлов/данных/истории/памяти; (2) УДАЛЕНИЕ или ОТКЛЮЧЕНИЕ существующей рабочей фичи либо защиты (watchdog/circuit-breaker/supervisor/security/sandbox); (3) необратимая операция (force-push, reset --hard, drop/truncate, массовое удаление). КРИТИЧНО ВАЖНО: обычная инженерная работа — ДОБАВЛЕНИЕ нового, ИЗМЕНЕНИЕ/УЛУЧШЕНИЕ/РЕФАКТОРИНГ существующего кода (ДАЖЕ в ядре и core-файлах вроде driver/audit/deep-audit), исправление багов, документация, новые срезы/проверки/метрики — это SAFE. Само по себе изменение core-файла НЕ опасно: отдельные критик и QA-агент проверят результат на регрессии. Блокируй только ЯВНОЕ удаление/отключение/уничтожение существующего или необратимость — НЕ обычные правки. Ответь СТРОГО: первая строка ровно одно слово SAFE или RISKY; вторая строка — краткая причина (<18 слов)."
        $reply = Invoke-LLM -Purpose 'preflight-safety' -Model 'gemini-2.5-flash-lite' -Prompt $q -TimeoutSec 25 -Temperature 0.1
        if ([string]$reply -match '(?im)^\s*RISKY') {
          $why = (($reply -split "`r?`n") | Where-Object { $_ -notmatch '(?i)^\s*RISKY\s*$' -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
          [void]$reasons.Add('LLM pre-flight RISKY: ' + ([string]$why).Trim())
        }
      }
    } catch {}
  } catch {
    return [pscustomobject]@{ safe=$true; risk='low'; reason='gate-error-failopen' }
  }
  if ($reasons.Count -gt 0) { return [pscustomobject]@{ safe=$false; risk='high'; reason=($reasons -join '; ') } }
  return [pscustomobject]@{ safe=$true; risk='low'; reason='ok' }
}

function Test-RunjobCommandSafe {
  # 2026-05-30 SECOND AUTONOMOUS PATH: [[RUNJOB: cmd]] runs an agent-emitted command in the
  # background, bypassing the backlog pre-flight gate entirely. A confused/compacted agent
  # could emit a destructive command (rm -rf, reset --hard, drop) and it would just run.
  # This vets the COMMAND by the same classes of danger as Test-AutonomousTaskSafe -- but
  # DETERMINISTIC ONLY (no LLM): RUNJOB fires often (audit etc.), so keep it fast. Returns
  # @{ safe; risk; reason }. Fail-OPEN on internal error (never wedge the loop).
  param([string]$Command, [string]$BridgeRoot)
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $txt = [string]$Command
  # 2026-06-01 ERR-015: Remove-Item on the Env: drive clears a PROCESS environment variable, NOT a
  # filesystem path — it is not destructive. Neutralize those forms BEFORE the destructive scan so a
  # legitimate seed/test cleanup like `Remove-Item Env:ADMIN_SECRET -Force` (scrubbing a secret from
  # the process env) isn't blocked as "forced deletion". Filesystem Remove-Item is untouched.
  try { $txt = $txt -replace '(?i)Remove-Item\s+(-(?:Path|LiteralPath)\s+)?Env:\\?[A-Za-z_][A-Za-z0-9_]*(\s+-[A-Za-z]+(\s+\w+)?)*', ' env-var-clear ' } catch {}
  try {
    # A. Irreversible operations (PS + cmd + git + sql forms).
    $irrev = @(
      @{ re='(?i)git\s+reset\s+--hard';                         why='git reset --hard (необратимая потеря правок)' },
      @{ re='(?i)git\s+push\b[^\n]*--force|--force-with-lease'; why='git push --force (перезапись истории)' },
      @{ re='(?i)git\s+branch\s+-D|git\s+clean\s+-[a-z]*[fdx]'; why='удаление веток / git clean -fd (необратимо)' },
      @{ re='(?i)\brm\s+-[a-z]*[rf]|Remove-Item[^\n]*-Recurse|Remove-Item[^\n]*-Force'; why='рекурсивное/принудительное удаление' },
      @{ re='(?i)\bdel\s+/[a-z]*[sq]|\brmdir\s+/[a-z]*s|\brd\s+/[a-z]*s'; why='del /s / rmdir /s (рекурсивное удаление)' },
      @{ re='(?i)Clear-Content|Set-Content[^\n]*\$null|Out-File[^\n]*-Force[^\n]*(state|backlog|config|registry|secrets|auth)'; why='перезапись/обнуление критического файла' },
      @{ re='(?i)drop\s+(table|database)|truncate\s+table';     why='drop/truncate (удаление данных)' },
      @{ re='(?i)Stop-Computer|Restart-Computer|shutdown\s+/';   why='выключение/перезагрузка машины' },
      @{ re='(?i)Format-Volume|format\s+[a-z]:';                why='форматирование тома' }
    )
    foreach ($p in $irrev) { if ($txt -match $p.re) { [void]$reasons.Add($p.why) } }

    # B. Disabling / bypassing ANY protection or safety mechanism.
    if ($txt -match '(?i)(disable|remove|удал|отключ|снес|убер|обойти|bypass|skip|kill|stop|drop)\w*') {
      if ($txt -match '(?i)(watchdog|circuit.?breaker|supervisor|security|sandbox|guard|validator|safety|secret|tripwire|preflight|pre-flight|защит|предохранитель|валидат)') {
        [void]$reasons.Add('отключение/обход защитного механизма')
      }
    }

    # C. Destructive op naming a critical config/state/data file (ANY delete form).
    if ($txt -match '(?i)(\bdel\b|\brm\b|Remove-Item|\bdrop\b|удал|снес|Clear-Content)') {
      if ($txt -match '(?i)(config\.json|secrets\.json|auth\.json|settings\.json|\.git\b|web[\\/]index\.html|registry\.json|state\.json|backlog\.jsonl|restart\.flag|watchdog\.pause)') {
        [void]$reasons.Add('деструктив над критическим файлом конфигурации/состояния/данных')
      }
      # destructive on a still-referenced .ps1
      foreach ($fn in @([regex]::Matches($txt, '([\w\-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
        try { $rc = Get-FileReferenceCount -FileName $fn -BridgeRoot $BridgeRoot; if ($rc -gt 0) { [void]$reasons.Add("деструктив над используемым файлом $fn (ссылок: $rc)") } } catch {}
      }
    }
  } catch {
    return [pscustomobject]@{ safe=$true; risk='low'; reason='runjob-gate-error-failopen' }
  }
  if ($reasons.Count -gt 0) { return [pscustomobject]@{ safe=$false; risk='high'; reason=(@($reasons | Select-Object -Unique) -join '; ') } }
  return [pscustomobject]@{ safe=$true; risk='low'; reason='ok' }
}

function Get-RecallKeywords {
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return @() }
  return @([regex]::Matches([string]$TaskText, '[\p{L}\p{N}_]{3,}') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
}

function Get-KeywordScore {
  param([string]$Text = '', [object[]]$Keywords = @())
  if ([string]::IsNullOrWhiteSpace($Text) -or -not $Keywords -or $Keywords.Count -eq 0) { return 0 }
  $score = 0
  foreach ($kw in $Keywords) {
    if ($Text -imatch [regex]::Escape([string]$kw)) { $score++ }
  }
  return $score
}

function Get-DecisionsRecall {
  param([string]$TaskText = '')
  $dp = Join-Path $bridgeRoot 'decisions'
  if (-not (Test-Path $dp)) { return '' }
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  $take = if ($keywords.Count -gt 0) { 10 } else { 5 }
  $files = @(Get-ChildItem $dp -Filter '*.md' -File | Sort-Object LastWriteTime -Descending | Select-Object -First $take)
  if ($files.Count -eq 0) { return '' }
  $items = foreach ($f in $files) {
    try { $raw = Get-Content $f.FullName -Raw -Encoding UTF8 } catch { continue }
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    [pscustomobject]@{
      File  = $f
      Raw   = $raw
      Score = Get-KeywordScore -Text $raw -Keywords $keywords
    }
  }
  if (-not $items) { return '' }
  if ($keywords.Count -gt 0) {
    $items = @($items | Sort-Object @{Expression='Score';Descending=$true}, @{Expression={$_.File.LastWriteTime};Descending=$true} | Select-Object -First 5)
  } else {
    $items = @($items | Select-Object -First 5)
  }
  $blocks = foreach ($item in $items) {
    $f = $item.File
    $raw = [string]$item.Raw
    $trimmed = $raw.Trim()
    $snippet = if ($trimmed.Length -gt 400) { $trimmed.Substring(0,400) + '...' } else { $trimmed }
    "[$($f.BaseName)]`n$snippet"
  }
  if (-not $blocks) { return '' }
  return "=== НЕДАВНИЕ ЗАМЕТКИ (decisions/) ===`n" + ($blocks -join "`n---`n")
}

function Get-EvidenceRecall {
  param([string]$TaskText = '')
  $ep = Join-Path $bridgeRoot 'evidence.jsonl'
  if (-not (Test-Path $ep)) { return '' }
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  if ($keywords.Count -eq 0) { return '' }
  try { $lines = @(Get-Content -LiteralPath $ep -Encoding UTF8 -Tail 50) } catch { return '' }
  if ($lines.Count -eq 0) { return '' }
  $items = foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rec = $line | ConvertFrom-Json } catch { continue }
    $haystack = @([string]$rec.source, [string]$rec.summary, [string]$rec.task) -join "`n"
    $score = Get-KeywordScore -Text $haystack -Keywords $keywords
    if ($score -le 0) { continue }
    [pscustomobject]@{
      Score      = $score
      Source     = [string]$rec.source
      Summary    = [string]$rec.summary
      Confidence = [string]$rec.confidence
      Agent      = [string]$rec.agent
    }
  }
  $items = @($items | Sort-Object @{Expression='Score';Descending=$true} | Select-Object -First 5)
  if ($items.Count -eq 0) { return '' }
  $blocks = foreach ($item in $items) {
    "[$($item.Source)] $($item.Summary) (conf: $($item.Confidence), агент: $($item.Agent))"
  }
  return "=== РЕЛЕВАНТНЫЕ EVIDENCE ===`n" + ($blocks -join "`n")
}

function Get-RecurrenceContext {
  # 2026-05-28: detect when current task is likely a RECURRENCE of an earlier
  # complaint (e.g., user said "проблема осталась", "опять мигает"). When detected,
  # we pull recent fix-commits and inject an architectural-review block so the
  # planner explicitly considers OTHER layers instead of patching the same files
  # again. Cheap heuristic, no LLM.
  param([string]$TaskText = '')
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  $markersRegex = '(?i)(\bпроблема\s+(осталась|та\s*же|сохрани)|снова\s+(мига|тормоз|падает|висит|ломается|ломае)|опять|ещё\s+раз|не\s+помог|всё\s+ещё|все\s+ещё|так\s+же|повтор(я|и)?ется|несмотря|не\s+пофиксил|не\s+помогло|по-прежнему)'
  $hasMarkers = [regex]::IsMatch($TaskText, $markersRegex)
  if (-not $hasMarkers) { return '' }
  # Pull recent fix/repair commits to show what was tried.
  $recentFixes = @()
  try {
    $log = & git -C $bridgeRoot log --oneline -30 --since='72 hours ago' 2>$null
    if ($log) {
      $recentFixes = @(([string[]]$log) | Where-Object { $_ -match '^[0-9a-f]+\s+(fix|repair|chore.fix)\b' })
    }
  } catch {}
  $keywords = @(Get-RecallKeywords -TaskText $TaskText)
  # Score each fix-commit against task keywords; keep top 8.
  $scored = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l in $recentFixes) {
    $score = Get-KeywordScore -Text $l -Keywords $keywords
    if ($score -gt 0) {
      [void]$scored.Add([pscustomobject]@{ score = $score; line = $l })
    }
  }
  $top = @($scored | Sort-Object @{Expression='score';Descending=$true} | Select-Object -First 8)
  # Also figure out which file-areas were touched recently.
  $touchedAreas = @{}
  foreach ($entry in $top) {
    $sha = ($entry.line -split '\s+')[0]
    if (-not $sha) { continue }
    try {
      $files = @(& git -C $bridgeRoot show --name-only --format='' $sha 2>$null | Where-Object { $_ -and ([string]$_).Trim() })
    } catch { $files = @() }
    foreach ($f in $files) {
      $area = ([string]$f).Split('/\')[0]
      if (-not $area) { continue }
      if ($touchedAreas.ContainsKey($area)) { $touchedAreas[$area] = [int]$touchedAreas[$area] + 1 }
      else { $touchedAreas[$area] = 1 }
    }
  }
  $blocks = New-Object 'System.Collections.Generic.List[string]'
  [void]$blocks.Add('🚨 РЕЦИДИВ ДЕТЕКТИРОВАН: текст задачи содержит маркеры повторной жалобы ("снова", "проблема осталась", "не помогло" и т.п.).')
  if ($top.Count -gt 0) {
    [void]$blocks.Add("Релевантные fix-коммиты последних 72ч (по ключевым словам задачи):")
    foreach ($entry in $top) { [void]$blocks.Add("  $($entry.line)") }
    if ($touchedAreas.Count -gt 0) {
      $areaSummary = ($touchedAreas.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true} | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
      [void]$blocks.Add("Слои, где правили: $areaSummary")
    }
  } else {
    [void]$blocks.Add("(Релевантных fix-коммитов в последних 72ч не нашлось по ключевым словам — возможно симптом старый или формулировка другая.)")
  }
  [void]$blocks.Add('')
  [void]$blocks.Add('🧭 ПРАВИЛО ДЛЯ ЭТОЙ ИТЕРАЦИИ:')
  [void]$blocks.Add('1. НЕ начинай сразу с CONTINUE → Codex с правкой того же файла. Если в "Слои, где правили" доминирует один (например web/), вероятный корень в ДРУГОМ слое (server.ps1, lib/, config).')
  [void]$blocks.Add('2. Первым ходом проведи мини-аудит: какие файлы трогали прошлые фиксы (используй Read), какие слои НЕ трогали, и где данные текут через границу слоёв (UI ↔ HTTP ↔ lib ↔ файлы).')
  [void]$blocks.Add('3. ПОПЫТАЙСЯ воспроизвести проблему до фикса: какой именно сценарий приводит к симптому? Без воспроизведения фикс — гадание.')
  [void]$blocks.Add('4. Только после этого выдай CONTINUE с инструкцией Codex, явно указав на ДРУГОЙ слой / иной механизм.')
  return ($blocks -join "`n")
}

function Format-Transcript {
  param([string]$TaskText = '')
  # Compressed context: a rolling summary of older messages + the hot window (full).
  $labels = @{ claude='[PLANNER/Claude]'; codex='[CODER/Codex]'; user='[USER]'; system='[SYSTEM]' }
  $summarizedSeq = [int](Read-State).summarized_seq
  $lines = foreach ($m in (Get-Messages -Since $summarizedSeq)) {
    $line = "$($labels[$m.from]): $($m.text)"
    $attPaths = @(Get-MessageAttachmentPaths $m)
    if ($attPaths.Count -gt 0) { $line += " (вложения: $($attPaths -join '; '))" }
    $line
  }
  $body = ($lines -join "`n`n")
  $summary = Read-Summary
  if ([string]::IsNullOrWhiteSpace($TaskText)) {
    try { $TaskText = [string](Read-State).current_task } catch { $TaskText = '' }
  }
  $decSect = Get-DecisionsRecall -TaskText $TaskText
  $evSect = Get-EvidenceRecall -TaskText $TaskText
  $projectCtxSect = ''
  try {
    if (Get-Command Get-ProjectContextPack -ErrorAction SilentlyContinue) {
      # Richer context for EXTERNAL projects: unfamiliar code needs more facts/risks/decisions/tests
      # to avoid shallow conclusions on a big codebase. The bridge's own 'main' channel is familiar,
      # so it stays lean. (Code snippets are injected separately as $codeSect, so no -IncludeCode here.)
      $pcScope = $null; try { $pcScope = Get-ProjectContextScope } catch {}
      $isBridgeProj = (-not $pcScope) -or [bool]$pcScope.is_bridge
      $pcMax = if ($isBridgeProj) { 2600 } else { 4200 }
      $projectCtxSect = Get-ProjectContextPack -TaskText $TaskText -MaxChars $pcMax
    }
  } catch { $projectCtxSect = '' }
  $memSect = ''
  try { $memSect = Get-MemoryRecall -TaskText $TaskText } catch { $memSect = '' }
  $skillSect = ''
  try { $skillSect = Get-SkillRecall -TaskText $TaskText } catch { $skillSect = '' }
  $antiSkillSect = ''
  try { $antiSkillSect = Get-AntiSkillRecall -TaskText $TaskText } catch { $antiSkillSect = '' }
  $codeSect = ''
  try { $codeSect = Get-CodeRecall -Query $TaskText } catch { $codeSect = '' }
  # 2026-05-28: Recurrence detection — if user/task contains "снова/опять/проблема осталась"
  # markers, surface recent fix commits + force planner to consider other layers.
  $recurrenceSect = ''
  try { $recurrenceSect = Get-RecurrenceContext -TaskText $TaskText } catch { $recurrenceSect = '' }
  # 2026-05-28: LLM-classified intent breakdown for the current task. Persisted in
  # state.task_intent at task acceptance; surfaced here so the planner sees the
  # structured decomposition on every turn, not just turn 1. This is what makes
  # "обсуди и сделай" actually trigger discuss-mode + show the subtask list.
  $intentSect = ''
  try {
    if (Get-Command Format-IntentForPrompt -ErrorAction SilentlyContinue) {
      $stIntent = $null
      try { $stIntent = (Read-State).task_intent } catch {}
      if ($stIntent) { $intentSect = Format-IntentForPrompt -Intent $stIntent }
    }
  } catch { $intentSect = '' }
  # 2026-05-28 Phase 2: semantic dedup gate. Surface top-3 most-similar
  # registered features when a non-trivial task arrives, so the planner can
  # decide "extend feature X" vs "create new Y" with eyes open.
  $dedupSect = ''
  try {
    if (Get-Command Test-FeatureSimilarity -ErrorAction SilentlyContinue) {
      $simMatches = $null
      try { $simMatches = Test-FeatureSimilarity -TaskText $TaskText -Threshold 0.7 -TopK 3 } catch { $simMatches = $null }
      if ($simMatches -and @($simMatches).Count -gt 0 -and (Get-Command Format-FeatureSimilarityForPrompt -ErrorAction SilentlyContinue)) {
        $dedupSect = Format-FeatureSimilarityForPrompt -Matches $simMatches
      }
    }
  } catch { $dedupSect = '' }
  $decAppend = if ($decSect) { "`n`n$decSect" } else { '' }
  $evAppend = if ($evSect) { "`n`n$evSect" } else { '' }
  $projectCtxAppend = if ($projectCtxSect) { "`n`n$projectCtxSect" } else { '' }
  $memAppend = if ($memSect) { "`n`n$memSect" } else { '' }
  $skillAppend = if ($skillSect) { "`n`n$skillSect" } else { '' }
  $antiSkillAppend = if ($antiSkillSect) { "`n`n$antiSkillSect" } else { '' }
  $codeAppend = if ($codeSect) { "`n`n$codeSect" } else { '' }
  $recurrenceAppend = if ($recurrenceSect) { "`n`n$recurrenceSect" } else { '' }
  $intentAppend = if ($intentSect) { "`n`n$intentSect" } else { '' }
  $dedupAppend = if ($dedupSect) { "`n`n$dedupSect" } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($summary)) {
    return ("СВОДКА ПРЕДЫДУЩЕГО ДИАЛОГА (сжато, для контекста):`n" + $summary.Trim() + "`n`n=== ПОСЛЕДНИЕ СООБЩЕНИЯ (полностью) ===`n" + $body + $projectCtxAppend + $memAppend + $skillAppend + $antiSkillAppend + $codeAppend + $decAppend + $evAppend + $recurrenceAppend + $intentAppend + $dedupAppend)
  }
  return $body + $projectCtxAppend + $memAppend + $skillAppend + $antiSkillAppend + $codeAppend + $decAppend + $evAppend + $recurrenceAppend + $intentAppend + $dedupAppend
}

function Get-ActiveProjectBinding {
  $slug = [string]$Channel
  try {
    if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $slug = Normalize-ChannelSlug $slug }
  } catch {}
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      return (Get-ChannelProjectBinding -Slug $slug)
    }
  } catch {}
  return [pscustomobject]@{
    slug                = $slug
    project_root        = $(if ($slug -eq 'main') { $bridgeRoot } else { '' })
    project_type        = $(if ($slug -eq 'main') { 'bridge (self)' } else { '' })
    project_description = ''
    source              = 'driver-fallback'
    ok                  = ($slug -eq 'main')
    error               = $(if ($slug -eq 'main') { '' } else { "Канал '$slug' не привязан к проекту" })
  }
}

function Get-ActiveProjectRoot {
  $binding = Get-ActiveProjectBinding
  if ($binding -and [bool]$binding.ok -and -not [string]::IsNullOrWhiteSpace([string]$binding.project_root)) {
    return [string]$binding.project_root
  }
  return ''
}

function Get-TaskRepoRoot {
  try {
    $projectRoot = Get-ActiveProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($projectRoot) -and (Test-Path -LiteralPath (Join-Path $projectRoot '.git'))) {
      return [System.IO.Path]::GetFullPath($projectRoot)
    }
  } catch {}
  return $bridgeRoot
}

function Add-ProjectWaveMemory {
  param(
    [string]$Outcome,
    [int]$Streams = 0,
    [int]$Merged = 0,
    [int]$Quarantined = 0,
    [string[]]$BacklogIds = @(),
    [string]$Reason = ''
  )
  try {
    $slug = [string]$Channel
    if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'main') { return $null }
    if (-not (Get-Command Add-ProjectMemory -ErrorAction SilentlyContinue)) { return $null }
    $kind = if ([string]$Outcome -eq 'complete') { 'project_worklog' } else { 'project_risk' }
    $trust = 'observed'
    $txt = if ([string]$Outcome -eq 'complete') {
      "Parallel workpack wave completed: merged $Merged of $Streams streams for backlog ids " + ((@($BacklogIds) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 12) -join ', ')
    } elseif ([string]$Outcome -eq 'partial') {
      "Parallel workpack wave was partial: merged $Merged of $Streams streams; quarantined $Quarantined. Planner must repair or re-plan failed streams."
    } else {
      "Parallel workpack wave failed or produced no merged streams. Planner must diagnose before continuing."
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $txt += " Reason: $Reason" }
    $meta = [ordered]@{
      outcome = [string]$Outcome
      streams = [int]$Streams
      merged = [int]$Merged
      quarantined = [int]$Quarantined
      backlog_ids = @($BacklogIds)
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $meta.reason = $Reason }
    return (Add-ProjectMemory -Text $txt -Kind $kind -Trust $trust -Tags @('workpack-wave','parallel') -Source 'scheduler' -Importance 0.6 -Channel $slug -Meta ([pscustomobject]$meta))
  } catch { return $null }
}

function Get-ProjectFocusPromptBlock {
  $binding = Get-ActiveProjectBinding
  $slug = if ($binding -and $binding.slug) { [string]$binding.slug } else { [string]$Channel }
  $root = if ($binding -and $binding.project_root) { [string]$binding.project_root } else { '' }
  $ptype = if ($binding -and $binding.project_type) { [string]$binding.project_type } else { '' }
  $pdesc = if ($binding -and $binding.project_description) { [string]$binding.project_description } else { '' }
  $source = if ($binding -and $binding.source) { [string]$binding.source } else { '' }
  if ([string]::IsNullOrWhiteSpace($root)) { $root = '<не привязан>' }
  if ([string]::IsNullOrWhiteSpace($ptype)) { $ptype = 'не задан' }
  if ([string]::IsNullOrWhiteSpace($pdesc)) { $pdesc = 'не задано' }

  $guard = ''
  if ($slug -ne 'main') {
    $guard = @"

ФОКУС-КАНАЛА:
- Все аудиты, чтение проекта, команды, правки и git-операции относятся к этому проекту.
- НЕ использовать bridge (`$bridgeRoot`) как целевой проект и НЕ менять файлы bridge без прямой просьбы пользователя.
- Если задача явно требует менять bridge из этого канала -- сначала объясни конфликт фокуса и запроси подтверждение.
"@
  } else {
    $guard = @"

ФОКУС-КАНАЛА:
- Канал `main` предназначен для улучшений самого bridge.
"@
  }

  return @"
⚠ АКТИВНЫЙ ПРОЕКТ: $slug
Путь: $root
Тип: $ptype
Описание: $pdesc
Источник привязки: $source$guard
"@
}
