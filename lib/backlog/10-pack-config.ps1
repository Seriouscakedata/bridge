# 10-pack-config.ps1 -- Backlog packer configuration, pressure, and pack requests.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function Get-BacklogPackObjectValue {
  param($Obj, [string]$Name, $Default = $null)
  try {
    if ($Obj -and ($Obj.PSObject.Properties.Name -contains $Name) -and $null -ne $Obj.PSObject.Properties[$Name].Value) {
      return $Obj.PSObject.Properties[$Name].Value
    }
  } catch {}
  return $Default
}

function ConvertTo-BacklogPackBool {
  param($Value, [bool]$Default = $true)
  try {
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (@('true','1','yes','on','enabled') -contains $s) { return $true }
    if (@('false','0','no','off','disabled') -contains $s) { return $false }
  } catch {}
  return $Default
}

function ConvertTo-BacklogPackInt {
  param($Value, [int]$Default, [int]$Min = 0, [int]$Max = 1000000)
  $n = 0.0
  try {
    if ([double]::TryParse([string]$Value, [ref]$n)) {
      $i = [int][Math]::Round($n)
      if ($i -lt $Min) { return $Min }
      if ($i -gt $Max) { return $Max }
      return $i
    }
  } catch {}
  return $Default
}

function Get-BacklogPackConfig {
  $cfg = [ordered]@{
    enabled            = $true
    burstCount         = 5
    windowMinutes      = 60
    unpackedOpenCount  = 8
    auditBurstCount    = 3
    auditWindowMinutes = 30
    cooldownMinutes    = 30
    minItems           = 2
  }
  $dotted = @{
    'backlogPack.enabled'            = 'enabled'
    'backlogPack.burstCount'         = 'burstCount'
    'backlogPack.windowMinutes'      = 'windowMinutes'
    'backlogPack.unpackedOpenCount'  = 'unpackedOpenCount'
    'backlogPack.auditBurstCount'    = 'auditBurstCount'
    'backlogPack.auditWindowMinutes' = 'auditWindowMinutes'
    'backlogPack.cooldownMinutes'    = 'cooldownMinutes'
    'backlogPack.minItems'           = 'minItems'
  }
  $flat = @{
    backlogPackEnabled            = 'enabled'
    backlogPackBurstCount         = 'burstCount'
    backlogPackWindowMinutes      = 'windowMinutes'
    backlogPackUnpackedOpenCount  = 'unpackedOpenCount'
    backlogPackAuditBurstCount    = 'auditBurstCount'
    backlogPackAuditWindowMinutes = 'auditWindowMinutes'
    backlogPackCooldownMinutes    = 'cooldownMinutes'
    backlogPackMinItems           = 'minItems'
  }
  try {
    if (Get-Command Get-AdvancedSettings -ErrorAction SilentlyContinue) {
      $adv = Get-AdvancedSettings
      foreach ($k in $dotted.Keys) {
        if ($adv -and $adv.Contains($k) -and $null -ne $adv[$k]) { $cfg[$dotted[$k]] = $adv[$k] }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.burstCount = ConvertTo-BacklogPackInt -Value $cfg.burstCount -Default 5 -Min 2 -Max 1000
  $cfg.windowMinutes = ConvertTo-BacklogPackInt -Value $cfg.windowMinutes -Default 60 -Min 1 -Max 1440
  $cfg.unpackedOpenCount = ConvertTo-BacklogPackInt -Value $cfg.unpackedOpenCount -Default 8 -Min 2 -Max 1000
  $cfg.auditBurstCount = ConvertTo-BacklogPackInt -Value $cfg.auditBurstCount -Default 3 -Min 2 -Max 1000
  $cfg.auditWindowMinutes = ConvertTo-BacklogPackInt -Value $cfg.auditWindowMinutes -Default 30 -Min 1 -Max 1440
  $cfg.cooldownMinutes = ConvertTo-BacklogPackInt -Value $cfg.cooldownMinutes -Default 30 -Min 1 -Max 1440
  $cfg.minItems = ConvertTo-BacklogPackInt -Value $cfg.minItems -Default 2 -Min 1 -Max 50
  return [pscustomobject]$cfg
}

function Get-BacklogPackChannel {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
      $slug = [string](Get-EffectiveChannel)
      if (-not [string]::IsNullOrWhiteSpace($slug)) { return $slug }
    }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-BacklogPackDir {
  $dir = $null
  try {
    if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
      $dir = Join-Path (Get-ChannelDir) 'workpacks'
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace([string]$dir)) {
    $dir = Join-Path (Get-BacklogControlDir) 'workpacks'
  }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Get-BacklogPackRequestPath { Join-Path (Get-BacklogPackDir) 'pack.request.json' }
function Get-BacklogPackLatestPath { Join-Path (Get-BacklogPackDir) 'latest.json' }
function Get-BacklogPackRunsPath { Join-Path (Get-BacklogPackDir) 'runs.jsonl' }

function Test-BacklogPackItemOpen {
  param($Item)
  $status = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'status' -Default '')
  return ($status -in @('new','approved','held'))
}

function Test-BacklogPackItemUnpacked {
  param($Item)
  $packId = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'workpack_id' -Default '')
  return [string]::IsNullOrWhiteSpace($packId)
}

function Test-BacklogPackItemAuditSource {
  param($Item)
  $from = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'from' -Default '')).ToLowerInvariant()
  if ($from -match 'audit') { return $true }
  $text = ([string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')).ToLowerInvariant()
  if ($text -match '^\s*\[(deep-)?audit[/: -]') { return $true }
  try {
    $tags = @(Get-BacklogPackObjectValue -Obj $Item -Name 'tags' -Default @() | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($tag in $tags) {
      if ($tag -match 'audit') { return $true }
    }
  } catch {}
  return $false
}

function Get-BacklogPackLastRun {
  $p = Get-BacklogPackLatestPath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-BacklogPackPressure {
  param($Config = $null)
  if (-not $Config) { $Config = Get-BacklogPackConfig }
  $now = (Get-Date).ToUniversalTime()
  $recentCut = $now.AddMinutes(-[Math]::Abs([int]$Config.windowMinutes))
  $auditCut = $now.AddMinutes(-[Math]::Abs([int]$Config.auditWindowMinutes))
  $recent = 0
  $auditRecent = 0
  $openUnpacked = 0
  $sample = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in @(Get-Backlog)) {
    if (-not (Test-BacklogPackItemOpen -Item $item)) { continue }
    if (-not (Test-BacklogPackItemUnpacked -Item $item)) { continue }
    $openUnpacked++
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($id) -and $sample.Count -lt 10) { [void]$sample.Add($id) }
    $ts = $null
    try { $ts = [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $item -Name 'ts' -Default '')).ToUniversalTime() } catch { $ts = $null }
    if ($ts -and $ts -ge $recentCut) { $recent++ }
    if ($ts -and $ts -ge $auditCut -and (Test-BacklogPackItemAuditSource -Item $item)) { $auditRecent++ }
  }
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  if ($recent -ge [int]$Config.burstCount) { [void]$reasons.Add(("burst:{0}/{1}m" -f $recent, [int]$Config.windowMinutes)) }
  if ($openUnpacked -ge [int]$Config.unpackedOpenCount) { [void]$reasons.Add(("open-unpacked:{0}" -f $openUnpacked)) }
  if ($auditRecent -ge [int]$Config.auditBurstCount) { [void]$reasons.Add(("audit-burst:{0}/{1}m" -f $auditRecent, [int]$Config.auditWindowMinutes)) }
  return [pscustomobject]@{
    needed                = ($reasons.Count -gt 0)
    reasons               = @($reasons.ToArray())
    recent_unpacked_open  = $recent
    open_unpacked         = $openUnpacked
    recent_audit_unpacked = $auditRecent
    sample_ids            = @($sample.ToArray())
    channel               = Get-BacklogPackChannel
  }
}

function Request-BacklogPackIfNeeded {
  param([string]$NewItemId = '')
  try {
    $cfg = Get-BacklogPackConfig
    if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ requested=$false; reason='disabled' } }
    $pressure = Get-BacklogPackPressure -Config $cfg
    if (-not [bool]$pressure.needed) { return [pscustomobject]@{ requested=$false; reason='below-threshold'; pressure=$pressure } }
    $requestPath = Get-BacklogPackRequestPath
    if (Test-Path -LiteralPath $requestPath) {
      return [pscustomobject]@{ requested=$true; existing=$true; path=$requestPath; pressure=$pressure }
    }
    $last = Get-BacklogPackLastRun
    if ($last) {
      try {
        $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
        $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
        if ($ageMin -lt [int]$cfg.cooldownMinutes) {
          return [pscustomobject]@{ requested=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
        }
      } catch {}
    }
    $req = [ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      channel = [string]$pressure.channel
      reasons = @($pressure.reasons)
      counts = [ordered]@{
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        open_unpacked = [int]$pressure.open_unpacked
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
      }
      sample_ids = @($pressure.sample_ids)
      new_item_id = [string]$NewItemId
    }
    $json = ($req | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path $requestPath -Content $json
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = $req.ts
        action = 'pack-request'
        channel = [string]$pressure.channel
        reasons = @($pressure.reasons)
        open_unpacked = [int]$pressure.open_unpacked
        recent_unpacked_open = [int]$pressure.recent_unpacked_open
        recent_audit_unpacked = [int]$pressure.recent_audit_unpacked
        new_item_id = [string]$NewItemId
      })
    } catch {}
    return [pscustomobject]@{ requested=$true; existing=$false; path=$requestPath; pressure=$pressure }
  } catch {
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='pack-request-error'; error=[string]$_.Exception.Message }) } catch {}
    return [pscustomobject]@{ requested=$false; reason='error'; error=[string]$_.Exception.Message }
  }
}
