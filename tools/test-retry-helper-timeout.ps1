param()

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $root 'lib\retry-helper.ps1'
$common = Join-Path $root 'lib\common.ps1'
$llm = Join-Path $root 'lib\llm.ps1'
$memory = Join-Path $root 'lib\memory.ps1'
$test = $PSCommandPath

$pass = 0
$fail = 0

function Assert {
  param([string]$Name, [bool]$Condition)
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name"
    $script:fail++
  }
}

function Test-Utf8Bom {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-ParseOk {
  param([string]$Path)
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  return ($errors.Count -eq 0)
}

$files = @($helper, $common, $llm, $memory, $test)
foreach ($f in $files) {
  Assert "BOM $(Split-Path -Leaf $f)" (Test-Utf8Bom $f)
  Assert "Parse $(Split-Path -Leaf $f)" (Test-ParseOk $f)
}

. $helper

Assert 'Default backoff attempt 1 is 3 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 1) -eq 3)
Assert 'Default backoff attempt 2 is 7 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 2) -eq 7)
Assert 'Default backoff attempt 3 is 15 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 3) -eq 15)
Assert 'Default backoff attempt 4 is 31 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 4) -eq 31)
Assert 'Default backoff attempt 0 is zero seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 0) -eq 0)
Assert 'Request timeout stays below hard timeout' ((Get-InvokeWithTimeoutRequestTimeoutSec -TimeoutSec 10) -eq 8)
Assert 'Request timeout has one second floor' ((Get-InvokeWithTimeoutRequestTimeoutSec -TimeoutSec 1) -eq 1)
Assert 'Initialization script factory returns scriptblock' ((New-InvokeWithTimeoutInitializationScript -HelperPath $helper) -is [scriptblock])

$timeoutName = 'retry-helper-timeout-test'
$errorName = 'retry-helper-error-test'
$retryName = 'retry-helper-retry-test'
$uniqueSuffix = [System.Guid]::NewGuid().ToString('N')
$timeoutName = "$timeoutName-$uniqueSuffix"
$errorName = "$errorName-$uniqueSuffix"
$retryName = "$retryName-$uniqueSuffix"

function Remove-TestJobsByNamePrefix {
  param([string[]]$Prefixes)
  foreach ($prefix in $Prefixes) {
    Get-Job -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like "$prefix*" } | Remove-Job -Force -ErrorAction SilentlyContinue
  }
}

Remove-TestJobsByNamePrefix -Prefixes @($timeoutName, $errorName, $retryName)
$before = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like "$timeoutName*" -or [string]$_.Name -like "$errorName*" -or [string]$_.Name -like "$retryName*" }).Count
Assert 'No matching jobs before test' ($before -eq 0)

$timeoutResult = Invoke-WithTimeout -Name $timeoutName -TimeoutSec 1 -MaxAttempts 2 -BackoffSeconds @(0,0) -ScriptBlock {
  Start-Sleep -Seconds 5
  'late'
}
Assert 'Timeout returns structured object' (Test-InvokeWithTimeoutResult -Value $timeoutResult -Status 'Timeout')
Assert 'Timeout result has helper marker' ([string]$timeoutResult.Kind -eq 'InvokeWithTimeoutResult')
Assert 'Timeout attempts equals max' ([int]$timeoutResult.Attempts -eq 2)
Assert 'TimeoutSec is preserved' ([int]$timeoutResult.TimeoutSec -eq 1)
Assert 'Arbitrary Status object is not helper result' (-not (Test-InvokeWithTimeoutResult -Value ([pscustomobject]@{ Status = 'Timeout'; Attempts = 2 }) -Status 'Timeout'))

$successResult = Invoke-WithTimeout -Name 'retry-helper-success-test' -TimeoutSec 5 -MaxAttempts 2 -BackoffSeconds @(0,0) -ArgumentList @('ok') -ScriptBlock {
  param([string]$Value)
  "result:$Value"
}
Assert 'Successful scriptblock returns normal output' ([string]$successResult -eq 'result:ok')

$errorResult = Invoke-WithTimeout -Name $errorName -TimeoutSec 5 -MaxAttempts 2 -BackoffSeconds @(0,0) -ScriptBlock {
  throw 'planned failure'
}
Assert 'Exception returns structured error object' (Test-InvokeWithTimeoutResult -Value $errorResult -Status 'Error')
Assert 'Exception attempts equals max' ([int]$errorResult.Attempts -eq 2)
Assert 'Exception message is preserved' ([string]$errorResult.Error -match 'planned failure')

$envName = 'BRIDGE_RETRY_HELPER_TEST_KEY'
$oldEnv = [System.Environment]::GetEnvironmentVariable($envName)
try {
  [System.Environment]::SetEnvironmentVariable($envName, 'secret-ok', 'Process')
  $secretResult = Invoke-WithTimeout -Name 'retry helper secret init test' -TimeoutSec 5 -MaxAttempts 1 -BackoffSeconds @(0) `
    -InitializationScript (New-InvokeWithTimeoutInitializationScript -HelperPath $helper) -ArgumentList @($root) -ScriptBlock {
      param([string]$BridgeRoot)
      Get-InvokeWithTimeoutSecretValue -BridgeRoot $BridgeRoot -Name 'retry_helper_test_key'
    }
  Assert 'Job initialization exposes secret helper' ([string]$secretResult -eq 'secret-ok')
} finally {
  [System.Environment]::SetEnvironmentVariable($envName, $oldEnv, 'Process')
}

$secretTestRoot = Join-Path $root ("audit\tmp\retry-helper-secret-test-" + [System.Guid]::NewGuid().ToString('N'))
$oldUserProfile = $env:USERPROFILE
$privateEnvName = 'BRIDGE_RETRY_HELPER_PRIVATE_KEY'
$oldPrivateEnv = [System.Environment]::GetEnvironmentVariable($privateEnvName)
try {
  $privateDir = Join-Path $secretTestRoot '.bridge-private'
  $legacyRoot = Join-Path $secretTestRoot 'legacy-root'
  New-Item -ItemType Directory -Path $privateDir,$legacyRoot -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $privateDir 'secrets.json'),
    '{"retry_helper_private_key":"private-ok","retry_helper_env_priority_key":"private-loses"}',
    (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText(
    (Join-Path $legacyRoot 'secrets.json'),
    '{"retry_helper_legacy_key":"legacy-ok","retry_helper_private_key":"legacy-loses"}',
    (New-Object System.Text.UTF8Encoding($false)))

  $env:USERPROFILE = $secretTestRoot
  Assert 'Private secrets path is preferred before legacy' ([string](Get-InvokeWithTimeoutSecretValue -BridgeRoot $legacyRoot -Name 'retry_helper_private_key') -eq 'private-ok')
  $privateJobResult = Invoke-WithTimeout -Name 'retry helper private secret path test' -TimeoutSec 5 -MaxAttempts 1 -BackoffSeconds @(0) `
    -InitializationScript (New-InvokeWithTimeoutInitializationScript -HelperPath $helper) -ArgumentList @($legacyRoot) -ScriptBlock {
      param([string]$BridgeRoot)
      Get-InvokeWithTimeoutSecretValue -BridgeRoot $BridgeRoot -Name 'retry_helper_private_key'
    }
  Assert 'Job helper reads private secrets path' ([string]$privateJobResult -eq 'private-ok')
  Assert 'Legacy secrets fallback is preserved' ([string](Get-InvokeWithTimeoutSecretValue -BridgeRoot $legacyRoot -Name 'retry_helper_legacy_key') -eq 'legacy-ok')

  [System.Environment]::SetEnvironmentVariable($privateEnvName, 'env-ok', 'Process')
  Assert 'Environment secret has priority over files' ([string](Get-InvokeWithTimeoutSecretValue -BridgeRoot $legacyRoot -Name 'retry_helper_private_key') -eq 'env-ok')

  [System.Environment]::SetEnvironmentVariable($privateEnvName, $null, 'Process')
  $dpapiProfile = Join-Path $secretTestRoot 'dpapi-profile'
  $dpapiPrivateDir = Join-Path $dpapiProfile '.bridge-private'
  New-Item -ItemType Directory -Path $dpapiPrivateDir -Force | Out-Null
  Add-Type -AssemblyName System.Security
  $entropy = [System.Text.Encoding]::UTF8.GetBytes('bridge-secrets-v1')
  $plainBytes = [System.Text.Encoding]::UTF8.GetBytes('{"retry_helper_dpapi_key":"dpapi-ok"}')
  $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
    $plainBytes,
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  $dpapiWrapper = [pscustomobject]@{
    _dpapi = $true
    data = [Convert]::ToBase64String($encryptedBytes)
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText(
    (Join-Path $dpapiPrivateDir 'secrets.json'),
    $dpapiWrapper,
    (New-Object System.Text.UTF8Encoding($false)))

  $env:USERPROFILE = $dpapiProfile
  Assert 'Private DPAPI secrets wrapper is preserved' ([string](Get-InvokeWithTimeoutSecretValue -BridgeRoot $legacyRoot -Name 'retry_helper_dpapi_key') -eq 'dpapi-ok')
} finally {
  [System.Environment]::SetEnvironmentVariable($privateEnvName, $oldPrivateEnv, 'Process')
  $env:USERPROFILE = $oldUserProfile
  if (Test-Path -LiteralPath $secretTestRoot) { Remove-Item -LiteralPath $secretTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$counterPath = Join-Path $env:TEMP ("$retryName-counter.txt")
if (Test-Path -LiteralPath $counterPath) { Remove-Item -LiteralPath $counterPath -Force }
$retryResult = Invoke-WithTimeout -Name $retryName -TimeoutSec 5 -MaxAttempts 2 -BackoffSeconds @(0,0) -ArgumentList @($counterPath) -ScriptBlock {
  param([string]$Path)
  $n = 0
  if (Test-Path -LiteralPath $Path) { $n = [int]([System.IO.File]::ReadAllText($Path).Trim()) }
  $n++
  [System.IO.File]::WriteAllText($Path, [string]$n)
  if ($n -lt 2) { throw 'retry once' }
  "retried:$n"
}
Assert 'Exception path retries then succeeds' ([string]$retryResult -eq 'retried:2')
if (Test-Path -LiteralPath $counterPath) { Remove-Item -LiteralPath $counterPath -Force }

$llmText = [System.IO.File]::ReadAllText($llm, [System.Text.Encoding]::UTF8)
$memoryText = [System.IO.File]::ReadAllText($memory, [System.Text.Encoding]::UTF8)
Assert 'DeepSeek job uses request timeout parameter' ($llmText -match '-TimeoutSec\s+\$RequestTimeoutSec')
Assert 'DeepSeek job uses retry-helper initialization' ($llmText -match 'New-InvokeWithTimeoutInitializationScript')
Assert 'DeepSeek job reads secret via shared helper' ($llmText -match "Get-InvokeWithTimeoutSecretValue[\s\S]*-Name 'deepseekApiKey'")
Assert 'DeepSeek job builds headers inside job from API key' ($llmText -match '\$headers\s*=\s*@\{\s*Authorization\s*=\s*\("Bearer "\s*\+\s*\$apiKey\)\s*\}')
Assert 'DeepSeek does not pass bearer header into job' ($llmText -notmatch '\$authHeader|AuthorizationHeader')
Assert 'DeepSeek job does not parse secrets.json directly' ($llmText -notmatch 'Get-Content\s+-LiteralPath\s+\$secretPath')
Assert 'Gemini job uses request timeout parameter' ($memoryText -match '-TimeoutSec\s+\$RequestTimeoutSec')
Assert 'Gemini job uses retry-helper initialization' ($memoryText -match 'New-InvokeWithTimeoutInitializationScript')
Assert 'Gemini job reads secret via shared helper' ($memoryText -match "Get-InvokeWithTimeoutSecretValue[\s\S]*-Name 'geminiApiKey'")
Assert 'Gemini job builds URL inside job from secret' ($memoryText -match 'geminiApiKey[\s\S]*\$requestUrl\s*=')
Assert 'Gemini API key is not passed in URL argument' ($memoryText -notmatch 'Invoke-GeminiApi\s+-Url')
Assert 'Gemini job does not parse secrets.json directly' ($memoryText -notmatch 'Get-Content\s+-LiteralPath\s+\$secretPath')
Assert 'Gemini API keeps legacy Url parameter' ($memoryText -match 'param\(\[string\]\$Url\s*=')

$after = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like "$timeoutName*" -or [string]$_.Name -like "$errorName*" -or [string]$_.Name -like "$retryName*" }).Count
Assert 'No matching jobs remain after test' ($after -eq 0)
Remove-TestJobsByNamePrefix -Prefixes @($timeoutName, $errorName, $retryName)

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
