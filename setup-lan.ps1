# setup-lan.ps1 -- make the bridge UI reachable from other devices on your home Wi-Fi.
# MUST run elevated (as Administrator). It does two things, both one-time:
#   1) reserves the URL so the normal-user server can bind to all interfaces
#   2) opens the firewall for the port on the Private (home) network only
$ErrorActionPreference = 'Continue'

$cfgPath = Join-Path $PSScriptRoot 'config.json'
$cfg  = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$cfg.port
$url  = "http://+:$port/"
$user = "$env:USERDOMAIN\$env:USERNAME"

Write-Host "=== 1/2: URL reservation $url for $user ==="
cmd /c "netsh http delete urlacl url=$url" 2>$null | Out-Null
cmd /c "netsh http add urlacl url=$url user=`"$user`""

Write-Host "=== 2/2: firewall rule (Private profile) for TCP $port ==="
Get-NetFirewallRule -DisplayName "AI Bridge $port" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "AI Bridge $port" -Direction Inbound -Protocol TCP `
  -LocalPort $port -Action Allow -Profile Private | Out-Null

Write-Host ""
Write-Host "Done. LAN access enabled on port $port (Private network only)."
Write-Host "Restart the server for the change to take effect."
Start-Sleep -Seconds 4
