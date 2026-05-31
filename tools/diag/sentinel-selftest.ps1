#Requires -Version 5.1
# ASCII-only self-test for the System Sentinel storm detector (watchdog.ps1).
# Extracts the config+functions (everything before the main loop), stubs side effects,
# and exercises: calm / detect / grace / dispatch / cooldown / self-heal / escalation.
$ErrorActionPreference = 'Stop'
$realWatchdog = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'watchdog.ps1'
if (-not (Test-Path $realWatchdog)) { Write-Host "FAIL: watchdog.ps1 not found at $realWatchdog"; exit 1 }

# 1) sandbox + redirect env to it (child process only, never touches real runtime)
$sandbox = Join-Path $env:TEMP ('sentinel-test-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
$env:BRIDGE_ROOT = $sandbox
$env:USERPROFILE = $sandbox
New-Item -ItemType Directory -Path (Join-Path $sandbox 'control') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox 'channels\main') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox '.bridge-runtime') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox '.bridge-private') -Force | Out-Null

# 2) load config+functions only (cut before the while-loop)
$src = [System.IO.File]::ReadAllText($realWatchdog, [System.Text.Encoding]::UTF8)
$marker = 'WLog "=== watchdog loop started'
$idx = $src.IndexOf($marker)
if ($idx -lt 0) { Write-Host 'FAIL: loop marker not found'; exit 1 }
Invoke-Expression $src.Substring(0, $idx)

# 3) stub side effects AFTER extract (late binding -> these win at call time)
$script:logs = New-Object System.Collections.ArrayList
function WLog($m) { [void]$script:logs.Add([string]$m) }
function Invoke-Rollback { $script:rolledBack = $true }
function Request-Restart { $script:restarted = $true }

$conv         = Join-Path $sandbox 'channels\main\conversation.jsonl'
$restartsFile = Join-Path $sandbox '.bridge-runtime\restarts.jsonl'
$repairSignal = Join-Path $sandbox 'control\repair.signal'
$suspectFile  = Join-Path $sandbox 'control\sentinel.suspect'
function UtcAgo($sec) { ((Get-Date).ToUniversalTime().AddSeconds(-$sec)).ToString('o') }
function WriteConv($lines) { [System.IO.File]::WriteAllLines($conv, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false))) }
function ClearSignals { Remove-Item $repairSignal, $suspectFile -Force -ErrorAction SilentlyContinue }
function ErrLine($seq, $agoSec) { return '{"seq":' + $seq + ',"ts":"' + (UtcAgo $agoSec) + '","from":"system","kind":"event","text":"Oshibka drajvera: Cannot process argument transformation on parameter StopReason. Reference type is expected."}' }

$fails = 0
function Assert($name, $cond) { if ($cond) { Write-Host "  PASS: $name" } else { Write-Host "  FAIL: $name"; $script:fails++ } }

Write-Host "[S0] calm system -> no storm"
WriteConv @('{"seq":1,"ts":"' + (UtcAgo 60) + '","from":"system","kind":"event","text":"task done ok"}')
'' | Out-File $restartsFile -Encoding ascii
$s = Get-StormSignals
Assert 'S0 calm returns null' ($null -eq $s)

Write-Host "`n[S1] 6x identical error in last 3 min -> storm detected"
WriteConv (1..6 | ForEach-Object { ErrLine (10 + $_) (30 * $_) })
$s = Get-StormSignals
Assert 'S1 storm detected' ($null -ne $s -and $s.count -ge 6)
Assert 'S1 source=error' ($s -and $s.source -eq 'error')
Assert 'S1 marked live (recent)' ($s -and $s.lastSeenSec -le $stormRecencySec)

Write-Host "`n[S2] first Check-Storm -> grace, NO dispatch"
ClearSignals
Check-Storm
Assert 'S2 suspect created' (Test-Path $suspectFile)
Assert 'S2 no repair.signal during grace' (-not (Test-Path $repairSignal))

Write-Host "`n[S3] age suspect past grace -> dispatch Doctor"
$susp = Get-Content $suspectFile -Raw | ConvertFrom-Json
$susp.firstSeen = (UtcAgo ($stormGraceSec + 120))
($susp | ConvertTo-Json -Compress) | Out-File $suspectFile -Encoding utf8
Check-Storm
Assert 'S3 repair.signal created' (Test-Path $repairSignal)
$rs = if (Test-Path $repairSignal) { (Get-Content $repairSignal -Raw).Trim() } else { '' }
Assert 'S3 signal=storm_detected:*' ($rs -like 'storm_detected:*')
$susp2 = Get-Content $suspectFile -Raw | ConvertFrom-Json
Assert 'S3 suspect.dispatched=true' ([bool]$susp2.dispatched)

Write-Host "`n[S4] within escalate window -> watch, no rollback"
$script:rolledBack = $false
Remove-Item $repairSignal -Force -ErrorAction SilentlyContinue
Check-Storm
Assert 'S4 no rollback while watching' (-not $script:rolledBack)

Write-Host "`n[S5] storm gone -> self-heal -> suspect cleared"
ClearSignals
WriteConv @('{"seq":99,"ts":"' + (UtcAgo 30) + '","from":"system","kind":"event","text":"all good now"}')
(@{ sig='deadbeef'; firstSeen=(UtcAgo 600); count=6; source='error'; sample='old storm'; dispatched=$false; dispatchedAt='' } | ConvertTo-Json -Compress) | Out-File $suspectFile -Encoding utf8
Check-Storm
Assert 'S5 suspect cleared on self-heal' (-not (Test-Path $suspectFile))

Write-Host "`n[S6] dispatched + still live + past escalate -> rollback + page"
$script:rolledBack = $false; $script:restarted = $false
WriteConv (1..6 | ForEach-Object { ErrLine (200 + $_) (20 * $_) })
$live = Get-StormSignals
(@{ sig=$live.sig; firstSeen=(UtcAgo 2000); count=6; source='error'; sample='persistent'; dispatched=$true; dispatchedAt=(UtcAgo ($stormEscalateSec + 120)) } | ConvertTo-Json -Compress) | Out-File $suspectFile -Encoding utf8
Check-Storm
Assert 'S6 rollback invoked' ($script:rolledBack)
Assert 'S6 restart requested' ($script:restarted)
$rs2 = if (Test-Path $repairSignal) { (Get-Content $repairSignal -Raw).Trim() } else { '' }
Assert 'S6 signal=storm_unhealed_rollback:*' ($rs2 -like 'storm_unhealed_rollback:*')

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'SENTINEL-SELFTEST: PASS' } else { Write-Host "SENTINEL-SELFTEST: FAIL ($fails assertion(s))"; exit 1 }
