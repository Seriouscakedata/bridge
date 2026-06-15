#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$BridgeRoot = '',
  [string]$StatePath = '',
  [int]$TimeoutSec = 25
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
  $BridgeRoot = Split-Path -Parent $PSScriptRoot
}

$BridgeRoot = [System.IO.Path]::GetFullPath($BridgeRoot)
if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $BridgeRoot 'channels\main\state.json'
}
$StatePath = [System.IO.Path]::GetFullPath($StatePath)

$script:Failures = New-Object System.Collections.ArrayList

function Add-Fail {
  param([Parameter(Mandatory=$true)][string]$Message)
  [void]$script:Failures.Add($Message)
  Write-Host ("FAIL {0}" -f $Message)
}

function Add-Pass {
  param([Parameter(Mandatory=$true)][string]$Message)
  Write-Host ("PASS {0}" -f $Message)
}

function Quote-ProcessArg {
  param([Parameter(Mandatory=$true)][string]$Value)
  return '"' + ($Value -replace '"','\"') + '"'
}

function Test-Ps1Parse {
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-Fail ("missing script: {0}" -f $Path)
    return
  }

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    $first = $errors[0]
    Add-Fail ("parse error in {0} at line {1}: {2}" -f $Path, $first.Extent.StartLineNumber, $first.Message)
    return
  }

  Add-Pass ("parse ok: {0}" -f $Path)
}

function Read-AndTestState {
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-Fail ("state.json missing: {0}" -f $Path)
    return $null
  }

  $state = $null
  try {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    $state = $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Add-Fail ("state.json invalid JSON: {0}" -f (($_.Exception.Message -replace '\s+',' ').Trim()))
    return $null
  }

  Add-Pass ("state.json parses: {0}" -f $Path)
  foreach ($field in @('status','heartbeat','current_task_id')) {
    $hasField = $false
    try { $hasField = ($state.PSObject.Properties.Name -contains $field) } catch {}
    if (-not $hasField) {
      Add-Fail ("state.json missing required field: {0}" -f $field)
    } else {
      Add-Pass ("state.json has required field: {0}" -f $field)
    }
  }

  return $state
}

function Invoke-DriverSelfTestChild {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][int]$TimeoutSeconds
  )

  $driverPath = Join-Path $Root 'driver.ps1'
  if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
    Add-Fail ("driver.ps1 missing: {0}" -f $driverPath)
    return
  }

  $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-driver-selftest-' + [guid]::NewGuid().ToString('N') + '.out')
  $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-driver-selftest-' + [guid]::NewGuid().ToString('N') + '.err')
  $process = $null

  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File {0} -SelfTest -Channel main' -f (Quote-ProcessArg $driverPath))

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
      try { $process.Kill() } catch {}
      Add-Fail ("driver.ps1 -SelfTest timed out after {0}s" -f $TimeoutSeconds)
      return
    }

    $stdout = $outTask.Result
    $stderr = $errTask.Result
    [System.IO.File]::WriteAllText($stdoutPath, [string]$stdout, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($stderrPath, [string]$stderr, (New-Object System.Text.UTF8Encoding($false)))

    if ($process.ExitCode -eq 0) {
      Add-Pass 'driver.ps1 -SelfTest exit 0'
      if ([string]$stdout -match 'DRIVER SELFTEST OK') {
        Add-Pass 'driver.ps1 -SelfTest reported OK'
      } else {
        Add-Fail 'driver.ps1 -SelfTest exit 0 but OK marker missing'
      }
    } else {
      $detail = (([string]$stdout + "`n" + [string]$stderr) -replace '\s+',' ').Trim()
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no output' }
      Add-Fail ("driver.ps1 -SelfTest exit {0}: {1}" -f $process.ExitCode, $detail)
    }
  } catch {
    Add-Fail ("driver.ps1 -SelfTest failed to run: {0}" -f $_.Exception.Message)
  } finally {
    foreach ($p in @($stdoutPath, $stderrPath)) {
      try { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($process) { try { $process.Dispose() } catch {} }
  }
}

if (-not (Test-Path -LiteralPath $BridgeRoot -PathType Container)) {
  Add-Fail ("BridgeRoot missing: {0}" -f $BridgeRoot)
} else {
  Add-Pass ("BridgeRoot exists: {0}" -f $BridgeRoot)
}

Test-Ps1Parse -Path $PSCommandPath
Test-Ps1Parse -Path (Join-Path $BridgeRoot 'driver.ps1')
$state = Read-AndTestState -Path $StatePath
if ($null -ne $state -and $script:Failures.Count -eq 0) {
  Invoke-DriverSelfTestChild -Root $BridgeRoot -TimeoutSeconds $TimeoutSec
}

if ($script:Failures.Count -gt 0) {
  Write-Host ("RESULT FAIL count={0}" -f $script:Failures.Count)
  exit 1
}

Write-Host 'RESULT PASS'
exit 0
