# run-tests.ps1 -- consolidated gate/regression suite runner for the bridge (Hardening Roadmap E).
# Runs every tools/test-*.ps1 in an isolated child process and reports a single pass/fail summary.
# Exit 0 = all passed; Exit 1 = one or more failed. This is the operational "are all gates green?"
# check: the bridge can run it before/after any control-plane self-modification so a gate change
# cannot regress a sibling gate (the gate-cascade root). Each test owns its own sandbox.
param(
  [int]$TimeoutSec = 120,
  [string]$Filter = 'test-*.ps1',
  [string[]]$Only = @(),
  [string]$OnlyLike = '',
  [string]$OnlyCsv = '',
  [switch]$NoSnapshot,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$toolsDir = $PSScriptRoot
$bridgeRoot = Split-Path -Parent $toolsDir
try { $ps = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $ps = '' }
if ([string]::IsNullOrWhiteSpace($ps) -or -not (Test-Path -LiteralPath $ps)) {
  throw 'Cannot resolve current PowerShell executable for isolated test runner.'
}

function Get-NormalizedOnlySelection {
  param(
    [string[]]$Only,
    [string]$OnlyLike,
    [string]$OnlyCsv
  )

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Only)) {
    if (-not [string]::IsNullOrWhiteSpace($item)) {
      $items.Add($item.Trim())
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($OnlyLike)) {
    $items.Add($OnlyLike.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($OnlyCsv)) {
    foreach ($item in ($OnlyCsv -split ',')) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        $items.Add($item.Trim())
      }
    }
  }

  return @($items.ToArray() | Select-Object -Unique)
}

function Join-TestProcessArguments {
  param([string[]]$Arguments)

  $quoted = @()
  foreach ($arg in @($Arguments)) {
    if ($null -eq $arg) { $arg = '' }
    $value = [string]$arg
    if ($value -notmatch '[\s"]') {
      $quoted += $value
      continue
    }
    $quoted += ('"' + ($value -replace '"','\"') + '"')
  }
  return ($quoted -join ' ')
}

$normalizedOnly = @(Get-NormalizedOnlySelection -Only $Only -OnlyLike $OnlyLike -OnlyCsv $OnlyCsv)

if (-not $NoSnapshot) {
  $snapshotId = [System.Guid]::NewGuid().ToString('N')
  $snapshotDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-run-tests-{0}" -f $snapshotId)
  $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-run-tests-{0}.zip" -f $snapshotId)
  try {
    [void](New-Item -ItemType Directory -Path $snapshotDir -Force)
    $gitSafeDirectory = "safe.directory=$bridgeRoot"
    $head = [string]((& git -c $gitSafeDirectory -C $bridgeRoot rev-parse HEAD 2>$null) -join '')
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
      throw 'Cannot resolve HEAD for gate-regression snapshot.'
    }
    $head = $head.Trim()
    Write-Host ("=== gate-regression snapshot: ref {0} ===" -f $head)
    Write-Host ("=== gate-regression snapshot: path {0} ===" -f $snapshotDir)

    & git -c $gitSafeDirectory -C $bridgeRoot archive --format zip --output $tmpZip HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpZip)) {
      throw 'Cannot create git archive for gate-regression snapshot.'
    }
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $snapshotDir -Force

    $snapshotScript = Join-Path $snapshotDir 'tools\run-tests.ps1'
    if (-not (Test-Path -LiteralPath $snapshotScript)) {
      throw 'Snapshot does not contain tools\run-tests.ps1.'
    }

    $childArgs = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $snapshotScript,
      '-NoSnapshot',
      '-TimeoutSec',
      [string]$TimeoutSec,
      '-Filter',
      $Filter
    )
    if ($normalizedOnly.Count -gt 0) {
      # powershell.exe -File does NOT collect multiple tokens into a [string[]] parameter:
      # "-Only a b c" binds a to -Only and spills b/c into the NEXT positional params
      # (-OnlyLike/-OnlyCsv), silently dropping the rest — the snapshot child ran only the
      # first 3 of N selected tests (observed live: 12 passed in -> 3 ran). Pass one CSV string.
      $childArgs += '-OnlyCsv'
      $childArgs += (($normalizedOnly | ForEach-Object { [string]$_ }) -join ',')
    }
    if ($Quiet) { $childArgs += '-Quiet' }

    & $ps @childArgs
    $childExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    exit $childExitCode
  } catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    exit 1
  } finally {
    Remove-Item -LiteralPath $snapshotDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmpZip) {
      Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    }
  }
}

$testFiles = @(Get-ChildItem -LiteralPath $toolsDir -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($normalizedOnly.Count -gt 0) {
  $testFiles = @($testFiles | Where-Object {
    $name = $_.Name
    @($normalizedOnly | Where-Object { $name -like ("*" + $_ + "*") }).Count -gt 0
  })
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($t in $testFiles) {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  $ok = $false; $code = -1; $tail = ''; $timedOut = $false
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps
    $psi.Arguments = Join-TestProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t.FullName)
    $psi.WorkingDirectory = $bridgeRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit($TimeoutSec * 1000)) {
      $code = [int]$proc.ExitCode
      $ok = ($code -eq 0)
      # The timed overload can return before redirected async readers finish
      # draining. The parameterless wait is instant after exit and prevents
      # false "stdout pipe did not close" failures for chatty tests.
      try { $proc.WaitForExit() | Out-Null } catch {}
      try { $outTask.Wait(3000) | Out-Null } catch {}
      try { $errTask.Wait(3000) | Out-Null } catch {}
      if ($outTask.IsCompleted) {
        try { [System.IO.File]::WriteAllText($tmpOut, [string]$outTask.Result, (New-Object System.Text.UTF8Encoding($false))) } catch {}
      } else {
        $tail = 'stdout pipe did not close after process exit'
      }
      if ($errTask.IsCompleted) {
        try { [System.IO.File]::WriteAllText($tmpErr, [string]$errTask.Result, (New-Object System.Text.UTF8Encoding($false))) } catch {}
      } elseif ([string]::IsNullOrWhiteSpace($tail)) {
        $tail = 'stderr pipe did not close after process exit'
      }
    } else {
      try { $proc.Kill() } catch {}
      $code = 124
      $timedOut = $true
      $tail = ("TIMEOUT after {0}s" -f $TimeoutSec)
    }
  } catch {
    $tail = $_.Exception.Message
  }
  if ([string]::IsNullOrWhiteSpace($tail)) {
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $tmpOut -ErrorAction SilentlyContinue) } catch {}
    if ($lines.Count -eq 0) { try { $lines = @(Get-Content -LiteralPath $tmpErr -ErrorAction SilentlyContinue) } catch {} }
    if ($lines.Count -gt 0) { $tail = [string]($lines[-1]) }
  }
  Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
  $results.Add([pscustomobject]@{ name = $t.Name; ok = $ok; inconclusive = $timedOut; code = $code; tail = [string]$tail })
  if (-not $Quiet) {
    $tag = if ($ok) { 'PASS' } elseif ($timedOut) { 'INCONCL' } else { 'FAIL' }
    Write-Host ("{0,-5} {1}" -f $tag, $t.Name)
  }
}

$arr = @($results.ToArray())
$failed = @($arr | Where-Object { -not $_.ok -and -not $_.inconclusive })
$inconclusiveArr = @($arr | Where-Object { $_.inconclusive })
$passCount = $arr.Count - $failed.Count - $inconclusiveArr.Count
Write-Host ''
Write-Host ("=== gate-regression suite: {0}/{1} passed, {2} failed, {3} inconclusive ===" -f $passCount, $arr.Count, $failed.Count, $inconclusiveArr.Count)
foreach ($f in $failed) { Write-Host ("  FAIL {0} (exit {1}): {2}" -f $f.name, $f.code, $f.tail) }
foreach ($inc in $inconclusiveArr) { Write-Host ("  INCONCL {0}: {1}" -f $inc.name, $inc.tail) }
if ($failed.Count -gt 0) { exit 1 }
exit 0
