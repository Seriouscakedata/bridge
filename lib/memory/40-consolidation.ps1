# ---- consolidation (librarian helpers) ----
function Invoke-MemoryDedup {
  # Drop near-duplicate memories inside the same channel/shared scope, keeping higher importance.
  # Returns number removed. Pure-local, no API cost.
  param([double]$Threshold = 0)
  $mc = Get-MemoryConfig
  if ($Threshold -le 0) {
    $dc = $null
    try { if ($mc.ContainsKey('dedupCosine')) { $dc = [double]$mc.dedupCosine } } catch {}
    if ($null -eq $dc) { $dc = [double]$mc.dedupThreshold }
    $Threshold = $dc
  }
  $mems = @(Get-AllMemories)
  if ($mems.Count -lt 2) { return 0 }
  $arr = foreach ($m in $mems) { [pscustomobject]@{ Mem = $m; Keep = $true } }
  $arr = @($arr)
  for ($i = 0; $i -lt $arr.Count; $i++) {
    if (-not $arr[$i].Keep) { continue }
    for ($j = $i + 1; $j -lt $arr.Count; $j++) {
      if (-not $arr[$j].Keep) { continue }
      $iScope = if (Test-MemoryShared $arr[$i].Mem) { '__shared__' } else { Get-MemoryChannel $arr[$i].Mem }
      $jScope = if (Test-MemoryShared $arr[$j].Mem) { '__shared__' } else { Get-MemoryChannel $arr[$j].Mem }
      if ($iScope -ne $jScope) { continue }
      $iSkill = @($arr[$i].Mem.tags) -contains 'skill'
      $jSkill = @($arr[$j].Mem.tags) -contains 'skill'
      if ($iSkill -ne $jSkill) { continue }
      $thr = if ($iSkill -and $jSkill) { [double]$mc.skillDedupThreshold } else { $Threshold }
      $sim = Get-CosineSimilarity -A $arr[$i].Mem.vec -B $arr[$j].Mem.vec
      if ($sim -ge $thr) {
        $ip = [bool]($arr[$i].Mem.PSObject.Properties['pinned'] -and $arr[$i].Mem.pinned)
        $jp = [bool]($arr[$j].Mem.PSObject.Properties['pinned'] -and $arr[$j].Mem.pinned)
        if ($ip -and -not $jp) { $arr[$j].Keep = $false; continue }   # never drop a pinned memory
        if ($jp -and -not $ip) { $arr[$i].Keep = $false; break }
        $ii = [double]$arr[$i].Mem.importance; $jj = [double]$arr[$j].Mem.importance
        if ($jj -gt $ii) { $arr[$i].Keep = $false; break } else { $arr[$j].Keep = $false }
      }
    }
  }
  $kept = @($arr | Where-Object { $_.Keep } | ForEach-Object { $_.Mem })
  $removed = $mems.Count - $kept.Count
  if ($removed -gt 0) { Save-AllMemories $kept }
  return $removed
}

function Invoke-MemoryAgePrune {
  # Drop old, low-importance, unused, non-pinned memories. Returns number removed.
  param([int]$AgeDays = 0, [double]$MinImportance = -1, [int]$UnusedDays = 0)
  $mc = Get-MemoryConfig
  if ($AgeDays -le 0) { $AgeDays = [int]$mc.ageDaysPrune }
  if ($MinImportance -lt 0) { $MinImportance = [double]$mc.minImportanceKeep }
  if ($UnusedDays -le 0) { $UnusedDays = [int]$mc.unusedDaysPrune }
  $mems = @(Get-AllMemories)
  if ($mems.Count -eq 0) { return 0 }
  $now = Get-Date
  $kept = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in $mems) {
    $pinned = [bool]($m.PSObject.Properties['pinned'] -and $m.pinned)
    if ($pinned) { [void]$kept.Add($m); continue }
    $imp = 0.5
    try { $imp = [double]$m.importance } catch {}
    if ($imp -ge $MinImportance) { [void]$kept.Add($m); continue }
    $ts = $null
    try {
      if ($m.PSObject.Properties['ts'] -and -not [string]::IsNullOrWhiteSpace([string]$m.ts)) {
        $ts = [datetime]::Parse([string]$m.ts)
      }
    } catch {}
    if ($null -eq $ts) { [void]$kept.Add($m); continue }
    if (($now - $ts).TotalDays -lt $AgeDays) { [void]$kept.Add($m); continue }
    $lastRecall = $null
    try {
      if ($m.PSObject.Properties['lastRecalledAt'] -and -not [string]::IsNullOrWhiteSpace([string]$m.lastRecalledAt)) {
        $lastRecall = [datetime]::Parse([string]$m.lastRecalledAt)
      }
    } catch {}
    if ($null -ne $lastRecall) {
      if (($now - $lastRecall).TotalDays -lt $UnusedDays) { [void]$kept.Add($m); continue }
    }
  }
  $removed = $mems.Count - $kept.Count
  if ($removed -gt 0) { Save-AllMemories @($kept.ToArray()) }
  return $removed
}
