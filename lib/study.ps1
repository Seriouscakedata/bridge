# study.ps1 -- detects whether a task is a genuine "study/research" request.
# Study mode is an INTERACTIVE user feature: trigger only on a real command verb
# ("изучи проект...", "study the repo..."), never on a study keyword that is part
# of a feature name ("Detect-StudyMode", "study-режим", "study/изучи") or a noun
# ("на изучение"). Autonomous backlog tasks are engineering work -> never study.

function Detect-StudyMode {
  param([string]$TaskText, [switch]$IsAutonomous)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $null }
  # Autonomous backlog tasks are self-improvement engineering, not study requests.
  if ($IsAutonomous) { return $null }
  # Require a study verb as a BOUNDED command word (imperative/request form),
  # not glued into a compound (Detect-StudyMode / study-режим / study/изучи) or a
  # noun (изучение/изучаю). Negative look-around rejects neighbouring letters, '-' and '/'.
  $verb = '(?i)(?<![\p{L}\-/])(?:изучи(?:ть|те|м)?|исследу(?:йте|ете|ем|й)?|разбер(?:ись|ите|и)|study|explore|research|investigate)(?![\p{L}\-/])'
  $verbMatch = [regex]::Match($TaskText, $verb)
  if (-not $verbMatch.Success) { return $null }
  # Bug-report / audit context = NOT a study request, even with the verb. The user is asking
  # the bridge to debug itself / audit its own behavior; planner handles that directly. Study
  # mode here just times out (see incident 2026-05-26: "Изучи проблему..." -> 2x planner timeout).
  $bugMarkers = '(?i)\bпроблем|\bошибк|\bбаг\b|\bбагрепорт|не\s+(?:работа|вижу|дела|выполня|отрабат|отвеча|показыв|появля|обновля|раб\b|готов)|сломан|пада(?:ет|ют)|ленится|почему\s+мост|зависает|тайма?ут|аудит\s+(?:моста|себя)|что\s+случилось|случилось\s+с\s+мост|broken|doesn''t\s+work|why\s+does|audit\s+(?:the\s+)?bridge'
  if ([regex]::IsMatch($TaskText, $bugMarkers)) { return $null }
  $trigger = $verbMatch.Value
  $patterns = @(
    '"(?<p>[A-Za-z]:\\[^"]+)"',
    "'(?<p>[A-Za-z]:\\[^']+)'",
    '(?<p>[A-Za-z]:\\[^\s"'']+)',
    '"(?<p>\\\\[^"]+)"',
    "'(?<p>\\\\[^']+)'",
    '(?<p>\\\\[^\s"'']+)'
  )
  foreach ($pat in $patterns) {
    $pathMatch = [regex]::Match($TaskText, $pat)
    if ($pathMatch.Success) {
      $path = $pathMatch.Groups['p'].Value.Trim()
      if ($path -and (Test-Path -LiteralPath $path)) {
        return @{ subtype='local'; path=$path; trigger=$trigger }
      }
    }
  }
  return @{ subtype='external'; path=$null; trigger=$trigger }
}
