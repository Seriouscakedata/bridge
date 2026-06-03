# memory.ps1 -- long-term VECTOR memory for the bridge.
# Gemini embeddings (semantic recall) + Flash librarian (nightly consolidation).
# Dot-sourced from common.ps1. EVERY network path is wrapped so a failure here can
# NEVER kill the engine -- memory is best-effort: if Gemini is down, the bridge runs as before.

$script:EmbedCache = $null
$script:EmbedCacheOrder = $null
$script:EmbedCacheMax = 500
$script:LastRecallFlushTs = $null
$script:RecallFlushMinIntervalSec = 60

# Memory implementation modules. Keep this loader thin; edit behavior in lib/memory/*.ps1.
. (Join-Path $PSScriptRoot 'memory\00-cache-paths-config.ps1')
. (Join-Path $PSScriptRoot 'memory\10-gemini.ps1')
. (Join-Path $PSScriptRoot 'memory\20-store-add.ps1')
. (Join-Path $PSScriptRoot 'memory\21-search-recall-skills.ps1')
. (Join-Path $PSScriptRoot 'memory\30-task-gate.ps1')
. (Join-Path $PSScriptRoot 'memory\40-consolidation.ps1')
. (Join-Path $PSScriptRoot 'memory\50-management.ps1')
