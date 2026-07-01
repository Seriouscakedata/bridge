param()

# ==============================================================================
# tools/test-contract-drift.ps1
#   Unit test for the PURE Гл4 hardening cores in lib/contract-drift.ps1:
#     * Test-ProjectAutopilotContractSymbolPresent  (per-language presence)
#     * Test-ProjectAutopilotContractDrift          (declared-methods drift)
#     * Test-ProjectAutopilotStitchManifestDrift     (manifest+file wrapper, temp files)
#     * Get-ProjectAutopilotOrphanStubResult        (pure orphan classification)
#   No live bridge. The wrapper test writes fixture provider files to a temp dir.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

# Get-BacklogPackObjectValue is needed by the orphan classifier.
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-core.ps1')
. (Join-Path $root 'lib\contract-drift.ps1')

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# ---- 1. symbol presence per language ----
$py = "class UserApi(ABC):`n    @abstractmethod`n    def apply(self, text: str) -> str:`n        ...`n    async def load(self):`n        pass`n"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'apply' -Content $py -Language 'python') "py: def apply present"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'load'  -Content $py -Language 'python') "py: async def load present"
Assert-True (-not (Test-ProjectAutopilotContractSymbolPresent -Symbol 'missing' -Content $py -Language 'python')) "py: absent method not present"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'apply(self, text)' -Content $py -Language 'python') "py: full-signature reduces to name"

$ts = "export interface UserApi {`n  getName(): string;`n  count: number;`n  apply?(x: string): void;`n}`n"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'getName' -Content $ts -Language 'typescript') "ts: method present"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'count'   -Content $ts -Language 'typescript') "ts: property present"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'apply'   -Content $ts -Language 'typescript') "ts: optional method present"
Assert-True (-not (Test-ProjectAutopilotContractSymbolPresent -Symbol 'nope' -Content $ts -Language 'typescript')) "ts: absent not present"

$kt = "interface UserApi {`n    fun getName(): String`n    val id: Int`n}`n"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'getName' -Content $kt -Language 'kotlin') "kt: fun present"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'id'      -Content $kt -Language 'kotlin') "kt: val present"
Assert-True (-not (Test-ProjectAutopilotContractSymbolPresent -Symbol 'x' -Content $kt -Language 'kotlin')) "kt: absent not present"

$ktg = "interface Api {`n    fun <T> transform(x: T): T`n    suspend fun load(): Unit`n}`n"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'transform' -Content $ktg -Language 'kotlin') "kt: generic 'fun <T> transform' present (fix: was false-negative)"
Assert-True (Test-ProjectAutopilotContractSymbolPresent -Symbol 'load' -Content $ktg -Language 'kotlin') "kt: 'suspend fun load' present"

# ---- 2. drift core ----
$dOk = Test-ProjectAutopilotContractDrift -Methods @('apply','load') -ProviderContent $py -Language 'python'
Assert-True (-not [bool]$dOk.drifted)              "drift: all methods present -> no drift"
Assert-True (@($dOk.checked).Count -eq 2)          "drift: 2 methods checked"

$dBad = Test-ProjectAutopilotContractDrift -Methods @('apply','vanished') -ProviderContent $py -Language 'python'
Assert-True ([bool]$dBad.drifted)                  "drift: a removed method -> drift"
Assert-True ((($dBad.missing -join ',')) -match 'vanished') "drift: missing names the removed method"

$dEmpty = Test-ProjectAutopilotContractDrift -Methods @() -ProviderContent $py -Language 'python'
Assert-True (-not [bool]$dEmpty.drifted)           "drift: empty methods -> not drifted (build is backstop)"

# ---- 3. manifest wrapper (temp fixture files) ----
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('contract-drift-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'src') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'src\provider_good.py') -Value $py -Encoding UTF8
Set-Content -LiteralPath (Join-Path $tmp 'src\provider_bad.py')  -Value "class UserApi:`n    def apply(self, text):`n        return text`n" -Encoding UTF8

$manGood = Join-Path $tmp 'man-good.json'
@{ stitch_slug='stitch-integration-aaa'; contracts=@(@{ id='user-api'; provider_file='src/provider_good.py'; language='python'; methods=@('apply','load') }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manGood -Encoding UTF8
$rGood = Test-ProjectAutopilotStitchManifestDrift -ManifestPath $manGood -ProjectRoot $tmp
Assert-True ([bool]$rGood.ok)                      "manifest: real provider satisfies frozen interface -> ok"
Assert-True (@($rGood.drifts).Count -eq 0)         "manifest: no drifts"

$manBad = Join-Path $tmp 'man-bad.json'
@{ stitch_slug='stitch-integration-bbb'; contracts=@(@{ id='user-api'; provider_file='src/provider_bad.py'; language='python'; methods=@('apply','load') }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manBad -Encoding UTF8
$rBad = Test-ProjectAutopilotStitchManifestDrift -ManifestPath $manBad -ProjectRoot $tmp
Assert-True (-not [bool]$rBad.ok)                  "manifest: provider dropped 'load' -> drift detected"
Assert-True (@($rBad.drifts).Count -ge 1)          "manifest: drift recorded"

$manMissing = Join-Path $tmp 'man-missing.json'
@{ stitch_slug='stitch-integration-ccc'; contracts=@(@{ id='user-api'; provider_file='src/never_built.py'; language='python'; methods=@('apply') }) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manMissing -Encoding UTF8
$rMissing = Test-ProjectAutopilotStitchManifestDrift -ManifestPath $manMissing -ProjectRoot $tmp
Assert-True (-not [bool]$rMissing.ok)              "manifest: provider file missing -> drift (false-green guard)"
Assert-True ((($rMissing.drifts | ForEach-Object { $_.reason }) -join ';') -match 'provider-file-missing') "manifest: reason=provider-file-missing"

$rNoMan = Test-ProjectAutopilotStitchManifestDrift -ManifestPath (Join-Path $tmp 'nope.json') -ProjectRoot $tmp
Assert-True ([bool]$rNoMan.ok)                     "manifest: absent manifest -> ok (fail-open, no wedge)"

# ---- 4. orphan classification ----
$backlog = @(
  [pscustomobject]@{ slug='freeze-a'; status='approved'; files=@('.bridge/stubs/user-api.py') }   # active owner
  [pscustomobject]@{ slug='stitch-x'; status='done';     files=@('.bridge/stubs/old-api.py') }     # done owner -> orphan
)
$stubs = @('.bridge/stubs/user-api.py', '.bridge/stubs/old-api.py', '.bridge/stubs/leaked.py')
$orph = Get-ProjectAutopilotOrphanStubResult -StubRelPaths $stubs -Backlog $backlog
$orphSet = @($orph.orphans)
Assert-True (-not ($orphSet -contains '.bridge/stubs/user-api.py')) "orphan: active-owned stub kept"
Assert-True ($orphSet -contains '.bridge/stubs/old-api.py')         "orphan: done-owned stub is orphan"
Assert-True ($orphSet -contains '.bridge/stubs/leaked.py')          "orphan: unowned stub is orphan"

# ---- 5. A1 writer <-> reader integration (manifest schema coherence) ----
# Override Get-BridgeRoot so Write-ProjectAutopilotStitchManifest writes into a temp channel dir.
$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('stitch-manifest-test-' + [guid]::NewGuid().ToString('N'))
function Get-BridgeRoot { return $script:TestBridgeRoot }
$projRoot = Join-Path $script:TestBridgeRoot 'project'
New-Item -ItemType Directory -Path (Join-Path $projRoot 'src') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $projRoot 'src\provider.py') -Value $py -Encoding UTF8

$fixtureContracts = @(
  # PRODUCTION shape: the processed interface-contract wraps the raw contract (which carries signature) under
  # '.contract' (Get-ProjectAutopilotInterfaceContracts). The writer must read signature through that nest.
  [pscustomobject]@{ id='user-api'; stable=$true; owned_files=@('src/provider.py'); contract=[pscustomobject]@{ signature=[pscustomobject]@{ abstract_methods=@([pscustomobject]@{ name='apply' }, [pscustomobject]@{ name='load' }) } } }
  [pscustomobject]@{ id='ignored';  stable=$false; owned_files=@('src/other.py'); contract=[pscustomobject]@{ signature=[pscustomobject]@{ abstract_methods=@() } } }  # unstable -> not in manifest
)
$stitchSlug = 'stitch-integration-deadbeef'
$mpath = Write-ProjectAutopilotStitchManifest -StitchSlug $stitchSlug -Contracts $fixtureContracts -FreezeManifest $null -ProjectRoot $projRoot -Channel 'unit'
Assert-True (-not [string]::IsNullOrWhiteSpace($mpath) -and (Test-Path -LiteralPath $mpath)) "A1: manifest written to channel dir"
$found = Get-ProjectAutopilotStitchManifestPath -StitchSlug $stitchSlug -Channel 'unit'
Assert-True ($found -eq $mpath)                    "A1: reader resolves manifest by stitch slug"
$manRead = Get-Content -LiteralPath $mpath -Raw | ConvertFrom-Json
Assert-True (@($manRead.contracts).Count -eq 1)    "A1: only STABLE contract recorded (unstable skipped)"
Assert-True (([string]$manRead.contracts[0].language) -eq 'python') "A1: language inferred from provider ext"
Assert-True ((@($manRead.contracts[0].methods) -join ',') -match 'apply') "A1: method names captured"

# reader runs drift against the manifest's stored project_root (no -ProjectRoot passed)
$rWire = Test-ProjectAutopilotStitchManifestDrift -ManifestPath $mpath -ProjectRoot ''
Assert-True ([bool]$rWire.ok)                      "A1<->drift: real provider satisfies manifest via stored project_root"
Assert-True ([int]$rWire.checked_contracts -eq 1)  "A1<->drift: exactly the stable contract checked"

# break the provider -> drift via the wired manifest
Set-Content -LiteralPath (Join-Path $projRoot 'src\provider.py') -Value "class UserApi:`n    def apply(self, text):`n        return text`n" -Encoding UTF8
$rWireBad = Test-ProjectAutopilotStitchManifestDrift -ManifestPath $mpath -ProjectRoot ''
Assert-True (-not [bool]$rWireBad.ok)              "A1<->drift: dropping 'load' from real provider -> drift via wired manifest"

# cleanup: temp dir removal
try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
try { Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
