#Requires -Version 5.1
[CmdletBinding()]
param([string]$BridgeRoot = '')

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
  $BridgeRoot = Split-Path -Parent $PSScriptRoot
}
$BridgeRoot = [System.IO.Path]::GetFullPath($BridgeRoot)

$checkerPath = Join-Path $BridgeRoot 'driver\86-loop-completion-checks.ps1'
$commonPath = Join-Path $BridgeRoot 'lib\common.ps1'
$script:Failures = New-Object System.Collections.ArrayList
$script:PassCount = 0

function Add-Pass {
  param([string]$Name)
  $script:PassCount++
  Write-Host ("PASS {0}" -f $Name)
}

function Add-Fail {
  param([string]$Name, [string]$Detail = '')
  $msg = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name -- $Detail" }
  [void]$script:Failures.Add($msg)
  Write-Host ("FAIL {0}" -f $msg)
}

function Assert-True {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) { Add-Pass $Name } else { Add-Fail $Name $Detail }
}

function Get-ResultValue {
  param(
    $Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) { return $Default }

  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in @($Object.Keys)) {
      if ([string]$key -ieq $Name) { return $Object[$key] }
    }
  }

  try {
    foreach ($prop in @($Object.PSObject.Properties)) {
      if ([string]$prop.Name -ieq $Name) { return $prop.Value }
    }
  } catch {}

  return $Default
}

function Test-TrueValue {
  param($Value)

  if ($Value -is [bool]) { return $Value }
  if ($null -eq $Value) { return $false }

  try { return [System.Convert]::ToBoolean($Value) } catch {}
  return $false
}

function Test-ContainsToken {
  param(
    $Value,
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($Token) -or $null -eq $Value) { return $false }

  if ($Value -is [string]) {
    return ($Value.IndexOf($Token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  }

  foreach ($item in @($Value)) {
    if ($null -eq $item) { continue }
    if (([string]$item).IndexOf($Token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      return $true
    }
  }

  return $false
}

function Get-TestStateHash {
  param([string]$Content)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }

  return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-TestDoneGateStateImportText {
  if (Test-Path -LiteralPath $commonPath) {
    . $commonPath
  }

  if (-not (Test-Path -LiteralPath $checkerPath)) {
    throw ("missing checker file: {0}" -f $checkerPath)
  }

  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($checkerPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count -gt 0) {
    throw ("failed to parse checker file: {0}" -f $checkerPath)
  }

  $defs = @{}
  foreach ($fn in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    if (-not $defs.ContainsKey($fn.Name)) {
      $defs[$fn.Name] = $fn
    }
  }

  if (-not $defs.ContainsKey('Test-DoneGateStateValid')) {
    throw 'could not extract Test-DoneGateStateValid'
  }

  $ordered = New-Object System.Collections.Generic.List[string]
  $visited = @{}
  $visiting = @{}

  function Add-DefinitionText {
    param([string]$Name)

    if ($visited.ContainsKey($Name)) { return }
    if ($visiting.ContainsKey($Name)) { return }
    if (-not $defs.ContainsKey($Name)) { return }

    $visiting[$Name] = $true
    $def = $defs[$Name]
    foreach ($cmdAst in @($def.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
      $cmdName = $cmdAst.GetCommandName()
      if (-not [string]::IsNullOrWhiteSpace($cmdName) -and $defs.ContainsKey($cmdName)) {
        Add-DefinitionText -Name $cmdName
      }
    }

    [void]$ordered.Add($def.Extent.Text)
    $visited[$Name] = $true
    [void]$visiting.Remove($Name)
  }

  Add-DefinitionText -Name 'Test-DoneGateStateValid'
  return (($ordered -join ([Environment]::NewLine + [Environment]::NewLine)) + [Environment]::NewLine)
}

function New-TestBridgeLayout {
  $root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'bridge-test-' + [guid]::NewGuid().ToString('N'))
  $channelRoot = Join-Path $root 'channels\main'
  New-Item -ItemType Directory -Path $channelRoot -Force | Out-Null
  return [pscustomobject]@{
    Root = $root
    ChannelRoot = $channelRoot
    StatePath = (Join-Path $channelRoot 'state.json')
  }
}

function Write-StateJson {
  param(
    [string]$Path,
    [object]$State
  )

  $json = $State | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $json
}

function Write-RawUtf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-StateSidecar {
  param(
    [string]$Path,
    [string]$Content,
    [string]$HashOverride = ''
  )

  $hash = if ([string]::IsNullOrWhiteSpace($HashOverride)) { Get-TestStateHash -Content $Content } else { $HashOverride }
  [System.IO.File]::WriteAllText(($Path + '.sha256'), $hash, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-TestDoneGateStateValid {
  param(
    [Parameter(Mandatory = $true)][string]$TempBridgeRoot,
    [Parameter(Mandatory = $true)][string]$ChannelRoot,
    [Parameter(Mandatory = $true)][string]$StatePath
  )

  $cmd = Get-Command Test-DoneGateStateValid -CommandType Function -ErrorAction Stop
  $argMap = @{
    BridgeRoot = $TempBridgeRoot
    Root = $TempBridgeRoot
    RepoRoot = $TempBridgeRoot
    Channel = 'main'
    ChannelName = 'main'
    ChannelRoot = $ChannelRoot
    StatePath = $StatePath
    StateJsonPath = $StatePath
    Path = $StatePath
    FilePath = $StatePath
    JsonPath = $StatePath
  }
  $invokeArgs = @{}

  foreach ($paramName in @($cmd.Parameters.Keys)) {
    if ($argMap.ContainsKey($paramName)) {
      $invokeArgs[$paramName] = $argMap[$paramName]
    }
  }

  Push-Location $TempBridgeRoot
  try {
    return & $cmd @invokeArgs
  } finally {
    Pop-Location
  }
}

function New-ValidState {
  param([string]$Status = 'idle')

  return [ordered]@{
    status = $Status
    current_backlog_id = 'task-123'
    current_task_id = 'task-123'
    heartbeat = '2026-06-20T00:00:00Z'
  }
}

function Invoke-Case {
  param(
    [string]$Name,
    [scriptblock]$Body
  )

  $layout = New-TestBridgeLayout
  try {
    & $Body $layout
  } catch {
    Add-Fail $Name $_.Exception.Message
  } finally {
    try { Remove-Item -LiteralPath $layout.Root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

try {
  $importText = Get-TestDoneGateStateImportText
  Invoke-Expression $importText

  Invoke-Case 'valid state.json with required fields returns Ok=true' {
    param($layout)
    [void](Write-StateJson -Path $layout.StatePath -State (New-ValidState -Status 'running'))
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    Assert-True 'valid state.json with required fields returns Ok=true' (Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'missing state.json returns missing reason' {
    param($layout)
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $reason = [string](Get-ResultValue -Object $result -Name 'Reason' '')
    Assert-True 'missing state.json returns missing reason' ((-not $ok) -and (Test-ContainsToken -Value $reason -Token 'missing')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'invalid JSON returns invalid JSON reason' {
    param($layout)
    Write-RawUtf8NoBom -Path $layout.StatePath -Content '{"status": }'
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $reason = [string](Get-ResultValue -Object $result -Name 'Reason' '')
    Assert-True 'invalid JSON returns invalid JSON reason' ((-not $ok) -and (Test-ContainsToken -Value $reason -Token 'invalid JSON')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'array state returns schema invalid reason' {
    param($layout)
    Write-RawUtf8NoBom -Path $layout.StatePath -Content '[{"status":"running","heartbeat":"2026-06-20T00:00:00Z","current_task_id":"task-123","current_backlog_id":"task-123"}]'
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $reason = [string](Get-ResultValue -Object $result -Name 'Reason' '')
    Assert-True 'array state returns schema invalid reason' ((-not $ok) -and (Test-ContainsToken -Value $reason -Token 'schema invalid')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'null state returns schema invalid reason' {
    param($layout)
    Write-RawUtf8NoBom -Path $layout.StatePath -Content 'null'
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $reason = [string](Get-ResultValue -Object $result -Name 'Reason' '')
    Assert-True 'null state returns schema invalid reason' ((-not $ok) -and (Test-ContainsToken -Value $reason -Token 'schema invalid')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'missing status reports MissingFields=status' {
    param($layout)
    [void](Write-StateJson -Path $layout.StatePath -State ([ordered]@{
      current_backlog_id = 'task-123'
      current_task_id = 'task-123'
      heartbeat = '2026-06-20T00:00:00Z'
    }))
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $missing = Get-ResultValue -Object $result -Name 'MissingFields'
    Assert-True 'missing status reports MissingFields=status' ((-not $ok) -and (Test-ContainsToken -Value $missing -Token 'status')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'missing current_backlog_id returns Ok=false' {
    param($layout)
    [void](Write-StateJson -Path $layout.StatePath -State ([ordered]@{
      status = 'running'
      heartbeat = '2026-06-20T00:00:00Z'
    }))
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    Assert-True 'missing current_backlog_id returns Ok=false' (-not (Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok'))) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'matching SHA256 sidecar returns Ok=true' {
    param($layout)
    $json = Write-StateJson -Path $layout.StatePath -State (New-ValidState -Status 'done')
    Write-StateSidecar -Path $layout.StatePath -Content $json
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    Assert-True 'matching SHA256 sidecar returns Ok=true' (Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'mismatched SHA256 sidecar returns Sha256Mismatch=true and Ok=false' {
    param($layout)
    $json = Write-StateJson -Path $layout.StatePath -State (New-ValidState -Status 'done')
    Write-StateSidecar -Path $layout.StatePath -Content $json -HashOverride ('0' * 64)
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    $ok = Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')
    $mismatch = Test-TrueValue (Get-ResultValue -Object $result -Name 'Sha256Mismatch')
    Assert-True 'mismatched SHA256 sidecar returns Sha256Mismatch=true and Ok=false' ((-not $ok) -and $mismatch) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }

  Invoke-Case 'missing SHA256 sidecar does not block valid state' {
    param($layout)
    [void](Write-StateJson -Path $layout.StatePath -State (New-ValidState -Status 'complete'))
    $result = Invoke-TestDoneGateStateValid -TempBridgeRoot $layout.Root -ChannelRoot $layout.ChannelRoot -StatePath $layout.StatePath
    Assert-True 'missing SHA256 sidecar does not block valid state' (Test-TrueValue (Get-ResultValue -Object $result -Name 'Ok')) ("result={0}" -f ($result | ConvertTo-Json -Depth 10 -Compress))
  }
} catch {
  Add-Fail 'test setup' $_.Exception.Message
}

if ($script:Failures.Count -gt 0) {
  Write-Host ("RESULT FAIL pass={0} fail={1}" -f $script:PassCount, $script:Failures.Count)
  exit 1
}

Write-Host ("RESULT PASS pass={0} fail=0" -f $script:PassCount)
exit 0
