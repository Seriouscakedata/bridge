# delivery-gate-facts.ps1 -- read-only facts collector for Delivery Gate shadow input.
#
# This module is intentionally isolated from the live driver. It reads task,
# channel, git status/diff, and event facts, then builds the strict input shape
# expected by Get-DeliveryGateResult. It does not write state, memory, backlog,
# runtime files, or git data.

$script:DeliveryGateFactsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:DeliveryGateFactsRoot 'lib\delivery-gate.ps1')
. (Join-Path $script:DeliveryGateFactsRoot 'lib\delivery-mode.ps1')

function Resolve-DeliveryGateBridgeRoot {
  param([string]$BridgeRoot)
  if (-not [string]::IsNullOrWhiteSpace($BridgeRoot)) { return $BridgeRoot }
  return $script:DeliveryGateFactsRoot
}

function Invoke-DeliveryGateGitRead {
  param(
    [Parameter(Mandatory)][string]$BridgeRoot,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $safeRoot = $BridgeRoot -replace '\\','/'
  try {
    $output = & git -c "safe.directory=$safeRoot" -C $BridgeRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return [string[]]@() }
    return [string[]]@($output)
  } catch {
    return [string[]]@()
  }
}

function ConvertTo-DeliveryGateRelativePath {
  param(
    [string]$BridgeRoot,
    [string]$Path
  )

  $p = Normalize-DeliveryPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return '' }

  if (-not [string]::IsNullOrWhiteSpace($BridgeRoot)) {
    $root = (Normalize-DeliveryPath -Path $BridgeRoot).TrimEnd('/')
    if (-not [string]::IsNullOrWhiteSpace($root) -and $p.StartsWith($root + '/')) {
      $p = $p.Substring($root.Length + 1)
    }
  }

  return $p
}

function Get-DeliveryGateEventValue {
  param($Event, [string[]]$Names)
  if ($null -eq $Event) { return $null }
  foreach ($name in @($Names)) {
    if ($Event -is [System.Collections.IDictionary] -and $Event.Contains($name)) {
      return $Event[$name]
    }
    $prop = $Event.PSObject.Properties[$name]
    if ($null -ne $prop) { return $prop.Value }
  }
  return $null
}

function Add-DeliveryGatePathValue {
  param(
    [Parameter(Mandatory)]$List,
    [string]$BridgeRoot,
    $Value
  )

  if ($null -eq $Value) { return }

  if ($Value -is [string]) {
    $path = ConvertTo-DeliveryGateRelativePath -BridgeRoot $BridgeRoot -Path $Value
    if (-not [string]::IsNullOrWhiteSpace($path) -and -not $List.Contains($path)) {
      [void]$List.Add($path)
    }
    return
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      Add-DeliveryGatePathValue -List $List -BridgeRoot $BridgeRoot -Value $item
    }
  }
}

function Get-DeliveryGateEventTouchedFiles {
  param(
    [string]$BridgeRoot,
    $Events
  )

  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($event in @($Events)) {
    foreach ($value in @(
        (Get-DeliveryGateEventValue -Event $event -Names @('touched_files','TouchedFiles','files','Files','paths','Paths')),
        (Get-DeliveryGateEventValue -Event $event -Names @('path','Path','file','File'))
      )) {
      Add-DeliveryGatePathValue -List $files -BridgeRoot $BridgeRoot -Value $value
    }
  }
  return [string[]]@($files.ToArray())
}

function Get-DeliveryGateEventText {
  param($Events)

  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($event in @($Events)) {
    if ($null -eq $event) { continue }
    if ($event -is [string]) {
      if (-not [string]::IsNullOrWhiteSpace($event)) { [void]$parts.Add($event) }
      continue
    }
    foreach ($value in @(
        (Get-DeliveryGateEventValue -Event $event -Names @('text','Text','message','Message','content','Content','diff','Diff','diff_text','DiffText'))
      )) {
      if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
        [void]$parts.Add([string]$value)
      }
    }
  }
  return ($parts.ToArray() -join "`n")
}

function Test-DeliveryGateExampleLine {
  param([string]$Line)
  if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
  return ($Line -match '(?i)(patterns?\s+like|examples?\s*:|for example|например|e\.g\.)')
}

function Test-DeliveryGateQualityBypassText {
  param(
    [string]$Text = '',
    [string]$DiffText = ''
  )

  $combined = (@($Text, $DiffText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
  foreach ($line in ($combined -split "(`r`n|`n|`r)")) {
    if (Test-DeliveryGateExampleLine -Line $line) { continue }
    if ($line -match '(?i)\b(skip|skipping|skipped)\s+(all\s+)?(tests?|smoke|qa|verification|verify|checks?)\b') { return $true }
    if ($line -match '(?i)\b(do\s+not|don''t|without)\s+(run|running|do|doing)\s+(the\s+)?(tests?|smoke|qa|verification|checks?)\b') { return $true }
    if ($line -match '(?i)\b(disable|turn\s+off)\s+(the\s+)?(critic|qa|gate|verification|verify|smoke|tests?)\b') { return $true }
    if ($line -match '(?i)\bbypass\s+(the\s+)?(verify|verification|gate|qa|critic|checks?)\b') { return $true }
    if ($line -match '(?i)\bforce\s+done\b.*\b(without|no)\b.*\b(checks?|tests?|smoke|verify|verification)\b') { return $true }
  }

  return $false
}

function Test-DeliveryGateDestructivePatternsText {
  param(
    [string]$Text = '',
    [string]$DiffText = ''
  )

  $combined = (@($Text, $DiffText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
  $hasSafeMigration = ($combined -match '(?i)\b(safe migration|migration plan|migrate safely|миграц)')

  foreach ($line in ($combined -split "(`r`n|`n|`r)")) {
    if (Test-DeliveryGateExampleLine -Line $line) { continue }
    if ($line -match '(?i)\bgit\s+reset\s+--hard\b') { return $true }
    if ($line -match '(?i)\bRemove-Item\b.*\b-Recurse\b.*(\$BridgeRoot|\$root|C:\\|/|\.\.|\*|\.($|\s))') { return $true }
    if (-not $hasSafeMigration -and $line -match '(?i)\b(delete|deleting|remove|removing|rm|erase|purge|удали|удалить)\b.*\b(state|backlog|memory)\b') { return $true }
    if ($line -match '(?i)\b(disable|turn\s+off|remove|bypass)\b.*\b(watchdog|safety|verify|verification)\b') { return $true }
  }

  return $false
}

function Test-DeliveryGateForbiddenPath {
  param([string]$Path)

  $p = Normalize-DeliveryPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }

  if ($p -match '(^|/)\.git(/|$)') { return $true }
  if ($p -match '(^|/)\.bridge-runtime(/|$)') { return $true }
  if ($p -match '(^|/)node_modules(/|$)') { return $true }
  if ($p -match '(^|/)uploads?(/|$)') { return $true }
  if ($p -match '(^|/)(secrets?(\.|/)|.*secret.*\.(json|yaml|yml|toml|env)$|\.env($|\.))') { return $true }
  if ($p -match '(^|/)(runtime|state|memory|backlog).*\.(db|sqlite|sqlite3)$') { return $true }
  if ($p -match '(^|/).*\.(db|sqlite|sqlite3)$' -and $p -match '(runtime|state|memory|backlog)') { return $true }

  return $false
}

function Test-DeliveryGateBridgeSelfEvidence {
  param([string]$TaskText)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $false }
  return ($TaskText -match '(?i)(bridge-self|bridge self|main channel|bridge development|самого bridge|сам мост|мост)')
}

function Test-DeliveryGateAcceptanceEvidence {
  param([string]$TaskText)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $false }
  return ($TaskText -match '(?i)(acceptance|accepted|verified|parsefile|smoke|tests?\s+pass|checks?\s+pass|при[её]мк|провер)')
}

function Test-DeliveryGateProjectAcceptancePass {
  param($ProjectAcceptanceResult)

  if ($null -eq $ProjectAcceptanceResult) { return $false }

  $okProp = $ProjectAcceptanceResult.PSObject.Properties['ok']
  if ($null -ne $okProp -and [bool]$okProp.Value) { return $true }

  $statusProp = $ProjectAcceptanceResult.PSObject.Properties['status']
  if ($null -ne $statusProp -and ([string]$statusProp.Value).Trim().ToUpperInvariant() -eq 'PASS') { return $true }

  return $false
}

function Get-DeliveryGateAcceptanceFact {
  param(
    [string]$BridgeRoot = '',
    [string]$TaskText = '',
    [string]$Channel = '',
    [string]$BaseCommit = '',
    [string]$HeadCommit = '',
    $Events = @(),
    [bool]$ExplicitAcceptancePassed = $false,
    [bool]$CanaryPassed = $false,
    $ProjectAcceptanceResult = $null
  )

  $root = Resolve-DeliveryGateBridgeRoot -BridgeRoot $BridgeRoot
  $gitFiles = @(Get-DeliveryGateTouchedFiles -BridgeRoot $root -BaseCommit $BaseCommit -HeadCommit $HeadCommit)
  $eventFiles = @(Get-DeliveryGateEventTouchedFiles -BridgeRoot $root -Events $Events)
  $touched = New-Object 'System.Collections.Generic.List[string]'
  foreach ($file in @($gitFiles + $eventFiles)) {
    Add-DeliveryGatePathValue -List $touched -BridgeRoot $root -Value $file
  }

  $eventText = Get-DeliveryGateEventText -Events $Events
  $scanText = (@($TaskText, $eventText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"

  $unsafe = [bool](
    (Test-DeliveryGateForbiddenChanges -TouchedFiles @($touched.ToArray()) -TaskText $TaskText) -or
    (Test-DeliveryGateDestructivePatternsText -Text $scanText) -or
    (Test-DeliveryGateQualityBypassText -Text $scanText)
  )
  if ($unsafe) { return $false }

  if ([bool]$ExplicitAcceptancePassed -or [bool]$CanaryPassed) { return $true }

  $isExternalProject = -not [string]::IsNullOrWhiteSpace($Channel) -and $Channel -ne 'main'
  if ($isExternalProject -and (Test-DeliveryGateProjectAcceptancePass -ProjectAcceptanceResult $ProjectAcceptanceResult)) {
    return $true
  }

  $coveredNoChange = [bool](
    (Test-DeliveryGateRepoClean -BridgeRoot $root) -and
    (@($touched.ToArray()).Count -eq 0) -and
    ($eventText -match '(?i)\bCOVERED\b')
  )
  if ($coveredNoChange) { return $true }

  return $false
}

function Get-DeliveryGateTouchedFiles {
  param(
    [string]$BridgeRoot = '',
    [string]$BaseCommit = '',
    [string]$HeadCommit = ''
  )

  $root = Resolve-DeliveryGateBridgeRoot -BridgeRoot $BridgeRoot
  $files = New-Object 'System.Collections.Generic.List[string]'

  if (-not [string]::IsNullOrWhiteSpace($BaseCommit) -and -not [string]::IsNullOrWhiteSpace($HeadCommit)) {
    foreach ($line in (Invoke-DeliveryGateGitRead -BridgeRoot $root -Arguments @('diff','--name-only','--diff-filter=ACMRTUXB',$BaseCommit,$HeadCommit))) {
      Add-DeliveryGatePathValue -List $files -BridgeRoot $root -Value $line
    }
  } else {
    foreach ($line in (Invoke-DeliveryGateGitRead -BridgeRoot $root -Arguments @('status','--porcelain'))) {
      if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
      $path = $line.Substring(3).Trim()
      if ($path -match '\s+->\s+') { $path = ($path -split '\s+->\s+')[-1] }
      Add-DeliveryGatePathValue -List $files -BridgeRoot $root -Value $path
    }
  }

  return [string[]]@($files.ToArray())
}

function Test-DeliveryGateRepoClean {
  param([string]$BridgeRoot = '')

  $root = Resolve-DeliveryGateBridgeRoot -BridgeRoot $BridgeRoot
  $status = Invoke-DeliveryGateGitRead -BridgeRoot $root -Arguments @('status','--porcelain')
  return (@($status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)
}

function Test-DeliveryGateForbiddenChanges {
  param(
    [string[]]$TouchedFiles = @(),
    [string]$TaskText = ''
  )

  foreach ($file in @($TouchedFiles)) {
    if (Test-DeliveryGateForbiddenPath -Path $file) { return $true }
  }

  $criticalFiles = @($TouchedFiles | Where-Object { Test-DeliveryCriticalBridgePath -Path $_ })
  if ($criticalFiles.Count -gt 0) {
    $hasBridgeSelf = Test-DeliveryGateBridgeSelfEvidence -TaskText $TaskText
    $hasAcceptance = Test-DeliveryGateAcceptanceEvidence -TaskText $TaskText
    if (-not ($hasBridgeSelf -and $hasAcceptance)) { return $true }
  }

  return $false
}

function New-DeliveryGateInputFacts {
  param(
    [string]$BridgeRoot = '',
    [string]$TaskText = '',
    [string]$Channel = '',
    [string]$BaseCommit = '',
    [string]$HeadCommit = '',
    $Events = @(),
    [bool]$QaPassed = $false,
    [bool]$CriticPassed = $false,
    [bool]$ParsePassed = $false,
    [bool]$SmokePassed = $false,
    [bool]$AcceptancePassed = $false,
    [bool]$MemoryUpdated = $false,
    [bool]$SelfModelRefreshed = $false,
    [bool]$ParallelObligationOk = $false
  )

  $root = Resolve-DeliveryGateBridgeRoot -BridgeRoot $BridgeRoot
  $gitFiles = @(Get-DeliveryGateTouchedFiles -BridgeRoot $root -BaseCommit $BaseCommit -HeadCommit $HeadCommit)
  $eventFiles = @(Get-DeliveryGateEventTouchedFiles -BridgeRoot $root -Events $Events)
  $touched = New-Object 'System.Collections.Generic.List[string]'
  foreach ($file in @($gitFiles + $eventFiles)) {
    Add-DeliveryGatePathValue -List $touched -BridgeRoot $root -Value $file
  }

  $eventText = Get-DeliveryGateEventText -Events $Events
  $scanText = (@($TaskText, $eventText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"

  $repoClean = Test-DeliveryGateRepoClean -BridgeRoot $root
  $critical = (@($touched.ToArray()) | Where-Object { Test-DeliveryCriticalBridgePath -Path $_ }).Count -gt 0
  $forbidden = Test-DeliveryGateForbiddenChanges -TouchedFiles @($touched.ToArray()) -TaskText $TaskText
  $destructive = Test-DeliveryGateDestructivePatternsText -Text $scanText
  $qualityBypass = Test-DeliveryGateQualityBypassText -Text $scanText
  $canaryOk = if ($critical) { ([bool]$ParsePassed -and [bool]$SmokePassed -and [bool]$AcceptancePassed) } else { $true }
  $rollbackRequired = [bool]($forbidden -or $destructive)

  $evidence = @(
    ('channel=' + $(if ([string]::IsNullOrWhiteSpace($Channel)) { 'unknown' } else { $Channel })),
    ('touched=' + @($touched.ToArray()).Count),
    ('critical=' + [string][bool]$critical),
    ('repo_clean=' + [string][bool]$repoClean),
    ('qa=' + [string][bool]$QaPassed + ' critic=' + [string][bool]$CriticPassed + ' parse=' + [string][bool]$ParsePassed + ' smoke=' + [string][bool]$SmokePassed + ' acceptance=' + [string][bool]$AcceptancePassed)
  ) -join "`n"

  return [ordered]@{
    repo_clean              = [bool]$repoClean
    forbidden_changes       = [bool]$forbidden
    destructive_patterns    = [bool]$destructive
    parse_ok                = [bool]$ParsePassed
    tests_ok                = [bool]$QaPassed
    smoke_ok                = [bool]$SmokePassed
    acceptance_ok           = [bool]$AcceptancePassed
    review_board_ok         = [bool]$CriticPassed
    parallel_obligation_ok  = [bool]$ParallelObligationOk
    memory_updated          = [bool]$MemoryUpdated
    self_model_refreshed    = [bool]$SelfModelRefreshed
    critical_bridge_self    = [bool]$critical
    canary_ok               = [bool]$canaryOk
    quality_bypass_detected = [bool]$qualityBypass
    rollback_required       = [bool]$rollbackRequired
    evidence                = [string]$evidence
  }
}
