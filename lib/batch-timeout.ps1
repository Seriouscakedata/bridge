function Get-BatchTimeoutBackoffSec {
  param([int]$Attempt)

  if ($Attempt -le 1) { return 10 }
  if ($Attempt -eq 2) { return 30 }
  return 60
}

function Get-BatchTimeoutTaskOverride {
  param(
    $Task,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Task -or [string]::IsNullOrWhiteSpace($Name)) { return $Default }

  if ($Task -is [System.Collections.IDictionary]) {
    if ($Task.Contains($Name)) { return $Task[$Name] }
    return $Default
  }

  try {
    if ($Task.PSObject.Properties.Name -contains $Name) {
      return $Task.$Name
    }
  } catch {}

  return $Default
}

function Stop-BatchTimeoutJob {
  param($Job)

  if (-not $Job) { return }

  try {
    if ([string]$Job.State -eq 'Running') {
      Stop-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
    }
  } catch {}

  try {
    Wait-Job -Job $Job -Timeout 2 -ErrorAction SilentlyContinue | Out-Null
  } catch {}

  try {
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
  } catch {}
}

function Ensure-BatchTimeoutCommonLoaded {
  if (Get-Command Read-State -ErrorAction SilentlyContinue) { return }

  $commonPath = Join-Path $PSScriptRoot 'common.ps1'
  if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Read-State is unavailable and common.ps1 was not found: $commonPath"
  }

  . $commonPath
}

function Invoke-BatchWithPerTaskTimeout {
  param(
    [array]$Tasks,
    [scriptblock]$ExecuteTask,
    [int]$TimeoutSec,
    [int]$MaxAttempts = 3,
    [string]$Name = 'batch'
  )

  if ($null -eq $ExecuteTask) { throw 'Invoke-BatchWithPerTaskTimeout requires ExecuteTask.' }
  if ($TimeoutSec -le 0) { throw 'Invoke-BatchWithPerTaskTimeout requires TimeoutSec > 0.' }
  if ($MaxAttempts -le 0) { throw 'Invoke-BatchWithPerTaskTimeout requires MaxAttempts > 0.' }

  $taskList = @($Tasks)
  $succeeded = New-Object 'System.Collections.Generic.List[int]'
  $timedOut = New-Object 'System.Collections.Generic.List[int]'
  $failed = New-Object 'System.Collections.Generic.List[int]'
  $results = New-Object 'System.Collections.Generic.List[object]'
  $taskScriptText = $ExecuteTask.ToString()

  for ($i = 0; $i -lt $taskList.Count; $i++) {
    $task = $taskList[$i]
    $taskTimeoutSec = [int](Get-BatchTimeoutTaskOverride -Task $task -Name 'TimeoutSec' -Default $TimeoutSec)
    if ($taskTimeoutSec -le 0) { $taskTimeoutSec = $TimeoutSec }

    $taskMaxAttempts = [int](Get-BatchTimeoutTaskOverride -Task $task -Name 'MaxAttempts' -Default $MaxAttempts)
    if ($taskMaxAttempts -le 0) { $taskMaxAttempts = $MaxAttempts }

    $taskTimedOut = $false
    $taskSucceeded = $false
    $taskResult = $null
    $lastError = ''
    $attemptsUsed = 0

    for ($attempt = 1; $attempt -le $taskMaxAttempts; $attempt++) {
      $attemptsUsed = $attempt
      $job = $null

      try {
        $job = Start-Job -ScriptBlock {
          param($t, [string]$taskScript)
          $sb = [scriptblock]::Create($taskScript)
          & $sb $t
        } -ArgumentList $task, $taskScriptText

        $done = Wait-Job -Job $job -Timeout $taskTimeoutSec -ErrorAction Stop
        if ($done) {
          $taskResult = Receive-Job -Job $job -ErrorAction Stop
          Stop-BatchTimeoutJob -Job $job
          $job = $null
          $taskSucceeded = $true
          [void]$succeeded.Add($i)
          break
        }

        $taskTimedOut = $true
        Write-Host ("[batch-timeout] task {0} timed out (attempt {1}/{2})" -f $i, $attempt, $taskMaxAttempts)
        Stop-BatchTimeoutJob -Job $job
        $job = $null

        if ($attempt -lt $taskMaxAttempts) {
          $backoffSec = Get-BatchTimeoutBackoffSec -Attempt $attempt
          if ($backoffSec -gt 0) { Start-Sleep -Seconds $backoffSec }
          continue
        }

        $lastError = "Timed out after $taskTimeoutSec seconds"
      } catch {
        $lastError = $_.Exception.Message

        if ($job) {
          try {
            $state = [string]$job.State
            if ($state -eq 'Running') {
              $taskTimedOut = $true
              Write-Host ("[batch-timeout] task {0} timed out (attempt {1}/{2})" -f $i, $attempt, $taskMaxAttempts)
            }
          } catch {}
        }

        if ($attempt -lt $taskMaxAttempts) {
          if ($taskTimedOut) {
            $backoffSec = Get-BatchTimeoutBackoffSec -Attempt $attempt
            if ($backoffSec -gt 0) { Start-Sleep -Seconds $backoffSec }
          }
          continue
        }
      } finally {
        if ($job) {
          Stop-BatchTimeoutJob -Job $job
        }
      }
    }

    if ($taskTimedOut) { [void]$timedOut.Add($i) }
    if (-not $taskSucceeded) { [void]$failed.Add($i) }

    $results.Add([pscustomobject]@{
      Index       = $i
      Task        = $task
      Status      = if ($taskSucceeded) { 'Success' } elseif ($taskTimedOut) { 'TimedOut' } else { 'Failed' }
      Attempts    = $attemptsUsed
      TimeoutSec  = $taskTimeoutSec
      MaxAttempts = $taskMaxAttempts
      Result      = $taskResult
      Error       = $lastError
    }) | Out-Null
  }

  return @{
    Succeeded = @($succeeded.ToArray())
    TimedOut  = @($timedOut.ToArray())
    Failed    = @($failed.ToArray())
    Results   = @($results.ToArray())
  }
}

function Get-BatchTimeoutConfig {
  Ensure-BatchTimeoutCommonLoaded

  $state = $null
  try { $state = Read-State } catch {}

  $timeoutSec = 600
  try {
    $rawTimeout = Get-BatchTimeoutTaskOverride -Task $state -Name 'workpack_batch_per_task_timeout_sec' -Default $timeoutSec
    $timeoutSec = [int]$rawTimeout
  } catch {
    $timeoutSec = 600
  }

  if ($timeoutSec -lt 0) { $timeoutSec = 0 }

  return @{
    TimeoutSec  = [int]$timeoutSec
    MaxAttempts = 3
    Enabled     = ([int]$timeoutSec -gt 0)
  }
}

function Test-BatchTimeoutSelfTest {
  $tasks = @(
    [pscustomobject]@{ TimeoutSec = 10; SleepSec = 1; Result = 'ok1' },
    [pscustomobject]@{ TimeoutSec = 5; MaxAttempts = 2; SleepSec = 30; Result = 'late2' },
    [pscustomobject]@{ TimeoutSec = 10; SleepSec = 1; Result = 'ok3' }
  )

  $result = Invoke-BatchWithPerTaskTimeout -Tasks $tasks -ExecuteTask {
    param($Task)
    Start-Sleep -Seconds ([int]$Task.SleepSec)
    return [string]$Task.Result
  } -TimeoutSec 10 -MaxAttempts 3 -Name 'batch-selftest'

  $succeeded = @($result.Succeeded | ForEach-Object { [int]$_ } | Sort-Object)
  $timedOut = @($result.TimedOut | ForEach-Object { [int]$_ } | Sort-Object)
  $failed = @($result.Failed | ForEach-Object { [int]$_ } | Sort-Object)

  if (($succeeded -join ',') -ne '0,2') { return $false }
  if (($timedOut -join ',') -ne '1') { return $false }
  if (($failed -join ',') -ne '1') { return $false }
  if (@($result.Results).Count -ne 3) { return $false }

  try {
    if ([string]$result.Results[0].Result -ne 'ok1') { return $false }
    if ([string]$result.Results[1].Status -ne 'TimedOut') { return $false }
    if ([string]$result.Results[2].Result -ne 'ok3') { return $false }
  } catch {
    return $false
  }

  return $true
}
