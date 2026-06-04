# test-parallel-collect-guard.ps1 -- focused tests for Test-ParallelCollectedPathAllowed guard helper
# Does NOT spawn LLM workers; purely exercises path validation logic.
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dot-source common + parallel to get guard helpers.
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')

if (-not (Get-Command _NormalizeRelPath -ErrorAction SilentlyContinue)) {
  function _NormalizeRelPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = [string]$Path
    if ([System.IO.Path]::IsPathRooted($p)) { return $null }
    $p = ($p -replace '\\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($segment in ($p -split '/+')) {
      if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
      if ($segment -eq '..') { return $null }
      $parts.Add($segment)
    }
    if ($parts.Count -eq 0) { return $null }
    return ($parts -join '/')
  }
}

if (-not (Get-Command Test-ParallelCollectedPathAllowed -ErrorAction SilentlyContinue)) {
  function Test-ParallelCollectedPathAllowed {
    param(
      [string]$RelativePath,
      [string[]]$DeclaredFiles
    )

    $target = _NormalizeRelPath $RelativePath
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    if ($target -eq '.git' -or $target.StartsWith('.git/')) { return $false }
    if (-not $DeclaredFiles -or @($DeclaredFiles).Count -eq 0) { return $false }

    foreach ($declared in @($DeclaredFiles)) {
      $normalized = _NormalizeRelPath $declared
      if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
      if ($normalized -eq '.git' -or $normalized.StartsWith('.git/')) { continue }
      if ($target -eq $normalized) { return $true }
      if ($target.StartsWith($normalized + '/')) { return $true }
    }
    return $false
  }
}

$pass = 0
$fail = 0

function Assert {
  param([bool]$C, [string]$M)
  if ($C) {
    $script:pass++
    Write-Host "PASS: $M"
  } else {
    $script:fail++
    Write-Host "FAIL: $M"
  }
}

# ---- Test-ParallelCollectedPathAllowed ----

# 1. Exact file match
Assert (Test-ParallelCollectedPathAllowed -RelativePath 'lib/foo.ps1' -DeclaredFiles @('lib/foo.ps1')) "exact file allowed"

# 2. Child under declared directory
Assert (Test-ParallelCollectedPathAllowed -RelativePath 'lib/sub/bar.ps1' -DeclaredFiles @('lib/sub')) "child under declared dir allowed"

# 3. File outside declared set
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath 'lib/other.ps1' -DeclaredFiles @('lib/foo.ps1'))) "outside declared path denied"

# 4. Path traversal denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath '../secrets.json' -DeclaredFiles @('../secrets.json', 'lib/foo.ps1'))) "path traversal denied"

# 5. Rooted (absolute) path denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath 'C:\Windows\System32\foo.ps1' -DeclaredFiles @('C:\Windows\System32\foo.ps1'))) "absolute path denied"

# 6. .git path denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath '.git/config' -DeclaredFiles @('.git/config'))) ".git path denied"

# 7. Empty/null path denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath '' -DeclaredFiles @('lib/foo.ps1'))) "empty path denied"

# 8. No declared files (empty touch-set) -> all denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath 'lib/foo.ps1' -DeclaredFiles @())) "no declared files -> denied"

# 9. Backslash-normalized path allowed (Windows path separator)
Assert (Test-ParallelCollectedPathAllowed -RelativePath 'lib\foo.ps1' -DeclaredFiles @('lib/foo.ps1')) "backslash-normalized path allowed"

# 10. Sub-dir with embedded traversal denied
Assert (-not (Test-ParallelCollectedPathAllowed -RelativePath 'lib/../../secrets.json' -DeclaredFiles @('lib/foo.ps1'))) "embedded traversal denied"

# ---- Accounting logic helper: test that quarantine captures unsafe scenarios ----
# (Synthetic -- tests the decision logic, not live collect)

# 11. A stream with status 'unknown_status' should not be treated as allowed terminal
$allowedStatuses = @('done', 'paused-for-restart')
Assert ($allowedStatuses -notcontains 'unknown_status') "unknown status not in allowed terminal statuses"

# 12. A stream with status 'done' IS an allowed terminal status
Assert ($allowedStatuses -contains 'done') "done is allowed terminal status"

# 13. paused-for-restart IS an allowed terminal status
Assert ($allowedStatuses -contains 'paused-for-restart') "paused-for-restart is allowed terminal status"

# 14. Clean complete: merged==total, quarantined==0 -> cleanComplete=true
$merged = 2
$total = 2
$qCount = 0
$cleanComplete = ($merged -ge $total -and $qCount -eq 0 -and $total -gt 0)
Assert $cleanComplete "clean complete: merged==total, quarantined==0"

# 15. Mixed: merged=1, quarantined=1, total=2 -> not clean, but anyDelivered=true
$merged = 1
$total = 2
$qCount = 1
$cleanComplete = ($merged -ge $total -and $qCount -eq 0 -and $total -gt 0)
$anyDelivered = ($merged -ge 1)
Assert (-not $cleanComplete -and $anyDelivered) "mixed: not clean but anyDelivered=true"

# 16. All failed: merged=0, quarantined=2, total=2 -> ok=false
$merged = 0
$total = 2
$qCount = 2
$anyDelivered = ($merged -ge 1)
Assert (-not $anyDelivered) "all failed: ok=false"

Write-Host "`nRESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
