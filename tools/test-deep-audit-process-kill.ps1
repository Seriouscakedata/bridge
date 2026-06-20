$ErrorActionPreference = 'Stop'

function Get-DeepAuditNativeChildProcessIds {
  param([int]$ParentPid)
  if ($ParentPid -le 0) { return @() }
  try {
    if (-not ('DeepAuditProcessTreeNative' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DeepAuditProcessTreeNative {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
  public struct PROCESSENTRY32 {
    public UInt32 dwSize;
    public UInt32 cntUsage;
    public UInt32 th32ProcessID;
    public IntPtr th32DefaultHeapID;
    public UInt32 th32ModuleID;
    public UInt32 cntThreads;
    public UInt32 th32ParentProcessID;
    public Int32 pcPriClassBase;
    public UInt32 dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string szExeFile;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern IntPtr CreateToolhelp32Snapshot(UInt32 dwFlags, UInt32 th32ProcessID);

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  private static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  private static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool CloseHandle(IntPtr hObject);

  public static int[] GetChildProcessIds(int parentPid) {
    const UInt32 TH32CS_SNAPPROCESS = 0x00000002;
    List<int> result = new List<int>();
    IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == new IntPtr(-1)) { return result.ToArray(); }
    try {
      PROCESSENTRY32 entry = new PROCESSENTRY32();
      entry.dwSize = (UInt32)Marshal.SizeOf(typeof(PROCESSENTRY32));
      if (!Process32First(snapshot, ref entry)) { return result.ToArray(); }
      do {
        if ((int)entry.th32ParentProcessID == parentPid) {
          result.Add((int)entry.th32ProcessID);
        }
      } while (Process32Next(snapshot, ref entry));
    } finally {
      CloseHandle(snapshot);
    }
    return result.ToArray();
  }
}
'@ -ErrorAction Stop | Out-Null
    }
    return @([DeepAuditProcessTreeNative]::GetChildProcessIds($ParentPid))
  } catch {
    return @()
  }
}

function Stop-DeepAuditProcessTree {
  param([System.Diagnostics.Process]$Proc)
  if (-not $Proc) { return }
  try { if ($Proc.HasExited) { return } } catch {}
  $rootPid = 0
  try { $rootPid = $Proc.Id } catch {}
  if ($rootPid -gt 0) {
    try { & taskkill /F /T /PID $rootPid 2>$null | Out-Null } catch {}
    try { if ($Proc.WaitForExit(1000)) { return } } catch {}
    $descendantPids = @()
    try {
      $seen = @{}
      $pending = New-Object System.Collections.Queue
      [void]$pending.Enqueue($rootPid)
      $seen[[string]$rootPid] = $true
      while ($pending.Count -gt 0) {
        $parentPid = [int]$pending.Dequeue()
        $childIds = @()
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentPid" -ErrorAction SilentlyContinue)
        foreach ($child in $children) { $childIds += [int]$child.ProcessId }
        $childIds += @(Get-DeepAuditNativeChildProcessIds -ParentPid $parentPid)
        foreach ($childPid in @($childIds | Select-Object -Unique)) {
          if ($childPid -le 0 -or $seen.ContainsKey([string]$childPid)) { continue }
          $seen[[string]$childPid] = $true
          $descendantPids += $childPid
          [void]$pending.Enqueue($childPid)
        }
      }
    } catch {}
    foreach ($descPid in @($descendantPids | Select-Object -Unique | Sort-Object -Descending)) {
      try { Stop-Process -Id $descPid -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch {}
  } else {
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch {}
  }
}

function Get-RequiredTimeoutSec {
  param($Cfg, [int]$TimeoutSec)
  $requiredMultiplier = 2.0
  if ($Cfg -and $Cfg.audit -and ($Cfg.audit.PSObject.Properties.Name -contains 'requiredSliceTimeoutMultiplier')) {
    try { $requiredMultiplier = [double]$Cfg.audit.requiredSliceTimeoutMultiplier } catch {}
  }
  if ($requiredMultiplier -lt 1.0) { $requiredMultiplier = 1.0 }
  return [int]([Math]::Ceiling($TimeoutSec * $requiredMultiplier))
}

function Assert-True {
  param([bool]$Condition, [string]$Name, [string]$Message)
  if (-not $Condition) { throw "FAIL $Name - $Message" }
  Write-Host "PASS $Name"
}

Stop-DeepAuditProcessTree -Proc $null
Assert-True -Condition $true -Name 'stop-process-tree-no-proc' -Message 'null proc threw'

$proc = $null
$childPids = @()
try {
  $psExe = (Get-Process -Id $PID).Path
  $childCommand = '$psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = ''ping.exe''; $psi.Arguments = ''-n 999 127.0.0.1''; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $child = [System.Diagnostics.Process]::Start($psi); Write-Output $child.Id; Start-Sleep -Seconds 999'
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $childLine = $proc.StandardOutput.ReadLine()
  if ([string]::IsNullOrWhiteSpace($childLine)) { throw 'FAIL stop-process-tree-kills-child - child pid was not reported' }
  $childPids = @([int]$childLine)
  Start-Sleep -Seconds 1
  if (-not (Get-Process -Id $childPids[0] -ErrorAction SilentlyContinue)) { throw 'FAIL stop-process-tree-kills-child - child process not alive before kill' }
  Stop-DeepAuditProcessTree -Proc $proc
  [void]$proc.WaitForExit(2000)
  $proc.Refresh()
  $remainingChildren = @()
  foreach ($childPid in $childPids) {
    if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) { $remainingChildren += $childPid }
  }
  Assert-True -Condition ($proc.HasExited -and $remainingChildren.Count -eq 0) -Name 'stop-process-tree-kills-child' -Message "rootExited=$($proc.HasExited) remainingChildren=$($remainingChildren -join ',')"
} finally {
  if ($proc -and -not $proc.HasExited) {
    try { & taskkill /F /T /PID $proc.Id 2>$null | Out-Null } catch {}
  }
  foreach ($childPid in $childPids) {
    try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
  }
}

$baseTimeout = 10
$cfgCustom = [pscustomobject]@{ audit = [pscustomobject]@{ requiredSliceTimeoutMultiplier = 3.0 } }
$requiredTimeoutSec = Get-RequiredTimeoutSec -Cfg $cfgCustom -TimeoutSec $baseTimeout
Assert-True -Condition ($requiredTimeoutSec -gt $baseTimeout) -Name 'required-timeout-larger' -Message "required=$requiredTimeoutSec base=$baseTimeout"

$requiredTimeoutSec = Get-RequiredTimeoutSec -Cfg ([pscustomobject]@{ audit = [pscustomobject]@{} }) -TimeoutSec $baseTimeout
Assert-True -Condition ($requiredTimeoutSec -eq 20) -Name 'required-multiplier-default' -Message "required=$requiredTimeoutSec"

$cfgFloor = [pscustomobject]@{ audit = [pscustomobject]@{ requiredSliceTimeoutMultiplier = -4.0 } }
$requiredTimeoutSec = Get-RequiredTimeoutSec -Cfg $cfgFloor -TimeoutSec $baseTimeout
Assert-True -Condition ($requiredTimeoutSec -eq $baseTimeout) -Name 'required-multiplier-floor' -Message "required=$requiredTimeoutSec base=$baseTimeout"

Write-Host 'deep-audit process-kill tests passed'
