param()
# 2026-06-29 Option-A fix verification: planner<->approval-gate contract-schema alignment.
# Proves (1) the schema instruction teaches the EXACT gate keys + traps, (2) a wrong-keyed
# contract shaped like the selfie-styler failure is rejected, (3) a contract shaped like the
# instruction passes, (4) the per-turn focus-block reminder carries precise gap feedback and
# goes silent once the contract is gate-ready. Pure ASCII (no BOM needed).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Assert-True { param([bool]$Cond,[string]$Msg) if ($Cond){ $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Msg" } }

$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'delivery-contract.ps1')
. (Join-Path $libDir 'backlog-autopilot.ps1')

# --- 1. Schema instruction content (what the planner is taught) ---
$full = Get-ProjectContractSchemaInstruction
foreach($t in @('acceptance_scenarios','parallel_policy','surfaces','spec_profile','lite','>= 12','glass-interpreter','interfaces','non_goals')){
  Assert-True ($full -match [regex]::Escape($t)) "full instruction mentions '$t'"
}
$concise = Get-ProjectContractSchemaInstruction -Concise
foreach($t in @('acceptance_scenarios','parallel_policy','spec_profile','lite')){
  Assert-True ($concise -match [regex]::Escape($t)) "concise instruction mentions '$t'"
}

# --- 2. Selfie-failure-shaped contract (invented keys) must FAIL ---
$wrong = [pscustomobject]@{
  scope        = 'Build a selfie styling app for Android with on-device filters.'
  users        = 'People who want to style selfies quickly on their phone.'
  capabilities = @('apply filter','save image')
  interfaces   = @('camera screen','gallery screen')
  invariants   = @('no network upload of photos')
  risks        = 'Model size may be large; mitigate with quantization.'
}
$sink1 = New-Object 'System.Collections.Generic.List[string]'
$rWrong = Test-ProjectAutopilotDeliveryContractReady -Contract $wrong -Issues $sink1
Assert-True (-not [bool]$rWrong.ok) 'wrong-keyed contract is rejected by the gate'
$wrongGaps = (@($rWrong.missing) -join ',') + '|' + (@($rWrong.blockers) -join ',')
Assert-True ($wrongGaps -match 'acceptance') "gate flags missing acceptance_scenarios (got: $wrongGaps)"
Assert-True ($wrongGaps -match 'parallel_policy') "gate flags missing parallel_policy (got: $wrongGaps)"

# --- 3. Contract shaped like the instruction (mirror glass-interpreter) must PASS ---
$good = [pscustomobject]@{
  goal      = 'Ship an on-device Android selfie styler that applies filters and saves images end to end.'
  scope     = 'In scope: camera capture screen, filter selection, save-to-gallery on Android.'
  non_goals = 'Out of scope: cloud upload, account system, video capture, and iOS support.'
  users     = 'Casual Android users who want to style and save selfies quickly on-device.'
  surfaces  = @(
    [pscustomobject]@{ kind='screen'; name='capture'; route='/capture' },
    [pscustomobject]@{ kind='screen'; name='gallery'; route='/gallery' }
  )
  backend = [pscustomobject]@{ providers='on-device filter engine'; models='quantized style model'; storage='MediaStore gallery'; secrets='none required for build/test' }
  acceptance_scenarios = @(
    [pscustomobject]@{ id='build-green';    given='clean checkout';   when='npm run build';      then='exit 0 and apk exists' },
    [pscustomobject]@{ id='filter-applies'; given='a captured photo'; when='user picks a filter'; then='styled preview renders' }
  )
  checks = @(
    [pscustomobject]@{ name='build'; command='npm run build'; expect='exit 0' },
    [pscustomobject]@{ name='test';  command='npm run test';  expect='all green' }
  )
  risk            = @([pscustomobject]@{ risk='model too large'; mitigation='quantize and lazy-load weights' })
  parallel_policy = [pscustomobject]@{ mode='sequential-by-default'; rationale='small project, shared UI state'; barrier='each chapter must build and test green' }
  requirements    = @('apply at least 3 filters','save styled image to gallery')
  user_journeys   = @([pscustomobject]@{ id='style-and-save'; steps=@('capture','pick filter','save') })
  ux_contract     = [pscustomobject]@{ navigation='capture -> filter -> save with clear feedback' }
  spec_profile    = 'lite'
}
$sink2 = New-Object 'System.Collections.Generic.List[string]'
$rGood = Test-ProjectAutopilotDeliveryContractReady -Contract $good -Issues $sink2
Assert-True ([bool]$rGood.ok) ("gate-compliant contract passes (score=$($rGood.score) missing=[$((@($rGood.missing)) -join ',')] blockers=[$((@($rGood.blockers)) -join ',')])")

# --- 4. Focus-block reminder feedback loop ---
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-contract-schema-test-' + [guid]::NewGuid().ToString('N'))
$bdir = Join-Path $tmp '.bridge'
New-Item -ItemType Directory -Path $bdir -Force | Out-Null
try {
  $remMissing = Get-ProjectContractSchemaReminder -ProjectRoot $tmp
  Assert-True (-not [string]::IsNullOrWhiteSpace($remMissing)) 'reminder non-empty when contract file is missing'

  $cpath = Join-Path $bdir 'project-contract.json'
  [System.IO.File]::WriteAllText($cpath, ($wrong | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  $remWrong = Get-ProjectContractSchemaReminder -ProjectRoot $tmp
  Assert-True (-not [string]::IsNullOrWhiteSpace($remWrong)) 'reminder non-empty when contract fails gate'
  Assert-True ($remWrong -match 'parallel_policy') 'reminder teaches the exact keys'

  [System.IO.File]::WriteAllText($cpath, ($good | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  $remGood = Get-ProjectContractSchemaReminder -ProjectRoot $tmp
  Assert-True ([string]::IsNullOrWhiteSpace($remGood)) ("reminder empty once contract is gate-ready (got: $remGood)")
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("PASS=$script:pass FAIL=$script:fail")
if ($script:fail -gt 0) { exit 1 } else { Write-Host 'OK' }
