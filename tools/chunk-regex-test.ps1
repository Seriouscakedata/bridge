$rx = '(?im)^\s*STATUS:\s*CONTINUE-CHUNK\s*:\s*(\d+)\s*/\s*(\d+)\s*$'
$cases = @(
  @{ T='STATUS: CONTINUE-CHUNK:2/5'; Expect=@(2,5) },
  @{ T="report`nSTATUS: CONTINUE-CHUNK:1/3"; Expect=@(1,3) },
  @{ T='STATUS: CONTINUE-CHUNK : 10 / 10'; Expect=@(10,10) },
  @{ T='STATUS: DONE'; Expect=$null },
  @{ T='STATUS: CONTINUE'; Expect=$null },
  @{ T='STATUS: CONTINUE-CHUNK:7/10'; Expect=@(7,10) },
  @{ T='inline mention STATUS: CONTINUE-CHUNK:2/3 here'; Expect=$null },
  @{ T="отчёт о работе`r`nеще строка`r`nSTATUS: CONTINUE-CHUNK:3/4`r`n"; Expect=@(3,4) }
)
$pass = 0; $fail = 0
foreach ($c in $cases) {
  $m = [regex]::Match($c.T, $rx)
  if ($c.Expect) {
    if (-not $m.Success) { "FAIL: should match -> $($c.T -replace "`r?`n",' \n ')"; $fail++; continue }
    $g1=[int]$m.Groups[1].Value; $g2=[int]$m.Groups[2].Value
    if ($g1 -eq $c.Expect[0] -and $g2 -eq $c.Expect[1]) {
      "OK: $($c.T -replace "`r?`n",' \n ') -> $g1/$g2"; $pass++
    } else {
      "FAIL: $($c.T -replace "`r?`n",' \n ') -> $g1/$g2 vs $($c.Expect[0])/$($c.Expect[1])"; $fail++
    }
  } else {
    if ($m.Success) { "FAIL: should NOT match -> $($c.T -replace "`r?`n",' \n ')"; $fail++ }
    else { "OK: not matched -> $($c.T -replace "`r?`n",' \n ')"; $pass++ }
  }
}
"`n=== $pass passed / $fail failed ==="
