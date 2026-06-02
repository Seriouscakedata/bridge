param()

$ErrorActionPreference = 'Stop'

$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-project-acceptance-contract-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

try {
  $project = Join-Path $script:TestRoot 'project'
  New-Item -ItemType Directory -Path (Join-Path $project '.bridge') -Force | Out-Null
  $mapText = ((1..80 | ForEach-Object { "Map line $($_): product surfaces, workflows, data, routes, risks, and UX acceptance traceability." }) -join "`n")
  $planText = ((1..100 | ForEach-Object { "Plan line $($_): chapter, dependency, implementation atom, checks, and final acceptance coverage." }) -join "`n")
  [System.IO.File]::WriteAllText((Join-Path $project 'PROJECT_MAP.md'), $mapText, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $project 'PROJECT_PLAN.md'), $planText, (New-Object System.Text.UTF8Encoding($false)))
  $contract = [ordered]@{
    project_goal = 'Deliver a durable test product with enough planning depth for deterministic acceptance and UX traceability.'
    requirements = @('first requirement','second requirement','third requirement')
    screens = @(
      [ordered]@{ id='dashboard'; path='/dashboard'; expected_status=200; must_contain=@('Dashboard','Account') },
      [ordered]@{ id='admin'; path='/admin'; expected_status=@(302,307) }
    )
    user_journeys = @(
      [ordered]@{ id='user-flow'; steps=@('register','login','use product') },
      [ordered]@{ id='admin-flow'; steps=@('login as admin','review','delete') }
    )
    ux_contract = [ordered]@{ navigation='Primary user journeys must expose clear navigation and feedback.' }
    acceptance_scenarios = @('typecheck passes','build passes','critical user journey passes')
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'project-contract.json'), (($contract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\project-acceptance.ps1')

  $steps = @(Get-ProjectAcceptancePlanContractSteps -ProjectRoot $project)
  Assert-True ($steps.Count -ge 9) 'expected contract plan steps'
  $fails = @($steps | Where-Object { -not [bool]$_.ok })
  Assert-True ($fails.Count -eq 0) ('expected valid contract, failed: ' + (($fails | ForEach-Object { [string]$_.name }) -join ', '))

  $webSpecs = @(Get-ProjectAcceptancePlanContractWebSpecs -ProjectRoot $project)
  Assert-True ($webSpecs.Count -eq 2) ('expected two web specs, got ' + [string]$webSpecs.Count)
  Assert-True (@($webSpecs[0].must_contain).Count -ge 1) 'expected must_contain to be preserved'
  $adminSpec = @($webSpecs | Where-Object { [string]$_.name -eq 'admin' } | Select-Object -First 1)
  Assert-True ($adminSpec.Count -eq 1 -and @($adminSpec[0].expected).Count -eq 2) 'expected status arrays to be preserved'

  Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'project-contract.json') -Force
  $missingSteps = @(Get-ProjectAcceptancePlanContractSteps -ProjectRoot $project)
  $present = @($missingSteps | Where-Object { [string]$_.name -eq 'plan-contract:present' } | Select-Object -First 1)
  Assert-True ($present.Count -eq 1 -and -not [bool]$present[0].ok) 'missing contract must fail plan-contract:present'

  Write-Output 'PROJECT ACCEPTANCE CONTRACT TEST OK'
} finally {
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
