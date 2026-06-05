# test-canary-smoke-source-files.ps1 -- verify canary smoke parses source ps1 files only.
param()

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

function Assert-True {
  param([bool]$Cond, [string]$Msg)
  if ($Cond) {
    Write-Host "PASS: $Msg"
    $script:pass++
  } else {
    Write-Host "FAIL: $Msg"
    $script:fail++
  }
}

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\canary.ps1')

Assert-True ([bool](Get-Command Get-CanarySmokePs1Files -ErrorAction SilentlyContinue)) "Get-CanarySmokePs1Files exists"

$tmpParent = Join-Path $root 'tmp'
New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null

$tmp = Join-Path $tmpParent ("canary-src-test-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  & git -C $tmp init --initial-branch=main 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { & git -C $tmp init 2>$null | Out-Null }
  & git -C $tmp config user.email "test@test" 2>$null | Out-Null
  & git -C $tmp config user.name "test" 2>$null | Out-Null

  $good = Join-Path $tmp 'good.ps1'
  [System.IO.File]::WriteAllText($good, "function Get-Foo { 'ok' }`r`n", (New-Object System.Text.UTF8Encoding($true)))
  & git -C $tmp add good.ps1 2>$null | Out-Null
  & git -C $tmp commit -m "init" 2>$null | Out-Null

  [System.IO.File]::WriteAllText((Join-Path $tmp '.gitignore'), "jobs/`r`n", (New-Object System.Text.UTF8Encoding($false)))
  & git -C $tmp add .gitignore 2>$null | Out-Null
  & git -C $tmp commit -m "gitignore" 2>$null | Out-Null

  New-Item -ItemType Directory -Path (Join-Path $tmp 'jobs') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmp 'jobs\bad.run.ps1'), "fix broken syntax ???`n", (New-Object System.Text.UTF8Encoding($false)))

  $files = @(Get-CanarySmokePs1Files -RepoRoot $tmp)
  $names = @($files | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) })

  Assert-True ($names -contains 'good.ps1') "git path: good.ps1 is included"
  Assert-True ($names -notcontains 'bad.run.ps1') "git path: ignored jobs/bad.run.ps1 is excluded"
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$tmp2 = Join-Path $tmpParent ("canary-src-fallback-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmp2 -Force | Out-Null
try {
  [System.IO.File]::WriteAllText((Join-Path $tmp2 'ok.ps1'), "function Get-Bar { 'ok' }`r`n", (New-Object System.Text.UTF8Encoding($true)))
  New-Item -ItemType Directory -Path (Join-Path $tmp2 'jobs') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $tmp2 'jobs\bad.run.ps1'), "fix broken syntax ???`n", (New-Object System.Text.UTF8Encoding($false)))

  $files2 = @(Get-CanarySmokePs1Files -RepoRoot $tmp2)
  $names2 = @($files2 | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) })

  Assert-True ($names2 -contains 'ok.ps1') "fallback: ok.ps1 is included"
  Assert-True ($names2 -notcontains 'bad.run.ps1') "fallback: jobs/bad.run.ps1 is excluded"
} finally {
  Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nRESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
