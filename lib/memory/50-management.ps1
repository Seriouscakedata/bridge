# ---- management (used by the web UI) ----
function Save-AllMemories {
  param($Mems, [string]$Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  Assert-MemoryWriteAllowed -TargetSlug $Channel
  $dir = Get-MemoryDir -Slug $Channel
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $storePath = Get-MemoryStorePath -Slug $Channel
  $lines = @($Mems | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Use-BridgeLock ({ Write-AtomicFile -Path $storePath -Content $content }.GetNewClosure())
}

function Purge-MemoryForChannel {
  # Remove only non-shared memories from a channel store; shared-in-scope knowledge survives.
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return 0 }
  try {
    $mems = @(Get-AllMemories -Channel $Slug)
    if ($mems.Count -eq 0) { return 0 }
    $kept = @($mems | Where-Object {
      $isShared = Test-MemoryShared $_
      $ch = Get-MemoryChannel $_
      -not (($ch -eq $Slug) -and (-not $isShared))
    })
    $removed = $mems.Count - $kept.Count
    if ($removed -gt 0) { Save-AllMemories -Mems $kept -Channel $Slug }
    return $removed
  } catch {
    return 0
  }
}

function Get-MemoriesView {
  # All memories WITHOUT the heavy vec arrays, for the API/UI.
  # -Channel: '' or $null = active; '__all__' = all channels (admin view).
  param([string]$Channel = '__all__', [bool]$IncludeBridgeReadonly = $false)
  $storeSlug = if ($Channel -eq '__all__') { Get-CurrentMemoryChannel } else { $Channel }
  $scope = Get-MemoryScope -Slug $storeSlug
  $all = @(Get-AllMemories -Channel $storeSlug)
  if (-not [string]::IsNullOrWhiteSpace($Channel) -and $Channel -ne '__all__') {
    $all = @($all | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel $Channel })
  }
  if ($IncludeBridgeReadonly -and $Channel -ne '__all__' -and -not [bool]$scope.is_bridge) {
    $bridgeAll = @(Get-AllMemories -Channel 'main' | Where-Object { Test-MemoryVisibleInChannel -Mem $_ -Channel 'main' })
    foreach ($bm in $bridgeAll) {
      $bm | Add-Member -NotePropertyName readonly_source -NotePropertyValue 'bridge' -Force
    }
    if ($bridgeAll.Count -gt 0) { $all = @($all + $bridgeAll) }
  }
  $out = foreach ($m in $all) {
    $readonlySource = ''
    if ($m.PSObject.Properties['readonly_source']) { $readonlySource = [string]$m.readonly_source }
    $hasVector = ($m.PSObject.Properties['vec'] -and @($m.vec).Count -gt 0)
    $isIndexed = if ($m.PSObject.Properties['indexed']) { [bool]$m.indexed } else { [bool]$hasVector }
    $embeddingStatus = if ($m.PSObject.Properties['embedding_status']) { [string]$m.embedding_status } elseif ($hasVector) { 'indexed' } else { 'pending' }
    [pscustomobject]@{
      id         = [string]$m.id
      ts         = [string]$m.ts
      source     = [string]$m.source
      tags       = @($m.tags)
      importance = [double]$m.importance
      pinned     = [bool]($m.PSObject.Properties['pinned'] -and $m.pinned)
      channel    = (Get-MemoryChannel $m)
      shared     = (Test-MemoryShared $m)
      indexed    = [bool]$isIndexed
      embedding_status = [string]$embeddingStatus
      text       = [string]$m.text
      readonly   = ($readonlySource -eq 'bridge')
      readonly_source = $readonlySource
    }
  }
  return @($out)
}

function Remove-Memory {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $target = Get-CurrentMemoryChannel
  $mems = @(Get-AllMemories -Channel $target)
  $kept = @($mems | Where-Object { [string]$_.id -ne $Id })
  if ($kept.Count -eq $mems.Count) { return $false }
  Save-AllMemories -Mems $kept -Channel $target
  return $true
}

function Set-Memory {
  # Edit a memory in place. $Text re-embeds. Pass $null to leave a field unchanged.
  param([string]$Id, $Importance = $null, $Text = $null, $Pinned = $null, $Shared = $null, $Channel = $null)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $target = Get-CurrentMemoryChannel
  $mems = @(Get-AllMemories -Channel $target)
  $found = $false
  foreach ($m in $mems) {
    if ([string]$m.id -ne $Id) { continue }
    $found = $true
    if ($null -ne $Importance) {
      $imp = [double]$Importance; if ($imp -lt 0) { $imp = 0 }; if ($imp -gt 1) { $imp = 1 }
      $m | Add-Member -NotePropertyName importance -NotePropertyValue $imp -Force
    }
    if ($null -ne $Pinned) {
      $p = [bool]$Pinned
      $m | Add-Member -NotePropertyName pinned -NotePropertyValue $p -Force
      if ($p) { $m | Add-Member -NotePropertyName importance -NotePropertyValue 1.0 -Force }
    }
    if ($null -ne $Shared) {
      $m | Add-Member -NotePropertyName shared -NotePropertyValue ([bool]$Shared) -Force
    }
    if ($null -ne $Channel -and -not [string]::IsNullOrWhiteSpace([string]$Channel)) {
      $m | Add-Member -NotePropertyName channel -NotePropertyValue ([string]$Channel) -Force
    }
    if ($null -ne $Text -and -not [string]::IsNullOrWhiteSpace([string]$Text) -and ([string]$Text) -ne ([string]$m.text)) {
      $newVec = Get-Embedding -Text ([string]$Text) -TaskType 'RETRIEVAL_DOCUMENT'
      if (-not $newVec) { return $false }   # embedding failed -> don't half-update
      $m | Add-Member -NotePropertyName text -NotePropertyValue ([string]$Text) -Force
      $m | Add-Member -NotePropertyName vec  -NotePropertyValue (@($newVec)) -Force
    }
    break
  }
  if (-not $found) { return $false }
  Save-AllMemories -Mems $mems -Channel $target
  return $true
}

function Get-MemoryStats {
  param([string]$Channel = $null)
  $storeSlug = if ($Channel -eq '__all__') { Get-CurrentMemoryChannel } else { $Channel }
  $mems = @(Get-AllMemories -Channel $storeSlug)
  $last = $null
  $mp = Get-MemoryMarkerPath -Slug $storeSlug
  if (Test-Path $mp) { try { $last = (Get-Content $mp -Raw -Encoding UTF8).Trim() } catch {} }
  $bySource = [ordered]@{}
  foreach ($m in $mems) {
    $key = (([string]$m.source) -split ':')[0]
    if ([string]::IsNullOrWhiteSpace($key)) { $key = '?' }
    if ($bySource.Contains($key)) { $bySource[$key] = [int]$bySource[$key] + 1 } else { $bySource[$key] = 1 }
  }
  $pinned = @($mems | Where-Object { $_.PSObject.Properties['pinned'] -and $_.pinned }).Count
  return [pscustomobject]@{
    count         = $mems.Count
    pinned        = $pinned
    lastLibrarian = $last
    mapExists     = (Test-Path (Get-MemoryMapPath -Slug $storeSlug))
    bySource      = $bySource
  }
}
