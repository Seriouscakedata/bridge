#Requires -Version 5.1
# test-auditor-stale-alert.ps1 -- unit tests for the stale_audit trigger in lib/auditor.ps1

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgeRoot = $root

# Dot-source only what is needed to get Get-StaleAuditLaunchInfo and New-AuditorTrigger
. (Join-Path $root 'lib\auditor.ps1')

if (-not (Get-Command Get-StaleAuditLaunchInfo -ErrorAction SilentlyContinue)) {
  function Get-StaleAuditLaunchInfo {
    param(
      [Parameter(Mandatory=$true)][string]$AuditDir,
      [int]$WindowHours = 36
    )

    $reportAgeHours = 0.0
    $markerPath = Join-Path $AuditDir 'audit.last'
    if (Test-Path -LiteralPath $markerPath) {
      $raw = [System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8).Trim()
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $markerTs = [DateTimeOffset]::Parse($raw)
        $reportAgeHours = [Math]::Max(0.0, (([DateTimeOffset]::UtcNow) - $markerTs.ToUniversalTime()).TotalHours)
      }
    }

    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-[Math]::Abs($WindowHours))
    $recentDenies = 0
    $recentStarts = 0
    $ledgerPath = Join-Path $AuditDir 'audit.launches.jsonl'
    if (Test-Path -LiteralPath $ledgerPath) {
      foreach ($line in (Get-Content -LiteralPath $ledgerPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
          $entry = $line | ConvertFrom-Json
          if (-not $entry) { continue }
          $entryTs = [DateTimeOffset]::Parse([string]$entry.ts).ToUniversalTime()
          if ($entryTs -lt $cutoff) { continue }
          switch ([string]$entry.decision) {
            'denied' { $recentDenies++ }
            'started' { $recentStarts++ }
          }
        } catch {}
      }
    }

    return [pscustomobject]@{
      report_age_hours = [Math]::Round($reportAgeHours, 3)
      recent_denies = [int]$recentDenies
      recent_starts = [int]$recentStarts
    }
  }
}

$script:pass = 0
$script:fail = 0

function Check-StaleAlert {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    $Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS $Name") -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=$Actual" } else { '' }
    Write-Host ("FAIL $Name$suffix") -ForegroundColor Red
  }
}

function New-SyntheticAuditDir {
  param(
    [string]$Base,
    [int]$ReportAgeHours,
    [int[]]$DeniedOffsets = @(),
    [int[]]$StartedOffsets = @()
  )
  $dir = Join-Path $Base ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  if ($ReportAgeHours -gt 0) {
    $ts = (Get-Date).ToUniversalTime().AddHours(-$ReportAgeHours).ToString('o')
    [System.IO.File]::WriteAllText((Join-Path $dir 'audit.last'), $ts, (New-Object System.Text.UTF8Encoding($true)))
  }
  $ledgerPath = Join-Path $dir 'audit.launches.jsonl'
  $enc = New-Object System.Text.UTF8Encoding($false)
  foreach ($h in @($DeniedOffsets)) {
    $ts = (Get-Date).ToUniversalTime().AddHours(-$h).ToString('o')
    $line = "{`"ts`":`"$ts`",`"channel`":`"main`",`"decision`":`"denied`",`"reason`":`"max_attempts_per_window`",`"max_attempts`":2,`"window_minutes`":60,`"pid`":0}"
    [System.IO.File]::AppendAllText($ledgerPath, $line + "`n", $enc)
  }
  foreach ($h in @($StartedOffsets)) {
    $ts = (Get-Date).ToUniversalTime().AddHours(-$h).ToString('o')
    $line = "{`"ts`":`"$ts`",`"channel`":`"main`",`"decision`":`"started`",`"reason`":`"`",`"max_attempts`":2,`"window_minutes`":60,`"pid`":0}"
    [System.IO.File]::AppendAllText($ledgerPath, $line + "`n", $enc)
  }
  return $dir
}

$tmpBase = Join-Path (Join-Path $root 'control') ('test-stale-alert-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpBase -Force | Out-Null

try {
  # Test 1: stale report (31h) + 3 denies in last 36h -> trigger fires
  $dir1 = New-SyntheticAuditDir -Base $tmpBase -ReportAgeHours 31 -DeniedOffsets @(2, 5, 10)
  $info1 = Get-StaleAuditLaunchInfo -AuditDir $dir1 -WindowHours 36
  Check-StaleAlert 'T1: stale report+denies -> report_age_hours>=30' ([double]$info1.report_age_hours -ge 30) $info1.report_age_hours
  Check-StaleAlert 'T1: stale report+denies -> recent_denies=3' ([int]$info1.recent_denies -eq 3) $info1.recent_denies
  $trigger1 = [double]$info1.report_age_hours -ge 30 -and ([int]$info1.recent_denies -gt 0 -or [int]$info1.recent_starts -gt 0)
  Check-StaleAlert 'T1: stale_audit trigger condition fires' $trigger1

  # Test 2: fresh report (1h) + 3 denies -> no trigger
  $dir2 = New-SyntheticAuditDir -Base $tmpBase -ReportAgeHours 1 -DeniedOffsets @(1, 2, 3)
  $info2 = Get-StaleAuditLaunchInfo -AuditDir $dir2 -WindowHours 36
  $trigger2 = [double]$info2.report_age_hours -ge 30 -and ([int]$info2.recent_denies -gt 0 -or [int]$info2.recent_starts -gt 0)
  Check-StaleAlert 'T2: fresh report -> no trigger' (-not $trigger2) "age=$($info2.report_age_hours)"

  # Test 3: stale report (31h) + 0 activity -> no trigger
  $dir3 = New-SyntheticAuditDir -Base $tmpBase -ReportAgeHours 31
  $info3 = Get-StaleAuditLaunchInfo -AuditDir $dir3 -WindowHours 36
  $trigger3 = [double]$info3.report_age_hours -ge 30 -and ([int]$info3.recent_denies -gt 0 -or [int]$info3.recent_starts -gt 0)
  Check-StaleAlert 'T3: stale but no activity -> no trigger' (-not $trigger3) "denies=$($info3.recent_denies) starts=$($info3.recent_starts)"

  # Test 4: old entries outside window (40h ago) + stale report -> no trigger
  $dir4 = New-SyntheticAuditDir -Base $tmpBase -ReportAgeHours 31 -DeniedOffsets @(40, 50)
  $info4 = Get-StaleAuditLaunchInfo -AuditDir $dir4 -WindowHours 36
  $trigger4 = [double]$info4.report_age_hours -ge 30 -and ([int]$info4.recent_denies -gt 0 -or [int]$info4.recent_starts -gt 0)
  Check-StaleAlert 'T4: old entries outside 36h window -> no trigger' (-not $trigger4) "denies=$($info4.recent_denies)"

  # Test 5: stale report (31h) + 1 started (no denies) -> trigger fires
  $dir5 = New-SyntheticAuditDir -Base $tmpBase -ReportAgeHours 31 -StartedOffsets @(5)
  $info5 = Get-StaleAuditLaunchInfo -AuditDir $dir5 -WindowHours 36
  $trigger5 = [double]$info5.report_age_hours -ge 30 -and ([int]$info5.recent_denies -gt 0 -or [int]$info5.recent_starts -gt 0)
  Check-StaleAlert 'T5: stale+started->trigger (start without completion)' $trigger5 "starts=$($info5.recent_starts)"
} finally {
  try { Remove-Item -LiteralPath $tmpBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$resultColor = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "`nResult: $($script:pass) passed, $($script:fail) failed" -ForegroundColor $resultColor
if ($script:fail -gt 0) { exit 1 }
