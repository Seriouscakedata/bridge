$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\script-integrity.ps1')

$tempRoot = Join-Path $root ('tmp\script-integrity-test-' + [guid]::NewGuid().ToString('N'))
$driverOk = $false
$serverOk = $false
$tamperBlocked = $false
$actionInvokedOnTamper = $true
$goodGuardOk = $false
$actionInvokedOnGood = $false
$missingManifestBlocked = $false
$missingHashBlocked = $false
$badAlgorithmBlocked = $false
$missingFileBlocked = $false
$markerExists = $false

try {
  $manifest = Read-BridgeScriptIntegrityManifest -Root $root -ManifestRelativePath 'security/script-integrity.json'
  if ($manifest.Ok) {
    $driver = Test-BridgeScriptIntegrity -Root $root -RelativePath 'driver.ps1' -Manifest $manifest
    $server = Test-BridgeScriptIntegrity -Root $root -RelativePath 'server.ps1' -Manifest $manifest
    $driverOk = [bool]$driver.Ok
    $serverOk = [bool]$server.Ok
  }

  $null = New-Item -ItemType Directory -Path $tempRoot -Force
  $fakeDriver = Join-Path $tempRoot 'driver.ps1'
  $fakeManifestDir = Join-Path $tempRoot 'security'
  $fakeManifestPath = Join-Path $fakeManifestDir 'script-integrity.json'
  $marker = Join-Path $tempRoot 'marker.txt'
  $null = New-Item -ItemType Directory -Path $fakeManifestDir -Force
  [System.IO.File]::WriteAllText($fakeDriver, "Write-Output 'fake driver'`r`n", (New-Object System.Text.UTF8Encoding($true)))
  $fakeDriverHash = Get-BridgeScriptSha256 -Path $fakeDriver
  $goodManifest = [ordered]@{
    version = 1
    algorithm = 'SHA256'
    files = [ordered]@{
      'driver.ps1' = $fakeDriverHash
    }
  }
  [System.IO.File]::WriteAllText($fakeManifestPath, ($goodManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

  $good = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'driver.ps1' -ManifestRelativePath 'security/script-integrity.json' -Action {
    return 'started'
  }
  $goodGuardOk = [bool]$good.Ok
  $actionInvokedOnGood = [bool]$good.ActionInvoked

  $badManifest = [ordered]@{
    version = 1
    algorithm = 'SHA256'
    files = [ordered]@{
      'driver.ps1' = '0000000000000000000000000000000000000000000000000000000000000000'
    }
  }
  [System.IO.File]::WriteAllText($fakeManifestPath, ($badManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

  $tamper = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'driver.ps1' -ManifestRelativePath 'security/script-integrity.json' -Action {
    [System.IO.File]::WriteAllText($marker, 'started', (New-Object System.Text.UTF8Encoding($false)))
    return $true
  }
  $tamperBlocked = (-not [bool]$tamper.Ok)
  $actionInvokedOnTamper = [bool]$tamper.ActionInvoked
  $markerExists = Test-Path -LiteralPath $marker

  $missing = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'driver.ps1' -ManifestRelativePath 'security/missing.json' -Action {
    [System.IO.File]::WriteAllText($marker, 'missing-started', (New-Object System.Text.UTF8Encoding($false)))
    return $true
  }
  $missingManifestBlocked = (-not [bool]$missing.Ok)

  $missingHashManifest = [ordered]@{
    version = 1
    algorithm = 'SHA256'
    files = [ordered]@{}
  }
  [System.IO.File]::WriteAllText($fakeManifestPath, ($missingHashManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  $missingHash = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'driver.ps1' -ManifestRelativePath 'security/script-integrity.json' -Action {
    [System.IO.File]::WriteAllText($marker, 'missing-hash-started', (New-Object System.Text.UTF8Encoding($false)))
    return $true
  }
  $missingHashBlocked = ((-not [bool]$missingHash.Ok) -and $missingHash.Reason -eq 'missing_hash')

  $badAlgorithmManifest = [ordered]@{
    version = 1
    algorithm = 'MD5'
    files = [ordered]@{
      'driver.ps1' = $fakeDriverHash
    }
  }
  [System.IO.File]::WriteAllText($fakeManifestPath, ($badAlgorithmManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  $badAlgorithm = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'driver.ps1' -ManifestRelativePath 'security/script-integrity.json' -Action {
    [System.IO.File]::WriteAllText($marker, 'bad-algorithm-started', (New-Object System.Text.UTF8Encoding($false)))
    return $true
  }
  $badAlgorithmBlocked = ((-not [bool]$badAlgorithm.Ok) -and $badAlgorithm.Reason -eq 'bad_algorithm')

  $missingFileManifest = [ordered]@{
    version = 1
    algorithm = 'SHA256'
    files = [ordered]@{
      'missing.ps1' = $fakeDriverHash
    }
  }
  [System.IO.File]::WriteAllText($fakeManifestPath, ($missingFileManifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  $missingFile = Invoke-BridgeIntegrityGuard -Root $tempRoot -RelativePath 'missing.ps1' -ManifestRelativePath 'security/script-integrity.json' -Action {
    [System.IO.File]::WriteAllText($marker, 'missing-file-started', (New-Object System.Text.UTF8Encoding($false)))
    return $true
  }
  $missingFileBlocked = ((-not [bool]$missingFile.Ok) -and $missingFile.Reason -eq 'missing_file')

  [pscustomobject][ordered]@{
    driverOk = $driverOk
    serverOk = $serverOk
    goodGuardOk = $goodGuardOk
    actionInvokedOnGood = $actionInvokedOnGood
    tamperBlocked = $tamperBlocked
    actionInvokedOnTamper = $actionInvokedOnTamper
    markerExists = $markerExists
    missingManifestBlocked = $missingManifestBlocked
    missingHashBlocked = $missingHashBlocked
    badAlgorithmBlocked = $badAlgorithmBlocked
    missingFileBlocked = $missingFileBlocked
    finalMarkerExists = (Test-Path -LiteralPath $marker)
    testPassed = ($driverOk -and $serverOk -and $goodGuardOk -and $actionInvokedOnGood -and $tamperBlocked -and (-not $actionInvokedOnTamper) -and (-not $markerExists) -and $missingManifestBlocked -and $missingHashBlocked -and $badAlgorithmBlocked -and $missingFileBlocked -and (-not (Test-Path -LiteralPath $marker)))
  } | ConvertTo-Json -Depth 5
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
