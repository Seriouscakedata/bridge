$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'compact-backlog.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
  throw "compact-backlog test: missing script at $scriptPath"
}

function Assert-True {
  param(
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$true)][string]$Message
  )
  if (-not $Condition) { throw "compact-backlog test failed: $Message" }
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-compact-backlog-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

try {
  $backlog = Join-Path $tmpRoot 'backlog.jsonl'
  $inputLines = @(
    '{"id":"a","value":1}'
    '{"id":"b","value":2}'
    '{"id":"a","value":3}'
    '{"value":"no id 1"}'
    '{"value":"no id 2"}'
  )
  [System.IO.File]::WriteAllLines($backlog, $inputLines, [System.Text.UTF8Encoding]::new($false))
  $originalText = [System.IO.File]::ReadAllText($backlog, [System.Text.Encoding]::UTF8)

  & $scriptPath -Path $backlog -ThresholdMB 999
  Assert-True (([System.IO.File]::ReadAllText($backlog, [System.Text.Encoding]::UTF8)) -eq $originalText) 'threshold skip should not modify the file'

  & $scriptPath -Path $backlog -ThresholdMB 0 -WhatIf
  Assert-True (([System.IO.File]::ReadAllText($backlog, [System.Text.Encoding]::UTF8)) -eq $originalText) 'WhatIf should not modify the file'

  & $scriptPath -Path $backlog -ThresholdMB 0
  $resultLines = @([System.IO.File]::ReadAllLines($backlog, [System.Text.Encoding]::UTF8))
  $resultText = $resultLines -join "`n"

  Assert-True (([System.IO.File]::ReadAllText($backlog, [System.Text.Encoding]::UTF8)) -ne $originalText) 'forced compaction should rewrite the file'
  Assert-True ($resultLines.Count -eq 4) 'compaction should keep one line per id and preserve no-id lines'
  Assert-True ($resultText.Contains('"id":"a","value":3')) 'last line should win for duplicate id a'
  Assert-True (-not $resultText.Contains('"id":"a","value":1')) 'older duplicate id a line should be removed'
  Assert-True ($resultText.Contains('"id":"b","value":2')) 'unique id b should be preserved'
  Assert-True ($resultText.Contains('"value":"no id 1"') -and $resultText.Contains('"value":"no id 2"')) 'no-id lines should be preserved independently'

  Write-Output 'PASS compact-backlog test'
} finally {
  if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
