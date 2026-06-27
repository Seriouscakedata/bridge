# Diffusion Execution — Architect Design & Phased Plan

Status: 2026-06-27 — operator gave GO to implement (phased, by me). Bridge ran a parallel DISCUSS
design on `main` (sanity check); this doc is the consolidated architect design to reconcile with it.
First proving ground: the paused glass-interpreter build (chapters 4-8).

## Goal
Remove the dominant speed bottleneck (dependency-sequenced atoms force chapter waves to run mostly
serially). Parallelize **dependent** atoms — not just independent ones — by building them against
**frozen interface contracts** (a consumer builds against a contract stub before the provider exists),
then stitching + integration-testing at the end. Target: run atoms in tens/hundreds of workers safely.

## Agreed design (operator discussion, 2026-06-27)
- **Risk moves from "writing code" to "designing the architecture up front."** Correct contracts +
  schedule = hundreds of workers fly; wrong = merge chaos. So the planning is the make-or-break.
- **Flow:** idea → detailed plan → full spec → synthesis → chapters → atoms → **global analysis of ALL
  atoms + a designed schedule** → simultaneous development of all parallelizable atoms.
- **The "designer" (global planner)** sees the whole atom graph and classifies each atom into 3 (4) types:
  1. **Independent** — no deps, different files → run together immediately.
  2. **Dependent-via-contract** — consumes a stable contract whose provider is in a later wave → build
     against the frozen contract stub now, in parallel with the provider.
  3. **Same-file-conflict** — touches a file a sibling also writes → must sequence, but the schedule
     *interleaves* it with other independent work so workers stay busy (timing).
  4. (Hard-dependent — unmet explicit prerequisite → wait.)
- **One upfront pass; correct on conflict.** The designer plans everything at the start; when stitching
  finds a mismatch it re-plans/corrects (corrective loop), it does NOT re-plan from scratch each step.
- **Small single-concern files** so same-file conflicts are rare (decomposition already aims for this).
- **Stitching is the danger zone**, not the coding. Integration checkpoints + a corrective loop must be
  bulletproof, else speed becomes debugging hell. Reliability wins ties (the bridge's core strength).

## Existing machinery (already built — extend, don't reinvent)
- `diffusionMode` config off/shadow/diffusion — lib/backlog-autopilot.ps1:9,18,27,58-61. Today the 3
  modes are described in the **coordinator prompt only** (~:1342), NOT dispatched by code.
- `New-ProjectAutopilotUnifiedGraph` (:541-621): builds the DAG from atoms+contracts — nodes, hard edges
  (depends_on), **soft edges** (consumes a contract that is valid+stable → parallel-safe), file_conflicts
  (Test-ProjectAutopilotPathOverlap :503-512), acyclic (Test-ProjectAutopilotGraphAcyclic :514-539, Kahn).
- `Test-ProjectAutopilotDiffusionGate` (:623-673): 9 deterministic gates (opt-in, clean tree, contract
  coverage, contracts valid, contracts stable, acyclic, no file-conflict, stitching tests present,
  independent-count>=K, wave-size<=N). **Defined but NOT called in production.**
- Contract schema `.bridge/specs/contracts/contract.schema.json`: id/version/signature/behavior/
  invariants/errors/golden_examples/owned_files + `stable` (frozen→soft edge) + `content_hash`.
- Frontier (lib/backlog-workpack.ps1 Resolve-BacklogWorkpackFrontier :2117-2515): per-chapter disjoint
  touch-set batch + serial-chain fallback. Parallel dispatch lib/parallel.ps1 (worktree workers).
- Unit of parallelism today: one wave of disjoint atoms **within one chapter**.

## Gap (net-new to build)
- (a) **Global** whole-project atom collection (today per-chapter).
- (b) **3-way classification** of atoms (above).
- (c) **Wave schedule** builder — durable PROJECT_WAVE_SCHEDULE artifact (waves 1..N, atoms/wave, timings).
- (d) **Parallel-against-contract** — contract-stub generation so a consumer builds before the provider.
- (e) **Stitching consolidation + corrective re-plan loop** on integration failure.

## Phased rollout (safe — never a big-bang on the engine; reliability gate each phase)
- **Phase 1 — SHADOW global planner + measurement (no behavior change).** New lib/diffusion-planner.ps1:
  collect all atoms across chapters, call the existing graph builder GLOBALLY, classify atoms (3-way),
  build a PROJECT_WAVE_SCHEDULE.json, and emit it as a durable artifact + telemetry (projected
  parallelism %, wave count, would-be conflicts) — WITHOUT changing execution. We inspect the schedule
  on a real project (glass-interpreter) and verify it is correct before any atom runs differently.
- **Phase 2 — LIMITED real parallel-against-contract.** Generate frozen contract stubs; run a small wave
  of contract-dependent atoms against stubs alongside providers; add a stitching/consolidation checkpoint
  after the wave with a bounded corrective loop. Few workers, heavy verification.
- **Phase 3 — SCALE.** Raise wave size + worker count to tens/hundreds once the stitching+corrective loop
  is proven. Keep the serial one-chapter fallback whenever the diffusion gate fails.

## Safety / acceptance (non-negotiable)
- Real per-atom build+test acceptance still gates EVERY atom (no false-green).
- Diffusion only acts when `Test-ProjectAutopilotDiffusionGate` passes; otherwise fall back to serial.
- Contracts must be `stable` before any parallel dependent work (no parallelizing on a moving target).
- Stitching/integration tests must catch contract-mismatch; corrective loop is bounded (no infinite re-plan).
- Worktree isolation per worker (already enforced). Bridge repo itself never parallelized.
