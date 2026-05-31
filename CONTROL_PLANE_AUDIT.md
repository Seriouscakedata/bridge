# Control-Plane Reliability Audit (2026-05-31)

Independent audit of failure classes that surface under **100+ queued tasks + 6 parallel drivers**.
Produced for the Block-B hardening pass (must be solid before delegating hundreds of tasks to the bridge).

## Priority queue for fixes

| ID | Class | Where | Status |
|----|-------|-------|--------|
| **H1** | heartbeat starvation → watchdog false `reset --hard` during parallel merge | parallel.ps1:1124-1181 poll loop (no heartbeat tick) + driver.ps1:4920 + watchdog.ps1:366 | **FIX FIRST** (destroys work, cheap) |
| **H2** | lost update on backlog (RMW not transactional) | backlog.ps1 Set-Idea (lock only inside Save-Backlog) | fix (task loss) |
| **H3** | non-atomic claim → `running` zombie never re-selected | driver.ps1:3727-3917 (3 separate locked ops) | fix (task strand) |
| **H4** | unbounded process/worker growth, reaper blind to worker/codex children | supervisor.ps1:736-776 + parallel fan-out + reaper:313 | bridge's own `process_supervision` task |
| M1 | global state mutex 15s thrash under 6 writers | common.ps1 Use-BridgeLock | later |
| M2 | bridge git index contention (merge vs gc vs watchdog/circuit) | parallel.ps1:1186-1240 | later |
| M3 | coalescer never deploys while queue drains (never empty) | driver.ps1:3162-3216 | later |
| M4 | shared restarts.jsonl fleet-wide co-trip; **my Test-CircuitCooldown starves genuine recovery under load** | circuit-breaker.ps1 + watchdog.ps1:306-396 | revisit my fix: per-channel count |
| M5 | 3-skip cap returns null with 97 runnable items behind | backlog.ps1:1855-1909 | fix (drain wedge) |
| L1 | worktree path keyed on task text only → cross-channel collision | parallel.ps1:1065-1101 | later |
| L2 | temp/jobs/log unbounded growth | parallel.ps1:709 + common.ps1 atomic tmp | later |

## Root-cause clusters (fix once, close many)
- **H1**: thread an `$OnTick` heartbeat refresher into Invoke-ParallelDispatch poll loop (siblings already have it).
- **H2+H3**: backlog mutation not transactional → one `Invoke-BacklogLocked { read; mutate; save }` around claim + Set-Idea.
- **H4+M4**: machine-wide process/worker budget + reaper tracks children + per-channel (not global) circuit window.
