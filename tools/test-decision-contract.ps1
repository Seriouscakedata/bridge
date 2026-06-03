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

# schema is exposed for prompts/docs
Check 'schema has 9 fields' ((Get-DecisionContractSchema).Keys.Count -eq 9)

Write-Host ""
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
