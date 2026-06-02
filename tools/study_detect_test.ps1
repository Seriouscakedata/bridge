$ErrorActionPreference = 'Stop'
$realRoot = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $realRoot 'lib\common.ps1')

# Real existing path used for the 'local' subtype case.
$localPath = $realRoot

# Verbatim text of the false-positive backlog task this fix targets.
$bugText = 'Detect-StudyMode ложно включает study-режим, когда слово «study/изучи» — часть названия фичи, а не запрос на изучение; стоит игнорировать срабатывание для автозадач из бэклога или требовать глагол-команду в начале'

function Label($r) { if ($null -eq $r) { 'null' } else { [string]$r.subtype } }

$script:failures = 0
function Assert {
  param([string]$Name, [string]$Actual, [string]$Expected)
  if ($Actual -eq $Expected) {
    Write-Host ("PASS {0}: {1}" -f $Name, $Actual)
  } else {
    $script:failures++
    Write-Host ("FAIL {0}: expected {1}, got {2}" -f $Name, $Expected, $Actual)
  }
}

Assert 'bug-title-autonomous' (Label (Detect-StudyMode -TaskText $bugText -IsAutonomous)) 'null'
Assert 'bug-title-user'       (Label (Detect-StudyMode -TaskText $bugText)) 'null'
Assert 'user-local'          (Label (Detect-StudyMode -TaskText ('Изучи проект "' + $localPath + '"'))) 'local'
Assert 'user-external'       (Label (Detect-StudyMode -TaskText 'Изучи устройство библиотеки React Query')) 'external'
Assert 'user-izuchit'        (Label (Detect-StudyMode -TaskText 'Можешь изучить этот репозиторий и сделать отчёт')) 'external'
Assert 'feature-mention'     (Label (Detect-StudyMode -TaskText 'Почему Detect-StudyMode срабатывает на study-режим?')) 'null'
Assert 'noun-mention'        (Label (Detect-StudyMode -TaskText 'Добавь запрос на изучение фичи в бэклог')) 'null'
Assert 'autonomous-real-verb' (Label (Detect-StudyMode -TaskText '[Автозадача из бэклога] Изучи проект X' -IsAutonomous)) 'null'
Assert 'plain-eng-task'      (Label (Detect-StudyMode -TaskText 'Добавь burn-rate в UI')) 'null'

if ($script:failures -gt 0) { Write-Host ("study_detect_test: {0} FAIL" -f $script:failures); exit 1 }
Write-Host 'study_detect_test: 9/9 PASS'
