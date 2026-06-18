#Requires -Version 5.1
<#
  lapa-control.ps1 -- a STANDALONE bridge tool that invokes лапа (the desktop
  controller at C:\Users\rafie\bridge-projects\lapa) as a callable GUI-task tool.

  This is a TOOL, not control-plane. It is NOT dot-sourced by the driver, imports
  no bridge library (no common.ps1), and changes no existing bridge file. The
  operator (Claude) or a bridge task runs:

      . <this file>            # or:  powershell -File lapa-control.ps1 ... (see bottom)
      Invoke-LapaSkill -Skill 'telegram-send' -Params @{ contact = 'X'; message = 'Y' }

  Under the hood it shells out to  `python -m lapa.cli <skill> --flag value ...`
  with cwd = the лапа project root, captures the JSON ExecutionReport that лапа
  prints to stdout, parses it (ConvertFrom-Json), and returns a structured object:

      [pscustomobject]@{
          status     = 'completed' | 'incomplete' | 'aborted' | 'refused' | 'stopped' | 'error'
          evidence   = @( <evidence objects from the report> )
          proof_path = '<screenshot ref>' or $null
          raw        = <the full parsed report object, or $null when unparseable>
          ok         = $true only for a fully-witnessed 'completed' report
          exit_code  = <the python process exit code>
          stdout     = <raw captured stdout>
          stderr     = <raw captured stderr>
          error      = <a message when status='error' (non-JSON / launch failure)>
      }

  It NEVER throws an uncaught exception: any failure (python missing, non-zero
  exit, non-JSON output, malformed report) is folded into a structured object
  with status 'error' and a human-readable .error field. A caller can branch on
  $r.ok / $r.status without a try/catch.

  SAFETY: лапа enforces the chat-identity gate and the declared-risk ladder on its
  side. A real send to a human is a MEDIUM-risk action -- лапа refuses it
  fail-closed unless its own safety policy authorises it. This wrapper does not
  weaken any лапа gate; it only marshals arguments and parses the report.
#>

Set-StrictMode -Version Latest

# The лапа project root -- the cwd `python -m lapa.cli` must run from so the
# `lapa` package is importable. Overridable via $env:LAPA_ROOT for relocation.
$script:LapaRoot = if ($env:LAPA_ROOT) { $env:LAPA_ROOT } else { 'C:\Users\rafie\bridge-projects\lapa' }

# The python executable. Overridable via $env:LAPA_PYTHON (e.g. a venv python).
$script:LapaPython = if ($env:LAPA_PYTHON) { $env:LAPA_PYTHON } else { 'python' }

# Skill name -> CLI subcommand + the param-key -> flag map. This is the ONLY place
# that knows the CLI surface; adding a skill means adding one entry here. Each
# value maps a friendly @Params hashtable key to the lapa.cli flag it becomes.
$script:LapaSkillMap = @{
    'telegram-send' = @{
        command = 'telegram-send'
        flags   = @{
            contact        = '--contact'
            message        = '--message'
            title_contains = '--title-contains'
            timeout        = '--timeout'
            stop_flag      = '--stop-flag'
            proof          = '--proof'
        }
    }
    'telegram-send-sticker' = @{
        command = 'telegram-send-sticker'
        flags   = @{
            contact        = '--contact'
            description    = '--description'
            title_contains = '--title-contains'
            min_confidence = '--min-confidence'
            timeout        = '--timeout'
            stop_flag      = '--stop-flag'
            proof          = '--proof'
        }
    }
    'open-app' = @{
        command = 'open-app'
        flags   = @{
            name      = '--name'
            timeout   = '--timeout'
            stop_flag = '--stop-flag'
            proof     = '--proof'
        }
    }
    'type' = @{
        command = 'type'
        flags   = @{
            app       = '--app'
            field     = '--field'
            text      = '--text'
            timeout   = '--timeout'
            stop_flag = '--stop-flag'
            proof     = '--proof'
        }
    }
}

function Get-LapaSkillNames {
    <# The skill names this wrapper can invoke (the keys of the skill map). #>
    [CmdletBinding()]
    param()
    return @($script:LapaSkillMap.Keys | Sort-Object)
}

function ConvertTo-LapaArgs {
    <#
      Turn a skill name + a @Params hashtable into the ordered argv for
      `python -m lapa.cli`. Unknown skills / unknown param keys are reported via
      the returned object's .error (this function never throws).

      Returns [pscustomobject]@{ ok; argv = @(...); error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Skill,
        [hashtable]$Params = @{}
    )
    if (-not $script:LapaSkillMap.ContainsKey($Skill)) {
        return [pscustomobject]@{
            ok    = $false
            argv  = @()
            error = ("unknown skill '{0}'; known: {1}" -f $Skill, ((Get-LapaSkillNames) -join ', '))
        }
    }
    $spec = $script:LapaSkillMap[$Skill]
    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add('-m'); $argv.Add('lapa.cli'); $argv.Add([string]$spec.command)

    $unknown = @()
    if ($Params) {
        foreach ($key in $Params.Keys) {
            if (-not $spec.flags.ContainsKey($key)) { $unknown += $key; continue }
            $value = $Params[$key]
            if ($null -eq $value) { continue }   # a $null param is simply omitted
            $argv.Add([string]$spec.flags[$key])
            $argv.Add([string]$value)
        }
    }
    if ($unknown.Count -gt 0) {
        return [pscustomobject]@{
            ok    = $false
            argv  = @($argv.ToArray())
            error = ("unknown param(s) for skill '{0}': {1}; known: {2}" -f `
                $Skill, ($unknown -join ', '), (($spec.flags.Keys | Sort-Object) -join ', '))
        }
    }
    return [pscustomobject]@{ ok = $true; argv = @($argv.ToArray()); error = $null }
}

function New-LapaErrorResult {
    <# A uniform failed result object (status='error'); never throws. #>
    [CmdletBinding()]
    param(
        [string]$Message,
        [int]$ExitCode = -1,
        [string]$Stdout = '',
        [string]$Stderr = ''
    )
    return [pscustomobject]@{
        status     = 'error'
        evidence   = @()
        proof_path = $null
        raw        = $null
        ok         = $false
        exit_code  = $ExitCode
        stdout     = $Stdout
        stderr     = $Stderr
        error      = $Message
    }
}

function Invoke-PythonCapture {
    <#
      Run `python <argv>` with cwd = $WorkingDirectory, capturing stdout/stderr to
      temp files (robust across the PS 5.1 native-stderr quirk). Returns
      [pscustomobject]@{ ok; exit_code; stdout; stderr; error }. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$PythonExe = $script:LapaPython
    )
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        return [pscustomobject]@{
            ok = $false; exit_code = -1; stdout = ''; stderr = ''
            error = ("лапа project root not found: {0}" -f $WorkingDirectory)
        }
    }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $PythonExe -ArgumentList $ArgumentList `
            -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        $out = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile) } else { '' }
        $err = if (Test-Path -LiteralPath $errFile) { [System.IO.File]::ReadAllText($errFile) } else { '' }
        return [pscustomobject]@{
            ok = $true; exit_code = [int]$proc.ExitCode; stdout = $out; stderr = $err; error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; exit_code = -1; stdout = ''; stderr = ''
            error = ("failed to launch python '{0}': {1}" -f $PythonExe, $_.Exception.Message)
        }
    }
    finally {
        foreach ($f in @($outFile, $errFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function ConvertFrom-LapaStdout {
    <#
      Parse лапа's stdout into a structured result. лапа prints the JSON report on
      one line, optionally followed by a `PROOF=<path>` line. We scan for the LAST
      line that parses as a JSON object with a 'status' field (robust to incidental
      leading output), and pick up the PROOF= line for the proof path.

      Returns the structured result object, or a status='error' object when no JSON
      report line is found. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$Stdout = '',
        [string]$Stderr = '',
        [int]$ExitCode = 0
    )
    $report = $null
    $proofLine = $null
    $lines = @()
    if ($Stdout) { $lines = $Stdout -split "`r?`n" }

    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -like 'PROOF=*') { $proofLine = $t.Substring(6).Trim(); continue }
        if ($t.StartsWith('{')) {
            try {
                $candidate = $t | ConvertFrom-Json -ErrorAction Stop
                if ($candidate -and ($candidate.PSObject.Properties.Name -contains 'status')) {
                    $report = $candidate   # keep the last valid report line
                }
            }
            catch { }   # not JSON / not a report -- ignore this line
        }
    }

    if ($null -eq $report) {
        return (New-LapaErrorResult `
            -Message ("лапа produced no parseable JSON report (exit {0}). stderr: {1}" -f `
                $ExitCode, ($Stderr.Trim())) `
            -ExitCode $ExitCode -Stdout $Stdout -Stderr $Stderr)
    }

    # Prefer the explicit PROOF= line; else the first screenshot evidence ref.
    $proof = $proofLine
    $evidence = @()
    if ($report.PSObject.Properties.Name -contains 'evidence' -and $report.evidence) {
        $evidence = @($report.evidence)
        if (-not $proof) {
            foreach ($ev in $evidence) {
                if (($ev.PSObject.Properties.Name -contains 'kind') -and ($ev.kind -eq 'screenshot')) {
                    if (($ev.PSObject.Properties.Name -contains 'payload') -and $ev.payload -and `
                        ($ev.payload.PSObject.Properties.Name -contains 'ref')) {
                        $proof = [string]$ev.payload.ref; break
                    }
                }
            }
        }
    }

    $status = [string]$report.status
    return [pscustomobject]@{
        status     = $status
        evidence   = $evidence
        proof_path = $(if ($proof) { $proof } else { $null })
        raw        = $report
        ok         = ($status -eq 'completed')
        exit_code  = $ExitCode
        stdout     = $Stdout
        stderr     = $Stderr
        error      = $null
    }
}

function Invoke-LapaSkill {
    <#
      .SYNOPSIS
        Invoke a лапа skill (a deterministic GUI task) and return its parsed report.

      .DESCRIPTION
        Shells out to `python -m lapa.cli <skill> --flags...` with cwd = the лапа
        project root, captures the JSON ExecutionReport from stdout, parses it, and
        returns a structured object {status, evidence, proof_path, raw, ok,
        exit_code, stdout, stderr, error}. Never throws -- a launch failure /
        non-zero exit / non-JSON output all return a status='error' object.

      .PARAMETER Skill
        The skill name: 'telegram-send', 'telegram-send-sticker', 'open-app', or 'type'.

      .PARAMETER Params
        A hashtable of skill params. Keys map to CLI flags per the skill:
          telegram-send:         contact, message, [title_contains], [timeout], [stop_flag], [proof]
          telegram-send-sticker: contact, description, [title_contains], [min_confidence], [timeout], [stop_flag], [proof]
          open-app:              name, [timeout], [stop_flag], [proof]
          type:                  app, field, text, [timeout], [stop_flag], [proof]

        NOTE: telegram-send-sticker is CANVAS MODE (vision + coordinate click). The
        sticker send is MEDIUM-risk; the CLI has no confirm hook, so an unattended
        wrapper run is DENIED fail-closed by лапа's safety ladder (status
        'incomplete'), never an auto-send. See USING_LAPA.md for the honest caveat.

      .EXAMPLE
        Invoke-LapaSkill -Skill 'telegram-send' -Params @{ contact='Булочка'; message='привет' }

      .EXAMPLE
        $r = Invoke-LapaSkill -Skill 'open-app' -Params @{ name='Notepad' }
        if ($r.ok) { "opened; evidence: $($r.evidence.Count)" } else { "failed: $($r.status)" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Skill,
        [hashtable]$Params = @{},
        [string]$LapaRoot = $script:LapaRoot,
        [string]$PythonExe = $script:LapaPython
    )

    $built = ConvertTo-LapaArgs -Skill $Skill -Params $Params
    if (-not $built.ok) {
        return (New-LapaErrorResult -Message $built.error)
    }

    $run = Invoke-PythonCapture -ArgumentList $built.argv -WorkingDirectory $LapaRoot -PythonExe $PythonExe
    if (-not $run.ok) {
        return (New-LapaErrorResult -Message $run.error -ExitCode $run.exit_code `
            -Stdout $run.stdout -Stderr $run.stderr)
    }

    return (ConvertFrom-LapaStdout -Stdout $run.stdout -Stderr $run.stderr -ExitCode $run.exit_code)
}

# When run directly as a script (not dot-sourced), expose a thin CLI so the tool is
# usable from `powershell -File lapa-control.ps1 -Skill ... -ParamsJson '{...}'`.
# Dot-sourcing (the primary usage) skips this block ($MyInvocation.InvocationName
# is '.'), so importing the functions has no side effects.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s') {
    $cliSkill = $null; $cliParamsJson = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            '-Skill'      { $cliSkill = [string]$args[$i + 1]; $i++ }
            '-ParamsJson' { $cliParamsJson = [string]$args[$i + 1]; $i++ }
        }
    }
    if ($cliSkill) {
        $p = @{}
        if ($cliParamsJson) {
            try {
                $obj = $cliParamsJson | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $obj.PSObject.Properties) { $p[$prop.Name] = $prop.Value }
            }
            catch {
                (New-LapaErrorResult -Message ("bad -ParamsJson: {0}" -f $_.Exception.Message)) |
                    ConvertTo-Json -Depth 8
                exit 1
            }
        }
        $result = Invoke-LapaSkill -Skill $cliSkill -Params $p
        $result | ConvertTo-Json -Depth 8
        exit $(if ($result.ok) { 0 } else { 1 })
    }
}
