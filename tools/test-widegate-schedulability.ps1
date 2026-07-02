param()

# ==============================================================================
# tools/test-widegate-schedulability.ps1  (2026-07-02 audit)
#   Verifies the wide-gate SCHEDULABILITY rework + wide freeze bootstrap + loud
#   truncation, END-TO-END through the REAL ingest Add-ProjectBacklogFromMarker
#   in an ISOLATED temp bridge root (mock pattern: test-diffusion-marker-e2e.ps1).
#   Cases:
#     (a) cold-start all-chapters batch with a SINGLE root + valid in-batch deps
#         (plus an ORDERED file overlap) -> gate GREEN, NOT collapsed, ingested
#         WHOLE (the old roots-count/any-overlap criteria would have collapsed it).
#     (a2) dep resolving against an ALREADY-INGESTED backlog slug -> still green.
#     (b) dangling in-batch dep OR a depends_on cycle -> collapsed as before.
#     (c) wide mode with provides/consumes metadata -> freeze locks WRITTEN
#         (Test-ProjectAutopilotHasFrozenContracts true), NO shaping applied.
#     (d) truncation: atoms beyond the cap -> loud 'project-backlog-truncated'
#         event + operator message; kept count == cap.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'lib\common.ps1') | Out-Null

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# ---- isolated temp bridge root + git-init'd project ----
$script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('widegate-sched-' + [guid]::NewGuid().ToString('N'))
$script:proj = Join-Path $script:T 'project'
New-Item -ItemType Directory -Path (Join-Path $script:proj 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path (Join-Path $script:T 'channels') 'itest') -Force | Out-Null
Push-Location $script:proj
try { git init -q 2>$null | Out-Null; git config user.email t@t 2>$null; git config user.name t 2>$null } catch {}
Pop-Location

$script:jsonl = New-Object 'System.Collections.Generic.List[object]'
$script:ideas = New-Object 'System.Collections.Generic.List[object]'
$script:msgs  = New-Object 'System.Collections.Generic.List[string]'
$script:BL = @()

# ---- overrides (defined AFTER sourcing so they win); scope the real ingest to temp ----
function Get-BridgeRoot { return $script:T }
function Get-EffectiveChannel { return 'itest' }
function Get-ChannelDir { param([string]$Slug) if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'itest' }; return (Join-Path (Join-Path $script:T 'channels') $Slug) }
function Use-BridgeLock { param([scriptblock]$Body) & $Body }
function Get-Backlog { return $script:BL }
function Get-ChannelProjectBinding { param([string]$Slug) return [pscustomobject]@{ ok=$true; slug=$Slug; project_root=$script:proj } }
function Write-BacklogJsonLine { param($Line) $script:jsonl.Add($Line) | Out-Null }
function Add-Message { param([string]$From, [string]$Text, [string]$Kind) $script:msgs.Add([string]$Text) | Out-Null }
function Add-Idea {
  param([string]$Text,[string]$From='agent',[string[]]$Tags=@(),[string]$Status='new',[double]$Score=0.0,[string]$Project='',[string]$Scope='bridge',[ValidateSet('critical','warning','info','')][string]$Severity='',[switch]$SkipCurator)
  $script:ideas.Add([pscustomobject]@{ text=$Text; project=$Project }) | Out-Null
  return ('itest-id-' + $script:ideas.Count)
}
function Get-ProjectAutopilotConfig {
  return [ordered]@{ enabled=$true; cooldownMinutes=5; maxTasksPerBatch=12; emptyCoordinatorLimit=3; diffusionMode='wide'; diffusionMinIndependentAtoms=2; diffusionMaxWaveSize=6; decomposeAheadLimit=1; skipBuildOnDocsOnly=$false; cleanFileOwnership=$false }
}

function Jsonl-Count { param([string]$Action) @($script:jsonl | Where-Object { [string]$_.action -eq $Action }).Count }
function Jsonl-First { param([string]$Action) @($script:jsonl | Where-Object { [string]$_.action -eq $Action }) | Select-Object -First 1 }
function Reset-Caps { $script:jsonl.Clear(); $script:ideas.Clear(); $script:msgs.Clear(); $script:BL = @() }
function Clear-Freezes { $p = Join-Path (Join-Path (Join-Path $script:T 'channels') 'itest') 'diffusion-contract-freezes'; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }

# ============ (a) cold-start all-chapters DAG: single root, valid deps, ordered overlap ============
# scaffold is the ONLY root (old 'independent' count = 1 < floor 2 -> old gate ALWAYS red).
# routes and app-shell BOTH touch src/nav.py but app-shell depends_on routes (ordered overlap ->
# old 'file-conflict-unresolved' red; the dispatch frontier serializes ordered overlaps, so green now).
$markerA = @'
[
  {"slug":"scaffold","title":"Scaffold","task":"Create the project scaffold with the base gradle-like build layout so all later atoms can compile.","acceptance":["scaffold builds"],"checks":["build"],"files":["src/build.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"routes","title":"Routes","task":"Create the route table module enumerating every screen route id used by navigation across the app.","acceptance":["routes compile"],"checks":["build"],"files":["src/nav.py"],"depends_on":["scaffold"],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"domain","title":"Domain","task":"Create the domain model module with the core entity types and mappers used by the screen layer.","acceptance":["domain compiles"],"checks":["build"],"files":["src/domain.py"],"depends_on":["scaffold"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"screen-a","title":"Screen A","task":"Create screen A with its state holder and preview rendering the domain entities in a simple list.","acceptance":["screen A compiles"],"checks":["build"],"files":["src/screen_a.py"],"depends_on":["domain"],"chapter":"Chapter 3","risk":"normal"},
  {"slug":"app-shell","title":"App shell","task":"Create the app shell wiring the route table into the navigation host and hosting all the screens.","acceptance":["shell compiles"],"checks":["build"],"files":["src/nav.py","src/shell.py"],"depends_on":["routes","screen-a"],"chapter":"Chapter 4","risk":"normal"}
]
'@
Write-Host '== (a) cold-start single-root all-chapters DAG =='
Reset-Caps; Clear-Freezes
$resA = Add-ProjectBacklogFromMarker -Block $markerA -Channel 'itest' -Source 'test' -MaxTasks 12
$gateA = Jsonl-First 'project-autopilot-wide-gate'
Assert-True ($null -ne $gateA -and [bool]$gateA.enabled) "wide gate GREEN on single-root DAG with ordered overlap (reasons=$(@(if($gateA){$gateA.reasons}else{@()}) -join ','))"
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-collapse-to-chapter') -eq 0) "NOT collapsed (old gate would have dropped chapters 2-4)"
# NOTE (PS 5.1): do NOT use @($script:ideas).Count on the generic List -- it throws
# 'Argument types do not match'; the List's own .Count property is safe.
Assert-True ([int]$resA.created -eq 5 -and $script:ideas.Count -eq 5) "ingested WHOLE: created=5 (got $([int]$resA.created))"
Assert-True ($null -ne $gateA -and [int]$gateA.first_wave_runnable -eq 1 -and -not [bool]$gateA.floor_met) "MinIndependentAtoms floor demoted to telemetry: first_wave_runnable=1, floor_met=false"
Assert-True ($null -ne $gateA -and [int]$gateA.file_conflicts -ge 1) "ordered file overlap reported as telemetry, not a red trigger"

# ============ (a2) dep resolves against an ALREADY-INGESTED backlog slug ============
$markerA2 = @'
[
  {"slug":"screen-b","title":"Screen B","task":"Create screen B rendering the secondary data view on top of the already-built domain module.","acceptance":["screen B compiles"],"checks":["build"],"files":["src/screen_b.py"],"depends_on":["prev-atom"],"chapter":"Chapter 5","risk":"normal"},
  {"slug":"screen-c","title":"Screen C","task":"Create screen C rendering the tertiary data view with its own state holder and preview code.","acceptance":["screen C compiles"],"checks":["build"],"files":["src/screen_c.py"],"depends_on":[],"chapter":"Chapter 5","risk":"normal"}
]
'@
Write-Host '== (a2) dep against already-ingested channel slug =='
Reset-Caps; Clear-Freezes
$script:BL = @([pscustomobject]@{ slug='prev-atom'; from='project-autopilot'; project='itest'; status='done'; tags=@('project-autopilot','atom') })
$resA2 = Add-ProjectBacklogFromMarker -Block $markerA2 -Channel 'itest' -Source 'test' -MaxTasks 12
$gateA2 = Jsonl-First 'project-autopilot-wide-gate'
Assert-True ($null -ne $gateA2 -and [bool]$gateA2.enabled) "gate GREEN when dep resolves against already-ingested backlog slug"
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-collapse-to-chapter') -eq 0 -and [int]$resA2.created -eq 2) "no collapse, both atoms ingested"

# ============ (b) genuinely broken graphs still collapse ============
$markerB1 = @'
[
  {"slug":"base","title":"Base","task":"Create the base module for the broken-graph scenario providing shared helper functions for later atoms.","acceptance":["base compiles"],"checks":["build"],"files":["src/base.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"orphan","title":"Orphan","task":"Create the orphan module that declares a dependency on an atom which was never emitted anywhere at all.","acceptance":["orphan compiles"],"checks":["build"],"files":["src/orphan.py"],"depends_on":["ghost"],"chapter":"Chapter 2","risk":"normal"}
]
'@
Write-Host '== (b1) dangling in-batch dep -> collapse =='
Reset-Caps; Clear-Freezes
$resB1 = Add-ProjectBacklogFromMarker -Block $markerB1 -Channel 'itest' -Source 'test' -MaxTasks 12
$gateB1 = Jsonl-First 'project-autopilot-wide-gate'
$colB1 = Jsonl-First 'project-autopilot-diffusion-collapse-to-chapter'
Assert-True ($null -ne $gateB1 -and -not [bool]$gateB1.enabled -and (@($gateB1.reasons) -contains 'depends-on-unresolved')) "gate RED with reason depends-on-unresolved"
Assert-True ($null -ne $colB1 -and [string]$colB1.reason -eq 'wide-gate-red' -and [int]$colB1.dropped -ge 1) "collapse fired (kept earliest chapter, dropped the broken tail)"
Assert-True ([int]$resB1.created -eq 1) "only the earliest-chapter atom ingested (got $([int]$resB1.created))"

$markerB2 = @'
[
  {"slug":"root","title":"Root","task":"Create the root module of the cycle scenario so the earliest chapter still has one valid atom to keep.","acceptance":["root compiles"],"checks":["build"],"files":["src/root.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"cyc-a","title":"Cycle A","task":"Create cycle module A which depends on cycle module B forming an unschedulable dependency loop.","acceptance":["cyc-a compiles"],"checks":["build"],"files":["src/cyc_a.py"],"depends_on":["cyc-b"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"cyc-b","title":"Cycle B","task":"Create cycle module B which depends on cycle module A forming an unschedulable dependency loop.","acceptance":["cyc-b compiles"],"checks":["build"],"files":["src/cyc_b.py"],"depends_on":["cyc-a"],"chapter":"Chapter 2","risk":"normal"}
]
'@
Write-Host '== (b2) depends_on cycle -> collapse =='
Reset-Caps; Clear-Freezes
$resB2 = Add-ProjectBacklogFromMarker -Block $markerB2 -Channel 'itest' -Source 'test' -MaxTasks 12
$gateB2 = Jsonl-First 'project-autopilot-wide-gate'
Assert-True ($null -ne $gateB2 -and -not [bool]$gateB2.enabled -and (@($gateB2.reasons) -contains 'graph-cyclic')) "gate RED with reason graph-cyclic"
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-collapse-to-chapter') -eq 1 -and [int]$resB2.created -eq 1) "cycle batch collapsed to earliest chapter"

# ============ (c) wide + provides/consumes -> freeze locks written, NO shaping ============
$markerC = @'
[
  {"slug":"provider","title":"Provider module","task":"Build the provider module that implements and exposes the user-api interface for the rest of the app to consume.","acceptance":["provider builds and exposes user-api"],"checks":["build"],"files":["src/provider.py"],"provides":["user-api"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"consumer-a","title":"Consumer A screen","task":"Build consumer A screen which consumes the user-api interface to render its data view for the user.","acceptance":["consumer A builds against user-api"],"checks":["build"],"files":["src/a.py"],"consumes":["user-api"],"depends_on":["provider"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"consumer-b","title":"Consumer B screen","task":"Build consumer B screen which consumes the user-api interface to render a second data view for the user.","acceptance":["consumer B builds against user-api"],"checks":["build"],"files":["src/b.py"],"consumes":["user-api"],"depends_on":["provider"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"independent","title":"Independent util","task":"Build an independent utility module with no cross-atom interface dependency for shared helpers.","acceptance":["util builds"],"checks":["build"],"files":["src/util.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"}
]
'@
Write-Host '== (c) wide freeze bootstrap: locks written, dispatch untouched =='
Reset-Caps; Clear-Freezes
Assert-True (-not (Test-ProjectAutopilotHasFrozenContracts -Channel 'itest')) "precondition: no frozen contracts before ingest"
$resC = Add-ProjectBacklogFromMarker -Block $markerC -Channel 'itest' -Source 'test' -MaxTasks 12
$fmC = Jsonl-First 'project-autopilot-diffusion-freeze-manifest'
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-contract-synthesis') -ge 1) "contract synthesis ran in WIDE mode"
Assert-True ($null -ne $fmC -and [string]$fmC.mode -eq 'wide') "freeze manifest written on the WIDE path"
Assert-True (Test-ProjectAutopilotHasFrozenContracts -Channel 'itest') "stable freeze lock ON DISK -> Test-ProjectAutopilotHasFrozenContracts true (strict diffusion can engage next turn)"
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-shaped') -eq 0) "NO shaping in wide (no markers, no stitch)"
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-gate') -eq 0) "heavy diffusion gate NOT run in wide"
Assert-True ([int]$resC.created -eq 4 -and $script:ideas.Count -eq 4) "atom count unchanged (4 in, 4 written; no synthetic atoms)"
$consumerIdea = @($script:ideas | Where-Object { [string]$_.text -match '\[project-autopilot consumer-a\]' }) | Select-Object -First 1
Assert-True ($null -ne $consumerIdea -and ([string]$consumerIdea.text -match 'Depends on: provider')) "consumer depends_on NOT rewritten (still points at the real provider)"

# ============ (d) truncation beyond the cap -> loud event ============
$atomsD = @(1..8 | ForEach-Object {
  '{"slug":"atom-' + $_ + '","title":"Atom ' + $_ + '","task":"Create module number ' + $_ + ' of the truncation scenario with enough body text to pass validation.","acceptance":["atom ' + $_ + ' compiles"],"checks":["build"],"files":["src/atom_' + $_ + '.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"}'
})
$markerD = '[' + ($atomsD -join ',') + ']'
Write-Host '== (d) truncation event =='
Reset-Caps; Clear-Freezes
$resD = Add-ProjectBacklogFromMarker -Block $markerD -Channel 'itest' -Source 'test' -MaxTasks 5
$truncD = Jsonl-First 'project-backlog-truncated'
Assert-True ($null -ne $truncD -and [int]$truncD.before -eq 8 -and [int]$truncD.kept -eq 5 -and [int]$truncD.dropped -eq 3) "loud 'project-backlog-truncated' event (before=8 kept=5 dropped=3)"
Assert-True ([int]$resD.created -eq 5) "kept atoms ingested (created=5)"
Assert-True (@($script:msgs | Where-Object { $_ -match 'exceeded the ingest cap' }).Count -ge 1) "operator Add-Message fired on truncation"
# negative: no event when under the cap
Reset-Caps; Clear-Freezes
$null = Add-ProjectBacklogFromMarker -Block $markerD -Channel 'itest' -Source 'test' -MaxTasks 12
Assert-True ((Jsonl-Count 'project-backlog-truncated') -eq 0) "no truncation event when the batch fits the cap"

# cleanup
try { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
