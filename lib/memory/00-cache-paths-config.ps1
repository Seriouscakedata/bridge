function Get-EmbedCacheKey {
  param([string]$Text, [string]$TaskType)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$TaskType) + "`0" + ([string]$Text))
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

# ---- paths ----
function Resolve-MemoryContainedPath {
  param([Parameter(Mandatory=$true)][string]$Path, [string]$Purpose = 'memory path')
  if (-not (Get-Command Resolve-BridgeContainedPath -ErrorAction SilentlyContinue)) {
    throw "Resolve-MemoryContainedPath: Resolve-BridgeContainedPath is not loaded"
  }
  return (Resolve-BridgeContainedPath -Path $Path -Purpose $Purpose)
}

function Add-MemoryJsonlContent {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowEmptyString()][string]$Content
  )
  if ([string]::IsNullOrEmpty($Content)) { return }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
}

function Get-MemoryScope {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) {
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { return (Get-EffectiveScope) }
  } elseif ($Slug -ne '__all__') {
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { return (Get-EffectiveScope -Slug $Slug) }
  }
  $bridgeRoot = Get-BridgeRoot
  $memoryRoot = Join-Path $bridgeRoot 'memory'
  return [pscustomobject]@{
    slug                = 'main'
    is_bridge           = $true
    bridge_root         = $bridgeRoot
    memory_root         = $memoryRoot
    memory_store        = (Join-Path $memoryRoot 'memory.jsonl')
    bridge_memory_root  = $memoryRoot
    bridge_memory_store = (Join-Path $memoryRoot 'memory.jsonl')
  }
}
function Get-MemoryDir {
  param([string]$Slug = $null)
  Resolve-MemoryContainedPath -Path ([string]((Get-MemoryScope -Slug $Slug).memory_root)) -Purpose 'memory root'
}
function Get-MemoryStorePath {
  param([string]$Slug = $null)
  Resolve-MemoryContainedPath -Path ([string]((Get-MemoryScope -Slug $Slug).memory_store)) -Purpose 'memory store'
}
function Get-MemoryMapPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'map.md' }
function Get-MemoryMapPathForChannel { param([string]$Slug) Join-Path (Get-MemoryDir -Slug $Slug) 'map.md' }
function Get-MemorySharedMapPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'map.shared.md' }
function Get-MemoryMapPathsForChannel {
  param([string]$Slug)
  return [pscustomobject]@{
    Channel = (Get-MemoryMapPathForChannel -Slug $Slug)
    Shared  = (Get-MemorySharedMapPath -Slug $Slug)
  }
}
function Get-MemoryLogPath { param([string]$Slug = $null) Resolve-MemoryContainedPath -Path (Join-Path (Get-MemoryDir -Slug $Slug) 'librarian.log') -Purpose 'librarian log' }
function Get-MemoryMarkerPath { param([string]$Slug = $null) Join-Path (Get-MemoryDir -Slug $Slug) 'librarian.last' }

# ---- secrets / config ----
function Get-Secret {
  param([string]$Name)
  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $envKey = 'BRIDGE_' + ($Name.ToUpper() -replace '[^A-Z0-9]', '_')
    $envVal = [System.Environment]::GetEnvironmentVariable($envKey)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
    $envVal = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
  }
  $p = if (Get-Command Get-SecretsPath -ErrorAction SilentlyContinue) { Get-SecretsPath } else { Join-Path (Get-BridgeRoot) 'secrets.json' }
  if (-not (Test-Path $p)) { return $null }
  try { $s = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  if ($s.PSObject.Properties.Name -contains $Name) { return [string]$s.$Name }
  return $null
}

function Get-MemoryConfig {
  $defaults = @{
    enabled        = $true
    embedModel     = 'gemini-embedding-001'
    embedDim       = 1536
    autoGate       = $true
    recallTopK     = 5
    recallMinScore = 0.62
    dedupThreshold = 0.93
    dedupCosine = 0.93
    ageDaysPrune = 30
    minImportanceKeep = 0.5
    unusedDaysPrune = 7
    maxInjectChars = 1200
    skillTopK = 2
    skillMinScore = 0.55
    skillMaxInjectChars = 600
    skillImportance = 0.8
    skillDedupThreshold = 0.96
    antiSkillTopK = 2
    antiSkillMinScore = 0.55
    antiSkillMaxInjectChars = 600
    codeTopK = 4
    codeMinScore = 0.5
    codeMaxInjectChars = 900
  }
  $m = $null
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'memory') { $m = $cfg.memory }
  } catch {}
  $out = @{}
  foreach ($k in $defaults.Keys) {
    if ($m -and ($m.PSObject.Properties.Name -contains $k) -and $null -ne $m.$k) { $out[$k] = $m.$k }
    else { $out[$k] = $defaults[$k] }
  }
  return $out
}
