# Regression tests for the 2026-06-21 bridge speed+quality fixes:
#  - depth fast-path (intent=normal high-conf skips Deep)
#  - #2 imperative-verb backstop (code-verb without discuss-verb -> Standard)
#  - false-done handoff (Test-SynthesisImplementationRequested: implementation_plan implies code)
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-speed-quality-fixes-20260621.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\decision-synthesis.ps1')
. (Join-Path $root 'lib\decision-depth.ps1')

$script:fail = 0
function Assert($name, $got, $want) {
  if ("$got" -eq "$want") { "PASS  $name  => $got" }
  else { $script:fail++; "FAIL  $name  => got '$got' want '$want'" }
}
function D($text, $intent) { (Get-SynthesisDepthDecision -Text $text -Intent $intent).depth }

"--- depth fast-path (2d0a3e7) ---"
Assert 'normal/simple -> Simple'                  (D 'реализуй захват в live.py'                 @{primary_mode='normal';confidence=0.95;complexity='simple'})   'Simple'
Assert 'normal/moderate + обсуди-word -> Standard' (D 'обсуди и спроектируй видео-захват'          @{primary_mode='normal';confidence=0.9;complexity='moderate'})  'Standard'
Assert 'discuss -> Deep (unchanged)'              (D 'обсуди архитектуру детектора'               @{primary_mode='discuss';confidence=0.9;complexity='moderate'}) 'Deep'
Assert 'normal low-conf 0.5 -> Deep (conservative)' (D 'обсуди дизайн'                            @{primary_mode='normal';confidence=0.5;complexity='moderate'})  'Deep'

"--- #2 imperative-verb backstop (36ad9ad) ---"
Assert 'code-verb + arch-noun (discuss intent) -> Standard' (D 'реализуй новую архитектуру в live.py, коммить' @{primary_mode='discuss';confidence=0.9;complexity='moderate'}) 'Standard'
Assert 'pure discuss (no code verb) -> Deep'      (D 'обсуди архитектуру'                          @{primary_mode='discuss';confidence=0.9;complexity='moderate'}) 'Deep'
Assert 'обсуди И реализуй (both verbs) -> Deep'    (D 'обсуди и реализуй детектор'                  @{primary_mode='discuss';confidence=0.9;complexity='moderate'}) 'Deep'

"--- false-done handoff (2d0a3e7) ---"
Assert 'plan + not-operator -> implement(True)'   (Test-SynthesisImplementationRequested -Task 'обсуди и спроектируй' -Record ([pscustomobject]@{needs_operator=$false;implementation_plan=@('P0','P1')})) 'True'
Assert 'needs_operator -> hold(False)'            (Test-SynthesisImplementationRequested -Task 'x'                  -Record ([pscustomobject]@{needs_operator=$true; implementation_plan=@('P0')}))      'False'
Assert 'empty plan -> discuss(False)'             (Test-SynthesisImplementationRequested -Task 'обсуди X'           -Record ([pscustomobject]@{needs_operator=$false;implementation_plan=@()}))           'False'

""
if ($script:fail -eq 0) { "ALL PASS (10/10)" } else { "FAILURES: $($script:fail)"; exit 1 }
