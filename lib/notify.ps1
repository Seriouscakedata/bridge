# notify.ps1 -- Logs bridge notifications and dispatches throttled push events from configured channels.
function Get-NotifyLogPath { Join-Path (Get-BridgeRoot) 'notify.log' }
function Get-NotifyLastPath { Join-Path (Get-BridgeRoot) 'notify.last' }

function Write-NotifyLog {
  param([string]$Message)
  try {
    $safeMessage = [string]$Message
    foreach ($secretName in @('telegramBotToken','telegramChatId')) {
      try {
        $secretValue = Get-Secret $secretName
        if (-not [string]::IsNullOrWhiteSpace($secretValue)) { $safeMessage = $safeMessage.Replace($secretValue, '***') }
      } catch {}
    }
    $line = (Get-Date).ToUniversalTime().ToString('o') + ' ' + $safeMessage
    Use-BridgeLock ({ Add-Content -LiteralPath (Get-NotifyLogPath) -Value $line -Encoding UTF8 }.GetNewClosure())
  } catch {}
}

function Get-NotifyConfig {
  $defaults = @{
    enabled = $true
    events = @{
      done = $true
      need_you = $true
      gate = $true
    }
    throttleSeconds = 20
    timeoutSec = 10
  }
  $out = @{
    enabled = $defaults.enabled
    events = @{
      done = $defaults.events.done
      need_you = $defaults.events.need_you
      gate = $defaults.events.gate
    }
    throttleSeconds = $defaults.throttleSeconds
    timeoutSec = $defaults.timeoutSec
  }
  try {
    $cfg = Get-BridgeConfig
    if (-not ($cfg.PSObject.Properties.Name -contains 'notify') -or $null -eq $cfg.notify) { return $out }
    $n = $cfg.notify
    if ($n.PSObject.Properties.Name -contains 'enabled' -and $null -ne $n.enabled) { $out.enabled = [bool]$n.enabled }
    if ($n.PSObject.Properties.Name -contains 'throttleSeconds' -and $null -ne $n.throttleSeconds) { $out.throttleSeconds = [int]$n.throttleSeconds }
    if ($n.PSObject.Properties.Name -contains 'timeoutSec' -and $null -ne $n.timeoutSec) { $out.timeoutSec = [int]$n.timeoutSec }
    if ($n.PSObject.Properties.Name -contains 'events' -and $null -ne $n.events) {
      foreach ($k in @('done','need_you','gate')) {
        if ($n.events.PSObject.Properties.Name -contains $k -and $null -ne $n.events.$k) { $out.events[$k] = [bool]$n.events.$k }
      }
    }
  } catch {
    Write-NotifyLog ("config-error: " + $_.Exception.Message)
  }
  return $out
}

function Get-NotifyHash {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
  } catch {
    return ([string]$Text).GetHashCode().ToString()
  } finally {
    if ($sha) { $sha.Dispose() }
  }
}

function Send-Telegram {
  param([string]$Text)
  try {
    $token = Get-Secret 'telegramBotToken'
    $chat = Get-Secret 'telegramChatId'
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($chat)) {
      Write-NotifyLog 'skipped: no telegram creds'
      return $false
    }
    $cfg = Get-NotifyConfig
    $timeout = [Math]::Max(1, [int]$cfg.timeoutSec)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = [ordered]@{
      chat_id = $chat
      text = [string]$Text
      disable_web_page_preview = $true
    }
    $json = $body | ConvertTo-Json -Compress -Depth 5
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout
    if ($resp -and $resp.ok) {
      Write-NotifyLog 'delivered'
      return $true
    }
    Write-NotifyLog 'failed: telegram returned not ok'
    return $false
  } catch {
    Write-NotifyLog ("failed: " + $_.Exception.Message)
    return $false
  }
}

function Send-PushEvent {
  param(
    [ValidateSet('done','need_you','gate')] [string]$Kind,
    [string]$Text
  )
  try {
    $cfg = Get-NotifyConfig
    if (-not [bool]$cfg.enabled) {
      Write-NotifyLog "skipped: disabled $Kind"
      return $false
    }
    if (-not [bool]$cfg.events[$Kind]) {
      Write-NotifyLog "skipped: event disabled $Kind"
      return $false
    }
    $prefix = @{
      done = '✅ Закончил'
      need_you = '🙋 Нужен ты'
      gate = '🛡 Упёрся в гейт'
    }[$Kind]
    $body = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { $body = $Kind }
    $message = "$prefix`n$body"
    $key = $Kind + ':' + (Get-NotifyHash $message)
    $lastPath = Get-NotifyLastPath
    if (Test-Path -LiteralPath $lastPath) {
      try {
        $lastText = [System.IO.File]::ReadAllText($lastPath, [System.Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($lastText)) {
          $last = $lastText | ConvertFrom-Json
          $lastTs = [DateTimeOffset]::Parse([string]$last.ts).UtcDateTime
          $age = ([DateTime]::UtcNow - $lastTs).TotalSeconds
          if ([string]$last.key -eq $key -and $age -lt [int]$cfg.throttleSeconds) {
            Write-NotifyLog "skipped: throttled $Kind"
            return $false
          }
        }
      } catch {
        Write-NotifyLog ("last-read-error: " + $_.Exception.Message)
      }
    }
    $ok = Send-Telegram -Text $message
    $lastRec = [ordered]@{ ts = [DateTime]::UtcNow.ToString('o'); key = $key; kind = $Kind; delivered = [bool]$ok }
    try {
      [System.IO.File]::WriteAllText($lastPath, ($lastRec | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      Write-NotifyLog ("last-write-error: " + $_.Exception.Message)
    }
    return [bool]$ok
  } catch {
    Write-NotifyLog ("push-error: " + $_.Exception.Message)
    return $false
  }
}
