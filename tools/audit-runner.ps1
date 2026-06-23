# audit-runner.ps1 -- detached nightly audit worker.
# Launched by driver.ps1 with Start-Process so the main loop stays responsive and
# the process can be tracked through Register-ChildProcess.

param(
  [string]$BridgePath,
  [string]$StateFile,
  [int]$MaxWaitMinutes = 60,
  [string]$WaitMarker,
  [string]$Channel = 'main',
  [string]$RunId = ''
)

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom; [Console]::InputEncoding = $Utf8NoBom } catch {}
$script:AuditRunnerTerminalWritten = $false
$script:AuditRunnerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Write-AuditRunnerLog {
  param([string]$Root, [string]$Message)
  try {
    $auditDir = Join-Path $Root 'audit'
    if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    $logPath = Join-Path $auditDir 'audit.log'
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ([string]$Message)
    [System.IO.File]::AppendAllText($logPath, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Get-AuditRunnerMaintenanceDir {
  param([string]$Root, [string]$Slug)
  try {
    if (Get-Command Get-AuditMaintenanceDir -ErrorAction SilentlyContinue) {
      return (Get-AuditMaintenanceDir -Channel $Slug)
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  if ($Slug -eq 'main') { return (Join-Path $Root 'audit') }
  return (Join-Path (Join-Path (Join-Path $Root 'channels') $Slug) 'audit')
}

function Write-AuditRunnerTerminal {
  param(
    [string]$Root,
    [string]$Slug,
    [string]$Decision,
    [string]$Reason = '',
    [string]$ExitReason = '',
    [string]$ReportPath = '',
    [double]$RuntimeSeconds = -1
  )
  if ($script:AuditRunnerTerminalWritten) { return }
  try {
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString() }
    if ($RuntimeSeconds -lt 0) { $RuntimeSeconds = $script:AuditRunnerStopwatch.Elapsed.TotalSeconds }
    $auditDir = Get-AuditRunnerMaintenanceDir -Root $Root -Slug $Slug
    Write-AuditLaunchLedgerEntry -AuditDir $auditDir -Channel $Slug -Decision $Decision -Reason $Reason -ProcessId $PID -RunId $RunId -ReportPath $ReportPath -RuntimeSeconds $RuntimeSeconds -ExitReason $ExitReason | Out-Null
    $script:AuditRunnerTerminalWritten = $true
  } catch {
    Write-AuditRunnerLog -Root $Root -Message ("audit runner terminal ledger write failed: " + $_.Exception.Message)
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($BridgePath)) {
    $BridgePath = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
  } else {
    $BridgePath = [System.IO.Path]::GetFullPath($BridgePath)
  }
  if ($MaxWaitMinutes -lt 0) { $MaxWaitMinutes = 0 }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString() }
  $bridgeRoot = $BridgePath

  $commonScript = Join-Path $BridgePath 'lib\common.ps1'
  if (Test-Path -LiteralPath $commonScript) {
    . $commonScript
    try {
      if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $Channel = Normalize-ChannelSlug $Channel }
      if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) { Set-PinnedChannel $Channel }
      if ([string]::IsNullOrWhiteSpace($StateFile) -and (Get-Command Get-ChannelStatePath -ErrorAction SilentlyContinue)) {
        $StateFile = Get-ChannelStatePath -Slug $Channel
      }
    } catch {}
  }
  $maintenanceScript = Join-Path $BridgePath 'driver\10-maintenance.ps1'
  if (Test-Path -LiteralPath $maintenanceScript) { . $maintenanceScript }
  if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = if ($Channel -eq 'main') { Join-Path $BridgePath 'channels\main\state.json' } else { Join-Path (Join-Path (Join-Path $BridgePath 'channels') $Channel) 'state.json' }
  }

  $auditScript = Join-Path $BridgePath 'tools\audit.ps1'
  if (-not (Test-Path -LiteralPath $auditScript)) {
    Write-AuditRunnerLog -Root $BridgePath -Message 'audit runner failed: tools/audit.ps1 missing'
    Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'failed' -Reason 'audit_script_missing' -ExitReason 'tools/audit.ps1 missing'
    exit 2
  }
  . $auditScript

  $idle = Wait-BridgeIdle -StateFile $StateFile -MaxMinutes $MaxWaitMinutes -StablePolls 2
  if ($idle) {
    $result = Invoke-BridgeAudit -BridgePath $BridgePath -Channel $Channel
    $status = ''
    $reportPath = ''
    $runtimeSeconds = $script:AuditRunnerStopwatch.Elapsed.TotalSeconds
    try { if ($result -and ($result.PSObject.Properties.Name -contains 'status')) { $status = [string]$result.status } } catch {}
    try { if ($result -and ($result.PSObject.Properties.Name -contains 'report_json')) { $reportPath = [string]$result.report_json } } catch {}
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
      try { if ($result -and ($result.PSObject.Properties.Name -contains 'report_md')) { $reportPath = [string]$result.report_md } } catch {}
    }
    try { if ($result -and ($result.PSObject.Properties.Name -contains 'runtime_sec') -and $null -ne $result.runtime_sec) { $runtimeSeconds = [double]$result.runtime_sec } } catch {}
    if ($status -eq 'locked') {
      $lockedPid = ''
      try { if ($result.PSObject.Properties.Name -contains 'pid') { $lockedPid = [string]$result.pid } } catch {}
      Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'failed' -Reason 'audit_lock_held' -ExitReason ("audit_lock_held pid={0}" -f $lockedPid) -ReportPath $reportPath -RuntimeSeconds $runtimeSeconds
      exit 1
    } elseif ($status -eq 'ok') {
      Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'completed_ok' -Reason 'ok' -ExitReason 'ok' -ReportPath $reportPath -RuntimeSeconds $runtimeSeconds
    } else {
      $exitReason = if ([string]::IsNullOrWhiteSpace($status)) { 'status=unknown' } else { 'status=' + $status }
      try {
        if ($result -and ($result.PSObject.Properties.Name -contains 'deep_status') -and -not [string]::IsNullOrWhiteSpace([string]$result.deep_status)) {
          $exitReason += '; deep_status=' + [string]$result.deep_status
        }
      } catch {}
      if ([string]::IsNullOrWhiteSpace($reportPath)) {
        Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'failed' -Reason 'empty_report' -ExitReason ("empty_report; {0}" -f $exitReason) -ReportPath $reportPath -RuntimeSeconds $runtimeSeconds
        exit 1
      } else {
        Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'completed_partial' -Reason 'partial' -ExitReason $exitReason -ReportPath $reportPath -RuntimeSeconds $runtimeSeconds
      }
    }
  } else {
    Write-AuditRunnerLog -Root $BridgePath -Message ("audit skipped: channel={0} did not stay idle for {1} min" -f $Channel, $MaxWaitMinutes)
    Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'skipped_not_idle' -Reason 'not_idle' -ExitReason ("not_idle_after_{0}_min" -f $MaxWaitMinutes)
  }
} catch {
  $rootForLog = if ([string]::IsNullOrWhiteSpace($BridgePath)) { [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) } else { $BridgePath }
  Write-AuditRunnerLog -Root $rootForLog -Message ("audit runner failed: " + $_.Exception.Message)
  Write-AuditRunnerTerminal -Root $rootForLog -Slug $Channel -Decision 'failed' -Reason 'runner_exception' -ExitReason $_.Exception.Message
  exit 1
} finally {
  try {
    if (-not $script:AuditRunnerTerminalWritten -and -not [string]::IsNullOrWhiteSpace($BridgePath)) {
      Write-AuditRunnerTerminal -Root $BridgePath -Slug $Channel -Decision 'failed' -Reason 'runner_finally_without_terminal' -ExitReason 'runner reached finally without terminal ledger entry'
    }
  } catch {}
  try {
    if (-not [string]::IsNullOrWhiteSpace($WaitMarker) -and (Test-Path -LiteralPath $WaitMarker)) {
      Remove-Item -LiteralPath $WaitMarker -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
