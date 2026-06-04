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
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Test 3: Get-Secret returns $null for missing key (no file needed)
$result = Get-Secret '__bridge_nonexistent_key_xyz__'
Assert-True ($null -eq $result) "Get-Secret returns null for missing key"

# Test 4: DPAPI round-trip -- protect plaintext then read back through Get-Secret
$tmp = $script:TestSecretsPath
try {
  Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
  [System.IO.File]::WriteAllText($tmp, '{"testKey":"hello-dpapi"}', $utf8NoBom)
  $script:PlainSecretResult = $null
  $null = @(& { $script:PlainSecretResult = Get-Secret 'testKey' } 3>&1)
  Assert-True ($script:PlainSecretResult -eq 'hello-dpapi') "Get-Secret reads plaintext secrets.json without BOM"
  Protect-SecretsAtRest -Path $tmp
  $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
  $obj = $raw | ConvertFrom-Json
  Assert-True ($obj.PSObject.Properties.Name -contains '_dpapi') "Protect-SecretsAtRest writes _dpapi marker"
  $bytes = [System.IO.File]::ReadAllBytes($tmp)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)
  Assert-True (-not $hasBom) "Protect-SecretsAtRest writes UTF-8 without BOM"
  $script:DpapiSecretResult = $null
  $null = @(& { $script:DpapiSecretResult = Get-Secret 'testKey' } 3>&1)
  Assert-True ($script:DpapiSecretResult -eq 'hello-dpapi') "Get-Secret reads DPAPI-protected secrets.json"

  [System.IO.File]::WriteAllText($tmp, '{"_dpapi":1,"data":"not-base64"}', $utf8NoBom)
  $script:BadDpapiResult = 'not-run'
  $warnings = @(& { $script:BadDpapiResult = Get-Secret 'testKey' } 3>&1)
  $warningText = ($warnings | ForEach-Object { [string]$_ }) -join "`n"
  Assert-True ($null -eq $script:BadDpapiResult) "Get-Secret returns null for malformed DPAPI wrapper"
  Assert-True ($warningText -match 'failed to decrypt DPAPI-protected file') "Get-Secret warns on malformed DPAPI wrapper"
} finally {
  Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
}

# Test 5: Test-SecretsFilePermissions returns true for non-existent path (graceful)
$ok = Test-SecretsFilePermissions -Path 'C:\nonexistent\secrets.json'
Assert-True ($ok -eq $true) "Test-SecretsFilePermissions returns true for missing file (graceful)"

# Test 6: Permission inspection errors are warnings, not success.
$tmpAcl = [System.IO.Path]::GetTempFileName()
try {
  function Get-Acl { throw 'mock access denied' }
  $script:AclResult = $true
  $aclWarnings = @(& { $script:AclResult = Test-SecretsFilePermissions -Path $tmpAcl } 3>&1)
  $aclWarningText = ($aclWarnings | ForEach-Object { [string]$_ }) -join "`n"
  Assert-True ($script:AclResult -eq $false) "Test-SecretsFilePermissions returns false when ACL inspection fails"
  Assert-True ($aclWarningText -match 'unable to inspect file permissions') "Test-SecretsFilePermissions warns when ACL inspection fails"
} finally {
  Remove-Item function:Get-Acl -Force -EA SilentlyContinue
  Remove-Item -LiteralPath $tmpAcl -Force -EA SilentlyContinue
}

# Test 7: Secrets JSON parsing rejects excessive nesting before ConvertFrom-Json.
$deepJson = ((1..17 | ForEach-Object { '[' }) -join '') + '0' + ((1..17 | ForEach-Object { ']' }) -join '')
$depthRejected = $false
try {
  $null = ConvertFrom-SecretsJson -Json $deepJson -Purpose 'test deep secrets JSON'
} catch {
  $depthRejected = ($_.Exception.Message -match 'exceeds max JSON depth')
}
Assert-True ($depthRejected -eq $true) "ConvertFrom-SecretsJson rejects excessive depth"

# Test 8: Get-Secret rechecks ACL after the secrets file changes.
$tmpStamp = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-test-secrets-stamp-" + [System.IO.Path]::GetRandomFileName() + ".json")
try {
  $script:TestSecretsPath = $tmpStamp
  $script:SecretsAclCheckStamp = $null
  $script:AclCheckCount = 0
  function Test-SecretsFilePermissions { param([string]$Path) $script:AclCheckCount++; return $true }
  [System.IO.File]::WriteAllText($tmpStamp, '{"testKey":"one"}', $utf8NoBom)
  $null = Get-Secret 'testKey'
  [System.IO.File]::WriteAllText($tmpStamp, '{"testKey":"two-two"}', $utf8NoBom)
  $null = Get-Secret 'testKey'
  Assert-True ($script:AclCheckCount -ge 2) "Get-Secret rechecks ACL after secrets file changes"
} finally {
  Remove-Item function:Test-SecretsFilePermissions -Force -EA SilentlyContinue
  Remove-Item -LiteralPath $tmpStamp -Force -EA SilentlyContinue
}

Write-Host "`nRESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
