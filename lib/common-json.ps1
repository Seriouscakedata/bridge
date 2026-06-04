# common-json.ps1 -- decomposed helpers from common.ps1. Dot-sourced by common.ps1.

function Read-StateJsonRawValidated {
  # Raw read+parse without calling Read-State/Write-State — safe on the recovery path (no recursion).
  param([string]$Path)
  if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
  } catch { return $null }
}
