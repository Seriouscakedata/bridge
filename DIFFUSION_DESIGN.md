# Diffusion Execution — Architect Design & Phased Plan

Status: 2026-06-27 - design deliverable plus P1 shadow freeze primitive. Bridge ran a parallel DISCUSS
design on `main` (sanity check); this doc is the consolidated architect design and architect-review
packet. It does not approve P2+ execution or further control-plane changes. Those require explicit
operator architect-review, including the P2 emit-shaping decision recorded below.
First proving ground: the paused glass-interpreter build slice chosen for measurement.

Follow-up architect packet for cross-chapter diffusion:
`PROJECT_AUTOPILOT_GLOBAL_UPFRONT_DECOMPOSITION.md`. That packet designs the global upfront chapter
decomposition pass, durable `PROJECT_WAVE_SCHEDULE`, safety classifier, bounded corrective loop, and
shadow -> limited -> full rollout. It is docs-only and does not approve behavior changes.

---

## Implementation status & live results (2026-07-03) — READ THIS FIRST

The design below (2026-06-27/28) is the aspirational contract-diffusion plan. Since then the simpler
**WIDE** path was built and PROVEN end-to-end, and the planner was made fast. This section is the current
ground truth; the older sections are the still-valid reference for the harder contract-parallel P2+ work.

### What actually works now (proven live)
- **`diffusionMode` now has FOUR modes: off / shadow / diffusion / `wide`.** WIDE was the breakthrough: the
  coordinator decomposes the ENTIRE project (all chapters) into ONE flat atom graph up front, and the frontier
  runs every independent atom in parallel across chapters — no contracts, no stubs, no freeze. Dependent atoms
  wait on `depends_on`; the dependent tail (integration + tests) stitches at the end. This is the practical
  realization of "forget chapters, go straight to atoms, decompose everything at once."
- **Swarm PROVEN** (project `textforge`, a Python parallel-stress plan, 55 atoms / 5 chapters): 55/55 atoms
  done, 0 failed, **peak 25-26 concurrent workers** (pool cap 16 cycles them in batches), 51 tests green,
  clean merge (0 conflicts, 0 duplicate classes, 40 plugins, 60 files), working app. The wide plugin wave
  (24 independent atoms) built in ~5 min; the dependent tail (engine + tests) ran narrow, by design.
- **Planner is fast now: ~34 min -> ~5.9 min per planning turn** (bridge's own `turns.jsonl`: sec 1993 ->
  351, ~5.7x). Root: the whole planning turn was ONE agentic claude.exe call whose time was eaten by dozens
  of internal file-read rounds + max reasoning + a bloated ~98KB prompt. Fix = inject PLAN/BRIEF/contract/
  acceptance VERBATIM into the coordinator task + "do NOT read files, repo is empty, emit the full backlog in
  ONE response" on cold start; lean coordinator prompt profile (rules+suffix 27K->5.2K chars, task-echo
  de-duplicated); coordinator explicitly routed to the deep model at `--effort high` WITHOUT `ultrathink`
  (previously the deep model was chosen by accident because the template contained the word "refactor").

### The four roots that used to block "all chapters at once" (now understood/fixed)
1. **Ingest collapsed the plan to ONE chapter.** A red/absent strict diffusion gate (no contracts -> gate=null)
   collapsed the whole batch to the earliest chapter, DISCARDING the rest. Fix: a red strict gate now falls
   back to **WIDE schedulability** (the whole valid DAG is ingested; collapse only for a genuinely broken
   graph — cycle / dangling dep). This was the main "all chapters" killer.
2. **Planner refuses on a contaminated repo.** A smart planner does git forensics (reflog/fsck/backup dirs) and
   correctly REFUSES to rebuild over apparent-wiped work. This is correct safety, not a bug — measure from a
   genuinely fresh repo (full `rm -rf .git && git init`, no history/backups/memory).
3. **Worker git-archaeology.** Dangling objects after a reset make a worker "rescue" a lost commit, refuse its
   atom, and stall the whole dependent front. Fix: after any reset run `git reflog expire --all && git gc
   --prune=now` (fsck dangling = 0) and purge fresh panic entries from the channel memory.
4. **Slow planning (~34 min).** Fixed as above.

### Known remaining defect (NOT yet fixed) — next priority
- **`batch-mixed-requeue-cap`.** In a MIXED workpack batch (some atoms done, some not), an INDEPENDENT atom
  (own file, deps met) burns its retry counter alongside a failing batch-mate (a contention atom looping in
  the zombie-reaper) and gets held after 3 attempts, blocking everything downstream. Observed on textforge:
  two independent plugins were unfairly held and blocked engine + tests. Fix candidate: in mixed-requeue do
  not burn attempts on atoms that never actually started/failed — decouple an atom's fate from its batch-mate.

### GIT STATUS — IMPORTANT (2026-07-03)
The fixes above (`cb7ce1b` ingest-collapse, `01e9028` planner-speed, `cf5a158` 14 audit fixes, `edef163`
stop-flag/halt) are **NOT on `master`.** On 2026-07-02 the bridge's own watchdog auto-rollback reset `master`
to fork-point `039a0be` (triggered by a pre-existing OOM-lint on `ConvertTo-Json -Depth 12`, unrelated to
this work) and discarded all of it as collateral. The work is preserved on branch
**`rescue/planner-speed-work`** (tag `rescue-20260703-planner-speed`, tip `edef163`). `master` (tip `18f65a0`)
does NOT contain these diffusion improvements. To restore: reset `master` to `edef163` and cherry-pick the one
useful doctor commit `a15c9f8` (JSON depth 12->10) so a restart does not re-trigger the same rollback. See
memory note `watchdog-rollback-discarded-operator-work`.

---

## Scope correction after critic review

Commit `7a1a2b0` was auto-titled as a workpack batch that completed seven independent approved backlog
tasks. That title is not supported by the diff: the commit added only this diffusion design document and
`channels/glass-interpreter/diffusion-final-decision-record.json`. Treat `7a1a2b0` as a design/decision
artifact commit, not as evidence that any independent backlog execution tasks were completed.

The executable P1 work is in the later P1 commit. This document is the durable design deliverable plus
architect-review notes; it is not a completion proof for a batch of backlog atoms.

Evidence rule for this task: commit titles, line counts, file sizes, and projected wave counts are not
completion evidence. Any final close-out that uses a number must cite the command output that produced
that number; otherwise the statement is intentionally omitted.

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

## Architect-review correction: graph soft edges are not execution

`New-ProjectAutopilotUnifiedGraph` and its hard/soft contract edges are planner/gate artifacts only.
The live executor frontier is `Resolve-BacklogWorkpackFrontier` in `lib/backlog-workpack.ps1`; it admits
parallel work from `depends_on` readiness, `workpack_conflict_group`, and path touch-overlap. It does not
read the unified graph, freeze locks, or soft edges. Therefore P1 soft-edge flipping is shadow-safe, but it
cannot by itself dispatch dependent consumers before their real provider atoms finish.

P2 must use additive emit-shaping instead of teaching the executor a new dependency rule:

- emit a freeze atom/marker for the frozen contract;
- emit each dependent consumer atom with `depends_on` on the freeze atom/marker, not on the real provider;
- place generated stubs only in consumer-owned or ephemeral test-double files so provider files remain
  untouched;
- emit a stitch/consolidation atom with `depends_on` on the provider and all consumers;
- let the existing frontier dispatch these shaped atoms without any `backlog-workpack.ps1` change.

If this shaping cannot be expressed for a slice, the slice stays serial with a concrete `serial_reason`.

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

## P1 freeze primitive (accepted Decision Record dec-20260627-161352-c39b46)

Diffusion execution is additive over the serial default. The first executable primitive is a
deterministic **contract freeze**:

1. Read `.bridge/specs/contracts/<id>.json`.
2. Compute `canonical_hash` over only the interface payload:
   `signature`, `behavior`, `invariants`, `errors`, `golden_examples`, `owned_files`, `owned_regions`.
3. A contract is freeze-ready only when all required fields are present, at least one golden example has
   input and output, no blocking open-question references the contract id, provider/consumer atoms exist,
   and contract-owned files do not overlap another contract.
4. The freeze step writes a channel-local lock under
   `channels/<channel>/diffusion-contract-freezes/<project-hash>/<contract-id>.lock.json` with
   `{ stable:true, version, canonical_hash, generated_stub_hash, frozen_at }`.
   The lock is deliberately outside the project repo so freezing does not dirty the project worktree and
   does not defeat the clean-git gate.
5. Runtime stability is then binary and LLM-free:
   `raw_mature && lock.stable && lock.version == contract.version && lock.canonical_hash == recomputed_hash`.
   A bare `stable:true` in the contract file is not sufficient.
6. `New-ProjectAutopilotUnifiedGraph` keeps contract edges hard by default. A stable lock can flip a
   provider->consumer edge to `soft` only when the diffusion gate calls the graph with
   `AllowContractSoftEdges=true`.
7. Any unbumped payload change after freeze is drift (`freeze-lock-hash-mismatch`) and blocks diffusion;
   the affected sub-DAG must fall back to serial until the contract is explicitly re-frozen with a new
   version/hash.

Deterministic gates for P1:

- Freeze manifest includes contract id, version, canonical hash, provider atoms, consumer atoms, owned
  files/regions, generated stub hash, lock path, lock write result, timestamp.
- The diffusion gate fails if contract coverage is incomplete, any contract is invalid/unstable, the graph
  is cyclic, contract files are listed in atom `files`, file ownership overlaps, stitching tests are absent,
  independent atom count is below K, or wave size exceeds N.
- In `shadow` mode the coordinator writes freeze/gate markers but still emits only the serial one-chapter
  default. In `diffusion` mode a red gate structurally falls back to serial and logs the reason.

Rollout phases:

- P0 shadow: compute graph/gate/freeze markers only.
- P1 freeze predicate: lock/hash maturity and mode-gated soft edges.
- P2 contract workpacks: isolated consumers build against deterministic stubs with
  `acceptance_scope=contract`.
- P3 stitching: integration atoms replace stubs with real bindings and run conformance + full acceptance,
  yielding only `acceptance_scope=integrated`.
- P4 fault fallback: injected drift, merge conflict, conformance red, timeout all collapse to serial.
- P5 measured rollout: speedup is non-VOID only when diffusion integrated acceptance equals the serial gate
  on the same git base.
