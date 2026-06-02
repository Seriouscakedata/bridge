#Requires -Version 5.1
# Smoke test: Wait-AgentProcess -FirstOutputGraceMs cold-start fast-fail.
# Spawns a no-output process, verifies abort within grace+margin (one 5s tick).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\diag\wait-coldstart-smoke.ps1
param([int]$GraceMs = 4000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- Stubs for Wait-AgentProcess dependencies ---
$Channel    = 'smoke-test'
$bridgeRoot = $root
function Update-State { param([scriptblock]$Action) }
function Get-RuntimeRoot { return $env:TEMP }
function Add-Message { param([string]$From, [string]$Text, [string]$Kind) }

# --- Load the shared Wait-AgentProcess implementation directly ---
$waitLib = Join-Path $root 'lib\agent-wait.ps1'
if (-not (Test-Path -LiteralPath $waitLib)) { Write-Host 'FAIL: lib\agent-wait.ps1 not found'; exit 1 }
. $waitLib
$waitCommand = Get-Command Wait-AgentProcess -ErrorAction SilentlyContinue
if (-not $waitCommand -or -not $waitCommand.Parameters.ContainsKey('FirstOutputGraceMs')) {
    Write-Host 'FAIL: Wait-AgentProcess lacks -FirstOutputGraceMs'
    exit 1
}
if (-not $waitCommand.Parameters.ContainsKey('StopReason')) {
    Write-Host 'FAIL: Wait-AgentProcess lacks -StopReason'
    exit 1
}

# --- Test helpers ---
$fails = 0
function Assert {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) { Write-Host "  PASS: $Name" }
    else { Write-Host "  FAIL: $Name$(if ($Detail) { ' | ' + $Detail })"; $script:fails++ }
}

function Start-SmokePowerShell {
    param([string]$Script)
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe)) { $powerShellExe = 'powershell.exe' }
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powerShellExe
    $psi.Arguments = "-NoProfile -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

# --- Test 1: zero-output process aborts within GraceMs + one-tick margin ---
Write-Host "`n[Test 1] No-output process aborts within grace + 7s margin"
$outF = [System.IO.Path]::GetTempFileName()
$errF = [System.IO.Path]::GetTempFileName()
$p = $null
try {
    $p = Start-SmokePowerShell -Script 'Start-Sleep -Seconds 60'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $reason = $null
    $result = Wait-AgentProcess -Proc $p -TimeoutMs 900000 -OutFile $outF -ErrFile $errF -FirstOutputGraceMs $GraceMs -StopReason ([ref]$reason)
    $elapsed = $sw.ElapsedMilliseconds
    $margin  = $GraceMs + 7000   # one 5s WaitForExit tick + 2s overhead
    Assert 'returns false (early abort)' ($result -eq $false) "result=$result"
    Assert 'stop reason is zero_output_grace' ([string]$reason -eq 'zero_output_grace') "reason=$reason"
    Assert "elapsed < grace+7s margin"   ($elapsed -lt $margin) "elapsed=${elapsed}ms margin=${margin}ms"
    Write-Host "  (elapsed ${elapsed}ms, grace ${GraceMs}ms)"
} finally {
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    Remove-Item $outF, $errF -ErrorAction SilentlyContinue
}

# --- Test 2: output growth before grace prevents early abort ---
Write-Host "`n[Test 2] Output before grace is treated as liveness"
$outF = [System.IO.Path]::GetTempFileName()
$errF = [System.IO.Path]::GetTempFileName()
$p = $null
try {
    $escapedOut = $outF.Replace("'", "''")
    $p = Start-SmokePowerShell -Script "Set-Content -LiteralPath '$escapedOut' -Value 'ready' -Encoding UTF8; Start-Sleep -Seconds 8"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $reason = $null
    $result = Wait-AgentProcess -Proc $p -TimeoutMs 30000 -OutFile $outF -ErrFile $errF -FirstOutputGraceMs $GraceMs -StopReason ([ref]$reason)
    $elapsed = $sw.ElapsedMilliseconds
    Assert 'returns true after observed output' ($result -eq $true) "result=$result"
    Assert 'stop reason is exited' ([string]$reason -eq 'exited') "reason=$reason"
    Assert 'output file grew' ((Get-Item -LiteralPath $outF).Length -gt 0) "length=$((Get-Item -LiteralPath $outF).Length)"
    Write-Host "  (elapsed ${elapsed}ms, grace ${GraceMs}ms)"
} finally {
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    Remove-Item $outF, $errF -ErrorAction SilentlyContinue
}

# --- Summary ---
Write-Host ''
if ($fails -eq 0) { Write-Host 'COLDSTART-SMOKE: PASS' }
else { Write-Host "COLDSTART-SMOKE: FAIL ($fails assertion(s) failed)"; exit 1 }
