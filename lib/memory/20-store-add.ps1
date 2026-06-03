# ---- vector math ----
function Get-CosineSimilarity {
  param($A, $B)
  if (-not $A -or -not $B) { return 0.0 }
  $n = [Math]::Min($A.Count, $B.Count)
  if ($n -eq 0) { return 0.0 }
  $dot = 0.0; $na = 0.0; $nb = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $x = [double]$A[$i]; $y = [double]$B[$i]
    $dot += $x * $y; $na += $x * $x; $nb += $y * $y
  }
  if ($na -le 0 -or $nb -le 0) { return 0.0 }
  return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}

# ---- store ----
function Get-CurrentMemoryChannel {
  # Channel slug to stamp on new memories. Driver-pinned/effective channel wins over
  # the UI's active channel so an in-flight task stays channel-local if the UI switches.
  $effectiveCmd = Get-Command -Name 'Get-EffectiveChannel' -ErrorAction SilentlyContinue
  if ($null -ne $effectiveCmd) {
    try { $s = [string](Get-EffectiveChannel); if (-not [string]::IsNullOrWhiteSpace($s)) { return $s } } catch {}
  }
  $activeCmd = Get-Command -Name 'Get-ActiveChannel' -ErrorAction SilentlyContinue
  if ($null -ne $activeCmd) {
    try { $s = [string](Get-ActiveChannel); if (-not [string]::IsNullOrWhiteSpace($s)) { return $s } } catch {}
  }
  return 'main'
}

function Assert-MemoryWriteAllowed {
  param([string]$TargetSlug)
  if ([string]::IsNullOrWhiteSpace($TargetSlug)) { $TargetSlug = Get-CurrentMemoryChannel }
  $current = Get-CurrentMemoryChannel
  if ($TargetSlug -eq 'main' -and $current -ne 'main') {
    throw 'Bridge memory is read-only from project channels'
  }
}

function Add-Memory {
  # Embed $Text and append a memory record. Returns the new id, or $null.
  # -Channel: explicit channel slug; default = current active channel.
  # -Shared:  if $true, memory is recallable inside the current channel store.
  param(
    [string]$Text,
    [string[]]$Tags = @(),
    [string]$Source = 'task',
    [double]$Importance = 0.5,
    [string]$Channel = $null,
    [bool]$Shared = $false,
    [string]$Kind = 'memory_note',
    [string]$Trust = 'legacy',
    [string]$Status = 'active',
    $Evidence = $null,
    $Meta = $null,
    [int]$SchemaVersion = 1
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  Assert-MemoryWriteAllowed -TargetSlug $Channel
  $vec = Get-Embedding -Text $Text -TaskType 'RETRIEVAL_DOCUMENT'
  $indexed = $true
  if (-not $vec) {
    # Durable-first memory: lack of an embedding key/API outage must not make
    # the bridge forget facts. Store the record without a vector and let a
    # later reindex/librarian pass attach embeddings.
    $vec = @()
    $indexed = $false
  }
  $dir = Get-MemoryDir -Slug $Channel
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $rec = [ordered]@{
    id         = [guid]::NewGuid().ToString('N')
    ts         = (Get-Date).ToUniversalTime().ToString('o')
    source     = $Source
    tags       = @($Tags)
    importance = [double]$Importance
    pinned     = $false
    channel    = [string]$Channel
    shared     = [bool]$Shared
    schema_version = [int]$SchemaVersion
    kind       = [string]$Kind
    trust      = [string]$Trust
    status     = [string]$Status
    indexed    = [bool]$indexed
    embedding_status = ($(if ($indexed) { 'indexed' } else { 'pending' }))
    text       = [string]$Text
    vec        = @($vec)
  }
  if ($null -ne $Evidence) { $rec.evidence = $Evidence }
  if ($null -ne $Meta) { $rec.meta = $Meta }
  $line = ($rec | ConvertTo-Json -Compress -Depth 10)
  $storePath = Get-MemoryStorePath -Slug $Channel
  Use-BridgeLock ({ Add-MemoryJsonlContent -Path $storePath -Content ($line + "`n") }.GetNewClosure())
  return $rec.id
}

function Get-MemoryKind {
  param($Mem)
  try {
    if ($Mem -and $Mem.PSObject.Properties['kind'] -and -not [string]::IsNullOrWhiteSpace([string]$Mem.kind)) {
      return [string]$Mem.kind
    }
  } catch {}
  return 'memory_note'
}

function Get-MemoryTrust {
  param($Mem)
  try {
    if ($Mem -and $Mem.PSObject.Properties['trust'] -and -not [string]::IsNullOrWhiteSpace([string]$Mem.trust)) {
      return [string]$Mem.trust
    }
  } catch {}
  return 'legacy'
}

function Get-MemoryStatus {
  param($Mem)
  try {
    if ($Mem -and $Mem.PSObject.Properties['status'] -and -not [string]::IsNullOrWhiteSpace([string]$Mem.status)) {
      return [string]$Mem.status
    }
  } catch {}
  return 'active'
}

function Add-ProjectMemory {
  # Typed project memory on top of the existing vector store. This is append-only
  # and backwards-compatible: old memory records simply read as kind=memory_note.
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [ValidateSet('project_fact','project_decision','project_risk','project_test','project_invariant','project_worklog','project_open_question','memory_note')]
    [string]$Kind = 'project_fact',
    [ValidateSet('legacy','inferred','observed','verified','operator_confirmed','stale','rejected')]
    [string]$Trust = 'observed',
    [ValidateSet('active','stale','rejected','archived')]
    [string]$Status = 'active',
    [string[]]$Tags = @(),
    [string]$Source = 'project',
    [double]$Importance = 0.65,
    [string]$Channel = $null,
    [bool]$Shared = $false,
    $Evidence = $null,
    $Meta = $null
  )
  $allTags = @('project-memory', $Kind) + @($Tags)
  return (Add-Memory -Text $Text -Tags $allTags -Source $Source -Importance $Importance -Channel $Channel -Shared:$Shared -Kind $Kind -Trust $Trust -Status $Status -Evidence $Evidence -Meta $Meta -SchemaVersion 2)
}

function Add-ProjectMemoryBatch {
  # Scalable path for onboarding large projects: one embedding batch and one
  # append under the bridge lock. Records: @{ text; kind; trust; status; tags;
  # evidence; meta; importance; source; shared }.
  param([object[]]$Records, [string]$Channel = $null)
  if (-not $Records -or @($Records).Count -eq 0) { return @() }
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return @() }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  Assert-MemoryWriteAllowed -TargetSlug $Channel
  $dir = Get-MemoryDir -Slug $Channel
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  $clean = New-Object 'System.Collections.Generic.List[object]'
  foreach ($r in @($Records)) {
    $txt = ''
    try { $txt = [string]$r.text } catch {}
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    [void]$clean.Add($r)
  }
  if ($clean.Count -eq 0) { return @() }

  $texts = @($clean.ToArray() | ForEach-Object { [string]$_.text })
  $vecList = New-Object 'System.Collections.Generic.List[object]'
  try {
    foreach ($v in (Get-EmbeddingBatch -Texts $texts -TaskType 'RETRIEVAL_DOCUMENT')) {
      [void]$vecList.Add($v)
    }
  } catch {}
  if ($vecList.Count -ne $texts.Count) {
    $vecList.Clear()
    foreach ($txt in $texts) { [void]$vecList.Add((Get-Embedding -Text $txt -TaskType 'RETRIEVAL_DOCUMENT')) }
  }

  $ids = New-Object 'System.Collections.Generic.List[string]'
  $lines = New-Object 'System.Collections.Generic.List[string]'
  for ($i = 0; $i -lt $clean.Count; $i++) {
    $r = $clean[$i]
    $vec = $vecList[$i]
    $indexed = $true
    if (-not $vec) {
      $vec = @()
      $indexed = $false
    }
    $kind = 'project_fact'; try { if (-not [string]::IsNullOrWhiteSpace([string]$r.kind)) { $kind = [string]$r.kind } } catch {}
    $trust = 'observed'; try { if (-not [string]::IsNullOrWhiteSpace([string]$r.trust)) { $trust = [string]$r.trust } } catch {}
    $status = 'active'; try { if (-not [string]::IsNullOrWhiteSpace([string]$r.status)) { $status = [string]$r.status } } catch {}
    $source = 'project:batch'; try { if (-not [string]::IsNullOrWhiteSpace([string]$r.source)) { $source = [string]$r.source } } catch {}
    $importance = 0.65; try { if ($null -ne $r.importance) { $importance = [double]$r.importance } } catch {}
    $shared = $false; try { if ($null -ne $r.shared) { $shared = [bool]$r.shared } } catch {}
    $tags = @('project-memory', $kind)
    try { if ($r.tags) { $tags += @($r.tags | ForEach-Object { [string]$_ }) } } catch {}
    $id = [guid]::NewGuid().ToString('N')
    $rec = [ordered]@{
      id             = $id
      ts             = (Get-Date).ToUniversalTime().ToString('o')
      source         = $source
      tags           = @($tags)
      importance     = [double]$importance
      pinned         = $false
      channel        = [string]$Channel
      shared         = [bool]$shared
      schema_version = 2
      kind           = [string]$kind
      trust          = [string]$trust
      status         = [string]$status
      indexed        = [bool]$indexed
      embedding_status = ($(if ($indexed) { 'indexed' } else { 'pending' }))
      text           = [string]$r.text
      vec            = @($vec)
    }
    try { if ($null -ne $r.evidence) { $rec.evidence = $r.evidence } } catch {}
    try { if ($null -ne $r.meta) { $rec.meta = $r.meta } } catch {}
    [void]$ids.Add($id)
    [void]$lines.Add(($rec | ConvertTo-Json -Compress -Depth 10))
  }

  if ($lines.Count -gt 0) {
    $storePath = Get-MemoryStorePath -Slug $Channel
    $payload = ($lines.ToArray() -join "`n") + "`n"
    Use-BridgeLock ({ Add-MemoryJsonlContent -Path $storePath -Content $payload }.GetNewClosure())
  }
  return @($ids.ToArray())
}
