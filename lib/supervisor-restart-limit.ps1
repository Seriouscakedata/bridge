# supervisor-restart-limit.ps1 -- in-memory per-process restart limiter for supervisor.ps1.
# Dot-source friendly: no live supervisor side effects on import.

function Get-SupervisorRestartLimitSettings {
  param([object]$Config = $null)
  $out = [ordered]@{
    maxPerHour = 10
    windowMin = 60
    cooldownMin = 30
  }
  try {
    if ($null -eq $Config -and (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue)) {
      $Config = Get-BridgeConfig
    }
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'supervisor') -and $Config.supervisor) {
      $sup = $Config.supervisor
      if ($sup.PSObject.Properties.Name -contains 'restartLimitMaxPerHour' -and $null -ne $sup.restartLimitMaxPerHour) {
        $out.maxPerHour = [int]$sup.restartLimitMaxPerHour
      }
      if ($sup.PSObject.Properties.Name -contains 'restartLimitWindowMin' -and $null -ne $sup.restartLimitWindowMin) {
        $out.windowMin = [int]$sup.restartLimitWindowMin
      }
      if ($sup.PSObject.Properties.Name -contains 'restartLimitCooldownMin' -and $null -ne $sup.restartLimitCooldownMin) {
        $out.cooldownMin = [int]$sup.restartLimitCooldownMin
      }
    }
  } catch {}
  if ([int]$out.maxPerHour -lt 1) { $out.maxPerHour = 10 }
  if ([int]$out.windowMin -lt 1) { $out.windowMin = 60 }
  if ([int]$out.cooldownMin -lt 1) { $out.cooldownMin = 30 }
  return [pscustomobject]$out
}

function Convert-SupervisorExitCodeList {
  param(
    [object]$Value,
    [int[]]$Default = @()
  )
  if ($null -eq $Value) { return @($Default) }
  $codes = @()
  foreach ($item in @($Value)) {
    try { $codes += [int]$item }
    catch { Write-Verbose ("Ignoring invalid supervisor fatal exit code '" + $item + "': " + $_.Exception.Message) }
  }
  return @($codes | Select-Object -Unique)
}

function Get-SupervisorFatalExitCodeSettings {
  param([object]$Config = $null)
  $driverCodes = @(3)
  $serverCodes = @()
  try {
    if ($null -eq $Config -and (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue)) {
      $Config = Get-BridgeConfig
    }
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'supervisor') -and $Config.supervisor) {
      $sup = $Config.supervisor
      if ($sup.PSObject.Properties.Name -contains 'fatalDriverExitCodes') {
        $driverCodes = @(Convert-SupervisorExitCodeList -Value $sup.fatalDriverExitCodes -Default @())
      }
      if ($sup.PSObject.Properties.Name -contains 'fatalServerExitCodes') {
        $serverCodes = @(Convert-SupervisorExitCodeList -Value $sup.fatalServerExitCodes -Default @())
      }
    }
  } catch {
    Write-Verbose ("Get-SupervisorFatalExitCodeSettings fallback to defaults: " + $_.Exception.Message)
  }
  return [pscustomobject]@{
    fatalDriverExitCodes = @($driverCodes)
    fatalServerExitCodes = @($serverCodes)
  }
}

function Test-SupervisorFatalExitCode {
  param(
    [Parameter(Mandatory=$true)][int]$ExitCode,
    [object]$FatalCodes
  )
  foreach ($code in @($FatalCodes)) {
    try {
      if ([int]$code -eq $ExitCode) { return $true }
    } catch {
      Write-Verbose ("Ignoring invalid fatal exit code '" + $code + "': " + $_.Exception.Message)
    }
  }
  return $false
}

function Format-SupervisorProcessExitLine {
  param(
    [Parameter(Mandatory=$true)][string]$ProcessKey,
    [Parameter(Mandatory=$true)][int]$ExitCode
  )
  return ($ProcessKey + " EXITED exitCode=" + $ExitCode + " - reading stderr tail...")
}

function New-SupervisorRestartLimitState {
  return @{}
}

function Get-SupervisorRestartLimitEntry {
  param(
    [Parameter(Mandatory=$true)][hashtable]$State,
    [Parameter(Mandatory=$true)][string]$Key
  )
  if (-not $State.ContainsKey($Key)) {
    $State[$Key] = [pscustomobject]@{
      attempts = @()
      cooldownUntil = $null
      lastCooldownNoticeAt = $null
    }
  }
  return $State[$Key]
}

function Invoke-SupervisorRestartLimitCallback {
  param([scriptblock]$Callback, [string]$Message)
  if ($Callback) {
    try { & $Callback $Message } catch {}
  }
}

function Invoke-SupervisorRestartLimitNotice {
  param(
    [string]$Message,
    [scriptblock]$LogCallback = $null,
    [scriptblock]$MessageCallback = $null,
    [scriptblock]$PushCallback = $null
  )
  Invoke-SupervisorRestartLimitCallback -Callback $LogCallback -Message $Message
  Invoke-SupervisorRestartLimitCallback -Callback $MessageCallback -Message $Message
  Invoke-SupervisorRestartLimitCallback -Callback $PushCallback -Message $Message
}

function Test-SupervisorRestartAllowed {
  param(
    [Parameter(Mandatory=$true)][hashtable]$State,
    [Parameter(Mandatory=$true)][string]$Key,
    [object]$Settings = $null,
    [datetime]$Now = (Get-Date),
    [scriptblock]$LogCallback = $null,
    [scriptblock]$MessageCallback = $null,
    [scriptblock]$PushCallback = $null
  )
  if ([string]::IsNullOrWhiteSpace($Key)) { $Key = 'unknown' }
  if ($null -eq $Settings) { $Settings = Get-SupervisorRestartLimitSettings }
  $maxPerHour = [Math]::Max(1, [int]$Settings.maxPerHour)
  $windowMin = [Math]::Max(1, [int]$Settings.windowMin)
  $cooldownMin = [Math]::Max(1, [int]$Settings.cooldownMin)
  $entry = Get-SupervisorRestartLimitEntry -State $State -Key $Key
  $nowUtc = ([datetime]$Now).ToUniversalTime()

  if ($entry.cooldownUntil) {
    $untilUtc = ([datetime]$entry.cooldownUntil).ToUniversalTime()
    if ($nowUtc -lt $untilUtc) {
      $shouldNotice = $false
      if (-not $entry.lastCooldownNoticeAt) { $shouldNotice = $true }
      else {
        $lastNoticeUtc = ([datetime]$entry.lastCooldownNoticeAt).ToUniversalTime()
        if (($nowUtc - $lastNoticeUtc).TotalSeconds -ge 60) { $shouldNotice = $true }
      }
      if ($shouldNotice) {
        $entry.lastCooldownNoticeAt = $nowUtc
        Invoke-SupervisorRestartLimitNotice -LogCallback $LogCallback -MessageCallback $MessageCallback -PushCallback $PushCallback -Message ("SUPERVISOR-RESTART-LIMIT: " + $Key + " start suppressed until " + $untilUtc.ToString('o') + " after exceeding " + $maxPerHour + " restarts/" + $windowMin + "min")
      }
      return [pscustomobject]@{ allowed = $false; status = 'cooldown-active'; key = $Key; cooldownUntil = $untilUtc; attemptsInWindow = @($entry.attempts).Count }
    }
    $entry.cooldownUntil = $null
    $entry.lastCooldownNoticeAt = $null
    $entry.attempts = @()
    Invoke-SupervisorRestartLimitCallback -Callback $LogCallback -Message ("SUPERVISOR-RESTART-LIMIT: " + $Key + " cooldown expired; restart attempts resume")
  }

  $cutoffUtc = $nowUtc.AddMinutes(-1 * $windowMin)
  $entry.attempts = @($entry.attempts | Where-Object { ([datetime]$_).ToUniversalTime() -ge $cutoffUtc })
  $count = @($entry.attempts).Count
  if ($count -ge $maxPerHour) {
    $untilUtc = $nowUtc.AddMinutes($cooldownMin)
    $entry.cooldownUntil = $untilUtc
    $entry.lastCooldownNoticeAt = $nowUtc
    $msg = "SUPERVISOR-RESTART-LIMIT: " + $Key + " exceeded " + $maxPerHour + " restarts/" + $windowMin + "min; cooldown until " + $untilUtc.ToString('o')
    Invoke-SupervisorRestartLimitNotice -LogCallback $LogCallback -MessageCallback $MessageCallback -PushCallback $PushCallback -Message $msg
    return [pscustomobject]@{ allowed = $false; status = 'entered-cooldown'; key = $Key; cooldownUntil = $untilUtc; attemptsInWindow = $count }
  }

  $entry.attempts = @($entry.attempts + $nowUtc)
  return [pscustomobject]@{ allowed = $true; status = 'allowed'; key = $Key; cooldownUntil = $null; attemptsInWindow = ($count + 1) }
}
