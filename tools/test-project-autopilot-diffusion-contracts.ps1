param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-autopilot-diffusion-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'external-diffusion-test'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function New-Atom {
  param(
    [string]$Slug,
    [string]$Chapter,
    [string[]]$Files,
    [string[]]$Provides = @(),
    [string[]]$Consumes = @(),
    [string[]]$DependsOn = @(),
    [string]$Kind = 'feature',
    [string[]]$Checks = @('contract check')
  )
  return [pscustomobject]@{
    slug = $Slug
    title = $Slug
    task = "Synthetic diffusion atom $Slug"
    chapter = $Chapter
    kind = $Kind
    files = @($Files)
    provides = @($Provides)
    consumes = @($Consumes)
    depends_on = @($DependsOn)
    acceptance = @("Synthetic acceptance for $Slug")
    checks = @($Checks)
    risk = 'normal'
  }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:EffectiveChannel }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    projectAutopilotEnabled = $true
    projectAutopilotDiffusionMode = 'off'
    projectAutopilotDiffusionMinIndependentAtoms = 2
    projectAutopilotDiffusionMaxWaveSize = 6
  }
}

try {
  $root = Split-Path -Parent $PSScriptRoot
  $channelDir = Get-ChannelDir -Slug $script:EffectiveChannel
  New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:EffectiveChannel), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path $root 'lib\backlog.ps1')

  $projectRoot = Join-Path $script:TestBridgeRoot 'project'
  $contractDir = Join-Path (Join-Path (Join-Path $projectRoot '.bridge') 'specs') 'contracts'
  New-Item -ItemType Directory -Path $contractDir -Force | Out-Null
  $contract = [ordered]@{
    id = 'user-api'
    version = '1.0.0'
    stable = $true
    signature = [ordered]@{ name='GetUser'; inputs=@('id'); output='user' }
    behavior = [ordered]@{
      preconditions = @('id is non-empty')
      postconditions = @('returns a user object or typed not_found error')
      ordering = @('read before render')
      side_effects = @()
      idempotency = 'idempotent'
    }
    invariants = @('user.id matches input id')
    errors = [ordered]@{ not_found='No matching user exists' }
    golden_examples = @([ordered]@{ input=@{id='u1'}; output=@{id='u1'; name='Ada'} })
    owned_files = @('src/contracts/user-api.ts')
    owned_regions = @('GetUser contract')
  }
  [System.IO.File]::WriteAllText((Join-Path $contractDir 'user-api.json'), (($contract | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

  $contracts = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $projectRoot)
  Assert-True ($contracts.Count -eq 1) ("expected one interface contract, got {0}" -f $contracts.Count)
  Assert-True ([string]$contracts[0].id -eq 'user-api') ("contract id mismatch: {0}" -f [string]$contracts[0].id)
  Assert-True ([bool]$contracts[0].valid) 'valid contract must pass required-field validation'
  Assert-True ([bool]$contracts[0].stable) 'stable:true contract must pass stability gate'

  $tasks = @(
    (New-Atom -Slug 'provider' -Chapter 'chapter-1' -Files @('src/provider.ts') -Provides @('user-api')),
    (New-Atom -Slug 'consumer' -Chapter 'chapter-2' -Files @('src/consumer.ts') -Consumes @('user-api')),
    (New-Atom -Slug 'stitch' -Chapter 'integration' -Files @('tests/user-api.integration.ts') -Kind 'consolidation' -Checks @('npm test -- user-api.integration'))
  )
  $graph = New-ProjectAutopilotUnifiedGraph -Tasks $tasks -Contracts $contracts
  $softEdges = @($graph.edges | Where-Object { [string]$_.from -eq 'provider' -and [string]$_.to -eq 'consumer' -and [string]$_.edge_type -eq 'soft' -and [string]$_.provenance -eq 'contract' })
  Assert-True ($softEdges.Count -eq 1) ("expected one soft contract edge provider->consumer, got {0}" -f $softEdges.Count)
  Assert-True ([bool]$graph.acyclic) 'valid graph must be acyclic'
  Assert-True (@($graph.dangling_consumes).Count -eq 0) 'valid graph must not have dangling consumes'
  Assert-True (@($graph.file_conflicts).Count -eq 0) 'valid graph must not have file conflicts'

  $offGate = Test-ProjectAutopilotDiffusionGate -Tasks $tasks -Contracts $contracts -OptIn:$false -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True (-not [bool]$offGate.enabled) 'diffusion gate must be disabled by default'
  Assert-True (@($offGate.reasons) -contains 'diffusion-opt-in-missing') 'default fallback reason must mention missing opt-in'

  $onGate = Test-ProjectAutopilotDiffusionGate -Tasks $tasks -Contracts $contracts -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True ([bool]$onGate.enabled) ('valid opt-in diffusion gate should pass; reasons=' + ((@($onGate.reasons) -join ', ')))

  $unstable = [pscustomobject]@{ id='user-api'; valid=$true; stable=$false; hash='unstable' }
  $unstableGate = Test-ProjectAutopilotDiffusionGate -Tasks $tasks -Contracts @($unstable) -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True (-not [bool]$unstableGate.enabled) 'unstable contract must block diffusion'
  Assert-True (@($unstableGate.reasons) -contains 'contract-unstable') 'unstable contract reason must be reported'

  $danglingTasks = @(
    (New-Atom -Slug 'consumer' -Chapter 'chapter-2' -Files @('src/consumer.ts') -Consumes @('missing-contract')),
    (New-Atom -Slug 'stitch' -Chapter 'integration' -Files @('tests/integration.ts') -Kind 'consolidation' -Checks @('npm test -- integration'))
  )
  $danglingGate = Test-ProjectAutopilotDiffusionGate -Tasks $danglingTasks -Contracts @() -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True (-not [bool]$danglingGate.enabled) 'dangling consume must block diffusion'
  Assert-True (@($danglingGate.reasons) -contains 'contract-coverage-incomplete') 'dangling consume must report incomplete coverage'

  $cycleTasks = @(
    (New-Atom -Slug 'a' -Chapter 'chapter-1' -Files @('src/a.ts') -DependsOn @('b')),
    (New-Atom -Slug 'b' -Chapter 'chapter-2' -Files @('src/b.ts') -DependsOn @('a')),
    (New-Atom -Slug 'stitch' -Chapter 'integration' -Files @('tests/cycle.integration.ts') -Kind 'consolidation' -Checks @('npm test -- cycle.integration'))
  )
  $cycleGate = Test-ProjectAutopilotDiffusionGate -Tasks $cycleTasks -Contracts @() -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True (-not [bool]$cycleGate.enabled) 'cycle must block diffusion'
  Assert-True (@($cycleGate.reasons) -contains 'graph-cyclic') 'cycle reason must be reported'

  $conflictTasks = @(
    (New-Atom -Slug 'left' -Chapter 'chapter-1' -Files @('src/shared.ts')),
    (New-Atom -Slug 'right' -Chapter 'chapter-2' -Files @('src/shared.ts')),
    (New-Atom -Slug 'stitch' -Chapter 'integration' -Files @('tests/shared.integration.ts') -Kind 'consolidation' -Checks @('npm test -- shared.integration'))
  )
  $conflictGate = Test-ProjectAutopilotDiffusionGate -Tasks $conflictTasks -Contracts @() -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 6
  Assert-True (-not [bool]$conflictGate.enabled) 'file conflict must block diffusion'
  Assert-True (@($conflictGate.reasons) -contains 'file-conflict-unresolved') 'file conflict reason must be reported'

  $autopilotText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\backlog-autopilot.ps1'), [System.Text.Encoding]::UTF8)
  Assert-True ($autopilotText.IndexOf('Default decomposition is still ONE next chapter/wave', [System.StringComparison]::Ordinal) -ge 0) 'prompt must preserve one-chapter default'
  Assert-True ($autopilotText.IndexOf('Diffusion/cross-chapter decomposition is opt-in only', [System.StringComparison]::Ordinal) -ge 0) 'prompt must document diffusion opt-in gate'
  Assert-True ($autopilotText.IndexOf('"provides"', [System.StringComparison]::Ordinal) -ge 0) 'PROJECT_BACKLOG schema must include provides'
  Assert-True ($autopilotText.IndexOf('"consumes"', [System.StringComparison]::Ordinal) -ge 0) 'PROJECT_BACKLOG schema must include consumes'

  Write-Output 'PROJECT AUTOPILOT DIFFUSION CONTRACTS TEST OK'
} finally {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
