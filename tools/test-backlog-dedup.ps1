# test-backlog-dedup.ps1 -- deterministic backlog dedup/supersede tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog-governor.ps1')
. (Join-Path $bridgeRoot 'lib\backlog-dedup.ps1')

$script:pass = 0
$script:fail = 0

function Assert-BacklogDedup {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function New-DedupItem {
  param(
    [string]$Id,
    [string]$Slug,
    [string]$RootCauseKey,
    [object[]]$TouchSet,
    [string]$Status = 'approved',
    [string]$Ts = ''
  )
  $item = [pscustomobject][ordered]@{
    id = $Id
    status = $Status
    slug = $Slug
    title = "Task $Id"
    text = "Implement deterministic task $Id"
    touch_set = @($TouchSet)
    root_cause_key = $RootCauseKey
  }
  if (-not [string]::IsNullOrWhiteSpace($Ts)) {
    $item | Add-Member -NotePropertyName ts -NotePropertyValue $Ts -Force
  }
  return $item
}

function Get-ItemById {
  param([object[]]$Items, [string]$Id)
  return @($Items | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

try {
  Assert-BacklogDedup 'slug normalization' ((Normalize-BacklogDedupSlug -Slug ' Provider_Task ') -eq 'provider-task')
  Assert-BacklogDedup 'root_cause_key normalization' ((Normalize-BacklogDedupRootCauseKey -RootCauseKey ' Provider:Flow  Key ') -eq 'provider:flow key')

  $oldSlug = New-DedupItem -Id 'old-slug' -Slug 'provider_task' -RootCauseKey 'dedup:old-slug' -TouchSet @('lib/a.ps1')
  $newSlug = New-DedupItem -Id 'new-slug' -Slug 'provider-task' -RootCauseKey 'dedup:new-slug' -TouchSet @('lib/b.ps1')
  $slugRun = Invoke-BacklogDeterministicSupersede -Items @($oldSlug,$newSlug) -Root $bridgeRoot
  Assert-BacklogDedup 'slug duplicate drops older' (
    [string]$oldSlug.status -eq 'auto-dropped' -and [string]$oldSlug.superseded_by -eq 'new-slug' -and [string]$oldSlug.superseded_reason -eq 'slug'
  ) ($oldSlug | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogDedup 'slug duplicate keeps newer approved' ([string]$newSlug.status -eq 'approved') ($newSlug | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogDedup 'dropped slug duplicate not returned approved' (
    @($slugRun.approved | Where-Object { [string]$_.id -eq 'old-slug' }).Count -eq 0
  ) ($slugRun.approved | ConvertTo-Json -Compress -Depth 8)

  $oldRoot = New-DedupItem -Id 'old-root' -Slug 'root-a' -RootCauseKey 'Provider:QueueGovernor' -TouchSet @('lib/root-a.ps1')
  $newRoot = New-DedupItem -Id 'new-root' -Slug 'root-b' -RootCauseKey ' provider:queuegovernor ' -TouchSet @('lib/root-b.ps1')
  $rootRun = Invoke-BacklogDeterministicSupersede -Items @($oldRoot,$newRoot) -Root $bridgeRoot
  Assert-BacklogDedup 'root_cause_key duplicate drops older' (
    [string]$oldRoot.status -eq 'auto-dropped' -and [string]$oldRoot.superseded_by -eq 'new-root' -and [string]$oldRoot.superseded_reason -eq 'root_cause_key'
  ) ($oldRoot | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogDedup 'root duplicate evidence records pair' (
    @($rootRun.duplicate_pairs | Where-Object { [string]$_.reason -eq 'root_cause_key' -and [string]$_.newer_id -eq 'new-root' }).Count -eq 1
  ) ($rootRun.duplicate_pairs | ConvertTo-Json -Compress -Depth 8)

  $oldTouch = New-DedupItem -Id 'old-touch' -Slug 'touch-a' -RootCauseKey 'dedup:touch-a' -TouchSet @('LIB\Provider')
  $newTouch = New-DedupItem -Id 'new-touch' -Slug 'touch-b' -RootCauseKey 'dedup:touch-b' -TouchSet @('./lib/provider/adapter.ps1')
  $touchRun = Invoke-BacklogDeterministicSupersede -Items @($oldTouch,$newTouch) -Root $bridgeRoot
  Assert-BacklogDedup 'normalized touch_set overlap drops older' (
    [string]$oldTouch.status -eq 'auto-dropped' -and [string]$oldTouch.superseded_by -eq 'new-touch' -and [string]$oldTouch.superseded_reason -eq 'touch_set'
  ) ($oldTouch | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogDedup 'touch_set duplicate not returned approved' (
    @($touchRun.approved | Where-Object { [string]$_.id -eq 'old-touch' }).Count -eq 0
  ) ($touchRun.approved | ConvertTo-Json -Compress -Depth 8)

  $staleApproved = New-DedupItem -Id 'stale-approved' -Slug 'stale-approved' -RootCauseKey 'dedup:stale-approved' -TouchSet @('lib/stale-approved.ps1')
  $staleApproved | Add-Member -NotePropertyName superseded_by -NotePropertyValue 'newer-stale' -Force
  $staleApproved | Add-Member -NotePropertyName superseded_reason -NotePropertyValue 'slug' -Force
  $cleanApproved = New-DedupItem -Id 'clean-approved' -Slug 'clean-approved' -RootCauseKey 'dedup:clean-approved' -TouchSet @('lib/clean-approved.ps1')
  $approvedSurvivors = @(Get-BacklogDeterministicApprovedItems -Items @($staleApproved,$cleanApproved))
  Assert-BacklogDedup 'superseded metadata excludes stale approved survivor' (
    @($approvedSurvivors | Where-Object { [string]$_.id -eq 'stale-approved' }).Count -eq 0 -and
    @($approvedSurvivors | Where-Object { [string]$_.id -eq 'clean-approved' }).Count -eq 1
  ) ($approvedSurvivors | ConvertTo-Json -Compress -Depth 8)

  $providerRootOld = New-DedupItem -Id 'provider-root-old' -Slug 'provider-backed-one' -RootCauseKey 'provider:story-flow' -TouchSet @('slopvid/provider.py')
  $providerRootNew = New-DedupItem -Id 'provider-root-new' -Slug 'provider-backed-two' -RootCauseKey 'PROVIDER:STORY-FLOW' -TouchSet @('slopvid/story.py')
  Invoke-BacklogDeterministicSupersede -Items @($providerRootOld,$providerRootNew) -Root $bridgeRoot | Out-Null
  Assert-BacklogDedup 'provider style duplicate caught by root_cause_key' (
    [string]$providerRootOld.status -eq 'auto-dropped' -and [string]$providerRootOld.superseded_reason -eq 'root_cause_key'
  ) ($providerRootOld | ConvertTo-Json -Compress -Depth 8)

  $providerTouchOld = New-DedupItem -Id 'provider-touch-old' -Slug 'provider-touch-one' -RootCauseKey 'provider:touch-one' -TouchSet @('SLOPVID\provider')
  $providerTouchNew = New-DedupItem -Id 'provider-touch-new' -Slug 'provider-touch-two' -RootCauseKey 'provider:touch-two' -TouchSet @('slopvid/provider/story_provider.py')
  Invoke-BacklogDeterministicSupersede -Items @($providerTouchOld,$providerTouchNew) -Root $bridgeRoot | Out-Null
  Assert-BacklogDedup 'provider style duplicate caught by touch_set overlap' (
    [string]$providerTouchOld.status -eq 'auto-dropped' -and [string]$providerTouchOld.superseded_reason -eq 'touch_set'
  ) ($providerTouchOld | ConvertTo-Json -Compress -Depth 8)

  $openA = New-DedupItem -Id 'open-a' -Slug 'open-a' -RootCauseKey 'dedup:open-a' -TouchSet @('lib/open-a.ps1')
  $openB = New-DedupItem -Id 'open-b' -Slug 'open-b' -RootCauseKey 'dedup:open-b' -TouchSet @('tools/open-b.ps1')
  $openRun = Invoke-BacklogDeterministicSupersede -Items @($openA,$openB) -Root $bridgeRoot
  Assert-BacklogDedup 'non-overlapping tasks preserved' (
    [string]$openA.status -eq 'approved' -and [string]$openB.status -eq 'approved' -and @($openRun.approved).Count -eq 2
  ) ($openRun | ConvertTo-Json -Compress -Depth 8)

  $datedNew = New-DedupItem -Id 'dated-new' -Slug 'dated-task' -RootCauseKey 'dedup:dated-new' -TouchSet @('lib/dated-new.ps1') -Ts '2026-02-01T00:00:00Z'
  $datedOld = New-DedupItem -Id 'dated-old' -Slug 'dated-task' -RootCauseKey 'dedup:dated-old' -TouchSet @('lib/dated-old.ps1') -Ts '2026-01-01T00:00:00Z'
  Invoke-BacklogDeterministicSupersede -Items @($datedNew,$datedOld) -Root $bridgeRoot | Out-Null
  Assert-BacklogDedup 'timestamp newer supersedes older even if array order differs' (
    [string]$datedOld.status -eq 'auto-dropped' -and [string]$datedOld.superseded_by -eq 'dated-new' -and [string]$datedNew.status -eq 'approved'
  ) (@($datedNew,$datedOld) | ConvertTo-Json -Compress -Depth 8)

  $stableOld = New-DedupItem -Id 'stable-old' -Slug 'stable-task' -RootCauseKey 'dedup:stable-old' -TouchSet @('lib/stable-old.ps1')
  $stableNew = New-DedupItem -Id 'stable-new' -Slug 'stable-task' -RootCauseKey 'dedup:stable-new' -TouchSet @('lib/stable-new.ps1')
  Invoke-BacklogDeterministicSupersede -Items @($stableOld,$stableNew) -Root $bridgeRoot | Out-Null
  Assert-BacklogDedup 'stable array order supersedes older when dates absent' (
    [string]$stableOld.status -eq 'auto-dropped' -and [string]$stableOld.superseded_by -eq 'stable-new'
  ) (@($stableOld,$stableNew) | ConvertTo-Json -Compress -Depth 8)

  $moduleText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\backlog-dedup.ps1') -Raw -Encoding UTF8
  $m = [regex]::Match($moduleText, '(?s)#region Deterministic backlog supersede helpers(?<body>.*?)#endregion Deterministic backlog supersede helpers')
  $body = if ($m.Success) { [string]$m.Groups['body'].Value } else { '' }
  $forbidden = @('Save-Backlog','Write-BacklogJsonLine','Set-Content','Out-File','New-Item','Remove-Item','Get-Embedding','Get-CosineSimilarity','Test-IdeaShouldKeep')
  $foundForbidden = @($forbidden | Where-Object { $body -like ('*' + $_ + '*') })
  Assert-BacklogDedup 'deterministic helper has no write or legacy advisory tokens' (
    $m.Success -and $foundForbidden.Count -eq 0
  ) ($foundForbidden -join ', ')
  Assert-BacklogDedup 'deterministic evidence marks semantic similarity as advisory metadata only' (
    @($slugRun.evidence.advisory_metadata | Where-Object { [string]$_ -eq 'semantic_similarity' }).Count -eq 1 -and
    @($slugRun.evidence.duplicate_rules | Where-Object { [string]$_ -eq 'slug' -or [string]$_ -eq 'root_cause_key' -or [string]$_ -eq 'touch_set' }).Count -eq 3
  ) ($slugRun.evidence | ConvertTo-Json -Compress -Depth 8)
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
}

Write-Host ("Backlog Dedup tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
