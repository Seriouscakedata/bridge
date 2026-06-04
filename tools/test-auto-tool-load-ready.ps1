param()

. ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\lib\common.ps1')))

$realBridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:TestBridgeRoot = Join-Path $realBridgeRoot ("sandbox\toolforge-load-test-" + [guid]::NewGuid().ToString('N'))

function Get-BridgeRoot {
  return $script:TestBridgeRoot
}

$pass = 0
$fail = 0

function Assert($name, $cond) {
  if ($cond) {
    Write-Host "PASS: $name"
    $script:pass++
  } else {
    Write-Host "FAIL: $name"
    $script:fail++
  }
}

function Write-TestTool {
  param(
    [string]$Name,
    [string]$Content,
    [bool]$Bom
  )
  $dir = Get-ToolForgeRoot
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $path = Join-Path $dir "$Name.ps1"
  $enc = New-Object System.Text.UTF8Encoding($Bom)
  [System.IO.File]::WriteAllText($path, $Content, $enc)
  return [System.IO.Path]::GetFullPath($path)
}

function Register-TestTool {
  param(
    [string]$Name,
    [string]$Path
  )
  $hash = Get-AutoToolFileHash -Path $Path
  Register-AutoTool -Name $Name -Contract "test $Name" -File "tools/auto/$Name.ps1" -Status 'active' -Sha256 $hash | Out-Null
}

try {
  $toolRoot = Get-ToolForgeRoot
  New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null

  $goodPath = Write-TestTool -Name 'GoodTool' -Content "function Invoke-GoodTool { return 'ok' }`r`n" -Bom $true
  Register-TestTool -Name 'GoodTool' -Path $goodPath

  $noBomPath = Write-TestTool -Name 'NoBomTool' -Content "function Invoke-NoBomTool { return 'ok' }`r`n" -Bom $false
  Register-TestTool -Name 'NoBomTool' -Path $noBomPath

  $badSyntaxPath = Write-TestTool -Name 'BadSyntaxTool' -Content "function Invoke-BadSyntaxTool {`r`n" -Bom $true
  Register-TestTool -Name 'BadSyntaxTool' -Path $badSyntaxPath

  $tamperedPath = Write-TestTool -Name 'TamperedTool' -Content "function Invoke-TamperedTool { return 'ok' }`r`n" -Bom $true
  Register-TestTool -Name 'TamperedTool' -Path $tamperedPath
  $tamperEnc = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($tamperedPath, "function Invoke-TamperedTool { return 'changed' }`r`n", $tamperEnc)

  Assert 'active BOM-valid tool is load-ready' (Test-AutoToolLoadReady -Path $goodPath)
  Assert 'active tool without BOM is rejected' (-not (Test-AutoToolLoadReady -Path $noBomPath))
  Assert 'active tool with parse error is rejected' (-not (Test-AutoToolLoadReady -Path $badSyntaxPath))
  Assert 'active tool with hash mismatch is rejected' (-not (Test-AutoToolLoadReady -Path $tamperedPath))
  Assert 'immediate pre-dot-source helper rejects tampered file' (-not (Test-AutoToolLoadReady -Path $tamperedPath))

  $activePaths = @(Get-ActiveAutoToolPaths)
  Assert 'Get-ActiveAutoToolPaths includes only the load-ready tool' ($activePaths.Count -eq 1 -and [string]::Equals([string]$activePaths[0], $goodPath, [System.StringComparison]::OrdinalIgnoreCase))
} finally {
  try { Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 } else { exit 0 }
