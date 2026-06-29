# test-intent-computer-action.ps1 -- Test-IsComputerActionTask must NOT mis-fire a software-BUILD
# request (that merely describes a UI with кнопка/нажми) into the local computer-use fast-lane,
# while still recognising terse desktop commands. Regression for the 2026-06-29 selfie-styler bug.
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\intent.ps1')

if (-not (Get-Command Test-IsComputerActionTask -ErrorAction SilentlyContinue)) {
  Write-Host "FAIL: Test-IsComputerActionTask not visible after dot-source"; exit 1
}
$pass=0; $fail=0
function Assert {
  param([bool]$C,[string]$M)
  if ($C) { $script:pass++; Write-Host "PASS: $M" } else { $script:fail++; Write-Host "FAIL: $M" }
}

# ---- terse desktop commands: STILL computer_action (TRUE) ----
Assert (Test-IsComputerActionTask -TaskText 'нажми кнопку OK')                  "terse: нажми кнопку OK -> true"
Assert (Test-IsComputerActionTask -TaskText 'закрой это окно')                  "terse: закрой это окно -> true"
Assert (Test-IsComputerActionTask -TaskText 'кликни мышкой по иконке')          "terse: кликни мышкой -> true"
Assert (Test-IsComputerActionTask -TaskText 'close this window')                "terse: close this window -> true"
Assert (Test-IsComputerActionTask -TaskText 'move mouse to the center')         "terse: move mouse -> true"
Assert (Test-IsComputerActionTask -TaskText 'щёлкни по кнопке Сохранить')       "terse: щёлкни по кнопке -> true"

# ---- software BUILD requests describing a UI: NOT computer_action (FALSE) ----
$selfie = @'
Построй Android-приложение Selfie Styler. На старте полноэкранная фронтальная камера с одной большой круглой кнопкой «Фото». По нажатию приложение снимает кадр и отправляет в Gemini. Экран результата: картинка, подпись «Стиль», кнопка «Сохранить» и кнопка «Ещё раз».
'@
Assert (-not (Test-IsComputerActionTask -TaskText $selfie))                     "build: full selfie spec (button/tap) -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'Построй Android-приложение с кнопкой Фото')) "build: построй приложение с кнопкой -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'Сделай приложение, где по нажатию открывается камера')) "build: сделай приложение + нажатие -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'Создай экран с кнопкой входа и обработай клик')) "build: создай экран + кнопка/клик -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'build an app with a photo button that the user taps')) "build(en): build app with photo button -> false"

# ---- excluded / non-UI: FALSE ----
Assert (-not (Test-IsComputerActionTask -TaskText 'удали этот файл, нажми кнопку'))  "excluded: удали ... -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'сделай скриншот экрана'))         "non-UI: скриншот (fast, no UI verb) -> false"
Assert (-not (Test-IsComputerActionTask -TaskText 'покажи логи'))                    "non-UI: покажи логи -> false"
# long text with a UI verb but no build-intent: length guard -> false (use [[ЛАПА]] for long flows)
$longflow = 'открой браузер и перейди на сайт, потом найди поле поиска и введи туда длинный запрос про погоду в разных городах мира на следующую неделю и нажми кнопку поиска несколько раз подряд для проверки стабильности интерфейса приложения под нагрузкой'
Assert (-not (Test-IsComputerActionTask -TaskText $longflow))                        "length guard: long UI flow (>200) -> false"

Write-Host ""
Write-Host ("RESULT: pass=$pass fail=$fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
