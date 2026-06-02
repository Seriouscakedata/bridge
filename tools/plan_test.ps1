$ErrorActionPreference = 'Stop'
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\plan.ps1')

# Изоляция: переопределяем пути плана на temp (живой plan.jsonl не трогаем)
$tmpDir = Join-Path $env:TEMP ('plantest_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$script:TestPlanPath = Join-Path $tmpDir 'plan.jsonl'
$script:TestArchPath = Join-Path $tmpDir 'plan.archive.jsonl'
function Get-PlanPath { $script:TestPlanPath }
function Get-PlanArchivePath { $script:TestArchPath }

$sample = @'
бла-бла текст планировщика
[[PLAN]]
EPIC e1: Подготовка данных
  TASK e1.t1: Сбор туров | данные собраны
    STEP e1.t1.s1: Скачать туры | файл скачан
    STEP e1.t1.s2: Распарсить туры | json валиден | deps: e1.t1.s1
EPIC e2: Расчёт цены
  TASK e2.t1: Калькуляция | цена посчитана
    STEP e2.t1.s1: price_calc без деления на ноль | пустой список обработан | deps: e1.t1.s2
[[/PLAN]]
хвост
'@

Write-Host '=== 1) ConvertFrom-PlanBlock ==='
$nodes = ConvertFrom-PlanBlock $sample
Write-Host ("узлов распарсено: {0}" -f @($nodes).Count)
foreach ($n in $nodes) { Write-Host ("  {0,-4} {1,-10} parent={2,-8} deps=[{3}] title='{4}' crit='{5}'" -f $n.type, $n.id, $n.parent, ((@($n.deps)) -join ','), $n.title, $n.criteria) }

Write-Host ''
Write-Host '=== 2) New-Plan ==='
$cnt = New-Plan -Task 'тест план-доски' -Nodes $nodes
Write-Host ("createdSteps = {0}" -f $cnt)
Write-Host ("файл существует: {0}" -f (Test-Path $script:TestPlanPath))

Write-Host ''
Write-Host '=== 3) Get-Plan (со статусами-роллапами) ==='
$plan = Get-Plan
Write-Host ("meta.task = {0}" -f $plan.meta.task)
foreach ($n in $plan.nodes) { Write-Host ("  {0,-4} {1,-10} status={2}" -f $n.type, $n.id, $n.status) }

Write-Host ''
Write-Host '=== 4) Get-NextPlanStep (ожидаем e1.t1.s1 — единственный без незакрытых deps) ==='
$next = Get-NextPlanStep
Write-Host ("next = {0} — {1}" -f $next.id, $next.title)

Write-Host ''
Write-Host '=== 5) Set-PlanStepStatus e1.t1.s1 done ==='
$ok = Set-PlanStepStatus -Id 'e1.t1.s1' -Status 'done' -Result 'скачано 100 туров'
Write-Host ("set result = {0}" -f $ok)

Write-Host ''
Write-Host '=== 6) Get-NextPlanStep снова (ожидаем сдвиг на e1.t1.s2) ==='
$next2 = Get-NextPlanStep
Write-Host ("next = {0} — {1}" -f $next2.id, $next2.title)

Write-Host ''
Write-Host '=== 7) Get-PlanProgress (ожидаем 1/3, 33%) ==='
$pr = Get-PlanProgress
Write-Host ("total={0} done={1} percent={2}" -f $pr.total, $pr.done, $pr.percent)

Write-Host ''
Write-Host '=== 8) Роллап epic/task после 1 done ==='
$plan2 = Get-Plan
foreach ($n in @($plan2.nodes | Where-Object { $_.type -ne 'step' })) { Write-Host ("  {0,-4} {1,-8} status={2}" -f $n.type, $n.id, $n.status) }

Write-Host ''
Write-Host '=== 9) Format-PlanForPrompt ==='
Write-Host (Format-PlanForPrompt)

Write-Host ''
Write-Host '=== 10) Get-PlanForApi -> JSON ==='
Write-Host ((Get-PlanForApi | ConvertTo-Json -Compress -Depth 10))

Remove-Item -LiteralPath $tmpDir -Recurse -Force
Write-Host ''
Write-Host 'CLEANUP OK'
