$script:DriverLoopCompletionRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-checks.ps1')
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-actions.ps1')
. (Join-Path $script:DriverLoopCompletionRoot '86-loop-completion-cleanup.ps1')

$script:DriverLoopCompletionBlock = {
  . $script:DriverLoopCompletionInitialChecksBlock
  . $script:DriverLoopCompletionCriticActionsBlock
  . $script:DriverLoopCompletionRuntimeChecksBlock
  . $script:DriverLoopCompletionProjectActionsBlock
  . $script:DriverLoopCompletionCleanupBlock
}