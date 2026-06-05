# test-bridge-lock-telemetry.ps1 -- bridge lock telemetry and uncertain-timeout tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\common.ps1')

$script:pass = 0
$script:fail = 0

function Assert-BridgeLockTelemetry {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function New-TestException {
  param([string]$Message)
  return (New-Object System.Exception($Message))
}

try {
  $uncertainErr = New-TestException -Message 'bridge-lock-timeout-uncertain: caller must re-read state before retry'
  Assert-BridgeLockTelemetry 'uncertain timeout exception is detected' (
    (Test-BridgeLockUncertainTimeout -Err $uncertainErr) -eq $true
  )

  $plainErr = New-TestException -Message 'Could not acquire bridge lock within 15s'
  Assert-BridgeLockTelemetry 'plain timeout exception is not uncertain' (
    (Test-BridgeLockUncertainTimeout -Err $plainErr) -eq $false
  )

  Assert-BridgeLockTelemetry 'null exception is not uncertain' (
    (Test-BridgeLockUncertainTimeout -Err $null) -eq $false
  )

  $mutexName = 'Global\TestBridgeLockTelemetry' + ([guid]::NewGuid().ToString('N'))
  $readyPath = Join-Path $bridgeRoot ('control\test-bridge-lock-ready-' + ([guid]::NewGuid().ToString('N')) + '.tmp')
  $holder = Start-Job -ScriptBlock {
    param([string]$Name, [string]$ReadyFile)
    $heldMutex = New-Object System.Threading.Mutex($true, $Name)
    try {
      [System.IO.File]::WriteAllText($ReadyFile, 'ready')
      Start-Sleep -Seconds 3
    } finally {
      try { $heldMutex.ReleaseMutex() } catch {}
      $heldMutex.Dispose()
    }
  } -ArgumentList $mutexName, $readyPath
  $deadline = (Get-Date).AddSeconds(2)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $readyPath)) {
    Start-Sleep -Milliseconds 25
  }

  $timeoutMessage = ''
  try {
    Use-BridgeLock -MutexName $mutexName -TimeoutMs 100 -SlowThresholdMs 0 -Body { }
  } catch {
    $timeoutMessage = [string]$_.Exception.Message
  } finally {
    try { Stop-Job -Job $holder -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-Job -Job $holder -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue } catch {}
  }
  Assert-BridgeLockTelemetry 'occupied mutex timeout is uncertain' (
    $timeoutMessage -like '*bridge-lock-timeout-uncertain*'
  ) $timeoutMessage

  $normalBodyRan = $false
  Use-BridgeLock -MutexName ('Global\TestBridgeLockTelemetry' + ([guid]::NewGuid().ToString('N'))) -TimeoutMs 1000 -Body {
    $script:normalBodyRan = $true
  }
  Assert-BridgeLockTelemetry 'normal Use-BridgeLock body runs without error' (
    $normalBodyRan -eq $true
  )

  $logPath = Join-Path $bridgeRoot 'control\bridge-lock.log'
  $beforeLogCount = 0
  if (Test-Path -LiteralPath $logPath) {
    $beforeLogCount = @([System.IO.File]::ReadAllLines($logPath)).Count
  }
  Use-BridgeLock -MutexName ('Global\TestBridgeLockTelemetry' + ([guid]::NewGuid().ToString('N'))) -TimeoutMs 1000 -SlowThresholdMs 0 -Body { }
  $afterLines = @()
  if (Test-Path -LiteralPath $logPath) {
    $afterLines = @([System.IO.File]::ReadAllLines($logPath))
  }
  $newLines = @()
  if ($afterLines.Count -gt $beforeLogCount) {
    $newLines = @($afterLines[$beforeLogCount..($afterLines.Count - 1)])
  }
  Assert-BridgeLockTelemetry 'slow_lock telemetry line is written' (
    @($newLines | Where-Object { $_ -like '*slow_lock elapsed_ms=*' -and $_ -like '*pid=*' }).Count -ge 1
  ) ($newLines -join ' | ')

  $normalMutationRan = $false
  $normalMutation = Invoke-BridgeMutationWithReRead -SlowThresholdMs 0 -MutationBody {
    $script:normalMutationRan = $true
  } -ReReadBody {
    return 'should-not-reread'
  }
  Assert-BridgeLockTelemetry 'mutation wrapper succeeds on normal lock' (
    $normalMutation.success -eq $true -and $normalMutation.uncertain -eq $false -and $normalMutation.retried -eq $false -and $normalMutationRan -eq $true
  ) ($normalMutation | ConvertTo-Json -Compress)

  $script:rereadCalled = $false
  $uncertainMutation = Invoke-BridgeMutationWithReRead -MutationBody {
    throw 'bridge-lock-timeout-uncertain: simulated timeout'
  } -ReReadBody {
    $script:rereadCalled = $true
    return 'fresh-state'
  }
  Assert-BridgeLockTelemetry 'uncertain mutation calls reread before retry decision' (
    $uncertainMutation.success -eq $false -and $uncertainMutation.uncertain -eq $true -and $uncertainMutation.retried -eq $false -and $script:rereadCalled -eq $true -and [string]$uncertainMutation.reread_result -eq 'fresh-state'
  ) ($uncertainMutation | ConvertTo-Json -Compress)

  $ordinaryRethrown = $false
  $ordinaryWasUncertain = $true
  try {
    [void](Invoke-BridgeMutationWithReRead -MutationBody {
      throw 'ordinary failure'
    } -ReReadBody {
      return 'should-not-reread'
    })
  } catch {
    $ordinaryRethrown = $true
    $ordinaryWasUncertain = Test-BridgeLockUncertainTimeout -Err $_.Exception
  }
  Assert-BridgeLockTelemetry 'ordinary mutation error is rethrown' (
    $ordinaryRethrown -eq $true -and $ordinaryWasUncertain -eq $false
  )

  $content = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\common.ps1') -Raw -Encoding UTF8
  $helperMatch = [regex]::Match($content, '(?s)function Use-BridgeLock \{.*?function Get-RuntimeStateMetrics \{')
  $helperBlock = ''
  if ($helperMatch.Success) { $helperBlock = $helperMatch.Value }
  $forbiddenTokens = @(
    'Save-Backlog',
    'Write-BacklogJsonLine',
    'Set-Content',
    'Out-File',
    'New-Item',
    'Remove-Item',
    'Start-Process',
    'driver/81-loop-idle-claim.ps1',
    'driver/83-loop-agent-turn.ps1',
    'driver/86-loop-completion-cleanup.ps1'
  )
  $foundForbidden = @($forbiddenTokens | Where-Object { $helperBlock -like ('*' + $_ + '*') })
  Assert-BridgeLockTelemetry 'lock helper block avoids backlog writer and driver hot-path tokens' (
    $helperMatch.Success -and @($foundForbidden).Count -eq 0
  ) ($foundForbidden -join ',')
} catch {
  Write-Host ("FAIL: unexpected exception {0}" -f $_.Exception.Message)
  $script:fail++
}

Write-Host ("Bridge lock telemetry tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
