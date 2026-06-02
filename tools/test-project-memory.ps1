$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $bridgeRoot ('tmp\project-memory-test-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'repo'
$memoryRoot = Join-Path $testRoot 'memory'
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src') -Force | Out-Null
New-Item -ItemType Directory -Path $memoryRoot -Force | Out-Null

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-BridgeConfig {
  [pscustomobject]@{
    memory = [pscustomobject]@{
      enabled = $true
      autoGate = $false
      recallTopK = 8
      recallMinScore = 0.10
      maxInjectChars = 2500
      codeTopK = 4
      codeMinScore = 0.10
      codeMaxInjectChars = 900
    }
    fastLane = [pscustomobject]@{ embedBatchEnabled = $true }
  }
}
function Get-Secret { param([string]$Name) return $null }
function Use-BridgeLock { param([scriptblock]$Action) & $Action }
function Resolve-BridgeContainedPath {
  param([Parameter(Mandatory=$true)][string]$Path, [string]$Purpose = 'test path')
  return [System.IO.Path]::GetFullPath($Path)
}
function Get-EffectiveChannel { return 'bigproj' }
function Get-CurrentMemoryChannel { return 'bigproj' }
function Get-EffectiveScope {
  param([string]$Slug = $null)
  [pscustomobject]@{
    slug = 'bigproj'
    is_bridge = $false
    bridge_root = $script:TestBridgeRoot
    project_root = $script:TestProjectRoot
    memory_root = $script:TestMemoryRoot
    memory_store = (Join-Path $script:TestMemoryRoot 'memory.jsonl')
    bridge_memory_root = (Join-Path $script:TestBridgeRoot 'memory')
    bridge_memory_store = (Join-Path $script:TestBridgeRoot 'memory\memory.jsonl')
  }
}
function Write-AtomicFile { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false)) }
function Add-UsageRecord { return $null }

$script:TestBridgeRoot = $testRoot
$script:TestProjectRoot = $projectRoot
$script:TestMemoryRoot = $memoryRoot

. (Join-Path $bridgeRoot 'lib\memory.ps1')
. (Join-Path $bridgeRoot 'lib\codemem.ps1')
. (Join-Path $bridgeRoot 'lib\project-context.ps1')

function Get-TestEmbeddingVector {
  param([string]$Text)
  $keys = @('auth','middleware','booking','payment','test','risk','large','module','login','src')
  $low = ([string]$Text).ToLowerInvariant()
  $vals = New-Object 'System.Collections.Generic.List[double]'
  foreach ($k in $keys) {
    [void]$vals.Add($(if ($low.Contains($k)) { 1.0 } else { 0.0 }))
  }
  [void]$vals.Add([double]([Math]::Max(1, ([string]$Text).Length % 17) / 17.0))
  return [double[]]$vals.ToArray()
}
function Get-Embedding {
  param([string]$Text, [string]$TaskType = 'RETRIEVAL_QUERY')
  return (Get-TestEmbeddingVector -Text $Text)
}
function Get-EmbeddingBatch {
  param([string[]]$Texts, [string]$TaskType = 'RETRIEVAL_DOCUMENT')
  foreach ($t in @($Texts)) { Write-Output -NoEnumerate (Get-TestEmbeddingVector -Text $t) }
}

function Add-Check {
  param([System.Collections.ArrayList]$Results, [string]$Name, [bool]$Ok, [string]$Detail = '')
  [void]$Results.Add([pscustomobject]@{
    Status = $(if ($Ok) { 'PASS' } else { 'FAIL' })
    Name = $Name
    Detail = $Detail
  })
}

$results = [System.Collections.ArrayList]::new()

try {
  $authPath = Join-Path $projectRoot 'src\auth.ts'
  Set-Content -LiteralPath $authPath -Encoding UTF8 -Value 'export function authMiddleware() { return true }'
  Set-Content -LiteralPath (Join-Path $projectRoot 'src\booking.ts') -Encoding UTF8 -Value 'export function createBooking() { return authMiddleware() }'
  Set-Content -LiteralPath (Join-Path $projectRoot 'src\worker.py') -Encoding UTF8 -Value "def payment_worker():`n    return 'ok'"
  Set-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Encoding UTF8 -Value '{"scripts":{"test":"npm test"}}'
  Set-Content -LiteralPath (Join-Path $projectRoot 'PROJECT_MAP.md') -Encoding UTF8 -Value "# Canonical Project Map`n- project-root-map-wins`n- Tests: npm test"
  Set-Content -LiteralPath (Join-Path $memoryRoot 'map.md') -Encoding UTF8 -Value "# Big Project`n- Stack: TypeScript`n- Auth entrypoint: src/auth.ts`n- Tests: npm test"
  $sha = Get-ProjectFileSha1 -Path $authPath

  $codeSlug = Get-ProjectSlug -Root $projectRoot
  $idx = Index-CodeBase -ProjectRoot $projectRoot -Slug $codeSlug
  Add-Check $results 'generic codemem indexes TS/Python/JSON files' ($idx.files -ge 4 -and $idx.records -gt 0) ("files=$($idx.files) records=$($idx.records)")

  $legacyId = Add-Memory -Text 'Legacy note about auth middleware in this project' -Tags @('legacy-check') -Channel 'bigproj'
  Add-Check $results 'legacy memory still writes' (-not [string]::IsNullOrWhiteSpace($legacyId))

  $factId = Add-ProjectMemory -Text 'Auth middleware starts in src/auth.ts and protects login routes' -Kind project_fact -Trust verified -Channel 'bigproj' -Evidence ([pscustomobject]@{ file='src/auth.ts'; line=1; sha1=$sha }) -Tags @('auth')
  $testId = Add-ProjectMemory -Text 'Auth changes must run npm test and login smoke tests' -Kind project_test -Trust observed -Channel 'bigproj' -Tags @('auth','test')
  $riskId = Add-ProjectMemory -Text 'Auth middleware is a risk zone because it guards login and booking sessions' -Kind project_risk -Trust observed -Channel 'bigproj' -Tags @('auth','risk')
  Add-Check $results 'typed project records write' (($factId -and $testId -and $riskId) -ne $null)

  $hits = @(Search-ProjectMemory -Query 'change auth middleware login' -Kind @('project_fact') -TopK 3 -MinScore 0.10 -Channel 'bigproj')
  Add-Check $results 'typed recall finds project_fact' ($hits.Count -gt 0 -and ([string]$hits[0].Mem.text -match 'Auth middleware')) ('hits=' + $hits.Count)

  $pack = Get-ProjectContextPack -TaskText 'change auth middleware and run auth tests' -Channel 'bigproj' -IncludeCode -MaxChars 6000
  Add-Check $results 'context pack includes header' ($pack -match 'PROJECT CONTEXT PACK')
  Add-Check $results 'context pack prefers root PROJECT_MAP.md' ($pack -match 'project-root-map-wins' -and $pack -notmatch 'Stack: TypeScript')
  Add-Check $results 'context pack includes verified fact' ($pack -match 'Auth middleware starts')
  Add-Check $results 'context pack includes tests' ($pack -match 'npm test')
  Add-Check $results 'context pack includes code recall' ($pack -match 'AuthMiddleware')

  Add-Content -LiteralPath $authPath -Encoding UTF8 -Value "`nexport const changed = true"
  $fresh = Test-ProjectMemoryFreshness -MemoryRecord $hits[0].Mem -Channel 'bigproj'
  Add-Check $results 'stale evidence detected after file change' (-not [bool]$fresh.fresh) ([string]$fresh.reason)

  $records = New-Object 'System.Collections.Generic.List[object]'
  for ($i = 1; $i -le 1500; $i++) {
    [void]$records.Add([pscustomobject]@{
      text = "Large project module $i booking auth payment test fact"
      kind = 'project_fact'
      trust = 'observed'
      tags = @('large','module')
      importance = 0.45
      evidence = [pscustomobject]@{ file='src/auth.ts'; line=1 }
    })
  }
  $ids = @(Add-ProjectMemoryBatch -Records $records.ToArray() -Channel 'bigproj')
  Add-Check $results 'batch writes 1500 records' ($ids.Count -eq 1500) ('ids=' + $ids.Count)
  $lineCount = (Get-Content -LiteralPath (Join-Path $memoryRoot 'memory.jsonl') -Encoding UTF8 | Measure-Object).Count
  Add-Check $results 'memory store keeps large project records' ($lineCount -ge 1503) ('lines=' + $lineCount)

  $ready = Test-ProjectReadiness -TaskText 'booking auth payment module' -Channel 'bigproj'
  Add-Check $results 'readiness reaches green on large indexed project' ([string]$ready.level -eq 'green') ("level=$($ready.level) score=$($ready.score)")

  $legacy = @(Search-ProjectMemory -Query 'legacy auth middleware' -Kind @('memory_note') -TopK 2 -MinScore 0.10 -Channel 'bigproj')
  Add-Check $results 'legacy records remain searchable as memory_note' ($legacy.Count -gt 0 -and (Get-MemoryKind $legacy[0].Mem) -eq 'memory_note') ('hits=' + $legacy.Count)
} finally {
  $safeTmp = [System.IO.Path]::GetFullPath((Join-Path $bridgeRoot 'tmp')).TrimEnd('\') + '\'
  $fullTest = [System.IO.Path]::GetFullPath($testRoot)
  if ($fullTest.StartsWith($safeTmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTest)) {
    Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue
  }
}

foreach ($r in $results) {
  Write-Host ("{0} {1} {2}" -f $r.Status, $r.Name, $r.Detail)
}
$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
