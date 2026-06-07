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
      try { $text = if ($Actual -is [string]) { [string]$Actual } else { ($Actual | ConvertTo-Json -Compress -Depth 6) } } catch { $text = [string]$Actual }
      if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...<truncated>' }
      $suffix = ' actual=' + $text
    }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
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
  $entries = @([System.IO.File]::ReadAllLines($ledgerPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
  $started = @($entries | Where-Object { [string]$_.decision -eq 'started' })
  $denied = @($entries | Where-Object { [string]$_.decision -eq 'denied' })
  Check-AuditLaunchGuard 'ledger records exactly two started attempts before denying' ($started.Count -eq 2) $entries
  Check-AuditLaunchGuard 'ledger records deny reason for suppressed repeated due' (($denied.Count -ge 1) -and (@($denied | Where-Object { [string]$_.reason -eq 'max_attempts_per_window' }).Count -eq 1)) $entries

  Remove-Item -LiteralPath $auditDir -Recurse -Force
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
  $lockPath = Join-Path $auditDir 'audit.launch.lock'
  $activeLock = [ordered]@{
    token      = 'active-test'
    channel    = 'main'
    pid        = [int]$PID
    created_at = (Get-Date).ToUniversalTime().ToString('o')
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($lockPath, $activeLock, (New-Object System.Text.UTF8Encoding($false)))
  $activeDenied = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'active pid launch lock denies concurrent launch' ((-not [bool]$activeDenied.allowed) -and [string]$activeDenied.reason -eq 'launch_lock_active') $activeDenied

  Remove-Item -LiteralPath $lockPath -Force
  $staleLock = [ordered]@{
    token      = 'stale-test'
    channel    = 'main'
    pid        = 999999
    created_at = (Get-Date).ToUniversalTime().ToString('o')
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($lockPath, $staleLock, (New-Object System.Text.UTF8Encoding($false)))
  $staleAllowed = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'stale dead-pid launch lock is cleared before admission' ([bool]$staleAllowed.allowed -and [string]$staleAllowed.reason -eq '') $staleAllowed

  Remove-Item -LiteralPath $auditDir -Recurse -Force
  New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
  $lockPath = Join-Path $auditDir 'audit.launch.lock'
  $oldLock = [ordered]@{
    token      = 'old-test'
    channel    = 'main'
    pid        = [int]$PID
    created_at = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($lockPath, $oldLock, (New-Object System.Text.UTF8Encoding($false)))
  $oldAllowed = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel 'main' -MaxAttempts 2 -WindowMinutes 60 -LockTtlMinutes 5
  Check-AuditLaunchGuard 'stale ttl launch lock is cleared even when pid is alive' ([bool]$oldAllowed.allowed -and [string]$oldAllowed.reason -eq '') $oldAllowed

  $source = Get-Content -LiteralPath (Join-Path $root 'driver\10-maintenance.ps1') -Raw -Encoding UTF8
  $admissionIndex = $source.IndexOf('Request-AuditLaunchAdmission -AuditDir $auditDir')
  $waitWriteIndex = $source.IndexOf('WriteAllText($waitMarker')
  Check-AuditLaunchGuard 'Start-AuditIfDue records launch admission before wait marker write' ($admissionIndex -ge 0 -and $waitWriteIndex -gt $admissionIndex) @{ admissionIndex = $admissionIndex; waitWriteIndex = $waitWriteIndex }
} finally {
  if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
  Write-Host ("FAILURES: " + $script:fail) -ForegroundColor Red
  exit 1
}

Write-Host ("audit launch guard tests passed: " + $script:pass)
