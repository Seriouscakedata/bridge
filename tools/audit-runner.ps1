# audit-runner.ps1 -- detached nightly audit worker.
# Launched by driver.ps1 with Start-Process so the main loop stays responsive and
# the process can be tracked through Register-ChildProcess.

param(
  [string]$BridgePath,
  [string]$StateFile,
  [int]$MaxWaitMinutes = 60,
  [string]$WaitMarker,
  [string]$Channel = 'main'
)

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom; [Console]::InputEncoding = $Utf8NoBom } catch {}

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

try {
  if ([string]::IsNullOrWhiteSpace($BridgePath)) {
    $BridgePath = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
  } else {
    $BridgePath = [System.IO.Path]::GetFullPath($BridgePath)
  }
  if ($MaxWaitMinutes -lt 0) { $MaxWaitMinutes = 0 }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }

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
  if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = if ($Channel -eq 'main') { Join-Path $BridgePath 'channels\main\state.json' } else { Join-Path (Join-Path (Join-Path $BridgePath 'channels') $Channel) 'state.json' }
  }

  $auditScript = Join-Path $BridgePath 'tools\audit.ps1'
  if (-not (Test-Path -LiteralPath $auditScript)) {
    Write-AuditRunnerLog -Root $BridgePath -Message 'audit runner failed: tools/audit.ps1 missing'
    exit 2
  }
  . $auditScript

  $idle = Wait-BridgeIdle -StateFile $StateFile -MaxMinutes $MaxWaitMinutes -StablePolls 2
  if ($idle) {
    Invoke-BridgeAudit -BridgePath $BridgePath -Channel $Channel | Out-Null
  } else {
    Write-AuditRunnerLog -Root $BridgePath -Message ("audit skipped: channel={0} did not stay idle for {1} min" -f $Channel, $MaxWaitMinutes)
  }
} catch {
  $rootForLog = if ([string]::IsNullOrWhiteSpace($BridgePath)) { [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)) } else { $BridgePath }
  Write-AuditRunnerLog -Root $rootForLog -Message ("audit runner failed: " + $_.Exception.Message)
  exit 1
} finally {
  try {
    if (-not [string]::IsNullOrWhiteSpace($WaitMarker) -and (Test-Path -LiteralPath $WaitMarker)) {
      Remove-Item -LiteralPath $WaitMarker -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
