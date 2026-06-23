# reflect.ps1 -- idle self-reflection ("what could we improve?"). Launched detached by
# driver.ps1 at most once per autonomy.reflectEveryHours, only when the bridge is idle.
# Reads recent activity + memory + open backlog, asks the CHEAP router (deepseek-v4-flash)
# for a few concrete, safe improvement ideas, and files them into the backlog as 'new'.
param(
  [switch]$SelfModelSmokeSelfTest,
  [string]$SelfModelSmokeScript = $null
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\self-model.ps1')
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$bridgeRoot = Get-BridgeRoot
function Write-ReflectLog { param([string]$Msg) try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'reflect.log') -Value ((Get-Date).ToString('s') + '  ' + $Msg) -Encoding UTF8 } catch {} }

$script:ReflectSelfModelCriticalModules = @('driver','tools','core')

function Get-ReflectSelfModelSmokeSnapshot {
  param([string]$BridgeRoot)

  $pack = ''
  try {
    if (Get-Command Get-SelfModelPack -ErrorAction SilentlyContinue) {
      $pack = [string](Get-SelfModelPack -BridgeRoot $BridgeRoot)
    }
  } catch {
    $pack = ''
  }

  $lines = @()
  if (-not [string]::IsNullOrWhiteSpace($pack)) {
    $lines = @($pack -split "`r?`n")
  }
  $subsystemCount = @($lines | Where-Object { $_ -match '^\s*-\s+' }).Count
  $missingModules = @()
  foreach ($module in $script:ReflectSelfModelCriticalModules) {
    if ($pack -notmatch [regex]::Escape($module)) {
      $missingModules += $module
    }
  }

  [pscustomobject]@{
    subsystem_count = [int]$subsystemCount
    missing_modules = @($missingModules)
  }
}

function Get-ReflectSelfModelSnapshot {
  param([string]$BridgeRoot)

  $pack = ''
  $packBytes = 0
  $packHash = ''
  $hasArch = $false
  $hasCritical = $false
  $hasFeatures = $false
  $hasTests = $false
  $hasSafety = $false
  $hasModules = $false
  $hasIdeaSources = $false
  try {
    if (Get-Command Get-SelfModelPack -ErrorAction SilentlyContinue) {
      $pack = [string](Get-SelfModelPack -BridgeRoot $BridgeRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($pack)) {
      $packBytes = [System.Text.Encoding]::UTF8.GetByteCount($pack)
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        $packHash = [System.BitConverter]::ToString(
          $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($pack))
        ) -replace '-',''
      } finally {
        try { $sha.Dispose() } catch {}
      }
      $hasArch = $pack -match '(?m)^ARCH:'
      $hasCritical = $pack -match '(?m)^CRITICAL:'
      $hasFeatures = $pack -match '(?m)^FEATURES active:'
      $hasTests = $pack -match '(?m)^TESTS:'
      $hasSafety = $pack -match '(?m)^SAFETY:'
      $hasModules = $pack -match '(?m)^MODULES '
      $hasIdeaSources = $pack -match '(?m)^IDEA SOURCES:'
    }
  } catch {}

  [pscustomobject]@{
    pack_bytes = [int]$packBytes
    pack_hash = $packHash
    has_arch = [bool]$hasArch
    has_critical = [bool]$hasCritical
    has_features = [bool]$hasFeatures
    has_tests = [bool]$hasTests
    has_safety = [bool]$hasSafety
    has_modules = [bool]$hasModules
    has_idea_sources = [bool]$hasIdeaSources
    pack_text = $pack
  }
}

function Save-ReflectSelfModelFallback {
  param([string]$BridgeRoot, [string]$PackText)

  try {
    $cacheDir = Join-Path $BridgeRoot '.bridge-runtime\self-model'
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
      New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    $cachePath = Join-Path $cacheDir 'main.prompt.txt'
    [System.IO.File]::WriteAllText($cachePath, $PackText, (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    return $false
  }
}

function Invoke-ReflectSelfModelSmoke {
  param(
    [string]$BridgeRoot,
    [string]$SmokeScript = $null
  )

  if ([string]::IsNullOrWhiteSpace($SmokeScript)) {
    $SmokeScript = Join-Path $BridgeRoot 'tools\self_model_smoke.ps1'
  }

  $before = Get-ReflectSelfModelSmokeSnapshot -BridgeRoot $BridgeRoot
  $exitCode = $null
  $smokeOut = ''
  $smokeParsed = $null
  $warningPath = $null
  $passed = $false

  try {
    if (-not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) {
      $exitCode = -1
      $smokeOut = "self_model_smoke.ps1 not found: $SmokeScript"
    } else {
      $smokeOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $SmokeScript -BridgeRoot $BridgeRoot 2>&1 | Out-String).Trim()
      $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
      try { $smokeParsed = $smokeOut | ConvertFrom-Json } catch { $smokeParsed = $null }
      $passed = (($exitCode -eq 0) -and $smokeParsed -and [bool]$smokeParsed.testPassed)
    }
  } catch {
    $exitCode = -2
    $smokeOut = $_.Exception.Message
  }

  $after = Get-ReflectSelfModelSmokeSnapshot -BridgeRoot $BridgeRoot
  if (-not $passed) {
    try {
      $decisionsDir = Join-Path $BridgeRoot 'decisions'
      if (-not (Test-Path -LiteralPath $decisionsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $decisionsDir -Force | Out-Null
      }
      $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
      $warningPath = Join-Path $decisionsDir "reflect-smoke-$ts.json"
      [pscustomobject]@{
        ts = (Get-Date).ToString('o')
        type = 'reflect-selfmodel-smoke-warning'
        smoke_exit_code = $exitCode
        subsystem_count_before = $before.subsystem_count
        subsystem_count_after = $after.subsystem_count
        missing_modules = @($after.missing_modules)
        smoke_output = (($smokeOut -replace '\s+',' ').Trim())
      } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $warningPath -Encoding UTF8
    } catch {
      Write-ReflectLog ("self-model smoke warning write failed: " + $_.Exception.Message)
    }
  }

  [pscustomobject]@{
    passed = [bool]$passed
    exit_code = $exitCode
    warning_path = $warningPath
    subsystem_count_before = $before.subsystem_count
    subsystem_count_after = $after.subsystem_count
    missing_modules = @($after.missing_modules)
    output = $smokeOut
  }
}

if ($SelfModelSmokeSelfTest) {
  Invoke-ReflectSelfModelSmoke -BridgeRoot $bridgeRoot -SmokeScript $SelfModelSmokeScript | ConvertTo-Json -Depth 5 -Compress
  return
}

$auto = Get-AutonomySettings
if (-not [bool]$auto.enabled) { Write-ReflectLog 'autonomy disabled; exit'; return }
# Anti-junk WIP budget: if the backlog is already full of open ideas, skip generating more —
# drain the queue first. Reflect is a proactive generator, so it yields to the cap.
if (Get-Command Test-BacklogHasCapacity -ErrorAction SilentlyContinue) {
  if (-not (Test-BacklogHasCapacity)) { Write-ReflectLog 'backlog at WIP cap; skip generation'; return }
}
$maxIdeas = if ($auto.maxIdeasPerReflect) { [int]$auto.maxIdeasPerReflect } else { 3 }
$scope = [string]$auto.scope
$scopeLine = if ($scope -eq 'projects') {
  "ОБЛАСТЬ: предлагай улучшения САМОГО МОСТА и его проектов (под рабочим корнем). Не предлагай трогать личные/системные файлы."
} else {
  "ОБЛАСТЬ: предлагай улучшения ТОЛЬКО самого моста (его код, надёжность, UX, память, автономия). НЕ предлагай менять другие проекты."
}

$selfModelBefore = Get-ReflectSelfModelSnapshot -BridgeRoot $bridgeRoot
Write-ReflectLog '=== reflect start ==='

# --- gather grounded context ---
$mapTxt = ''
$mp = Get-MemoryMapPath
if (Test-Path $mp) { try { $mapTxt = Get-Content $mp -Raw -Encoding UTF8 } catch {} }
if ($mapTxt.Length -gt 4000) { $mapTxt = $mapTxt.Substring(0,4000) }

# turn telemetry (durations, timeouts, statuses)
$turnsSummary = 'нет данных'
$tp = Join-Path $bridgeRoot 'turns.jsonl'
if (Test-Path $tp) {
  try {
    $rows = @(Get-Content $tp -Encoding UTF8 -Tail 80 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_ })
    if ($rows.Count -gt 0) {
      $byStatus = $rows | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }
      $timeouts = @($rows | Where-Object { $_.status -eq 'timeout' }).Count
      $avg = [Math]::Round(($rows | Measure-Object sec -Average).Average,1)
      $turnsSummary = "ходов: $($rows.Count); по статусам: $($byStatus -join ', '); таймаутов: $timeouts; средняя длит.: ${avg}с"
    }
  } catch {}
}

# recent conversation tail (compact)
$convoTail = ''
try {
  $msgs = @(Get-Messages -Since 0 | Select-Object -Last 24)
  $convoTail = ($msgs | ForEach-Object { "[$($_.from)] " + (($_.text -replace '\s+',' ').Trim()) } | ForEach-Object { if ($_.Length -gt 220) { $_.Substring(0,220)+'...' } else { $_ } }) -join "`n"
} catch {}
if ($convoTail.Length -gt 4000) { $convoTail = $convoTail.Substring($convoTail.Length-4000) }

# open backlog (avoid duplicate suggestions)
$openIdeas = ''
try {
  $open = @(Get-Backlog | Where-Object { @('new','approved','running') -contains [string]$_.status })
  $openIdeas = ($open | ForEach-Object { "- " + (($_.text -replace '\s+',' ').Trim()) }) -join "`n"
} catch {}
if ([string]::IsNullOrWhiteSpace($openIdeas)) { $openIdeas = '(пусто)' }

# goals
$goalsSection = '(не задан)'
$goalsPath = Join-Path $bridgeRoot 'goals.md'
if (Test-Path -LiteralPath $goalsPath) {
  try {
    $gc = Get-Content -LiteralPath $goalsPath -Raw -Encoding UTF8
    if ($gc.Length -gt 2000) { $gc = $gc.Substring(0,2000) }
    if (-not [string]::IsNullOrWhiteSpace($gc)) { $goalsSection = $gc }
  } catch {}
}

# learning loop: fate of past ideas (calibrate against what survives / gets rejected by the curator)
$learningSection = '(нет данных об исходах прошлых идей)'
try {
  if (Get-Command Format-IdeaLearningGuidance -ErrorAction SilentlyContinue) {
    $lg = Format-IdeaLearningGuidance
    if (-not [string]::IsNullOrWhiteSpace($lg)) { $learningSection = $lg }
  }
} catch {}

$ideaSourceSection = 'Источники идей: высокий drop-rate не выявлен или ещё мало terminal-данных.'
try {
  if (Get-Command Get-SelfModelIdeaSourceGuidance -ErrorAction SilentlyContinue) {
    $sg = Get-SelfModelIdeaSourceGuidance -BridgeRoot $bridgeRoot -MaxSources 3
    if (-not [string]::IsNullOrWhiteSpace($sg)) { $ideaSourceSection = $sg }
  }
} catch {}

$prompt = @"
Ты — аналитик-наблюдатель ИИ-моста (пара агентов Claude+Codex, разработка на ПК пользователя Тимура).
Твоя задача: на основе ДАННЫХ ниже предложить до $maxIdeas КОНКРЕТНЫХ, выполнимых улучшений самого моста (код, процесс, надёжность, UX, память, автономия).

ЦЕЛИ МОСТА (north-star):
$goalsSection

Требования к идеям:
- $scopeLine
- каждая идея должна двигать мост к хотя бы одной из целей выше;
- конкретные и проверяемые (не «улучшить качество», а «что и где изменить и зачем»);
- опирайся ТОЛЬКО на данные ниже (телеметрия, память, диалог); не выдумывай проблем;
- НЕ повторяй то, что уже есть в открытом бэклоге;
- избегай источников/тем с высоким drop-rate; если предлагаешь оттуда, нужна сильная evidence;
- безопасные: не предлагай трогать watchdog/supervisor/.git, не предлагай рискованных необратимых действий;
- FOUNDATION #2 GENERATOR-BIAS: предпочитай идеи класса ХАРДЕНИНГ / ФИКС / ПОКРЫТИЕ / НАДЁЖНОСТЬ (улучшение существующего поведения) перед идеями класса NET-NEW (новый механизм/подсистема). Для идей NET-NEW-класса обязательно добавь поле operator_justification с обоснованием необходимости — без него идею не предлагай. Для обычных bug-fix / reliability / harden / coverage идей funnel открыт: предлагай их freely.
- если данных мало или всё хорошо — верни пустой массив [].

ТЕЛЕМЕТРИЯ ХОДОВ:
$turnsSummary

КАРТА ПАМЯТИ:
$mapTxt

ПОСЛЕДНИЙ ДИАЛОГ:
$convoTail

УЖЕ В БЭКЛОГЕ (не повторять):
$openIdeas

РИСК ПО ИСТОЧНИКАМ ИДЕЙ:
$ideaSourceSection

$learningSection

Верни СТРОГО JSON-массив без markdown, формата:
[{"text":"идея одной-двумя фразами по-русски","tags":["короткие","теги"],"category":"harden|fix|coverage|reliability|net-new","value":N,"confidence":N,"effort":N,"operator_justification":"(обязательно для category=net-new, иначе пусто)"}]

Где value (1–5) — польза для моста/пользователя, confidence (1–5) — уверенность, что идея сработает, effort (1–5) — трудозатраты (1=легко, 5=сложно).
Чем выше value*confidence/effort, тем ценнее идея. Идеи класса harden/fix/coverage/reliability НЕ штрафуются — scoring применяется одинаково; category влияет только на наличие operator_justification.
"@

$raw = Invoke-LLM -Purpose 'reflect' -Prompt $prompt -TimeoutSec 120 -Temperature 0.4
if ([string]::IsNullOrWhiteSpace($raw)) { Write-ReflectLog 'empty LLM reply; exit'; try { [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'reflect.last'), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}; return }

$clean = ($raw -replace '```json','' -replace '```','').Trim()
$m = [regex]::Match($clean, '(?s)\[.*\]')
$ideas = @()
if ($m.Success) { try { $ideas = @($m.Value | ConvertFrom-Json) } catch { Write-ReflectLog "parse fail: $($_.Exception.Message)" } }

$added = 0
foreach ($it in $ideas) {
  $text = [string]$it.text
  if ([string]::IsNullOrWhiteSpace($text)) { continue }
  $tags = @('reflect'); try { if ($it.tags) { $tags = @('reflect') + @($it.tags | ForEach-Object { [string]$_ }) } } catch {}
  $score = 0.0
  try {
    $v = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.value))
    $c = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.confidence))
    $e = [Math]::Max(1.0,[Math]::Min(5.0,[double]$it.effort))
    $score = [Math]::Round($v * $c / $e, 2)
  } catch {}
  # 2026-05-28: tightened dedup. Real incident: reflect added "Добавить
  # epoch-guard в pollBacklog…" while an approved item already said
  # "pollBacklog не имеет epoch-guard, …" — word overlap was 50% (below
  # 60% threshold) so dedup missed. Now we try THREE strategies in order:
  #   (1) Test-IdeaShouldKeep — embedding cosine similarity via Get-Embedding;
  #       most accurate, catches paraphrases. Requires working gemini key.
  #   (2) prefix40 byte match (was already there) — catches near-identical openings.
  #   (3) word overlap — threshold lowered 0.6 -> 0.5 AND checks both
  #       min(|w1|,|w2|) and max(|w1|,|w2|) (was only min before).
  $isDup = $false
  try {
    if (Get-Command Test-IdeaShouldKeep -ErrorAction SilentlyContinue) {
      $keep = Test-IdeaShouldKeep -Text $text
      if ($keep -and [string]$keep.action -eq 'dedup') {
        $isDup = $true
      }
    }
  } catch {}
  if (-not $isDup) {
    try {
      $norm = ($text -replace '\s+',' ').Trim().ToLowerInvariant()
      $prefix40 = if ($norm.Length -gt 40) { $norm.Substring(0,40) } else { $norm }
      $existing = @(Get-Backlog | Where-Object { [string]$_.status -notin @('done','rejected','auto-dropped','auto-resolved') })
      foreach ($ex in $existing) {
        $exNorm = (([string]$ex.text) -replace '\s+',' ').Trim().ToLowerInvariant()
        if ($exNorm.StartsWith($prefix40)) { $isDup = $true; break }
        $words1 = @($norm -split '\W+' | Where-Object { $_.Length -gt 3 })
        $words2 = @($exNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
        if ($words1.Count -gt 3 -and $words2.Count -gt 3) {
          $shared = ($words1 | Where-Object { $words2 -contains $_ }).Count
          $minWords = [Math]::Min($words1.Count, $words2.Count)
          $maxWords = [Math]::Max($words1.Count, $words2.Count)
          # 50% of either min OR max counts as a duplicate signal — was 60%/min only,
          # too lenient when both texts have ~8 words and share 4 stable keywords.
          if (($shared / $minWords) -gt 0.5 -or ($shared / $maxWords) -gt 0.5) {
            $isDup = $true; break
          }
        }
      }
    } catch {}
  }
  if ($isDup) { continue }
  $id = Add-Idea -Text $text -From 'reflect' -Tags $tags -Status 'new' -Score $score
  if ($id) { $added++ }
}
Write-ReflectLog "ideas added: $added"
# self-model smoke after reflection guards against subsystem count regression.
try {
  $smokeResult = Invoke-ReflectSelfModelSmoke -BridgeRoot $bridgeRoot -SmokeScript $SelfModelSmokeScript
  if (-not [bool]$smokeResult.passed) {
    Write-ReflectLog ("self-model smoke FAIL after reflect: exit=" + $smokeResult.exit_code + " warning=" + $smokeResult.warning_path)

    $selfModelAfter = Get-ReflectSelfModelSnapshot -BridgeRoot $bridgeRoot
    $hashDiverged = ($selfModelBefore.pack_hash -ne '' -and $selfModelBefore.pack_hash -ne $selfModelAfter.pack_hash)
    $sectionLost = @('has_arch','has_critical','has_features','has_tests','has_safety','has_modules','has_idea_sources') |
      Where-Object { ([bool]$selfModelBefore.$_) -and (-not [bool]$selfModelAfter.$_) }
    $sizeDiff = [Math]::Abs($selfModelAfter.pack_bytes - $selfModelBefore.pack_bytes)
    $diverged = $hashDiverged -or $sectionLost.Count -gt 0 -or ($sizeDiff -gt 512 -and $selfModelBefore.pack_bytes -gt 0)

    $rollbackPerformed = $false
    if ($diverged -and -not [string]::IsNullOrWhiteSpace($selfModelBefore.pack_text)) {
      $rollbackPerformed = Save-ReflectSelfModelFallback -BridgeRoot $bridgeRoot -PackText $selfModelBefore.pack_text
      Write-ReflectLog ("self-model rollback: " + $(if ($rollbackPerformed) { 'OK' } else { 'FAILED' }))
    }

    try {
      $decisionsDir = Join-Path $bridgeRoot 'decisions'
      if (-not (Test-Path -LiteralPath $decisionsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $decisionsDir -Force | Out-Null
      }
      $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
      $logPath = Join-Path $decisionsDir "reflect-selfmodel-integrity-$ts.json"
      [pscustomobject]@{
        ts = (Get-Date).ToString('o')
        type = 'reflect-selfmodel-integrity-check'
        smoke_exit_code = $smokeResult.exit_code
        diverged = [bool]$diverged
        hash_diverged = [bool]$hashDiverged
        sections_lost = @($sectionLost)
        size_diff_bytes = [int]$sizeDiff
        before_pack_bytes = [int]$selfModelBefore.pack_bytes
        after_pack_bytes = [int]$selfModelAfter.pack_bytes
        before_pack_hash = [string]$selfModelBefore.pack_hash
        after_pack_hash = [string]$selfModelAfter.pack_hash
        rollback_performed = [bool]$rollbackPerformed
        smoke_warning_path = [string]$smokeResult.warning_path
      } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $logPath -Encoding UTF8
    } catch {
      Write-ReflectLog ("integrity log write failed: " + $_.Exception.Message)
    }

    $msgText = if ($rollbackPerformed) {
      "⚠ Рефлексия: self-model smoke не прошёл (деградация обнаружена) — выполнен откат к pre-reflect версии."
    } else {
      "⚠ Рефлексия: self-model smoke не прошёл после рефлексии — возможна деградация самомодели."
    }
    try { Add-Message -From system -Text $msgText -Kind event | Out-Null } catch {}
  } else {
    Write-ReflectLog 'self-model smoke OK after reflect'
  }
} catch { Write-ReflectLog ("self-model smoke error: " + $_.Exception.Message) }
if ($added -gt 0) {
  try { Add-Message -From system -Text "🤔 Саморефлексия: предложено идей — $added. Загляни в Бэклог (🧠 → вкладка «Бэклог»), чтобы одобрить или отклонить." -Kind event | Out-Null } catch {}
}
try { [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'reflect.last'), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-ReflectLog '=== reflect done ==='
