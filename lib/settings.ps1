# settings.ps1 -- user-tunable runtime settings, stored OUTSIDE git (settings.json) so they
# survive watchdog rollbacks (config.json is tracked and would be reset). settings.json
# overlays the config.json 'autonomy' defaults. Dot-sourced from common.ps1.

function Get-SettingsPath { Join-Path (Get-BridgeRoot) 'settings.json' }

function Get-Settings {
  $p = Get-SettingsPath
  if (-not (Test-Path $p)) { return ([pscustomobject]@{}) }
  try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return ([pscustomobject]@{}) }
}

function Save-Settings {
  param($Obj)
  Write-AtomicFile -Path (Get-SettingsPath) -Content ($Obj | ConvertTo-Json -Depth 6)
}

function Get-AutonomySettings {
  # Effective autonomy config: built-in defaults <- config.json 'autonomy' <- settings.json.
  $out = [ordered]@{
    enabled                  = $true
    requireApproval          = $false
    idleQuietMinutes         = 10
    maxAutonomousTasksPerDay = 0
    # 2026-05-30: per-channel autonomy. Channels listed here do NOT auto-claim
    # backlog tasks (they still respond to explicit user messages). Default: travel
    # off, main on -- so the two channels don't fight over the single shared Codex.
    autonomyDisabledChannels = @('travel')
    reflectEveryHours        = 6
    maxIdeasPerReflect       = 3
    stablePromoteMinutes     = 30
    scope                    = 'bridge'   # 'bridge' = only the bridge; 'projects' = bridge + its projects
    # Graduated self-development of UNapproved 'new' backlog ideas (the selection-autonomy axis).
    # Default 'shadow' is safe: the system surfaces WHICH new idea + risk tier it would self-pick
    # but executes nothing. The operator dials up only after trusting the classifier from logs.
    #   off    = legacy — only human/curator-approved ideas ever run; no shadow logging
    #   shadow = log the would-pick + risk tier (green/yellow/red), no execution            [default]
    #   green  = ALSO auto-execute green-tier (low-blast-radius, reversible) new ideas, no approval
    #   yellow = ALSO auto-execute yellow-tier new ideas (broader; opt-in)
    # red-tier (security/irreversible/externally-sourced) NEVER auto-executes at any dial.
    selfExecuteTier          = 'shadow'
    # Anti-junk brainstorm controls (2026-05-29): keep the backlog from flooding with junk.
    #   maxOpenIdeas     = WIP cap. Proactive generators (reflect/architect) stay SILENT while open
    #                      (new+approved+running) ideas >= this, so the queue drains first. Reactive
    #                      deep-audit (real bugs) is NOT gated.
    #   ideaStaleDays    = an unclaimed 'new' idea older than this is auto-archived ('auto-stale').
    #   dedupDroppedDays = window for refusing to re-propose ideas the curator recently rejected.
    maxOpenIdeas             = 12
    ideaStaleDays            = 14
    dedupDroppedDays         = 30
    # Backlog packer: when many ideas arrive quickly, group them into workpacks
    # before autonomy starts draining them one-by-one. The packer only annotates
    # existing backlog items; execution remains controlled by the normal backlog path.
    backlogPackEnabled       = $true
    backlogPackBurstCount    = 5
    backlogPackWindowMinutes = 60
    backlogPackUnpackedOpenCount = 8
    backlogPackAuditBurstCount = 3
    backlogPackAuditWindowMinutes = 30
    backlogPackCooldownMinutes = 30
    backlogPackMinItems      = 2
  }
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'autonomy') {
      $a = $cfg.autonomy
      foreach ($k in @($out.Keys)) { if (($a.PSObject.Properties.Name -contains $k) -and $null -ne $a.$k) { $out[$k] = $a.$k } }
    }
  } catch {}
  try {
    $s = Get-Settings
    foreach ($k in @($out.Keys)) { if (($s.PSObject.Properties.Name -contains $k) -and $null -ne $s.$k) { $out[$k] = $s.$k } }
  } catch {}
  return $out
}

function Set-AutonomySetting {
  # Merge updates into settings.json (gitignored). $Updates is a hashtable.
  param([hashtable]$Updates)
  $h = @{}
  $s = Get-Settings
  if ($s) { foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  foreach ($k in $Updates.Keys) { $h[$k] = $Updates[$k] }
  Save-Settings ([pscustomobject]$h)
  return $true
}

function Get-AdvancedSettings {
  # Returns ALL user-editable advanced settings as flat dotted-path map.
  # Resolved order: hardcoded defaults <- config.json <- settings.json (live overlay
  # already applied by Get-BridgeConfig). 2026-05-27v5: extended settings UI in /memory.
  $defaults = [ordered]@{
    'parallel.maxStreams'            = 6
    'chunking.maxChunksPerTask'      = 10
    'criticMaxRetries'               = 2
    'auditor.intervalMin'            = 15
    'auditor.cooldownMin'            = 30
    'auditor.doctorRecidivismHours'  = 24
    'auditor.doctorRecidivismMax'    = 5
    'canary.enabled'                 = $false
    'canary.intervalHours'           = 6
    'canary.cooldownMinutes'         = 30
    'fastLane.autoDetect'            = $false
    'fastLane.minChars'              = 100
    'memory.recallTopK'              = 5
    'memory.recallMinScore'          = 0.62
    'memory.dedupThreshold'          = 0.93
    'memory.ageDaysPrune'            = 30
    'librarian.deltaTriggerCount'    = 10
    'librarian.ceilingHours'         = 6
    'reflect.minTaskDurationSec'     = 60
    'backlogPack.enabled'            = $true
    'backlogPack.burstCount'         = 5
    'backlogPack.windowMinutes'      = 60
    'backlogPack.unpackedOpenCount'  = 8
    'backlogPack.auditBurstCount'    = 3
    'backlogPack.auditWindowMinutes' = 30
    'backlogPack.cooldownMinutes'    = 30
    'backlogPack.minItems'           = 2
  }
  try {
    $cfg = Get-BridgeConfig
    foreach ($k in @($defaults.Keys)) {
      $parts = $k -split '\.', 2
      $section = $parts[0]; $field = if ($parts.Count -gt 1) { $parts[1] } else { $null }
      if (-not $field) {
        if ($cfg.PSObject.Properties.Name -contains $section -and $null -ne $cfg.$section) { $defaults[$k] = $cfg.$section }
      } else {
        if ($cfg.PSObject.Properties.Name -contains $section -and $cfg.$section -and ($cfg.$section).PSObject.Properties.Name -contains $field -and $null -ne $cfg.$section.$field) {
          $defaults[$k] = $cfg.$section.$field
        }
      }
    }
  } catch {}
  return $defaults
}

function Test-AdvancedSettingValue {
  # 2026-05-27v6: range-check a single setting value. Returns @{ ok=$true; value=$coerced }
  # or @{ ok=$false; reason='...' }. Used by Set-AdvancedSetting AND startup validator
  # to catch bad values (audit P3 finding -- silent default fallback was hiding bugs).
  param([string]$Key, $Value)
  $ranges = @{
    'parallel.maxStreams'           = @{ type='int';   min=1;   max=12  }
    'chunking.maxChunksPerTask'     = @{ type='int';   min=1;   max=50  }
    'criticMaxRetries'              = @{ type='int';   min=0;   max=5   }
    'auditor.intervalMin'           = @{ type='int';   min=1;   max=1440 }
    'auditor.cooldownMin'           = @{ type='int';   min=1;   max=1440 }
    'auditor.doctorRecidivismHours' = @{ type='int';   min=1;   max=720  }
    'auditor.doctorRecidivismMax'   = @{ type='int';   min=1;   max=100  }
    'canary.enabled'                = @{ type='bool'                    }
    'canary.intervalHours'          = @{ type='int';   min=1;   max=168  }
    'canary.cooldownMinutes'        = @{ type='int';   min=1;   max=1440 }
    'fastLane.autoDetect'           = @{ type='bool'                    }
    'fastLane.minChars'             = @{ type='int';   min=0;   max=10000 }
    'memory.recallTopK'             = @{ type='int';   min=1;   max=30   }
    'memory.recallMinScore'         = @{ type='float'; min=0.0; max=1.0  }
    'memory.dedupThreshold'         = @{ type='float'; min=0.0; max=1.0  }
    'memory.ageDaysPrune'           = @{ type='int';   min=1;   max=3650 }
    'librarian.deltaTriggerCount'   = @{ type='int';   min=1;   max=1000 }
    'librarian.ceilingHours'        = @{ type='int';   min=1;   max=720  }
    'reflect.minTaskDurationSec'    = @{ type='int';   min=0;   max=86400 }
    'backlogPack.enabled'           = @{ type='bool'                    }
    'backlogPack.burstCount'        = @{ type='int';   min=2;   max=1000 }
    'backlogPack.windowMinutes'     = @{ type='int';   min=1;   max=1440 }
    'backlogPack.unpackedOpenCount' = @{ type='int';   min=2;   max=1000 }
    'backlogPack.auditBurstCount'   = @{ type='int';   min=2;   max=1000 }
    'backlogPack.auditWindowMinutes'= @{ type='int';   min=1;   max=1440 }
    'backlogPack.cooldownMinutes'   = @{ type='int';   min=1;   max=1440 }
    'backlogPack.minItems'          = @{ type='int';   min=1;   max=50   }
  }
  if (-not $ranges.ContainsKey($Key)) { return @{ ok=$false; reason="unknown key" } }
  $r = $ranges[$Key]
  if ($r.type -eq 'bool') {
    try {
      if ($Value -is [bool]) { return @{ ok=$true; value=$Value } }
      $s = ([string]$Value).Trim().ToLowerInvariant()
      if (@('true','1','yes','on','enabled') -contains $s) { return @{ ok=$true; value=$true } }
      if (@('false','0','no','off','disabled','') -contains $s) { return @{ ok=$true; value=$false } }
      return @{ ok=$false; reason="not a bool ($Value)" }
    } catch { return @{ ok=$false; reason="cast bool failed" } }
  }
  $v = 0.0
  if (-not [double]::TryParse([string]$Value, [ref]$v)) { return @{ ok=$false; reason="not a number ($Value)" } }
  if ($v -lt $r.min) { return @{ ok=$false; reason="below min ($($r.min))" } }
  if ($v -gt $r.max) { return @{ ok=$false; reason="above max ($($r.max))" } }
  if ($r.type -eq 'int') { return @{ ok=$true; value=[int][Math]::Round($v) } }
  return @{ ok=$true; value=$v }
}

function Set-AdvancedSetting {
  # Writes flat dotted-path keys to settings.json. Whitelisted by key allowlist
  # AND range-validated via Test-AdvancedSettingValue. Returns @{ ok; rejected=@(...) }.
  # 2026-05-27v6: added range validation -- audit P3 finding (bad config values
  # were silently accepted and falling back to defaults, hiding bugs).
  param([hashtable]$Updates)
  $allow = @(
    'parallel.maxStreams',
    'chunking.maxChunksPerTask',
    'criticMaxRetries',
    'auditor.intervalMin','auditor.cooldownMin','auditor.doctorRecidivismHours','auditor.doctorRecidivismMax',
    'canary.enabled','canary.intervalHours','canary.cooldownMinutes',
    'fastLane.autoDetect','fastLane.minChars',
    'memory.recallTopK','memory.recallMinScore','memory.dedupThreshold','memory.ageDaysPrune',
    'librarian.deltaTriggerCount','librarian.ceilingHours',
    'reflect.minTaskDurationSec',
    'backlogPack.enabled','backlogPack.burstCount','backlogPack.windowMinutes',
    'backlogPack.unpackedOpenCount','backlogPack.auditBurstCount','backlogPack.auditWindowMinutes',
    'backlogPack.cooldownMinutes','backlogPack.minItems'
  )
  $h = @{}
  $s = Get-Settings
  if ($s) { foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value } }
  $rejected = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in $Updates.Keys) {
    if ($allow -notcontains $k) {
      [void]$rejected.Add(@{ key = $k; reason = 'not in allowlist' })
      continue
    }
    $check = Test-AdvancedSettingValue -Key $k -Value $Updates[$k]
    if ($check.ok) {
      $h[$k] = $check.value
    } else {
      [void]$rejected.Add(@{ key = $k; reason = $check.reason; value = $Updates[$k] })
    }
  }
  Save-Settings ([pscustomobject]$h)
  return @{ ok = $true; rejected = @($rejected.ToArray()) }
}

function Get-ExternalProjects {
  # Project folders (containing .git) under workRoot, excluding the bridge itself, so the
  # user can see what the bridge considers an "external project". Depth-limited; skips
  # heavy/system dirs so the scan stays fast.
  $cfg = Get-BridgeConfig
  $workRoot = [string]$cfg.workRoot
  if ([string]::IsNullOrWhiteSpace($workRoot) -or -not (Test-Path $workRoot)) { return @() }
  $bridge = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\')
  $skipTop = @('AppData','Application Data','Local Settings','Cookies','NetHood','PrintHood','Recent','SendTo','Start Menu','Templates','MicrosoftEdgeBackups','Searches','Saved Games','Contacts','Links','Favorites')
  $found = New-Object System.Collections.Generic.List[string]
  try {
    $tops = Get-ChildItem -LiteralPath $workRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $skipTop -notcontains $_.Name -and -not $_.Name.StartsWith('.') }
    foreach ($t in $tops) {
      try {
        $gits = Get-ChildItem -LiteralPath $t.FullName -Directory -Recurse -Depth 3 -Filter '.git' -Force -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\(AppData|node_modules|Packages|\.vs|\.cache|venv|\.venv|dist|build)\\' }
        foreach ($g in $gits) {
          $proj = [System.IO.Path]::GetFullPath($g.Parent.FullName).TrimEnd('\')
          # exclude the bridge itself and anything inside it (e.g. sandbox)
          if ($proj -and -not $proj.StartsWith($bridge, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$found.Add($proj) }
        }
      } catch {}
    }
    # also check workRoot top-level repos themselves
    if (Test-Path (Join-Path $workRoot '.git')) { $w=[System.IO.Path]::GetFullPath($workRoot).TrimEnd('\'); if ($w -ne $bridge) { [void]$found.Add($w) } }
  } catch {}
  return @($found | Select-Object -Unique | Sort-Object)
}
