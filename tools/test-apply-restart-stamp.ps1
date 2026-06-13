#Requires -Version 5.1
# test-apply-restart-stamp.ps1 -- unit checks for apply restart sidecar.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 8) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function New-TestRoot {
  $p = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-apply-stamp-test-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $p 'control') -Force | Out-Null
  return $p
}

function Remove-TestRoot {
  param([string]$Path)
  if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$testRoots = New-Object System.Collections.ArrayList

try {
  $r1 = New-TestRoot; [void]$testRoots.Add($r1)
  $created = New-ApplyRestartStamp -Root $r1 -TaskId 'task-a' -Touched @('driver.ps1','config.json') -Reason 'test'
  $createdPathExists = Test-Path -LiteralPath $created.path
  $first = Consume-ApplyRestartStamp -Root $r1 -TaskId 'task-a'
  $second = Consume-ApplyRestartStamp -Root $r1 -TaskId 'task-a'
  Check 'happy create returns ok' ([bool]$created.ok -and $createdPathExists) $created
  Check 'happy consume ok' ([bool]$first.ok -and [string]$first.task_id -eq 'task-a' -and @($first.touched).Count -ge 1) $first
  Check 'one-shot second consume rejected' (-not [bool]$second.ok -and [string]$second.reason -eq 'missing-stamp') $second

  $r2 = New-TestRoot; [void]$testRoots.Add($r2)
  New-ApplyRestartStamp -Root $r2 -TaskId 'task-a' -Touched @('lib\common.ps1') -Reason 'test' | Out-Null
  $mismatch = Consume-ApplyRestartStamp -Root $r2 -TaskId 'task-b'
  Check 'task_id mismatch rejected' (-not [bool]$mismatch.ok -and [string]$mismatch.reason -eq 'task-id-mismatch') $mismatch

  $r3 = New-TestRoot; [void]$testRoots.Add($r3)
  New-ApplyRestartStamp -Root $r3 -TaskId 'task-a' -Touched @('driver\60-startup.ps1') -Reason 'test' -CreatedAtUtc ([DateTimeOffset]::UtcNow.AddMinutes(-120)) -TtlMinutes 90 | Out-Null
  $expired = Consume-ApplyRestartStamp -Root $r3 -TaskId 'task-a'
  Check 'TTL expired rejected' (-not [bool]$expired.ok -and [string]$expired.reason -eq 'expired') $expired

  $r4 = New-TestRoot; [void]$testRoots.Add($r4)
  [System.IO.File]::WriteAllText((Get-ApplyRestartStampPath -Root $r4), '{not json', (New-Object System.Text.UTF8Encoding($false)))
  $corrupt = Consume-ApplyRestartStamp -Root $r4 -TaskId 'task-a'
  Check 'corrupt JSON rejected' (-not [bool]$corrupt.ok -and [string]$corrupt.reason -eq 'corrupt-json') $corrupt

  $r5 = New-TestRoot; [void]$testRoots.Add($r5)
  $missing = Consume-ApplyRestartStamp -Root $r5 -TaskId 'task-a'
  Check 'missing stamp rejected' (-not [bool]$missing.ok -and [string]$missing.reason -eq 'missing-stamp') $missing

  # overwrite path: create stamp then create again on same root -- exercises File.Replace
  $r7 = New-TestRoot; [void]$testRoots.Add($r7)
  New-ApplyRestartStamp -Root $r7 -TaskId 'task-a' -Touched @('driver.ps1') -Reason 'test' | Out-Null
  $overwrite = New-ApplyRestartStamp -Root $r7 -TaskId 'task-b' -Touched @('lib\common.ps1') -Reason 'overwrite'
  $overwroteExists = Test-Path -LiteralPath $overwrite.path
  Check 'overwrite existing stamp succeeds' ([bool]$overwrite.ok -and $overwroteExists) $overwrite

  $r6 = New-TestRoot; [void]$testRoots.Add($r6)
  try {
    New-ApplyRestartStamp -Root $r6 -TaskId 'task-a' -Touched @('config.json') -Reason 'test' | Out-Null
    $noPs1Created = $true
  } catch {
    $noPs1Created = $false
  }
  Check 'create requires ps1 evidence' (-not $noPs1Created)
} finally {
  foreach ($tr in @($testRoots)) { Remove-TestRoot -Path ([string]$tr) }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
