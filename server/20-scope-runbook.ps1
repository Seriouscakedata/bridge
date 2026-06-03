function Get-ActiveScopeDto {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ActiveChannel }
  try {
    $scope = Get-EffectiveScope -Slug $Slug
    return [pscustomobject]@{
      slug         = [string]$scope.slug
      is_bridge    = [bool]$scope.is_bridge
      project_root = [string]$scope.project_root
      bridge_root  = [string]$scope.bridge_root
    }
  } catch {
    return [pscustomobject]@{
      slug         = [string]$Slug
      is_bridge    = ([string]$Slug -eq 'main')
      project_root = if ([string]$Slug -eq 'main') { Get-BridgeRoot } else { '' }
      bridge_root  = Get-BridgeRoot
      error        = [string]$_.Exception.Message
    }
  }
}
function Get-AuditApiScope {
  param($ctx)
  $slug = Get-QueryParamUtf8 $ctx 'channel'
  if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq '__active__') {
    try { $slug = Get-EffectiveChannel } catch { $slug = 'main' }
  }
  try { if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $slug = Normalize-ChannelSlug $slug } } catch {}
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'main' }
  $dir = $null
  if ($slug -eq 'main') {
    $dir = Join-Path $root 'audit'
  } else {
    try {
      if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
        $dir = Join-Path (Get-ChannelDir -Slug $slug) 'audit'
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($dir)) {
      $dir = Join-Path (Join-Path (Join-Path $root 'channels') $slug) 'audit'
    }
  }
  [pscustomobject]@{
    channel = $slug
    kind    = if ($slug -eq 'main') { 'bridge' } else { 'project' }
    dir     = $dir
  }
}
function Quote-RunbookProcessArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { $Value = '' }
  $s = [string]$Value
  if ($s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $s.ToCharArray()) {
    if ($ch -eq [char]92) {
      $slashes++
      continue
    }
    if ($ch -eq [char]34) {
      if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
      [void]$sb.Append('\"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$sb.Append(('\' * $slashes))
      $slashes = 0
    }
    [void]$sb.Append($ch)
  }
  if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}
function Join-RunbookProcessArguments {
  param([string[]]$ArgsList)
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($arg in @($ArgsList)) {
    [void]$parts.Add((Quote-RunbookProcessArgument -Value $arg))
  }
  return [string]::Join(' ', $parts.ToArray())
}
function Invoke-RunbookProcess {
  param(
    [string]$FileName,
    [string[]]$ArgsList = @(),
    [string]$WorkingDirectory = '',
    [int]$TimeoutMs = 300000
  )
  $result = [ordered]@{
    fileName = $FileName
    exitCode = $null
    timedOut = $false
    stdout = ''
    stderr = ''
    error = ''
  }
  $proc = New-Object System.Diagnostics.Process
  try {
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = Get-BridgeRoot }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = Join-RunbookProcessArguments -ArgsList $ArgsList
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.EnvironmentVariables['BRIDGE_CHANNEL'] = [string](Get-EffectiveChannel) } catch {}
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
      $result.timedOut = $true
      Write-Warning ("Invoke-RunbookProcess: process '$FileName' timed out after " + $TimeoutMs + "ms")
      try { $proc.Kill() } catch {}
      try { $proc.WaitForExit(5000) | Out-Null } catch {}
    } else {
      $result.exitCode = $proc.ExitCode
    }
    try {
      if ($stdoutTask.Wait(1000)) { $result.stdout = [string]$stdoutTask.Result }
    } catch {}
    try {
      if ($stderrTask.Wait(1000)) { $result.stderr = [string]$stderrTask.Result }
    } catch {}
  } catch {
    $result.error = [string]$_.Exception.Message
  } finally {
    if ($null -ne $proc) { $proc.Dispose() }
  }
  return [pscustomobject]$result
}
function Convert-RunbookProcessResultToText {
  param($Result)
  if ($null -eq $Result) { return 'ERROR: process did not return a result' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.error)) {
    [void]$parts.Add("ERROR: $($Result.error)")
  } elseif ([bool]$Result.timedOut) {
    [void]$parts.Add('ERROR: timeout')
  } elseif ($null -ne $Result.exitCode -and [int]$Result.exitCode -ne 0) {
    [void]$parts.Add("ERROR: exit code $($Result.exitCode)")
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.stdout)) {
    [void]$parts.Add(([string]$Result.stdout).TrimEnd())
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.stderr)) {
    [void]$parts.Add("STDERR`r`n$(([string]$Result.stderr).TrimEnd())")
  }
  if ($parts.Count -eq 0) { return '' }
  return [string]::Join("`r`n", $parts.ToArray())
}
function Get-RunbookStateObject {
  $stateObj = $null
  try { $stateObj = Read-State } catch { $stateObj = $null }
  if ($null -ne $stateObj) { return $stateObj }

  $statePath = $null
  try { $statePath = Get-StatePath } catch { $statePath = $null }
  if ([string]::IsNullOrWhiteSpace([string]$statePath)) { return $null }
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    $raw = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}
function Get-RunbookPropertyValue {
  param($InputObject, [string]$Name)
  if ($null -eq $InputObject) { return $null }
  try {
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
  } catch {}
  return $null
}
function ConvertTo-RunbookSummaryValue {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) { return [string]$Value }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToString('o') }
  try {
    $json = [string]($Value | ConvertTo-Json -Compress -Depth 4)
    if ([string]::IsNullOrWhiteSpace($json)) { return [string]$Value }
    if ($json.Length -gt 2000) { return ($json.Substring(0, 2000) + '...<truncated>') }
    return $json
  } catch {
    return [string]$Value
  }
}
