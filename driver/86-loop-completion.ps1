$script:DriverLoopCompletionRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-checks.ps1')
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-actions.ps1')
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-cleanup.ps1')

function Set-DriverCompletionFinalizing {
  param([bool]$Active)
  try {
    Update-State ({ param($s)
      $s | Add-Member -NotePropertyName completion_finalizing -NotePropertyValue $Active -Force
      $s.heartbeat = (Get-Date).ToString('o')
    }.GetNewClosure()) | Out-Null
  } catch {}
}

$script:DriverLoopCompletionBlock = {
  $completionFinalizingSet = $false
  try {
    . $script:DriverLoopCompletionInitialChecksBlock
    if ($plannerStatus -eq 'DONE' -or $fastLaneDone) {
      Set-DriverCompletionFinalizing -Active $true
      $completionFinalizingSet = $true
    }
    . $script:DriverLoopCompletionCriticActionsBlock
    . $script:DriverLoopCompletionRuntimeChecksBlock
    . $script:DriverLoopCompletionProjectActionsBlock
    . $script:DriverLoopCompletionCleanupBlock
  } finally {
    if ($completionFinalizingSet) {
      Set-DriverCompletionFinalizing -Active $false
    }
  }
}
