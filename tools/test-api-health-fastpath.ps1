$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $root 'server.ps1'
$source = [System.IO.File]::ReadAllText($serverPath, [System.Text.Encoding]::UTF8)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
  throw ("server.ps1 parse failed: " + (($errors | ForEach-Object { $_.Message }) -join '; '))
}

foreach ($fnName in @('Get-FastJsonlCount','Get-FastJsonlTailLines')) {
  $fn = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName
  }, $true)
  if (-not $fn) { throw "missing function $fnName" }
  Invoke-Expression $fn.Extent.Text
}

$healthAnchor = "if (`$method -eq 'GET' -and `$path -eq '/api/health') {"
$healthStart = $source.IndexOf($healthAnchor, [System.StringComparison]::Ordinal)
if ($healthStart -lt 0) { throw 'missing /api/health handler block' }
$healthEnd = $source.IndexOf("`n        continue", $healthStart, [System.StringComparison]::Ordinal)
if ($healthEnd -le $healthStart) { throw 'missing /api/health continue marker' }
$healthBlock = $source.Substring($healthStart, $healthEnd - $healthStart)

if ($healthBlock -notmatch 'Get-FastJsonlCount') { throw '/api/health does not use Get-FastJsonlCount' }
if ($healthBlock -notmatch 'Get-FastJsonlTailLines') { throw '/api/health does not use Get-FastJsonlTailLines' }
if ($healthBlock -match '\[System\.IO\.File\]::ReadLines\(\$convPath\)\s*\|\s*Select-Object\s+-Last') {
  throw '/api/health still uses full conversation enumeration before tail'
}
if ($healthBlock -match '\[System\.IO\.StreamReader\]::new\(\$memPath') {
  throw '/api/health still opens memory.jsonl for full line counting'
}
if ($healthBlock -notmatch 'healthMemoryLastReadTime' -or $healthBlock -notmatch 'TotalSeconds\s+-ge\s+60') {
  throw '/api/health memory count is not rate-limited to at most once per 60 seconds'
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-health-fastpath-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  $small = Join-Path $tmp 'small.jsonl'
  [System.IO.File]::WriteAllText($small, "a`nb`nc`n", [System.Text.Encoding]::UTF8)
  $smallCount = Get-FastJsonlCount -Path $small -CountPath (Join-Path $tmp 'missing.count') -CachedCount 0 -ExactMaxBytes 1024
  if ($smallCount -ne 3) { throw "small exact count expected 3, got $smallCount" }

  $large = Join-Path $tmp 'large.jsonl'
  $largeText = ('x' * 2048) + "`n"
  [System.IO.File]::WriteAllText($large, $largeText, [System.Text.Encoding]::UTF8)
  $countFile = Join-Path $tmp 'large.count'
  [System.IO.File]::WriteAllText($countFile, '123', [System.Text.Encoding]::UTF8)
  $sidecarCount = Get-FastJsonlCount -Path $large -CountPath $countFile -CachedCount 7 -ExactMaxBytes 10
  if ($sidecarCount -ne 123) { throw "sidecar count expected 123, got $sidecarCount" }

  Remove-Item -LiteralPath $countFile -Force
  $cachedCount = Get-FastJsonlCount -Path $large -CountPath $countFile -CachedCount 7 -ExactMaxBytes 10
  if ($cachedCount -ne 7) { throw "large fallback cached count expected 7, got $cachedCount" }

  $tailFile = Join-Path $tmp 'tail.jsonl'
  [System.IO.File]::WriteAllText($tailFile, "1`n2`n3`n4`n", [System.Text.Encoding]::UTF8)
  $tail = @(Get-FastJsonlTailLines -Path $tailFile -Tail 2)
  if ($tail.Count -ne 2 -or $tail[0] -ne '3' -or $tail[1] -ne '4') {
    throw ("tail expected 3,4 got " + ($tail -join ','))
  }

  # 2026-06-22 regression for watchdog_rollback_api_stuck: Get-FastJsonlTailLines
  # must read even while another handle holds the file open for writing with
  # restrictive sharing (the /api/health hang). Get-Content -Tail could
  # stall/fail here; the FileShare.ReadWrite StreamReader must succeed.
  $locked = Join-Path $tmp 'locked.jsonl'
  [System.IO.File]::WriteAllText($locked, "1`n2`n3`n4`n", [System.Text.Encoding]::UTF8)
  $writer = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $lockedTail = @(Get-FastJsonlTailLines -Path $locked -Tail 2)
    if ($lockedTail.Count -ne 2 -or $lockedTail[0] -ne '3' -or $lockedTail[1] -ne '4') {
      throw ("tail under concurrent write expected 3,4 got " + ($lockedTail -join ','))
    }
  } finally {
    $writer.Dispose()
  }

  # Guard against regressing to the blocking cmdlet read in the health hot-path.
  # Match real command invocations via the AST (CommandAst) so the historical
  # mention of the cmdlet in this function's comment does not trip the guard.
  $tailFnAst = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-FastJsonlTailLines'
  }, $true)
  $blockingUse = $tailFnAst.Find({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-Content'
  }, $true)
  if ($blockingUse) {
    throw 'Get-FastJsonlTailLines still invokes Get-Content (blocking) instead of FileShare.ReadWrite'
  }
  if ($tailFnAst.Extent.Text -notmatch '\.Seek\(') {
    throw 'Get-FastJsonlTailLines must read a bounded window from EOF, not scan the full file'
  }
  if ($tailFnAst.Extent.Text -notmatch 'FileShare\]::ReadWrite') {
    throw 'Get-FastJsonlTailLines must open with FileShare.ReadWrite'
  }
  $countFnAst = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-FastJsonlCount'
  }, $true)
  if ($countFnAst.Extent.Text -notmatch 'FileShare\]::ReadWrite') {
    throw 'Get-FastJsonlCount must open with FileShare.ReadWrite'
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'API HEALTH FASTPATH OK'
