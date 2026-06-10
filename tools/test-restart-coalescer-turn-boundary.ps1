#Requires -Version 5.1
# Regression coverage for deferred restart apply only at a turn boundary during DONE finalization.

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'driver\80-loop-preflight.ps1')

$script:pass = 0
$script:fail = 0

function Check-RestartBoundary {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    $Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $detail = ''
    if ($null -ne $Actual) {
      try { $detail = ' actual=' + (($Actual | Format-List * | Out-String).Trim()) } catch { $detail = ' actual=' + [string]$Actual }
      if ($detail.Length -gt 600) { $detail = $detail.Substring(0,600) + '...<truncated>' }
    }
    Write-Host ("FAIL " + $Name + $detail) -ForegroundColor Red
  }
}

function New-TestDeferredRestart {
  param(
    [Parameter(Mandatory=$true)][string]$DeferredPath,
    [int]$AgeSec = 0
  )
  $stamp = (Get-Date).ToUniversalTime().AddSeconds(-1 * $AgeSec).ToString('o')
  [System.IO.File]::WriteAllText($DeferredPath, $stamp, (New-Object System.Text.UTF8Encoding($false)))
}

$testRoot = Join-Path (Join-Path $root 'control') ('restart-coalescer-boundary-test-' + [guid]::NewGuid().ToString('N'))
$messages = New-Object 'System.Collections.Generic.List[string]'
$sink = { param([string]$Text) [void]$messages.Add($Text) }

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $defer = Join-Path $testRoot 'restart.deferred'
  $flag = Join-Path $testRoot 'restart.flag'

  $stubState = [pscustomobject][ordered]@{ completion_finalizing = $true }
  Check-RestartBoundary 'completion flag is detected from state' (Test-RestartCoalescerCompletionFinalizing -ChannelState $stubState) $stubState

  New-TestDeferredRestart -DeferredPath $defer -AgeSec 700
  $duringFinalization = Invoke-RestartCoalescerDeferredApply -DeferredPath $defer -FlagPath $flag -AgeSec 700 -QuietSec 0 -Busy:$true -LiveAgent:$false -PlanHasWork:$true -CompletionFinalizing:$true -MaxDeferSec 600 -CompletionBackstopSec 1800 -FailsafeQuietSec 300 -MessageSink $sink
  Check-RestartBoundary 'expired cap is held during DONE finalization' (
    [string]$duringFinalization.action -eq 'hold' -and
    [string]$duringFinalization.reason -eq 'completion_finalizing' -and
    (Test-Path -LiteralPath $defer) -and
    -not (Test-Path -LiteralPath $flag)
  ) $duringFinalization

  $afterBoundary = Invoke-RestartCoalescerDeferredApply -DeferredPath $defer -FlagPath $flag -AgeSec 700 -QuietSec 0 -Busy:$false -LiveAgent:$false -PlanHasWork:$true -CompletionFinalizing:$false -MaxDeferSec 600 -CompletionBackstopSec 1800 -FailsafeQuietSec 300 -MessageSink $sink
  Check-RestartBoundary 'held restart applies at next loop top after finalization clears' (
    [string]$afterBoundary.action -eq 'apply' -and
    [string]$afterBoundary.reason -eq 'max_defer' -and
    -not (Test-Path -LiteralPath $defer) -and
    (Test-Path -LiteralPath $flag)
  ) $afterBoundary

  Remove-Item -LiteralPath $flag -Force
  New-TestDeferredRestart -DeferredPath $defer -AgeSec 601
  $idleOldCap = Invoke-RestartCoalescerDeferredApply -DeferredPath $defer -FlagPath $flag -AgeSec 601 -QuietSec 0 -Busy:$false -LiveAgent:$false -PlanHasWork:$true -CompletionFinalizing:$false -MaxDeferSec 600 -CompletionBackstopSec 1800 -FailsafeQuietSec 300 -MessageSink $sink
  Check-RestartBoundary 'idle deferred restart still applies at old 600s cap' (
    [string]$idleOldCap.action -eq 'apply' -and
    [string]$idleOldCap.reason -eq 'max_defer' -and
    (Test-Path -LiteralPath $flag)
  ) $idleOldCap

  Remove-Item -LiteralPath $flag -Force
  New-TestDeferredRestart -DeferredPath $defer -AgeSec 1800
  $backstop = Invoke-RestartCoalescerDeferredApply -DeferredPath $defer -FlagPath $flag -AgeSec 1800 -QuietSec 0 -Busy:$true -LiveAgent:$false -PlanHasWork:$true -CompletionFinalizing:$true -MaxDeferSec 600 -CompletionBackstopSec 1800 -FailsafeQuietSec 300 -MessageSink $sink
  Check-RestartBoundary 'DONE-finalization hold has 1800s runaway backstop' (
    [string]$backstop.action -eq 'apply' -and
    [string]$backstop.reason -eq 'completion_backstop' -and
    (Test-Path -LiteralPath $flag)
  ) $backstop

  $wrapper = Get-Content -LiteralPath (Join-Path $root 'driver\86-loop-completion.ps1') -Raw -Encoding UTF8
  Check-RestartBoundary 'completion wrapper sets and clears completion_finalizing in finally' (
    $wrapper -match 'Set-DriverCompletionFinalizing\s+-Active\s+\$true' -and
    $wrapper -match 'finally' -and
    $wrapper -match 'Set-DriverCompletionFinalizing\s+-Active\s+\$false'
  ) $wrapper
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
  Write-Host ("FAILURES: " + $script:fail) -ForegroundColor Red
  exit 1
}

Write-Host ("restart coalescer turn-boundary tests passed: " + $script:pass)
