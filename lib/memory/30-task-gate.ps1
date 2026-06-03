# ---- write gate (Flash-Lite) ----
function Get-MemoryDistilled {
  # Cheap gate: decide if a task outcome is worth keeping; if so distill to a durable fact.
  # Returns [pscustomobject]{ Fact; Importance; Tags } or $null.
  param([string]$TaskText, [string]$Outcome)
  $mc = Get-MemoryConfig
  if (-not $mc.enabled) { return $null }
  $task = [string]$TaskText; if ($task.Length -gt 1500) { $task = $task.Substring(0,1500) }
  $out  = [string]$Outcome;  if ($out.Length  -gt 4000) { $out  = $out.Substring(0,4000) }
  $prompt = @"
Ты — фильтр долговременной памяти ИИ-моста (Claude+Codex, разработка на ПК пользователя).
Реши, стоит ли запоминать результат НАДОЛГО. Запоминаем только устойчивое и переиспользуемое:
решения, факты о проекте/настройках/путях, найденные грабли (gotchas), предпочтения пользователя.
НЕ запоминаем: болтовню, разовые статусы, мусор, быстро устаревающее.

ЗАДАЧА:
$task

РЕЗУЛЬТАТ:
$out

Ответь СТРОГО одной строкой JSON без markdown и пояснений:
{"keep": true|false, "fact": "1-2 предложения сути по-русски", "importance": 0.0-1.0, "tags": ["короткие","теги"]}
Если запоминать не стоит — {"keep": false}.
"@
  $raw = Invoke-LLM -Purpose 'gate' -Prompt $prompt -TimeoutSec 40 -Temperature 0.1
  if (-not $raw) { return $null }
  $clean = ($raw -replace '```json','' -replace '```','').Trim()
  $mt = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mt.Success) { return $null }
  try { $obj = $mt.Value | ConvertFrom-Json } catch { return $null }
  if (-not $obj.keep) { return $null }
  if ([string]::IsNullOrWhiteSpace([string]$obj.fact)) { return $null }
  $imp = 0.5
  try { if ($obj.PSObject.Properties.Name -contains 'importance' -and $null -ne $obj.importance) { $imp = [double]$obj.importance } } catch {}
  if ($imp -lt 0) { $imp = 0 }; if ($imp -gt 1) { $imp = 1 }
  $tags = @()
  try { if ($obj.tags) { $tags = @($obj.tags | ForEach-Object { [string]$_ }) } } catch {}
  return [pscustomobject]@{ Fact = [string]$obj.fact; Importance = $imp; Tags = $tags }
}

function Add-TaskMemory {
  # Gate + store, in one call. Returns memory id or $null. Never throws.
  param([string]$TaskText, [string]$Outcome, [string]$Source = 'task')
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled -or -not $mc.autoGate) { return $null }
    $d = Get-MemoryDistilled -TaskText $TaskText -Outcome $Outcome
    if (-not $d) { return $null }
    return (Add-Memory -Text $d.Fact -Tags $d.Tags -Source $Source -Importance $d.Importance)
  } catch { return $null }
}
