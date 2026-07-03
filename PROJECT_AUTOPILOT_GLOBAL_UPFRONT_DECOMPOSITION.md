# Project Autopilot Global Upfront Chapter Decomposition

Status: architect-review packet, no behavior change approved.

> **UPDATE 2026-07-03:** the practical version of this global upfront decomposition now WORKS via the
> `wide` diffusion mode — the coordinator emits ALL chapters as one flat atom graph and the frontier runs
> independent atoms across chapters in parallel (proven live on `textforge`: 55/55 atoms, peak ~25-26
> workers; planner turn ~34 min -> ~5.9 min). See the "Implementation status & live results (2026-07-03)"
> section at the top of `DIFFUSION_DESIGN.md` for the current ground truth, the four solved roots, the one
> remaining defect (`batch-mixed-requeue-cap`), and the GIT STATUS (this work is on branch
> `rescue/planner-speed-work`, rolled back off `master` by the watchdog — not yet restored).

Decision synthesis: `channels/main/decisions/dec-20260627-205201-edcd7f`.
Builds on: `dec-20260627-161352-c39b46`, `DIFFUSION_DESIGN.md`,
`New-ProjectAutopilotUnifiedGraph`,
`Get-ProjectAutopilotGlobalParallelismReport`, and
`Repair-ProjectAutopilotAtomFileOwnership`.

This document designs the missing global "designer" pass for cross-chapter
diffusion parallelism. It is a durable design and implementation plan only.
It does not approve P2+ execution behavior or control-plane changes without
operator architect-review, bridge_self_admission where applicable, and canary
gates.

## Problem

Project Autopilot currently decomposes and approves one chapter at a time. The
executor can already select multiple disjoint workpack atoms from the approved
backlog, but it only sees the atoms that have been emitted. If chapter B has
independent atoms while chapter A is still executing, those B atoms are absent
from the frontier, so they cannot run.

The missing primitive is not worker isolation or touch-set batching. The missing
primitive is a reviewable upfront designer pass that sees the whole approved
plan, emits the safe subset of future atoms early, and leaves unsafe future work
just-in-time.

## Target Model

Add a separate, pure, deterministic designer stage:

1. Read the approved project plan and chapter DAG.
2. Decompose the whole plan into coarse global atoms where it is safe.
3. Mark unsafe chapters/atoms as JIT placeholders rather than pretending they
   are known.
4. Build one global dependency, file-ownership, and contract graph.
5. Compute a durable `PROJECT_WAVE_SCHEDULE`.
6. Approve/enqueue eligible atoms in wave order.
7. Let the existing executor frontier run disjoint touch-set batches across
   chapter boundaries.
8. On drift or stitching failure, re-decompose only the affected subgraph and
   preserve unrelated work.

The bridge engine itself is never a target project for this mode. For bridge
self-improvement, use the existing bridge_self_admission path.

## Design Invariants

- Reliability wins every tie. If safety cannot be proven, fall back to the
  current per-chapter decomposition.
- Never build an atom against an unbuilt foundation unless every cross-chapter
  dependency is backed by a materialized, compilable frozen-contract stub.
- Metadata alone is not enough. A contract dependency is upfront-safe only when
  the stub artifact exists and the dependent atom can build/test against it.
- Real per-atom build and test gates remain authoritative.
- Diffusion speedup is valid only when diffusion-integrated acceptance equals
  the serial gate on the same git base.
- Same-file atoms are time-sequenced. File ownership repair may reduce false
  conflicts, but unresolved same-file writes serialize.
- The live executor is not rewritten for this design. Integration is enqueue
  only: shape `depends_on`, `files`, and `workpack_conflict_group` so the
  existing frontier can make the correct selection.

## Actual Executor Boundary

`New-ProjectAutopilotUnifiedGraph` is a planner artifact. It can classify
contract edges and compute graph telemetry, but it does not dispatch work.

The live frontier is `Resolve-BacklogWorkpackFrontier` in
`lib/backlog-workpack.ps1`. It selects approved workpack items by:

- explicit `depends_on` readiness;
- protected conflict groups;
- path-level touch-set overlap;
- configured max frontier size.

It does not read the unified graph, freeze locks, chapter labels, or soft-edge
metadata. Therefore, once atoms from multiple chapters are approved, there is
no chapter-local scheduling barrier in the frontier itself. Cross-chapter
parallelism is achieved by enqueuing multiple chapters' approved atoms and
ensuring their dependencies and touch-sets are shaped correctly.

Shadow phase must empirically confirm this on a real project before limited
execution.

## Upfront-Safety Model

The designer classifies at three levels: project, chapter, and atom. A higher
level can only restrict lower levels.

### Project Mode

The project mode is one of:

- `serial_jit`: current per-chapter behavior.
- `partial_upfront`: only eligible chapters/atoms are decomposed ahead.
- `full_upfront`: all chapters qualify for upfront decomposition.

Inputs:

- plan-level chapter DAG;
- count and fraction of cross-chapter edges backed by frozen contracts;
- contract maturity and stub availability;
- longest dependency chain from unbuilt foundations;
- unresolved shared mutable artifacts;
- current worktree cleanliness and gate health.

Conservative default:

- choose `full_upfront` only when all cross-chapter edges are contract-backed
  or already built, all required stubs materialize, and no immature chapter is
  in the ahead set;
- choose `partial_upfront` when at least two independent chapters qualify and
  their shared surfaces are stable;
- otherwise choose `serial_jit`.

### Chapter Eligibility

A chapter is eligible for upfront decomposition only when all conditions hold:

- every predecessor in the chapter DAG is already built, or the chapter's use
  of that predecessor is through a frozen, materialized contract stub;
- the chapter is not marked immature by the plan, operator annotation, or
  shadow telemetry;
- the chapter does not own an unstable foundation surface used by later
  chapters;
- the chapter has explicit files or a deterministic ownership derivation;
- same-file conflicts can be sequenced in the schedule;
- stitching acceptance exists for every contract seam used by the chapter.

Force JIT for a chapter when:

- it depends on actual built code shape rather than a stable surface;
- the provider API is expected to emerge during implementation;
- contracts are missing, invalid, drifted, or stub generation is unavailable;
- the chapter primarily integrates shared mutable artifacts such as manifests,
  DI registries, barrel indexes, migrations, or build configuration;
- the plan marks the chapter as exploratory or high-churn.

### Atom Classifier

Each atom receives one of:

- `upfront_safe`: can be emitted now.
- `contract_upfront_safe`: can be emitted now only against a frozen stub.
- `same_file_sequenced`: can be emitted now, but must be time-sequenced after
  the conflicting file owner.
- `jit_required`: must remain per-chapter/JIT.

An atom is upfront-safe only when:

- all explicit `depends_on` are either complete, in an earlier schedule wave, or
  represented by a frozen contract marker;
- all cross-chapter `consumes` entries have stable locks and materialized
  stubs;
- its dependency-chain depth from the nearest unbuilt foundation is below a
  conservative threshold;
- its owning chapter is eligible;
- its file touch-set is explicit or safely repaired;
- no shared mutable artifact is touched unless it is isolated in a dedicated
  integration atom.

If any check is unknown, the atom is `jit_required`.

## Contract Materialization

Frozen contracts are real build artifacts, not metadata notes.

The existing freeze primitive produces a channel-local lock keyed by canonical
contract hash. The global designer adds a materialization requirement:

- a generated stub file or package exists in a consumer-owned or ephemeral
  test-double location;
- the stub is compilable by the project build;
- dependent atoms can run their contract-scope unit tests using the stub only;
- provider-owned files are not touched by consumer stubs;
- the generated stub hash is recorded in the schedule.

If a language or build system cannot produce a high-fidelity compilable stub,
all dependents of that surface stay JIT. This is expected and correct.

## PROJECT_WAVE_SCHEDULE

The designer emits a durable `PROJECT_WAVE_SCHEDULE` artifact before any
limited/full execution. Recommended location:

`channels/<channel>/project-autopilot-schedules/<project-hash>/PROJECT_WAVE_SCHEDULE.json`

The artifact is deterministic: same plan, contracts, atom list, and policy
inputs produce byte-identical JSON.

Minimum schema:

```json
{
  "schema_version": 1,
  "mode": "shadow|limited|full",
  "channel": "glass-interpreter",
  "project_hash": "project-hash",
  "base_commit": "base-commit-sha",
  "decision_id": "dec-20260627-205201-edcd7f",
  "policy": {
    "max_dependency_depth_from_unbuilt_foundation": 2,
    "replan_budget": 2,
    "fallback": "serial_jit"
  },
  "inputs": {
    "plan_hash": "plan-hash",
    "contracts_hash": "contracts-hash",
    "atoms_hash": "atoms-hash",
    "file_ownership_repaired": true
  },
  "safety": {
    "project_mode": "serial_jit|partial_upfront|full_upfront",
    "reasons": []
  },
  "waves": [
    {
      "wave": 1,
      "parallel_groups": [
        {
          "group": "w1-g1",
          "atoms": ["slug-a", "slug-b"],
          "chapters": ["chapter-a", "chapter-b"],
          "touch_sets_disjoint": true
        }
      ],
      "sequenced": [
        {
          "atom": "slug-c",
          "after": "slug-a",
          "reason": "same-file"
        }
      ]
    }
  ],
  "atoms": {
    "slug-a": {
      "chapter": "chapter-a",
      "classification": "upfront_safe",
      "depends_on": [],
      "files": ["src/a.kt"],
      "contracts": [],
      "acceptance_scope": "integrated",
      "serial_reason": ""
    }
  },
  "jit_placeholders": [
    {
      "chapter": "ui",
      "reason": "depends-on-unbuilt-storage-implementation"
    }
  ],
  "telemetry": {
    "global_parallelism_report": {}
  }
}
```

Wave construction:

1. Repair obvious over-declared file ownership with
   `Repair-ProjectAutopilotAtomFileOwnership`.
2. Build the global graph with `New-ProjectAutopilotUnifiedGraph`.
3. Compute global telemetry with `Get-ProjectAutopilotGlobalParallelismReport`.
4. Treat hard dependency edges as topological constraints.
5. Treat contract-soft edges as schedulable only when the stub materialization
   check passes.
6. Within each topological level, batch atoms by disjoint touch-sets.
7. For same-file atoms, emit explicit `sequenced` entries rather than hiding
   them as generic serial fallback.
8. Order ready atoms by critical-path length first, then stable slug order.

The schedule is advisory in shadow. In limited/full modes, only approved atoms
from eligible waves are enqueued; JIT placeholders are never converted to
backlog atoms until their foundations exist.

## Enqueue-Only Execution Integration

The implementation must not require executor semantics changes for P2.

For normal independent atoms:

- emit real atoms with their explicit `depends_on` and repaired `files`;
- approve them in wave order.

For contract-dependent atoms:

- emit or reference a freeze marker atom;
- make the consumer depend on the freeze marker, not the unfinished provider;
- place generated stubs in consumer-owned or ephemeral paths;
- emit a stitching atom that depends on provider plus all consumers;
- require stitching acceptance before any integrated success is counted.

For same-file conflicts:

- emit dependencies between same-file owners in the schedule order; or
- leave the later atom JIT if sequencing would over-constrain the plan.

This preserves current frontier behavior while expanding the approved atom set
across chapters.

## Corrective Loop

The corrective loop is bounded and subgraph-local.

### Triggers

Replanning can be triggered by:

- contract drift after a foundation/provider atom completes;
- generated stub hash no longer matching the frozen lock;
- stitching/conformance test failure at a declared seam;
- merge conflict or touch-set violation on a scheduled file;
- provider output invalidates a dependent atom's assumptions.

Ordinary single-atom implementation failure is not automatically a global
replan. It remains the existing atom repair path unless the failure is
attributed to a contract seam or foundation drift.

### Attribution

Every stitching test must identify:

- provider atom(s);
- consumer atom(s);
- contract id(s);
- files involved;
- failing assertion or build target.

If attribution is missing, downgrade the affected chapter range to serial JIT
rather than attempting broad automatic replanning.

### Blast Radius

Given a failed seam, compute:

1. changed provider/foundation atoms;
2. contract ids whose canonical payload or generated stub hash drifted;
3. transitive dependents in the global graph that consume those contracts;
4. same-file sequenced successors of those dependents;
5. integration/stitch atoms that include the seam.

Only this induced subgraph is re-decomposed. Completed atoms outside the subgraph
are preserved.

### Termination

Each subgraph has a small replan budget `K`. Recommended initial default for
shadow calibration is `K=2`.

A replan is allowed only if it makes monotonic progress:

- a contract version/hash is advanced and re-frozen;
- a dependent is downgraded from upfront to JIT;
- a same-file sequence is made stricter;
- a failing stitch atom is replaced with a more specific integration atom.

If the budget is exhausted or no monotonic progress action exists, downgrade the
subgraph to serial JIT and keep the rest of the project schedule intact.

## Safe Fallback

Fallback is structural, not exceptional.

Use current per-chapter decomposition when:

- chapter DAG depth is high and cannot be contract-cut;
- contract coverage is incomplete;
- stubs are missing or low-fidelity;
- shared mutable artifacts dominate the touch-set;
- shadow cannot prove cross-chapter frontier batching;
- serial oracle cannot be established on the same git base;
- any deterministic gate returns unknown.

The fallback output must include explicit `serial_reason` values so later shadow
analysis can distinguish real dependencies from missing metadata.

## Rollout Plan

### P-prep: Data Model and Designer Skeleton

Goal: add no behavior. Define dependency classes and the pure designer interface.

Exit gates:

- same inputs produce byte-identical schedule output;
- no backlog write or execution path is touched;
- schema supports hard implementation dependency, frozen-contract dependency,
  soft ordering hint, and file-ownership conflict;
- operator reviews the schema.

### P0: Shadow Global Schedule

Goal: compute and log the would-be global schedule on a real project, changing
nothing in execution.

Actions:

- run ownership repair on candidate atoms;
- build the global graph;
- emit `PROJECT_WAVE_SCHEDULE`;
- attach global parallelism telemetry;
- classify project/chapter/atom safety;
- shadow-confirm that the existing frontier would select cross-chapter disjoint
  atoms once multiple chapters are approved.

Exit gates:

- durable schedule artifact exists;
- shadow schedule shows cross-chapter batches only for upfront-safe atoms;
- every JIT decision has a concrete reason;
- no live backlog execution changes;
- operator reviews the artifact.

### P1: Contract Stub Materialization

Goal: prove contract-dependent upfront atoms can build against real stubs.

Exit gates:

- generated stubs are compilable;
- dependent contract-scope tests pass against stubs only;
- provider files are untouched by consumer stubs;
- unsupported languages force JIT.

### P2: Limited Execution

Goal: execute exactly two independent eligible chapters ahead of time.

Exit gates:

- atoms run across the chapter boundary through existing frontier selection;
- per-worker worktree isolation remains active;
- diffusion-integrated acceptance equals the serial gate on the same git base;
- fallback to per-chapter default is clean when eligibility fails.

### P3: Corrective Loop

Goal: enable bounded subgraph repair.

Exit gates:

- injected contract drift replans only affected transitive dependents;
- stitching failure attribution selects a bounded subgraph;
- budget exhaustion downgrades to serial JIT;
- unrelated completed atoms are preserved.

### P4: Full Rollout

Goal: enable full or partial upfront mode for qualifying projects.

Exit gates:

- multiple real projects show honest speedup under equal serial-oracle
  acceptance;
- no false-green is observed;
- fallback remains default when safety is not provable;
- operator approves any default-on policy.

## Measurement

Speedup is reportable only when all hold:

- serial oracle and diffusion run start from the same git base;
- accepted artifact/test set is identical;
- diffusion-integrated acceptance equals the serial gate;
- per-atom checks ran for every atom;
- stitching/integration checks ran for every contract seam;
- failures and fallback time are included in elapsed time.

Shadow-only projected speedup is useful telemetry, but it is not delivery
evidence.

## Architect-Review Questions

Before behavior changes, operator review must settle:

- language-specific stub generation policy and unsupported-language fallback;
- default thresholds for dependency depth, contract maturity, project safety
  score, and replan budget;
- automatic versus operator-supplied immature chapter annotations;
- stitching failure attribution format;
- serial-oracle sampling budget;
- empirical confirmation that approved cross-chapter atoms are batched by the
  current frontier.

## Implementation Backlog Shape

Do not emit live implementation atoms until architect-review approves the packet.
When approved, split into control-plane atoms with bridge_self_admission where
they touch `lib/backlog-autopilot.ps1`, `lib/backlog-workpack.ps1`, `driver.ps1`,
`server.ps1`, `supervisor.ps1`, `watchdog.ps1`, or other core files.

Recommended atom order:

1. schema and pure designer interface;
2. deterministic schedule artifact writer in shadow mode;
3. safety classifier fixtures;
4. stub materialization dry-build harness;
5. limited enqueue-only integration for two eligible chapters;
6. corrective-loop fixtures and budget enforcement;
7. serial-oracle measurement harness.

Each atom must include concrete parser/selftest/smoke checks appropriate to the
touched files and must not create `control/restart.flag` for docs-only changes.
