#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\parallel.ps1"

$script:pass = 0
$script:fail = 0
$script:TestProjectRoot = ''
$script:TestParallelRoot = ''
$script:TestBaseCommit = ''

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -eq $Expected) {
    $script:pass++
  } else {
    $script:fail++
    Write-Host ("FAIL {0}: expected {1}, got {2}" -f $Message, $Expected, $Actual) -ForegroundColor Red
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message, $Actual = $null)
  if ($Condition) {
    $script:pass++
  } else {
    $script:fail++
    $suffix = ''
    if ($null -ne $Actual) { $suffix = ": " + ($Actual | ConvertTo-Json -Compress -Depth 8) }
    Write-Host ("FAIL {0}{1}" -f $Message, $suffix) -ForegroundColor Red
  }
}

function Get-GitExe { 'git' }

function Get-EffectiveProjectRoot { $script:TestProjectRoot }

function Get-ParallelRoot { $script:TestParallelRoot }

function Read-State {
  [pscustomobject]@{ task_base_commit = $script:TestBaseCommit }
}

function Update-State {
  param([scriptblock]$Body)
  $state = [pscustomobject]@{}
  if ($Body) { & $Body $state | Out-Null }
  return $state
}

function Add-Message {
  param(
    [string]$From,
    [string]$Text,
    [string]$Kind
  )
  return $null
}

function Invoke-TestGit {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string[]]$Arguments
  )
  $output = @(& git -C $RepoRoot @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw ("git -C {0} {1} failed: {2}" -f $RepoRoot, ($Arguments -join ' '), ($output -join ' | '))
  }
  return @($output)
}

function New-TestWorker {
  param([string]$Id, [string]$File)
  [pscustomobject]@{
    id     = $Id
    files  = @($File)
    branch = ("wip/parallel/nonblocking-test/{0}" -f $Id)
  }
}

function New-TestContext {
  param(
    [object[]]$Workers,
    [hashtable]$Completed,
    [string]$TaskHash = 'nonblocking-test'
  )
  $context = New-ParallelDispatchAggregationContext -Workers $Workers -Completed $Completed -TaskHash $TaskHash
  $context.eagerCollected = New-Object 'System.Collections.Generic.HashSet[string]'
  return $context
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-nonblocking-collect-" + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $repoRoot = Join-Path $tempRoot 'repo'
  $parallelRoot = Join-Path $tempRoot 'parallel'
  New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $parallelRoot -Force | Out-Null

  [void](Invoke-TestGit -RepoRoot $repoRoot -Arguments @('init'))
  [void](Invoke-TestGit -RepoRoot $repoRoot -Arguments @('config','user.email','test@example.invalid'))
  [void](Invoke-TestGit -RepoRoot $repoRoot -Arguments @('config','user.name','Bridge Test'))

  Set-Content -LiteralPath (Join-Path $repoRoot 'stream-A.txt') -Value 'base A' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $repoRoot 'stream-B.txt') -Value 'base B' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $repoRoot 'stream-C.txt') -Value 'base C' -Encoding UTF8
  [void](Invoke-TestGit -RepoRoot $repoRoot -Arguments @('add','.'))
  [void](Invoke-TestGit -RepoRoot $repoRoot -Arguments @('commit','-m','initial'))

  $script:TestProjectRoot = $repoRoot
  $script:TestParallelRoot = $parallelRoot
  $script:TestBaseCommit = ([string](@(Invoke-TestGit -RepoRoot $repoRoot -Arguments @('rev-parse','HEAD')) | Select-Object -First 1)).Trim()

  $workers = @(
    (New-TestWorker -Id 'stream-A' -File 'stream-A.txt'),
    (New-TestWorker -Id 'stream-B' -File 'stream-B.txt'),
    (New-TestWorker -Id 'stream-C' -File 'stream-C.txt')
  )

  $completed1 = @{
    'stream-A' = [pscustomobject]@{ status = 'done'; commits = @('commit-a') }
    'stream-B' = [pscustomobject]@{ status = 'done'; commits = @('commit-b') }
    'stream-C' = [pscustomobject]@{ status = 'failed'; commits = @() }
  }
  $context1 = New-TestContext -Workers $workers -Completed $completed1
  [void]$context1.eagerCollected.Add('stream-A')
  [void]$context1.eagerCollected.Add('stream-B')

  Invoke-ParallelDispatchCollectPhase -Context $context1

  Assert-True (-not $context1.quarantined.Contains('stream-A')) 'eagerCollected stream-A is not quarantined'
  Assert-True (-not $context1.quarantined.Contains('stream-B')) 'eagerCollected stream-B is not quarantined'
  Assert-True (-not ($context1.completed['stream-A'].PSObject.Properties.Name -contains '_collected')) 'eagerCollected stream-A is not collected again'
  Assert-True (-not ($context1.completed['stream-B'].PSObject.Properties.Name -contains '_collected')) 'eagerCollected stream-B is not collected again'
  Assert-True ($context1.quarantined.Contains('stream-C')) 'failed stream-C is quarantined'

  $completed2 = @{
    'stream-A' = [pscustomobject]@{ status = 'done'; commits = @('commit-a'); _collected = $true }
    'stream-B' = [pscustomobject]@{ status = 'done'; commits = @('commit-b'); _collected = $true }
    'stream-C' = [pscustomobject]@{ status = 'failed'; commits = @() }
  }
  $context2 = New-TestContext -Workers $workers -Completed $completed2
  $context2.merged = 2
  [void]$context2.mergedStreams.Add('stream-A')
  [void]$context2.mergedStreams.Add('stream-B')
  [void]$context2.eagerCollected.Add('stream-A')
  [void]$context2.eagerCollected.Add('stream-B')

  Invoke-ParallelDispatchCollectPhase -Context $context2
  $result2 = Complete-ParallelDispatchResult -Context $context2

  Assert-Equal $result2.merged 2 'merged counter keeps eager-collected successes'
  Assert-Equal $result2.ok $true 'partial nonblocking result is ok'
  Assert-Equal $result2.quarantined 1 'only failed stream is quarantined'
  Assert-Equal $result2.total 3 'total stream count is preserved'

  $completed3 = @{
    'stream-A' = [pscustomobject]@{ status = 'done'; commits = @('commit-a'); _collected = $true }
    'stream-B' = [pscustomobject]@{ status = 'done'; commits = @('commit-b'); _collected = $true }
    'stream-C' = [pscustomobject]@{ status = 'failed'; commits = @() }
  }
  $context3 = New-TestContext -Workers $workers -Completed $completed3 -TaskHash 'x'
  $context3.merged = 2
  [void]$context3.mergedStreams.Add('stream-A')
  [void]$context3.mergedStreams.Add('stream-B')
  [void]$context3.eagerCollected.Add('stream-A')
  [void]$context3.eagerCollected.Add('stream-B')

  $result3 = $null
  try {
    $result3 = Complete-ParallelDispatchOutputs -Workers $workers -Completed @{} -TaskHash 'x' -EagerContext $context3
    Assert-True ([int]$result3.merged -ge 2) 'Complete-ParallelDispatchOutputs preserves EagerContext merged count' $result3
  } catch {
    $script:fail++
    Write-Host ("FAIL Complete-ParallelDispatchOutputs accepts EagerContext: " + $_.Exception.Message) -ForegroundColor Red
  }
} catch {
  $script:fail++
  Write-Host ("FAIL unexpected exception: " + $_.Exception.Message) -ForegroundColor Red
} finally {
  try {
    $tempFull = [System.IO.Path]::GetFullPath($tempRoot)
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($tempFull.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $tempFull).StartsWith('bridge-nonblocking-collect-', [System.StringComparison]::Ordinal)) {
      Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

if ($script:fail -gt 0) {
  Write-Host ("test-nonblocking-collect: FAIL ({0} passed, {1} failed)" -f $script:pass, $script:fail) -ForegroundColor Red
  exit 1
}

Write-Host ("test-nonblocking-collect: PASS ({0} tests)" -f $script:pass) -ForegroundColor Green
exit 0
