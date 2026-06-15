$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $repoRoot 'lib\agent-wait.ps1')

$script:PowerShellExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PowerShellExe)) {
  throw 'Cannot resolve current PowerShell executable path.'
}

function New-AgentWaitTestDir {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-wait-test-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  return $dir
}

function Start-AgentWaitChild {
  param(
    [string]$Dir,
    [string]$ScriptText
  )

  $childScript = Join-Path $Dir 'child.ps1'
  $outFile = Join-Path $Dir 'stdout.txt'
  $errFile = Join-Path $Dir 'stderr.txt'
  [System.IO.File]::WriteAllBytes($outFile, [byte[]]@())
  [System.IO.File]::WriteAllBytes($errFile, [byte[]]@())
  $enc = New-Object System.Text.UTF8Encoding($true)
  $childBody = @"
param([string]`$OutFile, [string]`$ErrFile)
`$ErrorActionPreference = 'Stop'
function Write-AgentWaitOutput {
  param([string]`$Text)
  Add-Content -LiteralPath `$OutFile -Value `$Text -Encoding UTF8
}

$ScriptText
"@
  [System.IO.File]::WriteAllText($childScript, $childBody, $enc)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:PowerShellExe
  $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}"' -f $childScript, $outFile, $errFile)
  $psi.UseShellExecute = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $null = $proc.Handle
  return [pscustomobject]@{ Proc=$proc; OutFile=$outFile; ErrFile=$errFile }
}

function Stop-AgentWaitChild {
  param($Proc)
  if ($Proc -and -not $Proc.HasExited) {
    Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
    try { $Proc.WaitForExit(5000) | Out-Null } catch {}
  }
}

function Invoke-AgentWaitCase {
  param(
    [string]$Name,
    [string]$ScriptText,
    [int]$TimeoutMs,
    [int]$FirstOutputGraceMs = 0,
    [int]$MaxAliveExtensionMs = 0,
    [switch]$NoSignal,
    [bool]$ExpectedOk,
    [string]$ExpectedReason
  )

  $dir = New-AgentWaitTestDir
  $child = $null
  try {
    $child = Start-AgentWaitChild -Dir $dir -ScriptText $ScriptText
    $reason = $null
    $args = @{
      Proc = $child.Proc
      TimeoutMs = $TimeoutMs
      FirstOutputGraceMs = $FirstOutputGraceMs
      MaxAliveExtensionMs = $MaxAliveExtensionMs
      StopReason = [ref]$reason
    }
    if (-not $NoSignal) {
      $args.OutFile = $child.OutFile
      $args.ErrFile = $child.ErrFile
    }
    $ok = Wait-AgentProcess @args
    if ($ok -ne $ExpectedOk -or [string]$reason -ne $ExpectedReason) {
      throw "$Name failed: ok=$ok reason=$reason expectedOk=$ExpectedOk expectedReason=$ExpectedReason"
    }
    Write-Host "PASS: $Name -> ok=$ok reason=$reason"
  } finally {
    if ($child) { Stop-AgentWaitChild -Proc $child.Proc }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-AgentWaitCase -Name 'exited' `
  -ScriptText "Write-AgentWaitOutput 'done'" `
  -TimeoutMs 30000 `
  -ExpectedOk $true `
  -ExpectedReason 'exited'

Invoke-AgentWaitCase -Name 'zero_output_grace' `
  -ScriptText "Start-Sleep -Seconds 20" `
  -TimeoutMs 30000 `
  -FirstOutputGraceMs 1000 `
  -ExpectedOk $false `
  -ExpectedReason 'zero_output_grace'

Invoke-AgentWaitCase -Name 'soft_timeout_no_signal' `
  -ScriptText "Start-Sleep -Seconds 20" `
  -TimeoutMs 1000 `
  -NoSignal `
  -ExpectedOk $false `
  -ExpectedReason 'soft_timeout_no_signal'

Invoke-AgentWaitCase -Name 'soft_timeout_output_cap' `
  -ScriptText "for (`$i = 0; `$i -lt 100; `$i++) { Write-AgentWaitOutput `"tick `$i`"; Start-Sleep -Milliseconds 200 }" `
  -TimeoutMs 1000 `
  -MaxAliveExtensionMs 1000 `
  -ExpectedOk $false `
  -ExpectedReason 'soft_timeout_output_cap'

Invoke-AgentWaitCase -Name 'max_alive_extension_zero_no_output_cap' `
  -ScriptText "for (`$i = 0; `$i -lt 24; `$i++) { Write-AgentWaitOutput `"tick `$i`"; Start-Sleep -Milliseconds 250 }" `
  -TimeoutMs 1000 `
  -MaxAliveExtensionMs 0 `
  -ExpectedOk $true `
  -ExpectedReason 'exited'
