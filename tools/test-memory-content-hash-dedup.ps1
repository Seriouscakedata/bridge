#Requires -Version 5.1
# test-memory-content-hash-dedup.ps1 -- exact content_hash memory dedup coverage.

$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $bridgeRoot ('tmp\memory-hash-dedup-' + [guid]::NewGuid().ToString('N'))
$memoryRoot = Join-Path $testRoot 'memory'
New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-BridgeConfig { [pscustomobject]@{ memory = [pscustomobject]@{ enabled=$true; dedupCosine=0.93; dedupThreshold=0.93; skillDedupThreshold=0.96 } } }
function Get-Secret { param([string]$Name) return $null }
function Use-BridgeLock { param([scriptblock]$Action) & $Action }
function Resolve-BridgeContainedPath { param([Parameter(Mandatory=$true)][string]$Path, [string]$BasePath = $null, [string]$Purpose = 'test path') return [System.IO.Path]::GetFullPath($Path) }
function Get-EffectiveChannel { return 'main' }
function Get-CurrentMemoryChannel { return 'main' }
function Write-AtomicFile { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false)) }

$script:TestBridgeRoot = $testRoot

. (Join-Path $bridgeRoot 'lib\memory.ps1')
Set-Item -Path Function:\Get-Embedding -Value { param([string]$Text, [string]$TaskType) return @(0.25, 0.75, 0.0) } -Force

$script:pass = 0
$script:fail = 0
function Check {
  param([string]$Name, [bool]$Condition, $Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function New-Mem {
  param([string]$Id, [string]$Text, [double]$Importance = 0.5, [string]$Channel = 'main', [bool]$Shared = $false, [bool]$Pinned = $false, [string[]]$Tags = @())
  [pscustomobject][ordered]@{
    id = $Id
    ts = (Get-Date).ToUniversalTime().ToString('o')
    source = 'test'
    tags = @($Tags)
    importance = [double]$Importance
    pinned = [bool]$Pinned
    channel = $Channel
    shared = [bool]$Shared
    text = $Text
    vec = @(1.0, 0.0, 0.0)
  }
}

try {
  $records = @(
    (New-Mem -Id 'low' -Text 'Duplicate memory text' -Importance 0.4),
    (New-Mem -Id 'high' -Text 'Duplicate   memory text' -Importance 0.8),
    (New-Mem -Id 'other-channel' -Text 'Duplicate memory text' -Importance 0.2 -Channel 'project'),
    (New-Mem -Id 'pinned' -Text 'Pinned duplicate' -Importance 0.1 -Pinned $true),
    (New-Mem -Id 'unpinned' -Text 'Pinned duplicate' -Importance 0.9),
    (New-Mem -Id 'unique' -Text 'Unique memory text' -Importance 0.5)
  )
  Save-AllMemories -Mems $records -Channel 'main'

  $removed = Invoke-MemoryContentHashDedup
  $mems = @(Get-AllMemories)
  $ids = @($mems | ForEach-Object { [string]$_.id })

  Check 'content-hash dedup removes exact duplicates in same scope' ($removed -eq 2) $removed
  Check 'higher importance duplicate kept' (($ids -contains 'high') -and -not ($ids -contains 'low')) $ids
  Check 'pinned duplicate kept over higher importance unpinned' (($ids -contains 'pinned') -and -not ($ids -contains 'unpinned')) $ids
  Check 'same content in different channel scope kept' ($ids -contains 'other-channel') $ids
  Check 'content_hash backfilled on kept records' (@($mems | Where-Object { -not $_.PSObject.Properties['content_hash'] -or [string]::IsNullOrWhiteSpace([string]$_.content_hash) }).Count -eq 0) $mems

  $uniqueBefore = @($mems | Where-Object { [string]$_.id -eq 'unique' } | Select-Object -First 1)
  $oldHash = [string]$uniqueBefore.content_hash
  $updated = Set-Memory -Id 'unique' -Text 'Unique memory text, edited'
  $afterEdit = @(Get-AllMemories | Where-Object { [string]$_.id -eq 'unique' } | Select-Object -First 1)
  $newHash = [string]$afterEdit.content_hash
  Check 'Set-Memory refreshes content_hash when text changes' ([bool]$updated -and -not [string]::IsNullOrWhiteSpace($newHash) -and $newHash -ne $oldHash -and $newHash -eq (Get-MemoryContentHash -Text 'Unique memory text, edited')) $afterEdit
} finally {
  $safeTmp = [System.IO.Path]::GetFullPath((Join-Path $bridgeRoot 'tmp')).TrimEnd('\') + '\'
  $fullTest = [System.IO.Path]::GetFullPath($testRoot)
  if ($fullTest.StartsWith($safeTmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTest)) {
    Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}
Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
