$ErrorActionPreference = 'Stop'
$auth = Get-Content -Raw -LiteralPath 'C:\Users\rafie\OneDrive\Documents\bridge\auth.json' | ConvertFrom-Json
$pair = $auth.user + ':' + $auth.password
$basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
$base  = 'http://localhost:8787'
$h = @{ Authorization = "Basic $basic" }

function Hit($path) {
    try {
        $r = Invoke-WebRequest -Uri ($base + $path) -Headers $h -TimeoutSec 10 -UseBasicParsing
        return @{ status = $r.StatusCode; body = $r.Content }
    } catch {
        return @{ status = $_.Exception.Response.StatusCode.value__; error = $_.Exception.Message }
    }
}

Write-Host '== /api/state =='
$state = Hit '/api/state'
Write-Host ('status=' + $state.status)
if ($state.body) {
    $j = $state.body | ConvertFrom-Json
    Write-Host ('  is_bridge=' + $j.is_bridge)
    Write-Host ('  project_root=' + $j.project_root)
    Write-Host ('  scope=' + ($j.scope | ConvertTo-Json -Compress -Depth 3))
    Write-Host ('  active_channel=' + $j.active_channel)
}

Write-Host ''
Write-Host '== /api/channels =='
$ch = Hit '/api/channels'
Write-Host ('status=' + $ch.status)
if ($ch.body) {
    $j = $ch.body | ConvertFrom-Json
    if ($j.PSObject.Properties.Match('active_scope').Count) {
        Write-Host ('  active_scope=' + ($j.active_scope | ConvertTo-Json -Compress -Depth 3))
    } else {
        Write-Host '  (no active_scope key)'
    }
}

Write-Host ''
Write-Host '== /api/memory (default) =='
$mem = Hit '/api/memory'
Write-Host ('status=' + $mem.status)
if ($mem.body) {
    $j = $mem.body | ConvertFrom-Json
    $items = if ($j.PSObject.Properties.Match('items').Count) { $j.items } else { $j }
    $count = @($items).Count
    $bridgeReadonly = @($items | Where-Object { $_.readonly -eq $true -or $_.readonly_source -eq 'bridge' }).Count
    Write-Host ('  count=' + $count + ' bridge_readonly=' + $bridgeReadonly)
}

Write-Host ''
Write-Host '== /api/memory?channel=travel =='
$memT = Hit '/api/memory?channel=travel'
Write-Host ('status=' + $memT.status)
if ($memT.body) {
    $j = $memT.body | ConvertFrom-Json
    $items = if ($j.PSObject.Properties.Match('items').Count) { $j.items } else { $j }
    $count = @($items).Count
    $bridgeReadonly = @($items | Where-Object { $_.readonly -eq $true -or $_.readonly_source -eq 'bridge' }).Count
    Write-Host ('  count=' + $count + ' bridge_readonly=' + $bridgeReadonly + ' includeBridge=' + $j.includeBridge + ' scope.is_bridge=' + $j.scope.is_bridge)
}

Write-Host ''
Write-Host '== /api/memory?channel=travel&include_bridge=1 =='
$memTB = Hit '/api/memory?channel=travel&include_bridge=1'
Write-Host ('status=' + $memTB.status)
if ($memTB.body) {
    $j = $memTB.body | ConvertFrom-Json
    $items = if ($j.PSObject.Properties.Match('items').Count) { $j.items } else { $j }
    $count = @($items).Count
    $bridgeReadonly = @($items | Where-Object { $_.readonly -eq $true -or $_.readonly_source -eq 'bridge' }).Count
    $channelOnly = $count - $bridgeReadonly
    Write-Host ('  count=' + $count + ' channel=' + $channelOnly + ' bridge_readonly=' + $bridgeReadonly + ' includeBridge=' + $j.includeBridge)
}
