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
      [ordered]@{
        id='user-flow'
        access='public'
        steps=@(
          [ordered]@{ id='login-page'; action='open login'; path='/login'; expected_status=200; must_contain=@('Sign in','Email') },
          'GET /feed',
          'click primary CTA'
        )
      },
      [ordered]@{
        id='account-flow'
        role='user'
        steps=@(
          [ordered]@{ name='profile'; route='/profile' },
          'open /users/:id',
          'GET /post/[id]'
        )
      },
      [ordered]@{
        id='admin-flow'
        access='admin'
        steps=@(
          [ordered]@{ label='admin area'; path='/admin'; mustContain='Admin' },
          'review moderation queue'
        )
      }
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

  $journeySpecs = @(Get-ProjectAcceptancePlanContractJourneySpecs -ProjectRoot $project)
  Assert-True ($journeySpecs.Count -eq 4) ('expected four journey web specs, got ' + [string]$journeySpecs.Count)
  $loginJourney = @($journeySpecs | Where-Object { [string]$_.journey_id -eq 'user-flow' -and [string]$_.name -eq 'login-page' } | Select-Object -First 1)
  Assert-True ($loginJourney.Count -eq 1 -and [int]$loginJourney[0].step_index -eq 1 -and [string]$loginJourney[0].path -eq '/login') 'expected login object step from user-flow'
  Assert-True (@($loginJourney[0].expected).Count -eq 1 -and [int]$loginJourney[0].expected[0] -eq 200) 'expected explicit login status to be preserved'
  Assert-True ((@($loginJourney[0].must_contain) -join '|') -eq 'Sign in|Email') 'expected login must_contain to be preserved'
  $feedJourney = @($journeySpecs | Where-Object { [string]$_.journey_id -eq 'user-flow' -and [string]$_.path -eq '/feed' } | Select-Object -First 1)
  Assert-True ($feedJourney.Count -eq 1 -and [int]$feedJourney[0].step_index -eq 2 -and [string]$feedJourney[0].name -eq '/feed') 'expected GET /feed string step to be extracted'
  Assert-True (@($feedJourney[0].expected).Count -eq 1 -and [int]$feedJourney[0].expected[0] -eq 200) 'expected public feed default status'
  $profileJourney = @($journeySpecs | Where-Object { [string]$_.journey_id -eq 'account-flow' -and [string]$_.path -eq '/profile' } | Select-Object -First 1)
  Assert-True ($profileJourney.Count -eq 1 -and (@($profileJourney[0].expected) -contains 401) -and (@($profileJourney[0].expected) -contains 403)) 'expected protected profile default statuses from role'
  $adminJourney = @($journeySpecs | Where-Object { [string]$_.journey_id -eq 'admin-flow' -and [string]$_.path -eq '/admin' } | Select-Object -First 1)
  Assert-True ($adminJourney.Count -eq 1 -and [string]$adminJourney[0].name -eq 'admin area' -and (@($adminJourney[0].expected) -contains 401) -and (@($adminJourney[0].must_contain) -contains 'Admin')) 'expected admin journey object step'
  $dynamicJourney = @($journeySpecs | Where-Object { [string]$_.path -match ':id|\[id\]' })
  Assert-True ($dynamicJourney.Count -eq 0) 'expected dynamic journey paths to be skipped'
  $actionOnlyJourney = @($journeySpecs | Where-Object { [string]$_.name -match 'click|review' })
  Assert-True ($actionOnlyJourney.Count -eq 0) 'expected action-only journey strings to be skipped'
  foreach ($js in @($journeySpecs)) {
    Assert-True ([string]$js.source -eq 'journey') 'expected journey source marker'
  }

  $cfgFixture = Get-ProjectAcceptanceConfig -ProjectRoot $project
  $coverageStatic = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $project -Config $cfgFixture
  $coverageStaticStep = New-ProjectAcceptanceJourneyCoverageStep -Fact $coverageStatic
  Assert-True ([bool]$coverageStatic.required -and [bool]$coverageStatic.ok -and [int]$coverageStatic.journey_web_specs_count -ge 1) 'expected static journey specs to satisfy coverage'
  Assert-True ([string]$coverageStaticStep.name -eq 'plan-contract:journey-coverage' -and [bool]$coverageStaticStep.ok) 'expected coverage step to pass with static journey specs'

  $pkgA = ('{"scripts":{"smoke:browser":"cmd","smoke:ux":"cmd","smoke:api":"cmd"}}' | ConvertFrom-Json)
  $smokeA = @(Get-ProjectAcceptanceDefaultSmokeScripts -PackageJson $pkgA)
  Assert-True ($smokeA.Count -eq 3) ('expected 3 auto smoke scripts, got ' + [string]$smokeA.Count)
  Assert-True ($smokeA[0] -eq 'smoke:browser') 'expected smoke:browser first (candidate order)'
  Assert-True ($smokeA[1] -eq 'smoke:ux') 'expected smoke:ux before smoke:api (candidate order)'
  Assert-True ($smokeA[2] -eq 'smoke:api') 'expected smoke:api third'

  $pkgB = ('{"scripts":{"smoke:launch":"cmd","smoke:browser":"cmd"}}' | ConvertFrom-Json)
  $smokeB = @(Get-ProjectAcceptanceDefaultSmokeScripts -PackageJson $pkgB)
  Assert-True ($smokeB.Count -eq 1 -and $smokeB[0] -eq 'smoke:launch') 'expected only smoke:launch when orchestrator present'

  $pkgC = ('{"scripts":{"build":"next build"}}' | ConvertFrom-Json)
  $smokeC = @(Get-ProjectAcceptanceDefaultSmokeScripts -PackageJson $pkgC)
  Assert-True ($smokeC.Count -eq 0) 'expected empty default when no smoke candidates'

  $pkgJson = '{"scripts":{"smoke:browser":"cmd","smoke:ux":"cmd"}}'
  [System.IO.File]::WriteAllText((Join-Path $project 'package.json'), $pkgJson, (New-Object System.Text.UTF8Encoding($false)))
  $explicitAcc = '{"smokeScripts":["custom:smoke"]}'
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'acceptance.json'), $explicitAcc, (New-Object System.Text.UTF8Encoding($false)))
  $cfgExplicit = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgExplicit.smokeScripts.Count -eq 1 -and [string]$cfgExplicit.smokeScripts[0] -eq 'custom:smoke') 'expected explicit smokeScripts preserved, no auto-add'
  Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'acceptance.json') -Force

  $cfgAuto = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgAuto.smokeScripts.Count -eq 2 -and [string]$cfgAuto.smokeScripts[0] -eq 'smoke:browser' -and [string]$cfgAuto.smokeScripts[1] -eq 'smoke:ux') 'expected auto-discovered smoke scripts in config'
  Remove-Item -LiteralPath (Join-Path $project 'package.json') -Force

  $cfgEmpty = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgEmpty.smokeScripts.Count -eq 0) 'expected empty smokeScripts when no package.json'

  $routeLikeDir = Join-Path $project 'app\login'
  New-Item -ItemType Directory -Path $routeLikeDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $routeLikeDir 'page.tsx'), 'export default function Page() { return null }', (New-Object System.Text.UTF8Encoding($false)))
  $emptyServerChecksAcc = '{"server":{"checks":[]}}'
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'acceptance.json'), $emptyServerChecksAcc, (New-Object System.Text.UTF8Encoding($false)))
  $cfgExplicitEmptyChecks = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgExplicitEmptyChecks.checks.Count -eq 0) ('expected explicit empty server.checks to suppress discovered web checks, got ' + ((@($cfgExplicitEmptyChecks.checks) | ForEach-Object { [string]$_ }) -join ','))
  Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'acceptance.json') -Force
  Remove-Item -LiteralPath (Join-Path $project 'app') -Recurse -Force

  $cliOnlyContract = [ordered]@{
    project_goal = 'Deliver a local CLI pipeline that writes durable artifacts and reports for operator review.'
    requirements = @('plan command works','artifact manifest exists','report output exists')
    surfaces = @(
      [ordered]@{ id='cli-plan'; kind='cli'; command='slopvid plan --title <title>'; purpose='Create deterministic planning artifacts.' },
      [ordered]@{ id='run-manifest'; kind='artifact'; path='runs/<run_id>/manifest.json'; purpose='Machine-readable run state.' },
      [ordered]@{ id='report'; kind='artifact'; path='runs/<run_id>/reports/report.html'; purpose='Human review surface.' }
    )
    journeys = @(
      [ordered]@{
        id='title-to-report'
        steps=@(
          'Run planning mode for a title.',
          'Review generated manifest and report artifacts.',
          'Confirm CLI output records completion.'
        )
      },
      [ordered]@{
        id='resume-validation'
        steps=@(
          'Run validation for an existing run id.',
          'Inspect validation records in manifest.',
          'Regenerate failed assets outside web UI.'
        )
      }
    )
    ux_contract = [ordered]@{ primary_interface='CLI plus generated report artifacts.' }
    checks = @(
      [ordered]@{ id='unit'; command='pytest'; purpose='Run unit and pipeline tests.' },
      [ordered]@{ id='lint'; command='ruff check .'; purpose='Run linter.' },
      [ordered]@{ id='plan-smoke'; command='slopvid plan --title "The Trial" --provider stub'; purpose='Run CLI smoke.' }
    )
    acceptance_scenarios = @('pytest passes','ruff passes','CLI smoke writes artifacts')
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'project-contract.json'), (($cliOnlyContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $cfgCliOnly = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgCliOnly.checks.Count -eq 0) ('expected CLI-only contract to avoid default web checks, got ' + ((@($cfgCliOnly.checks) | ForEach-Object { [string]$_ }) -join ','))
  Assert-True ((@($cfgCliOnly.checks) -notcontains '/=200')) 'expected CLI-only contract to avoid default /=200 web check'
  $cliOnlyJourneySpecs = @(Get-ProjectAcceptancePlanContractJourneySpecs -ProjectRoot $project)
  Assert-True ($cliOnlyJourneySpecs.Count -eq 0) ('expected CLI-only journeys to have no web route specs, got ' + [string]$cliOnlyJourneySpecs.Count)
  $coverageCliOnly = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $project -Config $cfgCliOnly
  $coverageCliOnlyStep = New-ProjectAcceptanceJourneyCoverageStep -Fact $coverageCliOnly
  Assert-True ([bool]$coverageCliOnly.required -and [bool]$coverageCliOnly.ok) 'expected CLI/artifact command checks to satisfy journey coverage'
  Assert-True ([string]$coverageCliOnly.reason -eq 'cli/artifact contract checks present') ('expected CLI/artifact coverage reason, got ' + [string]$coverageCliOnly.reason)
  Assert-True ([string]$coverageCliOnlyStep.details -match 'reason=cli/artifact contract checks present') 'expected coverage step details to report CLI/artifact reason'
  Assert-True ([int]$coverageCliOnly.non_web_surface_count -ge 2 -and [int]$coverageCliOnly.non_web_command_check_count -eq 3) 'expected CLI/artifact surfaces plus three command checks'
  $webFactCliOnly = Get-ProjectAcceptanceWebAcceptanceFact -ProjectRoot $project -Config $cfgCliOnly
  Assert-True (-not [bool]$webFactCliOnly.required -and [int]$webFactCliOnly.config_checks_count -eq 0 -and [int]$webFactCliOnly.contract_web_specs_count -eq 0 -and [int]$webFactCliOnly.contract_journey_specs_count -eq 0) 'expected CLI-only acceptance to skip server:web-start'
  New-Item -ItemType Directory -Path $routeLikeDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $routeLikeDir 'page.tsx'), 'export default function Page() { return null }', (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'acceptance.json'), $emptyServerChecksAcc, (New-Object System.Text.UTF8Encoding($false)))
  $cfgCliOnlyExplicitEmptyChecks = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True ($cfgCliOnlyExplicitEmptyChecks.checks.Count -eq 0) 'expected CLI-only explicit empty server.checks to suppress discovered web checks'
  $webFactCliOnlyExplicitEmptyChecks = Get-ProjectAcceptanceWebAcceptanceFact -ProjectRoot $project -Config $cfgCliOnlyExplicitEmptyChecks
  Assert-True (-not [bool]$webFactCliOnlyExplicitEmptyChecks.required) 'expected CLI-only explicit empty server.checks to skip server:web-start even when route-like files exist'
  Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'acceptance.json') -Force
  Remove-Item -LiteralPath (Join-Path $project 'app') -Recurse -Force

  $actionOnlyContract = [ordered]@{
    user_journeys = @(
      [ordered]@{
        id = 'action-only-flow'
        steps = @('click login button', 'submit credentials', 'verify profile screen')
      }
    )
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'project-contract.json'), (($actionOnlyContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $project 'package.json'), '{"scripts":{"smoke:browser":"cmd"}}', (New-Object System.Text.UTF8Encoding($false)))
  $cfgBrowserCoverage = Get-ProjectAcceptanceConfig -ProjectRoot $project
  $coverageBrowser = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $project -Config $cfgBrowserCoverage
  $coverageBrowserStep = New-ProjectAcceptanceJourneyCoverageStep -Fact $coverageBrowser
  Assert-True ([bool]$coverageBrowser.required -and [bool]$coverageBrowser.ok -and [int]$coverageBrowser.journey_web_specs_count -eq 0) 'expected browser smoke script to satisfy action-only journey coverage'
  Assert-True ((@($coverageBrowser.browser_smoke_scripts) -join ',') -eq 'smoke:browser' -and [bool]$coverageBrowserStep.ok) 'expected smoke:browser to be reported as coverage'
  Remove-Item -LiteralPath (Join-Path $project 'package.json') -Force

  $cfgNoCoverage = Get-ProjectAcceptanceConfig -ProjectRoot $project
  $coverageMissing = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $project -Config $cfgNoCoverage
  $coverageMissingStep = New-ProjectAcceptanceJourneyCoverageStep -Fact $coverageMissing
  Assert-True ([bool]$coverageMissing.required -and -not [bool]$coverageMissing.ok) 'expected action-only journeys without browser smoke to fail coverage'
  Assert-True (-not [bool]$coverageMissingStep.ok -and [string]$coverageMissingStep.details -match 'no static journey checks') 'expected coverage failure reason to mention missing static checks'

  $noJourneyContract = [ordered]@{
    project_goal = 'Contract fixture with no declared journeys for coverage gate tests.'
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'project-contract.json'), (($noJourneyContract | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $coverageNotRequired = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $project -Config (Get-ProjectAcceptanceConfig -ProjectRoot $project)
  $coverageNotRequiredStep = New-ProjectAcceptanceJourneyCoverageStep -Fact $coverageNotRequired
  Assert-True (-not [bool]$coverageNotRequired.required -and [bool]$coverageNotRequired.ok -and [bool]$coverageNotRequiredStep.ok) 'expected no-journey contract to pass coverage as not required'

  $customServerPath = Join-Path $project 'custom-acceptance-server.ps1'
  $customServerScript = @'
param([int]$Port = 0)

$ErrorActionPreference = 'Stop'
if ($Port -le 0) { $Port = [int]$env:PORT }
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), $Port)
$listener.Start()
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 2048
      [void]$stream.Read($buffer, 0, $buffer.Length)
      $body = 'custom startCommand ok'
      $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
      $header = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
      $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
      $stream.Write($headerBytes, 0, $headerBytes.Length)
      $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  try { $listener.Stop() } catch {}
}
'@
  [System.IO.File]::WriteAllText($customServerPath, $customServerScript, (New-Object System.Text.UTF8Encoding($false)))
  $startCommandAcceptance = [ordered]@{
    server = [ordered]@{
      startCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $customServerPath + '" -Port {port}'
      readyPath = '/'
      readyStatuses = @(200)
      checks = @('/=200')
      timeoutSec = 20
    }
  }
  [System.IO.File]::WriteAllText((Join-Path (Join-Path $project '.bridge') 'acceptance.json'), (($startCommandAcceptance | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  $cfgStartCommand = Get-ProjectAcceptanceConfig -ProjectRoot $project
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$cfgStartCommand.startCommand)) 'expected server.startCommand to be loaded from acceptance config'
  $customServer = $null
  try {
    $customServer = Start-ProjectAcceptanceServer -ProjectRoot $project -Config $cfgStartCommand
    Assert-True ([bool]$customServer.ok) ('expected custom server.startCommand to start without npm start, got ' + [string]$customServer.reason)
    Assert-True ([int]$customServer.readyStatus -eq 200) ('expected custom server ready status 200, got ' + [string]$customServer.readyStatus)
    Assert-True ([string]$customServer.command -notmatch '\{port\}' -and [string]$customServer.command -match '-Port \d+') 'expected startCommand port placeholder to be expanded'
  } finally {
    if ($customServer) { Stop-ProjectAcceptanceServer -Server $customServer }
    Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'acceptance.json') -Force -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath (Join-Path (Join-Path $project '.bridge') 'project-contract.json') -Force
  $missingSteps = @(Get-ProjectAcceptancePlanContractSteps -ProjectRoot $project)
  $present = @($missingSteps | Where-Object { [string]$_.name -eq 'plan-contract:present' } | Select-Object -First 1)
  Assert-True ($present.Count -eq 1 -and -not [bool]$present[0].ok) 'missing contract must fail plan-contract:present'

  Write-Output 'PROJECT ACCEPTANCE CONTRACT TEST OK'
} finally {
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
