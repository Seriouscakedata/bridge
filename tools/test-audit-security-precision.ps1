param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\audit-security.ps1')

$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-audit-security-precision-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Write-TestFile {
  param([string]$RelativePath, [string]$Content)
  $path = Join-Path $script:TestRoot ($RelativePath -replace '/', '\')
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

try {
  New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

  Write-TestFile -RelativePath 'lib/comment-secret.ps1' -Content "# password = 'abcdef1234567890'`n"
  Write-TestFile -RelativePath 'lib/string-regex.ps1' -Content "`$rx = '(?i)\bInvoke-Expression\b|\biex\b|password = ''abcdef1234567890'''`n"
  Write-TestFile -RelativePath 'tools/test-audit-fixture.ps1' -Content "`$fixture = @'`nInvoke-Expression `$cmd`npassword = 'abcdef1234567890'`n'@`n"
  Write-TestFile -RelativePath 'lib/real-dynamic.ps1' -Content "`$cmd = 'Get-Date'`nInvoke-Expression `$cmd`n"
  Write-TestFile -RelativePath 'lib/real-secret.ps1' -Content "`$apiToken = 'abcdef1234567890'`n"

  $result = Invoke-SecurityAudit -BridgePath $script:TestRoot -TargetRoot $script:TestRoot -AuditKind 'bridge'
  $critical = @($result.findings | Where-Object { [string]$_.severity -eq 'critical' })
  $commandCritical = @($critical | Where-Object { [string]$_.category -eq 'command-injection' })
  $secretCritical = @($critical | Where-Object { [string]$_.category -eq 'hardcoded-credentials' })
  $falseCritical = @($critical | Where-Object {
    [string]$_.file -in @('lib\comment-secret.ps1','lib\string-regex.ps1','tools\test-audit-fixture.ps1')
  })

  Assert-True ($commandCritical.Count -eq 1) ("expected one real command-injection critical, got {0}" -f $commandCritical.Count)
  Assert-True ([string]$commandCritical[0].file -eq 'lib\real-dynamic.ps1') 'real Invoke-Expression should be reported from executable code'
  Assert-True ($secretCritical.Count -eq 1) ("expected one real hardcoded-credentials critical, got {0}" -f $secretCritical.Count)
  Assert-True ([string]$secretCritical[0].file -eq 'lib\real-secret.ps1') 'real hardcoded secret assignment should be reported'
  Assert-True ($falseCritical.Count -eq 0) ("comment/string/test fixture text should not be critical, got {0}" -f $falseCritical.Count)

  Write-Host 'audit-security precision tests passed'
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
