#Requires -Version 5.1
# test-backlog-write-integrity.ps1 -- backlog append/compaction terminal integrity checks.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-write-integrity-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'main'
$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 8) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-EffectiveScope { return [pscustomobject]@{ is_bridge = $true; project_root = '' } }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Get-BacklogControlDir { return (Join-Path $script:TestBridgeRoot 'control') }
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    backlogPackEnabled = $false
    backlogPackBurstCount = 0
    backlogPackWindowMinutes = 60
    backlogPackUnpackedOpenCount = 999
    backlogPackAuditBurstCount = 0
    backlogPackAuditWindowMinutes = 60
    backlogPackCooldownMinutes = 60
    backlogPackMinItems = 999
    backlogPackDedupeEnabled = $false
  }
}

function Write-TestBacklogLines {
  param([object[]]$Items)
  $path = Get-ChannelBacklogPath -Slug 'main'
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

try {
  New-Item -ItemType Directory -Path (Get-ChannelDir -Slug 'main') -Force | Out-Null
  . (Join-Path $root 'lib\backlog.ps1')
  function Request-BacklogPackIfNeeded { param([string]$NewItemId) return $null }

  Write-TestBacklogLines -Items @(
    [pscustomobject][ordered]@{ id='done-a'; status='done'; text='terminal with evidence'; reason='operator: completed'; done_sha='abc123'; done_by='codex' },
    [pscustomobject][ordered]@{ id='done-a'; status='done'; text='newer compact survivor'; reason='' }
  )
  $folded = @(Get-Backlog | Where-Object { [string]$_.id -eq 'done-a' } | Select-Object -First 1)[0]
  Check 'compaction preserves terminal reason' ([string]$folded.reason -eq 'operator: completed') $folded
  Check 'compaction preserves done_sha' ([string]$folded.done_sha -eq 'abc123') $folded
  Check 'compaction preserves done_by' ([string]$folded.done_by -eq 'codex') $folded

  Write-TestBacklogLines -Items @(
    [pscustomobject][ordered]@{ id='reopen-a'; status='done'; text='terminal with evidence'; reason='operator: completed'; done_sha='abc123'; done_by='codex' },
    [pscustomobject][ordered]@{ id='reopen-a'; status='approved'; text='explicit reopen without terminal evidence' }
  )
  $reopened = @(Get-Backlog | Where-Object { [string]$_.id -eq 'reopen-a' } | Select-Object -First 1)[0]
  $reopenHasTerminalEvidence = (
    -not [string]::IsNullOrWhiteSpace([string]$reopened.reason) -or
    -not [string]::IsNullOrWhiteSpace([string]$reopened.done_sha) -or
    -not [string]::IsNullOrWhiteSpace([string]$reopened.done_by)
  )
  Check 'compaction does not attach terminal evidence to reopened item' (-not $reopenHasTerminalEvidence) $reopened

  Write-TestBacklogLines -Items @()
  $script:BacklogAddIdeaAfterAppendHook = {
    param([string]$Path, [string]$Id, [int]$Attempt)
    if ($Attempt -eq 0) {
      [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
    }
  }
  $newId = Add-Idea -Text 'verify-after-append catches simulated lost write' -From 'test' -Tags @('unit') -Status 'new' -SkipCurator
  $script:BacklogAddIdeaAfterAppendHook = $null
  $savedNew = @(Get-Backlog | Where-Object { [string]$_.id -eq [string]$newId })
  $logPath = Join-Path (Get-BacklogControlDir) 'curator-decisions.jsonl'
  $logRaw = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } else { '' }
  Check 'Add-Idea verify-after-append retries lost write' ($savedNew.Count -eq 1 -and $logRaw -match 'add-idea-append-verify-retry') @{ id=$newId; log=$logRaw }

  Write-TestBacklogLines -Items @()
  $script:BacklogAddIdeaAfterAppendHook = {
    param([string]$Path, [string]$Id, [int]$Attempt)
    [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
    'hook-noise'
  }
  $threwOnLostWrite = $false
  try {
    Add-Idea -Text 'verify-after-append fails when every write is lost' -From 'test' -Tags @('unit') -Status 'new' -SkipCurator | Out-Null
  } catch {
    $threwOnLostWrite = ([string]$_.Exception.Message -match 'append verification failed')
  }
  $script:BacklogAddIdeaAfterAppendHook = $null
  Check 'Add-Idea append verification ignores hook output and fails absent id' $threwOnLostWrite

  Write-TestBacklogLines -Items @(
    [pscustomobject][ordered]@{ id='terminal-a'; status='done'; text='already done'; reason='operator: complete'; done_sha='def456'; done_by='codex' }
  )
  $blocked = Set-Idea -Id 'terminal-a' -Status 'running'
  $afterBlocked = @(Get-Backlog | Where-Object { [string]$_.id -eq 'terminal-a' } | Select-Object -First 1)[0]
  Check 'done item is not silently downgraded by abandon path' ((-not [bool]$blocked) -and [string]$afterBlocked.status -eq 'done') $afterBlocked

  $explicit = Set-Idea -Id 'terminal-a' -Status 'approved' -Reason 'operator: explicit reopen'
  $afterExplicit = @(Get-Backlog | Where-Object { [string]$_.id -eq 'terminal-a' } | Select-Object -First 1)[0]
  Check 'explicit operator reason can reopen terminal item' ([bool]$explicit -and [string]$afterExplicit.status -eq 'approved' -and [string]$afterExplicit.reason -eq 'operator: explicit reopen') $afterExplicit
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
