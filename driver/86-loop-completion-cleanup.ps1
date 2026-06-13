# Loop-completion cleanup: DONE bookkeeping, delivery-gate shadow, and final state reset.
# Dot invocation preserves existing `continue` behavior for doctor resume and loop close.

$script:DriverLoopCompletionCleanupRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DriverLoopCompletionCleanupBridgeRoot = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot
$script:DriverLoopCompletionLedgerPath = Join-Path $script:DriverLoopCompletionCleanupBridgeRoot 'lib\task-outcome-ledger.ps1'
$script:DriverCompletionLastGitError = ''
if (-not (Get-Command Test-TaskOutcomeLedgerDone -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $script:DriverLoopCompletionLedgerPath)) {
  . $script:DriverLoopCompletionLedgerPath
}

function Import-DriverTaskOutcomeLedger {
  param([string]$BridgeRoot = '')
  if (Get-Command Test-TaskOutcomeLedgerDone -ErrorAction SilentlyContinue) { return }
  $root = [string]$BridgeRoot
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot }
  $ledgerPath = Join-Path $root 'lib\task-outcome-ledger.ps1'
  if (-not (Test-Path -LiteralPath $ledgerPath)) { throw "Missing task outcome ledger: $ledgerPath" }
  . $ledgerPath
}

function Set-DriverOutcomeProperty {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()]$Value
  )
  if ($Item.PSObject.Properties.Name -contains $Name) {
    $Item.PSObject.Properties[$Name].Value = $Value
  } else {
    $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
  }
}

function Get-DriverOutcomeLedgerBlockDecision {
  # 2026-06-11 freeze-audit wave1 atom1. An outcome-ledger validation block used to force
  # CONTINUE on EVERY close attempt with no cap. A structural evidence gap (stale base sha,
  # HEAD==base zero-diff, project-vs-bridge sha mismatch) can never be cured by retrying, so
  # one task wedged the whole conveyor forever. This decides: retry once (strike 1) or degrade
  # the items to needs-review and close (strike >= threshold). The count is PERSISTED in
  # state.json by the caller (in-memory counters reset on driver restart and never fire).
  param(
    [AllowNull()]$State,
    [string]$TaskId = '',
    [int]$Threshold = 2
  )
  $prevCount = 0
  $prevTask = ''
  try {
    if ($State -and $State.PSObject.Properties.Name -contains 'outcome_ledger_block_count') { $prevCount = [int]$State.outcome_ledger_block_count }
  } catch { $prevCount = 0 }
  try {
    if ($State -and $State.PSObject.Properties.Name -contains 'outcome_ledger_block_task') { $prevTask = [string]$State.outcome_ledger_block_task }
  } catch { $prevTask = '' }
  if ($prevTask -ne $TaskId) { $prevCount = 0 }
  $newCount = $prevCount + 1
  return [pscustomobject][ordered]@{
    strike  = [int]$newCount
    degrade = ($newCount -ge $Threshold)
    task_id = [string]$TaskId
  }
}

function Copy-DriverOutcomeItem {
  param([Parameter(Mandatory=$true)]$Item)
  $copy = [pscustomobject][ordered]@{}
  foreach ($prop in @($Item.PSObject.Properties)) {
    Set-DriverOutcomeProperty -Item $copy -Name ([string]$prop.Name) -Value $prop.Value
  }
  return $copy
}

function ConvertTo-DriverCompletionPathList {
  param([object]$Value)

  $paths = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($raw in @($Value)) {
    $p = ([string]$raw).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $p = $p -replace '\\','/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($seen.Add($p)) { [void]$paths.Add($p) }
  }
  return @($paths.ToArray())
}

function Invoke-DriverCompletionGitLines {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string[]]$GitArgs
  )

  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) {
    $script:DriverCompletionLastGitError = 'missing or invalid repo root for git evidence'
    Write-Warning ("Driver completion git evidence failed: " + $script:DriverCompletionLastGitError)
    return @()
  }
  $gitErrFile = [System.IO.Path]::GetTempFileName()
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $out = @(& git -c ("safe.directory=" + $RepoRoot) -C $RepoRoot @GitArgs 2> $gitErrFile)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
      $errText = ''
      try {
        if (Test-Path -LiteralPath $gitErrFile) {
          $errText = [System.IO.File]::ReadAllText($gitErrFile, [System.Text.Encoding]::UTF8)
        }
      } catch {
        $errText = ''
      }
      $detail = ((@($out) + @($errText)) -join ' ').Trim()
      if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "exit $exitCode" }
      $script:DriverCompletionLastGitError = ("git {0} failed: {1}" -f (@($GitArgs) -join ' '), ($detail -replace '\s+', ' '))
      Write-Warning ("Driver completion git evidence failed: " + $script:DriverCompletionLastGitError)
      return @()
    }
    $script:DriverCompletionLastGitError = ''
    return @($out)
  } catch {
    $script:DriverCompletionLastGitError = ("git {0} failed: {1}" -f (@($GitArgs) -join ' '), $_.Exception.Message)
    Write-Warning ("Driver completion git evidence failed: " + $script:DriverCompletionLastGitError)
    return @()
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    Remove-Item -LiteralPath $gitErrFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-DriverCompletionGitChangedFiles {
  param(
    [string]$RepoRoot = '',
    [string]$BaseSha = '',
    [string]$HeadSha = ''
  )

  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or [string]::IsNullOrWhiteSpace($BaseSha) -or [string]::IsNullOrWhiteSpace($HeadSha)) {
    $script:DriverCompletionLastGitError = 'missing repo root, base sha, or head sha for git changed-files evidence'
    return @()
  }
  $script:DriverCompletionLastGitError = ''
  $baseType = [string]((Invoke-DriverCompletionGitLines -RepoRoot $RepoRoot -GitArgs @('cat-file','-t',$BaseSha) | Select-Object -First 1) -join '')
  $baseError = [string]$script:DriverCompletionLastGitError
  $headType = [string]((Invoke-DriverCompletionGitLines -RepoRoot $RepoRoot -GitArgs @('cat-file','-t',$HeadSha) | Select-Object -First 1) -join '')
  $headError = [string]$script:DriverCompletionLastGitError
  if ($baseType.Trim() -ne 'commit') {
    if ([string]::IsNullOrWhiteSpace($baseError)) { $baseError = "base sha is not a commit: $BaseSha" }
    $script:DriverCompletionLastGitError = $baseError
    return @()
  }
  if ($headType.Trim() -ne 'commit') {
    if ([string]::IsNullOrWhiteSpace($headError)) { $headError = "head sha is not a commit: $HeadSha" }
    $script:DriverCompletionLastGitError = $headError
    return @()
  }
  $diffLines = @(Invoke-DriverCompletionGitLines -RepoRoot $RepoRoot -GitArgs @('diff','--name-only',$BaseSha,$HeadSha,'--'))
  if (-not [string]::IsNullOrWhiteSpace([string]$script:DriverCompletionLastGitError)) { return @() }
  return @(ConvertTo-DriverCompletionPathList -Value $diffLines)
}

function Get-DriverCompletionObjectValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null
  )

  foreach ($name in @($Names)) {
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace([string]$name)) { continue }
    try {
      if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return $Object[$name] }
      if ($Object.PSObject.Properties.Name -contains $name) { return $Object.$name }
    } catch {
      continue
    }
  }
  return $Default
}

function Get-DriverCompletionActualFiles {
  param([Parameter(Mandatory=$false)]$OutcomeEvidence)

  $doneEvidence = Get-DriverCompletionObjectValue -Object $OutcomeEvidence -Names @('done_evidence') -Default $null
  $files = @(Get-DriverCompletionObjectValue -Object $OutcomeEvidence -Names @('actual_files','changed_files','files') -Default @())
  if (@($files).Count -eq 0) {
    $files = @(Get-DriverCompletionObjectValue -Object $doneEvidence -Names @('actual_files','changed_files','files') -Default @())
  }
  return @(ConvertTo-DriverCompletionPathList -Value $files)
}

function Add-DriverCompletionEvidenceText {
  param(
    [Parameter(Mandatory=$false)]$Value,
    [Parameter(Mandatory=$true)]$Lines,
    [int]$Depth = 0,
    [Parameter(Mandatory=$false)]$Visited = $null
  )

  if ($null -eq $Value -or $Depth -gt 4 -or $Lines.Count -ge 80) { return }
  if ($null -eq $Visited) { $Visited = New-Object 'System.Collections.Generic.HashSet[int]' }
  if ($Value -is [string]) {
    $text = ([string]$Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) { [void]$Lines.Add($text) }
    return
  }
  if ($Value -is [ValueType]) {
    $text = ([string]$Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) { [void]$Lines.Add($text) }
    return
  }
  $visitKey = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Value)
  if (-not $Visited.Add($visitKey)) { return }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($k in @($Value.Keys)) {
      if ($Lines.Count -ge 80) { break }
      Add-DriverCompletionEvidenceText -Value $Value[$k] -Lines $Lines -Depth ($Depth + 1) -Visited $Visited
    }
    return
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($v in @($Value)) {
      if ($Lines.Count -ge 80) { break }
      Add-DriverCompletionEvidenceText -Value $v -Lines $Lines -Depth ($Depth + 1) -Visited $Visited
    }
    return
  }
  foreach ($prop in @($Value.PSObject.Properties)) {
    if ($Lines.Count -ge 80) { break }
    Add-DriverCompletionEvidenceText -Value $prop.Value -Lines $Lines -Depth ($Depth + 1) -Visited $Visited
  }
}

function Test-DriverCompletionWiringGapEvidence {
  param([Parameter(Mandatory=$false)]$OutcomeEvidence)

  $lines = New-Object 'System.Collections.Generic.List[string]'
  Add-DriverCompletionEvidenceText -Value $OutcomeEvidence -Lines $lines
  $text = [string]::Join("`n", @($lines.ToArray()))
  return [bool]($text -match '(?i)built\s*[- ]\s*but\s*[- ]\s*not\s*[- ]\s*wired|wiring\s+gap|not\s+wired')
}

function New-DriverCompletionWiringGapFollowUp {
  param(
    [Parameter(Mandatory=$true)][string]$SourceId,
    [Parameter(Mandatory=$false)]$SourceItem,
    [Parameter(Mandatory=$false)]$OutcomeEvidence,
    [string[]]$ActualFiles = @()
  )

  $doneEvidence = Get-DriverCompletionObjectValue -Object $OutcomeEvidence -Names @('done_evidence') -Default $null
  $doneSha = [string](Get-DriverCompletionObjectValue -Object $OutcomeEvidence -Names @('done_sha','head_sha','commit') -Default '')
  $baseSha = [string](Get-DriverCompletionObjectValue -Object $doneEvidence -Names @('base_sha') -Default '')
  $headSha = [string](Get-DriverCompletionObjectValue -Object $doneEvidence -Names @('head_sha') -Default $doneSha)
  if ([string]::IsNullOrWhiteSpace($doneSha)) { $doneSha = $headSha }
  if ([string]::IsNullOrWhiteSpace($doneSha) -and $SourceItem) {
    $doneSha = [string](Get-DriverCompletionObjectValue -Object $SourceItem -Names @('done_sha','source_done_sha','source_head_sha') -Default '')
  }
  if ([string]::IsNullOrWhiteSpace($headSha)) { $headSha = $doneSha }
  if ([string]::IsNullOrWhiteSpace($doneSha)) { return $null }
  $files = @(ConvertTo-DriverCompletionPathList -Value $ActualFiles)
  if (@($files).Count -eq 0 -and $SourceItem) {
    $files = @(ConvertTo-DriverCompletionPathList -Value (Get-DriverCompletionObjectValue -Object $SourceItem -Names @('files','touch_set','workpack_touch_set') -Default @()))
  }
  if (@($files).Count -eq 0) { $files = @('backlog') }

  $sourceTitle = [string](Get-DriverCompletionObjectValue -Object $SourceItem -Names @('title','task','text') -Default '')
  if ($sourceTitle.Length -gt 120) { $sourceTitle = $sourceTitle.Substring(0,120) + '...' }
  $sourceProject = [string](Get-DriverCompletionObjectValue -Object $SourceItem -Names @('project') -Default '')
  $sourceScope = [string](Get-DriverCompletionObjectValue -Object $SourceItem -Names @('scope') -Default '')
  if ([string]::IsNullOrWhiteSpace($sourceScope)) { $sourceScope = 'bridge' }
  $title = "Follow up wiring gap from backlog task $SourceId"
  $taskText = "Investigate and wire the implementation from backlog task $SourceId so built-but-not-wired / wiring-gap evidence is resolved. Source commit: $headSha. Source task: $sourceTitle"
  return [pscustomobject][ordered]@{
    id = [guid]::NewGuid().ToString('N')
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = 'driver-completion'
    status = 'open'
    tags = @('follow-up','wiring-gap','built-but-not-wired')
    attempts = 0
    score = 0.0
    project = $sourceProject
    scope = $sourceScope
    title = $title
    task = $taskText
    text = $taskText
    files = @($files)
    acceptance = @(
      "The implementation touched by source backlog task $SourceId is invoked from the live runtime path, not only defined or unit-tested.",
      "A focused regression proves the wiring path executes and fails if the integration is removed."
    )
    checks = @(
      'Run the focused regression that covers the missing wiring path.',
      'Run Parser.ParseFile for touched PowerShell files.',
      'Run smoke.ps1.'
    )
    followup_kind = 'wiring-gap'
    followup_of = [string]$SourceId
    source_backlog_id = [string]$SourceId
    source_done_sha = [string]$doneSha
    source_base_sha = [string]$baseSha
    source_head_sha = [string]$headSha
    source_actual_files = @($files)
    evidence = [pscustomobject][ordered]@{
      reason = 'built-but-not-wired/wiring-gap evidence found during completion'
      source_backlog_id = [string]$SourceId
      source_done_sha = [string]$doneSha
      source_base_sha = [string]$baseSha
      source_head_sha = [string]$headSha
      actual_files = @($files)
    }
  }
}

function New-DriverCompletionDoneEvidence {
  param(
    [Parameter(Mandatory=$false)]$State,
    [string]$Reply = '',
    [string]$Speaker = '',
    [string]$BridgeRoot = '',
    [string]$Channel = '',
    [bool]$FastLaneDone = $false
  )

  $root = [string]$BridgeRoot
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot }
  $repoRoot = $root
  try {
    if (Get-Command Get-TaskRepoRoot -ErrorAction SilentlyContinue) {
      $candidateRepo = [string](Get-TaskRepoRoot)
      if (-not [string]::IsNullOrWhiteSpace($candidateRepo)) { $repoRoot = $candidateRepo }
    } elseif (Get-Command Get-ActiveProjectRoot -ErrorAction SilentlyContinue) {
      $candidateRepo = [string](Get-ActiveProjectRoot)
      if (-not [string]::IsNullOrWhiteSpace($candidateRepo)) { $repoRoot = $candidateRepo }
    }
  } catch {
    $repoRoot = $root
  }

  $head = ''
  $gitDiffError = ''
  try { $head = ((Invoke-DriverCompletionGitLines -RepoRoot $repoRoot -GitArgs @('rev-parse','HEAD') | Select-Object -First 1) -join '').Trim() } catch { $head = '' }
  $headError = [string]$script:DriverCompletionLastGitError
  $base = ''
  try { $base = [string]$State.task_base_commit } catch { $base = '' }
  $actualFiles = @()
  if ([string]::IsNullOrWhiteSpace($head)) {
    $gitDiffError = if ([string]::IsNullOrWhiteSpace($headError)) { 'missing head sha for git changed-files evidence' } else { $headError }
  } elseif ([string]::IsNullOrWhiteSpace($base)) {
    $gitDiffError = 'missing base sha for git changed-files evidence'
  } else {
    $actualFiles = @(Get-DriverCompletionGitChangedFiles -RepoRoot $repoRoot -BaseSha $base -HeadSha $head)
    $gitDiffError = [string]$script:DriverCompletionLastGitError
  }
  $actualFilesComplete = (@($actualFiles).Count -gt 0 -and [string]::IsNullOrWhiteSpace($gitDiffError))
  $actualFilesStatus = if ($actualFilesComplete) {
    'ok'
  } elseif (-not [string]::IsNullOrWhiteSpace($gitDiffError)) {
    'error'
  } else {
    'empty'
  }

  $verified = New-Object 'System.Collections.Generic.List[string]'
  foreach ($match in [regex]::Matches([string]$Reply, '(?im)^\s*\[\[VERIFIED:\s*(.+?)\]\]\s*$')) {
    $txt = $match.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($txt)) { [void]$verified.Add($txt) }
  }

  $riskMarkers = New-Object 'System.Collections.Generic.List[string]'
  foreach ($match in [regex]::Matches([string]$Reply, '(?im)^\s*\[\[PROJECT_RISK:\s*(.+?)\]\]\s*$')) {
    $txt = $match.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($txt)) { [void]$riskMarkers.Add($txt) }
  }

  $wiringLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in @(([string]$Reply) -split "`r?`n")) {
    if ($wiringLines.Count -ge 10) { break }
    $txt = ([string]$line).Trim()
    if ($txt -match '(?i)built\s*[- ]\s*but\s*[- ]\s*not\s*[- ]\s*wired|wiring\s+gap|not\s+wired') {
      [void]$wiringLines.Add($txt)
    }
  }

  $tests = New-Object 'System.Collections.Generic.List[string]'
  foreach ($v in @($verified.ToArray())) { [void]$tests.Add($v) }
  foreach ($gate in @('completion-gate:critic', 'completion-gate:parsefile', 'completion-gate:smoke', 'completion-gate:qa')) {
    [void]$tests.Add($gate)
  }

  $criticResult = 'PASS'
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'skip_critic') -and [bool]$State.skip_critic) {
      $criticResult = 'SKIPPED'
    } elseif ($State -and ($State.PSObject.Properties.Name -contains 'completion_critic_result') -and
        (Test-TaskOutcomeLedgerSkippedEmptyResult -Value $State.completion_critic_result)) {
      $criticResult = 'skipped-empty'
    }
  } catch {
    $criticResult = 'PASS'
  }
  $coderResult = ''
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'completion_coder_result') -and
        (Test-TaskOutcomeLedgerSkippedEmptyResult -Value $State.completion_coder_result)) {
      $coderResult = 'skipped-empty'
    }
  } catch {
    $coderResult = ''
  }
  $llmGateResults = [ordered]@{
    critic_result = $criticResult
    qa_result = 'PASS'
  }
  if (-not [string]::IsNullOrWhiteSpace($coderResult)) { $llmGateResults.coder_result = $coderResult }

  return [pscustomobject][ordered]@{
    done_sha = $head
    actual_files = @($actualFiles)
    actual_files_complete = [bool]$actualFilesComplete
    actual_files_status = $actualFilesStatus
    git_diff_error = $gitDiffError
    done_evidence = [pscustomobject][ordered]@{
      repo_root = $repoRoot
      base_sha = $base
      head_sha = $head
      changed_files = @($actualFiles)
      actual_files = @($actualFiles)
      actual_files_complete = [bool]$actualFilesComplete
      actual_files_status = $actualFilesStatus
      git_diff_error = $gitDiffError
      verified = @($verified.ToArray())
      project_risks = @($riskMarkers.ToArray())
      wiring_gap_evidence = @($wiringLines.ToArray())
      gates = @('critic','parsefile','smoke','qa')
      llm_gate_results = [pscustomobject]$llmGateResults
      channel = [string]$Channel
      fast_lane = [bool]$FastLaneDone
    }
    done_by = if ([string]::IsNullOrWhiteSpace($Speaker)) { 'driver-completion' } else { [string]$Speaker }
    tests_run = @($tests.ToArray())
    critic_result = $criticResult
    qa_result = 'PASS'
    llm_gate_results = [pscustomobject]$llmGateResults
  }
}

function Set-BacklogOutcomeDoneWithLedger {
  param(
    [Parameter(Mandatory=$true)][string[]]$Ids,
    [Parameter(Mandatory=$true)]$OutcomeEvidence,
    [string]$BridgeRoot = ''
  )

  Import-DriverTaskOutcomeLedger -BridgeRoot $BridgeRoot
  $idsClean = @($Ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($idsClean.Count -eq 0) {
    return [pscustomobject][ordered]@{ ok = $true; reason = 'no_ids'; done_ids = @(); needs_review_ids = @(); blocked_ids = @(); ledger_entries = @() }
  }

  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $testDoneFn = ${function:Test-TaskOutcomeLedgerDone}
  $recoverFn = ${function:Test-TaskOutcomeLedgerRecoverFalseFailed}
  $entryFn = ${function:Get-TaskOutcomeLedgerEntry}
  $copyFn = ${function:Copy-DriverOutcomeItem}
  $setPropFn = ${function:Set-DriverOutcomeProperty}
  $actualFilesFn = ${function:Get-DriverCompletionActualFiles}
  $wiringGapFn = ${function:Test-DriverCompletionWiringGapEvidence}
  $newFollowUpFn = ${function:New-DriverCompletionWiringGapFollowUp}
  $objectValueFn = ${function:Get-TaskOutcomeLedgerObjectValue}

  $doneSha = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_sha') -Default '')
  $doneEvidence = Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_evidence') -Default $null
  $doneBy = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_by') -Default '')
  $testsRun = @(Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('tests_run') -Default @())
  $criticResult = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('critic_result') -Default '')
  $qaResult = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('qa_result') -Default '')
  $llmGateResults = Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('llm_gate_results','llm_gate_evidence','empty_llm_results') -Default $null
  if ($null -eq $llmGateResults) {
    $llmGateResults = Get-TaskOutcomeLedgerObjectValue -Object $doneEvidence -Names @('llm_gate_results','llm_gate_evidence','empty_llm_results') -Default $null
  }
  if ([string]::IsNullOrWhiteSpace($criticResult) -and
      (Test-TaskOutcomeLedgerSkippedEmptyResult -Value (Get-TaskOutcomeLedgerObjectValue -Object $llmGateResults -Names @('critic_result') -Default $null))) {
    $criticResult = 'skipped-empty'
  }
  if ([string]::IsNullOrWhiteSpace($qaResult) -and
      (Test-TaskOutcomeLedgerSkippedEmptyResult -Value (Get-TaskOutcomeLedgerObjectValue -Object $llmGateResults -Names @('qa_result') -Default $null))) {
    $qaResult = 'skipped-empty'
  }
  $actualFiles = @(& $actualFilesFn -OutcomeEvidence $OutcomeEvidence)
  $hasWiringGap = [bool](& $wiringGapFn -OutcomeEvidence $OutcomeEvidence)
  $recoveryEvidence = [pscustomobject][ordered]@{
    recovery_sha = $doneSha
    recovery_checks = @($testsRun)
  }

  return (Invoke-BacklogLocked ({
    $items = @(& $getBacklogFn)
    $doneIds = New-Object 'System.Collections.Generic.List[string]'
    $needsReviewIds = New-Object 'System.Collections.Generic.List[string]'
    $blockedIds = New-Object 'System.Collections.Generic.List[string]'
    $missingIds = New-Object 'System.Collections.Generic.List[string]'
    $ledgerEntries = New-Object 'System.Collections.Generic.List[object]'
    $followUpIds = New-Object 'System.Collections.Generic.List[string]'
    $dirty = $false
    $reason = 'done_evidence_complete'

    foreach ($id in @($idsClean)) {
      $item = $null
      foreach ($candidateItem in $items) {
        if ([string]$candidateItem.id -eq [string]$id) { $item = $candidateItem; break }
      }
      if ($null -eq $item) {
        # 2026-06-10: a MISSING id (vetoed/archived/compacted mid-batch) can never be cured by
        # retrying the close — counting it as blocking wedged the whole batch close forever
        # while the FOUND members were already marked done. Skip it with a note instead.
        [void]$missingIds.Add([string]$id)
        $reason = 'backlog_item_not_found'
        continue
      }

      $currentStatus = ([string](Get-TaskOutcomeLedgerObjectValue -Object $item -Names @('status') -Default '')).Trim().ToLowerInvariant()
      if ($currentStatus -eq 'failed') {
        $recovery = & $recoverFn -Item $item -RecoveryEvidence $recoveryEvidence
        if ([bool]$recovery.recoverable -and [string]$recovery.proposed_status -eq 'needs-review') {
          & $setPropFn -Item $item -Name 'status' -Value 'needs-review'
          & $setPropFn -Item $item -Name 'outcome_recovery_reason' -Value ([string]$recovery.reason)
          & $setPropFn -Item $item -Name 'outcome_recovery_evidence' -Value $recoveryEvidence
          [void]$needsReviewIds.Add([string]$id)
          $dirty = $true
          $reason = 'false_failed_needs_review'
          continue
        }
      }

      $candidate = & $copyFn -Item $item
      & $setPropFn -Item $candidate -Name 'status' -Value 'done'
      & $setPropFn -Item $candidate -Name 'done_sha' -Value $doneSha
      & $setPropFn -Item $candidate -Name 'done_evidence' -Value $doneEvidence
      & $setPropFn -Item $candidate -Name 'done_by' -Value $doneBy
      & $setPropFn -Item $candidate -Name 'tests_run' -Value @($testsRun)
      & $setPropFn -Item $candidate -Name 'critic_result' -Value $criticResult
      & $setPropFn -Item $candidate -Name 'qa_result' -Value $qaResult
      if (@($actualFiles).Count -gt 0) {
        & $setPropFn -Item $candidate -Name 'files' -Value @($actualFiles)
        & $setPropFn -Item $candidate -Name 'actual_files' -Value @($actualFiles)
      }

      $validation = & $testDoneFn -Item $candidate
      if (-not [bool]$validation.valid) {
        [void]$blockedIds.Add([string]$id)
        $missing = @($validation.missing) -join ','
        $reason = if ([string]::IsNullOrWhiteSpace($missing)) { [string]$validation.reason } else { ([string]$validation.reason + ':' + $missing) }
        continue
      }

      & $setPropFn -Item $item -Name 'status' -Value 'done'
      & $setPropFn -Item $item -Name 'done_sha' -Value $doneSha
      & $setPropFn -Item $item -Name 'done_evidence' -Value $doneEvidence
      & $setPropFn -Item $item -Name 'done_by' -Value $doneBy
      & $setPropFn -Item $item -Name 'tests_run' -Value @($testsRun)
      & $setPropFn -Item $item -Name 'critic_result' -Value $criticResult
      & $setPropFn -Item $item -Name 'qa_result' -Value $qaResult
      if (@($actualFiles).Count -gt 0) {
        $declaredFiles = @()
        try { $declaredFiles = @($item.files) } catch { $declaredFiles = @() }
        $hasDeclaredSnapshot = $false
        try { $hasDeclaredSnapshot = ($item.PSObject.Properties.Name -contains 'declared_files_before_done') } catch { $hasDeclaredSnapshot = $false }
        if (@($declaredFiles).Count -gt 0 -and -not $hasDeclaredSnapshot) {
          & $setPropFn -Item $item -Name 'declared_files_before_done' -Value @($declaredFiles)
        }
        & $setPropFn -Item $item -Name 'files' -Value @($actualFiles)
        & $setPropFn -Item $item -Name 'actual_files' -Value @($actualFiles)
      }
      $entry = & $entryFn -Item $candidate
      & $setPropFn -Item $item -Name 'outcome_ledger' -Value $entry
      [void]$ledgerEntries.Add($entry)
      [void]$doneIds.Add([string]$id)
      $dirty = $true

      # Canary-child close: if this item is a canary gate child, auto-close its approved/held parent.
      if (Get-Command Close-BacklogCanaryParent -ErrorAction SilentlyContinue) {
        $null = Close-BacklogCanaryParent -ChildItem $item -AllItems $items
      }

      if ($hasWiringGap) {
        $followExists = $false
        foreach ($existing in @($items)) {
          $existingSource = [string](& $objectValueFn -Object $existing -Names @('followup_of','source_backlog_id') -Default '')
          $existingKind = [string](& $objectValueFn -Object $existing -Names @('followup_kind') -Default '')
          if ($existingSource -eq [string]$id -and $existingKind -eq 'wiring-gap') {
            $followExists = $true
            $existingId = [string](& $objectValueFn -Object $existing -Names @('id') -Default '')
            if (-not [string]::IsNullOrWhiteSpace($existingId)) { [void]$followUpIds.Add($existingId) }
            break
          }
        }
        if (-not $followExists) {
          $followUp = & $newFollowUpFn -SourceId ([string]$id) -SourceItem $item -OutcomeEvidence $OutcomeEvidence -ActualFiles @($actualFiles)
          if ($null -ne $followUp) {
            $items += $followUp
            [void]$followUpIds.Add([string]$followUp.id)
            $dirty = $true
          }
        }
      }
    }

    if ($dirty) { & $saveBacklogFn $items }
    # ok semantics (2026-06-10): only a REAL validation block should force the caller to retry
    # the close. A missing backlog id can never be cured by retrying, and a successful
    # failed->needs-review transition is a success — both used to flip ok=false and re-run the
    # whole DONE gauntlet every turn (close-wedge).
    $ok = ($blockedIds.Count -eq 0)
    return [pscustomobject][ordered]@{
      ok = [bool]$ok
      reason = $reason
      done_ids = @($doneIds.ToArray())
      needs_review_ids = @($needsReviewIds.ToArray())
      blocked_ids = @($blockedIds.ToArray())
      skipped_missing_ids = @($missingIds.ToArray())
      ledger_entries = @($ledgerEntries.ToArray())
      actual_files = @($actualFiles)
      followup_ids = @($followUpIds.ToArray())
    }
  }.GetNewClosure()))
}

function Set-BacklogOutcomeFailedWithLedger {
  param(
    [Parameter(Mandatory=$true)][string[]]$Ids,
    [Parameter(Mandatory=$false)]$FailureEvidence,
    [string]$BridgeRoot = ''
  )

  Import-DriverTaskOutcomeLedger -BridgeRoot $BridgeRoot
  $idsClean = @($Ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($idsClean.Count -eq 0) {
    return [pscustomobject][ordered]@{ ok = $true; reason = 'no_ids'; failed_ids = @(); blocked_ids = @() }
  }

  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $testFailedFn = ${function:Test-TaskOutcomeLedgerFailed}
  $copyFn = ${function:Copy-DriverOutcomeItem}
  $setPropFn = ${function:Set-DriverOutcomeProperty}

  return (Invoke-BacklogLocked ({
    $items = @(& $getBacklogFn)
    $failedIds = New-Object 'System.Collections.Generic.List[string]'
    $blockedIds = New-Object 'System.Collections.Generic.List[string]'
    $reason = 'failure_evidence_present'
    $dirty = $false
    foreach ($id in @($idsClean)) {
      $item = $null
      foreach ($candidateItem in $items) {
        if ([string]$candidateItem.id -eq [string]$id) { $item = $candidateItem; break }
      }
      if ($null -eq $item) {
        [void]$blockedIds.Add([string]$id)
        $reason = 'backlog_item_not_found'
        continue
      }
      $candidate = & $copyFn -Item $item
      & $setPropFn -Item $candidate -Name 'status' -Value 'failed'
      & $setPropFn -Item $candidate -Name 'failure_evidence' -Value $FailureEvidence
      $validation = & $testFailedFn -Item $candidate
      if (-not [bool]$validation.valid) {
        [void]$blockedIds.Add([string]$id)
        $reason = [string]$validation.reason
        continue
      }
      & $setPropFn -Item $item -Name 'status' -Value 'failed'
      & $setPropFn -Item $item -Name 'failure_evidence' -Value $FailureEvidence
      [void]$failedIds.Add([string]$id)
      $dirty = $true
    }
    if ($dirty) { & $saveBacklogFn $items }
    return [pscustomobject][ordered]@{
      ok = ($blockedIds.Count -eq 0)
      reason = $reason
      failed_ids = @($failedIds.ToArray())
      blocked_ids = @($blockedIds.ToArray())
    }
  }.GetNewClosure()))
}
$script:DriverLoopCompletionCleanupBlock = {
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE') {
    $qaDoneBlocked = $false
    $qaDoneBlockText = ''
    try {
      $stQaDoneGuard = Read-State
      if ($stQaDoneGuard -and $stQaDoneGuard.PSObject.Properties.Name -contains 'task_last_failure' -and $null -ne $stQaDoneGuard.task_last_failure) {
        $lastFailureKind = ''
        try { $lastFailureKind = [string]$stQaDoneGuard.task_last_failure.kind } catch { $lastFailureKind = '' }
        if ($lastFailureKind -eq 'qa_failed') {
          $qaDoneBlocked = $true
          try { $qaDoneBlockText = [string]$stQaDoneGuard.task_last_failure.text } catch { $qaDoneBlockText = '' }
        }
      }
    } catch {}
    if ($qaDoneBlocked) {
      if ([string]::IsNullOrWhiteSpace($qaDoneBlockText)) { $qaDoneBlockText = 'qa_failed' }
      Add-Message -From system -Text ("🔴 QA guard: блокирую переход задачи в done из-за последнего qa_failed: " + $qaDoneBlockText) -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE') {
    if ($mode -eq 'discuss') {
      try {
        $startSeqD = [int](Read-State).task_start_seq
        $thread = (Get-Messages -Since ($startSeqD - 1) | ForEach-Object { "**$($_.from):** $($_.text)" }) -join "`n`n"
        $dpath = Save-Decision -Title $task -Content $thread
        Add-Message -From system -Text "📝 Итог обсуждения сохранён: $dpath" -Kind event | Out-Null
      } catch {}
    }
    # 2026-06-12 stage 3a (speed program): these memory writes are 2-3 LLM calls (~2-3 min) that
    # used to run SYNCHRONOUSLY here, blocking the next claim while prose was being written.
    # They now run in a detached memory-tail process (NOT a bridge job — active_jobs are awaited
    # by preflight and would re-block the loop). Same conditions, same writes, same channel
    # notifications — just off the critical path. Fail-soft: if the spawn fails, fall back to
    # the old synchronous path so memory is never silently lost.
    $script:DriverMemoryPhaseStart = [DateTime]::UtcNow
    $memoryTailSpawned = $false
    try {
      $stMemTail = Read-State
      $commitForWorklog = ''
      try {
        $rootForWorklog = Get-ActiveProjectRoot
        if (-not [string]::IsNullOrWhiteSpace($rootForWorklog)) {
          $commitForWorklog = (& git -C $rootForWorklog rev-parse --short HEAD 2>$null).Trim()
        }
      } catch {}
      $memPayload = [pscustomobject]@{
        task        = [string]$task
        outcome     = [string]$visibleReply
        mode        = [string]$mode
        mode_before = [string]$modeBeforeIncrement
        channel     = [string]$Channel
        did_actions = [bool]$stMemTail.task_did_actions
        task_turn   = [int]$stMemTail.task_turn
        start_seq   = [int]$stMemTail.task_start_seq
        commit      = $commitForWorklog
      }
      $memTailScript = Join-Path $bridgeRoot 'tools\memory-tail.ps1'
      if (Test-Path -LiteralPath $memTailScript) {
        $payloadDir = Join-Path $bridgeRoot 'tmp'
        if (-not (Test-Path -LiteralPath $payloadDir)) { New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null }
        $payloadPath = Join-Path $payloadDir ('memory-tail-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        $u8MemTail = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($payloadPath, ($memPayload | ConvertTo-Json -Depth 4), $u8MemTail)
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $memTailScript, '-PayloadPath', $payloadPath) -WindowStyle Hidden | Out-Null
        $memoryTailSpawned = $true
        Add-Message -From system -Text "🧠 Память (task/worklog/плейбук) дописывается в фоне — закрытие не ждёт." -Kind event | Out-Null
      }
    } catch { $memoryTailSpawned = $false }
    if (-not $memoryTailSpawned) {
      try {
        $memId = Add-TaskMemory -TaskText $task -Outcome $visibleReply -Source ('task:' + $mode)
        if ($memId) { Add-Message -From system -Text "🧠 Запомнено в долговременную память." -Kind event | Out-Null }
      } catch {}
      try {
        $stWorklog = Read-State
        $didWorklogActions = [bool]$stWorklog.task_did_actions
        if (($didWorklogActions -or $mode -eq 'study') -and (Get-Command Update-ProjectMemoryAfterTask -ErrorAction SilentlyContinue)) {
          $commitForWorklogSync = ''
          try {
            $rootForWorklogSync = Get-ActiveProjectRoot
            if (-not [string]::IsNullOrWhiteSpace($rootForWorklogSync)) {
              $commitForWorklogSync = (& git -C $rootForWorklogSync rev-parse --short HEAD 2>$null).Trim()
            }
          } catch {}
          $worklogId = Update-ProjectMemoryAfterTask -TaskText $task -Outcome $visibleReply -Channel $Channel -Commit $commitForWorklogSync
          if ($worklogId) { Add-Message -From system -Text "🧠 Проектная память: worklog обновлён." -Kind event | Out-Null }
        }
      } catch {}
      try {
        $stMem = Read-State
        $turnForSkill = [int]$stMem.task_turn
        $didActionsForSkill = [bool]$stMem.task_did_actions
        if ($turnForSkill -ge 2 -and $didActionsForSkill -and $modeBeforeIncrement -ne 'study') {
          $startSeqSkill = [int]$stMem.task_start_seq
          $thread = (Get-Messages -Since ($startSeqSkill - 1) | ForEach-Object {
            "**$($_.from):** $($_.text)"
          }) -join "`n`n"
          $skillId = Add-SkillMemory -TaskText $task -Transcript $thread
          if ($skillId) { Add-Message -From system -Text "📘 плейбук сохранён." -Kind event | Out-Null }
        }
      } catch {}
    }
    try {
      $memMs = [long]([DateTime]::UtcNow - $script:DriverMemoryPhaseStart).TotalMilliseconds
      if ($memMs -gt 100 -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) {
        Update-TaskPhaseTiming -Phase memory_ms -Ms $memMs
      }
    } catch {}
    try {
      if ($modeBeforeIncrement -eq 'study') {
        $studyReportPath = $null
        foreach ($fp in $fileMarkerPaths) {
          try {
            $candidate = [string]$fp
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.md' -and (Test-Path -LiteralPath $candidate)) {
              $studyReportPath = $candidate
              break
            }
          } catch {}
        }
        if ($studyReportPath) {
          $lessonCount = Add-StudyLessons -ReportPath $studyReportPath -TaskText $task
          Add-Message -From system -Text "🎓 уроков: $lessonCount" -Kind event | Out-Null
        }
      }
    } catch {}
    # If this was an autonomous backlog task, close it out.
    try {
      $stDoneBacklog = Read-State
      $doneBid = [string]$stDoneBacklog.current_backlog_id
      $doneBatchIds = @()
      try {
        if ($stDoneBacklog.PSObject.Properties.Name -contains 'workpack_batch_ids' -and $null -ne $stDoneBacklog.workpack_batch_ids) {
          $doneBatchIds = @($stDoneBacklog.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
      } catch { $doneBatchIds = @() }
      $doneBatchMode = ''
      try {
        if ($stDoneBacklog.PSObject.Properties.Name -contains 'workpack_batch_mode') { $doneBatchMode = [string]$stDoneBacklog.workpack_batch_mode }
      } catch { $doneBatchMode = '' }
      $doneIds = if ($doneBatchIds.Count -gt 0) { @($doneBatchIds) } elseif ($doneBid) { @($doneBid) } else { @() }
      if ($doneIds.Count -gt 0) {
        $doneOutcomeEvidence = New-DriverCompletionDoneEvidence -State $stDoneBacklog -Reply $visibleReply -Speaker $speaker -BridgeRoot $bridgeRoot -Channel $Channel -FastLaneDone ([bool]$fastLaneDone)
        $doneLedgerResult = Set-BacklogOutcomeDoneWithLedger -Ids $doneIds -OutcomeEvidence $doneOutcomeEvidence -BridgeRoot $bridgeRoot
        if (-not [bool]$doneLedgerResult.ok) {
          $ledgerReason = [string]$doneLedgerResult.reason
          if ([string]::IsNullOrWhiteSpace($ledgerReason)) { $ledgerReason = 'outcome_ledger_invalid' }
          # 2026-06-11 freeze-audit wave1 atom1: this block used to force CONTINUE on every close
          # attempt with NO cap — a structural evidence gap can never be cured by retrying, so one
          # task wedged the conveyor forever. Two strikes (persisted in state, survives restarts)
          # -> degrade the items to needs-review (terminal, frees the queue) and close the task.
          $ledgerBlockTaskId = [string]$stDoneBacklog.current_task_id
          if ([string]::IsNullOrWhiteSpace($ledgerBlockTaskId)) { $ledgerBlockTaskId = [string]$stDoneBacklog.current_backlog_id }
          $ledgerBlockDecision = Get-DriverOutcomeLedgerBlockDecision -State $stDoneBacklog -TaskId $ledgerBlockTaskId
          try {
            Update-State ({ param($s)
              $s | Add-Member -NotePropertyName outcome_ledger_block_count -NotePropertyValue ([int]$ledgerBlockDecision.strike) -Force
              $s | Add-Member -NotePropertyName outcome_ledger_block_task  -NotePropertyValue ([string]$ledgerBlockDecision.task_id) -Force
            }.GetNewClosure()) | Out-Null
          } catch {}
          if (-not [bool]$ledgerBlockDecision.degrade) {
            try { Set-TaskLastFailure -Kind test_failed -Text ('outcome_ledger_invalid: ' + $ledgerReason) } catch {}
            Add-Message -From system -Text ("🚫 Outcome ledger blocked backlog completion (reason=" + $ledgerReason + ", strike " + $ledgerBlockDecision.strike + "/2). Done/failed terminal statuses require reproducible evidence; continuing instead of closing.") -Kind event | Out-Null
            $plannerStatus = 'CONTINUE'
            continue
          }
          foreach ($degradeId in @($doneIds)) {
            try { Set-Idea -Id ([string]$degradeId) -Status 'needs-review' -Reason ('outcome_ledger_degraded: ' + $ledgerReason) | Out-Null } catch {}
          }
          try { Clear-TaskLastFailureKind -Kind 'test_failed' } catch {}
          Add-Message -From system -Text ("⚠ Outcome ledger blocked twice (reason=" + $ledgerReason + ") — перевожу " + (@($doneIds).Count) + " задач(и) в needs-review и закрываю задачу, чтобы освободить конвейер (freeze-audit wave1).") -Kind event | Out-Null
        }
        # 🤖 Autonomy metric (Foundation #3): the honest self-sufficiency number — autonomous backlog
        # tasks closed IN A ROW with zero operator messages between them. Increment on each autonomous
        # done; the user-message handler resets the running streak to 0 (best is preserved here).
        $doneIncrement = [Math]::Max(1, [int]$doneIds.Count)
        Update-State ({ param($s)
          $cur = 0; try { $cur = [int]$s.autonomy_streak } catch {}
          $cur += $doneIncrement
          $best = 0; try { $best = [int]$s.autonomy_streak_best } catch {}
          if ($cur -gt $best) { $best = $cur }
          $s | Add-Member -NotePropertyName autonomy_streak      -NotePropertyValue $cur  -Force
          $s | Add-Member -NotePropertyName autonomy_streak_best -NotePropertyValue $best -Force
        }.GetNewClosure()) | Out-Null
        $stk = Read-State
        $sNow = 0; try { $sNow = [int]$stk.autonomy_streak } catch {}
        $sBest = 0; try { $sBest = [int]$stk.autonomy_streak_best } catch {}
        $bestTxt = if ($sBest -gt $sNow) { " (рекорд: $sBest)" } else { '' }
        if ($doneIds.Count -gt 1 -and [string]$doneBatchMode -eq 'serial') {
          Add-Message -From system -Text ("✅ Protected serial-batch выполнен: закрыто safety/core задач бэклога: " + $doneIds.Count + ". 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        } elseif ($doneIds.Count -gt 1) {
          Add-Message -From system -Text ("✅ Workpack-batch выполнен: закрыто задач бэклога: " + $doneIds.Count + ". 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Автозадача из бэклога выполнена и закрыта. 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        }
      }
    } catch {}
    # Mark ANY self-improvement commit as a hypothesis for the 24h verdict cycle (was previously
    # only autonomous backlog tasks -> we missed user-injected tasks and Doctor fixes entirely).
    # Wave 3 widening: any task that changed HEAD vs task_base_commit gets a baseline+commit row.
    try {
      $stEnd = Read-State
      $baseC = [string]$stEnd.task_base_commit
      $headC = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
      if ($baseC -and $headC -and $baseC -ne $headC) {
        Write-Hypothesis -CommitHash $headC -TaskText ([string]$task)
      }
    } catch {}
    # 🌱 Self-dev attribution: stamp the resulting commit on a self-executed idea so the safety
    # reflex can later correlate it to the 24h verdict (worse -> auto-dampen the dial). Read-mostly.
    try {
      $stSd = Read-State
      $sdBid = [string]$stSd.current_backlog_id
      if ($sdBid) {
        $sdIdea = Get-IdeaById $sdBid
        if ($sdIdea -and ([bool]$sdIdea.self_exec)) {
          $sdHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
          if ($sdHead) { Set-IdeaSelfExec -Id $sdBid -Dial ([string]$sdIdea.self_exec_dial) -Commit $sdHead | Out-Null }
        }
      }
    } catch {}
    try { Invoke-PostTaskSelfModelRefresh -Channel $Channel -BridgeRoot $bridgeRoot | Out-Null } catch {}
    # Delivery gate shadow: evidence-only report, never blocks DONE or release.
    if ($modeBeforeIncrement -eq 'normal') {
      try {
        $stDg = Read-State
        $dgTaskId = [string]$stDg.current_task_id
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = [string]$stDg.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = 'task-' + [string]$stDg.task_start_seq }
        $dgBase = [string]$stDg.task_base_commit
        $dgHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
        $dgEvents = @(@{ text = [string]$visibleReply })
        $dgAcceptancePassed = Get-DeliveryGateAcceptanceFact `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents
        # Atom 16: preliminary facts to detect critical_bridge_self before canary.
        $dgPrelimFacts = New-DeliveryGateInputFacts `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents `
          -QaPassed $false `
          -CriticPassed $false `
          -ParsePassed $false `
          -SmokePassed $false `
          -AcceptancePassed $false `
          -CanaryPassed $false
        $dgCanaryPassed = $false
        if ([bool]$dgPrelimFacts.critical_bridge_self `
            -and -not [bool]$dgPrelimFacts.rollback_required `
            -and -not [bool]$dgPrelimFacts.destructive_patterns `
            -and -not [bool]$dgPrelimFacts.quality_bypass_detected) {
          try {
            . (Join-Path $bridgeRoot 'lib\canary.ps1')
            $dgCanaryResult = Invoke-CanaryCycle -Force -NoStateUpdate
            $dgCanaryPassed = ([bool]$dgCanaryResult.ok -eq $true) -and ([bool]$dgCanaryResult.skipped -ne $true)
          } catch {
            $dgCanaryPassed = $false
          }
        }
        $dgFacts = New-DeliveryGateInputFacts `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents `
          -QaPassed $true `
          -CriticPassed $true `
          -ParsePassed $true `
          -SmokePassed $true `
          -AcceptancePassed $dgAcceptancePassed `
          -CanaryPassed $dgCanaryPassed `
          -MemoryUpdated $true `
          -SelfModelRefreshed $true `
          -ParallelObligationOk $true
        $dgResult = Get-DeliveryGateResult -InputFacts $dgFacts
        $dgWrite = Write-DeliveryGateShadowRecord `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskId $dgTaskId `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Facts $dgFacts `
          -Result $dgResult `
          -Note 'shadow-only; no DONE/release blocking'
        $dgReason = [string]$dgResult.reason
        if ($dgReason.Length -gt 160) { $dgReason = $dgReason.Substring(0,160) + '...' }
        Add-Message -From system -Text ("🧪 Delivery gate shadow: ok=$($dgResult.ok) risk=$($dgResult.risk) release=$($dgResult.release_allowed) reason=$dgReason") -Kind event | Out-Null
        if (-not [bool]$dgWrite.ok) {
          Add-Message -From system -Text ("⚠ Delivery gate shadow write failed: " + [string]$dgWrite.error) -Kind event | Out-Null
        }
      } catch {
        try { Add-Message -From system -Text ("⚠ Delivery gate shadow failed open: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      }
    }
    # Delivery gate shadow end.
    # 🩺 If Doctor just finished a repair, restore the held task instead of going idle.
    if ([bool](Read-State).doctor_active) {
      try { Complete-Doctor } catch { try { Add-Message -From system -Text ("🩺 Complete-Doctor: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
      try { Send-PushEvent -Kind done -Text "🩺 Doctor fix shipped; resuming held task." } catch {}
      continue
    }
    try { Send-PushEvent -Kind done -Text "Задача: $(Get-PushSnippet -Text $task)" } catch {}
    Add-Message -From system -Text "✅ Задача выполнена. Жду следующую." -Kind event | Out-Null
    # Latency breakdown report
    try {
      $latSt = Read-State
      $phKeys = @('planner_ms','worker_ms','critic_ms','verify_ms','smoke_ms','restart_ms','memory_ms')
      $phVals = @{}
      foreach ($k in $phKeys) {
        $sk = "task_timing_$k"
        $v = 0L
        if ($latSt.PSObject.Properties.Name -contains $sk) { try { $v = [long]($latSt.$sk) } catch {} }
        $phVals[$k] = $v
      }
      $totalMs = 0L
      try {
        if (-not [string]::IsNullOrWhiteSpace([string]$latSt.task_timing_start_at)) {
          $startAt = [DateTime]::Parse([string]$latSt.task_timing_start_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
          $totalMs = [long]([DateTime]::UtcNow - $startAt).TotalMilliseconds
        }
      } catch {}
      $phLabels = @{ planner_ms='Планировщик'; worker_ms='Кодер'; critic_ms='Критик'; verify_ms='Проверки'; smoke_ms='Smoke'; restart_ms='Рестарт'; memory_ms='Память' }
      $sorted = @($phVals.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object { $_.Value } -Descending | Select-Object -First 3)
      if ($sorted.Count -gt 0) {
        $top3Str = ($sorted | ForEach-Object {
          $lbl = if ($phLabels.ContainsKey($_.Key)) { $phLabels[$_.Key] } else { $_.Key }
          "$lbl $([Math]::Round($_.Value/1000,1))с"
        }) -join ' › '
        Add-Message -From system -Text "⏱ Топ задержек: $top3Str" -Kind event | Out-Null
      }
      if (Get-Command Append-TaskLatencyRecord -ErrorAction SilentlyContinue) {
        $taskTextShort = if ($task.Length -gt 80) { $task.Substring(0,77) + '...' } else { $task }
        Append-TaskLatencyRecord -TaskId ([string]$latSt.current_backlog_id) -TaskTextShort $taskTextShort -TotalMs $totalMs -PhaseTimings $phVals
      }
    } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s -PreserveReflectSkip; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName task_timing_planner_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_worker_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_critic_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_verify_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_smoke_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_restart_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_memory_ms -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName task_timing_start_at -NotePropertyValue '' -Force; $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName completion_critic_result -NotePropertyValue '' -Force; $s | Add-Member -NotePropertyName completion_critic_empty_attempts -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName completion_coder_result -NotePropertyValue '' -Force; $s | Add-Member -NotePropertyName completion_coder_empty_attempts -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
}
