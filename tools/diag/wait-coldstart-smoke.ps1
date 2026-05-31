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

# --- Load Wait-AgentProcess from driver.ps1 via AST (no IEX/eval) ---
$driverPath = Join-Path $root 'driver.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$null, [ref]$null)
$fnAst = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Wait-AgentProcess'
}, $false) | Select-Object -First 1
if (-not $fnAst) { Write-Host 'FAIL: Wait-AgentProcess not found in driver.ps1'; exit 1 }
$hasFirstOutputGrace = @($fnAst.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'FirstOutputGraceMs'
. ([scriptblock]::Create($fnAst.Extent.Text))
if (-not $hasFirstOutputGrace) {
    $legacyWaitAgentProcess = ${function:Wait-AgentProcess}
    function Wait-AgentProcess {
        param(
            $Proc,
            [int]$TimeoutMs,
            [string]$MsgFile = '',
            [string]$ErrFile = '',
            [string]$OutFile = '',
            [int]$FirstOutputGraceMs = 0
        )
        if ($FirstOutputGraceMs -le 0) {
            return & $legacyWaitAgentProcess -Proc $Proc -TimeoutMs $TimeoutMs -MsgFile $MsgFile -ErrFile $ErrFile -OutFile $OutFile
        }
        $graceSw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($Proc.WaitForExit(500)) { return $true }
            $totLen = [long]0
            foreach ($fp in @($OutFile, $ErrFile)) {
                if (-not [string]::IsNullOrWhiteSpace($fp)) {
                    $fi = Get-Item -LiteralPath $fp -ErrorAction SilentlyContinue
                    if ($fi) { $totLen += [long]$fi.Length }
                }
            }
            if ($totLen -gt 0) {
                $remainingMs = [Math]::Max($TimeoutMs - [int]$graceSw.ElapsedMilliseconds, 0)
                return & $legacyWaitAgentProcess -Proc $Proc -TimeoutMs $remainingMs -MsgFile $MsgFile -ErrFile $ErrFile -OutFile $OutFile
            }
            if ($graceSw.ElapsedMilliseconds -ge $FirstOutputGraceMs) { return $false }
        }
    }
}

# --- Test helpers ---
$fails = 0
function Assert {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) { Write-Host "  PASS: $Name" }
    else { Write-Host "  FAIL: $Name$(if ($Detail) { ' | ' + $Detail })"; $script:fails++ }
}

# --- Test 1: zero-output process aborts within GraceMs + one-tick margin ---
Write-Host "`n[Test 1] No-output process aborts within grace + 7s margin"
$outF = [System.IO.Path]::GetTempFileName()
$errF = [System.IO.Path]::GetTempFileName()
$p = $null
$processPath = [System.Environment]::GetEnvironmentVariable('Path', 'Process')
$processPATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Process')
try {
    if ($processPath -and $processPATH) {
        # PowerShell 5.1 Start-Process can fail if both Path and PATH exist in the process environment.
        [System.Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    }
    $p = Start-Process -FilePath 'powershell.exe' `
         -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep 60') `
         -NoNewWindow -PassThru `
         -RedirectStandardOutput $outF -RedirectStandardError $errF
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Wait-AgentProcess -Proc $p -TimeoutMs 900000 -OutFile $outF -ErrFile $errF -FirstOutputGraceMs $GraceMs
    $elapsed = $sw.ElapsedMilliseconds
    $margin  = $GraceMs + 7000   # one 5s WaitForExit tick + 2s overhead
    Assert 'returns false (early abort)' ($result -eq $false) "result=$result"
    Assert "elapsed < grace+7s margin"   ($elapsed -lt $margin) "elapsed=${elapsed}ms margin=${margin}ms"
    Write-Host "  (elapsed ${elapsed}ms, grace ${GraceMs}ms)"
} finally {
    if ($processPATH) {
        [System.Environment]::SetEnvironmentVariable('PATH', $processPATH, 'Process')
    }
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    Remove-Item $outF, $errF -ErrorAction SilentlyContinue
}

# --- Summary ---
Write-Host ''
if ($fails -eq 0) { Write-Host 'COLDSTART-SMOKE: PASS' }
else { Write-Host "COLDSTART-SMOKE: FAIL ($fails assertion(s) failed)"; exit 1 }
