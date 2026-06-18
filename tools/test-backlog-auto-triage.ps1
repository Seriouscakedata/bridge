#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

function Assert {
  param([string]$Name, [bool]$Condition)
  if ($Condition) { Write-Host "PASS: $Name"; $script:pass++ }
  else { Write-Host "FAIL: $Name"; $script:fail++ }
}

. (Join-Path $BridgeRoot 'lib\backlog-core.ps1')

$controlPlane = [pscustomobject]@{
  text = @'
Task: Add guard.
Files: lib/backlog-core.ps1, tools/test-backlog-auto-triage.ps1
Acceptance: ParseFile OK.
'@
}
$cpDecision = Test-BacklogAutoTriageDecision -Item $controlPlane
Assert 'control-plane is canary or escalate' (@('canary','escalate') -contains [string]$cpDecision.decision)
Assert 'control-plane is never approve' ([string]$cpDecision.decision -ne 'approve')
Assert 'control-plane flag true' ([bool]$cpDecision.touches_control_plane)

$destructive = [pscustomobject]@{
  text = 'Task: bypass gate and delete auth.json. Files: docs/a.md Acceptance: blocked.'
}
$destructiveDecision = Test-BacklogAutoTriageDecision -Item $destructive
Assert 'destructive keyword escalates' ([string]$destructiveDecision.decision -eq 'escalate')
Assert 'destructive keyword is high risk' ([string]$destructiveDecision.risk -eq 'high')

$clean = [pscustomobject]@{
  text = @'
Task: update docs.
Files: docs/triage.md
Acceptance: docs mention deterministic triage.
'@
}
$cleanDecision = Test-BacklogAutoTriageDecision -Item $clean
Assert 'clean non-control-plane approves' ([string]$cleanDecision.decision -eq 'approve')
Assert 'clean non-control-plane risk low' ([string]$cleanDecision.risk -eq 'low')

$junk = [pscustomobject]@{
  text = 'Task: maybe improve something later.'
}
$junkDecision = Test-BacklogAutoTriageDecision -Item $junk
Assert 'junk without files rejects' ([string]$junkDecision.decision -eq 'reject')
Assert 'junk risk low' ([string]$junkDecision.risk -eq 'low')

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
