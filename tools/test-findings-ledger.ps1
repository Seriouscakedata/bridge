# Smoke-test for findings-ledger functions embedded in tools/audit.ps1
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-findings-ledger.ps1
param([string]$BridgePath = $null)

$root = if ($BridgePath) { $BridgePath } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $root 'tools\audit.ps1')

$ledgerPath = Get-FindingsLedgerPath -BridgePath $root
$testPrefix  = 'test_smoke_findings_ledger_'

# Build 3 test findings
$findings = @(
  [pscustomobject]@{ source = 'security'; category = 'unsafe-json';   severity = 'warning';  title = 'ConvertTo-Json without depth';  file = 'server.ps1'; area = 'server.ps1'; component = '' }
  [pscustomobject]@{ source = 'security'; category = 'unsafe-json';   severity = 'warning';  title = 'ConvertTo-Json without depth';  file = 'server.ps1'; area = 'server.ps1'; component = '' }
  [pscustomobject]@{ source = 'security'; category = 'auth-bypass';   severity = 'critical'; title = 'Auth bypass in admin endpoint'; file = 'server.ps1'; area = 'server.ps1'; component = '' }
)

function Fail { param([string]$msg) Write-Host "FAIL: $msg"; exit 1 }

# --- Run 1 ---
$ledger1 = Read-FindingsLedger -LedgerPath $ledgerPath
$r1 = Update-FindingsLedger -CurrentFindings $findings -Ledger $ledger1 -Now ([datetime]::UtcNow)
Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $r1.ledger

$newCount = @($r1.reportFindings | Where-Object {
  $key = New-RootCauseKey -Finding $_
  $r1.ledger[$key].state -eq 'new'
}).Count
if ($r1.reportFindings.Count -lt 2) { Fail "Run1: expected >=2 reportFindings, got $($r1.reportFindings.Count)" }

# --- Run 2 (same findings, duplicates) ---
$ledger2 = Read-FindingsLedger -LedgerPath $ledgerPath
$r2 = Update-FindingsLedger -CurrentFindings $findings -Ledger $ledger2 -Now ([datetime]::UtcNow)
Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $r2.ledger

if ($r2.suppressedCount -lt 1) { Fail "Run2: expected suppressedCount>=1, got $($r2.suppressedCount)" }

# critical must always be in reportFindings
$hasCritical = @($r2.reportFindings | Where-Object { [string]$_.severity -eq 'critical' }).Count -gt 0
if (-not $hasCritical) { Fail "Run2: critical finding must always appear in reportFindings" }

# --- Verify ledger file has entries with seenCount>=2 ---
$ledger3 = Read-FindingsLedger -LedgerPath $ledgerPath
$testEntries = @($ledger3.Values | Where-Object { [int]$_.seenCount -ge 2 })
if ($testEntries.Count -lt 1) { Fail "Ledger: expected at least 1 entry with seenCount>=2, got $($testEntries.Count)" }

# --- Cleanup test entries (remove entries we created) ---
try {
  $allKeys = @($ledger3.Keys)
  $rck1 = New-RootCauseKey -Finding $findings[0]
  $rck2 = New-RootCauseKey -Finding $findings[2]
  $ledger3.Remove($rck1)
  $ledger3.Remove($rck2)
  Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $ledger3
} catch {}

Write-Host "PASS: findings-ledger smoke test OK (run1 reportFindings=$($r1.reportFindings.Count), run2 suppressed=$($r2.suppressedCount), seenCount2+=$($testEntries.Count))"
exit 0
