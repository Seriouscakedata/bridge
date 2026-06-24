# Smoke-test for findings-ledger functions embedded in tools/audit.ps1
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-findings-ledger.ps1
param([string]$BridgePath = $null)

$root = if ($BridgePath) { $BridgePath } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $root 'tools\audit.ps1')

$tmpDir = Join-Path (Join-Path $root 'audit\tmp') ('test-findings-ledger-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$ledgerPath = Get-FindingsLedgerPath -BridgePath $root -AuditDir $tmpDir
$testPrefix  = 'test_smoke_findings_ledger_'

# Build 3 test findings
$findings = @(
  [pscustomobject]@{ source = 'security'; category = 'unsafe-json';   severity = 'warning';  title = 'ConvertTo-Json without depth';  file = 'server.ps1'; area = 'server.ps1'; component = '' }
  [pscustomobject]@{ source = 'security'; category = 'unsafe-json';   severity = 'warning';  title = 'ConvertTo-Json without depth';  file = 'server.ps1'; area = 'server.ps1'; component = '' }
  [pscustomobject]@{ source = 'security'; category = 'auth-bypass';   severity = 'critical'; title = 'Auth bypass in admin endpoint'; file = 'server.ps1'; area = 'server.ps1'; component = '' }
)

function Fail { param([string]$msg) Write-Host "FAIL: $msg"; exit 1 }

try {
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

  # --- Run 3 (warning disappeared; structural absence closes it as fixed) ---
  $ledger3 = Read-FindingsLedger -LedgerPath $ledgerPath
  $r3 = Update-FindingsLedger -CurrentFindings @($findings[2]) -Ledger $ledger3 -Now ([datetime]::UtcNow)
  Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $r3.ledger

  $warningKey = New-RootCauseKey -Finding $findings[0]
  $warningEntry = $r3.ledger[$warningKey]
  if ([string]$warningEntry.state -ne 'fixed' -or [string]$warningEntry.status -ne 'fixed') {
    Fail "Run3: expected disappeared warning state/status fixed, got state=$($warningEntry.state) status=$($warningEntry.status)"
  }
  if ([string]$warningEntry.fixedVerification.method -ne 'rootCauseKey_absent_from_current_findings') {
    Fail "Run3: expected structural fixedVerification.method, got $($warningEntry.fixedVerification.method)"
  }
  if ([int]$r3.fixedCount -lt 1) { Fail "Run3: expected fixedCount>=1, got $($r3.fixedCount)" }

  # --- Run 4 (fixed warning reappears; ledger must flag regression) ---
  $ledger4 = Read-FindingsLedger -LedgerPath $ledgerPath
  $r4 = Update-FindingsLedger -CurrentFindings $findings -Ledger $ledger4 -Now ([datetime]::UtcNow)
  Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $r4.ledger
  $regressedEntry = $r4.ledger[$warningKey]
  if ([string]$regressedEntry.state -ne 'regressed' -or [string]$regressedEntry.status -ne 'regressed') {
    Fail "Run4: expected reappeared warning state/status regressed, got state=$($regressedEntry.state) status=$($regressedEntry.status)"
  }
  $regressedReported = @($r4.reportFindings | Where-Object { (New-RootCauseKey -Finding $_) -eq $warningKey }).Count -gt 0
  if (-not $regressedReported) { Fail "Run4: expected regressed finding to be reported" }

  # --- Verify ledger file has entries with seenCount>=2 ---
  $ledger5 = Read-FindingsLedger -LedgerPath $ledgerPath
  $testEntries = @($ledger5.Values | Where-Object { [int]$_.seenCount -ge 2 })
  if ($testEntries.Count -lt 1) { Fail "Ledger: expected at least 1 entry with seenCount>=2, got $($testEntries.Count)" }

  Write-Host "PASS: findings-ledger smoke test OK (run1 reportFindings=$($r1.reportFindings.Count), run2 suppressed=$($r2.suppressedCount), run3 fixed=$($r3.fixedCount), run4 regressed=$([string]$regressedEntry.state), seenCount2+=$($testEntries.Count))"
  exit 0
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
