param()
$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $bridgeRoot 'driver\40-agent-invoke.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Name)
  if (-not $Condition) {
    Write-Host "FAIL: $Name"
    exit 1
  }
  Write-Host "PASS: $Name"
}

$authText = 'Failed to authenticate. API Error: 401 Invalid authentication credentials'
Assert-True (Test-AgentAuthFailureText -Text $authText) '401 auth text is classified'
Assert-True (-not (Test-AgentAuthFailureText -Text 'STATUS: CONTINUE')) 'normal planner status is not classified'

$turnSource = Get-Content -LiteralPath (Join-Path $bridgeRoot 'driver\83-loop-agent-turn.ps1') -Raw -Encoding UTF8
Assert-True ($turnSource -match '\$turnResult\.status\s+-eq\s+''auth_error''') 'loop has auth_error branch'
Assert-True ($turnSource -match '\$s\.paused\s*=\s*\$true') 'auth_error branch pauses channel'
Assert-True ($turnSource -match 'Abort-Doctor\s+-Reason\s+\("operator auth required: "') 'auth_error aborts active Doctor'
Assert-True ($turnSource -match 'retry/Doctor loop') 'auth_error message documents loop stop'

Write-Host 'AGENT AUTH ERROR CLASSIFICATION TEST OK'
