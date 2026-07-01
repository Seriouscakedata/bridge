param()

# test-diffusion-synthesis.ps1 -- unit test for New-ProjectAutopilotSynthesizedContracts (diffusion
# cold-start reliability floor). Proves: an in-memory synthesized contract validates as valid+raw_mature,
# is genuinely FREEZABLE (freeze manifest writes a lock), is deterministic byte-for-byte, and that dangling
# consumes / already-real contracts are handled. Pure -- no network, uses a throwaway temp dir for the lock.

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-diffusion-synth-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'diffusion-synth-test'

# --- stubs the freeze-manifest lock path needs (mirror tools/test-project-autopilot-diffusion-contracts.ps1) ---
function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:EffectiveChannel }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}

$fail = 0
function Assert-That {
  param([bool]$Condition, [string]$Name)
  $res = if ($Condition) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1}" -f $res, $Name)
  if (-not $Condition) { $script:fail++ }
}

try {
  $root = Split-Path -Parent $PSScriptRoot
  . (Join-Path $root 'lib\common.ps1')
  . (Join-Path $root 'lib\backlog-autopilot.ps1')
  . (Join-Path $root 'lib\diffusion-planner.ps1')

  New-Item -ItemType Directory -Path (Get-ChannelDir) -Force | Out-Null
  $tempProj = Join-Path $script:TestBridgeRoot 'project'
  New-Item -ItemType Directory -Path $tempProj -Force | Out-Null

  $atoms = @(
    [pscustomobject]@{ slug='provider';   provides=@('user-api'); files=@('src/provider.ts'); chapter='Chapter 1'; depends_on=@() },
    [pscustomobject]@{ slug='consumer-a'; consumes=@('user-api'); files=@('src/a.ts');        chapter='Chapter 2'; depends_on=@('provider') },
    [pscustomobject]@{ slug='consumer-b'; consumes=@('user-api'); files=@('src/b.ts');        chapter='Chapter 3'; depends_on=@('provider') },
    [pscustomobject]@{ slug='indep';                              files=@('src/x.ts');        chapter='Chapter 1'; depends_on=@() }
  )

  # ---- Assertion 1: exactly one synthesized contract, covering 'user-api' ----
  $s = New-ProjectAutopilotSynthesizedContracts -Tasks $atoms -ExistingContracts @()
  Assert-That (@($s.synthesized).Count -eq 1) 'A1a: exactly one contract synthesized'
  Assert-That (@($s.covered_ids) -contains 'user-api') 'A1b: covered_ids contains user-api'

  # ---- Assertion 2: the synthesized entry validates as a freezable minimal contract ----
  $entry = @($s.synthesized)[0]
  Assert-That ([bool]$entry.valid -eq $true) 'A2a: entry.valid is true'
  Assert-That ([bool]$entry.raw_mature -eq $true) 'A2b: entry.raw_mature is true'
  Assert-That ([bool]$entry.stable -eq $false) 'A2c: entry.stable is false (no lock yet)'
  Assert-That ([bool]$entry.has_golden_example -eq $true) 'A2d: entry.has_golden_example is true'
  Assert-That (@($entry.owned_files) -contains 'src/provider.ts') 'A2e: owned_files contains src/provider.ts'
  Assert-That ([string]$entry.version -eq '0.0.0-synth') 'A2f: version is 0.0.0-synth'

  # ---- Assertion 3: FREEZABLE -- the real freeze manifest can freeze the synthesized contract ----
  $fm = New-ProjectAutopilotContractFreezeManifest -Tasks $atoms -Contracts @($s.synthesized) -ProjectRoot $tempProj -Channel 'test' -Mode 'diffusion' -WriteLocks:$true
  $fmc = @($fm.contracts)[0]
  Assert-That ($null -ne $fmc -and [bool]$fmc.freeze_ready -eq $true) 'A3a: freeze manifest contract freeze_ready is true'
  Assert-That ($null -ne $fmc -and [bool]$fmc.lock_written -eq $true) 'A3b: freeze manifest wrote the lock'

  # ---- Assertion 4: determinism -- two calls serialize byte-identically ----
  $s2 = New-ProjectAutopilotSynthesizedContracts -Tasks $atoms -ExistingContracts @()
  $j1 = @($s.synthesized) | ConvertTo-Json -Depth 12
  $j2 = @($s2.synthesized) | ConvertTo-Json -Depth 12
  Assert-That ([string]$j1 -eq [string]$j2) 'A4: synthesized output is byte-identical across calls'

  # ---- Assertion 5: dangling consume -- consumer with no provider is skipped, not synthesized ----
  $danglingAtoms = @(
    [pscustomobject]@{ slug='c-only'; consumes=@('missing'); files=@('src/c.ts'); chapter='Chapter 1'; depends_on=@() }
  )
  $sd = New-ProjectAutopilotSynthesizedContracts -Tasks $danglingAtoms -ExistingContracts @()
  $danglingSkip = @($sd.skipped | Where-Object { [string]$_.id -eq 'missing' -and [string]$_.reason -eq 'dangling-consume' })
  Assert-That ($danglingSkip.Count -eq 1) 'A5a: missing id skipped with reason dangling-consume'
  Assert-That (-not (@($sd.covered_ids) -contains 'missing')) 'A5b: missing id NOT synthesized'

  # ---- Assertion 6: real-present -- an already-valid ExistingContract is not re-synthesized ----
  $sr = New-ProjectAutopilotSynthesizedContracts -Tasks $atoms -ExistingContracts @([pscustomobject]@{ id='user-api'; valid=$true })
  $realSkip = @($sr.skipped | Where-Object { [string]$_.id -eq 'user-api' -and [string]$_.reason -eq 'real-contract-present' })
  Assert-That ($realSkip.Count -eq 1) 'A6a: user-api skipped with reason real-contract-present'
  Assert-That (@($sr.synthesized).Count -eq 0) 'A6b: nothing synthesized when a valid real contract exists'

  Write-Host ''
  $result = if ($script:fail -eq 0) { 'ALL PASS' } else { ("{0} FAILED" -f $script:fail) }
  Write-Host ("RESULT: {0}" -f $result)
} catch {
  Write-Host ("FATAL: {0}" -f $_.Exception.Message)
  Write-Host ([string]$_.ScriptStackTrace)
  $script:fail++
  Write-Host ''
  Write-Host ("RESULT: {0} FAILED" -f $script:fail)
} finally {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

exit $script:fail
