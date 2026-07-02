# test-coordinator-routing.ps1 -- mock-based test for the 2026-07-02 planner-speed fixes:
#  (1) Test-DriverCoordinatorTaskText (driver/00-task-session.ps1): pure shape-check for the
#      project-autopilot coordinator task text (positive/negative cases);
#  (2) Get-PlannerModel routes a coordinator task text to the deep model EXPLICITLY, even when
#      the text contains no opusKeywords (was accidental via 'refactor' in the template);
#  (3) New-DriverClaudePlannerArgs (driver/40-agent-invoke.ps1): coordinator override yields
#      '--effort','high' and NO ultrathink; default premium keeps '--effort','xhigh' + ultrathink;
#      empty override on non-premium is byte-identical to the pre-change arg list.
# No live bridge required; exits 0 on success, 1 on any failure.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:failCount = 0

function Assert-True {
  param([bool]$Condition, [string]$Name)
  if ($Condition) { Write-Host ("PASS " + $Name) }
  else { $script:failCount++; Write-Host ("FAIL " + $Name) }
}

# ---------- 0) Parse-check the edited files ----------
$editedFiles = @(
  (Join-Path $repoRoot 'driver\00-task-session.ps1'),
  (Join-Path $repoRoot 'driver\40-agent-invoke.ps1'),
  (Join-Path $repoRoot 'driver\83-loop-agent-turn.ps1')
)
foreach ($f in $editedFiles) {
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
  Assert-True (@($err).Count -eq 0) ("parse clean: " + (Split-Path -Leaf $f))
}

# ---------- harness: stubs BEFORE dot-sourcing driver/00 ----------
# driver/00 runs `$null = Initialize-Bridge` at dot-source time -- stub it to a no-op.
function Initialize-Bridge { return $null }
# Get-PlannerModel reads Get-BridgeConfig for plannerRouting; return a config WITHOUT
# plannerRouting so the built-in default keyword list applies (mock style mirrors
# tools\test-batch-speaker-guard.ps1 stubbing of driver dependencies).
function Get-BridgeConfig { return [pscustomobject]@{} }
# Get-PlannerModel resolves $deepModel/$triageModel dynamically (set by driver.ps1 in live runs).
$deepModel = 'claude-fable-5'
$triageModel = 'sonnet'
. (Join-Path $repoRoot 'driver\00-task-session.ps1')

# ---------- 1) Test-DriverCoordinatorTaskText: positive/negative ----------
$nl = [Environment]::NewLine
# Realistic coordinator shape (mirrors lib/backlog-autopilot.ps1 template) with NO opus keywords.
$coordText = '[project-autopilot demo-chan] [[NORMAL]]' + $nl + $nl +
  "Project Autopilot coordinator for channel 'demo-chan'." + $nl + $nl +
  'Work only in C:\proj\demo-chan.' + $nl +
  'Mission: keep this project moving without the operator manually feeding backlog items.' + $nl +
  'Rules: emit atoms for the next chapter; small durable planning docs only.'
Assert-True ([bool](Test-DriverCoordinatorTaskText -TaskText $coordText)) 'shape: full coordinator text -> true'

$tagOnly = '[project-autopilot demo-chan] [[NORMAL]]' + $nl + 'Fix the build script for channel demo-chan.'
Assert-True (-not (Test-DriverCoordinatorTaskText -TaskText $tagOnly)) 'shape: autopilot tag WITHOUT coordinator phrase -> false'

$phraseOnly = "Project Autopilot coordinator for channel 'demo-chan'. But no tag anywhere."
Assert-True (-not (Test-DriverCoordinatorTaskText -TaskText $phraseOnly)) 'shape: coordinator phrase WITHOUT autopilot tag -> false'

Assert-True (-not (Test-DriverCoordinatorTaskText -TaskText '')) 'shape: empty text -> false'
Assert-True (-not (Test-DriverCoordinatorTaskText -TaskText $null)) 'shape: null text -> false'
Assert-True (-not (Test-DriverCoordinatorTaskText -TaskText 'Update tools/foo.ps1 to log the retry count.')) 'shape: plain atom text -> false'

# ---------- 2) Get-PlannerModel: coordinator -> deep model without any opus keyword ----------
# Sanity: the sample really contains no default opusKeywords (else the test proves nothing).
$kwList = @('redesign','overhaul','design','refactor')  # ASCII members of the default list
$kwHit = $false
foreach ($kw in $kwList) { if ($coordText -imatch [regex]::Escape($kw)) { $kwHit = $true } }
Assert-True (-not $kwHit) 'sample: coordinator text contains no ASCII opusKeywords'

Assert-True ((Get-PlannerModel -TaskText $coordText -Mode 'normal') -eq $deepModel) 'route: coordinator text (no keywords) -> deep model'
Assert-True ((Get-PlannerModel -TaskText 'Update tools/foo.ps1 to log the retry count.' -Mode 'normal') -eq $triageModel) 'route: plain atom text -> triage model (unchanged)'
Assert-True ((Get-PlannerModel -TaskText 'Please refactor the settings loader.' -Mode 'normal') -eq $deepModel) 'route: keyword text still -> deep model (unchanged)'

# ---------- 3) New-DriverClaudePlannerArgs: effort override + ultrathink flag ----------
. (Join-Path $repoRoot 'driver\40-agent-invoke.ps1')

$tools = @('Read','Grep','Glob','Bash')
$cwd = 'C:\proj\demo-chan'

# Coordinator override on a premium model: --effort high, NO xhigh, NO ultrathink.
$ovr = New-DriverClaudePlannerArgs -Model 'claude-fable-5' -ReasoningEffort 'high' -PlannerCwd $cwd -ExtraDirs @() -AllowedTools $tools
$ovrJoined = @($ovr.args) -join '|'
Assert-True ($ovrJoined.Contains('|--effort|high')) 'args: coordinator override -> --effort high present'
Assert-True (-not $ovrJoined.Contains('xhigh')) 'args: coordinator override -> no xhigh'
Assert-True (-not [bool]$ovr.ultrathink) 'args: coordinator override -> ultrathink flag false'

# Default premium model (empty override): --effort xhigh + ultrathink true (unchanged behavior).
$opus = New-DriverClaudePlannerArgs -Model 'claude-opus-4-8' -ReasoningEffort '' -PlannerCwd $cwd -ExtraDirs @() -AllowedTools $tools
$opusJoined = @($opus.args) -join '|'
Assert-True ($opusJoined.Contains('|--effort|xhigh')) 'args: default opus -> --effort xhigh present'
Assert-True ([bool]$opus.ultrathink) 'args: default opus -> ultrathink flag true'

# Default non-premium model: byte-identical to the pre-change arg list (no --effort at all).
$son = New-DriverClaudePlannerArgs -Model 'sonnet' -ReasoningEffort '' -PlannerCwd $cwd -ExtraDirs @('D:\docs') -AllowedTools $tools
$expected = @('-p','--output-format','stream-json','--verbose','--permission-mode','acceptEdits',
  '--add-dir',$cwd,'--add-dir','D:\docs','--allowedTools') + $tools + @('--model','sonnet')
Assert-True ((@($son.args) -join '|') -eq ($expected -join '|')) 'args: default sonnet -> byte-identical legacy arg list (no --effort)'
Assert-True (-not [bool]$son.ultrathink) 'args: default sonnet -> ultrathink flag false'

# Empty model: no --model/--effort tail even with an override (mirrors old `if ($Model)` guard).
$noModel = New-DriverClaudePlannerArgs -Model '' -ReasoningEffort 'high' -PlannerCwd $cwd -ExtraDirs @() -AllowedTools $tools
Assert-True (-not ((@($noModel.args) -join '|').Contains('--model'))) 'args: empty model -> no --model/--effort appended'

# ---------- 4) Static wiring: tested helpers are the live path ----------
$src40 = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'driver\40-agent-invoke.ps1')
Assert-True ($src40.Contains('New-DriverClaudePlannerArgs -Model $Model -ReasoningEffort $ReasoningEffort')) 'static: Invoke-Planner builds args via New-DriverClaudePlannerArgs'
Assert-True ($src40.Contains('$plannerArgsPlan.ultrathink')) 'static: Invoke-Planner takes the ultrathink decision from the helper'

$src83 = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'driver\83-loop-agent-turn.ps1')
Assert-True ($src83.Contains('Test-DriverCoordinatorTaskText -TaskText $task')) 'static: 83 computes coordinator flag from the claimed task text'
Assert-True ($src83.Contains('-ReasoningEffort $plannerReasoningEffort')) 'static: 83 passes -ReasoningEffort to Invoke-Planner'

$src00 = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'driver\00-task-session.ps1')
$iCoord = $src00.IndexOf('if (Test-DriverCoordinatorTaskText -TaskText $text) { return $deepModel }')
$iKeywordScan = $src00.IndexOf('foreach ($kw in $complexKeywords)')
Assert-True ($iCoord -ge 0 -and $iKeywordScan -gt $iCoord) 'static: coordinator branch sits BEFORE the keyword scan in Get-PlannerModel'

# ---------- result ----------
if ($script:failCount -gt 0) {
  Write-Host ("RESULT: FAIL (" + $script:failCount + " assertion(s) failed)")
  exit 1
}
Write-Host 'RESULT: ALL PASS'
exit 0
