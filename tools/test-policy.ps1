# test-policy.ps1 -- unit tests for lib/policy.ps1 (the unified protection policy).
# SPEC-PINNED (operator contract, 2026-06-09): control-plane is keyed on EDIT TARGETS and
# AUTHORIZATION, not on topic words in task text. If these assertions go red, the policy
# drifted back toward the false-positive epidemic -- do not "fix the test", fix the policy.

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\policy.ps1')

$script:pass = 0
$script:fail = 0
function Assert-Policy {
  param([string]$Name, [bool]$Condition, $Detail = '')
  if ($Condition) { Write-Host "PASS: $Name"; $script:pass++ }
  else { Write-Host "FAIL: $Name $Detail"; $script:fail++ }
}

# ── 1. protected paths: ONE definition ─────────────────────────────────────────────
Assert-Policy 'driver.ps1 is control-plane' (Test-PolicyControlPlanePath -Path 'driver.ps1')
Assert-Policy 'driver module is control-plane' (Test-PolicyControlPlanePath -Path 'driver/80-loop-preflight.ps1')
Assert-Policy 'canary.ps1 is control-plane' (Test-PolicyControlPlanePath -Path 'canary.ps1')
Assert-Policy 'control/ flag dir is control-plane' (Test-PolicyControlPlanePath -Path 'control\restart.flag')
Assert-Policy 'lib backlog module is control-plane' (Test-PolicyControlPlanePath -Path 'lib\backlog-core.ps1')
Assert-Policy 'policy module itself is control-plane' (Test-PolicyControlPlanePath -Path 'lib/policy.ps1')
Assert-Policy 'a tools test file is NOT control-plane' (-not (Test-PolicyControlPlanePath -Path 'tools/test-generator-bias.ps1'))
Assert-Policy 'web ui is NOT control-plane' (-not (Test-PolicyControlPlanePath -Path 'web/index.html'))

# ── 2. edit-target keying (the 809cfdeb incident: verify-deps must not flag a test edit) ──
$testAtom = [pscustomobject]@{
  files     = @('tools/test-generator-bias.ps1')
  touch_set = @('driver.ps1','smoke.ps1','tools/test-generator-bias.ps1')   # verify deps, not edits
  text      = 'Add tools/test-generator-bias.ps1. Checks: driver.ps1 -SelfTest PASS ; smoke.ps1 PASS'
}
Assert-Policy 'test-only edit with driver.ps1 verify-dep is NOT control-plane' (-not (Test-PolicyItemTouchesControlPlane -Item $testAtom))
$cpAtom = [pscustomobject]@{ files = @('driver/81-loop-idle-claim.ps1'); text = 'patch the claim loop' }
Assert-Policy 'driver-module edit IS control-plane' (Test-PolicyItemTouchesControlPlane -Item $cpAtom)

# ── 3. text fallback (no declared paths): edit-verb + component, not bare mention ──
$freeEdit = [pscustomobject]@{ text = 'Добавить в driver/10-maintenance.ps1 защиту от двойного запуска' }
Assert-Policy 'free-text edit proposal on driver module IS control-plane' (Test-PolicyItemTouchesControlPlane -Item $freeEdit)
$discuss = [pscustomobject]@{ text = '[[DISCUSS]] обсудить, как улучшить supervisor и watchdog — анализ, без правок' }
Assert-Policy 'DISCUSS mention of supervisor is NOT control-plane' (-not (Test-PolicyItemTouchesControlPlane -Item $discuss))
$docs = [pscustomobject]@{ text = 'Написать документацию об устройстве circuit-breaker для OPERATOR_GUIDE' }
Assert-Policy 'docs mention of circuit-breaker is NOT control-plane' (-not (Test-PolicyItemTouchesControlPlane -Item $docs))
$destroy = [pscustomobject]@{ text = 'удалить watchdog чтобы не мешал' }
Assert-Policy 'free-text "удалить watchdog" IS control-plane' (Test-PolicyItemTouchesControlPlane -Item $destroy)

# ── 4. authorization model ─────────────────────────────────────────────────────────
$opTag  = [pscustomobject]@{ tags = @('operator','foundation2'); from = 'agent' }
$opFrom = [pscustomobject]@{ tags = @(); from = 'operator' }
$auto   = [pscustomobject]@{ tags = @('atom'); from = 'project-autopilot' }
Assert-Policy 'operator tag -> operator' ((Get-PolicyItemAuthorization -Item $opTag) -eq 'operator')
Assert-Policy 'from=operator -> operator' ((Get-PolicyItemAuthorization -Item $opFrom) -eq 'operator')
Assert-Policy 'autopilot atom -> autonomous' ((Get-PolicyItemAuthorization -Item $auto) -eq 'autonomous')

# ── 5. unified pre-flight verdict (danger scan stubbed to force unsafe) ────────────
function Test-AutonomousTaskSafe { param([string]$TaskText, [string]$BridgeRoot)
  return [pscustomobject]@{ safe = $false; risk = 'high'; reason = 'stub: forced unsafe' } }
$vOp = Test-PolicyAutotaskExecutionBlocked -Item $opTag -TaskText 'обойти защиту watchdog' -BridgeRoot $bridgeRoot
Assert-Policy 'unsafe + operator -> NOT blocked, exempt=operator' ((-not [bool]$vOp.blocked) -and ([string]$vOp.exempt -eq 'operator')) ($vOp | ConvertTo-Json -Compress -Depth 3)
$vDiscuss = Test-PolicyAutotaskExecutionBlocked -Item $auto -TaskText '[[DISCUSS]] анализ обхода защитного механизма' -BridgeRoot $bridgeRoot
Assert-Policy 'unsafe + DISCUSS -> NOT blocked, exempt=discuss' ((-not [bool]$vDiscuss.blocked) -and ([string]$vDiscuss.exempt -eq 'discuss')) ($vDiscuss | ConvertTo-Json -Compress -Depth 3)
$vAuto = Test-PolicyAutotaskExecutionBlocked -Item $auto -TaskText 'отключить watchdog навсегда' -BridgeRoot $bridgeRoot
Assert-Policy 'unsafe + autonomous -> BLOCKED' ([bool]$vAuto.blocked) ($vAuto | ConvertTo-Json -Compress -Depth 3)
# regression guard for the energy-saving sabotage class: autopilot-authored stays blocked
$energy = [pscustomobject]@{ tags = @('project-autopilot','atom','bridge-self'); from = 'project-autopilot' }
$vEnergy = Test-PolicyAutotaskExecutionBlocked -Item $energy -TaskText 'отключить backlog claim при простое оператора (energy saving)' -BridgeRoot $bridgeRoot
Assert-Policy 'energy-saving-class autopilot task stays BLOCKED' ([bool]$vEnergy.blocked) ($vEnergy | ConvertTo-Json -Compress -Depth 3)

Write-Host ("Policy tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
