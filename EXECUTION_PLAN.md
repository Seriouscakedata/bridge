# Execution Plan — 15 tasks toward "bridge = team doing 80% of the work"

Principles (earned today):
- **Foundation #4 (real external run) is the CENTER, not the finale.** Tools justify themselves against a real run.
- **Control-plane tasks are operator-led.** The classifier guard hard-blocks the bridge from auto-editing supervisor/watchdog/circuit-breaker/driver-core. Those carry tag `operator` and I drive them.
- **Activate by trigger, not by guess.** A Phase-2/3 task starts only when the run proves it's needed.
- **Don't pile up mechanisms** (Foundation #2). Simpler is more reliable — today proved it.

Legend: 👤 = I lead (touches control plane / strategic) · 🤖 = delegated to bridge (safe, non-control-plane) · 🔁 = both.

---

## Phase 0 — Instruments & control (so I can orchestrate the run)
Goal: I must SEE and MEASURE before delegating mass work.

| # | Task | Who | Steps | Acceptance | Risk |
|---|------|-----|-------|-----------|------|
| 12 | **pulse → API + light UI** | 👤 | Add `/api/operator/pulse` to server.ps1 returning the same JSON operator-pulse.ps1 computes; add a minimal read-only page in web/. | GET returns JSON; page renders health/queue/batches. | server.ps1 = control plane → I do it, smoke after. |
| 1 | **throughput-metric** | 🤖 | lib/metrics.ps1: % of tasks reaching terminal WITHOUT operator (24h/7d). One line in operator-pulse. | pulse prints `autonomy: X% 24h`. | low (no control plane). |
| 3 | **batch-report** | 👤 | On operator-batch completion, post one chat summary (done/failed/blocked). Get-OperatorBatchProgress + driver idle hook. | finishing a batch posts once, never repeats. | driver idle hook = control plane → I do it. |
| 4 | **failure-classifier** | 🤖 | Classify failed tasks {flaky, spec-unclear, blocked, real-bug} via gemini-2.5-flash-lite; group in pulse NEEDS-YOU. | failed tasks carry a class; pulse groups them. | low. |

Exit Phase 0: I have a live dashboard + honest autonomy % + structured failure view.

---

## Phase 1 — The real run (Foundation #4) — CENTER
| # | Task | Who | Steps | Acceptance |
|---|------|-----|-------|-----------|
| 14 | **Foundation #4 run** | 🔁 | 1) You create the repo + name the project. 2) I create a channel bound to it (project_root). 3) I decompose your vision into specced tasks w/ acceptance criteria. 4) Delegate in operator-batches. 5) Bridge builds → tests → commits, parallelizes. 6) I watch via pulse, fix what really breaks, report to you. | the project moves; autonomy % measured live. |
| 15 | **80%-metric on real project** | 🔁 | #1's metric scoped to the project channel. | an honest number: "bridge closed X% itself; broke at Y." |

This phase is the proof. Everything else is in service of it.

---

## Phase 2 — Efficiency, activated BY the run (trigger-gated)
| # | Task | Who | Trigger | Acceptance |
|---|------|-----|---------|-----------|
| 5 | **conflict-aware-claim** | 🤖 | parallel tasks collide on the same file | unit test: two same-file tasks never run concurrently. |
| 6 | **self-test-on-change** | 👤 | regressions accumulate in the run | a task breaking a covered file cannot reach DONE (driver verify gate = I do it). |
| 13 | **project-onboarding** | 🤖 | bridge makes shallow conclusions on existing code | first task on a channel builds a project map. |
| 2 | **cost-guard** | 🤖 | run gets expensive | pulse shows cost/24h; flags over a daily cap. |

If a trigger never fires, the task was premature optimization — I don't do it.

---

## Phase 3 — Control-plane reliability (ONLY if scale forces it; I lead, by proven need)
These add to the control plane — the exact surface that broke today. Done only if the run hits real load failures, and always operator-led with smoke + self-test gates.

| # | Task | Trigger | Note |
|---|------|---------|------|
| 7 | **M2 git-index serialization** | git conflicts under 6-stream parallel | risky git internals; isolate + test hard. |
| 8 | **H3 atomic claim** | tasks stuck as `running` zombies | claim becomes one transaction. |
| 9 | **H4 process budget** | machine overloaded by workers/codex | machine-wide cap + reaper tracks children. |
| 10 | **M3 coalescer deploy-on-drain** | bridge can't deploy its own fixes while queue full | only relevant to self-dev, low priority on external work. |

## Closed / dropped
- **#11 un-hold + self-edit throttle** — superseded. The control-plane guard already blocks autonomous self-edit; the 82 held control-plane tasks stay held by design. No throttle needed.

---

## Sequence
Phase 0 (instruments, ~mixed) → **Phase 1 run starts as soon as you give the repo** → Phase 2/3 fire only on real triggers from the run.
The point: stop building, start proving — and let the project tell us which of the remaining tasks are real.
