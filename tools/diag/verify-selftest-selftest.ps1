#Requires -Version 5.1
# VERIFY-COVERS: lib/verify-selftest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\verify-selftest.ps1')

$sandbox = Join-Path $env:TEMP ('verify-selftest-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path (Join-Path $sandbox 'lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox 'tools\diag') -Force | Out-Null

function Write-Utf8File {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content
  )
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-ParseDiag {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$TargetRelativePath,
    [switch]$UseMarker
  )

  $marker = ''
  if ($UseMarker) { $marker = "# VERIFY-COVERS: $TargetRelativePath`n" }
  $content = @"
$marker`$ErrorActionPreference = 'Stop'
`$root = Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)
`$target = Join-Path `$root '$($TargetRelativePath -replace '/','\')'
try {
  [void][scriptblock]::Create([System.IO.File]::ReadAllText(`$target, [System.Text.Encoding]::UTF8))
  Write-Host 'DIAG: PASS'
  exit 0
} catch {
  Write-Host ('DIAG: FAIL ' + `$_.Exception.Message)
  exit 1
}
"@
  Write-Utf8File -Path $Path -Content $content
}

$fails = 0
function Assert {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fails++ }
}

Write-Utf8File -Path (Join-Path $sandbox 'lib\alpha.ps1') -Content "function Alpha { return 'ok' }`n"
Write-Utf8File -Path (Join-Path $sandbox 'lib\beta.ps1') -Content "function Beta { return 'ok' }`n"
Write-Utf8File -Path (Join-Path $sandbox 'lib\orphan.ps1') -Content "function Orphan { return 'ok' }`n"
Write-ParseDiag -Path (Join-Path $sandbox 'tools\diag\alpha-selftest.ps1') -TargetRelativePath 'lib/alpha.ps1' -UseMarker
Write-ParseDiag -Path (Join-Path $sandbox 'tools\diag\beta-smoke.ps1') -TargetRelativePath 'lib/beta.ps1'

Write-Host "[V0] alpha plan selects selftest coverage"
$plan = Get-VerifySelftestPlan -Root $sandbox -ChangedPaths 'lib/alpha.ps1'
Assert 'V0 ready plan' ($plan.Ok -and $plan.Reason -eq 'ready')
Assert 'V0 alpha selected' ($plan.Diagnostics.RelativePath -contains 'tools/diag/alpha-selftest.ps1')

Write-Host "`n[V1] valid alpha -> gate passes"
$result = Invoke-VerifySelftestGate -Root $sandbox -ChangedPaths 'lib/alpha.ps1'
Assert 'V1 ok' ($result.Ok -and $result.Reason -eq 'verified')
Assert 'V1 diag pass' (($result.Diagnostics | Where-Object { $_.DiagnosticRelativePath -eq 'tools/diag/alpha-selftest.ps1' }).ExitCode -eq 0)

Write-Host "`n[V2] broken alpha -> gate blocks DONE"
Write-Utf8File -Path (Join-Path $sandbox 'lib\alpha.ps1') -Content 'function Alpha {'
$result = Invoke-VerifySelftestGate -Root $sandbox -ChangedPaths 'lib/alpha.ps1'
Assert 'V2 blocked' ((-not $result.Ok) -and $result.Reason -eq 'selftest_failed')
Assert 'V2 failed diag recorded' ($result.FailedDiagnostics -contains 'tools/diag/alpha-selftest.ps1')

Write-Host "`n[V3] beta smoke auto-detected from lib reference"
$result = Invoke-VerifySelftestGate -Root $sandbox -ChangedPaths 'lib/beta.ps1'
Assert 'V3 ok' ($result.Ok -and $result.Reason -eq 'verified')
Assert 'V3 smoke selected' ($result.Diagnostics.DiagnosticRelativePath -contains 'tools/diag/beta-smoke.ps1')

Write-Host "`n[V4] uncovered lib -> gate fails before DONE"
$result = Invoke-VerifySelftestGate -Root $sandbox -ChangedPaths 'lib/orphan.ps1'
Assert 'V4 missing coverage' ((-not $result.Ok) -and $result.Reason -eq 'missing_coverage')
Assert 'V4 orphan reported' ($result.UncoveredLibPaths -contains 'lib/orphan.ps1')

Write-Host "`n[V5] hanging diagnostic times out instead of blocking verify forever"
$sleepDiag = Join-Path $sandbox 'tools\diag\slow-selftest.ps1'
Write-Utf8File -Path $sleepDiag -Content "# VERIFY-COVERS: lib/alpha.ps1`nStart-Sleep -Seconds 5`nWrite-Host 'SLOW: DONE'`nexit 0`n"
$timeoutResult = Invoke-VerifySelftestDiagnostic -Root $sandbox -DiagnosticPath $sleepDiag -TimeoutSec 1
Assert 'V5 timeout recorded' ((-not $timeoutResult.Ok) -and $timeoutResult.TimedOut -and $timeoutResult.ExitCode -eq 124)
Assert 'V5 timeout output explains failure' (@($timeoutResult.Output) -join "`n" -match 'TIMEOUT after 1s')

Write-Host "`n[V6] Get-VerifySelftestRoot calls and validates Get-BridgeRoot"
if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) {
  Assert 'V6 skipped when external Get-BridgeRoot is already defined' $true
} else {
  try {
    $script:verifySelftestRootProbe = $root
    function global:Get-BridgeRoot { return $script:verifySelftestRootProbe }
    $resolvedRoot = Get-VerifySelftestRoot
    Assert 'V6 valid bridge root resolved' ($resolvedRoot -eq ([System.IO.Path]::GetFullPath($root).TrimEnd('\','/')))
    $script:verifySelftestRootProbe = Join-Path $sandbox 'missing-root'
    $rootRejected = $false
    try { Get-VerifySelftestRoot | Out-Null } catch { $rootRejected = ($_.Exception.Message -match 'Bridge root') }
    Assert 'V6 invalid bridge root rejected' $rootRejected
  } finally {
    Remove-Item -Path Function:\Get-BridgeRoot -ErrorAction SilentlyContinue
    Remove-Variable -Name verifySelftestRootProbe -Scope script -ErrorAction SilentlyContinue
  }
}

Write-Host "`n[GR1] docs-only paths -> empty gate-regression scope"
$scope = Get-GateRegressionScope -ChangedPaths @('docs/README.md','docs/architecture.md','CHANGELOG.md')
Assert 'GR1 docs-only scope empty' ($scope.Count -eq 0)

Write-Host "`n[GR2] HTML/CSS-only paths -> empty gate-regression scope"
$scope = Get-GateRegressionScope -ChangedPaths @('web/index.html','web/app.css','web/logo.svg')
Assert 'GR2 html-only scope empty' ($scope.Count -eq 0)

Write-Host "`n[GR3] config/json/jsonl-only paths -> empty gate-regression scope"
$scope = Get-GateRegressionScope -ChangedPaths @('config.json','.claude/settings.json','backlog.jsonl')
Assert 'GR3 config-only scope empty' ($scope.Count -eq 0)

Write-Host "`n[GR4] driver/lib/tools .ps1 paths -> non-empty gate-regression scope"
$scope = Get-GateRegressionScope -ChangedPaths @('driver.ps1','lib/verify-selftest.ps1','lib/backlog.ps1','tools/test-project-memory.ps1')
Assert 'GR4 scope non-empty' ($scope.Count -gt 0)
Assert 'GR4 scope contains driver.ps1' ($scope -contains 'driver.ps1')
Assert 'GR4 scope contains lib path' ($scope -contains 'lib/verify-selftest.ps1')
Assert 'GR4 scope contains tools/test path' ($scope -contains 'tools/test-project-memory.ps1')

Write-Host "`n[GR5] Invoke-GateRegressionSuite docs-only -> skips, Ok=true (no blocking)"
$grResult = Invoke-GateRegressionSuite -BridgeRoot $root -ChangedPaths @('docs/README.md','web/index.html')
Assert 'GR5 skip ok=true' ($grResult.Ok -eq $true)
Assert 'GR5 skipped=true' ($grResult.Skipped -eq $true)
Assert 'GR5 reason empty_scope' ($grResult.Reason -eq 'empty_scope')

Write-Host "`n[GR6] Invoke-GateRegressionSuite non-empty scope + failing suite -> fail-closed"
$grSandbox = Join-Path $env:TEMP ('gr-sandbox-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path (Join-Path $grSandbox 'tools') -Force | Out-Null
Write-Utf8File -Path (Join-Path $grSandbox 'tools\run-tests.ps1') -Content "exit 1`n"
$grResult = Invoke-GateRegressionSuite -BridgeRoot $grSandbox -ChangedPaths @('lib/common.ps1') -TimeoutSec 10
Assert 'GR6 fail-closed ok=false' ($grResult.Ok -eq $false)
Assert 'GR6 fail-closed not-skipped' ($grResult.Skipped -eq $false)
Remove-Item -LiteralPath $grSandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n[GR7] hyphenated lib module -> family-prefix scoped tests (not full suite)"
$selSandbox = Join-Path $env:TEMP ('gr-sel-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path (Join-Path $selSandbox 'tools') -Force | Out-Null
foreach ($tn in @('test-backlog-foo.ps1','test-backlog-bar.ps1','test-zeta.ps1','test-gate-regression-sentinel.ps1','test-verify-chain-fastpath.ps1')) {
  Write-Utf8File -Path (Join-Path $selSandbox "tools\$tn") -Content "exit 0`n"
}
$sel = @(Get-GateRegressionTestSelection -BridgeRoot $selSandbox -Scope @('lib/backlog-core.ps1'))
Assert 'GR7 backlog-core picks family tests' (($sel -contains 'test-backlog-foo.ps1') -and ($sel -contains 'test-backlog-bar.ps1'))
Assert 'GR7 does not pick unrelated test' (-not ($sel -contains 'test-zeta.ps1'))
Assert 'GR7 not full suite' ($sel.Count -lt 5)

Write-Host "`n[GR8] uncovered lib module -> sentinel fallback (never empty, never full)"
$sel = @(Get-GateRegressionTestSelection -BridgeRoot $selSandbox -Scope @('lib/architect.ps1'))
Assert 'GR8 sentinel selected' (($sel -contains 'test-gate-regression-sentinel.ps1') -and ($sel -contains 'test-verify-chain-fastpath.ps1'))
Assert 'GR8 only sentinel set' ($sel.Count -eq 2)

Write-Host "`n[GR9] control-plane driver path with no exact test -> sentinel fallback (never full suite)"
$sel = @(Get-GateRegressionTestSelection -BridgeRoot $selSandbox -Scope @('driver/40-agent-invoke.ps1'))
Assert 'GR9 never empty on non-empty scope' ($sel.Count -gt 0)
Assert 'GR9 falls back to sentinel not full' ($sel.Count -le 2)
Remove-Item -LiteralPath $selSandbox -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'VERIFY-SELFTEST: PASS' }
else { Write-Host "VERIFY-SELFTEST: FAIL ($fails assertion(s))"; exit 1 }
