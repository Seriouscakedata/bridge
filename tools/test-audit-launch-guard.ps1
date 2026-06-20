#Requires -Version 5.1
# test-audit-launch-guard.ps1 -- attempt-level audit launch admission guard.

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgeRoot = $root
. (Join-Path $root 'driver\10-maintenance.ps1')

$script:pass = 0
$script:fail = 0

function Check-AuditLaunchGuard {
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
    $suffix = ''
    if ($null -ne $Actual) {
      $text = ''
      try { $text = if ($Actual -is [string]) { [string]$Actual } else { ($Actual | Format-List * | Out-String).Trim() } } catch { $text = [string]$Actual }
      if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...<truncated>' }
      $suffix = ' actual=' + $text
    }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Read-AuditLaunchEntries {
  param([string]$LedgerPath)
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return @() }
  return @([System.IO.File]::ReadAllLines($LedgerPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertFrom-AuditLaunchJsonLine -Line $_ })
}

function New-SyntheticAuditScript {
  param([ValidateSet('success','not_idle','failed')][string]$Mode)
  if ($Mode -eq 'not_idle') {
    return @'
function Wait-BridgeIdle {
  param([string]$StateFile, [int]$MaxMinutes = 0, [int]$PollSeconds = 0, [int]$StablePolls = 1)
  return $false
}
function Invoke-BridgeAudit {
  throw 'Invoke-BridgeAudit should not run when bridge is not idle'
}
'@
  }
  if ($Mode -eq 'failed') {
    return @'
function Wait-BridgeIdle {
  param([string]$StateFile, [int]$MaxMinutes = 0, [int]$PollSeconds = 0, [int]$StablePolls = 1)
  return $true
}
function Invoke-BridgeAudit {
  param([string]$BridgePath, [string]$Channel)
  throw 'synthetic audit failure'
}
'@
  }
  return @'
function Wait-BridgeIdle {
  param([string]$StateFile, [int]$MaxMinutes = 0, [int]$PollSeconds = 0, [int]$StablePolls = 1)
  return $true
}
function Invoke-BridgeAudit {
  param([string]$BridgePath, [string]$Channel)
  $dir = Join-Path $BridgePath 'audit'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $report = Join-Path $dir 'synthetic-ok.json'
  [System.IO.File]::WriteAllText($report, '{"status":"ok"}', (New-Object System.Text.UTF8Encoding($false)))
  return [pscustomobject]@{ status = 'ok'; report_json = $report; runtime_sec = 1.25 }
}
'@
}

function Invoke-SyntheticAuditRunnerCase {
  param(
    [ValidateSet('success','not_idle','failed')][string]$Mode,
    [string]$Root,
    [string]$RunnerPath
  )
  $caseRoot = Join-Path $Root ('runner-' + $Mode + '-' + [guid]::NewGuid().ToString('N'))
  $driverDir = Join-Path $caseRoot 'driver'
  $toolsDir = Join-Path $caseRoot 'tools'
  $stateDir = Join-Path (Join-Path $caseRoot 'channels') 'main'
  New-Item -ItemType Directory -Path $driverDir,$toolsDir,$stateDir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $bridgeRoot 'driver\10-maintenance.ps1') -Destination (Join-Path $driverDir '10-maintenance.ps1') -Force
  [System.IO.File]::WriteAllText((Join-Path $toolsDir 'audit.ps1'), (New-SyntheticAuditScript -Mode $Mode), (New-Object System.Text.UTF8Encoding($true)))
  $statePath = Join-Path $stateDir 'state.json'
  [System.IO.File]::WriteAllText($statePath, '{"status":"idle","agent_pid":0,"active_jobs":[]}', (New-Object System.Text.UTF8Encoding($false)))
  $caseAuditDir = Join-Path $caseRoot 'audit'
  New-Item -ItemType Directory -Path $caseAuditDir -Force | Out-Null
  $admission = Request-AuditLaunchAdmission -AuditDir $caseAuditDir -Channel 'main' -MaxAttempts 5 -WindowMinutes 60 -LockTtlMinutes 5
  $waitMarker = Join-Path $caseAuditDir 'audit.waiting'
  [System.IO.File]::WriteAllText($waitMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $RunnerPath -BridgePath $caseRoot -StateFile $statePath -MaxWaitMinutes 0 -WaitMarker $waitMarker -Channel 'main' -RunId ([string]$admission.run_id) 2>&1
  $exitCode = $LASTEXITCODE
  $ledgerPath = Join-Path $caseAuditDir 'audit.launches.jsonl'
  $entries = Read-AuditLaunchEntries -LedgerPath $ledgerPath
  return [pscustomobject]@{
    mode       = $Mode
    root       = $caseRoot
    admission  = $admission
    exit_code  = $exitCode
    entries    = @($entries)
    output     = @($output)
    ledger     = $ledgerPath
  }
}

$tmpRoot = Join-Path (Join-Path $root 'control') ('test-audit-launch-guard-' + [guid]::NewGuid().ToString('N'))
$auditDir = Join-Path $tmpRoot 'audit'

try {
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null

  Check-AuditLaunchGuard 'Request-AuditLaunchAdmission is available' ([bool](Get-Command Request-AuditLaunchAdmission -ErrorAction SilentlyContinue))
  Check-AuditLaunchGuard 'atomic CreateNew lock is used by source' ((Get-Content -LiteralPath (Join-Path $root 'driver\10-maintenance.ps1') -Raw -Encoding UTF8) -match 'FileMode\]::CreateNew')

  $first = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  $second = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  $third = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5

  Check-AuditLaunchGuard 'first repeated-due audit launch is admitted' ([bool]$first.allowed -and [int]$first.count -eq 1) $first
  Check-AuditLaunchGuard 'second repeated-due audit launch is admitted up to limit' ([bool]$second.allowed -and [int]$second.count -eq 2) $second
  Check-AuditLaunchGuard 'third repeated-due audit launch is denied by attempt window' ((-not [bool]$third.allowed) -and [string]$third.reason -eq 'max_attempts_per_window' -and [int]$third.count -eq 2) $third

  $ledgerPath = Join-Path $auditDir 'audit.launches.jsonl'
  $entries = @([System.IO.File]::ReadAllLines($ledgerPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertFrom-AuditLaunchJsonLine -Line $_ })
  $started = @($entries | Where-Object { [string]$_.decision -eq 'started' })
  $denied = @($entries | Where-Object { [string]$_.decision -eq 'denied' })
  Check-AuditLaunchGuard 'ledger records exactly two started attempts before denying' ($started.Count -eq 2) $entries
  Check-AuditLaunchGuard 'ledger records deny reason for suppressed repeated due' (($denied.Count -ge 1) -and (@($denied | Where-Object { [string]$_.reason -eq 'max_attempts_per_window' }).Count -eq 1)) $entries

  Remove-Item -LiteralPath $auditDir -Recurse -Force
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
  $lockPath = Join-Path $auditDir 'audit.launch.lock'
  $activeLockObject = [ordered]@{
    token      = 'active-test'
    channel    = 'main'
    pid        = [int]$PID
    created_at = (Get-Date).ToUniversalTime().ToString('o')
  }
  $activeLock = ConvertTo-AuditLaunchJsonLine -Object $activeLockObject
  [System.IO.File]::WriteAllText($lockPath, $activeLock, (New-Object System.Text.UTF8Encoding($false)))
  $activeDenied = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'active pid launch lock denies concurrent launch' ((-not [bool]$activeDenied.allowed) -and [string]$activeDenied.reason -eq 'launch_lock_active') $activeDenied

  Remove-Item -LiteralPath $lockPath -Force
  $staleLockObject = [ordered]@{
    token      = 'stale-test'
    channel    = 'main'
    pid        = 999999
    created_at = (Get-Date).ToUniversalTime().ToString('o')
  }
  $staleLock = ConvertTo-AuditLaunchJsonLine -Object $staleLockObject
  [System.IO.File]::WriteAllText($lockPath, $staleLock, (New-Object System.Text.UTF8Encoding($false)))
  $staleAllowed = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'stale dead-pid launch lock is cleared before admission' ([bool]$staleAllowed.allowed -and [string]$staleAllowed.reason -eq '') $staleAllowed

  Remove-Item -LiteralPath $auditDir -Recurse -Force
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
  $lockPath = Join-Path $auditDir 'audit.launch.lock'
  $oldLockObject = [ordered]@{
    token      = 'old-test'
    channel    = 'main'
    pid        = [int]$PID
    created_at = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
  }
  $oldLock = ConvertTo-AuditLaunchJsonLine -Object $oldLockObject
  [System.IO.File]::WriteAllText($lockPath, $oldLock, (New-Object System.Text.UTF8Encoding($false)))
  $oldAllowed = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'stale ttl launch lock is cleared even when pid is alive' ([bool]$oldAllowed.allowed -and [string]$oldAllowed.reason -eq '') $oldAllowed

  $source = Get-Content -LiteralPath (Join-Path $root 'driver\10-maintenance.ps1') -Raw -Encoding UTF8
  $admissionIndex = $source.IndexOf('Request-AuditLaunchAdmission -AuditDir $auditDir')
  $waitWriteIndex = $source.IndexOf('WriteAllText($waitMarker')
  Check-AuditLaunchGuard 'Start-AuditIfDue records launch admission before wait marker write' ($admissionIndex -ge 0 -and $waitWriteIndex -gt $admissionIndex) @{ admissionIndex = $admissionIndex; waitWriteIndex = $waitWriteIndex }

  $runnerPath = Join-Path $root 'tools\audit-runner.ps1'
  $successCase = Invoke-SyntheticAuditRunnerCase -Mode 'success' -Root $tmpRoot -RunnerPath $runnerPath
  $successStarted = @($successCase.entries | Where-Object { [string]$_.decision -eq 'started' })
  $successTerminal = @($successCase.entries | Where-Object { [string]$_.decision -eq 'completed_ok' })
  Check-AuditLaunchGuard 'synthetic success runner exits cleanly' ([int]$successCase.exit_code -eq 0) $successCase
  Check-AuditLaunchGuard 'synthetic success writes started to completed_ok' ($successStarted.Count -eq 1 -and $successTerminal.Count -eq 1) $successCase.entries
  Check-AuditLaunchGuard 'synthetic success pairs run_id' ($successStarted.Count -eq 1 -and $successTerminal.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$successStarted[0].run_id) -and [string]$successStarted[0].run_id -eq [string]$successTerminal[0].run_id) $successCase.entries
  Check-AuditLaunchGuard 'completed_ok terminal has mandatory fields' ($successTerminal.Count -eq 1 -and [int]$successTerminal[0].pid -gt 0 -and [string]$successTerminal[0].channel -eq 'main' -and -not [string]::IsNullOrWhiteSpace([string]$successTerminal[0].report_path) -and [double]$successTerminal[0].runtime_seconds -gt 0 -and [string]$successTerminal[0].exit_reason -eq 'ok') $successTerminal
  Check-AuditLaunchGuard 'completed_ok terminal does not inflate attempt count' ((Get-AuditLaunchAttemptCount -AuditDir (Join-Path $successCase.root 'audit') -SinceUtc ((Get-Date).ToUniversalTime().AddHours(-1)) -Channel 'main') -eq 1) $successCase.entries

  $skipCase = Invoke-SyntheticAuditRunnerCase -Mode 'not_idle' -Root $tmpRoot -RunnerPath $runnerPath
  $skipStarted = @($skipCase.entries | Where-Object { [string]$_.decision -eq 'started' })
  $skipTerminal = @($skipCase.entries | Where-Object { [string]$_.decision -eq 'skipped_not_idle' })
  Check-AuditLaunchGuard 'synthetic not-idle runner exits cleanly' ([int]$skipCase.exit_code -eq 0) $skipCase
  Check-AuditLaunchGuard 'synthetic not-idle writes started to skipped_not_idle' ($skipStarted.Count -eq 1 -and $skipTerminal.Count -eq 1) $skipCase.entries
  Check-AuditLaunchGuard 'skipped_not_idle pairs run_id and reason' ($skipStarted.Count -eq 1 -and $skipTerminal.Count -eq 1 -and [string]$skipStarted[0].run_id -eq [string]$skipTerminal[0].run_id -and [string]$skipTerminal[0].exit_reason -match '^not_idle_after_') $skipCase.entries
  Check-AuditLaunchGuard 'skipped_not_idle terminal has mandatory fields' ($skipTerminal.Count -eq 1 -and [int]$skipTerminal[0].pid -gt 0 -and [string]$skipTerminal[0].channel -eq 'main' -and [double]$skipTerminal[0].runtime_seconds -ge 0 -and -not [string]::IsNullOrWhiteSpace([string]$skipTerminal[0].exit_reason)) $skipTerminal

  $failedCase = Invoke-SyntheticAuditRunnerCase -Mode 'failed' -Root $tmpRoot -RunnerPath $runnerPath
  $failedStarted = @($failedCase.entries | Where-Object { [string]$_.decision -eq 'started' })
  $failedTerminal = @($failedCase.entries | Where-Object { [string]$_.decision -eq 'failed' })
  Check-AuditLaunchGuard 'synthetic failed runner exits nonzero' ([int]$failedCase.exit_code -ne 0) $failedCase
  Check-AuditLaunchGuard 'synthetic failed runner writes started to failed' ($failedStarted.Count -eq 1 -and $failedTerminal.Count -eq 1) $failedCase.entries
  Check-AuditLaunchGuard 'failed terminal pairs run_id and exception reason' ($failedStarted.Count -eq 1 -and $failedTerminal.Count -eq 1 -and [string]$failedStarted[0].run_id -eq [string]$failedTerminal[0].run_id -and [string]$failedTerminal[0].exit_reason -match 'synthetic audit failure') $failedCase.entries
  Check-AuditLaunchGuard 'failed terminal has mandatory fields' ($failedTerminal.Count -eq 1 -and [int]$failedTerminal[0].pid -gt 0 -and [string]$failedTerminal[0].channel -eq 'main' -and [double]$failedTerminal[0].runtime_seconds -ge 0 -and -not [string]::IsNullOrWhiteSpace([string]$failedTerminal[0].exit_reason)) $failedTerminal

  $timeoutAuditDir = Join-Path $tmpRoot 'timeout-reserved\audit'
  Write-AuditLaunchLedgerEntry -AuditDir $timeoutAuditDir -Channel 'main' -Decision 'runner_timeout' -Reason 'reserved_test' -ProcessId $PID -RunId ([guid]::NewGuid().ToString()) -RuntimeSeconds 2 -ExitReason 'reserved_schema_test' | Out-Null
  $timeoutEntries = Read-AuditLaunchEntries -LedgerPath (Join-Path $timeoutAuditDir 'audit.launches.jsonl')
  Check-AuditLaunchGuard 'runner_timeout state is accepted by launch ledger schema' (@($timeoutEntries | Where-Object { [string]$_.decision -eq 'runner_timeout' }).Count -eq 1) $timeoutEntries

  $staleAuditDir1 = Join-Path $tmpRoot 'stale-reconcile-dead-old\audit'
  New-Item -ItemType Directory -Path $staleAuditDir1 -Force | Out-Null
  $staleLedger1 = Join-Path $staleAuditDir1 'audit.launches.jsonl'
  $staleRunId1a = [guid]::NewGuid().ToString()
  $staleRunId1b = [guid]::NewGuid().ToString()
  $s1a = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $staleRunId1a; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  $s1b = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddMinutes(-4).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $staleRunId1b; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  [System.IO.File]::WriteAllText($staleLedger1, ($s1a + "`n" + $s1b + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $staleAdmit = Request-AuditLaunchAdmission -AuditDir $staleAuditDir1 -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5 -StaleStartedTtlMinutes 2
  Check-AuditLaunchGuard 'dead-pid stale started entries reconciled then next audit admitted' ([bool]$staleAdmit.allowed) $staleAdmit
  $staleEntries1 = Read-AuditLaunchEntries -LedgerPath $staleLedger1
  $abandonedCount1 = @($staleEntries1 | Where-Object { [string]$_.decision -eq 'abandoned' }).Count
  Check-AuditLaunchGuard 'abandoned entries written for each reconciled stale-started' ($abandonedCount1 -eq 2) $staleEntries1

  $staleAuditDir2 = Join-Path $tmpRoot 'stale-reconcile-live-pid\audit'
  New-Item -ItemType Directory -Path $staleAuditDir2 -Force | Out-Null
  $staleLedger2 = Join-Path $staleAuditDir2 'audit.launches.jsonl'
  $liveRunId2a = [guid]::NewGuid().ToString()
  $liveRunId2b = [guid]::NewGuid().ToString()
  $l2a = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = [int]$PID; run_id = $liveRunId2a; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  $l2b = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddMinutes(-4).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = [int]$PID; run_id = $liveRunId2b; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  [System.IO.File]::WriteAllText($staleLedger2, ($l2a + "`n" + $l2b + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $liveDenied = Request-AuditLaunchAdmission -AuditDir $staleAuditDir2 -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5 -StaleStartedTtlMinutes 2
  Check-AuditLaunchGuard 'live-pid started entries block new audit launch storm guard intact' ((-not [bool]$liveDenied.allowed) -and [string]$liveDenied.reason -eq 'max_attempts_per_window') $liveDenied

  $staleAuditDir3 = Join-Path $tmpRoot 'stale-reconcile-dead-recent\audit'
  New-Item -ItemType Directory -Path $staleAuditDir3 -Force | Out-Null
  $staleLedger3 = Join-Path $staleAuditDir3 'audit.launches.jsonl'
  $recentRunId3a = [guid]::NewGuid().ToString()
  $recentRunId3b = [guid]::NewGuid().ToString()
  $r3a = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $recentRunId3a; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  $r3b = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddSeconds(-45).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $recentRunId3b; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  [System.IO.File]::WriteAllText($staleLedger3, ($r3a + "`n" + $r3b + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $recentDenied = Request-AuditLaunchAdmission -AuditDir $staleAuditDir3 -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5 -StaleStartedTtlMinutes 2
  Check-AuditLaunchGuard 'dead-pid started within TTL not reconciled and still blocks' ((-not [bool]$recentDenied.allowed) -and [string]$recentDenied.reason -eq 'max_attempts_per_window') $recentDenied

  $staleAuditDir4 = Join-Path $tmpRoot 'stale-reconcile-corrupt-lines\audit'
  New-Item -ItemType Directory -Path $staleAuditDir4 -Force | Out-Null
  $staleLedger4 = Join-Path $staleAuditDir4 'audit.launches.jsonl'
  $badTsRunId4 = [guid]::NewGuid().ToString()
  $deadRunId4 = [guid]::NewGuid().ToString()
  $oldDenied4 = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = '2026-06-10T03:27:59.9026379Z'; channel = 'main'; decision = 'denied'; reason = 'max_attempts_per_window'; max_attempts = 2; window_minutes = 60; pid = 27960; run_id = ''; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  $badTsStarted4 = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = 'not-a-date'; channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $badTsRunId4; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  $deadStarted4 = ConvertTo-AuditLaunchJsonLine -Object ([ordered]@{ ts = (Get-Date).ToUniversalTime().AddMinutes(-4).ToString('o'); channel = 'main'; decision = 'started'; reason = ''; max_attempts = 2; window_minutes = 60; pid = 999998; run_id = $deadRunId4; report_path = ''; runtime_seconds = 0; runtime = '00:00:00'; exit_reason = '' })
  [System.IO.File]::WriteAllText($staleLedger4, ("{broken-json`n" + $oldDenied4 + "`n" + $badTsStarted4 + "`n" + $deadStarted4 + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $corruptAllowed = Request-AuditLaunchAdmission -AuditDir $staleAuditDir4 -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5 -StaleStartedTtlMinutes 2
  Check-AuditLaunchGuard 'corrupt legacy launch ledger lines do not abort admission' ([bool]$corruptAllowed.allowed) $corruptAllowed
  $corruptEntries4 = Read-AuditLaunchEntries -LedgerPath $staleLedger4
  Check-AuditLaunchGuard 'valid dead stale-start is still abandoned with corrupt neighbors' (@($corruptEntries4 | Where-Object { [string]$_.decision -eq 'abandoned' -and [string]$_.run_id -eq $deadRunId4 }).Count -eq 1) $corruptEntries4
  $corruptLog4 = Join-Path $staleAuditDir4 'audit.log'
  $corruptWarnings4 = @()
  if (Test-Path -LiteralPath $corruptLog4) {
    $corruptWarnings4 = @(Get-Content -LiteralPath $corruptLog4 -Encoding UTF8 | Select-String -Pattern 'audit launch stale-start reconcile skipped corrupt_lines=1; invalid_timestamps=1')
  }
  Check-AuditLaunchGuard 'corrupt reconciliation writes one summarized warning' ($corruptWarnings4.Count -eq 1) $corruptWarnings4
} finally {
  if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
  Write-Host ("FAILURES: " + $script:fail) -ForegroundColor Red
  exit 1
}

Write-Host ("audit launch guard tests passed: " + $script:pass)
