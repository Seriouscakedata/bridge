$ErrorActionPreference = 'Continue'
$auth = Get-Content 'C:\Users\rafie\OneDrive\Documents\bridge\auth.json' | ConvertFrom-Json
$pair = "$($auth.user):$($auth.password)"
$b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
$h    = @{ Authorization = "Basic $b64" }

function Hit($url, $label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 15
        $sw.Stop()
        Write-Host ("[$label] code=$($r.StatusCode) ms=$($sw.ElapsedMilliseconds) bytes=$($r.RawContentLength)")
        return $r.Content
    } catch {
        $sw.Stop()
        Write-Host "[$label] ERROR: $($_.Exception.Message) ms=$($sw.ElapsedMilliseconds)"
        return $null
    }
}

Write-Host '=== Phase 5: /api/state has is_bridge / project_root / scope ==='
$state = Hit 'http://localhost:8787/api/state' 'state'
if ($state) {
    $obj = $state | ConvertFrom-Json
    [pscustomobject]@{
        is_bridge    = $obj.is_bridge
        project_root = $obj.project_root
        scope_slug   = $obj.scope.slug
        scope_is_bridge = $obj.scope.is_bridge
        scope_project_root = $obj.scope.project_root
    } | Format-List
}

Write-Host '=== Phase 5: /api/channels has active_scope ==='
$ch = Hit 'http://localhost:8787/api/channels' 'channels'
if ($ch) {
    $obj = $ch | ConvertFrom-Json
    [pscustomobject]@{
        active_scope_slug = $obj.active_scope.slug
        active_scope_is_bridge = $obj.active_scope.is_bridge
        active_scope_project_root = $obj.active_scope.project_root
        active = $obj.active
        pinned = $obj.pinned
    } | Format-List
}

Write-Host '=== Phase 6: /api/memory default (no bridge) ==='
$mem = Hit 'http://localhost:8787/api/memory' 'memory'
if ($mem) {
    $obj = $mem | ConvertFrom-Json
    $items = @($obj.items)
    $bridgeCount = @($items | Where-Object { $_.readonly_source -eq 'bridge' }).Count
    Write-Host "items=$($items.Count) bridge_readonly=$bridgeCount"
}

Write-Host '=== Phase 6: /api/memory?include_bridge=1 ==='
$mem2 = Hit 'http://localhost:8787/api/memory?include_bridge=1' 'memory+bridge'
if ($mem2) {
    $obj = $mem2 | ConvertFrom-Json
    $items = @($obj.items)
    $bridgeCount = @($items | Where-Object { $_.readonly_source -eq 'bridge' }).Count
    Write-Host "items=$($items.Count) bridge_readonly=$bridgeCount"
    if ($bridgeCount -gt 0) {
        $sample = $items | Where-Object { $_.readonly_source -eq 'bridge' } | Select-Object -First 1
        Write-Host "sample bridge entry: readonly=$($sample.readonly) readonly_source=$($sample.readonly_source) channel=$($sample.channel)"
    }
}

Write-Host '=== /api/memory in travel scope ==='
$mem3 = Hit 'http://localhost:8787/api/memory?channel=travel&include_bridge=1' 'memory travel+bridge'
if ($mem3) {
    $obj = $mem3 | ConvertFrom-Json
    $items = @($obj.items)
    $bridgeCount = @($items | Where-Object { $_.readonly_source -eq 'bridge' }).Count
    Write-Host "items=$($items.Count) bridge_readonly=$bridgeCount"
}
