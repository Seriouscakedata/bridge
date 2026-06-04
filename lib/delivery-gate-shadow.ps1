# delivery-gate-shadow.ps1 -- fail-open JSONL writer for Delivery Gate shadow reports.
#
# This module writes only channels/<channel>/delivery-gate-shadow.jsonl. It does
# not mutate state, backlog, memory, runtime caches, or git data.

$script:DeliveryGateShadowRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:DeliveryGateShadowRoot 'lib\delivery-gate.ps1')
. (Join-Path $script:DeliveryGateShadowRoot 'lib\delivery-gate-facts.ps1')

function Normalize-DeliveryGateShadowChannel {
  param([string]$Channel)

  if ([string]::IsNullOrWhiteSpace($Channel)) { return '' }
  $slug = $Channel.Trim()
  if ($slug -match '[\\/]' -or $slug -eq '.' -or $slug -eq '..' -or $slug -match '\.\.') { return '' }
  if ($slug -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return '' }
  return $slug
}

function Write-DeliveryGateShadowRecord {
  param(
    [string]$BridgeRoot,
    [string]$Channel,
    [string]$TaskId,
    [string]$TaskText,
    [string]$BaseCommit,
    [string]$HeadCommit,
    $Facts,
    $Result,
    [string]$Note = ''
  )

  $targetPath = ''
  try {
    if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
      return [pscustomobject]@{ ok = $false; path = ''; error = 'BridgeRoot is required' }
    }

    $channelSlug = Normalize-DeliveryGateShadowChannel -Channel $Channel
    if ([string]::IsNullOrWhiteSpace($channelSlug)) {
      return [pscustomobject]@{ ok = $false; path = ''; error = 'Channel is invalid' }
    }

    $rootPath = [System.IO.Path]::GetFullPath($BridgeRoot)
    $channelsPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath 'channels'))
    $channelPath = [System.IO.Path]::GetFullPath((Join-Path $channelsPath $channelSlug))
    if (-not $channelPath.StartsWith($channelsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ ok = $false; path = ''; error = 'Channel path escapes channels root' }
    }

    if (-not (Test-Path -LiteralPath $channelPath)) {
      New-Item -ItemType Directory -Path $channelPath -Force | Out-Null
    }

    $targetPath = Join-Path $channelPath 'delivery-gate-shadow.jsonl'
    $record = [ordered]@{
      ts          = (Get-Date).ToUniversalTime().ToString('o')
      channel     = $channelSlug
      task_id     = [string]$TaskId
      task_text   = [string]$TaskText
      base_commit = [string]$BaseCommit
      head_commit = [string]$HeadCommit
      facts       = $Facts
      result      = $Result
      note        = [string]$Note
    }

    $json = $record | ConvertTo-Json -Depth 10 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($targetPath, ($json + "`n"), $utf8NoBom)
    return [pscustomobject]@{ ok = $true; path = $targetPath; error = '' }
  } catch {
    return [pscustomobject]@{ ok = $false; path = $targetPath; error = $_.Exception.Message }
  }
}
