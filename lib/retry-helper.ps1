# retry-helper.ps1 -- shared timeout/retry helpers for bridge LLM/API calls.

if ([string]::IsNullOrWhiteSpace($script:InvokeWithTimeoutHelperPath) -and
    -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
  $script:InvokeWithTimeoutHelperPath = $PSCommandPath
}

function Get-InvokeWithTimeoutBackoffSec {
  param(
    [int]$Attempt,
    [int[]]$BackoffSeconds = $null
  )
  if ($Attempt -le 0) { return 0 }
  if ($BackoffSeconds -and $BackoffSeconds.Count -gt 0) {
    $idx = [Math]::Min([Math]::Max(0, $Attempt - 1), $BackoffSeconds.Count - 1)
    return [Math]::Max(0, [int]$BackoffSeconds[$idx])
  }
  $power = [Math]::Min(30, $Attempt + 1)
  return [Math]::Max(0, [int]([Math]::Pow(2, $power) - 1))
}

function Get-InvokeWithTimeoutRequestTimeoutSec {
  param([int]$TimeoutSec)
  if ($TimeoutSec -le 2) { return 1 }
  return [Math]::Max(1, [int]($TimeoutSec - 2))
}

function New-InvokeWithTimeoutInitializationScript {
  param([string]$HelperPath = '')
  if ([string]::IsNullOrWhiteSpace($HelperPath)) { $HelperPath = $script:InvokeWithTimeoutHelperPath }
  if ([string]::IsNullOrWhiteSpace($HelperPath)) { throw 'retry-helper path is unknown' }
  $full = [System.IO.Path]::GetFullPath($HelperPath)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "retry-helper not found: $full" }
  $quoted = $full.Replace("'", "''")
  return [scriptblock]::Create(". '$quoted'")
}

function ConvertTo-InvokeWithTimeoutJobName {
  param([string]$Name)
  $value = if ([string]::IsNullOrWhiteSpace($Name)) { 'bridge-timeout-call' } else { [string]$Name }
  $value = ($value -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($value)) { $value = 'bridge-timeout-call' }
  if ($value.Length -gt 80) { $value = $value.Substring(0, 80).Trim('-') }
  if ([string]::IsNullOrWhiteSpace($value)) { return 'bridge-timeout-call' }
  return $value
}

function Get-InvokeWithTimeoutSecretValue {
  param(
    [string]$BridgeRoot,
    [string]$Name,
    [string[]]$Aliases = @()
  )
  $candidates = @($Name) + @($Aliases) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
  foreach ($candidate in $candidates) {
    $envKey = 'BRIDGE_' + (([string]$candidate).ToUpperInvariant() -replace '[^A-Z0-9]', '_')
    $envValue = [System.Environment]::GetEnvironmentVariable($envKey)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
    $envValue = [System.Environment]::GetEnvironmentVariable([string]$candidate)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
  }

  $secretPaths = New-Object 'System.Collections.Generic.List[string]'
  if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    [void]$secretPaths.Add((Join-Path (Join-Path ([string]$env:USERPROFILE) '.bridge-private') 'secrets.json'))
  }
  if (-not [string]::IsNullOrWhiteSpace($BridgeRoot)) {
    [void]$secretPaths.Add((Join-Path $BridgeRoot 'secrets.json'))
  }

  foreach ($secretPath in @($secretPaths.ToArray() | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($secretPath)) { continue }
    if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) { continue }

    $item = Get-Item -LiteralPath $secretPath -Force
    if ($item.Length -gt 65536) { throw "secrets file exceeds 65536 bytes: $secretPath" }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $raw = [System.IO.File]::ReadAllText($item.FullName, $utf8)
    $secrets = $raw | ConvertFrom-Json

    if ($secrets -and ($secrets.PSObject.Properties.Name -contains '_dpapi')) {
      if ($secrets.PSObject.Properties.Name -notcontains 'data' -or [string]::IsNullOrWhiteSpace([string]$secrets.data)) {
        throw 'DPAPI wrapper is missing data'
      }
      Add-Type -AssemblyName System.Security
      $entropy = [System.Text.Encoding]::UTF8.GetBytes('bridge-secrets-v1')
      $encrypted = [Convert]::FromBase64String([string]$secrets.data)
      $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
      $secrets = ([System.Text.Encoding]::UTF8.GetString($decrypted) | ConvertFrom-Json)
    }

    foreach ($candidate in $candidates) {
      if ($secrets -and ($secrets.PSObject.Properties.Name -contains $candidate)) {
        return [string]$secrets.$candidate
      }
    }
  }
  return $null
}

function New-InvokeWithTimeoutResult {
  param(
    [string]$Status,
    [int]$Attempts,
    [int]$TimeoutSec,
    [string]$Name,
    [string]$ErrorMessage = '',
    [int[]]$BackoffSecondsUsed = @()
  )
  $out = [ordered]@{
    Kind       = 'InvokeWithTimeoutResult'
    Status     = $Status
    Attempts   = $Attempts
    TimeoutSec = $TimeoutSec
    Name       = $Name
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { $out.Error = $ErrorMessage }
  if ($BackoffSecondsUsed -and $BackoffSecondsUsed.Count -gt 0) { $out.BackoffSeconds = @($BackoffSecondsUsed) }
  return [pscustomobject]$out
}

function Test-InvokeWithTimeoutTimeoutLikeError {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  return ($Message -match '(?i)\b(timed?\s*out|timeout|operation has timed out|wait-?job)\b')
}

function Stop-InvokeWithTimeoutJob {
  param(
    $Job,
    [int]$DrainTimeoutSec = 2
  )
  if (-not $Job) { return }
  try {
    if ([string]$Job.State -eq 'Running') {
      Stop-Job -Job $Job -ErrorAction SilentlyContinue
    }
  } catch {
    $script:InvokeWithTimeoutLastCleanupError = $_.Exception.Message
  }
  try {
    Wait-Job -Job $Job -Timeout $DrainTimeoutSec -ErrorAction SilentlyContinue | Out-Null
  } catch {
    $script:InvokeWithTimeoutLastCleanupError = $_.Exception.Message
  }
  try {
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
  } catch {
    $script:InvokeWithTimeoutLastCleanupError = $_.Exception.Message
  }
}

function Test-InvokeWithTimeoutResult {
  param(
    $Value,
    [string]$Status = ''
  )
  if (-not $Value) { return $false }
  try {
    if ($Value.PSObject.Properties.Name -notcontains 'Kind') { return $false }
    if ([string]$Value.Kind -ne 'InvokeWithTimeoutResult') { return $false }
    if ($Value.PSObject.Properties.Name -notcontains 'Status') { return $false }
    if ([string]::IsNullOrWhiteSpace($Status)) { return $true }
    return ([string]$Value.Status -eq $Status)
  } catch {
    return $false
  }
}

function Invoke-WithTimeout {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
    [int]$TimeoutSec = 120,
    [int]$MaxAttempts = 3,
    [object[]]$ArgumentList = @(),
    [scriptblock]$InitializationScript = $null,
    [string]$Name = 'bridge-timeout-call',
    [int[]]$BackoffSeconds = $null
  )

  if ($TimeoutSec -le 0) { throw 'Invoke-WithTimeout requires TimeoutSec > 0' }
  if ($MaxAttempts -le 0) { throw 'Invoke-WithTimeout requires MaxAttempts > 0' }

  $attempt = 0
  $lastError = ''
  $usedBackoff = @()

  while ($attempt -lt $MaxAttempts) {
    $attempt++
    $job = $null
    $safeName = ConvertTo-InvokeWithTimeoutJobName -Name $Name
    $jobName = ('{0}-{1}-{2}-{3}' -f $safeName, $PID, $attempt, ([Guid]::NewGuid().ToString('N')))
    try {
      $jobArgs = @{
        ScriptBlock  = $ScriptBlock
        ArgumentList = @($ArgumentList)
        Name         = $jobName
        ErrorAction  = 'Stop'
      }
      if ($InitializationScript) { $jobArgs.InitializationScript = $InitializationScript }
      $job = Start-Job @jobArgs
      if (-not $job) { throw 'Start-Job returned no job' }
      $done = Wait-Job -Job $job -Timeout $TimeoutSec -ErrorAction Stop
      if (-not $done) {
        $lastError = ('Timed out after {0} seconds' -f $TimeoutSec)
        Stop-InvokeWithTimeoutJob -Job $job
        $job = $null
        if ($attempt -lt $MaxAttempts) {
          $delay = Get-InvokeWithTimeoutBackoffSec -Attempt $attempt -BackoffSeconds $BackoffSeconds
          $usedBackoff += $delay
          if ($delay -gt 0) { Start-Sleep -Seconds $delay }
          continue
        }
        return (New-InvokeWithTimeoutResult -Status 'Timeout' -Attempts $attempt -TimeoutSec $TimeoutSec -Name $Name -ErrorMessage $lastError -BackoffSecondsUsed @($usedBackoff))
      }
      $result = Receive-Job -Job $job -ErrorAction Stop
      Stop-InvokeWithTimeoutJob -Job $job
      $job = $null
      return $result
    } catch {
      $lastError = $_.Exception.Message
      $status = 'Error'
      if (Test-InvokeWithTimeoutTimeoutLikeError -Message $lastError) { $status = 'Timeout' }
      if ($job) {
        Stop-InvokeWithTimeoutJob -Job $job
        $job = $null
      }
      if ($attempt -lt $MaxAttempts) {
        $delay = Get-InvokeWithTimeoutBackoffSec -Attempt $attempt -BackoffSeconds $BackoffSeconds
        $usedBackoff += $delay
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        continue
      }
      return (New-InvokeWithTimeoutResult -Status $status -Attempts $attempt -TimeoutSec $TimeoutSec -Name $Name -ErrorMessage $lastError -BackoffSecondsUsed @($usedBackoff))
    } finally {
      if ($job) {
        Stop-InvokeWithTimeoutJob -Job $job
      }
    }
  }

  return (New-InvokeWithTimeoutResult -Status 'Timeout' -Attempts $MaxAttempts -TimeoutSec $TimeoutSec -Name $Name -ErrorMessage $lastError -BackoffSecondsUsed @($usedBackoff))
}
