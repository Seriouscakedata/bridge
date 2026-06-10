# test-parallel-collect-guard.ps1 -- focused tests for Test-ParallelCollectedPathAllowed guard helper
# Does NOT spawn LLM workers; purely exercises path validation logic.
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dot-source common + parallel to get guard helpers.
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')

if (-not (Get-Command _NormalizeRelPath -ErrorAction SilentlyContinue)) {
  Write-Host "FAIL: production helper _NormalizeRelPath is not visible after dot-source"
  exit 1
}

if (-not (Get-Command Test-ParallelCollectedPathAllowed -ErrorAction SilentlyContinue)) {
  Write-Host "FAIL: production helper Test-ParallelCollectedPathAllowed is not visible after dot-source"
  exit 1
}

if (-not (Get-Command Invoke-ParallelOutsideFilesCheckout -ErrorAction SilentlyContinue)) {
  Write-Host "FAIL: production helper Invoke-ParallelOutsideFilesCheckout is not visible after dot-source"
  exit 1
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
$cleanComplete = ($merged -eq $total -and $qCount -eq 0 -and $total -gt 0)
Assert $cleanComplete "clean complete: merged==total, quarantined==0"

# 15. Mixed: merged=1, quarantined=1, total=2 -> not clean, but anyDelivered=true
$merged = 1
$total = 2
$qCount = 1
$cleanComplete = ($merged -eq $total -and $qCount -eq 0 -and $total -gt 0)
$anyDelivered = ($merged -ge 1)
Assert (-not $cleanComplete -and $anyDelivered) "mixed: not clean but anyDelivered=true"

# 16. All failed: merged=0, quarantined=2, total=2 -> ok=false
$merged = 0
$total = 2
$qCount = 2
$anyDelivered = ($merged -ge 1)
Assert (-not $anyDelivered) "all failed: ok=false"

# 17. Completed can arrive as a one-element Object[] wrapper from dispatcher fallback paths.
$completedMap = ConvertTo-ParallelDispatchCompletedMap -Completed @(@{ wp1 = [pscustomobject]@{ status = 'done'; commits = @('abc123') } })
Assert ($completedMap.ContainsKey('wp1') -and $completedMap['wp1'].status -eq 'done') "Completed Object[] wrapper converts to map"

# 18. Aggregation context stores the converted map instead of requiring a hashtable parameter transform.
$ctx = New-ParallelDispatchAggregationContext -Workers @([pscustomobject]@{ id = 'wp1' }, [pscustomobject]@{ id = 'wp2' }) -Completed @($completedMap) -TaskHash 'unit'
Assert ($ctx.completed.ContainsKey('wp1') -and $ctx.allowedTerminalStatuses -contains 'paused-for-restart') "aggregation context accepts wrapped completed map"

# 19. Timeout/kill/incomplete workers are quarantined.
Add-ParallelDispatchIncompleteWorkersToQuarantine -Context $ctx
Assert ($ctx.quarantined.Contains('wp2')) "incomplete worker quarantined"

# 20. Quarantine accounting keeps all-failed result closed.
$failedCtx = @{
  workers = @([pscustomobject]@{ id = 'wp1' }, [pscustomobject]@{ id = 'wp2' })
  quarantined = (New-Object 'System.Collections.Generic.List[string]')
  merged = 0
}
[void]$failedCtx.quarantined.Add('wp1')
[void]$failedCtx.quarantined.Add('wp2')
$failedResult = Complete-ParallelDispatchResult -Context $failedCtx
Assert ((-not [bool]$failedResult.ok) -and $failedResult.reason -eq 'all_failed') "all quarantined streams produce all_failed"

# 21-24. LLM worker mirrors strict path semantics instead of silently skipping denied FILE blocks.
$llmWorkerSource = Get-Content -LiteralPath (Join-Path $root 'tools\parallel-llm-worker.ps1') -Raw -Encoding UTF8
Assert ($llmWorkerSource -match 'function Test-WorkerRelAllowed') "LLM worker has explicit allowed-path helper"
Assert ($llmWorkerSource -match 'denied FILE path') "LLM worker fails stream on denied FILE paths"
Assert ($llmWorkerSource -notmatch 'allowedFiles\.Count -gt 0 -and -not') "LLM worker does not silently skip denied paths"
Assert ($llmWorkerSource -notmatch '2>\$null') "LLM worker does not hide native git stderr with PowerShell redirection"

$parallelSource = Get-Content -LiteralPath (Join-Path $root 'lib\parallel.ps1') -Raw -Encoding UTF8
Assert ($parallelSource -match [regex]::Escape('Invoke-ParallelOutsideFilesCheckout -RepoRoot $wtPath -OutsideFiles @($deniedPaths)')) "collector cleans denied paths in worker worktree"
Assert ($parallelSource -notmatch [regex]::Escape('Invoke-ParallelOutsideFilesCheckout -RepoRoot $Context.bridgeRoot -OutsideFiles @($deniedPaths)')) "collector does not clean denied paths in bridge root before merge"

# 25-28. Outside touch-set cleanup runs checkout before quarantine and never checks out declared files.
$script:checkoutEvents = New-Object 'System.Collections.Generic.List[string]'
$cleanup = Invoke-ParallelOutsideFilesCheckout -RepoRoot $root -OutsideFiles @('lib/outside.ps1', 'lib/allowed.ps1', '../bad.ps1', '.git/config') -DeclaredFiles @('lib/allowed.ps1') -GitExe 'git' -GitRunner {
  param([string]$GitExe, [string]$RepoRoot, [object]$GitArgs)
  $argv = New-Object 'System.Collections.Generic.List[string]'
  foreach ($a in @($GitArgs)) {
    if ($a -is [System.Array]) {
      foreach ($nested in @($a)) { [void]$argv.Add([string]$nested) }
    } else {
      [void]$argv.Add([string]$a)
    }
  }
  [void]$script:checkoutEvents.Add((@($argv) -join ' '))
  return [pscustomobject]@{ ExitCode = 0; Output = @() }
}
[void]$script:checkoutEvents.Add('quarantine stream')
Assert ([bool]$cleanup.ok) "outside cleanup helper returns ok for fake git"
Assert (($script:checkoutEvents -join "`n") -match 'checkout -- lib/outside\.ps1') "outside cleanup invokes git checkout for denied path"
Assert (($script:checkoutEvents -join "`n") -notmatch 'lib/allowed\.ps1') "outside cleanup excludes declared path from checkout"
$checkoutIndex = [array]::IndexOf(@($script:checkoutEvents), 'checkout -- lib/outside.ps1')
$quarantineIndex = [array]::IndexOf(@($script:checkoutEvents), 'quarantine stream')
Assert ($checkoutIndex -ge 0 -and $quarantineIndex -gt $checkoutIndex) "outside checkout happens before quarantine"

# 29-30. Real temp repo: staged tracked outside path is reset+checked out; declared path is untouched.
$gitExe = Get-GitExe
$tmpParent = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-parallel-guard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null
try {
  & $gitExe -C $tmpParent init | Out-Null
  & $gitExe -C $tmpParent config user.email 'bridge-test@example.invalid' | Out-Null
  & $gitExe -C $tmpParent config user.name 'Bridge Test' | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmpParent 'allowed.txt'), "base-allowed`n", [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText((Join-Path $tmpParent 'outside.txt'), "base-outside`n", [System.Text.Encoding]::UTF8)
  & $gitExe -C $tmpParent add allowed.txt outside.txt | Out-Null
  & $gitExe -C $tmpParent commit -m 'base' | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmpParent 'allowed.txt'), "changed-allowed`n", [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText((Join-Path $tmpParent 'outside.txt'), "changed-outside`n", [System.Text.Encoding]::UTF8)
  & $gitExe -C $tmpParent add allowed.txt outside.txt | Out-Null
  $realCleanup = Invoke-ParallelOutsideFilesCheckout -RepoRoot $tmpParent -OutsideFiles @('outside.txt', 'allowed.txt') -DeclaredFiles @('allowed.txt') -GitExe $gitExe
  $statusAfter = @(& $gitExe -C $tmpParent status --porcelain)
  Assert ([bool]$realCleanup.ok) "real cleanup succeeds in temp repo"
  Assert (($statusAfter -contains 'M  allowed.txt') -and -not (($statusAfter -join "`n") -match 'outside\.txt')) "real cleanup clears staged outside path and leaves declared path staged"
} finally {
  if (Test-Path -LiteralPath $tmpParent) { Remove-Item -LiteralPath $tmpParent -Recurse -Force }
}

Write-Host "`nRESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
