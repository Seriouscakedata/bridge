param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$metricsZero = [pscustomobject]@{
  channels     = 0
  stateKb      = 0
  locks        = 0
  jobs         = 0
  checkpoints  = 0
  restartsHour = 0
}
$metricsHuge = [pscustomobject]@{
  channels     = 999
  stateKb      = 999999
  locks        = 999
  jobs         = 999
  checkpoints  = 999
  restartsHour = 999
}

$baseCfg = [pscustomobject]@{
  minMs   = 120000
  baseMs  = 180000
  maxMs   = 400000
  metrics = [pscustomobject]@{
    channels     = [pscustomobject]@{ weight = 10000; capMs = 90000 }
    stateKb      = [pscustomobject]@{ weight = 120;   capMs = 180000 }
    locks        = [pscustomobject]@{ weight = 15000; capMs = 120000 }
    jobs         = [pscustomobject]@{ weight = 5000;  capMs = 180000 }
    checkpoints  = [pscustomobject]@{ weight = 8000;  capMs = 180000 }
    restartsHour = [pscustomobject]@{ weight = 45000; capMs = 270000 }
  }
}

$base = Get-AdaptiveProbeTimeoutMs -Metrics $metricsZero -CoderTimeoutMs 500000 -ProbeTimeoutConfig $baseCfg
Assert-True ($base -eq 180000) "zero metrics should return baseMs, got $base"

$minCfg = [pscustomobject]@{ minMs = 200000; baseMs = 100000; maxMs = 400000; metrics = [pscustomobject]@{} }
$minClamp = Get-AdaptiveProbeTimeoutMs -Metrics $metricsZero -CoderTimeoutMs 500000 -ProbeTimeoutConfig $minCfg
Assert-True ($minClamp -eq 200000) "min clamp should return 200000, got $minClamp"

$maxClamp = Get-AdaptiveProbeTimeoutMs -Metrics $metricsHuge -CoderTimeoutMs 500000 -ProbeTimeoutConfig $baseCfg
Assert-True ($maxClamp -eq 400000) "max clamp should return 400000, got $maxClamp"

$coderCap = Get-AdaptiveProbeTimeoutMs -Metrics $metricsHuge -CoderTimeoutMs 250000 -ProbeTimeoutConfig $baseCfg
Assert-True ($coderCap -eq 250000) "coderTimeoutMs cap should return 250000, got $coderCap"

$oneMetricCfg = [pscustomobject]@{
  minMs   = 100000
  baseMs  = 150000
  maxMs   = 900000
  metrics = [pscustomobject]@{
    stateKb = [pscustomobject]@{ weight = 10000; capMs = 5000 }
  }
}
$stateOnly = [pscustomobject]@{
  channels     = 0
  stateKb      = 999999
  locks        = 0
  jobs         = 0
  checkpoints  = 0
  restartsHour = 0
}
$capOnly = Get-AdaptiveProbeTimeoutMs -Metrics $stateOnly -CoderTimeoutMs 900000 -ProbeTimeoutConfig $oneMetricCfg
Assert-True ($capOnly -eq 155000) "single metric cap should be base+cap (155000), got $capOnly"

$partialCfg = [pscustomobject]@{ maxMs = 240000; metrics = [pscustomobject]@{ channels = [pscustomobject]@{ weight = 1 } } }
$partial = Get-AdaptiveProbeTimeoutMs -Metrics $metricsZero -CoderTimeoutMs 230000 -ProbeTimeoutConfig $partialCfg
Assert-True ($partial -eq 180000) "partial config should fall back to default base and stay under coder cap, got $partial"

$emptyCfg = [pscustomobject]@{}
$emptyFallback = Get-AdaptiveProbeTimeoutMs -Metrics $metricsZero -CoderTimeoutMs 900000 -ProbeTimeoutConfig $emptyCfg
Assert-True ($emptyFallback -eq 180000) "empty config should fall back to default base, got $emptyFallback"

$badCfg = [pscustomobject]@{
  minMs   = 'bad'
  baseMs  = 'bad'
  maxMs   = 'bad'
  metrics = [pscustomobject]@{
    channels = [pscustomobject]@{ weight = 'bad'; capMs = 'bad' }
  }
}
$badFallback = Get-AdaptiveProbeTimeoutMs -Metrics $metricsZero -CoderTimeoutMs 900000 -ProbeTimeoutConfig $badCfg
Assert-True ($badFallback -eq 180000) "invalid config should fall back to default base, got $badFallback"

$probeByCommand = Test-IsProbeTask -Command 'powershell -File tools\diag\runtime-storage-probe.ps1'
$probeByTag = Test-IsProbeTask -Prompt 'ordinary task' -Tags @('diag')
$durabilityOnly = Test-IsProbeTask -Prompt 'foundation durability refactor without explicit marker'
$contextMentionOnly = Test-IsProbeTask -Prompt 'historical note: runtime-storage-probe existed in a previous task'
$fullPromptHistory = @'
ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:
foundation durability refactor without explicit marker

РОЛИ: test

ДИАЛОГ:
old note: powershell -File tools\diag\runtime-storage-probe.ps1
'@
$fullPromptCurrentProbe = @'
ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:
run powershell -File tools\diag\runtime-storage-probe.ps1

РОЛИ: test
'@
Assert-True $probeByCommand 'runtime-storage-probe command should be detected'
Assert-True $probeByTag 'diag tag should be detected'
Assert-True (-not $durabilityOnly) 'durability alone must not be detected as probe'
Assert-True (-not $contextMentionOnly) 'plain historical runtime-storage-probe mention must not be detected as probe'
Assert-True (-not (Test-IsProbeTask -Prompt $fullPromptHistory)) 'old probe path in dialogue must not affect current non-probe task'
Assert-True (Test-IsProbeTask -Prompt $fullPromptCurrentProbe) 'probe path in current task block should be detected'

$oldProfile = $env:USERPROFILE
$tmpProfile = Join-Path $env:TEMP ('bridge-probe-timeout-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpProfile -Force | Out-Null
try {
  $env:USERPROFILE = $tmpProfile
  Write-ProbeDuration -ComputedTimeoutMs 180000 -ActualDurationMs 1234 -Metrics $metricsZero -Exit 'ok' -Verdict 'self-test'
  $telemetryPath = Join-Path (Get-RuntimeRoot) 'probe-durations.jsonl'
  $lines = @(Get-Content -LiteralPath $telemetryPath -Encoding UTF8)
  Assert-True ($lines.Count -eq 1) "telemetry should contain one line, got $($lines.Count)"
  $rec = $lines[0] | ConvertFrom-Json
  Assert-True ($rec.computed_timeout_ms -eq 180000) 'telemetry computed_timeout_ms mismatch'
  Assert-True ($rec.actual_duration_ms -eq 1234) 'telemetry actual_duration_ms mismatch'
  Assert-True ($rec.exit -eq 'ok') 'telemetry exit mismatch'
} finally {
  $env:USERPROFILE = $oldProfile
}

Write-Host "base=$base minClamp=$minClamp maxClamp=$maxClamp coderCap=$coderCap perMetricCap=$capOnly partialFallback=$partial emptyFallback=$emptyFallback badFallback=$badFallback"
Write-Host "detect: command=$probeByCommand tag=$probeByTag durabilityOnly=$durabilityOnly contextMentionOnly=$contextMentionOnly"
Write-Host "telemetry: one valid JSONL line written"
Write-Host 'OK'
