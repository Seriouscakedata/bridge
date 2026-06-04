$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $root 'lib'

$modules = @(
  'common-files.ps1',
  'common-strings.ps1',
  'common-json.ps1'
)

foreach ($module in $modules) {
  $path = Join-Path $lib $module
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing decomposed module: $path"
  }

  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    throw "Parse failed for ${module}: $($errors[0].Message)"
  }
}

. (Join-Path $lib 'common.ps1')

$requiredFunctions = @(
  'Get-BridgeRoot',
  'Resolve-BridgeContainedPath',
  'Write-AtomicFile',
  'Get-SafeAttachmentName',
  'Test-TaskControlMarker',
  'Test-IsSafeOsFastLaneTask',
  'Read-StateJsonRawValidated'
)

foreach ($name in $requiredFunctions) {
  if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) {
    throw "Function not available after dot-sourcing common.ps1: $name"
  }
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-common-decompose-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
try {
  $target = Join-Path $tmpDir 'atomic.txt'
  Write-AtomicFile -Path $target -Content 'decompose-ok'
  $actual = Get-Content -LiteralPath $target -Raw -Encoding UTF8
  if ($actual -ne 'decompose-ok') {
    throw "Write-AtomicFile content mismatch: '$actual'"
  }
} finally {
  if (Test-Path -LiteralPath $tmpDir) {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force
  }
}

Write-Host 'PASS common decomposition'
