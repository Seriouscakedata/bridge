# Diffusion self-heal + pause-guard unit test (2026-07-01, broadened).
# Verifies: (1) Test-ProjectAutopilotColdStart channel-scoped/chapter-aware; (2) Test-ProjectAutopilotHasFrozen
# Contracts reads stable freeze locks; (3) strict 'diffusion' is healed to all-chapters 'wide' whenever there is
# no stable frozen contract (cold start OR a contract-less warm project); (4) once a stable contract is frozen,
# diffusion stays strict; (5) 'wide'/'off' requests untouched. Isolated: mocks Get-Backlog + a temp bridge root.
$ErrorActionPreference = 'Stop'
$lib = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog-autopilot.ps1'
. $lib

$script:MOCK_BACKLOG = @()
$script:TMPROOT = Join-Path $env:TEMP ('selfheal-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path (Join-Path $script:TMPROOT 'channels') 'selfie-styler') | Out-Null
function Get-Backlog { return $script:MOCK_BACKLOG }
function Get-BridgeRoot { return $script:TMPROOT }
if (-not (Get-Command Get-BacklogPackObjectValue -EA SilentlyContinue)) {
  function Get-BacklogPackObjectValue { param($Obj, $Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $Default }
}
if (-not (Get-Command Write-BacklogJsonLine -EA SilentlyContinue)) { function Write-BacklogJsonLine { param($x) } }
if (-not (Get-Command Add-Message -EA SilentlyContinue)) { function Add-Message { param([string]$From, [string]$Text, [string]$Kind) } }

function New-FreezeLock($stable) {
  $d = Join-Path (Join-Path (Join-Path (Join-Path $script:TMPROOT 'channels') 'selfie-styler') 'diffusion-contract-freezes') 'h1'
  New-Item -ItemType Directory -Force $d | Out-Null
  (@{ contract_id = 'user-api'; stable = $stable } | ConvertTo-Json) | Set-Content (Join-Path $d 'user-api.lock.json') -Encoding UTF8
}
function Clear-Freezes { $p = Join-Path (Join-Path (Join-Path $script:TMPROOT 'channels') 'selfie-styler') 'diffusion-contract-freezes'; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }

$script:pass = 0; $script:fail = 0
function ok($c, $m) { if ($c) { $script:pass++; Write-Host "  ok: $m" } else { $script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red } }

Write-Host '== Test-ProjectAutopilotColdStart =='
$script:MOCK_BACKLOG = @()
ok (Test-ProjectAutopilotColdStart -Channel 'selfie-styler') 'coldstart=TRUE when no atoms'
$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'selfie-styler'; chapter = 'Chapter 1 - scaffold'; status = 'done' })
ok (-not (Test-ProjectAutopilotColdStart -Channel 'selfie-styler')) 'coldstart=FALSE when a chaptered atom exists'
$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'glass-interpreter'; chapter = 'Chapter 3 - x'; status = 'done' })
ok (Test-ProjectAutopilotColdStart -Channel 'selfie-styler') 'coldstart=TRUE when only ANOTHER channel has chapters (bug#2)'

Write-Host '== Test-ProjectAutopilotHasFrozenContracts =='
Clear-Freezes
ok (-not (Test-ProjectAutopilotHasFrozenContracts -Channel 'selfie-styler')) 'no freeze dir -> false'
New-FreezeLock $false
ok (-not (Test-ProjectAutopilotHasFrozenContracts -Channel 'selfie-styler')) 'lock stable:false -> false'
New-FreezeLock $true
ok (Test-ProjectAutopilotHasFrozenContracts -Channel 'selfie-styler') 'lock stable:true -> true'

Write-Host '== self-heal in New-ProjectAutopilotCoordinatorTaskText =='
$tmp = Join-Path $env:TEMP ('selfheal-plan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
function Coord($mode) { New-ProjectAutopilotCoordinatorTaskText -Slug 'selfie-styler' -ProjectRoot $tmp -MaxTasks 40 -DiffusionMode $mode -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50 }

# cold start + diffusion -> wide
$script:MOCK_BACKLOG = @(); Clear-Freezes
$c = Coord 'diffusion'
ok ($c -match [regex]::Escape($wideClause)) 'COLD diffusion -> WIDE clause'
ok ($c -notmatch [regex]::Escape($diffClause)) 'COLD diffusion -> no strict clause'
ok ($c -match 'Decompose ALL remaining approved chapters') 'COLD diffusion -> all-chapters'

# WARM (chapter exists) + NO frozen contract -> STILL wide (broadened self-heal)
$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'selfie-styler'; chapter = 'Chapter 1 - scaffold'; status = 'done' }); Clear-Freezes
$w = Coord 'diffusion'
ok ($w -match [regex]::Escape($wideClause)) 'WARM + no frozen contract -> WIDE (broadened self-heal)'
ok ($w -match 'Decompose ALL remaining approved chapters') 'WARM + no contract -> all-chapters parallel wave'

# WARM + a STABLE frozen contract -> strict diffusion engages
New-FreezeLock $true
$s = Coord 'diffusion'
ok ($s -match [regex]::Escape($diffClause)) 'WARM + stable frozen contract -> strict diffusion clause'

# wide / off untouched
$script:MOCK_BACKLOG = @(); Clear-Freezes
ok ((Coord 'wide') -match [regex]::Escape($wideClause)) 'WIDE request -> wide clause (unchanged)'
ok ((Coord 'off') -match 'Decompose ONLY Chapter') 'OFF request -> one-chapter (untouched)'

Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
Remove-Item -Recurse -Force $script:TMPROOT -EA SilentlyContinue
Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
