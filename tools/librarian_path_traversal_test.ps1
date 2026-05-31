$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $bridgeRoot 'lib\common.ps1')

$script:BridgeRootFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $bridgeRoot -ErrorAction Stop).ProviderPath).TrimEnd('\','/')

function Test-InBridgeRoot {
  param([string]$Path)
  $target = [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
  if ($target.Equals($script:BridgeRootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  $prefix = $script:BridgeRootFull + [System.IO.Path]::DirectorySeparatorChar
  return $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-Check {
  param([System.Collections.ArrayList]$Results, [string]$Name, [bool]$Ok, [string]$Detail = '')
  [void]$Results.Add([pscustomobject]@{
    status = $(if ($Ok) { 'PASS' } else { 'FAIL' })
    name = $Name
    detail = $Detail
  })
}

function Add-ThrowCheck {
  param([System.Collections.ArrayList]$Results, [string]$Name, [scriptblock]$Block)
  try {
    $value = & $Block
    Add-Check $Results $Name $false ("returned=" + [string]$value)
  } catch {
    Add-Check $Results $Name $true $_.Exception.Message
  }
}

$results = [System.Collections.ArrayList]::new()

try {
  $decisionsPath = Get-DecisionsPath
  Add-Check $results 'Get-DecisionsPath stays under bridge root' (Test-InBridgeRoot $decisionsPath) $decisionsPath
} catch {
  Add-Check $results 'Get-DecisionsPath stays under bridge root' $false $_.Exception.Message
}

try {
  $memoryDir = Get-MemoryDir
  Add-Check $results 'Get-MemoryDir stays under bridge root' (Test-InBridgeRoot $memoryDir) $memoryDir
} catch {
  Add-Check $results 'Get-MemoryDir stays under bridge root' $false $_.Exception.Message
}

try {
  $memoryLogPath = Get-MemoryLogPath
  Add-Check $results 'Get-MemoryLogPath stays under bridge root' (Test-InBridgeRoot $memoryLogPath) $memoryLogPath
} catch {
  Add-Check $results 'Get-MemoryLogPath stays under bridge root' $false $_.Exception.Message
}

$script:OutsideMemoryRoot = Join-Path $bridgeRoot '..\outside-memory'
function Get-EffectiveScope {
  param([string]$Slug = $null)
  [pscustomobject]@{
    slug = 'main'
    is_bridge = $true
    bridge_root = $script:BridgeRootFull
    memory_root = $script:OutsideMemoryRoot
    memory_store = (Join-Path $script:OutsideMemoryRoot 'memory.jsonl')
    bridge_memory_root = (Join-Path $script:BridgeRootFull 'memory')
    bridge_memory_store = (Join-Path $script:BridgeRootFull 'memory\memory.jsonl')
  }
}

Add-ThrowCheck $results 'relative outside memory_root is rejected by Get-MemoryDir' { Get-MemoryDir }
Add-ThrowCheck $results 'relative outside memory_root is rejected by Get-MemoryLogPath' { Get-MemoryLogPath }

$script:OutsideMemoryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-memory-outside-' + [guid]::NewGuid().ToString('N'))
Add-ThrowCheck $results 'absolute outside memory_root is rejected by Get-MemoryDir' { Get-MemoryDir }
Add-ThrowCheck $results 'absolute outside memory_root is rejected by Get-MemoryLogPath' { Get-MemoryLogPath }

$failed = @($results | Where-Object { $_.status -ne 'PASS' })
$out = [pscustomobject]@{
  testPassed = ($failed.Count -eq 0)
  results = @($results)
}
$out | ConvertTo-Json -Depth 6
if ($failed.Count -gt 0) { exit 1 }
