function New-BridgeScriptIntegrityResult {
  param(
    [bool]$Ok,
    [string]$Reason,
    [string]$RelativePath = '',
    [string]$Expected = '',
    [string]$Actual = '',
    [string]$Algorithm = '',
    [string]$ManifestPath = '',
    [string]$FilePath = '',
    [string]$Error = ''
  )
  return [pscustomobject][ordered]@{
    Ok = [bool]$Ok
    Reason = $Reason
    RelativePath = $RelativePath
    Expected = $Expected
    Actual = $Actual
    Algorithm = $Algorithm
    ManifestPath = $ManifestPath
    FilePath = $FilePath
    Error = $Error
  }
}

function Resolve-BridgeScriptIntegrityPath {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$RelativePath
  )
  if ([string]::IsNullOrWhiteSpace($Root)) { throw "Root is required" }
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw "RelativePath is required" }
  if ([System.IO.Path]::IsPathRooted($RelativePath)) { throw "Path must be relative: $RelativePath" }

  $rootFull = [System.IO.Path]::GetFullPath($Root)
  $rootPrefix = $rootFull.TrimEnd([char]'\', [char]'/') + [System.IO.Path]::DirectorySeparatorChar
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
  if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes bridge root: $RelativePath"
  }
  return $candidate
}

function Get-BridgeScriptSha256 {
  param([Parameter(Mandatory=$true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Script file not found: $Path"
  }
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash).ToUpperInvariant()
}

function Read-BridgeScriptIntegrityManifest {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$ManifestRelativePath = 'security/script-integrity.json'
  )
  $manifestPath = ''
  try {
    $manifestPath = Resolve-BridgeScriptIntegrityPath -Root $Root -RelativePath $ManifestRelativePath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'missing_manifest' -ManifestPath $manifestPath)
    }
    $raw = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
    $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    $algorithm = [string]$manifest.algorithm
    if ($algorithm.ToUpperInvariant() -ne 'SHA256') {
      return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'bad_algorithm' -Algorithm $algorithm -ManifestPath $manifestPath)
    }
    if ($null -eq $manifest.files) {
      return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'missing_files_map' -Algorithm $algorithm -ManifestPath $manifestPath)
    }
    $result = New-BridgeScriptIntegrityResult -Ok:$true -Reason 'ok' -Algorithm $algorithm.ToUpperInvariant() -ManifestPath $manifestPath
    $result | Add-Member -NotePropertyName Manifest -NotePropertyValue $manifest
    return $result
  } catch {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'manifest_error' -ManifestPath $manifestPath -Error $_.Exception.Message)
  }
}

function Get-BridgeScriptManifestHash {
  param(
    [Parameter(Mandatory=$true)][object]$Manifest,
    [Parameter(Mandatory=$true)][string]$RelativePath
  )
  if ($null -eq $Manifest -or $null -eq $Manifest.files) { return $null }
  $key = ($RelativePath -replace '\\','/')
  $prop = $Manifest.files.PSObject.Properties[$key]
  if ($null -eq $prop) { return $null }
  return [string]$prop.Value
}

function Test-BridgeScriptIntegrity {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$RelativePath,
    [Parameter(Mandatory=$true)][object]$Manifest
  )
  $manifestObject = $Manifest
  if ($Manifest.PSObject.Properties['Manifest']) { $manifestObject = $Manifest.Manifest }
  $algorithm = [string]$manifestObject.algorithm
  $manifestPath = ''
  if ($Manifest.PSObject.Properties['ManifestPath']) { $manifestPath = [string]$Manifest.ManifestPath }

  if ($algorithm.ToUpperInvariant() -ne 'SHA256') {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'bad_algorithm' -RelativePath $RelativePath -Algorithm $algorithm -ManifestPath $manifestPath)
  }

  $filePath = ''
  try {
    $filePath = Resolve-BridgeScriptIntegrityPath -Root $Root -RelativePath $RelativePath
  } catch {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'invalid_path' -RelativePath $RelativePath -Algorithm $algorithm -ManifestPath $manifestPath -Error $_.Exception.Message)
  }
  if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'missing_file' -RelativePath $RelativePath -Algorithm $algorithm -ManifestPath $manifestPath -FilePath $filePath)
  }

  $expected = Get-BridgeScriptManifestHash -Manifest $manifestObject -RelativePath $RelativePath
  if ([string]::IsNullOrWhiteSpace($expected)) {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'missing_hash' -RelativePath $RelativePath -Algorithm $algorithm -ManifestPath $manifestPath -FilePath $filePath)
  }
  $expected = $expected.ToUpperInvariant()

  try {
    $actual = Get-BridgeScriptSha256 -Path $filePath
  } catch {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'hash_error' -RelativePath $RelativePath -Expected $expected -Algorithm $algorithm -ManifestPath $manifestPath -FilePath $filePath -Error $_.Exception.Message)
  }
  if ($actual -ne $expected) {
    return (New-BridgeScriptIntegrityResult -Ok:$false -Reason 'hash_mismatch' -RelativePath $RelativePath -Expected $expected -Actual $actual -Algorithm $algorithm -ManifestPath $manifestPath -FilePath $filePath)
  }
  return (New-BridgeScriptIntegrityResult -Ok:$true -Reason 'ok' -RelativePath $RelativePath -Expected $expected -Actual $actual -Algorithm $algorithm.ToUpperInvariant() -ManifestPath $manifestPath -FilePath $filePath)
}

function Invoke-BridgeIntegrityGuard {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$RelativePath,
    [string]$ManifestRelativePath = 'security/script-integrity.json',
    [Parameter(Mandatory=$true)][scriptblock]$Action
  )
  $manifestRead = Read-BridgeScriptIntegrityManifest -Root $Root -ManifestRelativePath $ManifestRelativePath
  if (-not $manifestRead.Ok) {
    $manifestRead | Add-Member -NotePropertyName ActionInvoked -NotePropertyValue $false
    return $manifestRead
  }
  $test = Test-BridgeScriptIntegrity -Root $Root -RelativePath $RelativePath -Manifest $manifestRead
  if (-not $test.Ok) {
    $test | Add-Member -NotePropertyName ActionInvoked -NotePropertyValue $false
    return $test
  }
  $actionResult = & $Action
  $test | Add-Member -NotePropertyName ActionInvoked -NotePropertyValue $true
  $test | Add-Member -NotePropertyName ActionResult -NotePropertyValue $actionResult
  return $test
}
