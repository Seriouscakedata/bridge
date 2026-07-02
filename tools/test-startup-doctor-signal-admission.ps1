# test-startup-doctor-signal-admission.ps1 - startup admission for watchdog repair.signal before normal resume
param([string]$BridgeRoot = $null)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Split-Path -Parent $PSScriptRoot }

$d60 = Join-Path $BridgeRoot 'driver\60-startup.ps1'
$src = [System.IO.File]::ReadAllText($d60, [System.Text.Encoding]::UTF8)
$fnStart = $src.IndexOf('function Test-DriverStartupPendingDoctorSignal')
$fnEnd = $src.IndexOf('Sweep-AgentOrphans', $fnStart)
if ($fnStart -lt 0 -or $fnEnd -le $fnStart) {
  Write-Error 'startup Doctor signal admission function block not found'
  exit 1
}
Invoke-Expression $src.Substring($fnStart, $fnEnd - $fnStart)

$pass = 0
$fail = 0
function Assert-True {
  param([bool]$Cond, [string]$Message)
  if ($Cond) { $script:pass++ }
  else {
    $script:fail++
    Write-Host "FAIL $Message"
  }
}
function Assert-Eq {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -eq $Expected) { $script:pass++ }
  else {
    $script:fail++
    Write-Host "FAIL $Message : got '$Actual' expected '$Expected'"
  }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('startup-doctor-signal-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path (Join-Path $tmp 'control') -Force | Out-Null
  function Get-BridgeRoot { return $script:TestRoot }
  $script:TestRoot = $tmp

  $state = [pscustomobject]@{
    current_task = 'original project task'
    held_task = ''
    doctor_active = $false
  }

  Assert-True (-not (Test-DriverStartupPendingDoctorSignal -State $state)) 'no repair.signal does not trigger'

  [System.IO.File]::WriteAllText((Join-Path $tmp 'control\repair.signal'), 'watchdog_rollback_api_stuck', [System.Text.Encoding]::UTF8)
  Assert-True (Test-DriverStartupPendingDoctorSignal -State $state) 'current_task + repair.signal triggers'

  $script:SignalRead = $false
  $script:ActivatedReason = ''
  $script:ActivatedDetail = ''
  function Test-DoctorSignal {
    $script:SignalRead = $true
    return 'watchdog_rollback_api_stuck'
  }
  function Activate-Doctor {
    param([string]$Reason, [string]$Detail = '')
    $script:ActivatedReason = $Reason
    $script:ActivatedDetail = $Detail
    return $true
  }

  $admitted = Invoke-DriverStartupDoctorSignalAdmission -State $state
  Assert-True $admitted 'admission returns true for watchdog repair.signal'
  Assert-True $script:SignalRead 'repair.signal is consumed through Test-DoctorSignal'
  Assert-Eq $script:ActivatedReason 'watchdog_rollback_api_stuck' 'Doctor receives signal reason'
  Assert-True ($script:ActivatedDetail -match 'before startup resume') 'Doctor detail marks pre-resume admission'

  $doctorState = [pscustomobject]@{ current_task = 'task'; held_task = ''; doctor_active = $true }
  Assert-True (-not (Test-DriverStartupPendingDoctorSignal -State $doctorState)) 'already-active Doctor does not trigger'

  $heldState = [pscustomobject]@{ current_task = 'task'; held_task = 'held'; doctor_active = $false }
  Assert-True (-not (Test-DriverStartupPendingDoctorSignal -State $heldState)) 'existing held_task does not trigger'

  $idleState = [pscustomobject]@{ current_task = ''; held_task = ''; doctor_active = $false }
  Assert-True (-not (Test-DriverStartupPendingDoctorSignal -State $idleState)) 'empty current_task does not trigger'

  Write-Host "Results: $pass passed, $fail failed"
  if ($fail -gt 0) { exit 1 }
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($tmp)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
