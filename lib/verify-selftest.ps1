function Get-VerifySelftestRoot {
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) {
    return Get-BridgeRoot
  }
  return (Split-Path -Parent $PSScriptRoot)
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
        $rawPaths += @(& git -c "safe.directory=$Root" -C $Root @gitArgs 2>$null)
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
    [Parameter(Mandatory=$true)][string]$DiagnosticPath
  )

  $powerShellExe = Join-Path $PSHOME 'powershell.exe'
  if (-not (Test-Path -LiteralPath $powerShellExe)) { $powerShellExe = 'powershell.exe' }

  $output = @()
  $exitCode = 1
  try {
    Push-Location $Root
    try {
      $output = @(& $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $DiagnosticPath 2>&1)
      $exitCode = if ($LASTEXITCODE -is [int]) { [int]$LASTEXITCODE } else { 0 }
    } finally {
      Pop-Location
    }
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  }

  return [pscustomobject][ordered]@{
    DiagnosticPath = $DiagnosticPath
    DiagnosticRelativePath = (Resolve-VerifySelftestRelativePath -Root $Root -Path $DiagnosticPath)
    ExitCode = $exitCode
    Ok = ($exitCode -eq 0)
    Output = @($output | ForEach-Object { [string]$_ })
  }
}

function Invoke-VerifySelftestGate {
  param(
    [string]$Root = (Get-VerifySelftestRoot),
    [string[]]$ChangedPaths
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
    $result = Invoke-VerifySelftestDiagnostic -Root $Root -DiagnosticPath $diag.Path
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
