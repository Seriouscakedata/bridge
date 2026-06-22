#Requires -Version 5.1
# test-decision-contract.ps1 -- validator tests for the DecisionContract (slimming Atom 1).
# The validator is the deterministic gate; these prove it accepts a well-formed proposal and rejects
# malformed ones. Pure unit test, no side effects.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\decision-contract.ps1')

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond) {
  if ($cond) { $script:pass++; Write-Host ("PASS " + $name) -ForegroundColor Green }
  else { $script:fail++; Write-Host ("FAIL " + $name) -ForegroundColor Red }
}
function J($h) { return ($h | ConvertTo-Json -Depth 6) }

$good = J @{ intent='code'; risk='medium'; files=@('app/page.tsx'); dependencies=@(); parallel_groups=@(); acceptance=@('npm build green'); needs_operator=$false; confidence=0.82; rationale_short='edit one component' }
$e = [ref]$null; Check 'well-formed contract is valid' (Test-DecisionContract -Json $good -Errors $e)

$e = [ref]$null; Check 'missing intent rejected'        (-not (Test-DecisionContract -Json (J @{ risk='low'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); needs_operator=$false; confidence=0.5; rationale_short='x' }) -Errors $e))
$e = [ref]$null; Check 'bad risk enum rejected'         (-not (Test-DecisionContract -Json (J @{ intent='code'; risk='nuclear'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); needs_operator=$false; confidence=0.5; rationale_short='x' }) -Errors $e))
$e = [ref]$null; Check 'bad intent enum rejected'       (-not (Test-DecisionContract -Json (J @{ intent='launch-rockets'; risk='low'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); needs_operator=$false; confidence=0.5; rationale_short='x' }) -Errors $e))
$e = [ref]$null; Check 'confidence > 1 rejected'        (-not (Test-DecisionContract -Json (J @{ intent='code'; risk='low'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); needs_operator=$false; confidence=1.7; rationale_short='x' }) -Errors $e))
$e = [ref]$null; Check 'missing needs_operator rejected'(-not (Test-DecisionContract -Json (J @{ intent='code'; risk='low'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); confidence=0.5; rationale_short='x' }) -Errors $e))
$e = [ref]$null; Check 'missing rationale rejected'     (-not (Test-DecisionContract -Json (J @{ intent='code'; risk='low'; files=@(); dependencies=@(); parallel_groups=@(); acceptance=@(); needs_operator=$false; confidence=0.5 }) -Errors $e))
$e = [ref]$null; Check 'invalid JSON rejected'          (-not (Test-DecisionContract -Json '{ not json ' -Errors $e))

# strict-type negatives (Codex review: validator was too loose)
$e = [ref]$null; Check 'parallel_groups as array-of-strings rejected' (-not (Test-DecisionContract -Json '{"intent":"code","risk":"low","files":[],"dependencies":[],"parallel_groups":["a","b"],"acceptance":[],"needs_operator":false,"confidence":0.5,"rationale_short":"x"}' -Errors $e))
$e = [ref]$null; Check 'valid array-of-arrays parallel_groups accepted' (Test-DecisionContract -Json '{"intent":"code","risk":"low","files":["a"],"dependencies":[],"parallel_groups":[["a"],["b"]],"acceptance":["t"],"needs_operator":false,"confidence":0.5,"rationale_short":"x"}' -Errors $e)
$e = [ref]$null; Check 'needs_operator string "false" rejected' (-not (Test-DecisionContract -Json '{"intent":"code","risk":"low","files":[],"dependencies":[],"parallel_groups":[],"acceptance":[],"needs_operator":"false","confidence":0.5,"rationale_short":"x"}' -Errors $e))
$e = [ref]$null; Check 'confidence string "0.8" rejected' (-not (Test-DecisionContract -Json '{"intent":"code","risk":"low","files":[],"dependencies":[],"parallel_groups":[],"acceptance":[],"needs_operator":false,"confidence":"0.8","rationale_short":"x"}' -Errors $e))
$e = [ref]$null; Check 'files with non-string element rejected' (-not (Test-DecisionContract -Json '{"intent":"code","risk":"low","files":[1,2],"dependencies":[],"parallel_groups":[],"acceptance":[],"needs_operator":false,"confidence":0.5,"rationale_short":"x"}' -Errors $e))

# helper tests (Read/Remove)
Check 'Read-DecisionFromReply extracts block'  ((Read-DecisionFromReply -Reply 'text [[DECISION: {"intent":"code"}]] tail') -match 'intent')
Check 'Read-DecisionFromReply null when absent' ($null -eq (Read-DecisionFromReply -Reply 'no marker here'))
Check 'Remove-DecisionMarker strips block'      ((Remove-DecisionMarker -Reply 'hi [[DECISION: {"a":1}]] bye') -notmatch 'DECISION')
Check 'Remove-DecisionMarker keeps prose'       ((Remove-DecisionMarker -Reply 'keep this [[DECISION: {"a":1}]]') -match 'keep this')

# observability of the shadow logger itself (Atom 2): the signal helper exists and the logger
# never throws — even on a garbage channel it routes to Write-DecisionShadowSignal instead of dying.
Check 'Write-DecisionShadowSignal exists' ([bool](Get-Command Write-DecisionShadowSignal -ErrorAction SilentlyContinue))
Check 'Write-DecisionShadow exists'       ([bool](Get-Command Write-DecisionShadow -ErrorAction SilentlyContinue))
$threw = $false
try { Write-DecisionShadow -Channel '___nonexistent_channel___' -Stage 'unit-test' -ModelDecision $good -Note 'no-throw probe' } catch { $threw = $true }
Check 'Write-DecisionShadow does not throw on missing channel' (-not $threw)

# Intent Decision Shadow (Atom 4a): shared canon + the intent-claim writer.
Check 'canon normal->work'   ((ConvertTo-IntentCanon -Mode 'normal') -eq 'work')
Check 'canon code->work'     ((ConvertTo-IntentCanon -Mode 'code') -eq 'work')
Check 'canon discuss->discuss' ((ConvertTo-IntentCanon -Mode 'discuss') -eq 'discuss')
Check 'canon study->study'   ((ConvertTo-IntentCanon -Mode 'study') -eq 'study')
Check 'canon empty->empty'   ((ConvertTo-IntentCanon -Mode '') -eq '')
Check 'Write-IntentShadow exists' ([bool](Get-Command Write-IntentShadow -ErrorAction SilentlyContinue))
$threwI = $false
try { Write-IntentShadow -Channel '___nonexistent_channel___' -ModelPrimaryMode 'code' -ModelConfidence 0.8 -EffectiveMode 'normal' -EffectiveReason 'default-normal' -Note 'no-throw probe' } catch { $threwI = $true }
Check 'Write-IntentShadow does not throw on missing channel' (-not $threwI)

# schema is exposed for prompts/docs
Check 'schema has 9 fields' ((Get-DecisionContractSchema).Keys.Count -eq 9)

Write-Host ""
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
