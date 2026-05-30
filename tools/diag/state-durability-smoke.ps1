#Requires -Version 5.1
# State-durability smoke test.
# Verifies Read-State retry+backup restore without touching the live bridge state.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\diag\state-durability-smoke.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'lib\common.ps1')

# в”Ђв”Ђ Override Get-StatePath to a temp file so we never touch live state в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
$script:SmokeStatePath = Join-Path $env:TEMP "bridge-smoke-state-$PID.json"
function Get-StatePath { return $script:SmokeStatePath }

# в”Ђв”Ђ Helpers в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
function Write-SmokeState([hashtable]$Fields) {
  $obj = [PSCustomObject]@{
    status='running'; lastSeq=1; paused=$false; stop=$false; abort=$false
    heartbeat=(Get-Date -Format 'o')
  }
  foreach ($kv in $Fields.GetEnumerator()) { $obj | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
  $json = $obj | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($script:SmokeStatePath, $json, [System.Text.Encoding]::UTF8)
  return $obj
}

function Write-SmokeBackup([string]$Json) {
  [System.IO.File]::WriteAllText(($script:SmokeStatePath + '.bak'), $Json, [System.Text.Encoding]::UTF8)
}

function Corrupt-SmokeState { [System.IO.File]::WriteAllText($script:SmokeStatePath, '{"status":"running","lastSeq":', [System.Text.Encoding]::UTF8) }

$fails = 0
function Assert([string]$Name, [bool]$Cond) {
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fails++ }
}

# в”Ђв”Ђ Test 1: Torn read в†’ restore from backup в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Write-Host "`n[Test 1] Torn read в†’ restore from backup"
$validObj  = Write-SmokeState @{ current_task='SMOKE-TASK-1' }
$validJson = $validObj | ConvertTo-Json -Depth 10
Write-SmokeBackup $validJson
Corrupt-SmokeState   # breaks state.json; backup is still valid
$result = Read-State
Assert 'result not null'           ($null -ne $result)
Assert 'current_task preserved'    ($result.current_task -eq 'SMOKE-TASK-1')
$qDir = Join-Path (Get-BridgeRoot) 'control\quarantine'
$qFiles = @(Get-ChildItem -LiteralPath $qDir -Filter 'state-corrupt-*.json' -ErrorAction SilentlyContinue)
Assert 'quarantine file created'   ($qFiles.Count -gt 0)
# cleanup quarantine entry created by this test
$qFiles | Remove-Item -Force -ErrorAction SilentlyContinue

# в”Ђв”Ђ Test 2: Backup also invalid в†’ graceful degrade ($null, no crash) в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Write-Host "`n[Test 2] Both state + backup corrupt в†’ graceful degrade"
Corrupt-SmokeState
Write-SmokeBackup '{"status":"running"'   # truncated backup
$result2 = $null
try { $result2 = Read-State } catch { $result2 = 'THREW' }
Assert 'result is null (degrade to defaults)' ($null -eq $result2)

# в”Ђв”Ђ Test 3: Shape-fail (missing fields) в†’ restore from valid backup в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Write-Host "`n[Test 3] Shape-fail в†’ restore from backup"
[System.IO.File]::WriteAllText($script:SmokeStatePath, '{"arbitrary":"value"}', [System.Text.Encoding]::UTF8)
$validObj3 = Write-SmokeState @{ current_task='SMOKE-TASK-3' }
Write-SmokeBackup ($validObj3 | ConvertTo-Json -Depth 10)
# Re-corrupt state with shape-fail (has required fields but broken values doesn't matter; missing is the issue)
[System.IO.File]::WriteAllText($script:SmokeStatePath, '{"arbitrary":"value"}', [System.Text.Encoding]::UTF8)
$result3 = Read-State
Assert 'result not null'           ($null -ne $result3)
Assert 'current_task from backup'  ($result3.current_task -eq 'SMOKE-TASK-3')

# в”Ђв”Ђ Test 4: Write-State writes backup automatically в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Write-Host "`n[Test 4] Write-State creates write-through backup"
$validObj4 = Write-SmokeState @{ current_task='SMOKE-TASK-4' }
Write-State -State $validObj4 -AllowPartial
Assert 'backup file exists after Write-State'  (Test-Path ($script:SmokeStatePath + '.bak'))
$bakContent = Read-StateJsonRawValidated -Path ($script:SmokeStatePath + '.bak')
Assert 'backup contains correct task'  ($bakContent.current_task -eq 'SMOKE-TASK-4')

# в”Ђв”Ђ Cleanup в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Remove-Item -LiteralPath $script:SmokeStatePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath ($script:SmokeStatePath + '.bak') -Force -ErrorAction SilentlyContinue

# в”Ђв”Ђ Summary в”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђв”Ђ
Write-Host ""
if ($fails -eq 0) { Write-Host "STATE-DURABILITY SMOKE: PASS" } else { Write-Host "STATE-DURABILITY SMOKE: FAIL ($fails assertion(s) failed)"; exit 1 }
