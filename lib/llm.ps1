# llm.ps1 -- provider-agnostic LLM router for the bridge's CHEAP batch thinking
# (memory gate, nightly librarian, idle reflection). Dot-sourced from common.ps1
# AFTER memory.ps1 (it reuses Invoke-GeminiChat / Get-Secret from there).
#
# Cost policy: prepaid Claude/Codex do the heavy task work via the normal pipeline;
# this router is ONLY for the small, low-frequency background calls, and it prefers the
# cheapest capable paid model (deepseek-v4-flash, non-thinking) to spare prepaid limits.
# Provider is inferred from the model name: deepseek* -> DeepSeek, gemini* -> Gemini.

function Get-LLMConfig {
  $defaults = @{
    gate      = 'deepseek-v4-flash'
    librarian = 'deepseek-v4-flash'
    reflect   = 'deepseek-v4-flash'
    postmortem = 'deepseek-v4-flash'
    deep      = 'deepseek-v4-pro'
    critic    = 'deepseek-v4-pro'
    criticHeavy = 'deepseek-v4-pro'
    # 2026-05-28: nightly audit functional analyzer. Receives a static
    # context (function list, endpoints, debt markers) and returns JSON
    # findings about dead/legacy code. Deepseek-pro for quality;
    # falls back to gemini-2.5-flash via Invoke-LLM router.
    'audit-functional' = 'deepseek-v4-pro'
    # 2026-05-28: task-intent classifier. Replaces [[DEEP-THINK]] regex with
    # cheap LLM understanding of user's natural-language intent. Fires once
    # per new task on each new user task (~$0.0001/call on flash-lite).
    # Was temporarily deepseek-v4-flash 2026-05-28 morning during Google
    # billing restriction; reverted to gemini-2.5-flash-lite same day after
    # reinstatement (verified HTTP 200 across 2.5-line). Override via
    # config.json llm.intent if needed.
    intent    = 'gemini-2.5-flash-lite'
    fallback  = 'gemini-2.5-flash'
  }
  $m = $null
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'llm') { $m = $cfg.llm }
  } catch {}
  $out = @{}
  foreach ($k in $defaults.Keys) {
    if ($m -and ($m.PSObject.Properties.Name -contains $k) -and $null -ne $m.$k) { $out[$k] = [string]$m.$k }
    else { $out[$k] = $defaults[$k] }
  }
  return $out
}

function Invoke-DeepSeekChat {
  # Returns model text or $null. Non-thinking by default (cheap, direct).
  param([string]$Model, [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.3, [switch]$Thinking, [string]$Purpose = '')
  if ([string]::IsNullOrWhiteSpace($Prompt)) { return $null }
  $key = Get-Secret 'deepseekApiKey'
  if (-not $key) { return $null }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $body = [ordered]@{
    model       = $Model
    messages    = @(@{ role = 'user'; content = $Prompt })
    temperature = $Temperature
    stream      = $false
  }
  if (-not $Thinking) { $body.thinking = @{ type = 'disabled' } }
  $json  = $body | ConvertTo-Json -Depth 8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $H = @{ Authorization = "Bearer $key" }
  try {
    $resp = Invoke-WebRequest -Uri 'https://api.deepseek.com/chat/completions' -Method Post -Headers $H `
      -ContentType 'application/json' -Body $bytes -UseBasicParsing -TimeoutSec $TimeoutSec
    $txt = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    $obj = $txt | ConvertFrom-Json
    $pt = 0; $ct = 0; $costUsd = $null
    try {
      if ($obj.usage) {
        if ($null -ne $obj.usage.prompt_tokens) { $pt = [int]$obj.usage.prompt_tokens }
        if ($null -ne $obj.usage.completion_tokens) { $ct = [int]$obj.usage.completion_tokens }
      }
      if (Get-Command Get-UsageCostUsd -ErrorAction SilentlyContinue) {
        $costUsd = Get-UsageCostUsd -Model $Model -PromptTokens $pt -CompletionTokens $ct
      }
      $null = Add-UsageRecord -Kind paid -Provider 'deepseek' -Model $Model -Purpose $Purpose -PromptTokens $pt -CompletionTokens $ct -Status 'ok'
    } catch {
      Write-Warning ("DeepSeek usage accounting failed: " + $_.Exception.Message)
    }
    $responseText = [string]$obj.choices[0].message.content
    $replayPurpose = if ([string]::IsNullOrWhiteSpace($Purpose)) { 'general' } else { $Purpose }
    Add-ReplayRecordForCurrentTask -Role ("deepseek-" + $replayPurpose) -Model $Model -Mode $Purpose -Prompt $Prompt -Response $responseText `
      -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $costUsd -Status 'ok' -ErrorType $null -Provider 'deepseek'
    return $responseText
  } catch {
    $replayPurpose = if ([string]::IsNullOrWhiteSpace($Purpose)) { 'general' } else { $Purpose }
    Add-ReplayRecordForCurrentTask -Role ("deepseek-" + $replayPurpose) -Model $Model -Mode $Purpose -Prompt $Prompt -Response '' `
      -LatencyMs ([int]$sw.ElapsedMilliseconds) -CostUsd $null -Status 'error' -ErrorType 'deepseek_error' -Provider 'deepseek'
    return $null
  }
}

function Invoke-LLMProvider {
  param([string]$Model, [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.3, [string]$Purpose = '')
  if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
  if ($Model -like 'deepseek*') { return Invoke-DeepSeekChat -Model $Model -Prompt $Prompt -TimeoutSec $TimeoutSec -Temperature $Temperature -Purpose $Purpose }
  if ($Model -like 'gemini*')   { return Invoke-GeminiChat   -Model $Model -Prompt $Prompt -TimeoutSec $TimeoutSec -Temperature $Temperature -Purpose $Purpose }
  return $null
}

function Invoke-LLM {
  # Route a cheap background call by Purpose (gate|librarian|reflect|critic|deep) or explicit -Model.
  # Falls back to the configured fallback model if the primary provider fails.
  param([string]$Purpose = '', [string]$Model = '', [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.3)
  if ([string]::IsNullOrWhiteSpace($Prompt)) { return $null }
  $cfg = Get-LLMConfig
  $model = $Model
  if ([string]::IsNullOrWhiteSpace($model) -and $Purpose -and $cfg.ContainsKey($Purpose)) { $model = [string]$cfg[$Purpose] }
  if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]$cfg['fallback'] }
  if ($model -eq 'off') { return $null }
  $res = Invoke-LLMProvider -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Temperature $Temperature -Purpose $Purpose
  if (-not [string]::IsNullOrWhiteSpace($res)) { return $res }
  $fb = [string]$cfg['fallback']
  if ($fb -and $fb -ne $model -and $fb -ne 'off') {
    return (Invoke-LLMProvider -Model $fb -Prompt $Prompt -TimeoutSec $TimeoutSec -Temperature $Temperature -Purpose $Purpose)
  }
  return $null
}
