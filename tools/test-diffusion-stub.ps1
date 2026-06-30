# tools/test-diffusion-stub.ps1
# Unit test for New-ProjectAutopilotContractStub (Ch2 deterministic interface-stub generator).
# Sources the bridge libs, exercises the real core-transform contract + synthetic cases, and
# asserts deterministic, compiling-shaped output. Exits with the number of failed assertions.

$ErrorActionPreference = 'Stop'
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'

. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-autopilot.ps1')
. (Join-Path $root 'lib\diffusion-planner.ps1')

$fail = 0
function Assert-That {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fail++ }
}

# ---------------------------------------------------------------------------
# 1. REAL contract: core-transform.json
# ---------------------------------------------------------------------------
Write-Host "[core-transform.json]"
$contractPath = Join-Path $root '.bridge\specs\contracts\core-transform.json'
$contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
$stub = New-ProjectAutopilotContractStub -Contract $contract

Assert-That "language is python" ($stub.language -eq 'python')
Assert-That "source contains 'class Transform'" ($stub.source -like '*class Transform*')
Assert-That "source contains 'apply(self, text: str) -> str'" ($stub.source -like '*apply(self, text: str) -> str*')
Assert-That "source contains 'NotImplementedError'" ($stub.source -like '*NotImplementedError*')
$hashOk = (-not [string]::IsNullOrWhiteSpace($stub.hash)) -and ($stub.hash.Length -eq 64) -and ($stub.hash -match '^[0-9a-f]{64}$')
Assert-That "hash is non-empty 64-char hex" $hashOk

# ---------------------------------------------------------------------------
# 2. Determinism: render twice -> identical hash AND identical source
# ---------------------------------------------------------------------------
Write-Host "[determinism]"
$stub2 = New-ProjectAutopilotContractStub -Contract $contract
Assert-That "identical hash across two renders" ($stub.hash -eq $stub2.hash)
Assert-That "identical source across two renders" ($stub.source -eq $stub2.source)

# ---------------------------------------------------------------------------
# 3. Synthetic kotlin contract
# ---------------------------------------------------------------------------
Write-Host "[kotlin]"
$kt = [pscustomobject]@{
  name = 'Styler'
  version = '1.0.0'
  owned_files = @('app/src/main/Styler.kt')
  signature = @{
    type = 'interface'
    abstract_methods = @(
      @{ name = 'apply'; signature = 'fun apply(bitmap: Bitmap): Bitmap' }
    )
  }
}
$ktStub = New-ProjectAutopilotContractStub -Contract $kt
Assert-That "kotlin language" ($ktStub.language -eq 'kotlin')
Assert-That "source contains 'interface Styler'" ($ktStub.source -like '*interface Styler*')
Assert-That "source contains 'fun apply(bitmap: Bitmap): Bitmap'" ($ktStub.source -like '*fun apply(bitmap: Bitmap): Bitmap*')

# ---------------------------------------------------------------------------
# 4. Malformed: $null contract must NOT throw and must return a non-null source
# ---------------------------------------------------------------------------
Write-Host "[malformed]"
$threw = $false
$nullStub = $null
try { $nullStub = New-ProjectAutopilotContractStub -Contract $null } catch { $threw = $true }
Assert-That "null contract does not throw" (-not $threw)
$nullSrcOk = ($null -ne $nullStub) -and (-not [string]::IsNullOrWhiteSpace([string]$nullStub.source))
Assert-That "null contract returns non-null source" $nullSrcOk

# empty pscustomobject also must not throw
$threw2 = $false
$emptyStub = $null
try { $emptyStub = New-ProjectAutopilotContractStub -Contract ([pscustomobject]@{}) } catch { $threw2 = $true }
Assert-That "empty contract does not throw" (-not $threw2)
$emptySrcOk = ($null -ne $emptyStub) -and (-not [string]::IsNullOrWhiteSpace([string]$emptyStub.source))
Assert-That "empty contract returns non-null source" $emptySrcOk

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
$res = if ($fail -eq 0) { "RESULT: ALL PASS" } else { "RESULT: $fail FAILED" }
Write-Host $res
exit $fail
