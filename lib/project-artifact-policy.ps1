# project-artifact-policy.ps1 -- shared rules for generated project artifacts.

function Normalize-ProjectArtifactPolicyPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $p = ([string]$Path).Trim() -replace '\\','/'
  while ($p.StartsWith('./')) { $p = $p.Substring(2) }
  return $p.Trim('/')
}

function Test-ProjectGeneratedArtifactPath {
  param([string]$Path)

  $p = Normalize-ProjectArtifactPolicyPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }

  # Project workers may create these during verification or media/model runs, but
  # they must not be treated as durable product code or committed release output.
  if ($p -match '^(runs|runs[-_][^/]+|\.verify($|[-_][^/]*|_runs)|\.verify_runs|run[-_]artifacts|tmp[-_]runs|\.tmp[-_][^/]+)(/|$)') { return $true }

  # Common caches/build byproducts. Keep this intentionally narrow: top-level
  # source assets and fixtures should remain commit-worthy.
  if ($p -match '(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.nox)(/|$)') { return $true }
  if ($p -match '(^|/).*\.(pyc|pyo)$') { return $true }

  return $false
}

function Get-ProjectTrackedGeneratedArtifactPaths {
  param([string]$ProjectRoot)

  $items = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [string[]]@()
  }

  try {
    foreach ($line in @(& git -C $ProjectRoot ls-files 2>$null)) {
      $p = Normalize-ProjectArtifactPolicyPath -Path ([string]$line)
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      if (Test-ProjectGeneratedArtifactPath -Path $p) { [void]$items.Add($p) }
    }
  } catch {}

  return [string[]]@($items.ToArray())
}
