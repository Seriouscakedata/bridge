# Loop-completion actions: critic, self-model refresh, and project-autopilot outcome hooks.
function Invoke-PostTaskSelfModelRefresh {
  [CmdletBinding()]
  param(
    [string]$Channel,
    [string]$BridgeRoot
  )

  $result = [ordered]@{
    attempted = $false
    ok        = $false
    skipped   = $false
    error     = ''
  }

  function Write-PostTaskSelfModelRefreshFailure {
    param([string]$Message)

    try {
      if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
        Add-Message -From system -Text ("⚠ Self-model refresh skipped/failed: " + $Message) -Kind event | Out-Null
      }
    } catch {}
    try {
      $logRoot = $BridgeRoot
      if ([string]::IsNullOrWhiteSpace($logRoot)) { $logRoot = (Get-Location).Path }
      Add-Content -LiteralPath (Join-Path $logRoot 'self-model-refresh.log') -Value ((Get-Date).ToString('s') + '  post-task-refresh: ' + $Message) -Encoding UTF8
    } catch {}
  }

  try {
    $effectiveChannel = [string]$Channel
    if ([string]::IsNullOrWhiteSpace($effectiveChannel)) {
      try {
        if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
          $effectiveChannel = [string](Get-EffectiveChannel)
        }
      } catch {}
    }
    if ($effectiveChannel -ne 'main') {
      $result.skipped = $true
      $result.error = 'channel is not main'
      return [pscustomobject]$result
    }

    $root = [string]$BridgeRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
      try { $root = Split-Path -Parent $PSScriptRoot } catch { $root = (Get-Location).Path }
    }
    $refreshTool = Join-Path $root 'tools\refresh-self-model.ps1'
    if (-not (Test-Path -LiteralPath $refreshTool)) {
      $result.skipped = $true
      $result.error = 'refresh tool missing'
      Write-PostTaskSelfModelRefreshFailure -Message $result.error
      return [pscustomobject]$result
    }

    $result.attempted = $true
    & $refreshTool -BridgeRoot $root -NoOutput | Out-Null
    $result.ok = $true
    return [pscustomobject]$result
  } catch {
    $result.error = $_.Exception.Message
    Write-PostTaskSelfModelRefreshFailure -Message $result.error
    return [pscustomobject]$result
  }
}

$script:DriverLoopCompletionCriticActionsBlock = {
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    # Независимый критик: перед закрытием ревьюим git-дифф задачи на другой модели.
    # Серьёзное -> возврат Codex на доработку; сбои критика не блокируют завершение.
    try {
      $stC = Read-State
      if ([bool]$stC.task_did_actions) {
        if ([bool]$stC.skip_critic) {
          Add-Message -From system -Text "⏭ Critic пропущен (fast-lane)" -Kind event | Out-Null
        } else {
        $criticMaxRetries = 2
        try { $cfgCr = Get-BridgeConfig; if ($cfgCr.PSObject.Properties.Name -contains 'criticMaxRetries') { $criticMaxRetries = [int]$cfgCr.criticMaxRetries } } catch {}
        $crc  = [int]$stC.critic_retry_count
        $base = [string]$stC.task_base_commit
        $criticRepoRoot = Get-TaskRepoRoot
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          $baseOkForCritic = $false
          try {
            $baseTypeForCritic = (& git -C $criticRepoRoot cat-file -t $base 2>$null | Select-Object -First 1)
            if ([string]$baseTypeForCritic -eq 'commit') { $baseOkForCritic = $true }
          } catch {}
          if (-not $baseOkForCritic) { $base = '' }
        }
        $diff = ''
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          try { $diff = (& git -C $criticRepoRoot diff $base -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if ([string]::IsNullOrWhiteSpace($diff)) {
          try { $diff = (& git -C $criticRepoRoot diff HEAD -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($diff)) {
          if ($crc -ge $criticMaxRetries) {
            Add-Message -From system -Text "🔎 Критик: лимит доработок ($criticMaxRetries) исчерпан — закрываю задачу как есть, нужно внимание оператора." -Kind event | Out-Null
            try { Send-PushEvent -Kind need_you -Text "Критик исчерпал лимит доработок: $(Get-PushSnippet -Text $task)" } catch {}
          } else {
            $llmCfg = $null
            try { $llmCfg = Get-LLMConfig } catch {}
            $criticLight = if ($llmCfg -and $llmCfg.ContainsKey('critic')) { [string]$llmCfg['critic'] } else { 'deepseek-v4-flash' }
            $criticHeavy = if ($llmCfg -and $llmCfg.ContainsKey('criticHeavy')) { [string]$llmCfg['criticHeavy'] } else { 'deepseek-v4-pro' }
            $diffNames = @()
            try {
              if (-not [string]::IsNullOrWhiteSpace($base)) { $diffNames = @(& git -C $criticRepoRoot diff --name-only $base -- 2>$null) }
              if (@($diffNames).Count -eq 0) { $diffNames = @(& git -C $criticRepoRoot diff --name-only HEAD -- 2>$null) }
            } catch {}
            $linesChanged = 0
            try {
              $numstat = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $numstat = @(& git -C $criticRepoRoot diff --numstat $base -- 2>$null) }
              if (@($numstat).Count -eq 0) { $numstat = @(& git -C $criticRepoRoot diff --numstat HEAD -- 2>$null) }
              foreach ($lnStat in @($numstat)) {
                $parts = @(([string]$lnStat) -split '\s+')
                if ($parts.Count -ge 2) {
                  $adds = 0; $dels = 0
                  [int]::TryParse($parts[0], [ref]$adds) | Out-Null
                  [int]::TryParse($parts[1], [ref]$dels) | Out-Null
                  $linesChanged += ($adds + $dels)
                }
              }
            } catch {}
            $heavyRegex = '(?i)security|auth|secret|crypto|race|mutex|lock|concurr(en|ency)?|sql\s*injection|inject(ion)?|csrf|xss'
            # 2026-06-11 Q2: PATH trigger — a 1-file/80-line control-plane diff with none of the
            # keyword matches was reviewed by the light non-thinking model, exactly where a false
            # green costs the most (rollbacks, dirty-guard wedges). Control-plane paths now always
            # get the heavy critic.
            $controlPlanePathRegex = '(?i)^(driver/|driver\.ps1|supervisor\.ps1|watchdog\.ps1|server\.ps1|lib/(backlog|parallel|supervisor|watchdog|llm|agent-wait|common|doctor|verify-selftest|policy))'
            $touchesControlPlanePath = $false
            foreach ($dn in @($diffNames)) {
              if ((([string]$dn).Trim() -replace '\\','/') -match $controlPlanePathRegex) { $touchesControlPlanePath = $true; break }
            }
            $isHeavyCritic = (@($diffNames).Count -gt 3) -or ($linesChanged -gt 100) -or ($diff -match $heavyRegex) -or $touchesControlPlanePath
            $crcNow = 0
            try { $crcNow = [int](Read-State).critic_retry_count } catch {}
            if ($crcNow -ge 1) { $isHeavyCritic = $true }
            $criticModelName = if ($isHeavyCritic) { $criticHeavy } else { $criticLight }

            # 2026-05-27: deterministic CLI-flag check BEFORE the LLM critic.
            # The LLM critic (deepseek) approved a non-existent --cwd flag for
            # claude.exe in the prior Wave-C-tails task because it has no way
            # to run the CLI. This pre-check actually invokes `cli --help` and
            # rejects diffs that introduce unknown flags. Findings here are
            # treated as serious and prepended to LLM issues -- they cannot be
            # talked away by the LLM.
            $cliFlagIssues = @()
            try { $cliFlagIssues = @(Test-CliFlagsInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ CLI-flag check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $cliFlagIssuesText = ''
            if ($cliFlagIssues.Count -gt 0) {
              $parts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $cliFlagIssues) {
                [void]$parts.Add(("$($iss.cli).exe не знает флага '$($iss.flag)' (в --help отсутствует). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $cliFlagIssuesText = [string]::Join(' ; ', $parts.ToArray())
              Add-Message -From system -Text ("🔎 CLI-flag-check: " + $cliFlagIssuesText) -Kind event | Out-Null
            }

            $qualityBypassIssues = @()
            try { $qualityBypassIssues = @(Test-QualityBypassesInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ Quality-bypass check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $qualityBypassIssuesText = ''
            if ($qualityBypassIssues.Count -gt 0) {
              $qbParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $qualityBypassIssues) {
                [void]$qbParts.Add(("$($iss.reason). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $qualityBypassIssuesText = [string]::Join(' ; ', $qbParts.ToArray())
              Add-Message -From system -Text ("🔎 Quality-bypass-check: " + $qualityBypassIssuesText) -Kind event | Out-Null
            }

            $diffWasTruncated = $false
            $diffBytes = 0
            try { $diffBytes = [Text.Encoding]::UTF8.GetByteCount($diff) } catch { $diffBytes = $diff.Length }
            if ($diff.Length -gt 16000) {
              $diffWasTruncated = $true
              $diff = $diff.Substring(0,16000) + "`n...[дифф обрезан]..."
            }
            $truncationNote = if ($diffWasTruncated) {
              "ВАЖНО: diff ниже обрезан по лимиту контекста. Не считай сам факт обрезки синтаксической ошибкой, потерей кода или доказательством обрезанной функции; проверяй только реально видимые изменения. Синтаксис .ps1 и BOM проверяются отдельными командами."
            } else { "" }
            $diffTruncatedText = ([string]$diffWasTruncated).ToLowerInvariant()
            $changedFilesText = ''
            try {
              $changedLines = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $changedLines = @(& git -C $criticRepoRoot diff --name-status $base -- 2>$null) }
              if (@($changedLines).Count -eq 0) { $changedLines = @(& git -C $criticRepoRoot diff --name-status HEAD -- 2>$null) }
              $changedFilesText = [string]::Join("`n", @($changedLines))
              if ($changedFilesText.Length -gt 3000) { $changedFilesText = $changedFilesText.Substring(0, 3000) + "`n...[changed-files truncated]..." }
            } catch {
              $changedFilesText = "(changed-files unavailable: $($_.Exception.Message))"
            }
            $taskHistory = ''
            if (-not [string]::IsNullOrWhiteSpace($base)) {
              try {
                $histLines = @(& git -C $criticRepoRoot log --oneline --name-status "$base..HEAD" 2>$null)
                $taskHistory = [string]::Join("`n", @($histLines))
                if ($taskHistory.Length -gt 6000) {
                  $taskHistory = $taskHistory.Substring(0, 6000) + "`n...[история обрезана]..."
                }
              } catch {
                $taskHistory = "(task-history unavailable: $($_.Exception.Message))"
              }
            }
            # HEAD context lets the critic distinguish "not in this diff" from "not in repo".
            $headContext = ''
            $symbolEvidence = ''
            try {
              $repoPs1Files = @()
              try { $repoPs1Files = @(& git -C $criticRepoRoot ls-files --cached '*.ps1' 2>$null) } catch { $repoPs1Files = @() }
              $repoPs1List = if ($repoPs1Files.Count -gt 0) { [string]::Join(', ', $repoPs1Files) } else { '(none)' }

              $funcLines = New-Object 'System.Collections.Generic.List[string]'
              $diffPs1Names = @($diffNames | Where-Object { $_ -match '\.ps1$' })
              $diffPs1Set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
              foreach ($relDiffPs1 in $diffPs1Names) { [void]$diffPs1Set.Add([string]$relDiffPs1) }
              foreach ($relf in $diffPs1Names) {
                $fullF = Join-Path $criticRepoRoot $relf
                if (Test-Path $fullF) {
                  $fns = @()
                  try {
                    $fns = @(& git -C $criticRepoRoot show ('HEAD:' + ($relf -replace '\\','/')) 2>$null |
                      Select-String -Pattern '^\s*function\s+([A-Za-z][\w-]*)' -AllMatches |
                      ForEach-Object { $_.Matches | ForEach-Object { $_.Groups[1].Value } })
                  } catch { $fns = @() }
                  if ($fns.Count -gt 0) {
                    [void]$funcLines.Add(($relf + ': ' + [string]::Join(', ', $fns)))
                  }
                }
              }

              $allFuncsInDiffedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
              foreach ($ln in @($funcLines)) {
                $parts2 = $ln -split ': ', 2
                if ($parts2.Count -eq 2) {
                  foreach ($fn in ($parts2[1] -split ', ')) {
                    [void]$allFuncsInDiffedFiles.Add($fn.Trim())
                  }
                }
              }

              $calledInDiff = @()
              try {
                $cmdNamePattern = '(?:Invoke-|Get-|Set-|Add-|Remove-|Test-|New-|Write-|Read-|Send-|Update-|Save-|Load-|Build-|Find-|Format-|Start-|Stop-)[A-Za-z][\w-]*'
                $calledSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($dln in ($diff -split "`r?`n")) {
                  if ($dln -notmatch '^[\+\- ]') { continue }
                  if ($dln -match '^(?:\+\+\+|---)') { continue }
                  $codeLine = if ($dln.Length -gt 0) { $dln.Substring(1) } else { '' }
                  if ($codeLine -match '^\s*#') { continue }
                  foreach ($m in [regex]::Matches($codeLine, "(?<![\w-])$cmdNamePattern(?![\w-])")) {
                    [void]$calledSet.Add($m.Value)
                  }
                }
                $calledInDiff = @($calledSet | Sort-Object)
              } catch { $calledInDiff = @() }

              $crossRefs = New-Object 'System.Collections.Generic.List[string]'
              $symbolEvidenceParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($fn in $calledInDiff) {
                if ($allFuncsInDiffedFiles.Contains($fn)) { continue }
                $fnFiles = New-Object 'System.Collections.Generic.List[string]'
                foreach ($rf in $repoPs1Files) {
                  $fullRf = Join-Path $criticRepoRoot $rf
                  if (-not (Test-Path $fullRf)) { continue }
                  if ($diffPs1Set.Contains([string]$rf)) { continue }
                  try {
                    $headLines = @(& git -C $criticRepoRoot show ('HEAD:' + ($rf -replace '\\','/')) 2>$null)
                    $fnPattern = '^\s*function\s+' + [regex]::Escape($fn) + '\b'
                    $hitIndex = -1
                    for ($idx = 0; $idx -lt $headLines.Count; $idx++) {
                      if ([string]$headLines[$idx] -match $fnPattern) { $hitIndex = $idx; break }
                    }
                    $hit = ($hitIndex -ge 0)
                    if ($hit) {
                      [void]$fnFiles.Add($rf)
                      if ($symbolEvidence.Length -lt 8000) {
                        $endIdx = [Math]::Min($headLines.Count - 1, $hitIndex + 10)
                        $bodyLines = New-Object 'System.Collections.Generic.List[string]'
                        for ($bodyIdx = $hitIndex; $bodyIdx -le $endIdx; $bodyIdx++) {
                          [void]$bodyLines.Add([string]$headLines[$bodyIdx])
                        }
                        $snippet = ("### {0} -> {1}`n{2}" -f $fn, $rf, [string]::Join("`n", $bodyLines.ToArray()))
                        [void]$symbolEvidenceParts.Add($snippet)
                        $symbolEvidence = [string]::Join("`n`n", $symbolEvidenceParts.ToArray())
                        if ($symbolEvidence.Length -gt 8000) {
                          $symbolEvidence = $symbolEvidence.Substring(0, 8000) + "`n...[symbol-evidence truncated]..."
                          break
                        }
                      }
                    }
                  } catch { $hit = $false }
                }
                if ($fnFiles.Count -gt 0) {
                  [void]$crossRefs.Add($fn + ' -> ' + [string]::Join(', ', $fnFiles.ToArray()))
                }
                if ($symbolEvidence.Length -gt 8000) { break }
              }

              $hcParts = New-Object 'System.Collections.Generic.List[string]'
              if ($funcLines.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ:`n" + [string]::Join("`n", $funcLines.ToArray()))
              }
              if ($crossRefs.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ ИЗ DIFF, ОПРЕДЕЛЁННЫЕ В ДРУГИХ ФАЙЛАХ:`n" + [string]::Join("`n", $crossRefs.ToArray()))
              }
              [void]$hcParts.Add("ВСЕ .ps1 ФАЙЛЫ РЕПО: $repoPs1List")
              $headContext = [string]::Join("`n`n", $hcParts.ToArray())
              if ($headContext.Length -gt 8000) { $headContext = $headContext.Substring(0, 8000) + "`n...[контекст обрезан]..." }
              if ([string]::IsNullOrWhiteSpace($symbolEvidence)) { $symbolEvidence = "(no cross-file symbol evidence)" }
            } catch {
              $headContext = "(head-context unavailable: $($_.Exception.Message))"
              $symbolEvidence = "(symbol-evidence unavailable: $($_.Exception.Message))"
            }
            $criticPrompt = @"
Ты — независимый код-критик. Другой ИИ (Codex) внёс изменения в проект на PowerShell (автономный мост Claude<->Codex на Windows). Проверь git-дифф на СЕРЬЁЗНЫЕ проблемы: баги, уязвимости безопасности, регрессии, потеря данных, падения, синтаксические ошибки, нарушение инвариантов (каждый .ps1 в UTF-8 с BOM; не трогать watchdog/supervisor/.git; не выводить секреты).
НЕ придирайся к стилю, именованию и форматированию — отмечай только то, что реально сломает работу или создаёт риск.

ОСОБО ПРОВЕРЬ ИЗВЕСТНЫЕ ГРАБЛИ POWERSHELL (частые причины аварий в этом проекте — при наличии ставь severity=serious):
- ConvertTo-Json по строке из `Get-Content -Raw` (или по сырым объектам из ConvertFrom-Json), особенно с -Depth>=12 → рекурсия по ETS-графу провайдера (PSProvider/PSDrive) → OOM ~70ГБ и краш хоста. Должно быть [IO.File]::ReadAllText или `("" + $s)` + ПЛОСКИЕ DTO + -Depth<=10. (это уже роняло мост — /api/radar)
- .ps1 без BOM (PS 5.1 ломает кириллицу); вызов нативного exe (git и т.п.) под $ErrorActionPreference='Stop' (stderr бросит исключение).
- Новый/изменённый API-эндпоинт или UI БЕЗ реальной проверки по HTTP/загрузке страницы.
- Бесконечные циклы / отсутствие таймаута; убийство процессов по возрасту/эвристике; чтение или вывод secrets.json.
- `param([string[]]$Args)` или другие зарезервированные имена параметров (Args/Input/PSCmdlet/MyInvocation/PSScriptRoot) — silent override автоматическими переменными, функция получит пусто или мусор (2026-05-27: Get-BacklogGitOutput с `$Args` вернула git help-страницу 2335 символов вместо коммитов, freshness-check 18 items работал на мусоре).
- `Add-Content -Encoding UTF8` в PS 5.1 пишет BOM при создании файла — JSONL с BOM ломает строгие парсеры. Для JSONL нужно `[IO.File]::AppendAllText($path,$line+"`n",(New-Object Text.UTF8Encoding($false)))`.
- Native command stderr через `2>&1` под PS 5.1 — каждая stderr-строка оборачивается в NativeCommandError ErrorRecord, что часто валит скрипт. Используй `2>$null` отдельно или `cmd /c "... 2>NUL"`.

🔢 ОТДЕЛЬНО — OVER-CLAIM ПАТТЕРН (это уже было причиной 1-часового цикла verify-reject):
Если в коммит-сообщениях или в обвязке кода Codex ЗАЯВЛЯЕТ численный результат («backfill для 51 items», «обновлено N файлов», «все 4 теста OK», «merged 3 streams») БЕЗ инкорпорированной команды-доказательства в самом коде/коммите — это RED FLAG. Помечай severity=serious с конкретикой:
- «commit message заявляет 51 items, но в коде только цикл foreach без проверки итогового count»
- «комментарий говорит "all parsed OK", но parse-проверка не возвращается / не логируется»
Это родилось из curator-задачи 2026-05-27 где Codex 3 раза подряд заявлял «backfill 51» при реальных 3/19/35.

🩺 ПРОВЕРКА: ЗАКРЫВАЕТ ЛИ ФИКС СИМПТОМ ИЛИ ТОЛЬКО МАСКИРУЕТ?
Задача обычно описывает симптом от пользователя («X мигает», «Y тормозит», «не могу Z»). Прежде чем дать OK:
1. Восстанови по тексту задачи: что именно увидел пользователь? Какой конкретный сценарий ломался?
2. Спроси сам себя: ЕСЛИ пользователь повторит этот сценарий после применения этого диффа — симптом ИСЧЕЗНЕТ или просто станет менее частым/будет глотаться guard'ом?
3. Если диф добавляет защиту (guard / try-catch / timeout / retry / epoch check / abort signal / debounce) — это часто МАСКА, а не фикс. Корень обычно лежит на этаж глубже: данные испорчены в источнике, а guard ловит их уже на выходе. Помечай severity=serious с пометкой «patches symptom, not root cause» и предложи где искать корень.
4. Особо для UI/HTTP пар: если диф меняет КЛИЕНТ (web/), но НЕ ТРОГАЕТ серверный эндпоинт, который этот клиент дёргает — это сильный сигнал маскировки. Перечисли эндпоинты, упомянутые в diff клиента, и спроси «их серверная сторона была пересмотрена в этом дифе?». Если нет — severity=serious с конкретным эндпоинтом для проверки.
5. Слова в комментариях кода и в коммит-сообщении: «race», «flicker», «stale», «timing», «debounce», «throttle», «retry» — это часто сигнал, что чинят временной симптом, а не источник несоответствия. Спроси «есть ли источник правды или два потока данных, которые расходятся?»

🔁 ПРОВЕРКА: ЭТО НЕ ПЕРВАЯ ПОПЫТКА?
Если в тексте задачи (или в HEAD-контексте ниже) есть признаки «уже исправляли», «повторяется», «снова», «опять», «ещё раз», «несмотря на <SHA>», ссылки на предыдущие коммиты-фиксы в этой же области — это RECURRENCE. Тогда:
- Назови явно, чем этот диф ОТЛИЧАЕТСЯ от прошлых попыток на уровне рут-каузы (а не имени файла).
- Если диф структурно ПОХОЖ на прошлые (тот же файл, та же функция, добавлен ещё один guard/epoch/abort/timeout) — severity=serious с подписью «N-th attempt, structurally similar to previous fix, root cause likely elsewhere».
- Если этот диф впервые трогает СОВСЕМ ДРУГОЙ слой (UI→server, client→config, lib→tests) — это хороший знак, не флаг.

ЗАДАЧА: $task

=== КОНТЕКСТ ЗАДАЧИ ===
DIFF_META: repo=$criticRepoRoot | base=$base | diff_truncated=$diffTruncatedText | diff_bytes=$diffBytes
DIFF ниже — полный диф от начала задачи до HEAD. Если diff_truncated=true — файлы за пределом могут быть изменены; их отсутствие в DIFF не доказывает, что они не менялись.
TASK_HISTORY показывает все коммиты задачи — используй его для проверки полноты фаз и файлов.
SYMBOL_EVIDENCE — сигнатуры и первые строки функций, вызванных в DIFF, но определённых в других файлах. Если функция есть в SYMBOL_EVIDENCE или в блоке "ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ" из HEAD-контекста — не флагируй её как отсутствующую. Duplicate/drift флагируй только если изменённые строки DIFF реально вводят конфликтующую реализацию.
Аудируй только строки DIFF со знаком + или -. Не аудируй unchanged код из SYMBOL_EVIDENCE, TASK_HISTORY или HEAD-контекста.

=== CHANGED_FILES ===
$changedFilesText

=== TASK_HISTORY ===
$taskHistory

=== SYMBOL_EVIDENCE ===
$symbolEvidence

КОНТЕКСТ HEAD (для проверки over-claim: функции, упомянутые в diff, существуют в этих файлах — не помечай их как несуществующие):
$headContext

$truncationNote

GIT-ДИФФ:
$diff

Верни СТРОГО JSON без markdown и без пояснений:
{"verdict":"OK","severity":"none","issues":[],"summary":"одна фраза по-русски"}
Где severity = "serious" ТОЛЬКО если есть баг/уязвимость/регрессия, которую обязательно исправить до закрытия; иначе "minor" или "none".
"@
            # 2026-06-11 A5 (speed program): no verdict memo existed — the SAME diff was re-reviewed
            # by the LLM on every verify-retry / restart-resume tail (1-2 extra calls x up to 90s
            # each per task tail). Memo an OK/none verdict in state keyed by MD5(diff); 'serious'
            # is never cached (must re-review after a fix), and any deterministic finding from THIS
            # pass (cli-flag / quality-bypass) disqualifies the cache.
            $criticCacheKey = ''
            try {
              $md5 = [System.Security.Cryptography.MD5]::Create()
              $criticCacheKey = ([System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$diff))) -replace '-','')
            } catch { $criticCacheKey = '' }
            $criticCacheHit = $false
            $criticCacheSummary = ''
            if (-not [string]::IsNullOrWhiteSpace($criticCacheKey) -and $cliFlagIssues.Count -eq 0 -and $qualityBypassIssues.Count -eq 0) {
              try {
                $ccState = Read-State
                if ($ccState.PSObject.Properties.Name -contains 'critic_verdict_cache' -and $ccState.critic_verdict_cache) {
                  $cc = $ccState.critic_verdict_cache
                  if ([string]$cc.key -eq $criticCacheKey -and [string]$cc.verdict -eq 'OK' -and [string]$cc.severity -eq 'none') {
                    $criticCacheHit = $true
                    $criticCacheSummary = [string]$cc.summary
                  }
                }
              } catch { $criticCacheHit = $false }
            }
            $criticEmptyMaxAttempts = 2
            $rawC = ''
            if ($criticCacheHit) {
              Add-Message -From system -Text "🔎 Критик: тот же дифф уже одобрен ранее (verdict-кэш по MD5 диффа) — пропускаю повторное LLM-ревью." -Kind event | Out-Null
            } else {
              # Q2: heavy reviews run with provider thinking enabled and a longer budget
              # (thinking lengthens the response; 90s starved it).
              $criticTimeoutSec = if ($isHeavyCritic) { 180 } else { 90 }
              $script:DriverCriticTimingStart = [DateTime]::UtcNow
              for ($criticEmptyAttempt = 1; $criticEmptyAttempt -le $criticEmptyMaxAttempts; $criticEmptyAttempt++) {
                $rawC = Invoke-LLM -Purpose 'critic' -Model $criticModelName -Prompt $criticPrompt -TimeoutSec $criticTimeoutSec -Temperature 0.1 -Thinking:$isHeavyCritic
                if (-not [string]::IsNullOrWhiteSpace($rawC)) { break }
                if ($criticEmptyAttempt -lt $criticEmptyMaxAttempts) {
                  Add-Message -From system -Text ("🔁 Критик вернул пустой ответ (empty " + $criticEmptyAttempt + "/" + $criticEmptyMaxAttempts + ") — повторяю только critic gate.") -Kind event | Out-Null
                }
              }
              try {
                $criticElapsedMs = [long]([DateTime]::UtcNow - $script:DriverCriticTimingStart).TotalMilliseconds
                if ($criticElapsedMs -gt 100 -and (Get-Command Update-TaskPhaseTiming -ErrorAction SilentlyContinue)) {
                  Update-TaskPhaseTiming -Phase critic_ms -Ms $criticElapsedMs
                }
              } catch {}
            }
            $verdict='OK'; $severity='none'; $summary=''; $issuesText=''
            if ($criticCacheHit) {
              $summary = if ([string]::IsNullOrWhiteSpace($criticCacheSummary)) { 'OK (verdict-кэш)' } else { $criticCacheSummary + ' [verdict-кэш]' }
            } elseif (-not [string]::IsNullOrWhiteSpace($rawC)) {
              $cleanC = ($rawC -replace '```json','' -replace '```','').Trim()
              $mC = [regex]::Match($cleanC, '(?s)\{.*\}')
              if ($mC.Success) {
                try {
                  $cv = $mC.Value | ConvertFrom-Json
                  if ($cv.verdict)  { $verdict  = [string]$cv.verdict }
                  if ($cv.severity) { $severity = ([string]$cv.severity).Trim().ToLower() }
                  if ($cv.summary)  { $summary  = [string]$cv.summary }
                  if ($cv.issues) {
                    $issueParts = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($issue in @($cv.issues)) {
                      if ($null -eq $issue) { continue }
                      if ($issue -is [string]) {
                        $txtIssue = ([string]$issue).Trim()
                      } else {
                        $fields = New-Object 'System.Collections.Generic.List[string]'
                        foreach ($pn in @('file','line','severity','issue','problem','message','summary','fix')) {
                          try {
                            if ($issue.PSObject.Properties.Name -contains $pn) {
                              $pv = [string]$issue.$pn
                              if (-not [string]::IsNullOrWhiteSpace($pv)) { [void]$fields.Add(("{0}={1}" -f $pn,$pv)) }
                            }
                          } catch {}
                        }
                        if ($fields.Count -gt 0) { $txtIssue = [string]::Join(' | ', [string[]]@($fields.ToArray())) }
                        else { $txtIssue = ($issue | ConvertTo-Json -Compress -Depth 4) }
                      }
                      if (-not [string]::IsNullOrWhiteSpace($txtIssue)) { [void]$issueParts.Add($txtIssue) }
                    }
                    $issuesText = [string]::Join('; ', [string[]]@($issueParts.ToArray()))
                  }
                } catch {}
              }
            } else {
              $verdict = 'SKIPPED_EMPTY'
              $severity = 'none'
              $summary = "critic returned empty after $criticEmptyMaxAttempts attempts; recorded as skipped-empty"
              try {
                Update-State ({ param($s)
                  $s | Add-Member -NotePropertyName completion_critic_result -NotePropertyValue 'skipped-empty' -Force
                  $s | Add-Member -NotePropertyName completion_critic_empty_attempts -NotePropertyValue $criticEmptyMaxAttempts -Force
                }.GetNewClosure()) | Out-Null
              } catch {}
              Add-Message -From system -Text ("🔎 Критик вернул пустой ответ " + $criticEmptyMaxAttempts + " раза подряд — фиксирую critic_result=skipped-empty и продолжаю close; deterministic gates остаются обязательными.") -Kind event | Out-Null
            }
            if ([string]::IsNullOrWhiteSpace($issuesText) -and -not [string]::IsNullOrWhiteSpace($summary)) { $issuesText = $summary }

            # 2026-06-02: quality-bypass findings ALWAYS escalate to 'serious'.
            # Passing build by disabling build/type/lint checks is not an implementation;
            # project autonomy must fix the actual code and keep gates meaningful.
            if ($qualityBypassIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $qbPrefix = "Отключение проверок качества (ground-truth diff check): " + $qualityBypassIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $qbPrefix }
              else { $issuesText = $qbPrefix + ' ; ' + $issuesText }
            }

            # 2026-05-27: CLI-flag findings ALWAYS escalate to 'serious' regardless
            # of what the LLM critic decided. Deterministic checks override LLM
            # opinion (the LLM cannot run the CLI, so trust ground truth).
            if ($cliFlagIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $prefix = "Неверные CLI-флаги (ground-truth check, --help проверен реально): " + $cliFlagIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $prefix }
              else { $issuesText = $prefix + ' ; ' + $issuesText }
            }

            $taskShort = ($task -replace '\s+',' ').Trim()
            if ($taskShort.Length -gt 80) { $taskShort = $taskShort.Substring(0,80) }
            try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + "  model=$criticModelName verdict=$verdict severity=$severity crc=$crc | $taskShort | $summary | $issuesText") -Encoding UTF8 } catch {}
            if ($severity -eq 'serious') {
              $newCrc = $crc + 1
              Update-State ({ param($s) $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue $newCrc -Force }.GetNewClosure()) | Out-Null
              try { Set-TaskLastFailure -Kind critic_rejected -Text $issuesText } catch {}
              Add-Message -From system -Text "🔎 Независимый критик ($criticModelName) нашёл серьёзное (попытка $newCrc/$criticMaxRetries): $issuesText`n`nCodex, исправь это и снова доведи до STATUS: DONE — задачу НЕ закрываю." -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
              Update-State { param($s) $s.task_mode='normal' } | Out-Null
            } else {
              # A5: memo a FRESH final OK/none verdict (post-escalations) for this exact diff.
              if ($verdict -eq 'OK' -and $severity -eq 'none' -and -not $criticCacheHit -and -not [string]::IsNullOrWhiteSpace($criticCacheKey)) {
                try {
                  $cacheSummaryToStore = $summary
                  Update-State ({ param($s)
                    $s | Add-Member -NotePropertyName critic_verdict_cache -NotePropertyValue ([pscustomobject]@{
                      key = [string]$criticCacheKey; verdict = 'OK'; severity = 'none'; summary = [string]$cacheSummaryToStore; ts = (Get-Date).ToUniversalTime().ToString('o')
                    }) -Force
                  }.GetNewClosure()) | Out-Null
                } catch {}
              }
              if ($verdict -ne 'SKIPPED_EMPTY') {
                try {
                  Update-State { param($s)
                    $s | Add-Member -NotePropertyName completion_critic_result -NotePropertyValue 'PASS' -Force
                    $s | Add-Member -NotePropertyName completion_critic_empty_attempts -NotePropertyValue 0 -Force
                  } | Out-Null
                } catch {}
              }
              Add-Message -From system -Text "🔎 Критик ($criticModelName): $verdict / $severity — $summary" -Kind event | Out-Null
            }
          }
        }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + '  critic-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
}

$script:DriverLoopCompletionProjectActionsBlock = {
  # Project Autopilot stop-condition: record the coordinator outcome only after
  # STATUS/COVERED/verification gates have settled the final planner status.
  if ($plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stPaOutcome = Read-State
      $paTask = [string]$stPaOutcome.current_task
      $paBacklogId = [string]$stPaOutcome.current_backlog_id
      if (Get-Command Test-ProjectAutopilotCoordinatorText -ErrorAction SilentlyContinue) {
        $paIsCoordinator = [bool](Test-ProjectAutopilotCoordinatorText -Text $paTask)
      } else {
        $paIsCoordinator = [bool]([regex]::IsMatch($paTask, '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel'))
      }
      if ($paIsCoordinator -and (Get-Command Record-ProjectAutopilotCoordinatorOutcome -ErrorAction SilentlyContinue)) {
        $paChannel = ''
        $paRoot = ''
        try { $paChannel = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'slug' -Default '') } catch {}
        try { $paRoot = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'project_root' -Default '') } catch {}
        Record-ProjectAutopilotCoordinatorOutcome -Channel $paChannel -ProjectRoot $paRoot -CoordinatorId $paBacklogId -Created ([int]$projectBacklogCreated) -Reason 'final-planner-status-done' | Out-Null
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Project Autopilot outcome tracking failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
}
