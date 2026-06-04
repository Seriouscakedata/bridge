# jobs.ps1 -- background job manager for LONG-running commands (e.g. a project run that
# takes hours to debug). The agent launches a job via the [[RUNJOB: cmd | dir]] marker;
# it runs detached with output to jobs/<id>.log; the driver polls (not idle, no per-turn
# timeout) and, when done, feeds the result back to the agents. Dot-sourced from common.ps1.

function Get-JobsDir { Join-Path (Get-BridgeRoot) 'jobs' }

function ConvertTo-BridgeJobPsLiteral {
  param([string]$Value)
  return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-BridgeJobNativeSource {
@'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class BridgeJobNative {
  private const UInt32 CREATE_SUSPENDED = 0x00000004;
  private const UInt32 CREATE_NO_WINDOW = 0x08000000;
  private const UInt32 STARTF_USESTDHANDLES = 0x00000100;
  private const UInt32 HANDLE_FLAG_INHERIT = 0x00000001;
  private const UInt32 INFINITE = 0xFFFFFFFF;
  private const UInt32 WAIT_TIMEOUT = 0x00000102;
  private const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
  private const UInt32 JOB_OBJECT_TERMINATE = 0x0008;
  private const int JobObjectExtendedLimitInformation = 9;

  [StructLayout(LayoutKind.Sequential)]
  private struct SECURITY_ATTRIBUTES {
    public int nLength;
    public IntPtr lpSecurityDescriptor;
    [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct STARTUPINFO {
    public UInt32 cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public UInt32 dwX;
    public UInt32 dwY;
    public UInt32 dwXSize;
    public UInt32 dwYSize;
    public UInt32 dwXCountChars;
    public UInt32 dwYCountChars;
    public UInt32 dwFillAttribute;
    public UInt32 dwFlags;
    public UInt16 wShowWindow;
    public UInt16 cbReserved2;
    public IntPtr lpReserved2;
    public IntPtr hStdInput;
    public IntPtr hStdOutput;
    public IntPtr hStdError;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct PROCESS_INFORMATION {
    public IntPtr hProcess;
    public IntPtr hThread;
    public UInt32 dwProcessId;
    public UInt32 dwThreadId;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UInt32 ActiveProcessLimit;
    public Int64 Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct IO_COUNTERS {
    public UInt64 ReadOperationCount;
    public UInt64 WriteOperationCount;
    public UInt64 OtherOperationCount;
    public UInt64 ReadTransferCount;
    public UInt64 WriteTransferCount;
    public UInt64 OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern IntPtr OpenJobObject(UInt32 dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, string lpName);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInfoClass, IntPtr lpJobObjectInfo, UInt32 cbJobObjectInfoLength);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool TerminateJobObject(IntPtr hJob, UInt32 uExitCode);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool TerminateProcess(IntPtr hProcess, UInt32 uExitCode);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool CloseHandle(IntPtr hObject);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, UInt32 nSize);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool SetHandleInformation(IntPtr hObject, UInt32 dwMask, UInt32 dwFlags);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CreateProcess(
    string lpApplicationName,
    StringBuilder lpCommandLine,
    IntPtr lpProcessAttributes,
    IntPtr lpThreadAttributes,
    [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
    UInt32 dwCreationFlags,
    IntPtr lpEnvironment,
    string lpCurrentDirectory,
    ref STARTUPINFO lpStartupInfo,
    out PROCESS_INFORMATION lpProcessInformation);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern UInt32 ResumeThread(IntPtr hThread);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern UInt32 WaitForSingleObject(IntPtr hHandle, UInt32 dwMilliseconds);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetExitCodeProcess(IntPtr hProcess, out UInt32 lpExitCode);

  public static bool TerminateNamedJob(string jobName, UInt32 exitCode) {
    if (String.IsNullOrWhiteSpace(jobName)) return false;
    IntPtr hJob = OpenJobObject(JOB_OBJECT_TERMINATE, false, jobName);
    if (hJob == IntPtr.Zero) return false;
    try {
      return TerminateJobObject(hJob, exitCode);
    } finally {
      CloseHandle(hJob);
    }
  }

  public static int RunCommandInJob(string jobName, string comSpec, string cmdFile, string workDir, string logPath, string readyPath, UInt32 timeoutMs) {
    if (String.IsNullOrWhiteSpace(jobName)) throw new InvalidOperationException("jobName is empty");
    if (String.IsNullOrWhiteSpace(cmdFile)) throw new InvalidOperationException("cmdFile is empty");
    if (String.IsNullOrWhiteSpace(logPath)) throw new InvalidOperationException("logPath is empty");
    if (String.IsNullOrWhiteSpace(comSpec)) comSpec = Environment.GetEnvironmentVariable("ComSpec");
    if (String.IsNullOrWhiteSpace(comSpec)) comSpec = "cmd.exe";

    string logDir = Path.GetDirectoryName(logPath);
    if (!String.IsNullOrWhiteSpace(logDir)) Directory.CreateDirectory(logDir);

    IntPtr hJob = IntPtr.Zero;
    IntPtr stdoutRead = IntPtr.Zero;
    IntPtr stdoutWrite = IntPtr.Zero;
    IntPtr stderrRead = IntPtr.Zero;
    IntPtr stderrWrite = IntPtr.Zero;
    IntPtr stdinRead = IntPtr.Zero;
    IntPtr stdinWrite = IntPtr.Zero;
    PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
    bool processCreated = false;
    bool processResumed = false;
    FileStream logStream = null;
    Thread stdoutThread = null;
    Thread stderrThread = null;
    SafeFileHandle stdoutSafeHandle = null;
    SafeFileHandle stderrSafeHandle = null;

    try {
      hJob = CreateJobObject(IntPtr.Zero, jobName);
      if (hJob == IntPtr.Zero) throw LastError("CreateJobObject");
      SetKillOnJobClose(hJob);

      SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
      sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
      sa.bInheritHandle = true;

      if (!CreatePipe(out stdoutRead, out stdoutWrite, ref sa, 0)) throw LastError("CreatePipe(stdout)");
      if (!SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0)) throw LastError("SetHandleInformation(stdout)");
      if (!CreatePipe(out stderrRead, out stderrWrite, ref sa, 0)) throw LastError("CreatePipe(stderr)");
      if (!SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0)) throw LastError("SetHandleInformation(stderr)");
      if (!CreatePipe(out stdinRead, out stdinWrite, ref sa, 0)) throw LastError("CreatePipe(stdin)");
      if (!SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0)) throw LastError("SetHandleInformation(stdin)");

      STARTUPINFO si = new STARTUPINFO();
      si.cb = (UInt32)Marshal.SizeOf(typeof(STARTUPINFO));
      si.dwFlags = STARTF_USESTDHANDLES;
      si.hStdInput = stdinRead;
      si.hStdOutput = stdoutWrite;
      si.hStdError = stderrWrite;

      string commandLine = QuoteForCreateProcess(comSpec) + " /d /s /c call " + QuoteForCreateProcess(cmdFile);
      string cwd = (!String.IsNullOrWhiteSpace(workDir) && Directory.Exists(workDir)) ? workDir : null;
      if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero, cwd, ref si, out pi)) {
        throw LastError("CreateProcess");
      }
      processCreated = true;

      CloseHandleSafe(ref stdoutWrite);
      CloseHandleSafe(ref stderrWrite);
      CloseHandleSafe(ref stdinRead);
      CloseHandleSafe(ref stdinWrite);

      if (!AssignProcessToJobObject(hJob, pi.hProcess)) {
        UInt32 err = (UInt32)Marshal.GetLastWin32Error();
        TerminateProcess(pi.hProcess, 1);
        throw new InvalidOperationException("AssignProcessToJobObject failed: " + err);
      }
      WriteReadyMarker(readyPath, pi.dwProcessId);

      logStream = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
      object logLock = new object();
      stdoutSafeHandle = new SafeFileHandle(stdoutRead, true);
      stdoutRead = IntPtr.Zero;
      stderrSafeHandle = new SafeFileHandle(stderrRead, true);
      stderrRead = IntPtr.Zero;
      SafeFileHandle stdoutThreadHandle = stdoutSafeHandle;
      SafeFileHandle stderrThreadHandle = stderrSafeHandle;
      stdoutThread = new Thread(delegate() { CopyPipeToLog(stdoutThreadHandle, logStream, logLock); });
      stderrThread = new Thread(delegate() { CopyPipeToLog(stderrThreadHandle, logStream, logLock); });
      stdoutThread.IsBackground = true;
      stderrThread.IsBackground = true;
      stdoutThread.Start();
      stderrThread.Start();

      UInt32 resumeResult = ResumeThread(pi.hThread);
      if (resumeResult == UInt32.MaxValue) throw LastError("ResumeThread");
      processResumed = true;

      UInt32 waitResult = WaitForSingleObject(pi.hProcess, timeoutMs);
      if (waitResult == WAIT_TIMEOUT) {
        TerminateJobObject(hJob, 1);
        TryJoinThread(stdoutThread, 5000);
        TryJoinThread(stderrThread, 5000);
        throw new InvalidOperationException("RunCommandInJob timed out after " + timeoutMs + " ms");
      }
      TryJoinThread(stdoutThread, -1);
      TryJoinThread(stderrThread, -1);

      UInt32 exitCode;
      if (!GetExitCodeProcess(pi.hProcess, out exitCode)) throw LastError("GetExitCodeProcess");
      return unchecked((int)exitCode);
    } finally {
      if (processCreated && !processResumed && pi.hProcess != IntPtr.Zero) {
        try { TerminateProcess(pi.hProcess, 1); } catch {}
      }
      CloseHandleSafe(ref stdoutRead);
      CloseHandleSafe(ref stdoutWrite);
      CloseHandleSafe(ref stderrRead);
      CloseHandleSafe(ref stderrWrite);
      CloseHandleSafe(ref stdinRead);
      CloseHandleSafe(ref stdinWrite);
      TryJoinThread(stdoutThread, 1000);
      TryJoinThread(stderrThread, 1000);
      DisposeHandleSafe(ref stdoutSafeHandle);
      DisposeHandleSafe(ref stderrSafeHandle);
      if (logStream != null) logStream.Dispose();
      if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
      if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
      if (hJob != IntPtr.Zero) CloseHandle(hJob);
    }
  }

  private static void SetKillOnJobClose(IntPtr hJob) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    IntPtr ptr = Marshal.AllocHGlobal(length);
    try {
      Marshal.StructureToPtr(info, ptr, false);
      if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, ptr, (UInt32)length)) {
        throw LastError("SetInformationJobObject");
      }
    } finally {
      Marshal.FreeHGlobal(ptr);
    }
  }

  private static void CopyPipeToLog(SafeFileHandle readHandle, FileStream logStream, object logLock) {
    using (FileStream pipeStream = new FileStream(readHandle, FileAccess.Read)) {
      byte[] buffer = new byte[4096];
      int count;
      while ((count = pipeStream.Read(buffer, 0, buffer.Length)) > 0) {
        lock (logLock) {
          logStream.Write(buffer, 0, count);
          logStream.Flush();
        }
      }
    }
  }

  private static void WriteReadyMarker(string readyPath, UInt32 processId) {
    if (String.IsNullOrWhiteSpace(readyPath)) return;
    string readyDir = Path.GetDirectoryName(readyPath);
    if (!String.IsNullOrWhiteSpace(readyDir)) Directory.CreateDirectory(readyDir);
    File.WriteAllText(readyPath, processId.ToString(), Encoding.UTF8);
  }

  private static string QuoteForCreateProcess(string value) {
    if (value == null) value = "";
    StringBuilder result = new StringBuilder();
    result.Append('"');
    int backslashes = 0;
    foreach (char c in value) {
      if (c == '\\') {
        backslashes++;
      } else if (c == '"') {
        result.Append('\\', backslashes * 2 + 1);
        result.Append('"');
        backslashes = 0;
      } else {
        if (backslashes > 0) {
          result.Append('\\', backslashes);
          backslashes = 0;
        }
        result.Append(c);
      }
    }
    if (backslashes > 0) result.Append('\\', backslashes * 2);
    result.Append('"');
    return result.ToString();
  }

  private static Exception LastError(string operation) {
    return new InvalidOperationException(operation + " failed: " + Marshal.GetLastWin32Error());
  }

  private static void CloseHandleSafe(ref IntPtr handle) {
    if (handle != IntPtr.Zero) {
      CloseHandle(handle);
      handle = IntPtr.Zero;
    }
  }

  private static void DisposeHandleSafe(ref SafeFileHandle handle) {
    if (handle != null) {
      handle.Dispose();
      handle = null;
    }
  }

  private static void TryJoinThread(Thread thread, int millisecondsTimeout) {
    if (thread == null) return;
    try {
      if (millisecondsTimeout < 0) {
        thread.Join();
      } else {
        thread.Join(millisecondsTimeout);
      }
    } catch (ThreadStateException) {}
  }
}
'@
}

function Ensure-BridgeJobNative {
  if ('BridgeJobNative' -as [type]) { return }
  Add-Type -TypeDefinition (Get-BridgeJobNativeSource) -Language CSharp
}

function Start-BridgeJob {
  # Launch $Command in the background. Returns a job record (hashtable) or $null.
  param([string]$Command, [string]$WorkDir = '', [int]$TimeoutHours = 24)
  if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
  $dir = Get-JobsDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $id = [guid]::NewGuid().ToString('N').Substring(0,8)
  $jobObjectName = "Global\BridgeJobObject-$id"
  $log  = Join-Path $dir "$id.log"
  $done = Join-Path $dir "$id.done"
  $ready = Join-Path $dir "$id.ready"
  $cmdF = Join-Path $dir "$id.cmd"
  $run  = Join-Path $dir "$id.run.ps1"
  if ([string]::IsNullOrWhiteSpace($WorkDir)) { try { $WorkDir = [string](Get-BridgeConfig).workRoot } catch { $WorkDir = (Get-BridgeRoot) } }
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($cmdF, [string]$Command, $u8)

  $nativeSource = Get-BridgeJobNativeSource
  $jobObjectNameLit = ConvertTo-BridgeJobPsLiteral $jobObjectName
  $cmdFLit = ConvertTo-BridgeJobPsLiteral $cmdF
  $workDirLit = ConvertTo-BridgeJobPsLiteral $WorkDir
  $logLit = ConvertTo-BridgeJobPsLiteral $log
  $readyLit = ConvertTo-BridgeJobPsLiteral $ready
  $timeoutMs = [UInt32]([math]::Min([long]$TimeoutHours * 3600000, [UInt32]::MaxValue - 1))
  $doneLit = ConvertTo-BridgeJobPsLiteral $done

  # Runner creates the named Windows Job Object, starts cmd.exe suspended, assigns it
  # to the job object, then resumes it. Stop-BridgeJob terminates the job object by
  # name and never needs to kill by recycled PID for new records.
  $runner = @"
`$ErrorActionPreference='Continue'
`$nativeSource = @'
$nativeSource
'@
if (-not ('BridgeJobNative' -as [type])) { Add-Type -TypeDefinition `$nativeSource -Language CSharp }
`$code = 1
try {
  `$code = [BridgeJobNative]::RunCommandInJob($jobObjectNameLit, `$env:ComSpec, $cmdFLit, $workDirLit, $logLit, $readyLit, $timeoutMs)
} catch {
  try { [System.IO.File]::AppendAllText($logLit, (([string]`$_) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding(`$false))) } catch {}
  `$code = 1
}
try { [System.IO.File]::WriteAllText($doneLit, [string]`$code, (New-Object System.Text.UTF8Encoding(`$false))) } catch {}
exit `$code
"@
  [System.IO.File]::WriteAllText($run, $runner, (New-Object System.Text.UTF8Encoding($true)))
  try {
    $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$run -WindowStyle Hidden -PassThru
    }
    $null = $p.Handle
    $ticks = 0; try { $ticks = $p.StartTime.Ticks } catch {}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 15) {
      if ((Test-Path -LiteralPath $ready) -or (Test-Path -LiteralPath $done)) { break }
      try { if ($p.HasExited) { break } } catch {}
      Start-Sleep -Milliseconds 100
    }
    return [ordered]@{
      id = $id; cmd = [string]$Command; dir = $WorkDir; pid = $p.Id; startTicks = $ticks
      log = $log; done = $done; ready = $ready; started = (Get-Date).ToUniversalTime().ToString('o')
      jobObjectName = $jobObjectName; stopMode = 'jobObject'
    }
  } catch { return $null }
}

function Test-JobDone {
  param($Job)
  try { return (Test-Path -LiteralPath ([string]$Job.done)) } catch { return $true }
}

function Get-JobResult {
  # Returns @{ exitCode; tail } for a finished job (tail of output, capped).
  param($Job)
  $code = ''
  try { $raw = Get-Content -LiteralPath ([string]$Job.done) -Raw -ErrorAction SilentlyContinue; if ($raw) { $code = ([string]$raw).Trim() } } catch {}
  $tail = ''
  try { $tail = Get-Content -LiteralPath ([string]$Job.log) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
  if ($null -eq $tail) { $tail = '' }
  if ($tail.Length -gt 3000) { $tail = '...(truncated)...' + "`n" + $tail.Substring($tail.Length - 3000) }
  return @{ exitCode = $code; tail = $tail }
}

function Stop-BridgeJob {
  # Stop a job's process tree by terminating its named Windows Job Object. This is
  # the primary path for new job records and avoids recycled-PID identity races.
  # Old records without jobObjectName cannot be stopped safely because any PID-based
  # kill has a recycled-PID race; refuse to kill instead of guessing.
  param($Job)
  if (-not $Job) { return }
  if (Test-JobDone $Job) { return }

  $jobObjectName = ''
  try { $jobObjectName = [string]$Job.jobObjectName } catch {}
  if ([string]::IsNullOrWhiteSpace($jobObjectName)) { return }

  if (-not [string]::IsNullOrWhiteSpace($jobObjectName)) {
    try {
      Ensure-BridgeJobNative
      for ($i = 0; $i -lt 30; $i++) {
        if (Test-JobDone $Job) { return }
        if ([BridgeJobNative]::TerminateNamedJob($jobObjectName, 1)) { return }
        Start-Sleep -Milliseconds 100
      }
    } catch {}
    return
  }
}
