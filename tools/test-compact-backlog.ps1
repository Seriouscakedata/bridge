param()

$ErrorActionPreference = 'Stop'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

$scriptPath = Join-Path $PSScriptRoot 'compact-backlog.ps1'
Assert-True (Test-Path -LiteralPath $scriptPath) 'compact-backlog.ps1 not found'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-compact-backlog-tool-test-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $backlogPath = Join-Path $tempRoot 'backlog.jsonl'
  $inputLines = @(
    '{"id":"task-a","status":"old","value":1}',
    '{"id":"task-b","status":"keep","value":2}',
    '{"id":"task-a","status":"new","value":3}'
  )
  [System.IO.File]::WriteAllLines($backlogPath, $inputLines, $utf8NoBom)

  $before = [System.IO.File]::ReadAllText($backlogPath, [System.Text.Encoding]::UTF8)
  & $scriptPath -Path $backlogPath -ThresholdMB 10
  $afterSkip = [System.IO.File]::ReadAllText($backlogPath, [System.Text.Encoding]::UTF8)
  Assert-True ($before -eq $afterSkip) 'threshold skip should not rewrite backlog'

  & $scriptPath -Path $backlogPath -ThresholdMB 0 -WhatIf
  $afterWhatIf = [System.IO.File]::ReadAllText($backlogPath, [System.Text.Encoding]::UTF8)
  Assert-True ($before -eq $afterWhatIf) 'WhatIf should not rewrite backlog'

  & $scriptPath -Path $backlogPath -ThresholdMB 0
  $actualLines = @([System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8))
  Assert-True ($actualLines.Count -eq 2) ("expected 2 compacted lines, got {0}" -f $actualLines.Count)
  Assert-True ($actualLines[0] -eq '{"id":"task-a","status":"new","value":3}') 'task-a should keep the last line'
  Assert-True ($actualLines[1] -eq '{"id":"task-b","status":"keep","value":2}') 'task-b should be preserved'

  Write-Host 'OK compact-backlog tool: threshold skip, WhatIf, and last-line-wins replacement verified'
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($tempRoot)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
