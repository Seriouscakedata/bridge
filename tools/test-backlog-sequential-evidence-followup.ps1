#Requires -Version 5.1
# Regression coverage for sequential completion updating backlog actual files
# and filing wiring-gap follow-up items.

$ErrorActionPreference = 'Stop'

$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'driver\86-loop-completion-cleanup.ps1')

$script:pass = 0
$script:fail = 0
$script:testRepo = ''
$script:testBacklog = @()

function Check-SequentialEvidenceFollowup {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    Write-Host ("FAIL " + $Name + " " + [string]$Detail) -ForegroundColor Red
  }
}

function Invoke-TestGit {
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string[]]$GitArgs
  )

  $gitErrFile = [System.IO.Path]::GetTempFileName()
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $out = @(& git -C $Repo @GitArgs 2> $gitErrFile)
    $exit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exit -ne 0) {
      $err = ''
      try { $err = [System.IO.File]::ReadAllText($gitErrFile, [System.Text.Encoding]::UTF8) } catch { $err = '' }
      throw ("git " + ($GitArgs -join ' ') + " failed: " + ((@($out) + @($err) -join ' ') -replace '\s+', ' ').Trim())
    }
    return @($out)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    Remove-Item -LiteralPath $gitErrFile -Force -ErrorAction SilentlyContinue
  }
}

function New-SequentialEvidenceRepo {
  $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-seq-evidence-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('init') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('config','user.email','bridge-test@example.invalid') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('config','user.name','Bridge Test') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $repo 'lib') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repo 'README.md'), "baseline`n", [System.Text.Encoding]::ASCII)
  Invoke-TestGit -Repo $repo -GitArgs @('add','--','README.md') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('commit','-m','baseline') | Out-Null
  $base = ((Invoke-TestGit -Repo $repo -GitArgs @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
  [System.IO.File]::WriteAllText((Join-Path $repo 'lib\wiring.ps1'), "function Invoke-TestWiring { 'ok' }`n", [System.Text.Encoding]::ASCII)
  Invoke-TestGit -Repo $repo -GitArgs @('add','--','lib/wiring.ps1') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('commit','-m','add wiring helper') | Out-Null
  $head = ((Invoke-TestGit -Repo $repo -GitArgs @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
  return [pscustomobject]@{ Repo = $repo; Base = $base; Head = $head }
}

function Get-TaskRepoRoot {
  return $script:testRepo
}

function Invoke-BacklogLocked {
  param([Parameter(Mandatory=$true)][scriptblock]$ScriptBlock)
  return (& $ScriptBlock)
}

function Get-Backlog {
  return @($script:testBacklog)
}

function Save-Backlog {
  param([Parameter(Mandatory=$true)]$Items)
  $script:testBacklog = @($Items)
}

$case = New-SequentialEvidenceRepo
$script:testRepo = $case.Repo
try {
  $script:testBacklog = @(
    [pscustomobject][ordered]@{
      id = 'seq-item'
      status = 'running'
      title = 'Synthetic sequential backlog item'
      files = @('declared-only.md')
      text = 'Synthetic task'
    }
  )

  $state = [pscustomobject][ordered]@{ task_base_commit = $case.Base }
  $reply = @'
[[PROJECT_RISK: built-but-not-wired evidence: helper exists but live completion path has a wiring gap]]
[[VERIFIED: focused regression PASS]]
'@
  $evidence = New-DriverCompletionDoneEvidence -State $state -Reply $reply -Speaker 'codex' -BridgeRoot $case.Repo -Channel 'main'
  $result1 = Set-BacklogOutcomeDoneWithLedger -Ids @('seq-item') -OutcomeEvidence $evidence -BridgeRoot $bridgeRoot
  $result2 = Set-BacklogOutcomeDoneWithLedger -Ids @('seq-item') -OutcomeEvidence $evidence -BridgeRoot $bridgeRoot

  $source = $script:testBacklog | Where-Object { [string]$_.id -eq 'seq-item' } | Select-Object -First 1
  $followups = @($script:testBacklog | Where-Object { [string]$_.followup_of -eq 'seq-item' -and [string]$_.followup_kind -eq 'wiring-gap' })
  $sourceFiles = @($source.files | ForEach-Object { [string]$_ })
  $sourceActual = @($source.actual_files | ForEach-Object { [string]$_ })
  $evFiles = @($source.done_evidence.actual_files | ForEach-Object { [string]$_ })

  Check-SequentialEvidenceFollowup 'git evidence records actual changed file' (@($evidence.actual_files) -contains 'lib/wiring.ps1') ($evidence | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'backlog item is marked done' ([string]$source.status -eq 'done') ($source | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'backlog item files are replaced with actual git diff files' ($sourceFiles.Count -eq 1 -and $sourceFiles[0] -eq 'lib/wiring.ps1') ($source | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'done evidence stores actual files' ($evFiles.Count -eq 1 -and $evFiles[0] -eq 'lib/wiring.ps1') ($source.done_evidence | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'declared files are preserved for audit' (@($source.declared_files_before_done) -contains 'declared-only.md') ($source | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'wiring gap creates one open follow-up' ($followups.Count -eq 1 -and [string]$followups[0].status -eq 'open') ($followups | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'follow-up carries concrete actual files' (@($followups[0].files) -contains 'lib/wiring.ps1') ($followups[0] | ConvertTo-Json -Compress -Depth 8)
  Check-SequentialEvidenceFollowup 'second run does not duplicate follow-up' (@($result1.followup_ids).Count -eq 1 -and @($result2.followup_ids).Count -eq 1 -and $followups.Count -eq 1) (($result1 | ConvertTo-Json -Compress -Depth 8) + ' :: ' + ($result2 | ConvertTo-Json -Compress -Depth 8))
} finally {
  if (Test-Path -LiteralPath $case.Repo) {
    Remove-Item -LiteralPath $case.Repo -Recurse -Force
  }
}

Write-Host ("Sequential evidence follow-up tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
