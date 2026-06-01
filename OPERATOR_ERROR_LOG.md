# Operator Error Log

_Created: 2026-06-01. Owner: Codex operator/monitor._

This file records concrete errors, weak spots, and recovery notes observed while operating the bridge. It is intentionally separate from project plans: this is an incident/worklog file for problems encountered during bridge-driven execution.

## Logging Rules

- Record only observed issues, not guesses.
- Include impact, current status, and the next practical fix.
- Do not store secrets, tokens, passwords, or private user data.
- Keep entries short enough to scan during monitoring.

## 2026-06-01

### ERR-2026-06-01-001 - Planner stalls with no output

**Context:** Channel `private-community`, task `approve-and-start-ch2-private-community`.

**Observed:** Claude planner repeatedly stayed past soft timeout around 126-127 seconds while `outF` and `errF` stayed at length `0`. Driver heartbeat stayed fresh, so the bridge process was alive, but the active agent turn had no usable output for several minutes.

**Impact:** Tasks can look alive while no useful progress is happening. This delays execution and makes monitoring ambiguous.

**Action taken:** Monitored instead of killing immediately, because the first approval task eventually completed and committed.

**Status:** Open. Need improve zero-output/stall handling and status messages so "output is still growing" is not emitted when output files are actually `0` bytes.

### ERR-2026-06-01-002 - Dependent Chapter 2 tasks were packed as independent

**Context:** `private-community` Chapter 2 batch after approval gate.

**Observed:** Packer grouped 5 tasks into 5 workpacks and deterministic parallel dispatch ran them together. The tasks were logically dependent: scaffold -> Prisma/User model -> admin seed -> auth flow. File touch sets looked different, so the system treated them as parallel-safe.

**Impact:** Parallel execution can generate incompatible code because later tasks assume earlier files already exist. This is a correctness risk, not just a speed optimization issue.

**Action taken:** Continued monitoring and flagged the risk before merge/verify.

**Status:** Open. Need dependency-aware packing: task text dependencies like "after scaffold exists" and "after User model exists" must force sequential waves even when files differ.

### ERR-2026-06-01-003 - `git add` CRLF warnings marked workers as failed

**Context:** Parallel workers `wp1`, `wp2`, `wp4`, `wp5` in `private-community`.

**Observed:** Workers wrote files, but `tools/parallel-llm-worker.ps1` treated normal Git CRLF warnings from `git add -A` as `NativeCommandError`. Example: `warning: in the working copy ... LF will be replaced by CRLF`.

**Impact:** Workers were reported as `failed, commits=0` even though their worktree files existed. This creates false failures and makes the execution report unreliable.

**Action taken:** Inspected `jobs/parallel/*.err.txt` and each worktree status. Confirmed the failures were caused by warnings, not missing file edits.

**Status:** Open. Need make the worker tolerate Git warning stderr when exit code is `0`, or set Git/PowerShell invocation so warnings do not throw.

### ERR-2026-06-01-004 - Collect-commit merged files from failed workers

**Context:** Same `private-community` workpack-batch.

**Observed:** After 4 workers reported failed and only `wp3` reported done, collect-commit still copied 23 files from all 5 streams into the main project and committed `b2ee0f0`.

**Impact:** Failed or partially verified work can enter the main repo. This weakens the safety model and can bypass the intended meaning of worker status.

**Action taken:** Inspected the resulting commit and project files before trusting bridge verification.

**Status:** Open. Need collect-commit to quarantine failed streams or require explicit recovery/verification before collecting their files.

### ERR-2026-06-01-005 - Generated auth baseline is internally inconsistent

**Context:** Commit `b2ee0f0` in `C:\Users\rafie\bridge-projects\private-community`.

**Observed:**

- `prisma/schema.prisma` defines `User.email` and `User.isActive`.
- Auth routes use `username` and `active`.
- `package.json` lacks required dependencies: `@prisma/client`, `prisma`, `bcryptjs`, `jose`.
- Auth files were placed under `pages/routes/...`, which is not a normal Next.js route layout.
- README describes an admin seed/setup script, but no seed script was added.

**Impact:** The project is not expected to build or run correctly until these inconsistencies are fixed.

**Action taken:** Detected by manual inspection while bridge verify-gate was still running.

**Status:** Open. Need fix schema/code alignment, dependencies, route layout, and seed implementation, then run install/typecheck/build.
