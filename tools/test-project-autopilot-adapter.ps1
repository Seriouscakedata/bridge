param()
# 2026-06-30 verifies the discuss->autopilot adapter: feeding the REAL discuss output (evidence
# plan.jsonl + 9-section delivery contract) through Convert-DiscussToAutopilotInputs produces project
# artifacts that PASS the REAL Test-ProjectPlanContractReady gate (so wide diffusion can trigger after
# operator approval). The validator is the oracle.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\delivery-contract.ps1')
. (Join-Path $root 'lib\backlog.ps1')
. (Join-Path $root 'lib\project-autopilot-adapter.ps1')

# --- evidence inputs (what the live discuss actually produced) ---
$planEvidence = 'C:\Users\rafie\.bridge-runtime\selfie-evidence-20260630-163801\plan.jsonl'
$contractEvidence = 'C:\Users\rafie\bridge-projects\_evidence-selfie-20260630-163801\.bridge\project-contract.json'
if (-not (Test-Path $planEvidence)) { Write-Host "MISSING plan evidence: $planEvidence"; exit 2 }
if (-not (Test-Path $contractEvidence)) { Write-Host "MISSING contract evidence: $contractEvidence"; exit 2 }

# --- temp project root seeded with the discuss output ---
$proj = Join-Path ([IO.Path]::GetTempPath()) ('adapter-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $proj '.bridge') -Force | Out-Null
Copy-Item -LiteralPath $contractEvidence -Destination (Join-Path $proj '.bridge\project-contract.json') -Force
$records = @(Get-Content $planEvidence -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
Write-Host ("plan records=" + $records.Count + "  tasks=" + @($records | Where-Object { [string]$_.type -eq 'task' }).Count)

# --- BEFORE: gate should fail (no PROJECT_PLAN.md etc.) ---
$before = Test-ProjectPlanContractReady -ProjectRoot $proj
Write-Host ("BEFORE adapter: ready=" + $before.ready + "  spec_profile=" + $before.spec_profile)
Write-Host ("  issues (" + @($before.issues).Count + "): " + (@($before.issues) -join ' | '))

# --- run the adapter ---
$res = Convert-DiscussToAutopilotInputs -ProjectRoot $proj -PlanRecords $records
Write-Host ("ADAPTER: ok=" + $res.ok + " reason=" + $res.reason + " chapters=" + $res.chapters + " files=" + (@($res.files) -join ', '))

# --- artifact sizes + chapter count via the real parser ---
foreach ($f in @('PROJECT_PLAN.md','PROJECT_MAP.md','PROJECT_BRIEF.md','.bridge\specs\acceptance.md')) {
  $p = Join-Path $proj $f
  $len = if (Test-Path $p) { (Get-Content $p -Raw).Length } else { -1 }
  Write-Host ("  " + $f + " chars=" + $len)
}
try { $chCount = Get-ProjectAutopilotPlanChapterCount -ProjectRoot $proj; Write-Host ("  chapters parsed from PROJECT_PLAN.md=" + $chCount) } catch { Write-Host ("  chapter-parse err: " + $_.Exception.Message) }

# --- AFTER: gate must pass ---
$after = Test-ProjectPlanContractReady -ProjectRoot $proj
Write-Host ("AFTER adapter: ready=" + $after.ready + "  spec_profile=" + $after.spec_profile + "  delivery_contract_ok=" + $after.delivery_contract_ok)
Write-Host ("  issues (" + @($after.issues).Count + "): " + (@($after.issues) -join ' | '))
Write-Host ("  counts: req=" + $after.counts.requirements + " surf=" + $after.counts.surfaces + " journeys=" + $after.counts.journeys + " accept=" + $after.counts.acceptance + " iface=" + $after.counts.interface_contract + " stages=" + $after.counts.planning_stages)

Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
if ($after.ready) { Write-Host 'OK: gate PASSES after adapter'; exit 0 } else { Write-Host 'FAIL: gate still red'; exit 1 }
