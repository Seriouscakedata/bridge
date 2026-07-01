# Diffusion cold-start self-heal + pause-guard unit test (2026-07-01).
# Verifies: (1) Test-ProjectAutopilotColdStart is channel-scoped and chapter-aware; (2) strict 'diffusion'
# requested at cold start (no chapter decomposed) is healed to all-chapters 'wide' in the coordinator prompt;
# (3) once a chapter exists it stays strict diffusion; (4) 'wide'/'off' requests are untouched.
# Isolated: mocks Get-Backlog; no live-driver state writes -> safe to run against a running bridge.
$ErrorActionPreference = 'Stop'
$lib = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog-autopilot.ps1'
. $lib

$script:MOCK_BACKLOG = @()
function Get-Backlog { return $script:MOCK_BACKLOG }
if (-not (Get-Command Get-BacklogPackObjectValue -EA SilentlyContinue)) {
  function Get-BacklogPackObjectValue { param($Obj, $Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $Default }
}
if (-not (Get-Command Write-BacklogJsonLine -EA SilentlyContinue)) { function Write-BacklogJsonLine { param($x) } }
if (-not (Get-Command Add-Message -EA SilentlyContinue)) { function Add-Message { param([string]$From, [string]$Text, [string]$Kind) } }
if (-not (Get-Command Get-BridgeRoot -EA SilentlyContinue)) { function Get-BridgeRoot { 'C:\Users\rafie\OneDrive\Documents\bridge' } }

$script:pass = 0; $script:fail = 0
function ok($c, $m) { if ($c) { $script:pass++; Write-Host "  ok: $m" } else { $script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red } }

Write-Host '== Test-ProjectAutopilotColdStart =='
$script:MOCK_BACKLOG = @()
ok (Test-ProjectAutopilotColdStart -Channel 'selfie-styler') 'coldstart=TRUE when no atoms'

$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'selfie-styler'; chapter = 'Chapter 1 - scaffold'; status = 'done' })
ok (-not (Test-ProjectAutopilotColdStart -Channel 'selfie-styler')) 'coldstart=FALSE when a chaptered atom exists'

$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'glass-interpreter'; chapter = 'Chapter 3 - x'; status = 'done' })
ok (Test-ProjectAutopilotColdStart -Channel 'selfie-styler') 'coldstart=TRUE when only ANOTHER channel has chapters (bug#2 isolation)'

$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'selfie-styler'; chapter = ''; status = 'working' })
ok (Test-ProjectAutopilotColdStart -Channel 'selfie-styler') 'coldstart=TRUE when the only autopilot atom has no chapter'

Write-Host '== New-ProjectAutopilotCoordinatorTaskText self-heal =='
$tmp = Join-Path $env:TEMP ('coldstart-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
@'
## Chapter 1 - scaffold
## Chapter 2 - domain
## Chapter 3 - camera
## Chapter 4 - styles
## Chapter 5 - apply
## Chapter 6 - result
## Chapter 7 - integration
## Chapter 8 - apk
'@ | Set-Content (Join-Path $tmp 'PROJECT_PLAN.md') -Encoding UTF8

$wideClause = 'No interface-contract/stub/stitching ceremony is required in wide mode'
$diffClause = 'freezes a contract and lets consumers build against a stub'

# cold start + diffusion requested -> healed to wide (all-chapters, no contracts)
$script:MOCK_BACKLOG = @()
$cold = New-ProjectAutopilotCoordinatorTaskText -Slug 'selfie-styler' -ProjectRoot $tmp -MaxTasks 40 -DiffusionMode 'diffusion' -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50
ok ($cold -match [regex]::Escape($wideClause)) 'COLD diffusion -> WIDE clause present (self-heal fired)'
ok ($cold -notmatch [regex]::Escape($diffClause)) 'COLD diffusion -> strict-contract clause ABSENT'
ok ($cold -match 'Decompose ALL remaining approved chapters') 'COLD diffusion -> still all-chapters decomposition'

# a chapter already decomposed -> stays strict diffusion
$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'selfie-styler'; chapter = 'Chapter 1 - scaffold'; status = 'done' })
$warm = New-ProjectAutopilotCoordinatorTaskText -Slug 'selfie-styler' -ProjectRoot $tmp -MaxTasks 40 -DiffusionMode 'diffusion' -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50
ok ($warm -match [regex]::Escape($diffClause)) 'WARM diffusion (chapter exists) -> strict-contract clause retained'

# wide requested directly -> unchanged wide clause even at cold start
$script:MOCK_BACKLOG = @()
$wide = New-ProjectAutopilotCoordinatorTaskText -Slug 'selfie-styler' -ProjectRoot $tmp -MaxTasks 40 -DiffusionMode 'wide' -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50
ok ($wide -match [regex]::Escape($wideClause)) 'WIDE request -> wide clause (unchanged)'

# off requested -> one-chapter default (self-heal must not touch off)
$off = New-ProjectAutopilotCoordinatorTaskText -Slug 'selfie-styler' -ProjectRoot $tmp -MaxTasks 40 -DiffusionMode 'off' -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50
ok ($off -match 'Decompose ONLY Chapter') 'OFF request -> one-chapter default (self-heal untouched)'

Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
