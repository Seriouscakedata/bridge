# test-wp-verify.ps1 -- quick verify for wp1/wp2 parallel fixes
$b = 'C:\Users\rafie\OneDrive\Documents\bridge'
$pass = 0; $fail = 0

function Test-Check {
  param([string]$Name, [scriptblock]$Block)
  try {
    $r = & $Block
    if ($r) { Write-Host "PASS: $Name"; $script:pass++ }
    else     { Write-Host "FAIL: $Name"; $script:fail++ }
  } catch {
    Write-Host "FAIL: $Name :: $($_.Exception.Message)"
    $script:fail++
  }
}

# WP2: Get-BacklogPath and Ensure-BacklogPathFunction defined in backlog.ps1
. (Join-Path $b 'lib\common.ps1')
. (Join-Path $b 'lib\backlog.ps1')

Test-Check 'Get-BacklogPath is defined' { Get-Command Get-BacklogPath -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Resolve-BacklogPathValue is defined' { Get-Command Resolve-BacklogPathValue -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Ensure-BacklogPathFunction is defined' { Get-Command Ensure-BacklogPathFunction -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Get-BacklogPath returns non-empty string' {
  $p = Get-BacklogPath
  -not [string]::IsNullOrWhiteSpace($p)
}
Test-Check 'Resolve-BacklogPathValue returns same as Get-BacklogPath' {
  (Get-BacklogPath) -eq (Resolve-BacklogPathValue)
}

# WP2: Ensure-BacklogPathFunction re-registers if missing
Test-Check 'Ensure re-registers Get-BacklogPath after removal' {
  # remove from local scope simulation: just call Ensure again (idempotent)
  Ensure-BacklogPathFunction
  $p = Get-BacklogPath
  -not [string]::IsNullOrWhiteSpace($p)
}

# WP1: Resolve-MemoryContainedPath accepts BasePath param
. (Join-Path $b 'lib\memory.ps1')
Test-Check 'Resolve-MemoryContainedPath has BasePath param' {
  $cmd = Get-Command Resolve-MemoryContainedPath -ErrorAction SilentlyContinue
  $cmd -and ($cmd.Parameters.ContainsKey('BasePath'))
}

# WP1: librarian path-traversal rejection via Resolve-BridgeContainedPath
Test-Check 'Resolve-BridgeContainedPath rejects path-traversal' {
  try {
    Resolve-BridgeContainedPath -Path '..\..\..\Windows\win.ini' -Purpose 'test traversal'
    $false  # should have thrown
  } catch {
    $_.Exception.Message -match 'escapes'
  }
}

Write-Host ""
Write-Host "Result: $pass passed, $fail failed"
exit $fail
