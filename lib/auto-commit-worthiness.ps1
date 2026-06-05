#Requires -Version 5.1
# auto-commit-worthiness.ps1 -- deterministic path filter for bridge driver auto-commits.

function Normalize-AutoCommitStatusPath {
  param([string]$StatusLine)

  if ([string]::IsNullOrWhiteSpace($StatusLine)) { return '' }
  $line = [string]$StatusLine
  if ($line.Length -le 3) { return '' }

  $path = $line.Substring(3).Trim()
  if ($path -match ' -> ') { $path = ($path -split ' -> ', 2)[1].Trim() }
  $path = $path.Trim('"').Trim()
  if ([string]::IsNullOrWhiteSpace($path)) { return '' }

  $path = $path -replace '\\','/'
  while ($path.StartsWith('./')) { $path = $path.Substring(2) }
  return $path
}

function Test-BridgeAutoCommitWorthPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = ([string]$Path).Trim().Trim('"') -replace '\\','/'
  while ($p.StartsWith('./')) { $p = $p.Substring(2) }
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }

  $runtimePatterns = @(
    '^decisions/session-ledger\.jsonl$',
    '^turns\.jsonl$',
    '^features/state\.json$',
    '^control/.*$',
    '^audit/.*$',
    '^logs/.*$',
    '^channels/[^/]+/state\.json$',
    '^channels/[^/]+/conversation\.jsonl$',
    '^channels/[^/]+/task-management-shadow\.jsonl$',
    '^channels/[^/]+/[^/]*shadow[^/]*\.jsonl$',
    '^channels/[^/]+/[^/]*\.log$'
  )

  foreach ($rx in $runtimePatterns) {
    if ($p -match $rx) { return $false }
  }
  return $true
}

