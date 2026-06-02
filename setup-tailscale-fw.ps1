# setup-tailscale-fw.ps1 -- allow the bridge port ONLY from the Tailscale network.
# Run elevated. Scopes inbound to 100.64.0.0/10 (Tailscale CGNAT range), so the
# port is reachable from your tailnet devices but NOT the public internet/LAN.
$ErrorActionPreference = 'Continue'
$cfg  = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$cfg.port
$name = "AI Bridge Tailscale $port"
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port `
  -Action Allow -Profile Any -RemoteAddress 100.64.0.0/10 | Out-Null
Write-Host "Added firewall rule '$name' (inbound TCP $port from Tailscale range only)."
Start-Sleep -Seconds 3
