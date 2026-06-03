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
  $stageDefs = @(
    @{ id='brief'; path='PROJECT_BRIEF.md'; title='Project brief'; deps=@() },
    @{ id='product'; path='DISCUSS_PRODUCT.md'; title='Product discussion'; deps=@('brief') },
    @{ id='ux'; path='DISCUSS_UX.md'; title='UX discussion'; deps=@('brief','product') },
    @{ id='ui'; path='DISCUSS_UI.md'; title='UI discussion'; deps=@('brief','product','ux') },
    @{ id='backend'; path='DISCUSS_BACKEND.md'; title='Backend discussion'; deps=@('brief','product','ux') },
    @{ id='qa'; path='DISCUSS_QA.md'; title='QA discussion'; deps=@('brief','product','ux','ui','backend') },
    @{ id='integration'; path='DISCUSS_INTEGRATION.md'; title='Integration discussion'; deps=@('brief','product','ux','ui','backend','qa') }
  )
  foreach ($sd in $stageDefs) {
    $stageText = ((1..45 | ForEach-Object { "$($sd.title) line $($_): this fixture records durable decisions, previous-stage inputs, risks, open questions, and acceptance traceability for the staged planning flow." }) -join "`n")
    [System.IO.File]::WriteAllText((Join-Path $project ([string]$sd.path)), $stageText, (New-Object System.Text.UTF8Encoding($false)))
  }
  $contract = [ordered]@{
    project_goal = 'Deliver a durable test product with enough planning depth for deterministic acceptance and UX traceability.'
    planning_flow = [ordered]@{
      stages = @($stageDefs | ForEach-Object {
        [ordered]@{
          id = [string]$_.id
          status = 'complete'
          doc = [string]$_.path
          depends_on = @($_.deps)
          summary = ('Completed staged planning fixture for ' + [string]$_.id + ', using prior decisions and preserving traceability into the final contract.')
        }
      })
    }
    scope = 'The acceptance fixture covers dashboard routes, admin moderation routes, persisted account data, UX traceability, and final verification checks.'
    non_goals = 'The acceptance fixture does not implement feature code, approve project plans automatically, or infer user roles from journey names.'
    users = @(
      'Authenticated product users who need dashboard feedback, navigation, and account state coverage.',
      'Administrative reviewers who need moderation workflows, route status checks, and durable audit evidence.'
    )
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
    backend = 'The acceptance fixture covers account state, admin moderation data, route status expectations, and durable storage checks.'
    acceptance_scenarios = @('typecheck passes','build passes','critical user journey passes')
    checks = @(
      'Run typecheck before accepting implementation atoms.',
      'Run build before accepting route and workflow changes.',
      'Run smoke coverage for critical user and admin journeys.'
    )
    risk = 'Acceptance drift can let implementation pass build while missing route, UX, or workflow coverage.'
    parallel_policy = 'Independent route and admin work may run in parallel only with disjoint files and explicit dependencies.'
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'project-contract.json'), (($contract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\project-acceptance.ps1')

  $steps = @(Get-ProjectAcceptancePlanContractSteps -ProjectRoot $project)
  Assert-True ($steps.Count -ge 24) 'expected staged contract plan steps'
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
