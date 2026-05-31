# supervisor_restart_limit_test.ps1 -- focused self-test for supervisor restart limiter.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\supervisor-restart-limit.ps1')

function Assert-RestartLimit {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$settings = [pscustomobject]@{
  maxPerHour = 10
  windowMin = 60
  cooldownMin = 30
}
$state = New-SupervisorRestartLimitState
$now = [datetime]'2026-05-31T12:00:00Z'
$log = @()
$messages = @()
$pushes = @()

$allowed = @()
1..10 | ForEach-Object {
  $allowed += (Test-SupervisorRestartAllowed -State $state -Key 'server' -Settings $settings -Now $now.AddMinutes($_ - 1) `
    -LogCallback { param($m) $script:log += $m } `
    -MessageCallback { param($m) $script:messages += $m } `
    -PushCallback { param($m) $script:pushes += $m })
}
Assert-RestartLimit ((@($allowed | Where-Object { $_.allowed }).Count) -eq 10) 'first 10 restart attempts should be allowed'
Assert-RestartLimit (($state['server'].attempts.Count) -eq 10) 'state should retain 10 attempts in the window'

$eleventh = Test-SupervisorRestartAllowed -State $state -Key 'server' -Settings $settings -Now $now.AddMinutes(10) `
  -LogCallback { param($m) $script:log += $m } `
  -MessageCallback { param($m) $script:messages += $m } `
  -PushCallback { param($m) $script:pushes += $m }
Assert-RestartLimit (-not $eleventh.allowed) '11th attempt should be blocked'
Assert-RestartLimit ($eleventh.status -eq 'entered-cooldown') '11th attempt should enter cooldown'
Assert-RestartLimit ($null -ne $eleventh.cooldownUntil) 'cooldown should have an expiry timestamp'
Assert-RestartLimit ((@($log).Count) -eq 1) 'entering cooldown should log once'
Assert-RestartLimit ((@($messages).Count) -eq 1) 'entering cooldown should notify operator once'
Assert-RestartLimit ((@($pushes).Count) -eq 1) 'entering cooldown should push once'

$active = Test-SupervisorRestartAllowed -State $state -Key 'server' -Settings $settings -Now $now.AddMinutes(11) `
  -LogCallback { param($m) $script:log += $m } `
  -MessageCallback { param($m) $script:messages += $m } `
  -PushCallback { param($m) $script:pushes += $m }
Assert-RestartLimit (-not $active.allowed) 'attempt inside cooldown should be blocked'
Assert-RestartLimit ($active.status -eq 'cooldown-active') 'attempt inside cooldown should report active cooldown'

$afterCooldown = Test-SupervisorRestartAllowed -State $state -Key 'server' -Settings $settings -Now $now.AddMinutes(41) `
  -LogCallback { param($m) $script:log += $m } `
  -MessageCallback { param($m) $script:messages += $m } `
  -PushCallback { param($m) $script:pushes += $m }
Assert-RestartLimit $afterCooldown.allowed 'attempt after cooldown should be allowed'
Assert-RestartLimit (($state['server'].attempts.Count) -eq 1) 'attempt history should reset after cooldown expires'

$driverAllowed = Test-SupervisorRestartAllowed -State $state -Key 'driver:main' -Settings $settings -Now $now
Assert-RestartLimit $driverAllowed.allowed 'driver key should be tracked independently'
Assert-RestartLimit (($state['driver:main'].attempts.Count) -eq 1) 'driver key should have independent attempt history'

$cfg = [pscustomobject]@{
  supervisor = [pscustomobject]@{
    restartLimitMaxPerHour = 7
    restartLimitWindowMin = 45
    restartLimitCooldownMin = 20
  }
}
$cfgSettings = Get-SupervisorRestartLimitSettings -Config $cfg
Assert-RestartLimit ($cfgSettings.maxPerHour -eq 7) 'config max should be honored'
Assert-RestartLimit ($cfgSettings.windowMin -eq 45) 'config window should be honored'
Assert-RestartLimit ($cfgSettings.cooldownMin -eq 20) 'config cooldown should be honored'

[pscustomobject]@{
  ok = $true
  allowedBeforeCooldown = @($allowed | Where-Object { $_.allowed }).Count
  eleventhAllowed = $eleventh.allowed
  eleventhStatus = $eleventh.status
  activeAllowed = $active.allowed
  activeStatus = $active.status
  afterCooldownAllowed = $afterCooldown.allowed
  serverAttemptsAfterResume = $state['server'].attempts.Count
  driverAttempts = $state['driver:main'].attempts.Count
  configMax = $cfgSettings.maxPerHour
  configWindowMin = $cfgSettings.windowMin
  configCooldownMin = $cfgSettings.cooldownMin
} | ConvertTo-Json -Compress -Depth 5
