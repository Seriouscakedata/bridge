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
    reflectEveryHours        = 6
    maxIdeasPerReflect       = 3
    stablePromoteMinutes     = 30
    scope                    = 'bridge'   # 'bridge' = only the bridge; 'projects' = bridge + its projects
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
