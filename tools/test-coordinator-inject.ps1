# Coordinator injected-inputs unit test (2026-07-02 planner-speed).
# Verifies Get-ProjectAutopilotInjectedInputsBlock + the conditional read directive in
# New-ProjectAutopilotCoordinatorTaskText:
#  (a) cold start + plan/brief/contract on disk -> prompt has 'INJECTED PROJECT INPUTS' with the
#      plan content verbatim, the do-NOT-read directive, and NO 'Read the Bridge spec layer first';
#  (b) warm (a chaptered atom exists) -> scoped read line, injected inputs still present,
#      PROJECT_MAP.md not injected (cold-start-only file);
#  (c) clipping: a >24KB plan gets the '[...clipped N of M bytes...]' marker on a LINE boundary;
#      oversized JSON contract is skipped whole (never cut mid-JSON), mid-size JSON injected whole;
#  (d) fail-open: nonexistent project root -> prompt still builds, no INJECTED block, classic line.
# Isolated: mocks Get-Backlog + a temp bridge root (mirrors test-diffusion-coldstart-selfheal.ps1).
$ErrorActionPreference = 'Stop'
$lib = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog-autopilot.ps1'
. $lib

$script:MOCK_BACKLOG = @()
$script:TMPROOT = Join-Path $env:TEMP ('inject-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path (Join-Path $script:TMPROOT 'channels') 'inject-test') | Out-Null
function Get-Backlog { return $script:MOCK_BACKLOG }
function Get-BridgeRoot { return $script:TMPROOT }
if (-not (Get-Command Get-BacklogPackObjectValue -EA SilentlyContinue)) {
  function Get-BacklogPackObjectValue { param($Obj, $Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $Default }
}
if (-not (Get-Command Write-BacklogJsonLine -EA SilentlyContinue)) { function Write-BacklogJsonLine { param($x) } }
if (-not (Get-Command Add-Message -EA SilentlyContinue)) { function Add-Message { param([string]$From, [string]$Text, [string]$Kind) } }

$script:pass = 0; $script:fail = 0
function ok($c, $m) { if ($c) { $script:pass++; Write-Host "  ok: $m" } else { $script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red } }

# temp project with plan/brief/contract/acceptance/map (sentinels prove verbatim injection)
$tmp = Join-Path $env:TEMP ('inject-proj-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path (Join-Path $tmp '.bridge') 'specs') | Out-Null
@'
## Chapter 1 - scaffold
plan-sentinel-alpha unique verbatim line
## Chapter 2 - screens
## Chapter 3 - release
'@ | Set-Content (Join-Path $tmp 'PROJECT_PLAN.md') -Encoding UTF8
'brief-sentinel-bravo' | Set-Content (Join-Path $tmp 'PROJECT_BRIEF.md') -Encoding UTF8
'{ "requirements": ["contract-sentinel-charlie"] }' | Set-Content (Join-Path (Join-Path $tmp '.bridge') 'project-contract.json') -Encoding UTF8
'acceptance-sentinel-delta' | Set-Content (Join-Path (Join-Path (Join-Path $tmp '.bridge') 'specs') 'acceptance.md') -Encoding UTF8
'map-sentinel-echo' | Set-Content (Join-Path $tmp 'PROJECT_MAP.md') -Encoding UTF8

function Coord($root) { New-ProjectAutopilotCoordinatorTaskText -Slug 'inject-test' -ProjectRoot $root -MaxTasks 40 -DiffusionMode 'wide' -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 50 }

Write-Host '== (a) cold start: inputs injected, read directive replaced =='
$script:MOCK_BACKLOG = @()
$a = Coord $tmp
ok ($a -match 'INJECTED PROJECT INPUTS') 'prompt contains INJECTED PROJECT INPUTS header'
ok ($a.Contains('plan-sentinel-alpha unique verbatim line')) 'PROJECT_PLAN.md content injected verbatim'
ok ($a.Contains('brief-sentinel-bravo')) 'PROJECT_BRIEF.md injected'
ok ($a.Contains('contract-sentinel-charlie')) 'project-contract.json injected'
ok ($a.Contains('acceptance-sentinel-delta')) 'specs/acceptance.md injected'
ok ($a.Contains('map-sentinel-echo')) 'PROJECT_MAP.md injected on COLD start'
ok ($a -match 'Do NOT read files') 'cold-start do-NOT-read directive present'
ok ($a -notmatch 'Read the Bridge spec layer first') 'static read-everything line replaced on cold start'

Write-Host '== (b) warm: scoped read line, inputs still injected, map NOT injected =='
$script:MOCK_BACKLOG = @([pscustomobject]@{ from = 'project-autopilot'; project = 'inject-test'; chapter = 'Chapter 1 - scaffold'; status = 'done' })
$b = Coord $tmp
ok ($b -match 'Read ONLY the specific source files your atoms will create or touch') 'warm scoped read line present'
ok ($b -match 'INJECTED PROJECT INPUTS') 'warm prompt still injects inputs'
ok ($b.Contains('plan-sentinel-alpha unique verbatim line')) 'warm: plan still injected verbatim'
ok ($b -notmatch 'Read the Bridge spec layer first') 'warm: static read-everything line replaced'
ok ($b -notmatch 'Do NOT read files') 'warm: cold-start directive absent'
ok (-not $b.Contains('map-sentinel-echo')) 'warm: PROJECT_MAP.md NOT injected (cold-start-only)'

Write-Host '== (c) clipping on line boundary + JSON whole-or-skip rule =='
$tmp2 = Join-Path $env:TEMP ('inject-clip-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $tmp2 '.bridge') | Out-Null
$fill = for ($i = 1; $i -le 1200; $i++) { "plan filler line $i with some padding text to grow bytes" }
("## Chapter 1 - scaffold`n" + ($fill -join "`n") + "`n") | Set-Content (Join-Path $tmp2 'PROJECT_PLAN.md') -Encoding UTF8
$blk = Get-ProjectAutopilotInjectedInputsBlock -ProjectRoot $tmp2 -ColdStart $true
ok ($blk -match '\[\.\.\.clipped \d+ of \d+ bytes\.\.\.\]') 'oversized plan carries the clipped marker'
ok ($blk -match 'padding text to grow bytes\r?\n\[\.\.\.clipped') 'clip lands ON a line boundary (last kept line is complete)'
$mClip = [regex]::Match($blk, '\[\.\.\.clipped (\d+) of (\d+) bytes\.\.\.\]')
ok ($mClip.Success -and [int]$mClip.Groups[1].Value -le 24576 -and [int]$mClip.Groups[2].Value -gt 24576) 'clip marker numbers: kept <= 24576 < total'
# oversized JSON: skipped whole with a note (never cut mid-JSON)
$bigJson = '{ "json-sentinel-foxtrot": "' + ('x' * 26000) + '" }'
$bigJson | Set-Content (Join-Path (Join-Path $tmp2 '.bridge') 'project-contract.json') -Encoding UTF8
$blk2 = Get-ProjectAutopilotInjectedInputsBlock -ProjectRoot $tmp2 -ColdStart $true
ok ($blk2 -match 'NOT injected: \d+ bytes exceeds the 24576-byte whole-JSON cap') 'oversized contract JSON skipped with a note'
ok (-not $blk2.Contains('json-sentinel-foxtrot')) 'oversized contract body NOT injected'
# mid-size JSON (>16384, <=24576): injected WHOLE (tail sentinel survives, no clip marker in that section)
$midJson = '{ "pad": "' + ('y' * 20000) + '", "json-tail-sentinel-golf": true }'
$midJson | Set-Content (Join-Path (Join-Path $tmp2 '.bridge') 'project-contract.json') -Encoding UTF8
$blk3 = Get-ProjectAutopilotInjectedInputsBlock -ProjectRoot $tmp2 -ColdStart $true
ok ($blk3.Contains('json-tail-sentinel-golf')) 'mid-size contract JSON injected WHOLE (tail intact, never cut mid-JSON)'

Write-Host '== (d) fail-open: nonexistent project root =='
$script:MOCK_BACKLOG = @()
$ghost = Join-Path $env:TEMP ('inject-ghost-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$d = Coord $ghost
ok ($d -match '\[project-autopilot inject-test\]') 'prompt still builds (no crash)'
ok ($d -notmatch 'INJECTED PROJECT INPUTS') 'no INJECTED block for missing root'
ok ($d -match 'Read the Bridge spec layer first') 'classic read line kept when nothing injected'
ok ((Get-ProjectAutopilotInjectedInputsBlock -ProjectRoot $ghost -ColdStart $true) -eq '') 'helper returns empty string for missing root'

Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
Remove-Item -Recurse -Force $tmp2 -EA SilentlyContinue
Remove-Item -Recurse -Force $script:TMPROOT -EA SilentlyContinue
Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
