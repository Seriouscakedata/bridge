param()

# ==============================================================================
# tools/test-diffusion-marker-e2e.ps1
#   END-TO-END through the REAL production ingest Add-ProjectBacklogFromMarker.
#   Feeds a realistic PROJECT_BACKLOG marker (provider + 2 consumers + 1 independent
#   atom carrying provides/consumes) in diffusionMode='diffusion', in an ISOLATED
#   temp bridge root (NO live bridge, NO contention), and asserts the real function
#   produces a DIFFUSION batch: synthesis ran, gate green, shaping added freeze
#   marker(s) + a stitch atom + the drift manifest, and the written atoms include
#   the freeze-marker + stitch. Negative control: diffusionMode='off' -> serial.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'lib\common.ps1') | Out-Null

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# ---- isolated temp bridge root + git-init'd project (clean-git gate needs a repo) ----
$script:T = Join-Path ([System.IO.Path]::GetTempPath()) ('diffusion-marker-e2e-' + [guid]::NewGuid().ToString('N'))
$script:proj = Join-Path $script:T 'project'
New-Item -ItemType Directory -Path (Join-Path $script:proj 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path (Join-Path $script:T 'channels') 'itest') -Force | Out-Null
Push-Location $script:proj
try { git init -q 2>$null | Out-Null; git config user.email t@t 2>$null; git config user.name t 2>$null } catch {}
Pop-Location

$script:jsonl = New-Object 'System.Collections.Generic.List[object]'
$script:ideas = New-Object 'System.Collections.Generic.List[object]'

# ---- overrides (defined AFTER sourcing so they win); scope the real ingest to temp ----
function Get-BridgeRoot { return $script:T }
function Get-EffectiveChannel { return 'itest' }
function Get-ChannelDir { param([string]$Slug) if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'itest' }; return (Join-Path (Join-Path $script:T 'channels') $Slug) }
function Use-BridgeLock { param([scriptblock]$Body) & $Body }
function Get-Backlog { return @() }
function Get-ChannelProjectBinding { param([string]$Slug) return [pscustomobject]@{ ok=$true; slug=$Slug; project_root=$script:proj } }
function Write-BacklogJsonLine { param($Line) $script:jsonl.Add($Line) | Out-Null }
function Add-Idea {
  param([string]$Text,[string]$From='agent',[string[]]$Tags=@(),[string]$Status='new',[double]$Score=0.0,[string]$Project='',[string]$Scope='bridge',[ValidateSet('critical','warning','info','')][string]$Severity='',[switch]$SkipCurator)
  $script:ideas.Add([pscustomobject]@{ text=$Text; project=$Project }) | Out-Null
  return ('itest-id-' + $script:ideas.Count)
}
$script:diffMode = 'diffusion'
function Get-ProjectAutopilotConfig {
  return [ordered]@{ enabled=$true; cooldownMinutes=5; maxTasksPerBatch=12; emptyCoordinatorLimit=3; diffusionMode=$script:diffMode; diffusionMinIndependentAtoms=2; diffusionMaxWaveSize=6; decomposeAheadLimit=1; skipBuildOnDocsOnly=$false; cleanFileOwnership=$false }
}

# ---- realistic marker: provider(provides user-api) + 2 consumers + 1 independent ----
$marker = @'
[
  {"slug":"provider","title":"Provider module","task":"Build the provider module that implements and exposes the user-api interface for the rest of the app to consume.","acceptance":["provider builds and exposes user-api"],"checks":["build"],"files":["src/provider.py"],"provides":["user-api"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"},
  {"slug":"consumer-a","title":"Consumer A screen","task":"Build consumer A screen which consumes the user-api interface to render its data view for the user.","acceptance":["consumer A builds against user-api"],"checks":["build"],"files":["src/a.py"],"consumes":["user-api"],"depends_on":["provider"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"consumer-b","title":"Consumer B screen","task":"Build consumer B screen which consumes the user-api interface to render a second data view for the user.","acceptance":["consumer B builds against user-api"],"checks":["build"],"files":["src/b.py"],"consumes":["user-api"],"depends_on":["provider"],"chapter":"Chapter 2","risk":"normal"},
  {"slug":"independent","title":"Independent util","task":"Build an independent utility module with no cross-atom interface dependency for shared helpers.","acceptance":["util builds"],"checks":["build"],"files":["src/util.py"],"depends_on":[],"chapter":"Chapter 1","risk":"normal"}
]
'@

# ================= RUN 1: diffusionMode='diffusion' =================
$script:diffMode = 'diffusion'
$script:jsonl.Clear(); $script:ideas.Clear()
$res = Add-ProjectBacklogFromMarker -Block $marker -Channel 'itest' -Source 'test' -MaxTasks 12

# count of entries for a given action (array-safe)
function Jsonl-Count { param([string]$Action) @($script:jsonl | Where-Object { [string]$_.action -eq $Action }).Count }
# FIRST matching entry as the OrderedDictionary itself. NOTE: do NOT index @(...)[0] on a single match --
# PowerShell unwraps a 1-element array to the OrderedDictionary, and dict[0] indexes INTO the dict (returns
# the value at position 0), not the first element. Select-Object -First 1 returns the dict; .key works on it.
function Jsonl-First { param([string]$Action) @($script:jsonl | Where-Object { [string]$_.action -eq $Action }) | Select-Object -First 1 }

$gate   = Jsonl-First 'project-autopilot-diffusion-gate'
$shaped = Jsonl-First 'project-autopilot-diffusion-shaped'
$man    = Jsonl-First 'project-autopilot-diffusion-stitch-manifest'

Assert-True ((Jsonl-Count 'project-autopilot-diffusion-contract-synthesis') -ge 1) "synthesis ran on the real coordinator-style marker"
Assert-True ($null -ne $gate -and [bool]$gate.enabled) "diffusion GATE went GREEN through the real function"
Assert-True ($null -ne $shaped) "batch was SHAPED (diffusion engaged, not collapsed to serial)"
Assert-True ($null -ne $shaped -and [int]$shaped.markers_added -ge 1) "shaping added >=1 freeze marker"
Assert-True ($null -ne $shaped -and [int]$shaped.stitch_added -ge 1) "shaping added the stitch atom"
Assert-True ($null -ne $shaped -and [int]$shaped.consumers_rewritten -ge 2) "both consumers rewired to the fast marker"
Assert-True ($null -ne $man -and -not [string]::IsNullOrWhiteSpace([string]$man.stitch_slug)) "A1 stitch drift-manifest persisted"

$ideaTexts = @($script:ideas | ForEach-Object { [string]$_.text })
Assert-True (@($ideaTexts | Where-Object { $_ -match '(?i)frozen contract stub|Freeze contract stub' }).Count -ge 1) "a freeze-marker atom was written to the backlog"
Assert-True (@($ideaTexts | Where-Object { $_ -match '(?i)Integration/stitch|integration stitch' }).Count -ge 1) "the stitch atom was written to the backlog"
Assert-True (@($ideaTexts).Count -gt 4) "diffusion batch is LARGER than the raw 4 atoms (markers+stitch added)"

# ================= RUN 2 (negative control): diffusionMode='off' =================
$script:diffMode = 'off'
$script:jsonl.Clear(); $script:ideas.Clear()
$null = Add-ProjectBacklogFromMarker -Block $marker -Channel 'itest' -Source 'test' -MaxTasks 12
Assert-True ((Jsonl-Count 'project-autopilot-diffusion-shaped') -eq 0) "negative control: diffusionMode=off -> NO shaping (serial)"

# cleanup
try { Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
