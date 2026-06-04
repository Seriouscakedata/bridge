param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$libRoot = Join-Path $repoRoot 'lib'
$aggregatorPath = Join-Path $libRoot 'backlog.ps1'
$modulePaths = @(
  (Join-Path $libRoot 'backlog-io.ps1'),
  (Join-Path $libRoot 'backlog-core.ps1'),
  (Join-Path $libRoot 'backlog-workpack.ps1')
)

function Assert-BacklogDecompose {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Test-BacklogScriptParse {
  param([string]$Path)
  Assert-BacklogDecompose (Test-Path -LiteralPath $Path) "Missing script: $Path"
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    $joined = ($errors | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Message)" }) -join '; '
    throw "Parse failed for ${Path}: $joined"
  }
}

foreach ($path in @($aggregatorPath) + $modulePaths) {
  Test-BacklogScriptParse -Path $path
}

$script:BacklogDecomposeTempBase = Join-Path $repoRoot '.tmp'
$script:BacklogDecomposeTempRoot = Join-Path $script:BacklogDecomposeTempBase ("bridge-backlog-decompose-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:BacklogDecomposeTempRoot -Force | Out-Null
$script:BacklogDecomposePath = Join-Path $script:BacklogDecomposeTempRoot 'backlog.jsonl'

function Get-BridgeRoot {
  return $script:BacklogDecomposeTempRoot
}

function Get-ChannelBacklogPath {
  return $script:BacklogDecomposePath
}

function Use-BridgeLock {
  param([scriptblock]$ScriptBlock)
  return (& $ScriptBlock)
}

try {
  . $aggregatorPath

  $requiredFunctions = @(
    'Get-BacklogPath',
    'Get-Backlog',
    'Save-Backlog',
    'Add-Idea',
    'Get-NextBacklogWorkpackBatch'
  )
  foreach ($name in $requiredFunctions) {
    Assert-BacklogDecompose ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "Function unavailable after dot-source backlog.ps1: $name"
  }

  $expected = [pscustomobject]@{
    id = 'decompose-smoke'
    ts = '2026-06-04T00:00:00.0000000Z'
    from = 'test'
    status = 'approved'
    tags = @('decompose')
    attempts = 0
    score = 0.0
    project = ''
    scope = 'bridge'
    text = 'decomposition smoke item'
  }

  Save-Backlog @($expected)
  Assert-BacklogDecompose (Test-Path -LiteralPath $script:BacklogDecomposePath) 'Save-Backlog did not create the temp backlog file.'

  $actual = @(Get-Backlog)
  Assert-BacklogDecompose ($actual.Count -eq 1) "Expected one backlog item, got $($actual.Count)."
  Assert-BacklogDecompose ([string]$actual[0].id -eq 'decompose-smoke') 'Read item id mismatch.'
  Assert-BacklogDecompose ([string]$actual[0].status -eq 'approved') 'Read item status mismatch.'
  Assert-BacklogDecompose ([string]$actual[0].text -eq 'decomposition smoke item') 'Read item text mismatch.'

  Write-Host 'backlog decomposition smoke test passed'
} finally {
  Remove-Item -LiteralPath $script:BacklogDecomposeTempRoot -Recurse -Force -ErrorAction SilentlyContinue
  try {
    if ((Test-Path -LiteralPath $script:BacklogDecomposeTempBase) -and -not @(Get-ChildItem -LiteralPath $script:BacklogDecomposeTempBase -Force -ErrorAction SilentlyContinue).Count) {
      Remove-Item -LiteralPath $script:BacklogDecomposeTempBase -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
