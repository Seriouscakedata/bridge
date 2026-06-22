#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Regression test for the DONE-gate heartbeat pump (Wait-DriverDoneGateJobsWithHeartbeat).
# Root cause it guards: a heavy DONE-gate (parse + smoke + gate-regression, >20min) used to block
# the driver in a bare Wait-Job with no heartbeat write -> watchdog saw a false STALE and restarted
# a HEALTHY-but-finalizing driver. The pump keeps the heartbeat fresh while the gate jobs run, with
# a bounded cap so a genuinely stuck gate still fails closed.

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'driver\86-loop-completion-checks.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Check {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }
  $script:FailCount++
  $suffix = ''
  if ($null -ne $Actual) { $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 6) }
  Write-Host ("FAIL: {0}{1}" -f $Name, $suffix)
}

# --- 1. Interval invariant (HB_PUMP_006): pump interval <= watchdog stale threshold / 3 ---
$i30 = Get-DriverHeartbeatPumpInterval -Requested 30
Check 'interval 30 stays 30' ($i30 -eq 30) $i30
Check 'interval 30 satisfies <= stale/3' ((($i30) * 3) -le $script:DriverWatchdogStaleThresholdSec) $i30
$iBig = Get-DriverHeartbeatPumpInterval -Requested 99999
Check 'interval clamps to stale/3 ceiling' (($iBig * 3) -le $script:DriverWatchdogStaleThresholdSec) $iBig
$iZero = Get-DriverHeartbeatPumpInterval -Requested 0
Check 'interval floors at 5' ($iZero -eq 5) $iZero

# --- 2. Zero jobs returns immediately, no beats ---
$r0 = Wait-DriverDoneGateJobsWithHeartbeat -Jobs @()
Check 'zero jobs: ended completed' ($r0.Ended -eq 'completed') $r0.Ended
Check 'zero jobs: no heartbeats' ($r0.HeartbeatCount -eq 0) $r0.HeartbeatCount

# --- 3. Multiple heartbeats emitted across the block (deterministic fake clock + fake jobs) ---
$script:beats3 = 0
$hb3 = { $script:beats3++ }
$script:fakeT3 = [DateTime]'2026-06-22T00:00:00Z'
$now3 = { $t = $script:fakeT3; $script:fakeT3 = $script:fakeT3.AddSeconds(3); return $t }
$script:polls3 = 0
$run3 = { param($js) $script:polls3++; return ($script:polls3 -le 5) }
$r3 = Wait-DriverDoneGateJobsWithHeartbeat -Jobs @('fake') -HeartbeatIntervalSec 5 -PollIntervalMs 1 -MaxWaitSec 100000 -HeartbeatAction $hb3 -JobsRunningCheck $run3 -NowProvider $now3
Check 'block: ended completed' ($r3.Ended -eq 'completed') $r3.Ended
Check 'block: emitted >1 heartbeat during the block' ($script:beats3 -ge 2) $script:beats3
Check 'block: record count matches recorder' ($r3.HeartbeatCount -eq $script:beats3) @($r3.HeartbeatCount, $script:beats3)
Check 'block: not cap' (-not $r3.CapHit) $r3

# --- 4. Cap path: jobs never finish -> pump stops and returns so the gate fails closed ---
$script:beats4 = 0
$hb4 = { $script:beats4++ }
$script:fakeT4 = [DateTime]'2026-06-22T00:00:00Z'
$now4 = { $t = $script:fakeT4; $script:fakeT4 = $script:fakeT4.AddSeconds(3); return $t }
$runAlways = { param($js) $true }
$r4 = Wait-DriverDoneGateJobsWithHeartbeat -Jobs @('stuck') -HeartbeatIntervalSec 5 -PollIntervalMs 1 -MaxWaitSec 7 -HeartbeatAction $hb4 -JobsRunningCheck $runAlways -NowProvider $now4
Check 'cap: terminated despite jobs still running' ($r4.CapHit) $r4
Check 'cap: ended=cap' ($r4.Ended -eq 'cap') $r4.Ended
Check 'cap: still emitted at least the opening beat' ($script:beats4 -ge 1) $script:beats4

# --- 5. Real job end-to-end through the default .State check + real clock ---
$script:beats5 = 0
$hb5 = { $script:beats5++ }
$realJob = Start-Job -ScriptBlock { Start-Sleep -Milliseconds 700 }
try {
  $r5 = Wait-DriverDoneGateJobsWithHeartbeat -Jobs @($realJob) -HeartbeatIntervalSec 5 -PollIntervalMs 50 -MaxWaitSec 60 -HeartbeatAction $hb5
  Check 'real job: ended completed' ($r5.Ended -eq 'completed') $r5.Ended
  Check 'real job: opening beat fired' ($script:beats5 -ge 1) $script:beats5
  Check 'real job: not cap' (-not $r5.CapHit) $r5
} finally {
  Remove-Job -Job $realJob -Force -ErrorAction SilentlyContinue
}

if ($script:FailCount -gt 0) {
  Write-Host ("test-donegate-heartbeat-pump: FAIL ({0} passed, {1} failed)" -f $script:PassCount, $script:FailCount) -ForegroundColor Red
  exit 1
}
Write-Host ("test-donegate-heartbeat-pump: PASS ({0} tests)" -f $script:PassCount) -ForegroundColor Green
exit 0
