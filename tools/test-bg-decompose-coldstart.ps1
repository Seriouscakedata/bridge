param()
# Tests the upfront-speed#2 cold-start carve-out in Test-ShouldBackgroundDecompose + the foreground
# retirement in Start-ProjectAutopilotIfNeeded (lib/backlog-autopilot.ps1). The carve-out is deadlock-
# critical: when the foreground coordinator is retired (decomposeAheadLimit>1), the background worker MUST
# fire at true cold start (no atoms yet) or chapter 1 never gets decomposed.
$ErrorActionPreference = 'Stop'
function Assert-True { param([bool]$Cond,[string]$Msg) if (-not $Cond) { throw ("FAIL: " + $Msg) } }

. 'C:\Users\rafie\.bridge-runtime\tmp\op-bootstrap.ps1' *> $null

# --- Mocks (override lib functions after bootstrap; later definition wins) ---
$script:MockBacklog = @()
$script:MockLimit = 2
$script:MockChapters = 7
function Get-ProjectAutopilotConfig { return [pscustomobject]@{ decomposeAheadLimit = $script:MockLimit; maxTasksPerBatch = 12; diffusionMode='off'; diffusionMinIndependentAtoms=3; diffusionMaxWaveSize=8 } }
function Get-ChannelProjectBinding { param($Slug) return [pscustomobject]@{ ok=$true; project_root='C:\Users\rafie\bridge-projects\selfie-styler' } }
function Get-Backlog { return $script:MockBacklog }
function Get-ProjectAutopilotPlanChapterCount { param($ProjectRoot) return $script:MockChapters }
function Test-BackgroundDecomposeRunning { param($Channel) return $false }

function New-Atom { param([string]$chapter,[string]$status) [pscustomobject]@{ from='project-autopilot'; chapter=$chapter; status=$status } }

# Case 1: TRUE COLD START — no atoms at all, plan has chapters, limit>1 -> MUST decompose (should=true).
$script:MockBacklog = @()
$script:MockLimit = 2
$r1 = Test-ShouldBackgroundDecompose -Channel 'selfie-styler'
Assert-True ($r1.should -eq $true) ("cold-start should be should=true, got should=$($r1.should) reason=$($r1.reason)")
Assert-True ($r1.reason -eq 'ok') ("cold-start reason should be 'ok', got '$($r1.reason)'")

# Case 2: DORMANT — atoms exist but all done (decomposed>0, runnable=0) -> should=false 'no-runnable-atoms'.
$script:MockBacklog = @( (New-Atom 'Chapter 1 - Theme' 'done'), (New-Atom 'Chapter 1 - Nav' 'done') )
$script:MockLimit = 2
$r2 = Test-ShouldBackgroundDecompose -Channel 'selfie-styler'
Assert-True ($r2.should -eq $false) ("dormant should be should=false, got should=$($r2.should)")
Assert-True ($r2.reason -eq 'no-runnable-atoms') ("dormant reason should be 'no-runnable-atoms', got '$($r2.reason)'")

# Case 3: ACTIVE — runnable atoms in chapter 1, undecomposed chapters remain -> should=true (decompose-ahead).
$script:MockBacklog = @( (New-Atom 'Chapter 1 - Theme' 'approved'), (New-Atom 'Chapter 1 - Nav' 'approved') )
$script:MockLimit = 2
$r3 = Test-ShouldBackgroundDecompose -Channel 'selfie-styler'
Assert-True ($r3.should -eq $true) ("active should be should=true, got should=$($r3.should) reason=$($r3.reason)")

# Case 4: FLAG OFF — limit<=1 -> should=false 'flag-off' (background owns nothing; foreground decomposes).
$script:MockBacklog = @()
$script:MockLimit = 1
$r4 = Test-ShouldBackgroundDecompose -Channel 'selfie-styler'
Assert-True ($r4.should -eq $false) ("flag-off should be should=false")
Assert-True ($r4.reason -eq 'flag-off') ("flag-off reason should be 'flag-off', got '$($r4.reason)'")

# Case 5: COLD START but ALL chapters already decomposed edge (decomposed>=total, runnable=0, atoms done) ->
# dormant path returns first (decomposed>0 -> no-runnable-atoms), so never spins. (same as case 2 essentially)
$script:MockBacklog = @( (New-Atom 'Chapter 1 - Theme' 'done') )
$script:MockChapters = 1
$script:MockLimit = 2
$r5 = Test-ShouldBackgroundDecompose -Channel 'selfie-styler'
Assert-True ($r5.should -eq $false) ("all-done channel must not spawn, got should=$($r5.should) reason=$($r5.reason)")
$script:MockChapters = 7

Write-Host "OK bg-decompose cold-start: cold-start=decompose, dormant=silent, active=decompose-ahead, flag-off=off, all-done=silent (5/5)"
