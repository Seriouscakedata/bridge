$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Add-Message { param($From, $Text, $Kind) return $null }

function Get-BridgeConfig {
  return [pscustomobject]@{
    parallel = [pscustomobject]@{
      complexityFloor = [pscustomobject]@{
        simple        = 2
        moderate      = 3
        complex       = 4
        architectural = 5
      }
      domainHints = [pscustomobject]@{
        backend  = @('ps1')
        docs     = @('md')
        frontend = @('tsx')
      }
      workers = @(
        [pscustomobject]@{ id='claude-fable'; cli='claude'; model='claude-fable-5'; strength=5; speed=5; cost=1; domains=@('any','backend') },
        [pscustomobject]@{ id='claude-sonnet'; cli='claude'; model='sonnet'; strength=3; speed=3; cost=3; domains=@('any') },
        [pscustomobject]@{ id='codex-high'; cli='codex'; model='gpt-5.5'; reasoning='high'; strength=4; speed=2; cost=4; domains=@('any','backend') },
        [pscustomobject]@{ id='codex-xhigh'; cli='codex'; model='gpt-5.5'; reasoning='xhigh'; strength=5; speed=1; cost=5; domains=@('any','backend') }
      )
    }
  }
}

. (Join-Path $root 'lib\parallel.ps1')

$failures = 0
function Check {
  param([string]$Name, [bool]$Condition, [object]$Value = $null)
  if ($Condition) {
    Write-Host "PASS $Name"
  } else {
    $script:failures++
    Write-Host "FAIL $Name"
    if ($null -ne $Value) { Write-Host ($Value | ConvertTo-Json -Depth 8) }
  }
}

$complexStream = [pscustomobject]@{
  id         = 's1'
  files      = @('lib/example.ps1')
  complexity = 'complex'
  opus       = $false
  premium    = $false
  body       = ''
}
$complexPick = Select-WorkerForStream -Stream $complexStream
Check 'complex without marker does not pick premium fable' ([string]$complexPick.id -eq 'codex-high') $complexPick

$architecturalStream = [pscustomobject]@{
  id         = 's2'
  files      = @('lib/example.ps1')
  complexity = 'architectural'
  opus       = $false
  premium    = $false
  body       = ''
}
$architecturalPick = Select-WorkerForStream -Stream $architecturalStream
Check 'architectural prefers codex before premium fable by default' ([string]$architecturalPick.id -eq 'codex-xhigh') $architecturalPick

$markedStream = [pscustomobject]@{
  id         = 's3'
  files      = @('lib/example.ps1')
  complexity = 'complex'
  opus       = $false
  premium    = $true
  body       = '[[FABLE]]'
}
$markedPick = Select-WorkerForStream -Stream $markedStream
Check 'premium marker unlocks fable but codex priority still wins' ([string]$markedPick.id -eq 'codex-high') $markedPick

$explicitFableStream = [pscustomobject]@{
  id         = 's4'
  files      = @('lib/example.ps1')
  complexity = 'complex'
  opus       = $false
  premium    = $false
  body       = "worker: claude-fable"
}
$explicitFablePick = Select-WorkerForStream -Stream $explicitFableStream
Check 'explicit worker override can still pick fable' ([string]$explicitFablePick.id -eq 'claude-fable') $explicitFablePick

$plan = @'
[[PARALLEL:a]]
Files: lib/a.ps1
Complexity: complex
[[FABLE]]
Do A.
[[/PARALLEL:a]]

[[PARALLEL:b]]
Files: lib/b.ps1
Complexity: complex
Do B.
[[/PARALLEL:b]]
'@
$streams = @(Test-CanParallelize -PlanText $plan)
$streamA = $streams | Where-Object { [string]$_.id -eq 'a' } | Select-Object -First 1
$streamB = $streams | Where-Object { [string]$_.id -eq 'b' } | Select-Object -First 1
Check 'parser marks FABLE as premium' ([bool]$streamA.premium -and [bool]$streamA.opus) $streamA
Check 'parser leaves unmarked stream non-premium' (-not [bool]$streamB.premium) $streamB

# --- Codex priority tests: complex/architectural prefer codex over cheap non-codex ---
function Get-BridgeConfig {
  return [pscustomobject]@{
    parallel = [pscustomobject]@{
      complexityFloor = [pscustomobject]@{
        simple        = 2
        moderate      = 3
        complex       = 4
        architectural = 5
      }
      domainHints = [pscustomobject]@{
        backend  = @('ps1')
        docs     = @('md')
        frontend = @('tsx')
      }
      workers = @(
        [pscustomobject]@{ id='cheap-claude'; cli='claude'; model='some-model'; strength=4; speed=4; cost=1; domains=@('any') },
        [pscustomobject]@{ id='codex-high';   cli='codex';  model='gpt-5.5'; reasoning='high'; strength=4; speed=2; cost=4; domains=@('any') }
      )
    }
  }
}

$s5 = [pscustomobject]@{ id='s5'; files=@('lib/a.ps1'); complexity='complex'; opus=$false; premium=$false; body='' }
$pick5 = Select-WorkerForStream -Stream $s5
Check 'complex: codex-high beats cheap-claude despite higher cost' ([string]$pick5.id -eq 'codex-high') $pick5

$s6 = [pscustomobject]@{ id='s6'; files=@('lib/a.ps1'); complexity='simple'; opus=$false; premium=$false; body='' }
$pick6 = Select-WorkerForStream -Stream $s6
Check 'simple: cheap-claude is acceptable (cost-asc unchanged)' ([string]$pick6.id -eq 'cheap-claude') $pick6

if ($failures -gt 0) { exit 1 }
Write-Host 'test-premium-claude-routing: PASS'
