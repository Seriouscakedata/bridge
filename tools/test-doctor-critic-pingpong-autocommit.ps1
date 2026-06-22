#Requires -Version 5.1
# Verifies Doctor's critic_pingpong fast-path commits an existing valid diff before normal repair.

param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0
$script:Messages = @()
$script:Logs = @()
$script:CompleteDoctorCalls = 0
$script:TestBridgeRoot = Join-Path (Join-Path $BridgeRoot '.tmp') ("bridge-doctor-critic-pingpong-" + [guid]::NewGuid().ToString('N'))
$script:Git = 'C:\Program Files\Git\cmd\git.exe'

function Assert-True {
  param([bool]$Condition, [string]$Label)
  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Label"
  } else {
    $script:FailCount++
    Write-Host "FAIL: $Label"
  }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-BridgeConfig { return [pscustomobject]@{ doctor = [pscustomobject]@{ maxRepairAttempts = 3; maxRestartResumes = 3 } } }
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind)
  $script:Messages += [pscustomobject]@{ from = $From; text = $Text; kind = $Kind }
}
function Write-DoctorLog {
  param([string]$Message)
  $script:Logs += [string]$Message
}

. (Join-Path $BridgeRoot 'lib\doctor.ps1')

function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind)
  $script:Messages += [pscustomobject]@{ from = $From; text = $Text; kind = $Kind }
}
function Write-DoctorLog {
  param([string]$Message)
  $script:Logs += [string]$Message
}
function Complete-Doctor {
  $script:CompleteDoctorCalls++
  return $true
}

function Invoke-Git {
  $gitArgs = @($args)
  $output = & $script:Git -C $script:TestBridgeRoot @gitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ("git {0} failed: {1}" -f ($gitArgs -join ' '), ($output -join "`n"))
  }
  return $output
}

try {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $script:TestBridgeRoot -Force | Out-Null
  & $script:Git -C $script:TestBridgeRoot init | Out-Null
  & $script:Git -C $script:TestBridgeRoot config user.email 'doctor-test@example.invalid' | Out-Null
  & $script:Git -C $script:TestBridgeRoot config user.name 'Doctor Test' | Out-Null

  $scriptPath = Join-Path $script:TestBridgeRoot 'sample.ps1'
  [System.IO.File]::WriteAllText($scriptPath, "'base' | Out-Null`r`n", (New-Object System.Text.UTF8Encoding($true)))
  Invoke-Git add -A | Out-Null
  Invoke-Git commit -m 'base' | Out-Null

  [System.IO.File]::WriteAllText($scriptPath, "'changed' | Out-Null`r`n", (New-Object System.Text.UTF8Encoding($true)))
  $state = [pscustomobject]@{ doctor_reason = 'auditor:critic_pingpong'; doctor_active = $true }

  Write-Host '=== Doctor critic_pingpong auto-commit ==='
  $result = Invoke-DoctorCriticPingPongAutoCommit -State $state
  $commitCount = [int]((Invoke-Git rev-list --count HEAD | Select-Object -First 1).Trim())
  $status = @(Invoke-Git status --short | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $lastMessage = [string](Invoke-Git log -1 --pretty=%s | Select-Object -First 1)

  Assert-True ([bool]$result) 'critic_pingpong valid diff returns true'
  Assert-True ($commitCount -eq 2) 'valid diff creates one new commit'
  Assert-True (@($status).Count -eq 0) ("working tree is clean after auto-commit (status: {0})" -f (($status -join '; ')))
  Assert-True ($lastMessage -match '^repair\(uncommitted-diff\): doctor auto-commit on critic_pingpong') 'commit message identifies critic_pingpong repair'
  Assert-True ($script:CompleteDoctorCalls -eq 1) 'Doctor is completed after successful auto-commit'

  [System.IO.File]::WriteAllText($scriptPath, "function {`r`n", (New-Object System.Text.UTF8Encoding($true)))
  $tokens = $null; $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
  Assert-True ($parseErrors -and $parseErrors.Count -gt 0) 'parse-broken fixture is rejected by Parser.ParseFile'
  $script:CompleteDoctorCalls = 0
  $parseFail = Invoke-DoctorCriticPingPongAutoCommit -State $state
  $statusAfterParseFail = @(Invoke-Git status --short | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  Assert-True (-not [bool]$parseFail) 'parse-broken ps1 diff returns false'
  Assert-True (@($statusAfterParseFail).Count -gt 0) 'parse-broken diff is left uncommitted for normal repair'
  Assert-True ($script:CompleteDoctorCalls -eq 0) 'Doctor is not completed when ParseFile fails'

  Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
  if ($script:FailCount -gt 0) { exit 1 }
} finally {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
