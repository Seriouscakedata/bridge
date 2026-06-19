# Bridge-Self Deterministic Decomposition MAP/PLAN

Date: 2026-06-19
Channel: main / bridge-self
Status: design for operator review, no implementation in this document

## Goal

Large bridge-self tasks must be decomposed into small, claimable, independently verifiable atoms before any coder turn can receive implementation work. The mechanism must prevent commit famine by making each atom small enough to commit in minutes, while preserving existing PROJECT-channel approval gates and existing bridge-self control-plane safety.

## Current Anchors

- `lib/prompt-builder.ps1:538-551` currently classifies large tasks from text length, regex file mentions, and broad keywords. This misses short but wide tasks.
- `lib/prompt-builder.ps1:384-402` currently injects a decomposition prompt, but the prompt asks for `Add-Idea` style children and does not make a machine-valid split mandatory.
- `driver/84-loop-reply-markers.ps1:135-170` already owns `[[PROJECT_BACKLOG]]` marker ingest and calls `Add-ProjectBacklogFromMarker`.
- `lib/backlog-autopilot.ps1:1373-1465` already has the reusable atom ingest path. For `Channel == 'main'`, it marks children as `scope='bridge'`, `project='main'`, tags them with `bridge-self`, and creates them as `status='approved'`.
- `lib/backlog-autopilot.ps1:1326,1345,1364` already copies `bridge_self_admission` from atom metadata.
- `lib/backlog.ps1:445-522` already enforces `bridge_self_admission` evidence for control-plane bridge-self work.
- `lib/backlog-autopilot.ps1:965-985` keeps PROJECT autopilot behind project binding and approved PROJECT_PLAN. This path must stay untouched for PROJECT channels.

## Design Invariants

1. Scope fence: the mandatory decomposition path applies only when the current task is `channel == main` and `scope == bridge`.
2. PROJECT channels keep the existing F1-F4 PROJECT_PLAN approval flow. No PROJECT task is auto-split by this bridge-self mechanism.
3. There is one largeness classifier, one marker ingest path, and one mandatory gate site. No new `goals.md` gate or parallel backlog path is added.
4. `[[PROJECT_BACKLOG]]` JSON is the source of truth for atom content. `[[DECOMPOSED:N]]` is only a human/driver signal and must not be trusted over the JSON ingest result.
5. A bridge-self split is valid only when deterministic ingest validation says it is valid. Planner self-report is not enough.
6. Approved children bypass only repeated approval of the already-approved parent decomposition. They do not bypass control-plane claimability or canary admission.
7. Control-plane atoms must carry valid `bridge_self_admission`; otherwise they remain blocked by the existing admission gate.
8. If a split cannot be made from independently green single-file atoms, the parent must be held for operator review instead of being coded as a monolith.

## Scope Classifier

Replace `Test-IsLargeTask` internals with a scope profile while preserving the existing early return for `atom` and `decomposed-child` tags.

Inputs:
- `TaskText`
- `Tags`
- optional `Channel`
- optional `Scope`
- optional `AcceptanceCount`
- optional `SubsystemCount`
- optional `EstimatedTurns`
- optional `Files`

Default behavior:
- If tags contain `atom` or `decomposed-child`, return false.
- If not `main` / `bridge`, use only existing non-project behavior and do not enable mandatory bridge-self decomposition.
- For `main` / `bridge`, classify as large when any strong signal is true:
  - `AcceptanceCount >= 5`
  - `SubsystemCount >= 3`
  - `EstimatedTurns >= 3`
  - `Files.Count >= 3`, but only as a scope signal from structured metadata, not regex in prose.
- Classify as medium/small otherwise. Short text alone is not evidence of small scope.

If `EstimatedTurns` is absent, it is neutral. It may be derived later from acceptance/subsystem counts, but absence must not fail open into monolith coding when other signals are large.

## Planner Contract

For a large bridge-self parent, the planner prompt must require:

- A `[[PROJECT_BACKLOG]]` JSON array.
- Each atom has the existing project-autopilot fields: `slug`, `title`, `task`, `chapter`, `wave`, `parallel_group`, `files`, `depends_on`, `acceptance`, `checks`, `risk` or `severity`, `serial_reason`.
- Each atom has exactly one file in `files`.
- Each atom has parent linkage through the marker call `SourceTaskId`; the JSON may also include `source_task_id` for audit, but the driver source id remains authoritative.
- Each control-plane atom includes `bridge_self_admission` with:
  - `admitted: true`
  - `mode: "bridge_self_canary"`
  - `canary_required: true`
  - checks covering `driver.ps1 -SelfTest`, `tools/smoke.ps1`, and canary
  - non-empty `rollback_plan`
- The planner may include `[[DECOMPOSED:N]]`, but `N` is informational. JSON ingest validation decides validity.

Do not use raw `Add-Idea` instructions in the prompt for this path.

## Ingest Contract

Reuse `Add-ProjectBacklogFromMarker -Channel main` as the only mutation path.

Extend validation for `Channel == main` and source mode `bridge-self-decomposition`:

- `files.Count == 1`.
- `acceptance.Count > 0` and every acceptance item is concrete enough to be executed by a reviewer or test.
- `checks.Count > 0`.
- `SourceTaskId` is non-empty and is written to `autopilot_source_task`.
- For control-plane files, `bridge_self_admission` exists and passes the existing evidence requirements.
- Return per-atom validation details, not only aggregate `{created, skipped, errors}`.

The return object should add:

```json
{
  "created": 0,
  "skipped": 0,
  "errors": [],
  "ids": [],
  "slugs": [],
  "atoms": [
    {
      "slug": "example",
      "id": "id-or-empty",
      "action": "created|skipped_existing|rejected",
      "valid_for_split": true,
      "files": ["lib/example.ps1"],
      "source_task_id": "parent-id",
      "errors": []
    }
  ]
}
```

Dedup rule for retries:

- `created >= 2` is not sufficient because retry calls can legitimately skip atoms created by the previous attempt.
- Valid split count is `created_valid + skipped_existing_valid`.
- A skipped atom counts only if the existing item has the same slug, same `autopilot_source_task`, status not terminal/rejected, and still satisfies the bridge-self atom validation.
- Existing atoms from another parent do not count toward this parent split.

## Mandatory Gate

The gate sits after planner reply marker processing and before any coder dispatch for a large bridge-self parent.

Gate behavior:

1. Compute `is_large_bridge_self_parent` from the scope classifier.
2. Process markers through `driver/84-loop-reply-markers.ps1`.
3. Read the persisted ingest result for the current parent.
4. If valid split count is at least 2 and errors are empty, do not call the coder for the parent. The parent can be marked decomposed/blocked-from-monolith and the approved child atoms become runnable.
5. If no valid split exists, block `STATUS: CONTINUE` to coder and force a decomposition retry.
6. Retry cap: 2 attempts after the first invalid split.
7. Each retry prompt includes deterministic ingest errors and the current accepted/skipped slugs so the planner can repair, not duplicate blindly.
8. On exhaustion, put the parent on operator hold with reason `bridge-self-decomposition-invalid`; never code the parent monolith.

## Single-File Atomicity

The target is one file per atom and independently green verification.

Allowed decomposition patterns:

- Add backward-compatible helper in one file, then separately switch caller in a later one-file atom.
- Add tests after implementation atoms, not before, unless the test file can pass with existing behavior.
- For control-plane changes, each atom includes parser check, `driver.ps1 -SelfTest`, smoke, canary, and rollback plan.

Not allowed:

- Multi-file atom just because the implementation feels convenient.
- Signature-breaking caller/callee changes split across atoms that leave smoke red between commits.
- Coding the parent monolith when no valid single-file sequence exists.

If the feature cannot be represented as a sequence of independently green single-file atoms, the correct outcome is operator hold with a clear explanation.

## Verification Plan

Minimum checks for implementation atoms:

- Parse touched `.ps1` with `Parser.ParseFile`.
- Run focused tool tests added by the atom.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest` for control-plane changes.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\smoke.ps1`.
- Run canary for control-plane atoms that include `bridge_self_admission`.

Regression coverage:

- Short text with high acceptance/subsystem/estimated_turns classifies as large.
- `atom` and `decomposed-child` tags never reclassify as large.
- PROJECT-channel large task does not enter bridge-self decomposition and still requires F1-F4 PROJECT_PLAN approval.
- Large main task with invalid/missing split blocks coder dispatch.
- Retry with existing valid children counts skipped existing atoms for the same parent.
- Approved control-plane child without valid `bridge_self_admission` remains unclaimable.
- Approved control-plane child with valid `bridge_self_admission` remains claimable through the existing gate.

## Implementation Atoms For Review

These atoms are intentionally listed for operator review only. They are not wrapped in `[[PROJECT_BACKLOG]]` in this document.

### atom_01_scope_classifier

- File: `lib/prompt-builder.ps1`
- Task: Replace `Test-IsLargeTask` internals with the scoped classifier and update the large-task planner instruction to require `[[PROJECT_BACKLOG]]` JSON instead of raw `Add-Idea`.
- Depends on: none
- Acceptance:
  - `atom` and `decomposed-child` tags return false.
  - Short bridge-self task with high acceptance/subsystem/estimated_turns returns true.
  - Non-main/project tasks do not activate mandatory bridge-self decomposition.
- Checks:
  - `Parser.ParseFile('lib/prompt-builder.ps1')`
  - focused inline invocation of `Test-IsLargeTask`
  - `tools/smoke.ps1`
- Risk: medium
- Serial reason: establishes classifier contract used by later atoms.
- bridge_self_admission: required because this touches prompt/control plane.

### atom_02_ingest_validation

- File: `lib/backlog-autopilot.ps1`
- Task: Add bridge-self decomposition validation mode to `Add-ProjectBacklogFromMarker`, including exactly-one-file, parent linkage, control-plane admission check, per-atom return records, and retry-safe skipped-existing accounting.
- Depends on: `atom_01_scope_classifier`
- Acceptance:
  - Main/channel atoms are created approved, tagged bridge-self, linked to `SourceTaskId`.
  - Invalid multi-file or missing-acceptance atoms are rejected with deterministic errors.
  - Existing valid children for the same parent count as valid skipped atoms on retry.
  - Control-plane atoms without valid `bridge_self_admission` are rejected or returned invalid for split.
- Checks:
  - `Parser.ParseFile('lib/backlog-autopilot.ps1')`
  - `tools/test-backlog-packer.ps1`
  - `tools/test-autopilot-controlplane-gate.ps1`
  - `tools/smoke.ps1`
- Risk: high
- Serial reason: defines the authoritative split-validity contract.
- bridge_self_admission: required because this touches backlog control plane.

### atom_03_marker_result_state

- File: `driver/84-loop-reply-markers.ps1`
- Task: Persist the `Add-ProjectBacklogFromMarker` result for the current parent so the mandatory gate can read deterministic ingest output instead of rescanning tags.
- Depends on: `atom_02_ingest_validation`
- Acceptance:
  - Current parent id, created/skipped/errors, per-atom validity, and timestamp are stored in state after marker processing.
  - No state write occurs when there is no `[[PROJECT_BACKLOG]]` marker.
  - PROJECT-channel marker behavior remains unchanged except for existing informational messages.
- Checks:
  - `Parser.ParseFile('driver/84-loop-reply-markers.ps1')`
  - focused marker-processing test or existing reply-marker test
  - `driver.ps1 -SelfTest`
  - `tools/smoke.ps1`
- Risk: medium
- Serial reason: later gate depends on persisted ingest evidence.
- bridge_self_admission: required because this touches driver control plane.

### atom_04_mandatory_gate

- File: `driver/86-loop-completion-actions.ps1`
- Task: Add the single mandatory gate that blocks coder dispatch for large bridge-self parents without a valid split and routes to decompose-retry/operator-hold.
- Depends on: `atom_03_marker_result_state`
- Acceptance:
  - Large bridge-self parent with valid split never reaches coder as monolith.
  - Large bridge-self parent with invalid/missing split gets bounded retry.
  - Retry exhaustion sets operator hold reason `bridge-self-decomposition-invalid`.
  - Small tasks and child atoms are unaffected.
- Checks:
  - `Parser.ParseFile('driver/86-loop-completion-actions.ps1')`
  - focused driver completion test
  - `driver.ps1 -SelfTest`
  - `tools/smoke.ps1`
- Risk: high
- Serial reason: only after ingest evidence is available.
- bridge_self_admission: required because this touches driver control plane.

### atom_05_backlog_claimability_regression

- File: `tools/test-autopilot-controlplane-gate.ps1`
- Task: Extend existing control-plane regression tests to cover approved decomposed children with and without valid `bridge_self_admission`.
- Depends on: `atom_02_ingest_validation`
- Acceptance:
  - Approved bridge-self control-plane child without admission is unclaimable.
  - Same child with valid admission is claimable through the existing gate.
  - Test proves approval alone does not bypass control-plane safety.
- Checks:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-autopilot-controlplane-gate.ps1`
  - `tools/smoke.ps1`
- Risk: medium
- Serial reason: regression for the red-team admission finding.

### atom_06_project_noninterference_regression

- File: `tools/test-project-autopilot-stop.ps1`
- Task: Add/extend PROJECT-channel tests proving large PROJECT tasks still require approved PROJECT_PLAN and do not use bridge-self decomposition.
- Depends on: `atom_04_mandatory_gate`
- Acceptance:
  - PROJECT channel without approved plan remains gated.
  - Main channel bridge-self decomposition changes do not alter `Start-ProjectAutopilotIfNeeded` PROJECT behavior.
  - No new operator approval gate is introduced.
- Checks:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-project-autopilot-stop.ps1`
  - `tools/smoke.ps1`
- Risk: medium
- Serial reason: protects the anti-Frankenstein invariant after gate implementation.

### atom_07_split_retry_regression

- File: `tools/test-backlog-packer.ps1`
- Task: Add retry/dedup regression coverage for `Add-ProjectBacklogFromMarker` so valid skipped-existing atoms for the same parent count toward split validity.
- Depends on: `atom_02_ingest_validation`
- Acceptance:
  - First ingest creates valid bridge-self atoms.
  - Second ingest with the same parent skips existing atoms but returns them as valid for split.
  - Same slug from a different parent does not count.
- Checks:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-backlog-packer.ps1`
  - `tools/smoke.ps1`
- Risk: medium
- Serial reason: prevents retry loops from stranding already-created children.

### atom_08_end_to_end_decomposition_smoke

- File: `tools/test-monolith-decompose.ps1`
- Task: Extend the monolith decomposition smoke to cover scope classification, mandatory valid split, invalid split block, and non-large child bypass.
- Depends on: `atom_04_mandatory_gate`, `atom_05_backlog_claimability_regression`, `atom_06_project_noninterference_regression`, `atom_07_split_retry_regression`
- Acceptance:
  - Short but wide bridge-self parent is treated as large.
  - Valid split produces approved runnable atoms and parent is not sent to coder.
  - Invalid split produces retry/hold behavior.
  - Decomposed child is not decomposed again.
- Checks:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tools/test-monolith-decompose.ps1`
  - `driver.ps1 -SelfTest`
  - `tools/smoke.ps1`
- Risk: high
- Serial reason: final integration smoke after all contracts exist.

## Operator Review Questions

1. Thresholds: accept `AcceptanceCount >= 5`, `SubsystemCount >= 3`, `EstimatedTurns >= 3` as initial defaults?
2. Retry cap: accept first invalid split plus two repair attempts, then operator hold?
3. Control-plane admission: allow planner-emitted `bridge_self_admission` only when it matches the existing strict evidence schema, or require held-item auto-triage to attach it instead?
4. Atomicity exception: if no independently green single-file sequence exists, should the parent always hold, or may the operator approve a narrowly scoped two-file atom?

