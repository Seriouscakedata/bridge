#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
$auditPath  = Join-Path $bridgeRoot 'tools\audit.ps1'

# ── Case 1: ParseFile clean ──────────────────────────────────────────────────
Write-Host "=== Case 1: ParseFile tools/audit.ps1 ==="
$parseErrors = $null; $parseTokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($auditPath, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    Write-Host "FAIL: ParseFile errors: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    exit 1
}
Write-Host "PASS: ParseFile 0 errors"

# ── Dot-source (safe: main-guarded) ─────────────────────────────────────────
. $auditPath

# Stubs (defined AFTER dot-source to override if needed)
function Write-AuditLog { }
$script:addIdeaCalled = $false
function Add-Idea { $script:addIdeaCalled = $true; return 'STUB' }

$pass = 1
$fail = 0

function Assert-Eq {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label — expected '$Expected', got '$Actual'"
        $script:fail++
    }
}
function Assert-True {
    param($Value, [string]$Label)
    if ($Value) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label — expected `$true, got '$Value'"
        $script:fail++
    }
}

# ── Case 2: helper default returns $true ────────────────────────────────────
Write-Host "=== Case 2: Test-AuditDirectDeepFilingDisabled default ==="
Assert-True (Test-AuditDirectDeepFilingDisabled) 'default returns $true'

# ── Case 3: helper with Config.directDeepFilingDisabled=$false ──────────────
Write-Host "=== Case 3: Test-AuditDirectDeepFilingDisabled -Config false ==="
$cfg = [pscustomobject]@{ directDeepFilingDisabled = $false }
Assert-Eq (Test-AuditDirectDeepFilingDisabled -Config $cfg) $false 'Config=$false returns $false'

# ── Case 4: bypass gate — nothing filed, Add-Idea not called ────────────────
Write-Host "=== Case 4: Add-DeepAuditFindingsToBacklog early-return guard ==="
$script:addIdeaCalled = $false
$ctx = [pscustomobject]@{ kind = 'bridge'; backlog_channel = 'main' }
$dc  = [pscustomobject]@{
    findings = @(
        [pscustomobject]@{ severity='critical'; category='x'; file='f.ps1'; line=1; finding='y'; recommendation='z' }
    )
}
$errList = [System.Collections.ArrayList]::new()
$r = Add-DeepAuditFindingsToBacklog -Root (Get-Location).Path -AuditCtx $ctx `
    -DeepCodexResult $dc -DeepClaudeResult $null -DeepModelAgentResults @() `
    -AddIdeaAvailable $true -Errors ([ref]$errList)

Assert-Eq $r.deepFiled 0 'deepFiled==0 (bypass closed)'
Assert-Eq $r.deepCodexCount 0 'deepCodexCount==0'
Assert-Eq $r.deepClaudeCount 0 'deepClaudeCount==0'
Assert-Eq $r.deepModelAgentCount 0 'deepModelAgentCount==0'
Assert-True (-not $script:addIdeaCalled) 'Add-Idea NOT called (bypass closed)'

Write-Host ""
Write-Host "=== RESULT: $pass PASS, $fail FAIL ==="
if ($fail -gt 0) { exit 1 }