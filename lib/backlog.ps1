# backlog.ps1 -- compatibility aggregator for the bridge self-improvement backlog.
# Dot-source this file to load the domain modules that preserve the historical API.

$script:BacklogCuratorModel = 'gemini-2.5-flash-lite'
$script:BacklogLibraryDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }

$script:BacklogModuleDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } elseif (-not [string]::IsNullOrWhiteSpace($script:BacklogLibraryDir)) { $script:BacklogLibraryDir } else { Split-Path -Parent $PSCommandPath }

foreach ($script:BacklogModuleName in @('backlog-io.ps1', 'backlog-core.ps1', 'backlog-workpack.ps1')) {
  $script:BacklogModulePath = Join-Path $script:BacklogModuleDir $script:BacklogModuleName
  . $script:BacklogModulePath
}

Remove-Variable -Name BacklogModuleName -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name BacklogModulePath -Scope Script -ErrorAction SilentlyContinue
