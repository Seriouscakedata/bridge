# reflect.ps1 -- idle self-reflection ("what could we improve?"). Launched detached by
# driver.ps1 at most once per autonomy.reflectEveryHours, only when the bridge is idle.
# Reads recent activity + memory + open backlog, asks the CHEAP router (deepseek-v4-flash)
# for a few concrete, safe improvement ideas, and files them into the backlog as 'new'.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$bridgeRoot = Get-BridgeRoot
function Write-ReflectLog { param([string]$Msg) try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'reflect.log') -Value ((Get-Date).ToString('s') + '  ' + $Msg) -Encoding UTF8 } catch {} }

$auto = Get-AutonomySettings
if (-not [bool]$auto.enabled) { Write-ReflectLog 'autonomy disabled; exit'; return }
$maxIdeas = if ($auto.maxIdeasPerReflect) { [int]$auto.maxIdeasPerReflect } else { 3 }
$scope = [string]$auto.scope
$scopeLine = if ($scope -eq 'projects') {
  "ОБЛАСТЬ: предлагай улучшения САМОГО МОСТА и его проектов (под рабочим корнем). Не предлагай трогать личные/системные файлы."
} else {
  "ОБЛАСТЬ: предлагай улучшения ТОЛЬКО самого моста (его код, надёжность, UX, память, автономия). НЕ предлагай менять другие проекты."
}

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

$prompt = @"
Ты — аналитик-наблюдатель ИИ-моста (пара агентов Claude+Codex, разработка на ПК пользователя Тимура).
Твоя задача: на основе ДАННЫХ ниже предложить до $maxIdeas КОНКРЕТНЫХ, выполнимых улучшений самого моста (код, процесс, надёжность, UX, память, автономия).
Требования к идеям:
- $scopeLine
- конкретные и проверяемые (не «улучшить качество», а «что и где изменить и зачем»);
- опирайся ТОЛЬКО на данные ниже (телеметрия, память, диалог); не выдумывай проблем;
- НЕ повторяй то, что уже есть в открытом бэклоге;
- безопасные: не предлагай трогать watchdog/supervisor/.git, не предлагай рискованных необратимых действий;
- если данных мало или всё хорошо — верни пустой массив [].

ТЕЛЕМЕТРИЯ ХОДОВ:
$turnsSummary

КАРТА ПАМЯТИ:
$mapTxt

ПОСЛЕДНИЙ ДИАЛОГ:
$convoTail

УЖЕ В БЭКЛОГЕ (не повторять):
$openIdeas

Верни СТРОГО JSON-массив без markdown, формата:
[{"text":"идея одной-двумя фразами по-русски","tags":["короткие","теги"]}]
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
  $id = Add-Idea -Text $text -From 'reflect' -Tags $tags -Status 'new'
  if ($id) { $added++ }
}
Write-ReflectLog "ideas added: $added"
if ($added -gt 0) {
  try { Add-Message -From system -Text "🤔 Саморефлексия: предложено идей — $added. Загляни в Бэклог (🧠 → вкладка «Бэклог»), чтобы одобрить или отклонить." -Kind event | Out-Null } catch {}
}
try { [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'reflect.last'), (Get-Date).ToString('o'), $Utf8NoBom) } catch {}
Write-ReflectLog '=== reflect done ==='
