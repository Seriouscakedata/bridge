# common-strings.ps1 -- decomposed helpers from common.ps1. Dot-sourced by common.ps1.

function Test-TaskControlMarker {
  param([string]$TaskText, [string]$Marker)
  if ([string]::IsNullOrWhiteSpace($TaskText) -or [string]::IsNullOrWhiteSpace($Marker)) { return $false }
  $markerRegex = '(?m)^\s*\[\[' + [regex]::Escape($Marker.Trim()) + '\]\]\s*$'
  foreach ($line in ([string]$TaskText -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    return [bool]([regex]::IsMatch($line, $markerRegex))
  }
  return $false
}

function Test-IsTrivialTask {
  param([string]$TaskText, [int]$MinChars = 0)
  $t = ([string]$TaskText -replace '\[\[FAST\]\]', '').Trim()
  if ($MinChars -le 0) {
    try { $MinChars = [int](Get-FastLaneSettings).minChars } catch { $MinChars = 100 }
  }
  if ($MinChars -le 0) { $MinChars = 100 }
  if ($t.Length -ge $MinChars) { return $false }
  if ($t -match '\[\[REASONING:high\]\]') { return $false }
  if ($t -match '(?m)^#+\s') { return $false }
  if ($t -match '(?m)^\d+\.\s') { return $false }
  if ($t -match '```') { return $false }
  if ($t -match '(?i)(архитектур|разбер|исследу|спроектир|design|refactor|audit)') { return $false }
  if (Test-IsUnsafeFastLaneTask -TaskText $t) { return $false }
  return [bool](Test-IsSafeOsFastLaneTask -TaskText $t)
}

function Test-IsUnsafeFastLaneTask {
  # Destructive, irreversible, or outgoing actions must keep the normal safety gates.
  param([string]$TaskText)
  $t = ([string]$TaskText).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return [bool]([regex]::IsMatch($t, '(?i)(удал\w*|сотр\w*|очист\w*|формат\w*|перезапиш\w*|перезапуст\w*|закро\w*|убе[йт]\w*|уби\w*|\bdelete\b|\bdel\b|\brm\b|remove-item|\bformat\b|reset\s+--hard|git\s+push|\bpush\b|\bdrop\b|truncate|wipe|\bkill\b|taskkill|заверш\w*|shutdown|restart-computer|выключ\w*\s+комп|перезагруз\w*\s+комп)'))
}

function Test-IsSafeOsFastLaneTask {
  # Reversible/read-only OS/UI commands that can skip the planner ceremony.
  param([string]$TaskText)
  $t = ([string]$TaskText).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  if (Test-IsUnsafeFastLaneTask -TaskText $t) { return $false }
  if ($t -match '(?i)(аудит|audit)') { return $false }
  if ($t -match '(?i)(обсуд\w*|согласу\w*|проанализ\w*|спроектир\w*|исследу\w*|изучи\w*|реализ\w*|внедр\w*|добав\w*|почин\w*|поправ\w*|обнов\w*|измен\w*|\bdesign\b|\brefactor\b|\bimplement\b|\bfix\b|\bupdate\b|\badd\b)') { return $false }
  return [bool]([regex]::IsMatch($t, '(?i)(скриншот|screenshot|снимок\s+экран|запуст\w*|launch\b|открой\w*|\bopen\b|покаж\w*|\bshow\b|найд\w*|\bfind\b|поищ\w*|список|\blist\b|статус\b|\bstatus\b|\blog\w*|логи?\b)'))
}
