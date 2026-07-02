# test-driver-dirty-salvage-plan.ps1 -- unit test for Get-DriverDirtySalvagePlan (2026-07-02 audit).
# The orphaned-dirty auto-stash used to sweep completed-but-uncommitted sibling-stream work into a
# stash (domain-filters near-loss). The salvage plan attributes dirty paths to known atoms via their
# declared touch-sets: matched -> 'commit' (salvage commit), unknown -> 'stash'. Pure function, no
# git/file IO; dot-sourcing driver\81-loop-idle-claim.ps1 only defines functions (the loop body is a
# scriptblock assignment), so this is safe with the bridge stopped.

$ErrorActionPreference = 'Stop'
$driverLib = 'C:\Users\rafie\OneDrive\Documents\bridge\driver\81-loop-idle-claim.ps1'
. $driverLib

$script:pass = 0
$script:fail = 0
function ok($c, $m) {
  if ($c) { $script:pass++; Write-Host "  ok: $m" }
  else { $script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red }
}

$atoms = @(
  [pscustomobject]@{ slug = 'domain-filters'; files = @('app/src/main/java/f/Filter.kt', 'app/src/main/java/f/FilterCatalog.kt') },
  [pscustomobject]@{ slug = 'scaffold-manifest'; files = @('app/src/main/res/values/strings.xml') }
)

# 1) dirty path exactly matching a pending atom's declared file -> commit, attributed to the atom
$plan1 = Get-DriverDirtySalvagePlan -DirtyLines @(' M app/src/main/java/f/Filter.kt') -Atoms $atoms
ok (@($plan1.entries).Count -eq 1 -and [string]$plan1.entries[0].action -eq 'commit' -and [string]$plan1.entries[0].slug -eq 'domain-filters') 'declared file -> commit with atom slug'
ok (@($plan1.commit).Count -eq 1 -and @($plan1.commit[0].paths) -contains 'app/src/main/java/f/Filter.kt') 'commit group carries the path'
ok (@($plan1.stash).Count -eq 0) 'nothing goes to stash when everything is attributed'

# 2) unknown path -> stash
$plan2 = Get-DriverDirtySalvagePlan -DirtyLines @('?? junk/tmp-notes.txt') -Atoms $atoms
ok (@($plan2.entries).Count -eq 1 -and [string]$plan2.entries[0].action -eq 'stash') 'unattributable path -> stash'
ok (@($plan2.stash) -contains 'junk/tmp-notes.txt' -and @($plan2.commit).Count -eq 0) 'stash list carries the unknown path only'

# 3) mixed: matched paths commit (grouped per atom), junk stashes
$plan3 = Get-DriverDirtySalvagePlan -DirtyLines @(
  '?? app/src/main/java/f/Filter.kt',
  ' M app/src/main/java/f/FilterCatalog.kt',
  '?? junk/leftover.log'
) -Atoms $atoms
$grp3 = @($plan3.commit | Where-Object { [string]$_.slug -eq 'domain-filters' })
ok (@($plan3.commit).Count -eq 1 -and @($grp3[0].paths).Count -eq 2) 'two matched paths grouped under one atom'
ok (@($plan3.stash).Count -eq 1 -and @($plan3.stash) -contains 'junk/leftover.log') 'junk still goes to stash in a mixed set'

# 4) collapsed untracked DIR that is the PARENT of a declared file -> commit (git status without
# -uall reports a whole new directory as one parent entry)
$plan4 = Get-DriverDirtySalvagePlan -DirtyLines @('?? app/src/main/res/') -Atoms $atoms
ok (@($plan4.entries).Count -eq 1 -and [string]$plan4.entries[0].action -eq 'commit' -and [string]$plan4.entries[0].slug -eq 'scaffold-manifest') 'collapsed parent dir of a declared file -> commit'

# 5) dirty file UNDER a declared directory touch-set -> commit
$dirAtoms = @([pscustomobject]@{ slug = 'ui-style'; files = @('app/ui/style/') })
$plan5 = Get-DriverDirtySalvagePlan -DirtyLines @('?? app/ui/style/StyleScreen.kt') -Atoms $dirAtoms
ok (@($plan5.entries).Count -eq 1 -and [string]$plan5.entries[0].action -eq 'commit' -and [string]$plan5.entries[0].slug -eq 'ui-style') 'dirty file under declared dir -> commit'

# 6) normalization: backslashes + case differences still match
$plan6 = Get-DriverDirtySalvagePlan -DirtyLines @(' M app\src\main\java\f\FILTER.KT') -Atoms $atoms
ok (@($plan6.entries).Count -eq 1 -and [string]$plan6.entries[0].action -eq 'commit') 'backslash/case-normalized path still attributed'

# 7) empty/degenerate inputs -> empty plan (fail-safe)
$plan7 = Get-DriverDirtySalvagePlan -DirtyLines @() -Atoms $atoms
$plan8 = Get-DriverDirtySalvagePlan -DirtyLines @(' M app/src/main/java/f/Filter.kt') -Atoms @()
ok (@($plan7.entries).Count -eq 0) 'no dirty lines -> empty plan'
ok (@($plan8.entries).Count -eq 1 -and [string]$plan8.entries[0].action -eq 'stash') 'no atoms -> everything stashes (old behavior)'

# 8) rename porcelain line uses the NEW path
$plan9 = Get-DriverDirtySalvagePlan -DirtyLines @('R  old/name.kt -> app/src/main/java/f/Filter.kt') -Atoms $atoms
ok (@($plan9.entries).Count -eq 1 -and [string]$plan9.entries[0].action -eq 'commit') 'rename line matched on its new path'

Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
