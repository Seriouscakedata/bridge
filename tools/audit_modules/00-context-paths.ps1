function Get-AuditBridgeRoot {
  param([string]$Hint)
  if ($Hint -and (Test-Path -LiteralPath $Hint)) { return ([System.IO.Path]::GetFullPath($Hint)) }
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) {
    try { return (Get-BridgeRoot) } catch {}
  }
  # tools/audit.ps1 -> parent of tools/ is bridge root
  $toolsRoot = $script:AuditToolsRoot
  if ([string]::IsNullOrWhiteSpace($toolsRoot)) { $toolsRoot = Split-Path -Parent $PSScriptRoot }
  return ([System.IO.Path]::GetFullPath((Split-Path -Parent $toolsRoot)))
}

function Get-AuditDir {
  param([string]$BridgePath)
  Join-Path $BridgePath 'audit'
}

function Normalize-AuditChannelSlug {
  param([string]$Channel)
  if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) {
    try { return (Normalize-ChannelSlug $Channel) } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { return 'main' }
  $slug = ([string]$Channel).Trim().ToLowerInvariant()
  $slug = ($slug -replace '\s+', '-' -replace '[^a-z0-9_-]+', '-').Trim('-','_')
  if ([string]::IsNullOrWhiteSpace($slug)) { return 'main' }
  return $slug
}

function Test-AuditSamePath {
  param([string]$Left, [string]$Right)
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  try {
    $trim = [char[]]@('\','/')
    $a = [System.IO.Path]::GetFullPath($Left).TrimEnd($trim)
    $b = [System.IO.Path]::GetFullPath($Right).TrimEnd($trim)
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return ([string]::Equals($Left.TrimEnd('\','/'), $Right.TrimEnd('\','/'), [System.StringComparison]::OrdinalIgnoreCase))
  }
}

function Get-AuditChannelDir {
  param([string]$BridgePath, [string]$Channel)
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
    try { return (Get-ChannelDir -Slug $slug) } catch {}
  }
  return (Join-Path (Join-Path $BridgePath 'channels') $slug)
}

function Get-AuditReportDir {
  param(
    [string]$BridgePath,
    [string]$Channel = 'main',
    [string]$Kind = 'bridge'
  )
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  $kindNorm = ([string]$Kind).ToLowerInvariant()
  if ($slug -eq 'main' -or $kindNorm -eq 'bridge') {
    return (Get-AuditDir -BridgePath $BridgePath)
  }
  return (Join-Path (Get-AuditChannelDir -BridgePath $BridgePath -Channel $slug) 'audit')
}

function New-AuditContext {
  param(
    [string]$BridgePath,
    [string]$Channel = 'main',
    [string]$ProjectRoot = $null
  )
  $bridgeRoot = Get-AuditBridgeRoot -Hint $BridgePath
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  $target = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ($slug -eq 'main') { $bridgeRoot } else { '' }
  } else {
    [string]$ProjectRoot
  }
  try { $target = [System.IO.Path]::GetFullPath($target) } catch {}
  $isBridge = ($slug -eq 'main')
  $kind = if ($isBridge) { 'bridge' } else { 'project' }
  $reportRoot = Get-AuditReportDir -BridgePath $bridgeRoot -Channel $slug -Kind $kind
  $backlogChannel = if ($kind -eq 'bridge') { 'main' } else { $slug }
  [pscustomobject][ordered]@{
    kind            = $kind
    channel         = $slug
    bridge_root     = $bridgeRoot
    target_root     = $target
    report_root     = $reportRoot
    backlog_channel = $backlogChannel
    profile         = if ($kind -eq 'bridge') { 'bridge-self' } else { 'external-project' }
  }
}

function Get-AuditLockPath {
  param([string]$BridgePath)
  Join-Path (Get-AuditDir -BridgePath $BridgePath) '.audit.lock'
}

function Get-AuditLastMarker {
  param([string]$BridgePath, [string]$AuditDir = $null)
  $dir = if ([string]::IsNullOrWhiteSpace($AuditDir)) { Get-AuditDir -BridgePath $BridgePath } else { $AuditDir }
  Join-Path $dir 'audit.last'
}

function Get-FindingsLedgerPath {
  param([string]$BridgePath, [string]$AuditDir = $null)
  $dir = if ([string]::IsNullOrWhiteSpace($AuditDir)) { Get-AuditDir -BridgePath $BridgePath } else { $AuditDir }
  Join-Path $dir 'findings-ledger.jsonl'
}

function Get-AuditMainBacklogPath {
  param([string]$BridgePath)
  $channelPath = Join-Path $BridgePath 'channels\main\backlog.jsonl'
  $channelDir = Split-Path -Parent $channelPath
  if (Test-Path -LiteralPath $channelDir -PathType Container) { return $channelPath }
  return (Join-Path $BridgePath 'backlog.jsonl')
}

function Get-AuditBacklogPath {
  param([string]$BridgePath, [string]$Channel = 'main')
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  if ($slug -eq 'main') { return (Get-AuditMainBacklogPath -BridgePath $BridgePath) }
  if (Get-Command Get-ChannelBacklogPath -ErrorAction SilentlyContinue) {
    try { return (Get-ChannelBacklogPath -Slug $slug) } catch {}
  }
  return (Join-Path (Get-AuditChannelDir -BridgePath $BridgePath -Channel $slug) 'backlog.jsonl')
}

function Format-AuditNativeArg {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '""' }
  $s = [string]$Value
  if ($s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }
  return '"' + ($s -replace '"','\"') + '"'
}
