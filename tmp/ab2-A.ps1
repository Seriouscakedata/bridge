. 'C:\Users\rafie\OneDrive\Documents\bridge\tools\audit.ps1'
$r = Invoke-BridgeAudit -FunctionalAgent 'auto'
$r | ConvertTo-Json -Depth 3 -Compress | Out-File 'C:\Users\rafie\OneDrive\Documents\bridge\tmp\ab2-A-result.json' -Encoding utf8