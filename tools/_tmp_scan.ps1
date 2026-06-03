$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
$regRaw = [System.IO.File]::ReadAllText((Join-Path $root 'features\registry.json'),[System.Text.Encoding]::UTF8) | ConvertFrom-Json
$regFiles = [System.Collections.Generic.HashSet[string]]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $regRaw) {
    foreach ($o in @($f.owner_files)) {
        $n = [string]$o
        if ($n) { [void]$regFiles.Add($n.Replace('\','/')) }
    }
}

$libFiles = Get-ChildItem (Join-Path $root 'lib') -Filter '*.ps1' | Sort-Object Name
foreach ($file in $libFiles) {
    $rel = 'lib/' + $file.Name
    if (-not $regFiles.Contains($rel)) {
        $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)
        $first = if ($lines.Count -gt 0) { $lines[0] } else { '' }
        $content = $lines -join "`n"
        $fnMatches = [regex]::Matches($content, '(?m)^function ([A-Za-z][A-Za-z0-9_-]+)')
        $fns = @($fnMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 5)
        Write-Host ('MODULE: ' + $rel)
        Write-Host ('Header: ' + $first)
        Write-Host ('Fns: ' + ($fns -join ', '))
        Write-Host ''
    }
}
