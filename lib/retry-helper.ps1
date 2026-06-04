# retry-helper.ps1 -- shared timeout/retry helpers for bridge LLM/API calls.

function Get-InvokeWithTimeoutBackoffSec {
  param(
    [int]$Attempt,
    [int[]]$BackoffSeconds = $null
  )
  if ($BackoffSeconds -and $BackoffSeconds.Count -gt 0) {
    $idx = [Math]::Min([Math]::Max(0, $Attempt - 1), $BackoffSeconds.Count - 1)
    return [Math]::Max(0, [int]$BackoffSeconds[$idx])
  }
  return [Math]::Max(0, [int]([Math]::Pow(2, $Attempt + 1) - 1))
}

function Get-InvokeWithTimeoutRequestTimeoutSec {
  param([int]$TimeoutSec)
  if ($TimeoutSec -le 2) { return 1 }
  return [Math]::Max(1, [int]($TimeoutSec - 2))
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
    $jobName = ('{0}-{1}-{2}-{3}' -f $Name, $PID, $attempt, ([Guid]::NewGuid().ToString('N')))
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
      $done = Wait-Job -Job $job -Timeout $TimeoutSec
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
