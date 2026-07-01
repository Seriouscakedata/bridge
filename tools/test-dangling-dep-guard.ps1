# Dangling-dep guard unit test (2026-07-01). A project-autopilot atom whose depends_on references a slug
# that was never emitted (absent from the backlog) must NOT block forever -> the frontier drops the dangling
# edge (dropped_dangling) so the dependent stays runnable. Present-but-not-done deps still block; non-autopilot
# items keep strict '(missing)'. Isolated (mocks), safe with the bridge running.
$ErrorActionPreference='Stop'
$lib='C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog-workpack.ps1'
. $lib
if (-not (Get-Command Get-BacklogPackObjectValue -EA SilentlyContinue)) {
  function Get-BacklogPackObjectValue { param($Obj,$Name,$Default=$null)
    if ($null -eq $Obj) { return $Default }
    $p=$Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $Default }
}
if (-not (Get-Command Get-BacklogTaskDependencySlugs -EA SilentlyContinue)) {
  function Get-BacklogTaskDependencySlugs { param($Item) @($Item.depends_on) }
}
$script:pass=0;$script:fail=0
function ok($c,$m){ if($c){$script:pass++; Write-Host "  ok: $m"} else {$script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red} }

# status map: scaffold done, viewmodel approved. domain-filter is ABSENT (never emitted).
$map=@{ 'ch1-scaffold'='done'; 'ch1-viewmodel'='approved' }

# 1) autopilot atom, dep on absent slug + a done slug -> ready (dangling dropped)
$vm=[pscustomobject]@{ from='project-autopilot'; slug='ch1-viewmodel'; depends_on=@('ch1-domain-filter','ch1-scaffold') }
$r=Test-BacklogTaskDependenciesReady -Item $vm -StatusBySlug $map
ok ($r.ready) 'autopilot: absent dep dropped, real done dep satisfied -> ready=true'
ok (@($r.dropped_dangling) -contains 'ch1-domain-filter') 'autopilot: dangling slug recorded in dropped_dangling'
ok (@($r.unmet).Count -eq 0) 'autopilot: no unmet when only-absent+done deps'

# 2) autopilot atom, dep on a PRESENT-but-not-done slug -> still blocks
$lt=[pscustomobject]@{ from='project-autopilot'; slug='ch1-launch-test'; depends_on=@('ch1-viewmodel') }
$r2=Test-BacklogTaskDependenciesReady -Item $lt -StatusBySlug $map
ok (-not $r2.ready) 'autopilot: present-but-approved dep still blocks (ready=false)'
ok (@($r2.dropped_dangling).Count -eq 0) 'autopilot: present dep is NOT treated as dangling'

# 3) autopilot atom, all deps done -> ready
$map2=@{ 'ch1-scaffold'='done'; 'ch1-viewmodel'='done' }
$r3=Test-BacklogTaskDependenciesReady -Item $lt -StatusBySlug $map2
ok ($r3.ready) 'autopilot: all deps done -> ready=true'

# 4) NON-autopilot atom, absent dep -> strict, still blocks (unchanged)
$ext=[pscustomobject]@{ from='claude'; slug='x'; depends_on=@('never-emitted') }
$r4=Test-BacklogTaskDependenciesReady -Item $ext -StatusBySlug $map
ok (-not $r4.ready) 'non-autopilot: absent dep still blocks (strict, unchanged)'
ok (@($r4.unmet) -contains 'never-emitted(missing)') 'non-autopilot: absent dep reported as (missing)'

# 5) terminal-failed present dep still surfaced
$tf=New-Object 'System.Collections.Generic.HashSet[string]'; [void]$tf.Add('ch1-viewmodel')
$r5=Test-BacklogTaskDependenciesReady -Item $lt -StatusBySlug $map -TerminalFailedSlugs $tf
ok (@($r5.terminal_failed).Count -ge 1) 'terminal-failed present dep still reported'

# 6) no deps -> ready
$r6=Test-BacklogTaskDependenciesReady -Item ([pscustomobject]@{from='project-autopilot';slug='s';depends_on=@()}) -StatusBySlug $map
ok ($r6.ready) 'no deps -> ready=true'

Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
