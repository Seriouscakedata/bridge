#Requires -Version 5.1
# test-project-artifact-policy.ps1 -- generated artifact policy fixtures.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\project-artifact-policy.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

Check 'verify chapter dir is generated' (Test-ProjectGeneratedArtifactPath '.verify_ch7/summary.json')
Check 'runs chapter dir is generated' (Test-ProjectGeneratedArtifactPath 'runs_ch6_check/video.mp4')
Check 'verify chapter dir is verification artifact' (Test-ProjectVerificationArtifactPath '.verify_ch7/summary.json')
Check 'runs chapter check dir is verification artifact' (Test-ProjectVerificationArtifactPath 'runs_ch6_check/video.mp4')
Check 'runtime runs dir is not verification artifact' (-not (Test-ProjectVerificationArtifactPath 'runs/live/video.mp4'))
Check 'python cache is generated' (Test-ProjectGeneratedArtifactPath 'src/__pycache__/app.cpython-311.pyc')
Check 'source file is durable' (-not (Test-ProjectGeneratedArtifactPath 'src/app.py'))
Check 'project contract is durable' (-not (Test-ProjectGeneratedArtifactPath '.bridge/project-contract.json'))

$tmpRoot = Join-Path (Join-Path $root 'tmp') ('bridge-project-artifact-policy-test-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
  & git -C $tmpRoot init -q *> $null
  & git -C $tmpRoot config user.email test@example.invalid *> $null
  & git -C $tmpRoot config user.name 'Bridge Test' *> $null
  & git -C $tmpRoot config core.autocrlf false *> $null

  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'README.md'), "init`n", [System.Text.UTF8Encoding]::new($false))
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot '.verify_ch7') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'runs_ch6_check') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'runs\live') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'src') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot '.verify_ch7\summary.json'), "{}" + "`n", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'runs_ch6_check\video.mp4'), "fake`n", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'runs\live\video.mp4'), "fake`n", [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'src\app.py'), "print('ok')`n", [System.Text.UTF8Encoding]::new($false))
  & git -C $tmpRoot add README.md .verify_ch7/summary.json runs_ch6_check/video.mp4 runs/live/video.mp4 src/app.py *> $null
  & git -C $tmpRoot commit -q -m init *> $null

  $tracked = @(Get-ProjectTrackedGeneratedArtifactPaths -ProjectRoot $tmpRoot)
  Check 'tracked generated detects verify artifact' (@($tracked) -contains '.verify_ch7/summary.json') $tracked
  Check 'tracked generated detects runs artifact' (@($tracked) -contains 'runs_ch6_check/video.mp4') $tracked
  Check 'tracked generated detects runtime runs artifact' (@($tracked) -contains 'runs/live/video.mp4') $tracked
  Check 'tracked generated excludes source' (@($tracked) -notcontains 'src/app.py') $tracked

  $blockingTracked = @(Get-ProjectTrackedGeneratedArtifactPaths -ProjectRoot $tmpRoot -ExcludeVerificationArtifacts)
  Check 'acceptance tracked generated excludes verify artifact' (@($blockingTracked) -notcontains '.verify_ch7/summary.json') $blockingTracked
  Check 'acceptance tracked generated excludes runs check fixture' (@($blockingTracked) -notcontains 'runs_ch6_check/video.mp4') $blockingTracked
  Check 'acceptance tracked generated keeps runtime runs artifact blocking' (@($blockingTracked) -contains 'runs/live/video.mp4') $blockingTracked
} finally {
  $safeTmp = [System.IO.Path]::GetFullPath((Join-Path $root 'tmp')).TrimEnd('\') + '\'
  $fullTmp = [System.IO.Path]::GetFullPath($tmpRoot)
  if ($fullTmp.StartsWith($safeTmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTmp)) {
    Remove-Item -LiteralPath $fullTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}
Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
