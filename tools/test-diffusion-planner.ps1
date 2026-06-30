# Ch1 shadow-planner unit test: the soft (contract-aware) wave schedule must parallelize a contract
# consumer with its provider WHEN the contract is stable, and must NOT when it is unstable.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
$root='C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-autopilot.ps1')
. (Join-Path $root 'lib\diffusion-planner.ps1')
foreach($fn in 'New-ProjectAutopilotWaveSchedule','Invoke-ProjectAutopilotShadowPlanner'){ if(-not (Get-Command $fn -EA SilentlyContinue)){ throw "FAIL: $fn not loaded" } }

$fail=0
function Assert($cond,$msg){ if($cond){ Write-Host ("  PASS: "+$msg) } else { Write-Host ("  FAIL: "+$msg); $script:fail++ } }

# 9-atom selfie-like graph: 6 independent + styler(provides) + viewmodel(consumes) + navhost(hard) + apk(hard)
$atoms = @(
  [pscustomobject]@{ slug='gitignore';     chapter='Chapter 1'; files=@('.gitignore');     depends_on=@() }
  [pscustomobject]@{ slug='capture-screen';chapter='Chapter 3'; files=@('ui/Capture.kt');  depends_on=@() }
  [pscustomobject]@{ slug='style-screen';  chapter='Chapter 4'; files=@('ui/Style.kt');    depends_on=@() }
  [pscustomobject]@{ slug='apply-screen';  chapter='Chapter 5'; files=@('ui/Apply.kt');    depends_on=@() }
  [pscustomobject]@{ slug='result-screen'; chapter='Chapter 6'; files=@('ui/Result.kt');   depends_on=@() }
  [pscustomobject]@{ slug='styler';        chapter='Chapter 2'; files=@('domain/Styler.kt'); depends_on=@(); provides=@('styler-iface') }
  [pscustomobject]@{ slug='viewmodel';     chapter='Chapter 7'; files=@('SelfieViewModel.kt'); depends_on=@(); consumes=@('styler-iface') }
  [pscustomobject]@{ slug='navhost';       chapter='Chapter 7'; files=@('ui/NavHost.kt');  depends_on=@('capture-screen','style-screen','apply-screen','result-screen','viewmodel') }
  [pscustomobject]@{ slug='apk';           chapter='Chapter 8'; files=@('apk.md');         depends_on=@('navhost') }
)

# --- Scenario A: contract present but UNSTABLE -> no soft edge, viewmodel serializes ---
$contractsUnstable = @([pscustomobject]@{ id='styler-iface'; valid=$true; stable=$false })
$schedA = New-ProjectAutopilotWaveSchedule -Tasks $atoms -Contracts $contractsUnstable
Assert ($schedA.acyclic) "A: graph acyclic"
Assert (@($schedA.file_conflicts).Count -eq 0) "A: no file conflicts (distinct files)"
Assert ([int]$schedA.projected.first_wave_gain -eq 0) ("A: unstable contract -> no first-wave gain (got "+$schedA.projected.first_wave_gain+")")
Assert (@($schedA.classification.hard_dependent) -contains 'viewmodel') "A: viewmodel is hard_dependent when contract unstable"
Assert (-not (@($schedA.classification.contract_parallel) -contains 'viewmodel')) "A: viewmodel NOT contract_parallel when unstable"

# --- Scenario B: contract STABLE -> soft edge, viewmodel runs in wave 1 in the soft schedule ---
$contractsStable = @([pscustomobject]@{ id='styler-iface'; valid=$true; stable=$true })
$schedB = New-ProjectAutopilotWaveSchedule -Tasks $atoms -Contracts $contractsStable
Assert ([int]$schedB.hard.stats.first_wave_size -eq 6) ("B: hard first wave = 6 (got "+$schedB.hard.stats.first_wave_size+")")
Assert ([int]$schedB.soft.stats.first_wave_size -eq 7) ("B: soft first wave = 7 (viewmodel joins) (got "+$schedB.soft.stats.first_wave_size+")")
Assert ([int]$schedB.projected.first_wave_gain -eq 1) ("B: first-wave gain = 1 (got "+$schedB.projected.first_wave_gain+")")
Assert ([int]$schedB.projected.wave_count_reduction -ge 1) ("B: wave-count reduced by >=1 (hard="+$schedB.hard.stats.wave_count+" soft="+$schedB.soft.stats.wave_count+")")
Assert (@($schedB.classification.contract_parallel) -contains 'viewmodel') "B: viewmodel classified contract_parallel when stable"
Assert ([int]$schedB.projected.parallelism_pct_soft -gt [int]$schedB.projected.parallelism_pct_hard) ("B: soft parallelism% > hard (soft="+$schedB.projected.parallelism_pct_soft+" hard="+$schedB.projected.parallelism_pct_hard+")")
# hard deps still serialize (navhost waits for screens+viewmodel, apk waits for navhost)
Assert (@($schedB.classification.hard_dependent) -contains 'navhost' -and (@($schedB.classification.hard_dependent) -contains 'apk')) "B: navhost & apk stay hard_dependent (real prereqs)"

# --- writer ---
$tmp = Join-Path $env:TEMP ('ch1test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $summary = Invoke-ProjectAutopilotShadowPlanner -Tasks $atoms -Contracts $contractsStable -OutputDir $tmp -Channel 'test'
  Assert ($null -ne $summary) "writer: summary returned"
  $schedPath = Join-Path $tmp 'PROJECT_WAVE_SCHEDULE.json'
  Assert (Test-Path $schedPath) "writer: PROJECT_WAVE_SCHEDULE.json written"
  $reparsed = Get-Content $schedPath -Raw | ConvertFrom-Json
  Assert ([string]$reparsed.schema -eq 'project-wave-schedule/v1') "writer: schema tag present + valid JSON"
  Assert ([int]$summary.soft_first_wave -eq 7 -and [int]$summary.contract_parallel -eq 1) "writer summary: soft_first_wave=7, contract_parallel=1"
} finally { try { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue } catch {} }

$res = if($fail -eq 0){'ALL PASS'}else{"$fail FAILED"}
Write-Host ("`nRESULT: " + $res)
exit $fail