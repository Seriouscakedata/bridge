$ErrorActionPreference = 'Stop'
$realRoot = 'C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $realRoot 'lib\common.ps1')

$script:RouterTestDir = Join-Path $env:TEMP ('routertest_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $script:RouterTestDir -Force | Out-Null
function Get-BridgeRoot { $script:RouterTestDir }

$config = @{
  router = @{
    minSuccess = 0.5
    minSamples = 5
    windowHours = 24
  }
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $script:RouterTestDir 'config.json'), $config, (New-Object System.Text.UTF8Encoding($false)))

$script:triageModel = 'sonnet'
$script:deepModel = 'opus'
function Get-PlannerModel {
  param([string]$TaskText, [string]$Mode)
  if ($Mode -eq 'discuss' -or $Mode -eq 'study') { return $script:deepModel }
  if ([string]$TaskText -imatch 'архитектур') { return $script:deepModel }
  return $script:triageModel
}

function Reset-TestTurns {
  param([object[]]$Rows = @())
  $p = Join-Path $script:RouterTestDir 'turns.jsonl'
  [System.IO.File]::WriteAllText($p, '', (New-Object System.Text.UTF8Encoding($false)))
  foreach ($r in @($Rows)) {
    Add-Content -LiteralPath $p -Value ($r | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
  }
}

function New-TestTurn {
  param([string]$Model, [string]$Status, [int]$MinutesAgo = 5)
  [pscustomobject]@{
    ts = ([DateTime]::UtcNow.AddMinutes(-1 * $MinutesAgo)).ToString('o')
    speaker = 'claude'
    model = $Model
    sec = 1
    status = $Status
    mode = 'normal'
  }
}

$failures = 0
function Assert-Case {
  param([string]$Name, [string]$Actual, [string]$Expected)
  if ($Actual -eq $Expected) {
    Write-Host ("PASS {0}: {1}" -f $Name, $Actual)
  } else {
    $script:failures++
    Write-Host ("FAIL {0}: expected {1}, got {2}" -f $Name, $Expected, $Actual)
  }
}

try {
  Reset-TestTurns
  Assert-Case 'escalate->opus' (Select-PlannerModel -TaskText 'простая задача' -Mode 'normal' -Escalate $true) 'opus'

  $bad = @(
    New-TestTurn -Model 'sonnet' -Status 'timeout' -MinutesAgo 1
    New-TestTurn -Model 'sonnet' -Status 'timeout' -MinutesAgo 2
    New-TestTurn -Model 'sonnet' -Status 'empty' -MinutesAgo 3
    New-TestTurn -Model 'sonnet' -Status 'error' -MinutesAgo 4
    New-TestTurn -Model 'sonnet' -Status 'timeout' -MinutesAgo 5
  )
  Reset-TestTurns -Rows $bad
  Assert-Case 'seeded-fails->opus' (Select-PlannerModel -TaskText 'простая задача' -Mode 'normal') 'opus'

  $good = @(
    New-TestTurn -Model 'sonnet' -Status 'ok' -MinutesAgo 1
    New-TestTurn -Model 'sonnet' -Status 'ok' -MinutesAgo 2
    New-TestTurn -Model 'sonnet' -Status 'ok' -MinutesAgo 3
    New-TestTurn -Model 'sonnet' -Status 'timeout' -MinutesAgo 4
    New-TestTurn -Model 'sonnet' -Status 'ok' -MinutesAgo 5
  )
  Reset-TestTurns -Rows $good
  Assert-Case 'clean-simple->sonnet' (Select-PlannerModel -TaskText 'простая задача' -Mode 'normal') 'sonnet'
  Assert-Case 'architecture->opus' (Select-PlannerModel -TaskText 'архитектура новой подсистемы' -Mode 'normal') 'opus'
} finally {
  Remove-Item -LiteralPath $script:RouterTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { exit 1 }
Write-Host 'router_test: 4/4 PASS'
