#Requires -Version 5.1
# ASCII-only self-test for Test-CircuitCooldown + watchdog hold-on-cooldown (deadlock fix).
$ErrorActionPreference = 'Stop'
$realWatchdog = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'watchdog.ps1'
if (-not (Test-Path $realWatchdog)) { Write-Host "FAIL: watchdog.ps1 not found"; exit 1 }

$sandbox = Join-Path $env:TEMP ('cb-test-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
$env:BRIDGE_ROOT = $sandbox
$env:USERPROFILE = $sandbox
New-Item -ItemType Directory -Path (Join-Path $sandbox 'control') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox 'channels\main') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox '.bridge-runtime') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox '.bridge-private') -Force | Out-Null
'{"circuitBreaker":{"windowMin":30,"maxRestarts":5}}' | Out-File (Join-Path $sandbox 'config.json') -Encoding ascii

# load config+functions only (cut before the while-loop)
$src = [System.IO.File]::ReadAllText($realWatchdog, [System.Text.Encoding]::UTF8)
$idx = $src.IndexOf('WLog "=== watchdog loop started')
if ($idx -lt 0) { Write-Host 'FAIL: loop marker not found'; exit 1 }
. ([scriptblock]::Create($src.Substring(0, $idx)))

# stub side effects (late binding)
$script:restarted = $false; $script:rolledBack = $false
function WLog($m) {}
function Invoke-Rollback { $script:rolledBack = $true }
function Request-Restart { $script:restarted = $true }

$rj = Join-Path $sandbox '.bridge-runtime\restarts.jsonl'
function UtcAgo($sec) { ((Get-Date).ToUniversalTime().AddSeconds(-$sec)).ToString('o') }
function WriteRestarts($n, $agoBaseSec) {
  $lines = 1..$n | ForEach-Object { '{"ts":"' + (UtcAgo ($agoBaseSec + $_*5)) + '","cause":"explicit-flag","signature":"abc","detail":"x"}' }
  [System.IO.File]::WriteAllLines($rj, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}
$fails = 0
function Assert($n, $c) { if ($c) { Write-Host "  PASS: $n" } else { Write-Host "  FAIL: $n"; $script:fails++ } }

Write-Host "[C0] empty restarts -> not cooldown"
[System.IO.File]::WriteAllText($rj, '')
Assert 'C0 false' (-not (Test-CircuitCooldown))

Write-Host "`n[C1] 5 fresh restarts -> cooldown (TRIPPED)"
WriteRestarts 5 0
Assert 'C1 true' (Test-CircuitCooldown)

Write-Host "`n[C2] 4 fresh restarts -> not cooldown (below max)"
WriteRestarts 4 0
Assert 'C2 false' (-not (Test-CircuitCooldown))

Write-Host "`n[C3] 6 OLD restarts (>30min ago) -> not cooldown (out of window)"
WriteRestarts 6 2400
Assert 'C3 false' (-not (Test-CircuitCooldown))

# Check-Once integration: stale heartbeat + bad auth (api down) + high fails => would rollback/restart,
# UNLESS the breaker is tripped, in which case it must HOLD.
'{"password":"wrong-pw-so-api-401"}' | Out-File (Join-Path $sandbox 'auth.json') -Encoding ascii
('{"heartbeat":"' + (UtcAgo 3000) + '"}') | Out-File (Join-Path $sandbox 'channels\main\state.json') -Encoding ascii

Write-Host "`n[C4] Check-Once: cooldown + unhealthy -> HOLD (no restart, no rollback)"
WriteRestarts 5 0
'9' | Out-File (Join-Path $sandbox 'control\watchdog.fails') -Encoding ascii
$script:restarted = $false; $script:rolledBack = $false
Check-Once
Assert 'C4 no restart (held)' (-not $script:restarted)
Assert 'C4 no rollback (held)' (-not $script:rolledBack)

Write-Host "`n[C5] Check-Once: NO cooldown + unhealthy -> acts (sanity: fix didn't break normal recovery)"
[System.IO.File]::WriteAllText($rj, '')
'9' | Out-File (Join-Path $sandbox 'control\watchdog.fails') -Encoding ascii
$script:restarted = $false; $script:rolledBack = $false
Check-Once
Assert 'C5 acted (restart or rollback)' ($script:restarted -or $script:rolledBack)

Write-Host "`n[C6] heartbeat stale + parallel ACTIVE in a channel -> HOLD rollback (H1 guard)"
[System.IO.File]::WriteAllText($rj, '')   # no cooldown, so only the parallel guard can hold
'9' | Out-File (Join-Path $sandbox 'control\watchdog.fails') -Encoding ascii
New-Item -ItemType Directory -Path (Join-Path $sandbox 'channels\travel') -Force | Out-Null
('{"heartbeat":"' + (UtcAgo 10) + '","parallel_streams":[{"id":"s1"},{"id":"s2"}]}') | Out-File (Join-Path $sandbox 'channels\travel\state.json') -Encoding ascii
$script:restarted = $false; $script:rolledBack = $false
Check-Once
Assert 'C6 no rollback while parallel active' (-not $script:rolledBack)

Write-Host "`n[C6b] parallel cleared -> rollback proceeds again"
Remove-Item (Join-Path $sandbox 'channels\travel\state.json') -Force -ErrorAction SilentlyContinue
'9' | Out-File (Join-Path $sandbox 'control\watchdog.fails') -Encoding ascii
$script:restarted = $false; $script:rolledBack = $false
Check-Once
Assert 'C6b rollback proceeds once parallel clears' ($script:rolledBack -or $script:restarted)

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'CIRCUIT-COOLDOWN-SELFTEST: PASS' } else { Write-Host "CIRCUIT-COOLDOWN-SELFTEST: FAIL ($fails assertion(s))"; exit 1 }
