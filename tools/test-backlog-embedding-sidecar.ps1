param()
# 2026-06-30 verifies embeddings live in the backlog-embeddings.jsonl sidecar, NOT inline in
# backlog.jsonl -- the fix for the global-lock contention storm (inline vectors were ~88% of a 26MB
# backlog, so every locked RMW parsed+serialized ~22MB and wedged the bridge).
#  - Save-Backlog strips any inline embedding (slim transactional file).
#  - Set/Get-BacklogDedupCachedEmbedding round-trip through the sidecar, keyed by id.
#  - Inline embedding still wins (backward-compat during rollout).
#  - The in-memory store survives a second write without losing the first id.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function A { param([bool]$c,[string]$m) if($c){$script:pass++}else{$script:fail++;Write-Host "FAIL: $m"} }

$root = Split-Path -Parent $PSScriptRoot
$script:TestBridgeRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-emb-test-' + [guid]::NewGuid().ToString('N'))
$chDir = Join-Path $script:TestBridgeRoot 'channels\main'
New-Item -ItemType Directory -Path $chDir -Force | Out-Null
$script:TestBacklog = Join-Path $chDir 'backlog.jsonl'
$script:TestSidecar = Join-Path $chDir 'backlog-embeddings.jsonl'

function Get-BridgeRoot { return $script:TestBridgeRoot }
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog.ps1')
# Point the backlog path at our temp file (bypass channel resolution).
function Resolve-BacklogPathValue { return $script:TestBacklog }
# Bypass the global bridge mutex in this unit test so it never touches / contends with a live bridge.
function Invoke-BacklogLocked { param([scriptblock]$ScriptBlock) return (& $ScriptBlock) }
function Use-BridgeLock { param([scriptblock]$Body,[int]$SlowThresholdMs=5000,[string]$MutexName='x',[int]$TimeoutMs=15000) return (& $Body) }

function New-Item2 { param($id,$status='new',$text='some idea text',$emb=$null)
  $o = [pscustomobject]@{ id=$id; status=$status; text=$text; ts=(Get-Date).ToUniversalTime().ToString('o') }
  if ($null -ne $emb) { $o | Add-Member -NotePropertyName embedding -NotePropertyValue (@($emb)) -Force }
  return $o
}

# ---- T1: Save-Backlog strips inline embedding -------------------------------------------------
$emb1 = @(0.11,0.22,0.33,0.44)
$items = @( (New-Item2 'aaa' 'new' 'first idea' $emb1), (New-Item2 'bbb' 'done' 'second idea' @(1.0,2.0,3.0)) )
Save-Backlog $items
$raw = [System.IO.File]::ReadAllText($script:TestBacklog)
A (-not ($raw -match '"embedding"')) 'Save-Backlog strips inline embedding from backlog.jsonl'
A ($raw -match '"id"\s*:\s*"aaa"') 'backlog still contains item id aaa'
A ($raw -match '"text"\s*:\s*"first idea"') 'backlog still contains non-embedding fields'
$reread = @(Get-Backlog)
A ($reread.Count -eq 2) ("Get-Backlog returns both items (got " + $reread.Count + ")")
$aRead = $reread | Where-Object { $_.id -eq 'aaa' } | Select-Object -First 1
A ($null -ne $aRead -and -not ($aRead.PSObject.Properties.Name -contains 'embedding')) 'reread item has no inline embedding'

# ---- T2: sidecar set/get round-trip; original item NOT mutated inline -------------------------
$itemX = New-Item2 'xxx' 'new' 'idea x'
$setOk = Set-BacklogDedupCachedEmbedding -Item $itemX -Embedding $emb1
A ([bool]$setOk) 'Set-BacklogDedupCachedEmbedding returns true'
A (Test-Path $script:TestSidecar) 'sidecar file created'
A (-not ($itemX.PSObject.Properties.Name -contains 'embedding')) 'Set does NOT add an inline embedding to the item'
$got = @(Get-BacklogEmbeddingFromStore -Id 'xxx')
A ($got.Count -eq 4) ("sidecar get returns the vector (count=" + $got.Count + ")")
A ([math]::Abs([double]$got[0] - 0.11) -lt 1e-9) 'sidecar vector value preserved'

# ---- T3: Get-BacklogDedupCachedEmbedding falls back to sidecar when no inline -----------------
$itemX2 = New-Item2 'xxx' 'new' 'idea x'   # fresh object, no inline embedding, same id
$viaAccessor = @(Get-BacklogDedupCachedEmbedding -Item $itemX2)
A ($viaAccessor.Count -eq 4) ("accessor falls back to sidecar (count=" + $viaAccessor.Count + ")")

# ---- T4: inline embedding wins (backward-compat) ---------------------------------------------
$inlineEmb = @(9.0,8.0,7.0)
$itemInline = New-Item2 'xxx' 'new' 'idea x' $inlineEmb   # same id as sidecar, but different inline vec
$viaInline = @(Get-BacklogDedupCachedEmbedding -Item $itemInline)
A ($viaInline.Count -eq 3 -and [math]::Abs([double]$viaInline[0]-9.0) -lt 1e-9) 'inline embedding takes precedence over sidecar'

# ---- T5: second write keeps the first id (in-memory store patched, not clobbered) ------------
$itemY = New-Item2 'yyy' 'new' 'idea y'
Set-BacklogDedupCachedEmbedding -Item $itemY -Embedding @(5.5,6.6) | Out-Null
$gx = @(Get-BacklogEmbeddingFromStore -Id 'xxx')
$gy = @(Get-BacklogEmbeddingFromStore -Id 'yyy')
A ($gx.Count -eq 4) 'first id still retrievable after a second write'
A ($gy.Count -eq 2) 'second id retrievable'

# ---- T6: store reload picks up an out-of-band append (cross-process consistency) -------------
Add-Content -LiteralPath $script:TestSidecar -Value ([pscustomobject]@{ id='zzz'; embedding=@(1.0,1.0,1.0,1.0,1.0) } | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
$gz = @(Get-BacklogEmbeddingFromStore -Id 'zzz')
A ($gz.Count -eq 5) ("store reloads after external append (count=" + $gz.Count + ")")

Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail) { exit 1 } else { Write-Host 'OK' }
