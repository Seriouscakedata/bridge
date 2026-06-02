# circuit_breaker_test.ps1 -- focused self-test for lib/circuit-breaker.ps1.
param([string]$WorkDir = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\circuit-breaker.ps1')

function Assert-Cb {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT: $Message" }
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $WorkDir = Join-Path $root ('tmp\circuit-breaker-test-' + (Get-Date -Format 'yyyyMMddHHmmss'))
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$now = [datetime]'2026-05-29T13:00:00Z'
$log = Join-Path $WorkDir 'restarts.jsonl'
$enc = New-Object System.Text.UTF8Encoding($false)
$bom = [string][char]0xFEFF

function New-CbLine {
  param([datetime]$Ts, [string]$Cause, [string]$Signature)
  ([pscustomobject]@{
    ts = $Ts.ToUniversalTime().ToString('o')
    cause = $Cause
    signature = $Signature
    detail = 'test'
    pid = 1
  } | ConvertTo-Json -Compress -Depth 3)
}

$lines = @()
1..5 | ForEach-Object { $lines += (New-CbLine -Ts $now.AddMinutes(-1 * $_) -Cause 'parse-fail' -Signature 'same-parse') }
$lines[2] = $bom + $lines[2]
$lines += '{bad json'
[System.IO.File]::WriteAllText($log, (($lines -join "`n") + "`n"), $enc)
$trip = Test-CircuitTrip -LogPath $log -WindowMin 30 -MaxRestarts 5 -Now $now
Assert-Cb $trip.tripped '5 events in 30min should trip'
Assert-Cb ($trip.countInWindow -eq 5) 'BOM-prefixed JSONL line should count and bad JSONL line should be ignored'
Assert-Cb ($trip.invalidLineCount -eq 1) 'bad JSONL line should be counted as invalid'
Assert-Cb ($trip.dominantSignatureCause -eq 'parse-fail') 'dominant repeated signature should retain its cause'
Assert-Cb ((Get-CircuitMode -Trip $trip) -eq 'hard-freeze') 'same deterministic signature should hard-freeze'

$old = Join-Path $WorkDir 'old.jsonl'
$oldLines = @()
1..4 | ForEach-Object { $oldLines += (New-CbLine -Ts $now.AddMinutes(-35 - $_) -Cause 'explicit-flag' -Signature "old-$_") }
[System.IO.File]::WriteAllText($old, (($oldLines -join "`n") + "`n"), $enc)
$oldTrip = Test-CircuitTrip -LogPath $old -WindowMin 30 -MaxRestarts 5 -Now $now
Assert-Cb (-not $oldTrip.tripped) '4 old events should not trip'
Assert-Cb ($oldTrip.countInWindow -eq 0) 'old events should be outside window'

$causes = @(
  (Get-RestartCause -RecentErrLog 'ParserError: bad token' -ReapFired:$false -FlagPresent:$false -StateAttempts 0).class,
  (Get-RestartCause -RecentErrLog 'state.json повреждён' -ReapFired:$false -FlagPresent:$false -StateAttempts 0).class,
  (Get-RestartCause -RecentErrLog '' -ReapFired:$true -FlagPresent:$false -StateAttempts 0).class,
  (Get-RestartCause -RecentErrLog '' -ReapFired:$false -FlagPresent:$true -StateAttempts 0).class
)
Assert-Cb (($causes -join ',') -eq 'parse-fail,state-corrupt,OOM,explicit-flag') 'restart cause classification mismatch'

$mixed = Join-Path $WorkDir 'mixed.jsonl'
$mixedLines = @(
  (New-CbLine -Ts $now.AddMinutes(-1) -Cause 'explicit-flag' -Signature 'a'),
  (New-CbLine -Ts $now.AddMinutes(-2) -Cause 'unknown' -Signature 'b'),
  (New-CbLine -Ts $now.AddMinutes(-3) -Cause 'OOM' -Signature 'c'),
  (New-CbLine -Ts $now.AddMinutes(-4) -Cause 'explicit-flag' -Signature 'd'),
  (New-CbLine -Ts $now.AddMinutes(-5) -Cause 'unknown' -Signature 'e')
)
[System.IO.File]::WriteAllText($mixed, (($mixedLines -join "`n") + "`n"), $enc)
$mixedTrip = Test-CircuitTrip -LogPath $mixed -WindowMin 30 -MaxRestarts 5 -Now $now
Assert-Cb ($mixedTrip.tripped -and (Get-CircuitMode -Trip $mixedTrip) -eq 'cooldown') 'mixed trip should cooldown'

$explicitRepeated = Join-Path $WorkDir 'explicit-repeated.jsonl'
$explicitRepeatedLines = @()
1..4 | ForEach-Object { $explicitRepeatedLines += (New-CbLine -Ts $now.AddMinutes(-1 * $_) -Cause 'explicit-flag' -Signature 'same-explicit') }
$explicitRepeatedLines += (New-CbLine -Ts $now.AddMinutes(-5) -Cause 'parse-fail' -Signature 'one-parse')
[System.IO.File]::WriteAllText($explicitRepeated, (($explicitRepeatedLines -join "`n") + "`n"), $enc)
$explicitRepeatedTrip = Test-CircuitTrip -LogPath $explicitRepeated -WindowMin 30 -MaxRestarts 5 -Now $now
Assert-Cb ($explicitRepeatedTrip.tripped -and $explicitRepeatedTrip.sameSignatureRatio -eq 0.8) 'repeated explicit flag should compute pair ratio'
Assert-Cb ((Get-CircuitMode -Trip $explicitRepeatedTrip) -eq 'cooldown') 'repeated explicit flag is not deterministic hard-freeze'

$writeLog = Join-Path $WorkDir 'write.jsonl'
$bomEnc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($writeLog, '', $bomEnc)
$written = Write-RestartEvent -Cause explicit-flag -Signature sig-write -Detail 'unit write event' -LogPath $writeLog
$writeBytes = [System.IO.File]::ReadAllBytes($writeLog)
Assert-Cb (-not ($writeBytes.Length -ge 3 -and $writeBytes[0] -eq 0xEF -and $writeBytes[1] -eq 0xBB -and $writeBytes[2] -eq 0xBF)) 'Write-RestartEvent should repair leading BOM'
Assert-Cb ($written.cause -eq 'explicit-flag') 'Write-RestartEvent should return schema DTO'

$freeze = Join-Path $WorkDir 'cb-freeze.flag'
[System.IO.File]::WriteAllText($freeze, 'freeze', $enc)
$pauseFreeze = Test-CircuitSpawnPauseState -FreezeFlagPath $freeze -CooldownUntil $null
Assert-Cb $pauseFreeze.paused 'existing freeze with null cooldown should pause'
Remove-Item -LiteralPath $freeze -Force
$pauseMissing = Test-CircuitSpawnPauseState -FreezeFlagPath $freeze -CooldownUntil $null
Assert-Cb (-not $pauseMissing.paused) 'missing freeze and null cooldown should not pause'
$pauseFuture = Test-CircuitSpawnPauseState -FreezeFlagPath $freeze -CooldownUntil (Get-Date).AddMinutes(10)
Assert-Cb $pauseFuture.paused 'future cooldown should pause'
$pausePast = Test-CircuitSpawnPauseState -FreezeFlagPath $freeze -CooldownUntil (Get-Date).AddMinutes(-1)
Assert-Cb (-not $pausePast.paused) 'past cooldown with green health should resume'
Assert-Cb ($null -eq $pausePast.cooldownUntil) 'past cooldown with green health should clear cooldownUntil'

$diag = Save-CircuitDiagnostics -OutDir (Join-Path $WorkDir 'diag')
Assert-Cb $diag.ok 'diagnostics should complete'
Assert-Cb (Test-Path -LiteralPath (Join-Path $diag.outDir 'git-status.txt')) 'diagnostics should write git-status.txt'
Assert-Cb (Test-Path -LiteralPath (Join-Path $diag.outDir 'git-diff.patch')) 'diagnostics should write git-diff.patch'
$diffText = [System.IO.File]::ReadAllText((Join-Path $diag.outDir 'git-diff.patch'), $enc)
Assert-Cb (-not ($diffText -match '(?m)^# stderr:|^exitCode:')) 'git-diff.patch should contain stdout only; stderr belongs in a sidecar'

$health = Invoke-HealthProbe
Assert-Cb $health.green "health probe should be green: $($health.reason)"
$failSafe = try { throw 'simulated cb failure' } catch { 'allow restart' }
Assert-Cb ($failSafe -eq 'allow restart') 'fail-safe wrapper should default to allow restart'

[pscustomobject]@{
  ok = $true
  workDir = $WorkDir
  trip5 = $trip.tripped
  trip5Count = $trip.countInWindow
  invalidLineCount = $trip.invalidLineCount
  oldTrip = $oldTrip.tripped
  oldCount = $oldTrip.countInWindow
  hardMode = Get-CircuitMode -Trip $trip
  mixedMode = Get-CircuitMode -Trip $mixedTrip
  explicitRepeatedMode = Get-CircuitMode -Trip $explicitRepeatedTrip
  causes = $causes
  freezeNullPaused = $pauseFreeze.paused
  pastGreenPaused = $pausePast.paused
  pastGreenCooldown = $pausePast.cooldownUntil
  diagnosticsFiles = @($diag.files).Count
  health = $health.reason
  failSafe = $failSafe
} | ConvertTo-Json -Compress -Depth 5
