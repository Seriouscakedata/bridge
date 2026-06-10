# verify-selftest.ps1 -- bridge self-test helpers for deterministic verification gates
function Get-VerifySelftestRoot {
  $root = ''
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) {
    try { $root = [string](Get-BridgeRoot) } catch { $root = '' }
  }
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $PSScriptRoot }
  if ([string]::IsNullOrWhiteSpace($root)) { throw 'Bridge root is required for verify-selftest' }

  $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\','/')
  if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw "Bridge root does not exist: $rootFull"
  }
  $selfPath = Join-Path $rootFull 'lib\verify-selftest.ps1'
  if (-not (Test-Path -LiteralPath $selfPath -PathType Leaf)) {
    throw "Bridge root is invalid for verify-selftest: $rootFull"
  }
  return $rootFull
}

function Resolve-VerifySelftestRelativePath {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Root)) { throw 'Root is required' }
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is required' }

  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  $target = $Path
  if (-not [System.IO.Path]::IsPathRooted($target)) {
    $target = Join-Path $rootFull $target
  }
  $targetFull = [System.IO.Path]::GetFullPath($target).TrimEnd('\','/')

  $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  if ($targetFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
  if (-not $targetFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes bridge root: $Path"
  }

  return ($targetFull.Substring($rootPrefix.Length) -replace '\\','/')
}

function ConvertTo-VerifySelftestProcessArgument {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) { return '""' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }

  $escaped = ([string]$Value) -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Invoke-VerifySelftestProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = (Get-VerifySelftestRoot),
    [int]$TimeoutSec = 120
  )

  $timeout = [Math]::Max(1, [int]$TimeoutSec)
  $output = @()
  $exitCode = 1
  $timedOut = $false

  try {
    $argLine = (@($Arguments) | ForEach-Object { ConvertTo-VerifySelftestProcessArgument ([string]$_) }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argLine
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
      $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    } catch {}

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeout * 1000)) {
      $timedOut = $true
      try { $proc.Kill() } catch {}
      try { $proc.WaitForExit(3000) | Out-Null } catch {}
      $exitCode = 124
    } else {
      $exitCode = [int]$proc.ExitCode
    }
    try { $stdoutTask.Wait(3000) | Out-Null } catch {}
    try { $stderrTask.Wait(3000) | Out-Null } catch {}
    if ($stdoutTask.IsCompleted -and -not [string]::IsNullOrEmpty($stdoutTask.Result)) {
      $output += @($stdoutTask.Result -split "\r?\n" | Where-Object { $_ -ne '' })
    }
    if ($stderrTask.IsCompleted -and -not [string]::IsNullOrEmpty($stderrTask.Result)) {
      $output += @($stderrTask.Result -split "\r?\n" | Where-Object { $_ -ne '' })
    }
  } catch {
    $output += $_.Exception.Message
    $exitCode = 1
  }

  if ($timedOut) { $output += ("TIMEOUT after {0}s" -f $timeout) }
  return [pscustomobject][ordered]@{
    ExitCode = $exitCode
    TimedOut = [bool]$timedOut
    Output = @($output | ForEach-Object { [string]$_ })
  }
}

function Get-VerifySelftestChangedLibPaths {
  param(
    [string]$Root = (Get-VerifySelftestRoot),
    [string[]]$ChangedPaths
  )

  $rawPaths = @()
  if ($ChangedPaths -and $ChangedPaths.Count -gt 0) {
    $rawPaths = @($ChangedPaths)
  } elseif (Get-Command git -ErrorAction SilentlyContinue) {
    $gitSets = @(
      @('diff', '--name-only', '--cached', '--diff-filter=ACMR', '--', 'lib'),
      @('diff', '--name-only', '--diff-filter=ACMR', '--', 'lib'),
      @('ls-files', '--others', '--exclude-standard', '--', 'lib')
    )
    foreach ($gitArgs in $gitSets) {
      try {
        $safeGitArgs = @('-c', "safe.directory=$Root", '-C', $Root) + @($gitArgs)
        $result = Invoke-VerifySelftestProcess -FilePath 'git' -Arguments $safeGitArgs -WorkingDirectory $Root -TimeoutSec 15
        if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
          $rawPaths += @($result.Output)
        }
      } catch {}
    }
  }

  $libPaths = New-Object System.Collections.Generic.List[string]
  foreach ($rawPath in @($rawPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    try {
      $relativePath = Resolve-VerifySelftestRelativePath -Root $Root -Path ([string]$rawPath)
    } catch {
      continue
    }
    if ($relativePath -imatch '^lib/[^/]+\.ps1$') {
      [void]$libPaths.Add($relativePath.ToLowerInvariant())
    }
  }

  return @($libPaths.ToArray() | Sort-Object -Unique)
}

function Get-VerifySelftestCoveragePaths {
  param([string]$Content)
  $covers = New-Object System.Collections.Generic.List[string]

  if (-not [string]::IsNullOrWhiteSpace($Content)) {
    foreach ($marker in [regex]::Matches($Content, '(?im)^\s*#\s*VERIFY-COVERS\s*:\s*(.+)$')) {
      foreach ($token in (($marker.Groups[1].Value -split '[,;]') | ForEach-Object { $_.Trim() })) {
        if ($token -imatch '^lib[\\/][^\\/]+\.ps1$') {
          [void]$covers.Add((($token -replace '\\','/').ToLowerInvariant()))
        }
      }
    }

    foreach ($ref in [regex]::Matches($Content, '(?im)lib[\\/][A-Za-z0-9._-]+\.ps1')) {
      [void]$covers.Add((($ref.Value -replace '\\','/').ToLowerInvariant()))
    }
  }

  return @($covers | Sort-Object -Unique)
}

function Get-VerifySelftestDiagnostics {
  param([string]$Root = (Get-VerifySelftestRoot))

  $diagDir = Join-Path $Root 'tools\diag'
  if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) { return @() }

  $diagFiles = Get-ChildItem -LiteralPath $diagDir -File -Filter '*.ps1' |
    Where-Object { $_.Name -match '(?i)(selftest|smoke)' }

  $diagnostics = New-Object System.Collections.Generic.List[object]
  foreach ($diagFile in $diagFiles) {
    $content = Get-Content -LiteralPath $diagFile.FullName -Raw -Encoding UTF8
    $coverage = @(Get-VerifySelftestCoveragePaths -Content $content)
    $relativePath = Resolve-VerifySelftestRelativePath -Root $Root -Path $diagFile.FullName
    [void]$diagnostics.Add([pscustomobject][ordered]@{
      Name = $diagFile.Name
      Path = $diagFile.FullName
      RelativePath = $relativePath
      Coverage = $coverage
    })
  }

  return @($diagnostics.ToArray())
}

function Get-VerifySelftestPlan {
  param(
    [string]$Root = (Get-VerifySelftestRoot),
    [string[]]$ChangedPaths
  )

  $changedLibPaths = @(Get-VerifySelftestChangedLibPaths -Root $Root -ChangedPaths $ChangedPaths)
  $diagnostics = @(Get-VerifySelftestDiagnostics -Root $Root)
  $selectedDiagnostics = New-Object System.Collections.Generic.List[object]
  $coveredLibPaths = New-Object System.Collections.Generic.List[string]
  $uncoveredLibPaths = New-Object System.Collections.Generic.List[string]

  foreach ($libPath in $changedLibPaths) {
    $matches = @($diagnostics | Where-Object { $_.Coverage -contains $libPath })
    if ($matches.Count -eq 0) {
      [void]$uncoveredLibPaths.Add($libPath)
      continue
    }
    [void]$coveredLibPaths.Add($libPath)
    foreach ($match in $matches) {
      if (-not ($selectedDiagnostics | Where-Object { $_.RelativePath -eq $match.RelativePath })) {
        [void]$selectedDiagnostics.Add($match)
      }
    }
  }

  return [pscustomobject][ordered]@{
    Root = $Root
    ChangedLibPaths = @($changedLibPaths)
    CoveredLibPaths = @($coveredLibPaths.ToArray() | Sort-Object -Unique)
    UncoveredLibPaths = @($uncoveredLibPaths.ToArray() | Sort-Object -Unique)
    Diagnostics = @($selectedDiagnostics.ToArray())
    Ok = ($uncoveredLibPaths.Count -eq 0)
    Reason = $(if ($changedLibPaths.Count -eq 0) { 'no_lib_changes' } elseif ($uncoveredLibPaths.Count -gt 0) { 'missing_coverage' } else { 'ready' })
  }
}

function Invoke-VerifySelftestDiagnostic {
  param(
    [string]$Root = (Get-VerifySelftestRoot),
    [Parameter(Mandatory=$true)][string]$DiagnosticPath,
    [int]$TimeoutSec = 120
  )

  $powerShellExe = Join-Path $PSHOME 'powershell.exe'
  if (-not (Test-Path -LiteralPath $powerShellExe)) { $powerShellExe = 'powershell.exe' }

  try {
    $run = Invoke-VerifySelftestProcess -FilePath $powerShellExe `
      -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $DiagnosticPath) `
      -WorkingDirectory $Root -TimeoutSec $TimeoutSec
  } catch {
    $run = [pscustomobject][ordered]@{ ExitCode = 1; TimedOut = $false; Output = @($_.Exception.Message) }
  }

  return [pscustomobject][ordered]@{
    DiagnosticPath = $DiagnosticPath
    DiagnosticRelativePath = (Resolve-VerifySelftestRelativePath -Root $Root -Path $DiagnosticPath)
    ExitCode = [int]$run.ExitCode
    TimedOut = [bool]$run.TimedOut
    Ok = ([int]$run.ExitCode -eq 0 -and -not [bool]$run.TimedOut)
    Output = @($run.Output | ForEach-Object { [string]$_ })
  }
}

function Invoke-VerifySelftestGate {
  param(
    [string]$Root = (Get-VerifySelftestRoot),
    [string[]]$ChangedPaths,
    [int]$TimeoutSec = 120
  )

  $plan = Get-VerifySelftestPlan -Root $Root -ChangedPaths $ChangedPaths
  if ($plan.Reason -eq 'no_lib_changes') {
    return [pscustomobject][ordered]@{
      Ok = $true
      Reason = 'no_lib_changes'
      Root = $plan.Root
      ChangedLibPaths = $plan.ChangedLibPaths
      CoveredLibPaths = $plan.CoveredLibPaths
      UncoveredLibPaths = $plan.UncoveredLibPaths
      Diagnostics = @()
    }
  }
  if ($plan.UncoveredLibPaths.Count -gt 0) {
    return [pscustomobject][ordered]@{
      Ok = $false
      Reason = 'missing_coverage'
      Root = $plan.Root
      ChangedLibPaths = $plan.ChangedLibPaths
      CoveredLibPaths = $plan.CoveredLibPaths
      UncoveredLibPaths = $plan.UncoveredLibPaths
      Diagnostics = @()
    }
  }

  $results = New-Object System.Collections.Generic.List[object]
  $failedDiagnostics = New-Object System.Collections.Generic.List[string]
  foreach ($diag in $plan.Diagnostics) {
    $result = Invoke-VerifySelftestDiagnostic -Root $Root -DiagnosticPath $diag.Path -TimeoutSec $TimeoutSec
    [void]$results.Add($result)
    if (-not $result.Ok) {
      [void]$failedDiagnostics.Add($result.DiagnosticRelativePath)
    }
  }

  return [pscustomobject][ordered]@{
    Ok = ($failedDiagnostics.Count -eq 0)
    Reason = $(if ($failedDiagnostics.Count -eq 0) { 'verified' } else { 'selftest_failed' })
    Root = $plan.Root
    ChangedLibPaths = $plan.ChangedLibPaths
    CoveredLibPaths = $plan.CoveredLibPaths
    UncoveredLibPaths = $plan.UncoveredLibPaths
    Diagnostics = @($results.ToArray())
    FailedDiagnostics = @($failedDiagnostics.ToArray())
  }
}

function Get-GateRegressionScope {
  param([string[]]$ChangedPaths = @())

  if ($null -eq $ChangedPaths -or $ChangedPaths.Count -eq 0) { return @() }

  $matchingPaths = New-Object System.Collections.Generic.SortedSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($path in @($ChangedPaths)) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }

    $normalizedPath = (([string]$path).Trim() -replace '\\','/').TrimStart('./')
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) { continue }
    $isControlPlaneOrGatePath =
      $normalizedPath -match '^(?i:driver/)' -or
      $normalizedPath -match '^(?i:lib/)' -or
      $normalizedPath -match '^(?i:control/)' -or
      $normalizedPath -match '^(?i:tools/run-tests\.ps1)$' -or
      $normalizedPath -match '^(?i:tools/test-[^/]+\.ps1)$' -or
      $normalizedPath -match '^(?i:tools/diag/[^/]+\.ps1)$' -or
      $normalizedPath -match '^(?i:(driver|supervisor|server|smoke)\.ps1)$'
    if ($isControlPlaneOrGatePath) {
      [void]$matchingPaths.Add($normalizedPath)
    }
  }

  return @($matchingPaths | ForEach-Object { [string]$_ })
}

function Get-GateRegressionTestSelection {
  param(
    [string]$BridgeRoot = (Get-VerifySelftestRoot),
    [string[]]$Scope = @()
  )

  $root = [System.IO.Path]::GetFullPath($BridgeRoot).TrimEnd('\','/')
  $toolsDir = Join-Path $root 'tools'
  $knownTests = @{}
  if (Test-Path -LiteralPath $toolsDir -PathType Container) {
    foreach ($testFile in @(Get-ChildItem -LiteralPath $toolsDir -Filter 'test-*.ps1' -File -ErrorAction SilentlyContinue)) {
      $knownTests[$testFile.Name.ToLowerInvariant()] = $testFile.Name
    }
  }

  $selected = New-Object System.Collections.Generic.SortedSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($path in @($Scope)) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $normalizedPath = (([string]$path).Trim() -replace '\\','/').TrimStart('./')
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) { continue }

    $leaf = [System.IO.Path]::GetFileName($normalizedPath)
    $leafKey = $leaf.ToLowerInvariant()
    if ($knownTests.ContainsKey($leafKey)) {
      [void]$selected.Add($knownTests[$leafKey])
      continue
    }

    if ($normalizedPath -imatch '^(driver/86-loop-completion-checks\.ps1|lib/verify-selftest\.ps1|tools/run-tests\.ps1|tools/diag/.+)$') {
      foreach ($name in @('test-gate-regression-sentinel.ps1','test-verify-chain-fastpath.ps1')) {
        $key = $name.ToLowerInvariant()
        if ($knownTests.ContainsKey($key)) { [void]$selected.Add($knownTests[$key]) }
      }
      continue
    }

    if ($normalizedPath -imatch '^lib/([^/]+)\.ps1$') {
      $base = $Matches[1].ToLowerInvariant()
      foreach ($testName in @($knownTests.Values)) {
        $testKey = $testName.ToLowerInvariant()
        if ($testKey -eq ("test-{0}.ps1" -f $base) -or $testKey.StartsWith(("test-{0}-" -f $base))) {
          [void]$selected.Add($testName)
        }
      }
    }
  }

  return @($selected | ForEach-Object { [string]$_ })
}

function Invoke-GateRegressionSuite {
  param(
    [string]$BridgeRoot = (Get-VerifySelftestRoot),
    [int]$TimeoutSec = 180,
    [string[]]$ChangedPaths = $null
  )

  $scopeWasExplicit = $PSBoundParameters.ContainsKey('ChangedPaths')
  $scope = @()
  if ($scopeWasExplicit) {
    $scope = @(Get-GateRegressionScope -ChangedPaths @($ChangedPaths))
    if ($scope.Count -eq 0) {
      return [pscustomobject][ordered]@{
        Ok = $true
        Skipped = $true
        Reason = 'empty_scope'
        Scope = @()
        ExitCode = 0
        Elapsed = [System.TimeSpan]::Zero
        TimedOut = $false
      }
    }
  }

  $root = [System.IO.Path]::GetFullPath($BridgeRoot).TrimEnd('\','/')
  $scriptPath = Join-Path $root 'tools\run-tests.ps1'
  $powerShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  if ([string]::IsNullOrWhiteSpace($powerShellExe) -or -not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { $powerShellExe = 'powershell.exe' }
  }

  $selectedTests = @()
  if ($scopeWasExplicit) {
    $selectedTests = @(Get-GateRegressionTestSelection -BridgeRoot $root -Scope @($scope))
  }

  $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-TimeoutSec', ([string]$TimeoutSec))
  if ($selectedTests.Count -gt 0) {
    $runArgs += '-OnlyCsv'
    $runArgs += (($selectedTests | ForEach-Object { [string]$_ }) -join ',')
  }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $run = Invoke-VerifySelftestProcess -FilePath $powerShellExe `
    -Arguments $runArgs `
    -WorkingDirectory $root -TimeoutSec ([Math]::Max(1, [int]$TimeoutSec) + 30)
  $stopwatch.Stop()

  return [pscustomobject][ordered]@{
    Ok = ([int]$run.ExitCode -eq 0 -and -not [bool]$run.TimedOut)
    Skipped = $false
    Reason = $(if ($selectedTests.Count -gt 0) { 'snapshot_suite_scoped' } else { 'snapshot_suite' })
    Scope = @($scope)
    SelectedTests = @($selectedTests)
    ExitCode = [int]$run.ExitCode
    Elapsed = $stopwatch.Elapsed
    TimedOut = [bool]$run.TimedOut
  }
}
