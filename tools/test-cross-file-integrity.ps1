#Requires -Version 5.1
# Cross-file integrity validator for multi-file DONE-gate evidence.

[CmdletBinding()]
param(
  [string]$BridgeRoot = '',
  [string[]]$Files = @(),
  [string]$RegistryPath = '',
  [string]$TaskId = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Normalize-CfiPath {
  param([AllowNull()][string]$Path)
  $p = ([string]$Path).Trim()
  if ([string]::IsNullOrWhiteSpace($p)) { return '' }
  $p = $p -replace '\\','/'
  while ($p.StartsWith('./')) { $p = $p.Substring(2) }
  return $p.Trim('/')
}

function Add-CfiUniquePath {
  param(
    [Parameter(Mandatory=$true)]$List,
    [Parameter(Mandatory=$true)]$Seen,
    [AllowNull()][string]$Path
  )
  $p = Normalize-CfiPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return }
  if ($Seen.Add($p)) { [void]$List.Add($p) }
}

function Get-CfiObjectValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [AllowNull()]$Default = $null
  )
  if ($null -eq $Object) { return $Default }
  foreach ($name in @($Names)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    try {
      if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return $Object[$name] }
      if ($Object.PSObject.Properties.Name -contains $name) { return $Object.$name }
    } catch {}
  }
  return $Default
}

function ConvertTo-CfiPathList {
  param([AllowNull()]$Value)
  $paths = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($raw in @($Value)) {
    Add-CfiUniquePath -List $paths -Seen $seen -Path ([string]$raw)
  }
  return @($paths.ToArray())
}

function Get-CfiGitChangedFiles {
  param([Parameter(Mandatory=$true)][string]$Root)
  $lines = @(& git -c ("safe.directory=" + $Root) -C $Root diff --name-only HEAD -- 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'git diff --name-only HEAD failed' }
  return @(ConvertTo-CfiPathList -Value $lines)
}

function Add-CfiEvidenceFilesFromObject {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory=$true)]$FilesList,
    [Parameter(Mandatory=$true)]$Seen,
    [int]$Depth = 0
  )
  if ($null -eq $Object -or $Depth -gt 5) { return }

  foreach ($name in @('actual_files','changed_files','declared_files','files','source_actual_files')) {
    $value = Get-CfiObjectValue -Object $Object -Names @($name) -Default $null
    if ($null -ne $value) {
      foreach ($p in @(ConvertTo-CfiPathList -Value $value)) {
        Add-CfiUniquePath -List $FilesList -Seen $Seen -Path $p
      }
    }
  }

  foreach ($childName in @('done_evidence','evidence','outcome_ledger','validation_result')) {
    $child = Get-CfiObjectValue -Object $Object -Names @($childName) -Default $null
    if ($null -ne $child) {
      Add-CfiEvidenceFilesFromObject -Object $child -FilesList $FilesList -Seen $Seen -Depth ($Depth + 1)
    }
  }
}

function Add-CfiFilesFromTaskText {
  param(
    [AllowNull()][string]$Text,
    [Parameter(Mandatory=$true)]$FilesList,
    [Parameter(Mandatory=$true)]$Seen
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  foreach ($line in ([string]$Text -split "`r?`n")) {
    if ($line -notmatch '(?i)^\s*Files\s*:\s*(.+?)\s*$') { continue }
    $tail = $Matches[1]
    foreach ($part in ($tail -split '[,;]')) {
      Add-CfiUniquePath -List $FilesList -Seen $Seen -Path $part
    }
  }
}

function Get-CfiDoneGateEvidence {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$TaskId = ''
  )

  $files = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $sources = New-Object 'System.Collections.Generic.List[string]'

  $statePath = Join-Path $Root 'channels\main\state.json'
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      $state = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId = [string](Get-CfiObjectValue -Object $state -Names @('current_backlog_id','done_gate_pass_task') -Default '')
      }
      Add-CfiFilesFromTaskText -Text ([string](Get-CfiObjectValue -Object $state -Names @('current_task') -Default '')) -FilesList $files -Seen $seen
      [void]$sources.Add('task:channels/main/state.json')
    } catch {}
  }

  $channelsDir = Join-Path $Root 'channels'
  if (Test-Path -LiteralPath $channelsDir -PathType Container) {
    foreach ($backlogPath in @(Get-ChildItem -LiteralPath $channelsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'backlog.jsonl' })) {
      if (-not (Test-Path -LiteralPath $backlogPath -PathType Leaf)) { continue }
      try {
        foreach ($line in [System.IO.File]::ReadLines($backlogPath, [System.Text.Encoding]::UTF8)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          if (-not [string]::IsNullOrWhiteSpace($TaskId) -and $line.IndexOf($TaskId, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
          $item = $line | ConvertFrom-Json
          if (-not [string]::IsNullOrWhiteSpace($TaskId) -and [string](Get-CfiObjectValue -Object $item -Names @('id') -Default '') -ne $TaskId) { continue }
          Add-CfiEvidenceFilesFromObject -Object $item -FilesList $files -Seen $seen
          Add-CfiFilesFromTaskText -Text ([string](Get-CfiObjectValue -Object $item -Names @('text','task','title') -Default '')) -FilesList $files -Seen $seen
          [void]$sources.Add('task:' + (Normalize-CfiPath -Path ($backlogPath.Substring($Root.Length).TrimStart('\','/'))))
        }
      } catch {}
    }
  }

  $decisionsDir = Join-Path $Root 'decisions'
  if (Test-Path -LiteralPath $decisionsDir -PathType Container) {
    foreach ($decPath in @(Get-ChildItem -LiteralPath $decisionsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json','.jsonl') })) {
      try {
        if ($decPath.Extension -eq '.json') {
          $obj = [System.IO.File]::ReadAllText($decPath.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
          if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
            $bid = [string](Get-CfiObjectValue -Object $obj -Names @('backlog_id','task_id','source_backlog_id') -Default '')
            if (-not [string]::IsNullOrWhiteSpace($bid) -and $bid -ne $TaskId) { continue }
          }
          Add-CfiEvidenceFilesFromObject -Object $obj -FilesList $files -Seen $seen
          [void]$sources.Add('decisions:' + $decPath.Name)
        } else {
          foreach ($line in [System.IO.File]::ReadLines($decPath.FullName, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not [string]::IsNullOrWhiteSpace($TaskId) -and $line.IndexOf($TaskId, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            try {
              $obj = $line | ConvertFrom-Json
              Add-CfiEvidenceFilesFromObject -Object $obj -FilesList $files -Seen $seen
              [void]$sources.Add('decisions:' + $decPath.Name)
            } catch {}
          }
        }
      } catch {}
    }
  }

  return [pscustomobject][ordered]@{
    files = @($files.ToArray())
    sources = @($sources.ToArray() | Sort-Object -Unique)
    task_id = [string]$TaskId
  }
}

function Get-CfiRegistryFiles {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$Path = ''
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $Root 'features\registry.json' }
  $items = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $parsed = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $items = @($parsed)
  }

  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($feature in @($items)) {
    $id = [string](Get-CfiObjectValue -Object $feature -Names @('id') -Default '')
    foreach ($p in @(ConvertTo-CfiPathList -Value (Get-CfiObjectValue -Object $feature -Names @('owner_files') -Default @()))) {
      [void]$records.Add([pscustomobject][ordered]@{ feature = $id; path = $p })
    }
  }
  return [pscustomobject][ordered]@{
    path = $Path
    files = @($records.ToArray())
  }
}

function Test-CfiPowerShellParse {
  param([Parameter(Mandatory=$true)][string]$Path)
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors -and $errors.Count -gt 0) {
    return [pscustomobject][ordered]@{ ok = $false; error = [string]$errors[0].Message }
  }
  return [pscustomobject][ordered]@{ ok = $true; error = '' }
}

function Invoke-CrossFileIntegrity {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string[]]$InputFiles = @(),
    [string]$RegistryPath = '',
    [string]$TaskId = ''
  )

  $rootFull = [System.IO.Path]::GetFullPath($Root)
  $targetFiles = @(ConvertTo-CfiPathList -Value $InputFiles)
  if ($targetFiles.Count -eq 0) {
    $targetFiles = @(Get-CfiGitChangedFiles -Root $rootFull)
  }

  $errors = New-Object 'System.Collections.Generic.List[object]'
  $checks = New-Object 'System.Collections.Generic.List[object]'

  $done = Get-CfiDoneGateEvidence -Root $rootFull -TaskId $TaskId
  $doneSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in @($done.files)) { [void]$doneSet.Add([string]$p) }
  $missingFromDone = @()
  if ($targetFiles.Count -gt 0 -and $doneSet.Count -gt 0) {
    $missingFromDone = @($targetFiles | Where-Object { -not $doneSet.Contains([string]$_) })
    foreach ($p in @($missingFromDone)) {
      [void]$errors.Add([pscustomobject][ordered]@{ source = 'done_gate'; path = [string]$p; reason = 'input file is absent from DONE-gate task/evidence' })
    }
  }
  [void]$checks.Add([pscustomobject][ordered]@{
    source = 'done_gate'
    ok = ($missingFromDone.Count -eq 0)
    evidence_files = @($done.files)
    evidence_sources = @($done.sources)
    task_id = [string]$done.task_id
  })

  $registry = Get-CfiRegistryFiles -Root $rootFull -Path $RegistryPath
  $registryMissing = New-Object 'System.Collections.Generic.List[object]'
  foreach ($record in @($registry.files)) {
    $abs = Join-Path $rootFull ([string]$record.path)
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
      [void]$registryMissing.Add($record)
      [void]$errors.Add([pscustomobject][ordered]@{ source = 'registry'; feature = [string]$record.feature; path = [string]$record.path; reason = 'owner_files path is missing on disk' })
    }
  }
  [void]$checks.Add([pscustomobject][ordered]@{
    source = 'registry'
    ok = ($registryMissing.Count -eq 0)
    registry_path = $registry.path
    owner_file_count = @($registry.files).Count
    missing = @($registryMissing.ToArray())
  })

  $diskProblems = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in @($targetFiles)) {
    $abs = Join-Path $rootFull ([string]$p)
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
      $problem = [pscustomobject][ordered]@{ source = 'disk'; path = [string]$p; reason = 'input file is missing on disk' }
      [void]$diskProblems.Add($problem)
      [void]$errors.Add($problem)
      continue
    }
    if ([string]$p -match '(?i)\.ps1$') {
      $parse = Test-CfiPowerShellParse -Path $abs
      if (-not [bool]$parse.ok) {
        $problem = [pscustomobject][ordered]@{ source = 'disk'; path = [string]$p; reason = 'ParseFile failed'; detail = [string]$parse.error }
        [void]$diskProblems.Add($problem)
        [void]$errors.Add($problem)
      }
    }
  }
  [void]$checks.Add([pscustomobject][ordered]@{
    source = 'disk'
    ok = ($diskProblems.Count -eq 0)
    checked_files = @($targetFiles)
    problems = @($diskProblems.ToArray())
  })

  return [pscustomobject][ordered]@{
    ok = ($errors.Count -eq 0)
    files = @($targetFiles)
    checks = @($checks.ToArray())
    errors = @($errors.ToArray())
  }
}

function Write-CfiResult {
  param([Parameter(Mandatory=$true)]$Result)
  $Result | ConvertTo-Json -Depth 8
}

function Write-CfiTextErrorSummary {
  param([Parameter(Mandatory=$true)]$Result)
  foreach ($err in @($Result.errors)) {
    $source = [string](Get-CfiObjectValue -Object $err -Names @('source') -Default 'unknown')
    $path = [string](Get-CfiObjectValue -Object $err -Names @('path') -Default '')
    $reason = [string](Get-CfiObjectValue -Object $err -Names @('reason') -Default '')
    Write-Host ("DESYNC source={0} path={1} reason={2}" -f $source,$path,$reason)
  }
}

function New-CfiSelfTestBridge {
  param([bool]$RegistryMismatch = $false)
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-cfi-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $root 'features') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $root 'channels\main') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $root 'decisions') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null

  $toolRel = 'tools/sample.ps1'
  [System.IO.File]::WriteAllText((Join-Path $root $toolRel), "# sample`nparam()`n", (New-Object System.Text.UTF8Encoding($true)))
  $owner = if ($RegistryMismatch) { 'tools/missing.ps1' } else { $toolRel }
  $registry = @([pscustomobject][ordered]@{ id = 'sample'; owner_files = @($owner) })
  [System.IO.File]::WriteAllText((Join-Path $root 'features\registry.json'), ($registry | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))

  $item = [pscustomobject][ordered]@{
    id = 'task-a'
    status = 'done'
    text = 'Files: tools/sample.ps1'
    done_sha = 'abc1234'
    done_evidence = [pscustomobject][ordered]@{ actual_files = @($toolRel); changed_files = @($toolRel) }
  }
  [System.IO.File]::WriteAllText((Join-Path $root 'channels\main\backlog.jsonl'), (($item | ConvertTo-Json -Compress -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($true)))
  [System.IO.File]::WriteAllText((Join-Path $root 'channels\main\state.json'), (@{ current_backlog_id = 'task-a'; current_task = 'Files: tools/sample.ps1' } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
  return [pscustomobject][ordered]@{ Root = $root; Files = @($toolRel); TaskId = 'task-a' }
}

function Invoke-CfiSelfTest {
  $pass = 0
  $fail = 0
  $caseOk = New-CfiSelfTestBridge -RegistryMismatch:$false
  try {
    $r1 = Invoke-CrossFileIntegrity -Root $caseOk.Root -InputFiles $caseOk.Files -TaskId $caseOk.TaskId
    if ([bool]$r1.ok) { $pass++; Write-Host 'PASS consistent fixture returns ok' } else { $fail++; Write-Host 'FAIL consistent fixture'; Write-CfiResult -Result $r1 }
  } finally {
    Remove-Item -LiteralPath $caseOk.Root -Recurse -Force -ErrorAction SilentlyContinue
  }

  $caseBad = New-CfiSelfTestBridge -RegistryMismatch:$true
  try {
    $r2 = Invoke-CrossFileIntegrity -Root $caseBad.Root -InputFiles $caseBad.Files -TaskId $caseBad.TaskId
    $hasRegistry = @($r2.errors | Where-Object { [string]$_.source -eq 'registry' }).Count -gt 0
    if ((-not [bool]$r2.ok) -and $hasRegistry) {
      $pass++
      Write-Host 'PASS synthetic registry mismatch returns failure'
      Write-CfiTextErrorSummary -Result $r2
    } else {
      $fail++
      Write-Host 'FAIL synthetic registry mismatch'
      Write-CfiResult -Result $r2
    }
  } finally {
    Remove-Item -LiteralPath $caseBad.Root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host ("RESULT: {0} passed, {1} failed" -f $pass,$fail)
  if ($fail -gt 0) { exit 1 }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
  $BridgeRoot = Split-Path -Parent $PSScriptRoot
}

if ($SelfTest) {
  Invoke-CfiSelfTest
}

$result = Invoke-CrossFileIntegrity -Root $BridgeRoot -InputFiles $Files -RegistryPath $RegistryPath -TaskId $TaskId
Write-CfiResult -Result $result
if (-not [bool]$result.ok) {
  Write-CfiTextErrorSummary -Result $result
  exit 1
}
exit 0
