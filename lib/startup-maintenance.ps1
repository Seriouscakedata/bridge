function Invoke-StartupBacklogCompaction {
  param(
    [Parameter(Mandatory=$true)][string]$BridgeRoot,
    [scriptblock]$LogBlock = $null
  )

  function Write-StartupBacklogCompactionLog {
    param([string]$Message)
    if ($LogBlock) { & $LogBlock $Message }
    else { Write-Host $Message }
  }

  try {
    $compactBacklogScript = Join-Path $BridgeRoot 'tools\compact-backlog.ps1'
    $channelsRoot = Join-Path $BridgeRoot 'channels'
    if (-not (Test-Path -LiteralPath $compactBacklogScript)) {
      Write-StartupBacklogCompactionLog ("startup backlog compaction skipped: missing " + $compactBacklogScript)
      return
    }
    if (-not (Test-Path -LiteralPath $channelsRoot)) {
      Write-StartupBacklogCompactionLog ("startup backlog compaction skipped: missing " + $channelsRoot)
      return
    }

    Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $backlogPath = Join-Path $_.FullName 'backlog.jsonl'
      if (Test-Path -LiteralPath $backlogPath) {
        try {
          $output = @(& $compactBacklogScript -Path $backlogPath *>&1)
          foreach ($line in $output) {
            if ($null -ne $line -and ('' -ne [string]$line)) {
              Write-StartupBacklogCompactionLog ("startup backlog compaction: " + [string]$line)
            }
          }
        } catch {
          Write-StartupBacklogCompactionLog ("startup backlog compaction error for " + $backlogPath + ": " + $_.Exception.Message)
        }
      }
    }
  } catch {
    Write-StartupBacklogCompactionLog ("startup backlog compaction error: " + $_.Exception.Message)
  }
}
