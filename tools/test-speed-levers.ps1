param()
$ErrorActionPreference='Stop'
. "C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1" *> $null
$fail=0
function A($cond,$msg){ if($cond){ "  OK  $msg" } else { $script:fail++; "  FAIL $msg" } }

"== docs-only predicate =="
A ((Test-ProjectAutopilotAtomDocsOnly -Paths @('docs/x.md','README_RU.md')) -eq $true)  "docs+_RU.md => docs-only"
A ((Test-ProjectAutopilotAtomDocsOnly -Paths @('memory/notes.md')) -eq $true)            "memory/*.md => docs-only"
A ((Test-ProjectAutopilotAtomDocsOnly -Paths @('app/src/Main.kt','docs/x.md')) -eq $false) "mixed code+docs => NOT docs-only"
A ((Test-ProjectAutopilotAtomDocsOnly -Paths @('app/build.gradle.kts')) -eq $false)      "kts => NOT docs-only"
A ((Test-ProjectAutopilotAtomDocsOnly -Paths @()) -eq $false)                            "empty => NOT docs-only (conservative)"

"== config defaults (must be OFF = default-safe) =="
$c = Get-ProjectAutopilotConfig
A ($c.skipBuildOnDocsOnly -eq $false) "skipBuildOnDocsOnly default false"
A ($c.cleanFileOwnership -eq $false)  "cleanFileOwnership default false"

"== cleanFileOwnership repair: flag OFF (default) leaves partial-overlap atoms UNCHANGED =="
$mk = { @(
  [pscustomobject]@{ slug='login-screen';    files=@('app/ui/MainUiState.kt','app/ui/LoginScreen.kt') },
  [pscustomobject]@{ slug='home-screen';     files=@('app/ui/MainUiState.kt','app/ui/HomeScreen.kt') },
  [pscustomobject]@{ slug='settings-screen'; files=@('app/ui/MainUiState.kt','app/ui/SettingsScreen.kt') }
) }
$off = Repair-ProjectAutopilotAtomFileOwnership -Tasks (& $mk)
$offLogin = $off | Where-Object { $_.slug -eq 'login-screen' }
A (@($offLogin.files).Count -eq 2) "flag OFF: god-file NOT stripped (2 files kept)"

"== cleanFileOwnership repair: flag ON strips the shared god-file, keeps each atom's own file =="
function Get-ProjectAutopilotConfig { [pscustomobject]@{ cleanFileOwnership = $true } }
$on = Repair-ProjectAutopilotAtomFileOwnership -Tasks (& $mk)
foreach($a in $on){ "    $($a.slug): [$(@($a.files) -join ', ')]" }
$onLogin = $on | Where-Object { $_.slug -eq 'login-screen' }
$onHome  = $on | Where-Object { $_.slug -eq 'home-screen' }
A (@($onLogin.files).Count -eq 1 -and ($onLogin.files[0] -like '*LoginScreen.kt')) "login keeps ONLY LoginScreen.kt"
A (@($onHome.files).Count -eq 1 -and ($onHome.files[0] -like '*HomeScreen.kt'))    "home keeps ONLY HomeScreen.kt"
A (-not (@($onLogin.files) -match 'MainUiState')) "god-file MainUiState.kt dropped from login"

"== summary =="
if($fail -eq 0){ "ALL PASS" } else { "FAILURES: $fail"; exit 1 }
