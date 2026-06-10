#Requires -Version 5.1
# test-feature-verifier.ps1 -- static guards for the unsafe feature-verifier scenarios.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [object]$Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

$scenarioRunner = Get-Content -LiteralPath (Join-Path $root 'tools\scenario.ps1') -Raw -Encoding UTF8
$backlogAddScenario = Get-Content -LiteralPath (Join-Path $root 'tools\scenarios\backlog-add.js') -Raw -Encoding UTF8

Check 'runner creates backlog-flow sandbox channel' ($scenarioRunner.Contains("`$sandboxChannelSlug = 'feature-verifier-backlog-flow-' + [Guid]::NewGuid().ToString('N')"))
Check 'runner replaces existing channel query param' ($scenarioRunner.Contains("Equals([string]`$name, 'channel', [System.StringComparison]::OrdinalIgnoreCase)") -and $scenarioRunner.Contains("`$builder.Query = (`$parts -join '&')"))
Check 'runner refuses backlog-add outside sandbox' ($scenarioRunner.Contains('Refusing to run backlog-add outside feature-verifier sandbox channel'))
Check 'browser scenario reads channel from URL' ($backlogAddScenario.Contains("searchParams.get('channel')"))
Check 'browser scenario requires sandbox channel' ($backlogAddScenario.Contains('scenario uses feature-verifier sandbox channel') -and $backlogAddScenario.Contains('Refusing backlog-add outside feature-verifier sandbox channel'))
Check 'browser scenario posts to selected channel' ($backlogAddScenario.Contains("JSON.stringify({text: taskText, status: 'new', channel: channel, skip_curator: true})"))
Check 'browser scenario deletes from selected channel' ($backlogAddScenario.Contains('JSON.stringify({id: addResp.id, channel: channel})'))

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
