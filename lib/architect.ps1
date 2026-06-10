# architect.ps1 -- the meta-improvement agent ("Architect").
#
# Where reflect.ps1 is leaf-level ("what to tweak in this turn") and Doctor is acute fix
# ("this task just failed -- diagnose & repair"), the Architect is STRUCTURAL: it looks
# across the post-mortem corpus, failure patterns, operator interventions, capability
# matrix, metrics, radar findings, and external-systems comparisons -- and proposes 1-3
# architectural changes (whole new mechanisms, new agents, new safeguards) into the
# backlog. It NEVER auto-executes. The user approves like any external idea.
#
# State / cadence:
#   - Schedule gate: at least 24h since last run (or via /api/architect/run manual trigger).
#   - Or: after >=10 closed user tasks since last run (delta trigger).
#   - Marker: control/architect.last (ISO ts) + control/architect.taskcount.last (int).
#   - Mode 'normal': 1-3 grounded structural ideas.
#   - Mode 'deep-think': open-ended weekly "what should bridge be in 3 months?".

function Get-ArchitectMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.last' }
function Get-ArchitectCountMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.taskcount.last' }
function Get-ArchitectExternalSystemsPath { Join-Path (Get-BridgeRoot) 'external-systems.md' }
function Get-ArchitectMatrixPath { Join-Path (Get-BridgeRoot) 'architecture-matrix.md' }
function Get-ArchitectSelfModelPath { Join-Path $env:USERPROFILE '.bridge-runtime\self-model\main.prompt.txt' }

function Get-ArchitectScope {
  # Single source of truth: see Get-EffectiveScope in lib/channels.ps1.
  if (-not (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue)) {
    throw "Get-ArchitectScope: Get-EffectiveScope is not loaded (lib/channels.ps1 must be sourced before any architect call)"
  }
  return (Get-EffectiveScope)
}

function Get-OperatorInterventions {
  # Scan recent user messages for intervention markers -- signals where the operator stepped
  # in because the bridge couldn't do something. Returns up to $Limit most recent items.
  # Intervention markers (Russian + English heuristics): commands of correction/audit, complaints.
  param([int]$Limit = 15, [int]$Since = 0)
  $patterns = @(
    'исправ', 'почему', 'разбер', 'не\s+работа', 'не\s+вижу', 'не\s+делает',
    'не\s+выполня', 'не\s+отрабат', 'не\s+появи', 'почини', 'не\s+появ',
    'добавь', 'убери', 'удали', 'переделай', 'верни', 'это\s+баг', 'это\s+ошибк',
    'сломан', 'падает', 'ленится', 'странн', 'странно', 'что\s+случилось',
    'это\s+нормально', 'почему\s+мост', 'аудит\s+(моста|себя)',
    'broken', "doesn'?t\s+work", 'why\s+does', 'fix\s+this'
  )
  $combined = '(?i)\b(?:' + ($patterns -join '|') + ')\b'
  $msgs = @(Get-Messages -Since $Since | Where-Object { $_.from -eq 'user' })
  $hits = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in $msgs) {
    $t = [string]$m.text
    # 2026-05-30: exclude AUTO-injected meta-tasks -- they are NOT operator interventions. The
    # auto-brainstorm ("[[DEEP-THINK]] Архитектурная мета-задача") embeds the 5-whys instruction
    # «спроси «почему»», which false-matched the 'почему' pattern and made the brainstorm count its
    # OWN past runs as operator interventions -- a self-pollution loop. Doctor self-repair tasks and
    # reflect/architect wake-ups are likewise system-generated, not the operator stepping in.
    if ($t -match '\[\[DEEP-THINK\]\]\s*Архитектурн\w*\s+мета-задач') { continue }
    if ($t -match 'задача\s+саморемонта|🩺\s*ДОКТОР|Архитектор просыпается|Рефлексия:') { continue }
    $found = [regex]::Match($t, $combined)
    if (-not $found.Success) { continue }
    $snippet = $t -replace '\s+', ' '
    if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0,200) + '...' }
    [void]$hits.Add([pscustomobject]@{
      seq     = [int]$m.seq
      ts      = [string]$m.ts
      marker  = $found.Value
      snippet = $snippet
    })
  }
  return @($hits.ToArray() | Sort-Object seq -Descending | Select-Object -First $Limit)
}

function Get-ThinkingJournalPath { Join-Path (Get-BridgeRoot) 'memory\thinking-journal.jsonl' }

function Add-ThinkingNote {
  # Append one durable INSIGHT from a thinking cycle -- the bridge's "train of thought" across
  # sessions. Not a backlog idea: it's what the cycle CONCLUDED (themes, what got filtered, patterns).
  # Read back into the Architect prompt so each cycle builds on the last instead of a blank slate.
  param([string]$Note, [string]$Source = 'architect')
  if ([string]::IsNullOrWhiteSpace($Note)) { return }
  try {
    $p = Get-ThinkingJournalPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rec = ([ordered]@{ ts=(Get-Date).ToString('o'); source=([string]$Source); note=([string]$Note) } | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $p -Value $rec -Encoding UTF8
  } catch {}
}

function Get-ThinkingNotes {
  # Last N journal insights (newest last) as compact dated text lines.
  param([int]$Last = 6)
  $p = Get-ThinkingJournalPath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object System.Collections.ArrayList
  try {
    $lines = @([System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8) | Where-Object { $_ } | Select-Object -Last $Last)
    foreach ($ln in $lines) {
      try { $r = $ln | ConvertFrom-Json; $d = [string]$r.ts; if ($d.Length -ge 10) { $d = $d.Substring(0,10) }; [void]$out.Add("[$d] " + [string]$r.note) } catch {}
    }
  } catch {}
  return $out.ToArray()
}

function Get-ThinkingExperience {
  # Compact recent EXPERIENCE for deep reflection: turn outcomes + notable failures + idea fates.
  $sb = New-Object System.Text.StringBuilder
  try {
    $tp = Join-Path (Get-BridgeRoot) 'turns.jsonl'
    if (Test-Path $tp) {
      $rows = New-Object System.Collections.ArrayList
      foreach ($ln in @([System.IO.File]::ReadAllLines($tp, [System.Text.Encoding]::UTF8) | Where-Object { $_ } | Select-Object -Last 80)) { try { [void]$rows.Add(($ln | ConvertFrom-Json)) } catch {} }
      $okN = @($rows | Where-Object { [string]$_.status -eq 'ok' }).Count
      $erN = @($rows | Where-Object { [string]$_.status -eq 'error' }).Count
      $toN = @($rows | Where-Object { [string]$_.status -eq 'timeout' }).Count
      [void]$sb.AppendLine("Турны (последние $($rows.Count)): ok=$okN error=$erN timeout=$toN")
    }
  } catch {}
  try {
    $bl = @(Get-Backlog)
    $failed = @($bl | Where-Object { [string]$_.status -eq 'failed' })
    $doneN  = @($bl | Where-Object { [string]$_.status -eq 'done' }).Count
    $rejN   = @($bl | Where-Object { [string]$_.status -eq 'rejected' }).Count
    [void]$sb.AppendLine("Идеи в бэклоге: done=$doneN failed=$($failed.Count) rejected=$rejN")
    if ($failed.Count -gt 0) {
      [void]$sb.AppendLine('Недавно провалившиеся задачи (до 5):')
      foreach ($f in @($failed | Select-Object -Last 5)) { $ft = ([string]$f.text -replace '\s+',' ').Trim(); if ($ft.Length -gt 90) { $ft = $ft.Substring(0,90) }; [void]$sb.AppendLine("  - $ft") }
    }
  } catch {}
  return $sb.ToString()
}

function Get-ThinkingReflectionMarkerPath { Join-Path (Get-BridgeRoot) 'control\thinking.reflection.last' }

function Should-RunThinkingReflection {
  # Cron-style: at least 20h since the last deep reflection.
  $m = Get-ThinkingReflectionMarkerPath
  if (-not (Test-Path $m)) { return $true }
  try { $last = [datetime]((Get-Content $m -Raw -Encoding UTF8).Trim()); return (((Get-Date) - $last) -ge [TimeSpan]::FromHours(20)) } catch { return $true }
}

function Invoke-ThinkingReflection {
  # DEEP reflection (internal-thinking step 3): unlike reflect/metrics (leaf stats), this reads recent
  # EXPERIENCE and distills ONE substantive INSIGHT about the bridge itself -- a recurring pattern,
  # weakness, or lesson -- then writes it to the thinking journal so it shapes the next Architect cycle.
  # Quality over quantity: one actionable conclusion, never a stat dump. FAIL-OPEN (no LLM -> no note).
  param([int]$TimeoutSec = 180)
  $exp = Get-ThinkingExperience
  if ([string]::IsNullOrWhiteSpace($exp)) { return @{ ok = $false; note = '' } }
  $prior = @(Get-ThinkingNotes -Last 8)
  $priorStr = if ($prior.Count -gt 0) { ($prior -join "`n") } else { '(журнал пуст)' }
  $prompt = @"
Ты — рефлексирующий мост Claude+Codex. Посмотри на свой НЕДАВНИЙ ОПЫТ ниже и сформулируй РОВНО ОДИН
содержательный вывод О СЕБЕ: повторяющийся паттерн, слабость или урок, который должен изменить твоё
поведение. ЭТО НЕ СТАТИСТИКА («N задач провалилось») — это инсайт ПОЧЕМУ и ЧТО менять.
Если в прошлых выводах (журнал) это уже сказано — найди НОВОЕ или углуби, не повторяйся.
Одно-два предложения. Конкретно и действенно.

НЕДАВНИЙ ОПЫТ:
$exp

ПРОШЛЫЕ ВЫВОДЫ (журнал — не повторяй):
$priorStr

Верни ТОЛЬКО текст вывода, без преамбулы и кавычек.
"@
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'deep' -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.4 } catch {}
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{ ok = $false; note = '' } }
  $insight = ($raw -replace '```','').Trim()
  if ($insight.Length -gt 400) { $insight = $insight.Substring(0,400) + '…' }
  Add-ThinkingNote -Note ("Рефлексия: " + $insight) -Source 'reflection'
  try { Add-Message -From system -Text ("🪞 Рефлексия моста: " + $insight) -Kind event | Out-Null } catch {}
  return @{ ok = $true; note = $insight }
}

function Start-ThinkingReflectionIfDue {
  # Called from the driver idle loop. Honors autonomy.enabled + 20h cadence.
  try { $auto = Get-AutonomySettings; if (-not [bool]$auto.enabled) { return } } catch {}
  if (-not (Should-RunThinkingReflection)) { return }
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-ThinkingReflectionMarkerPath), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try { Invoke-ThinkingReflection | Out-Null } catch { try { Add-Message -From system -Text ('🪞 Рефлексия: ошибка цикла: ' + $_.Exception.Message) -Kind event | Out-Null } catch {} }
}

function Format-FileAgeTag {
  # 2026-05-30: staleness suffix for a file-based context block. The Architect reads several
  # files (capability matrix, ARCHITECTURE_V2, external systems, radar) that are refreshed only
  # manually/periodically and lag 4-5 days. Tagging their age tells the Architect how much to
  # trust them vs the LIVE block below.
  param([string]$Path)
  try {
    if (Test-Path -LiteralPath $Path) {
      $ageD = ((Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime).TotalDays
      if ($ageD -ge 2) { return ("  [⚠ обновлён {0:N1}д назад — мог устареть; при расхождении верь LIVE-блоку]" -f $ageD) }
    }
  } catch {}
  return ''
}

function Get-ArchitectLiveState {
  # 2026-05-30: LIVE snapshot recomputed on EVERY brainstorm so the prompt never goes stale.
  # The file-based context blocks lag 4-5 days between refreshes; this is derived FRESH from
  # git + backlog + settings + clock at call time, so the Architect always reasons about the
  # CURRENT system (what shipped this week, the live autonomy dial, the funnel right now).
  $sb = New-Object System.Text.StringBuilder
  $now = Get-Date
  [void]$sb.AppendLine('=== LIVE-СОСТОЯНИЕ (пересчитывается КАЖДЫЙ запуск — самый свежий сигнал, ему верь в первую очередь) ===')
  [void]$sb.AppendLine('Сегодня: ' + $now.ToString('yyyy-MM-dd HH:mm') + ' (' + $now.DayOfWeek + ')')
  try {
    $au = Get-AutonomySettings
    $dis = (@($au.autonomyDisabledChannels) -join ',')
    [void]$sb.AppendLine('Автономия: enabled=' + [bool]$au.enabled + ' selfExecuteTier=' + [string]$au.selfExecuteTier + ' disabled_channels=[' + $dis + ']')
  } catch {}
  try {
    $bk = @(Get-Backlog)
    $tot = $bk.Count
    $by = @{}; foreach ($x in ($bk | Group-Object status)) { $by[$x.Name] = $x.Count }
    $drop = [int]$by['auto-dropped']
    $dr = if ($tot -gt 0) { [math]::Round(100 * $drop / $tot) } else { 0 }
    [void]$sb.AppendLine('Backlog-воронка: new=' + [int]$by['new'] + ' approved=' + [int]$by['approved'] + ' running=' + [int]$by['running'] + ' done=' + [int]$by['done'] + ' auto-dropped=' + $drop + ' rejected=' + [int]$by['rejected'] + ' (drop-rate ' + $dr + '%, всего ' + $tot + ')')
    # exclude deep-agent audit findings (orphaned_tool etc.) -- they are auto-resolved findings,
    # not real "the bridge built X" tasks, and just add noise to the recently-done signal.
    $recentDone = @($bk | Where-Object { [string]$_.status -eq 'done' -and ([string]$_.text) -notmatch '^\s*\[deep-|orphaned_tool|orphaned_finding|hardcoded_secret|auth_bypass|unsafe_dynamic' } | Select-Object -Last 6)
    if ($recentDone.Count -gt 0) {
      [void]$sb.AppendLine('Недавно завершено (мост УЖЕ это сделал — НЕ предлагай повторно):')
      foreach ($d in $recentDone) { $t = ([string]$d.text -replace '\s+', ' '); if ($t.Length -gt 90) { $t = $t.Substring(0, 90) + '…' }; [void]$sb.AppendLine('  • ' + $t) }
    }
  } catch {}
  try {
    $since = $now.AddDays(-7).ToString('yyyy-MM-dd')
    $commits = @(& git -C (Get-BridgeRoot) log --oneline --since=$since 2>$null)
    [void]$sb.AppendLine('Коммиты за 7д: ' + $commits.Count + ' — что РЕАЛЬНО менялось в коде (свежие 18; это сильнейший сигнал «что уже трогали»):')
    foreach ($c in ($commits | Select-Object -First 18)) { $cc = [string]$c; if ($cc.Length -gt 110) { $cc = $cc.Substring(0, 110) + '…' }; [void]$sb.AppendLine('  ' + $cc) }
  } catch {}
  [void]$sb.AppendLine('')
  return $sb.ToString()
}

function Get-CapabilityMatrixLive {
  # 2026-05-30: generate the capability matrix FRESH from features/registry.json on every run,
  # instead of reading a hand-maintained architecture-matrix.md that lagged 4+ days and marked
  # LIVE features (Architect agent, deep-think, operator-interventions, external-systems) as ❌
  # "отсутствует" -- self-contradicting, since the brainstorm prompt IS their output. The registry
  # is updated whenever a feature is registered, so it's the source of truth for "what exists".
  $sb = New-Object System.Text.StringBuilder
  $regPath = Join-Path (Get-BridgeRoot) 'features\registry.json'
  if (-not (Test-Path -LiteralPath $regPath)) { return '' }
  $feats = $null
  # PS 5.1 gotcha: @(ConvertFrom-Json ...) wraps the returned Object[] as ONE element (Count=1).
  # Must assign to a variable FIRST, then @() unwraps the array correctly (Count=40).
  try { $parsed = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json; $feats = @($parsed) } catch { return '' }
  if (-not $feats -or $feats.Count -eq 0) { return '' }
  [void]$sb.AppendLine('=== CAPABILITY MATRIX (генерируется из features/registry.json — ВСЕГДА актуально, НЕ файл) ===')
  [void]$sb.AppendLine('Зарегистрировано подсистем: ' + $feats.Count + '. Это РЕАЛЬНО существующие механизмы — НЕ предлагай построить то, что уже здесь есть.')
  foreach ($lg in ($feats | Group-Object layer | Sort-Object Name)) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Слой ' + $lg.Name + ' (' + $lg.Group.Count + ')')
    foreach ($f in ($lg.Group | Sort-Object { [string]$_.name })) {
      $st = switch ([string]$f.status) { 'active' { '✅' } 'partial' { '⚠' } 'planned' { '🔄' } 'deprecated' { '🚫' } default { '•' } }
      $mod = (@($f.owner_files) -join ',')
      $desc = ([string]$f.description -replace '\s+', ' ')
      if ($desc.Length -gt 140) { $desc = $desc.Substring(0, 140) + '…' }
      [void]$sb.AppendLine('- ' + $st + ' **' + [string]$f.name + '** (' + $mod + ') — ' + $desc)
    }
  }
  return $sb.ToString()
}

function Get-ArchitectContext {
  # Compact diagnostic dump for the Architect prompt. All strings, no ETS.
  param([int]$WindowDays = 7)
  $sb = New-Object System.Text.StringBuilder
  $scope = Get-ArchitectScope

  [void]$sb.AppendLine('=== EFFECTIVE SCOPE ===')
  [void]$sb.AppendLine("channel=$($scope.slug) is_bridge=$($scope.is_bridge)")
  [void]$sb.AppendLine("project_root=$($scope.project_root)")
  [void]$sb.AppendLine("backlog_path=$($scope.backlog_path)")
  [void]$sb.AppendLine('')

  # LIVE state FIRST -- recomputed every run (git/backlog/autonomy/clock) so the prompt never
  # goes stale even when the file-based blocks below lag a few days.
  try { [void]$sb.Append((Get-ArchitectLiveState)) } catch {}

  # 0) thinking journal -- past conclusions so this cycle builds on prior thought, not a blank slate
  try {
    $jnotes = @(Get-ThinkingNotes -Last 6)
    if ($jnotes.Count -gt 0) {
      [void]$sb.AppendLine('=== ЖУРНАЛ РАЗМЫШЛЕНИЙ (твои прошлые выводы — строй ПОВЕРХ, НЕ повторяй уже обдуманное) ===')
      foreach ($jn in $jnotes) { [void]$sb.AppendLine($jn) }
      [void]$sb.AppendLine('')
    }
  } catch {}

  # 1) capability matrix -- generated LIVE from features/registry.json (was a hand-maintained .md
  #    that lagged days and marked live features as ❌). Fall back to the file only if registry fails.
  $mtxLive = ''
  try { $mtxLive = Get-CapabilityMatrixLive } catch {}
  if (-not [string]::IsNullOrWhiteSpace($mtxLive)) {
    [void]$sb.AppendLine($mtxLive)
    [void]$sb.AppendLine('')
  } else {
    $matrixPath = Get-ArchitectMatrixPath
    if (Test-Path $matrixPath) {
      [void]$sb.AppendLine('=== CAPABILITY MATRIX (файл-резерв) ===' + (Format-FileAgeTag $matrixPath))
      try {
        $mtx = [System.IO.File]::ReadAllText($matrixPath, [System.Text.Encoding]::UTF8)
        if ($mtx.Length -gt 8000) { $mtx = $mtx.Substring(0, 8000) + "`n...[truncated]" }
        [void]$sb.AppendLine($mtx)
      } catch {}
      [void]$sb.AppendLine('')
    }
  }

  # 2) ARCHITECTURE_V2 (the plan / north-star architecture)
  $archPath = Join-Path (Get-BridgeRoot) 'ARCHITECTURE_V2.md'
  if (Test-Path $archPath) {
    [void]$sb.AppendLine('=== ARCHITECTURE_V2.md (план) ===' + (Format-FileAgeTag $archPath))
    try {
      $arch = [System.IO.File]::ReadAllText($archPath, [System.Text.Encoding]::UTF8)
      if ($arch.Length -gt 4000) { $arch = $arch.Substring(0, 4000) + "`n...[truncated]" }
      [void]$sb.AppendLine($arch)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 3) goals.md
  $goalsPath = Join-Path (Get-BridgeRoot) 'goals.md'
  if (Test-Path $goalsPath) {
    [void]$sb.AppendLine('=== goals.md (north-star) ===' + (Format-FileAgeTag $goalsPath))
    try {
      $gc = [System.IO.File]::ReadAllText($goalsPath, [System.Text.Encoding]::UTF8)
      if ($gc.Length -gt 2000) { $gc = $gc.Substring(0, 2000) + "`n...[truncated]" }
      [void]$sb.AppendLine($gc)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 4) failures patterns (last week, top 8)
  [void]$sb.AppendLine('=== RECURRING FAILURE CLASSES (last 7d) ===')
  try {
    $pats = @(Get-FailurePatterns -WindowHours ($WindowDays * 24) -TopN 8)
    if ($pats.Count -eq 0) { [void]$sb.AppendLine('(нет записанных классов сбоев)') }
    else { foreach ($p in $pats) { [void]$sb.AppendLine("- class=$($p.class) count=$($p.count)`n$($p.samples)") } }
  } catch { [void]$sb.AppendLine('(не удалось прочитать failures.jsonl)') }
  [void]$sb.AppendLine('')

  # 5) operator interventions (last 15)
  [void]$sb.AppendLine('=== OPERATOR INTERVENTIONS (recent 15) ===')
  [void]$sb.AppendLine('# Каждая запись = пользователь пришёл и попросил исправить/объяснить — это implicit-сигнал "мост сам не справился".')
  try {
    $ints = @(Get-OperatorInterventions -Limit 15)
    if ($ints.Count -eq 0) { [void]$sb.AppendLine('(пусто)') }
    else { foreach ($i in $ints) { [void]$sb.AppendLine("- [seq $($i.seq)] marker=«$($i.marker)»: $($i.snippet)") } }
  } catch { [void]$sb.AppendLine('(error)') }
  [void]$sb.AppendLine('')

  # 6) recent metrics snapshot
  [void]$sb.AppendLine('=== METRICS (last snapshot) ===')
  try {
    $snap = Get-LastMetricsSnapshot
    if ($snap) {
      $bPct = [Math]::Round([double]$snap.timeout_pct * 100, 1)
      $sPct = [Math]::Round([double]$snap.success_pct * 100, 1)
      [void]$sb.AppendLine("turns=$($snap.total_turns) timeout=$bPct% success=$sPct% avg_sec=$($snap.avg_sec)")
    } else { [void]$sb.AppendLine('(нет snapshot)') }
  } catch {}
  [void]$sb.AppendLine('')

  # 7) latest radar digest (top 3 items)
  $radarPath = Join-Path (Get-BridgeRoot) 'radar\digest.md'
  if (Test-Path $radarPath) {
    [void]$sb.AppendLine('=== RADAR DIGEST (latest, top of file) ===' + (Format-FileAgeTag $radarPath))
    try {
      $rd = [System.IO.File]::ReadAllText($radarPath, [System.Text.Encoding]::UTF8)
      if ($rd.Length -gt 2500) { $rd = $rd.Substring(0, 2500) + "`n...[truncated]" }
      [void]$sb.AppendLine($rd)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 8) external systems for comparison
  $extPath = Get-ArchitectExternalSystemsPath
  if (Test-Path $extPath) {
    [void]$sb.AppendLine('=== EXTERNAL AI SYSTEMS (для сравнения) ===' + (Format-FileAgeTag $extPath))
    try {
      $ext = [System.IO.File]::ReadAllText($extPath, [System.Text.Encoding]::UTF8)
      if ($ext.Length -gt 3500) { $ext = $ext.Substring(0, 3500) + "`n...[truncated]" }
      [void]$sb.AppendLine($ext)
    } catch {}
    [void]$sb.AppendLine('')
  }

  # 9) open architect-tagged ideas (avoid duplicate proposals)
  [void]$sb.AppendLine('=== УЖЕ В БЭКЛОГЕ как architect-идеи (НЕ ПРЕДЛАГАЙ ПОВТОРНО) ===')
  try {
    $open = @(Get-Backlog | Where-Object {
      $st = [string]$_.status
      $tags = @($_.tags | ForEach-Object { [string]$_ })
      ($tags -contains 'architect') -and ($st -in @('new','approved','running','inprogress'))
    })
    if ($open.Count -eq 0) { [void]$sb.AppendLine('(пусто)') }
    else { foreach ($o in $open) { [void]$sb.AppendLine('- ' + (([string]$o.text -replace '\s+',' ').Substring(0,[Math]::Min(200,([string]$o.text -replace '\s+',' ').Length)))) } }
  } catch { [void]$sb.AppendLine('(не удалось)') }
  [void]$sb.AppendLine('')

  # 10) learning loop: fate of past ideas (drop-rates, substantive rejection reasons, recent wins)
  # so the Architect calibrates -- propose more of what survives, avoid what the curator rejects.
  try {
    if (Get-Command Format-IdeaLearningGuidance -ErrorAction SilentlyContinue) {
      $guidance = Format-IdeaLearningGuidance
      if (-not [string]::IsNullOrWhiteSpace($guidance)) { [void]$sb.AppendLine($guidance); [void]$sb.AppendLine('') }
    }
  } catch {}

  # (scholar knowledge block removed 2026-06-03 slimming rank1 — scholar.ps1 oracle deleted)

  # self-model pack -- bridge structural knowledge (ARCH/CRITICAL/SAFETY/TESTS sections only;
  # FEATURES skipped here -- capability matrix above already has live feature data).
  try {
    $smPath = Get-ArchitectSelfModelPath
    if (Test-Path $smPath) {
      $smRaw = [System.IO.File]::ReadAllText($smPath, [System.Text.Encoding]::UTF8)
      # Strip FEATURES block (already in cap-matrix above) to avoid duplication.
      # Keep: ARCH, CRITICAL, MODULES, SAFETY, TESTS
      $smFiltered = $smRaw -replace '(?s)\nFEATURES active:.*?(?=\nMODULES|\nSAFETY|\nTESTS|\z)', ''
      $smFiltered = $smFiltered -replace '(?s)\nFEATURES dormant:.*?(?=\nMODULES|\nSAFETY|\nTESTS|\z)', ''
      $smFiltered = $smFiltered.Trim()
      if ($smFiltered.Length -gt 3000) { $smFiltered = $smFiltered.Substring(0, 3000) + "`n...[truncated]" }
      if (-not [string]::IsNullOrWhiteSpace($smFiltered)) {
        [void]$sb.AppendLine('=== BRIDGE SELF-MODEL (ARCH/CRITICAL/MODULES/SAFETY — features см. выше) ===')
        [void]$sb.AppendLine($smFiltered)
        [void]$sb.AppendLine('')
      }
    }
  } catch {}

  return $sb.ToString()
}

function Build-ArchitectPrompt {
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal', [int]$MaxIdeas = 3)
  $ctx = Get-ArchitectContext
  $modeIntro = if ($Mode -eq 'deep-think') {
    @"
РЕЖИМ: deep-think (ежедневно). Открытый вопрос:
**Что сильнее всего улучшит САМ МОСТ — автономность, стабильность, скорость, безопасность, саморазвитие?**
FOUNDATION #2: в первую очередь ищи ХАРДЕНИНГ/ПОКРЫТИЕ/НАДЁЖНОСТЬ существующих фич — это приоритет.
Net-new верхнеуровневый механизм/подсистему предлагай ТОЛЬКО если идея содержит поле "operator_justification";
без него — не предлагай. Рыночные/сторонние проекты НЕ предлагай. До $MaxIdeas предложений.
"@
  } else {
    @"
РЕЖИМ: normal (плановый ход). Look-across-everything:
найди 1-$MaxIdeas архитектурных пробела: ПРИОРИТЕТ — харденинг, coverage, надёжность существующих фич (Foundation #2).
"@
  }
  return @"
Ты — Архитектор моста Claude+Codex. Твоя единственная задача: **мета-уровень структурных
пробелов**, не leaf-tweaks. Reflect (leaf) уже работает рядом. Doctor (острый ремонт)
тоже. ТЫ смотришь на узоры через корпус и предлагаешь **новые механизмы / агенты /
подсистемы**, которых сейчас нет.

$modeIntro

ВАЖНЫЕ ЗАМЕЧАНИЯ:
- ФОКУС (СТРОГО): только улучшение САМОГО МОСТА — автономность, стабильность, скорость, безопасность,
  саморазвитие/самообучение. Рыночные/сторонние проекты СЕЙЧАС НЕ предлагай (оператор отключил эту тему —
  фокус только на самой системе). Каждая идея — про укрепление внутренней системы.
- FOUNDATION #2 (ОБЯЗАТЕЛЬНО): первый выбор — идеи класса «захарденить», «покрыть тестами», «починить», «укрепить» существующие фичи; они приоритетны и всегда допустимы. Предложить НОВЫЙ верхнеуровневый механизм/модуль/подсистему (которого сейчас нет) — ТОЛЬКО с полем "operator_justification"; без него такие идеи НЕ предлагай.
- Это не «видение ради видения»: каждая идея — конкретный шаг к саморазвитию/автономности, а не общие рассуждения.
- Если 3 разных post-mortem'а намекают на отсутствие капабилити X — это твой сигнал.
- Если оператор 3 раза вмешивался про одно и то же — это твой сигнал.
- Если внешняя система имеет паттерн, которого у нас нет, и оно объяснимо — это сигнал.
- НЕ предлагай мелкие фиксы (это работа reflect.ps1). НЕ предлагай уже сделанное (см. capability matrix и список выше).
- Опирайся ТОЛЬКО на данные ниже. Не выдумывай проблем "вообще".
- Каждая идея должна быть конкретной: что добавить (файл/модуль), как триггерится, какую метрику улучшит, на чём основана (post-mortem N, intervention M, и т.д.).

ДАННЫЕ:
$ctx

ВЕРНИ СТРОГО JSON-массив (без markdown), формата:
[
  {
    "text": "Полная формулировка идеи 1-2 предложения по-русски",
    "tags": ["architect", "<доп. короткие теги>"],
    "rationale": "На каких сигналах основана: <post-mortem/intervention/external/matrix-gap>",
    "value": N,
    "confidence": N,
    "effort": N,
    "operator_justification": "ТОЛЬКО для net-new механизма/подсистемы — зачем нужен именно сейчас; для харденинга/фикса/coverage — поле опускай"
  }
]

value (1-5) = ценность для моста; confidence (1-5) = уверенность что сработает;
effort (1-5) = трудозатраты (1=просто, 5=сложно).
ОБЯЗАТЕЛЬНО: каждая отдельная идея — ОТДЕЛЬНЫЙ объект массива; НЕ склеивай 2-3 идеи в один "text"
(если придумал три механизма — это ТРИ объекта). Поля value/confidence/effort обязательны (числа
1-5) у КАЖДОЙ идеи — без них идея не приоритизируется.
Если по данным ВСЁ в норме и серьёзных пробелов нет — верни пустой массив [].
"@
}

function Invoke-ArchitectCritique {
  # SELF-CRITIQUE PASS (2026-05-29): turn one-shot idea generation into think -> critique -> refine.
  # The Architect used to generate ideas in a single LLM call and dump them straight to the backlog,
  # which sprayed shallow/duplicate proposals (~186 historically auto-dropped). Here a SKEPTIC reviews
  # the drafts adversarially and returns only the survivors -- concrete, data-grounded, non-duplicate --
  # rewriting weak-but-valuable ones to be specific. Fewer, deeper ideas. FAIL-OPEN: if the critique
  # LLM is unavailable or returns garbage, we keep the original drafts (never lose the work).
  param([object[]]$DraftIdeas, [string]$Context = '', [int]$TimeoutSec = 240)
  if (-not $DraftIdeas -or @($DraftIdeas).Count -eq 0) { return @() }
  $draftJson = ''
  try { $draftJson = ($DraftIdeas | ConvertTo-Json -Depth 6) } catch { return $DraftIdeas }
  $ctxShort = [string]$Context
  if ($ctxShort.Length -gt 4000) { $ctxShort = $ctxShort.Substring(0,4000) + "`n...[обрезано]" }
  $prompt = @"
Ты — ЖЁСТКИЙ скептик-архитектор моста Claude+Codex. Тебе дали ЧЕРНОВЫЕ идеи развития (сгенерированы
одним проходом, без обдумывания). Твоя работа — отсеять слабое и углубить ценное, ПОКА идеи не попали
в бэклог. Принцип: лучше ОДНА конкретная идея, чем три расплывчатых.

Для КАЖДОЙ черновой идеи вынеси вердикт:
- "drop"   — расплывчата / «видение ради видения» / дубль уже существующего / низкая ценность / не подкреплена сигналом из данных.
- "keep"   — конкретна, опирается на данные ниже, реальный пробел. Оставь text как есть.
- "refine" — суть ценна, но формулировка слабая: ПЕРЕПИШИ text конкретнее (что добавить — файл/модуль, как триггерится, какую метрику улучшит).

Жёсткие правила:
- Нет конкретного сигнала из ДАННЫХ под идеей — "drop".
- Две идеи про одно — оставь лучшую, остальные "drop".
- Фокус: только улучшение самого моста (стабильность/автономность/скорость/безопасность/самообучение); идеи про рыночные/сторонние проекты сейчас сразу drop.
- НЕ придумывай новые идеи — только суди и уточняй то, что дано.

ЧЕРНОВЫЕ ИДЕИ (JSON):
$draftJson

ДАННЫЕ (на чём всё должно быть основано):
$ctxShort

Верни СТРОГО JSON-массив ТОЛЬКО выживших (keep+refine), без markdown. Каждый объект:
{ "text": "...", "tags": ["architect", ...], "rationale": "...", "value": N, "confidence": N, "effort": N, "verdict": "keep|refine", "critique": "1 короткая фраза: почему выжила / что уточнил" }
Если все черновые слабые — верни [].
"@
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'criticHeavy' -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.2 } catch {}
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DraftIdeas }              # fail-open
  $clean = ($raw -replace '```json','' -replace '```','').Trim()
  $mm = [regex]::Match($clean, '(?s)\[.*\]')
  if (-not $mm.Success) { return $DraftIdeas }                                # fail-open
  $survivors = @()
  try { $survivors = @($mm.Value | ConvertFrom-Json) } catch { return $DraftIdeas }
  # Enforce the verdict in CODE: the LLM sometimes returns dropped items too (annotated verdict='drop')
  # instead of omitting them -- without this filter the rejected junk would still reach the backlog.
  # Keep only keep/refine survivors that have non-empty text.
  $kept = @($survivors | Where-Object { ([string]$_.verdict).Trim().ToLower() -ne 'drop' -and -not [string]::IsNullOrWhiteSpace([string]$_.text) })
  return $kept
}

function Invoke-Architect {
  # Run one Architect reflection cycle. Returns hashtable with count + ids of created ideas.
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal', [int]$MaxIdeas = 3, [int]$TimeoutSec = 240)
  try { Add-Message -From system -Text ("🧭 Архитектор просыпается (режим: $Mode). Анализирую структурные пробелы...") -Kind event | Out-Null } catch {}
  $draftN = 0; $keptN = 0   # tracked through the cycle for the thinking-journal note at the end
  $prompt = Build-ArchitectPrompt -Mode $Mode -MaxIdeas $MaxIdeas
  # Use deep-reasoning model purpose ('deep' -> deepseek-v4-pro by default;
  # operator can override to a premium model via config if desired).
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'deep' -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.3 } catch {}
  if ([string]::IsNullOrWhiteSpace($raw)) {
    try { Add-Message -From system -Text "🧭 Архитектор: LLM не ответил (пусто). Пропускаю цикл." -Kind event | Out-Null } catch {}
    return @{ ok = $false; count = 0; ids = @() }
  }
  $clean = ($raw -replace '```json','' -replace '```','').Trim()
  $m = [regex]::Match($clean, '(?s)\[.*\]')
  $ideas = @()
  if ($m.Success) { try { $ideas = @($m.Value | ConvertFrom-Json) } catch {} }
  # SELF-CRITIQUE: adversarially filter+refine the drafts BEFORE they hit the backlog
  # (think -> critique -> refine). Cures one-shot shallow generation -> backlog spam.
  if ($ideas -and @($ideas).Count -gt 0) {
    $draftN = @($ideas).Count
    $ctxForCritique = ''
    try { $ctxForCritique = Get-ArchitectContext } catch {}
    $ideas = @(Invoke-ArchitectCritique -DraftIdeas $ideas -Context $ctxForCritique -TimeoutSec $TimeoutSec)
    $keptN = @($ideas).Count
    try { Add-Message -From system -Text ("🧐 Самокритика идей: из $draftN черновых прошли отбор $keptN (расплывчатые/дубли/слабые отсеяны ДО бэклога).") -Kind event | Out-Null } catch {}
  }
  if (-not $ideas -or $ideas.Count -eq 0) {
    try { Add-Message -From system -Text "🧭 Архитектор: структурных пробелов не вижу (или все черновики не пережили самокритику). Цикл закрыт без идей." -Kind event | Out-Null } catch {}
    return @{ ok = $true; count = 0; ids = @() }
  }
  $created = New-Object 'System.Collections.Generic.List[string]'
  foreach ($it in $ideas) {
    $text = [string]$it.text
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $tags = @('architect')
    try {
      if ($it.tags) {
        foreach ($t in @($it.tags)) {
          $ts = [string]$t
          if (-not [string]::IsNullOrWhiteSpace($ts) -and -not ($tags -contains $ts)) { $tags += $ts }
        }
      }
    } catch {}
    $rationale = [string]$it.rationale
    if (-not [string]::IsNullOrWhiteSpace($rationale)) { $text = $text + "`n_Основа:_ " + $rationale }
    $critique = [string]$it.critique
    if (-not [string]::IsNullOrWhiteSpace($critique)) { $text = $text + "`n_Самокритика (" + ([string]$it.verdict) + "):_ " + $critique }
    $score = 0.0
    try {
      $v = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.value))
      $c = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.confidence))
      $e = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.effort))
      $score = [Math]::Round($v * $c / $e, 2)
    } catch {}
    $shortText = ($it.text -replace '\s+',' ').Trim()
    if ($shortText.Length -gt 100) { $shortText = $shortText.Substring(0,100) + '…' }
    $id = Add-Idea -Text $text -From 'architect' -Tags $tags -Status 'new' -Score $score
    if ($id) {
      [void]$created.Add([string]$id)
      try { Add-Message -From system -Text ("  💡 в бэклог (score=$score): «$shortText»") -Kind event | Out-Null } catch {}
    } else {
      try { Add-Message -From system -Text ("  ♻ отсеяна воронкой (дубль/недавно отклонена): «$shortText»") -Kind event | Out-Null } catch {}
    }
  }
  if ($created.Count -gt 0) {
    try { Add-Message -From system -Text ("🧭 Архитектор: в бэклог попало " + $created.Count + " идей (тег: architect, status=new). Дальше — классификация риска + воронка/одобрение.") -Kind event | Out-Null } catch {}
  } else {
    try { Add-Message -From system -Text "🧭 Архитектор: все предложенные идеи отсеяны воронкой (дубли/уже отклонённые) — бэклог не засоряется." -Kind event | Out-Null } catch {}
  }
  # journal this cycle's conclusion so the NEXT cycle builds on it (continuity of thought, step 2)
  try {
    $jthemes = @()
    foreach ($ji in @($ideas)) { foreach ($jt in @($ji.tags)) { $jts=[string]$jt; if ($jts -and $jts -ne 'architect' -and -not ($jthemes -contains $jts)) { $jthemes += $jts } } }
    $jthemeStr = if ($jthemes.Count -gt 0) { ($jthemes -join ', ') } else { 'без явных тем' }
    Add-ThinkingNote -Note ("Цикл ${Mode}: черновых $draftN, после самокритики $keptN, в бэклог $($created.Count). Темы: $jthemeStr.") -Source 'architect'
  } catch {}
  return @{ ok = $true; count = $created.Count; ids = @($created.ToArray()) }
}

function Should-RunArchitect {
  # Cron-style gate: at least 24h since last + at least 10 closed user tasks since last
  # (delta). Either condition is enough; both can fire.
  $lastTs = $null
  $marker = Get-ArchitectMarkerPath
  if (Test-Path $marker) { try { $lastTs = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  if (-not $lastTs) { return $true }   # never ran -> due
  $age = (Get-Date) - $lastTs
  if ($age -ge [TimeSpan]::FromHours(24)) { return $true }
  # delta-trigger: 10 closed user tasks since last
  $lastCount = -1
  $cmkr = Get-ArchitectCountMarkerPath
  if (Test-Path $cmkr) { try { $lastCount = [int]((Get-Content $cmkr -Raw -Encoding UTF8).Trim()) } catch {} }
  if ($lastCount -ge 0) {
    $curCount = 0
    try { $curCount = @(Get-Backlog | Where-Object { [string]$_.status -eq 'done' }).Count } catch {}
    if (($curCount - $lastCount) -ge 10) { return $true }
  }
  return $false
}

function Save-ArchitectMarker {
  # Update last-run timestamp + the done-task baseline for delta trigger.
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-ArchitectMarkerPath), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $doneN = 0
    try { $doneN = @(Get-Backlog | Where-Object { [string]$_.status -eq 'done' }).Count } catch {}
    [System.IO.File]::WriteAllText((Get-ArchitectCountMarkerPath), [string]$doneN, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Start-ArchitectIfDue {
  # Called from driver idle loop. Honors autonomy.enabled and Should-RunArchitect.
  param([ValidateSet('normal','deep-think')] [string]$Mode = 'normal')
  try {
    $auto = Get-AutonomySettings
    if (-not [bool]$auto.enabled) { return }
  } catch {}
  if (-not (Should-RunArchitect)) { return }
  Save-ArchitectMarker   # Touch marker BEFORE running so we don't relaunch every idle tick.
  # Anti-junk WIP budget: if the backlog is already full of open ideas, skip this cycle (wait for the
  # next window) rather than piling on more structural proposals.
  if ((Get-Command Test-BacklogHasCapacity -ErrorAction SilentlyContinue) -and -not (Test-BacklogHasCapacity)) {
    try { Add-Message -From system -Text '🧭 Архитектор: бэклог полон (WIP-лимит) — пропускаю цикл, сначала разгребём очередь.' -Kind event | Out-Null } catch {}
    return
  }
  try { Invoke-Architect -Mode $Mode -MaxIdeas 3 | Out-Null } catch { try { Add-Message -From system -Text ("🧭 Архитектор: ошибка цикла: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
}

function Get-DeepThinkMarkerPath { Join-Path (Get-BridgeRoot) 'control\architect.deepthink.last' }

function Test-WithinQuietHours {
  # Alarm-clock-style gate: runs ONLY in the user's deep-sleep window. User feedback
  # 2026-05-26: heavy tasks should fire by clock, not by timer ("я бы не привязывался к
  # таймеру, а именно по будильнику включал, когда пользователь точно спит — 2-6 утра").
  param([int]$StartHour = 2, [int]$EndHour = 6, [string[]]$DaysOfWeek = @())
  $now = Get-Date
  if ($DaysOfWeek.Count -gt 0 -and -not ($DaysOfWeek -contains $now.DayOfWeek.ToString())) { return $false }
  $h = $now.Hour
  return ($h -ge $StartHour -and $h -lt $EndHour)
}

function Should-RunDeepThink {
  # DAILY proactive deep-think, TARGETED at ~01:00 (user 2026-05-29: "ежедневно в час ночи, или сразу
  # после последней задачи, если мост занят в час ночи"). The "after the last task if busy" half is
  # automatic: this gate is polled from the driver's IDLE-maintenance block, so if the bridge is mid-task
  # at 01:00 the dialog fires the moment it goes idle within the 01:00-09:00 window. A ~23h floor keeps it
  # ~daily even if the PC was off all night (then it runs by day).
  # 2026-06-11 (Plan C — stop mechanism proliferation): deep-think now respects the WIP cap like
  # architect/reflect. While the backlog has >= maxOpenIdeas open ideas, the nightly idea-generating
  # dialog stays silent so the queue drains (subtraction phase) instead of piling on more structural
  # proposals. Reversible: raise maxOpenIdeas (settings/config) to re-enable.
  if ((Get-Command Test-BacklogHasCapacity -ErrorAction SilentlyContinue) -and -not (Test-BacklogHasCapacity)) { return $false }
  $now = Get-Date
  $marker = Get-DeepThinkMarkerPath
  $last = $null
  if (Test-Path $marker) { try { $last = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  $sinceH = if ($last) { ((Get-Date) - $last).TotalHours } else { 9999 }
  $inNightWindow = ($now.Hour -ge 1 -and $now.Hour -lt 9)   # 01:00 target; 01-09 = catch-up if busy at 1am
  if ($inNightWindow -and $sinceH -ge 20) { return $true }  # daily nightly path (>=20h since last)
  if ($sinceH -ge 23) { return $true }                      # safety floor: ~daily even if PC was off at night
  return $false
}

function Start-DeepThinkDialog {
  # Inject a deep-think user task with the [[DEEP-THINK]] marker. The driver picks it up
  # and forces task_mode='discuss' so Claude+Codex bounce ideas back and forth (not a
  # single Opus monologue). Convergence cap is enforced by the existing discuss-mode max
  # turns. After STATUS: DONE the planner files 1-3 ideas via the normal pipeline.
  $ctx = Get-ArchitectContext
  # 2026-05-30: [[DEEP-THINK]] MUST be alone on its own line. The driver's deepThinkMark regex
  # (FIX 2026-05-27) is '(?m)^\s*\[\[DEEP-THINK\]\]\s*$' -- anchored to a whole line to avoid
  # prose/example false-matches. With the marker inline ("[[DEEP-THINK]] Архитектурная...") it did
  # NOT match -> discuss-mode was NOT forced -> the intent classifier mis-routed this huge meta-task
  # to FAST-LANE (critic skipped, Codex faked the whole dialog in one turn). Marker on its own line.
  $prompt = @"
[[DEEP-THINK]]
Архитектурная мета-задача (ежедневно, ночь).

ТЕМА: какой ОДИН следующий шаг сильнее всего улучшит САМ МОСТ — автономность, стабильность, скорость,
безопасность, саморазвитие/самообучение? Фокус ТОЛЬКО на улучшении самой системы изнутри.
Рыночные/сторонние проекты сейчас НЕ обсуждаем (оператор отключил эту тему — думаем только про мост).
FOUNDATION #2: ищи прежде всего ХАРДЕНИНГ/COVERAGE/НАДЁЖНОСТЬ существующих фич. Net-new механизм/подсистему
предлагай только с явным обоснованием (OPERATOR_JUSTIFICATION: ...) — без него не предлагай.

КАК ДУМАТЬ — НЕ прыгай сразу к идеям (это даёт поверхностные ответы). Сначала пройди по шагам:
1. ДИАГНОЗ: назови САМУЮ БОЛЬНУЮ точку прямо сейчас, с ДОКАЗАТЕЛЬСТВОМ из данных ниже (постмортемы, мои
   вмешательства как оператора, журнал размышлений, провалившиеся задачи). Не «что улучшить вообще», а
   «что РЕАЛЬНО мешает сейчас и чем это видно в данных».
2. КОРЕНЬ: спроси «почему» 2-3 раза вглубь, дойди до причины. Симптом ≠ болезнь.
3. ВАРИАНТЫ: предложи 2-3 РАЗНЫХ подхода к корню, а не один.
4. Только теперь — выбери сильнейший.

ПРАВИЛА ДИАЛОГА (Claude ↔ Codex — это РАЗНЫЕ модели, используйте разницу взглядов):
- Claude (планировщик) НАЧИНАЕТ: пройди шаги 1-4. Дай диагноз + 1-3 идеи, каждая с механизмом. STATUS: DISCUSS.
- Codex КРИТИКУЕТ ЖЁСТКО И КОНКРЕТНО (не из вежливости):
    • оспорь ПРЕДПОСЫЛКУ — «а точно это проблема? может корень в другом?»;
    • назови failure modes — «это сломается, когда…», с привязкой к конкретному коду / постмортему / инциденту;
    • предложи более простую ИЛИ более сильную альтернативу.
- Claude ОТВЕЧАЕТ по существу: защищает НОВЫМИ доводами ИЛИ меняет позицию, если Codex прав. Без воды и вежливости.
- Углубляйтесь каждый ход: «что мы НЕ видим? какую предпосылку не проверили? что будет через 10 таких задач?».
- Минимум 4 хода discuss, максимум 6. Если за 6 не сошлись — Claude сам выбирает сильнейший вариант.

СХОДИМОСТЬ → STATUS: DONE с блоком `## ИТОГ`. КАЖДУЮ финальную идею (1-3 шт), пережившую критику, выведи
ОТДЕЛЬНОЙ строкой строго так:
  IDEA: <что добавить (файл/модуль) · как триггерится · какую метрику улучшит · главный риск>
  Если идея — net-new верхнеуровневый механизм/подсистема (не улучшение существующего), добавь:
  OPERATOR_JUSTIFICATION: <почему именно сейчас это необходимо — без этой строки idea отклонится>
Идея без механизма и метрики — НЕ идея, не включай её. Лучше одна выстраданная идея, чем три сырых.

ЦЕЛЬ — не компромисс, а идея, выдержавшая жёсткую проверку с разных сторон. Слабую — отбросить, копать дальше.

КОНТЕКСТ (общий для обоих агентов):
$ctx
"@
  try { Add-Message -From user -Text $prompt | Out-Null } catch {}
  try { Add-Message -From system -Text "🧭💭 Deep-think dialog запущен (Claude↔Codex; discuss-mode, max 6 ходов до сходимости). Это раз в неделю в ночное окно — продолжай работу, я не помешаю." -Kind event | Out-Null } catch {}
}

function Start-DeepThinkIfDue {
  # Weekly weekend-night dialog. Alarm-clock trigger (Sat/Sun 02-06 AM local), not interval.
  try {
    $auto = Get-AutonomySettings
    if (-not [bool]$auto.enabled) { return }
  } catch {}
  if (-not (Should-RunDeepThink)) { return }
  # Save marker BEFORE injection so we don't re-fire in the same hour window.
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-DeepThinkMarkerPath), (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try { Start-DeepThinkDialog } catch { try { Add-Message -From system -Text ("🧭 Deep-think: ошибка: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
}
