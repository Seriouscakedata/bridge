# test-secrets-permissions.ps1 -- unit tests for secrets ACL check and DPAPI protect/unprotect.
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$pass = 0; $fail = 0
function Assert-True { param([bool]$C,[string]$M) if ($C) { $script:pass++; Write-Host "PASS: $M" } else { $script:fail++; Write-Host "FAIL: $M" } }

# Test 1: Test-SecretsFilePermissions exists
Assert-True ((Get-Command Test-SecretsFilePermissions -EA SilentlyContinue) -ne $null) "Test-SecretsFilePermissions is defined"

# Test 2: Protect-SecretsAtRest exists
Assert-True ((Get-Command Protect-SecretsAtRest -EA SilentlyContinue) -ne $null) "Protect-SecretsAtRest is defined"

$script:TestSecretsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-test-secrets-" + [System.IO.Path]::GetRandomFileName() + ".json")
function Get-SecretsPath { return $script:TestSecretsPath }

# Test 3: Get-Secret returns $null for missing key (no file needed)
$result = Get-Secret '__bridge_nonexistent_key_xyz__'
Assert-True ($null -eq $result) "Get-Secret returns null for missing key"

# Test 4: DPAPI round-trip -- protect plaintext then read back through Get-Secret
$tmp = $script:TestSecretsPath
try {
  Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
  '{"testKey":"hello-dpapi"}' | Set-Content -LiteralPath $tmp -Encoding UTF8
  Assert-True ((Get-Secret 'testKey') -eq 'hello-dpapi') "Get-Secret reads plaintext secrets.json"
  Protect-SecretsAtRest -Path $tmp
  $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
  $obj = $raw | ConvertFrom-Json
  Assert-True ($obj.PSObject.Properties.Name -contains '_dpapi') "Protect-SecretsAtRest writes _dpapi marker"
  Assert-True ((Get-Secret 'testKey') -eq 'hello-dpapi') "Get-Secret reads DPAPI-protected secrets.json"
} finally {
  Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
}

# Test 5: Test-SecretsFilePermissions returns true for non-existent path (graceful)
$ok = Test-SecretsFilePermissions -Path 'C:\nonexistent\secrets.json'
Assert-True ($ok -eq $true) "Test-SecretsFilePermissions returns true for missing file (graceful)"

Write-Host "`nRESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
