# primitives.ps1 -- ONE shared low-level helper layer (2026-06-09, subtractive audit Tier 2).
#
# WHY: the audit found the SAME primitive re-authored across the codebase with DIVERGENT
# semantics -- not a style smell, a correctness bug. Concretely:
#   Get-BacklogGovernorObjectValue (governor:5)  returns a present-but-null property value
#   Get-BacklogPackObjectValue     (workpack:5)   treats a present-but-null value as MISSING
# Both are called interchangeably across the gate stack, so one gate can see a field and another
# can't, from the same data. Plus 7x ConvertTo-*StringArray, 4x *Truthy, 11x path-normalizers.
#
# This module is the single source for those primitives. Existing domain copies become thin
# delegates that PASS THE FLAG matching their original behavior, so behavior is byte-identical
# while there is now ONE implementation to fix. Keep dependency-free; load FIRST.

function Get-BridgeObjectValue {
  # Canonical safe property/key accessor. Superset of every prior copy:
  #   - $Object may be $null, an IDictionary, or a PSObject
  #   - $Names is an ordered preference list (first match wins), case-insensitive
  #   - -NullAsMissing: a present-but-NULL value is treated as not-found (workpack semantics).
  #     Without it, a present-but-null value is returned as-is (governor semantics).
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null,
    [switch]$NullAsMissing
  )
  if ($null -eq $Object) { return $Default }
  foreach ($name in $Names) {
    $found = $false
    $val = $null
    if ($Object -is [System.Collections.IDictionary]) {
      foreach ($key in @($Object.Keys)) {
        if ([string]::Equals([string]$key, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
          $found = $true; $val = $Object[$key]; break
        }
      }
    } else {
      try {
        $prop = @($Object.PSObject.Properties | Where-Object {
          [string]::Equals([string]$_.Name, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($prop.Count -gt 0) { $found = $true; $val = $prop[0].Value }
      } catch { $found = $false }
    }
    if ($found) {
      if ($NullAsMissing -and ($null -eq $val)) { continue }
      return $val
    }
  }
  return $Default
}

function ConvertTo-BridgeStringArray {
  # Canonical string-array coercion: $null -> @(); string -> @(string); IEnumerable -> strings;
  # scalar -> @(scalar). Whitespace/empty entries are dropped, entries are trimmed-as-strings.
  param([Parameter(Mandatory=$false)]$Value)
  if ($null -eq $Value) { return @() }
  $items = $null
  if ($Value -is [string]) { $items = @($Value) }
  elseif ($Value -is [System.Collections.IEnumerable]) { $items = @($Value) }
  else { $items = @($Value) }
  return @($items | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Test-BridgeTruthy {
  # Canonical truthy coercion. true/1/yes/on/enabled -> $true; false/0/no/off/disabled -> $false;
  # anything else -> $Default. Matches the union of the prior *Truthy/Pack-Bool copies.
  param($Value, [bool]$Default = $true)
  try {
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (@('true','1','yes','on','enabled') -contains $s) { return $true }
    if (@('false','0','no','off','disabled') -contains $s) { return $false }
  } catch {}
  return $Default
}
