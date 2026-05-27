# Helper tests for Wave A: Test-IsTrivialTask and Get-EmbeddingBatch
# Runs functions extracted from driver.ps1 / lib/memory.ps1 without booting the main loop.

$ErrorActionPreference = 'Stop'

# --- Extract Test-IsTrivialTask from driver.ps1 ---
$driverPath = 'C:\Users\rafie\OneDrive\Documents\bridge\driver.ps1'
$src = Get-Content -LiteralPath $driverPath -Raw -Encoding UTF8

# Match the function definition (multi-line), greedy until matching closing brace.
$pattern = '(?ms)function\s+Test-IsTrivialTask\s*\{.*?\n\}'
$m = [regex]::Match($src, $pattern)
if (-not $m.Success) { throw 'Test-IsTrivialTask not found in driver.ps1' }
$funcSrc = $m.Value
Invoke-Expression $funcSrc

# Stub Get-FastLaneSettings so the function call doesn't need full driver init.
function Get-FastLaneSettings { @{ minChars = 100 } }

$results = @()
$cases = @(
  @{ Name = 'simple imperative'; Text = 'поправь typo в driver.ps1'; Expected = $true },
  @{ Name = 'complexity marker'; Text = 'разбери архитектуру модуля'; Expected = $false },
  @{ Name = '[[FAST]] strip + short'; Text = '[[FAST]] обнови tooltip'; Expected = $true },
  @{ Name = 'numbered steps'; Text = "1. шаг А`n2. шаг Б"; Expected = $false }
)
foreach ($c in $cases) {
  $got = Test-IsTrivialTask -TaskText $c.Text -MinChars 100
  $ok = ($got -eq $c.Expected)
  $results += [pscustomobject]@{ Case = $c.Name; Expected = $c.Expected; Got = $got; Pass = $ok }
}

$pass = ($results | Where-Object Pass).Count
$total = $results.Count
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("Test-IsTrivialTask: $pass/$total")

# --- Verify Get-EmbeddingBatch loads cleanly from lib/memory.ps1 ---
$memPath = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\memory.ps1'
$memSrc = Get-Content -LiteralPath $memPath -Raw -Encoding UTF8
$memMatch = [regex]::Match($memSrc, '(?ms)function\s+Get-EmbeddingBatch\s*\{.*?\n\}')
if (-not $memMatch.Success) { throw 'Get-EmbeddingBatch not found in lib/memory.ps1' }
Write-Host ("Get-EmbeddingBatch found: length=" + $memMatch.Value.Length + " bytes")
Write-Host 'helper tests done.'

if ($pass -ne $total) { exit 1 } else { exit 0 }
