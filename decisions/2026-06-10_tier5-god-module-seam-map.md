# 2026-06-10 - Tier 5 god-module seam map

Status: DESIGN / operator review. This is a pure move-plan, not an execution patch.
Scope: `lib/backlog-workpack.ps1`, `lib/common.ps1`, `lib/backlog-core.ps1`, `driver/81-loop-idle-claim.ps1`.

Constraint: Tier 5 runs only after Tier 2 primitive dedup lands. The split must not create a new mechanism; every atom is a pure function move into a new `lib/*.ps1` file plus a guarded dot-source from the old module. Behavior, names, script-scope state, and call sites stay unchanged.

## Sequencing gate

Tier 2 decides the shared helper fate first:

- `lib/backlog-core.ps1:841` `ConvertTo-BacklogClaimStringArray` trims, deduplicates, and returns `[string[]]`; it is divergent from `ConvertTo-BridgeStringArray`.
- `lib/backlog-core.ps1:860` `Test-BacklogClaimTruthy` accepts `admitted`, `approved`, and `ok`; it is divergent from `Test-BridgeTruthy`.
- `lib/backlog-workpack.ps1:1490` `ConvertTo-BacklogWorkpackStringArray` trims and deduplicates; it is divergent from `ConvertTo-BridgeStringArray`.

Move atoms below must leave those divergent helpers in place until Tier 2 findings are reviewed. If the operator chooses to keep them domain-specific, the first extraction atom moves them with their owning seam, not into primitives.

## Seam map: `lib/backlog-workpack.ps1` (2693 lines)

Natural seams:

- Primitive/config/header: `Get-BacklogPackObjectValue`, `ConvertTo-BacklogPackBool`, `ConvertTo-BacklogPackInt`, `Get-BacklogPackConfig`, channel/path helpers at `11-145`.
- Duplicate compaction and intake gates: duplicate representative logic and intake security evidence at `147-581`.
- Packer request/pressure: last-run, pressure, request emission at `583-677`.
- File inference and classification: signal text, path inference, scope contract, classification at `679-1299`.
- Execution eligibility and touch-set policy: config, touches, bridge admission, project scope, exec eligibility at `1300-1647`.
- Dependency/frontier reasoning: dependency signals, candidate reports, reason formatting, slug status, dependency readiness, frontier resolver at `1649-2268`.
- Protected serial frontier and task text: protected serial candidate/group/frontier and batch prompt text at `2292-2693`.

Internal dependencies:

- Later seams depend on the primitive/config helpers and on `Get-BacklogPackObjectValue`.
- Execution eligibility uses file-list/touch helpers and bridge admission helpers.
- Frontier resolution uses eligibility, dependency signals, candidate report objects, and status maps.
- Protected serial resolution reuses eligibility, touch overlap, and batch text helpers.

Safe extraction order:

1. Move duplicate compaction + intake gates to `lib/backlog-workpack-intake.ps1`; dot-source it from `backlog-workpack.ps1`. Checks: ParseFile for both files, existing backlog packer tests, `tools/smoke.ps1`. Control-plane: yes, requires `bridge_self_admission` and canary.
2. Move packer request/pressure to `lib/backlog-workpack-request.ps1`. Same checks/admission.
3. Move file inference/classification to `lib/backlog-workpack-classify.ps1`. Same checks/admission.
4. Move execution eligibility/touch policy to `lib/backlog-workpack-eligibility.ps1`. Same checks/admission.
5. Move dependency/frontier reasoning to `lib/backlog-workpack-frontier.ps1`. Same checks/admission.
6. Move protected serial frontier and batch text to `lib/backlog-workpack-protected-serial.ps1`. Same checks/admission.
7. Leave only guarded dot-sources and thin compatibility wrappers in `lib/backlog-workpack.ps1`; run a final grep for duplicated moved function definitions.

## Seam map: `lib/common.ps1` (1947 lines)

Natural seams:

- Root/config/executable resolution: `Get-BridgeRoot`, `Get-BridgeConfig`, `Get-FastLaneSettings`, `Resolve-CodexExe`, `Resolve-ClaudeExe` at `11-132`.
- Process management: zombie recovery, child process registry/sweep, bridge-owned process detection, orphan sweeps at `133-399`.
- Summary/state IO: summary read/write, decision save, state backup/read/shape/write/mutation/update/failure fields/session ledger at `400-991`.
- Runtime metrics and probe timing: state metrics, probe timeout defaults/adaptation, probe duration at `636-841`.
- Snapshots/context blocks: snapshots and runtime context block at `992-1186`.
- Agent/channel state: other-channel agents, current agent, preflight blockers at `1187-1439`.
- Test-channel archival/cleanup: test channel detection, archive flags, idle archival, cleanup at `1440-1601`.
- Conversation IO/archive: `Add-Message`, conversation archive/prune, `Get-Messages` at `1603-1743`.
- Initialization: `Initialize-Bridge` at `1744-1947`.

Internal dependencies:

- Most seams call `Get-BridgeRoot` and `Get-BridgeConfig`; keep these in the base file until all moves are complete.
- State write/update functions share `state.json` shape and lock semantics; move as a single seam.
- Agent/channel functions call state functions and should move after state IO.
- Conversation archive uses root/config and can move late with low risk.

Safe extraction order:

1. Move process management to `lib/common-process.ps1`; dot-source from `common.ps1`. Checks: ParseFile, process-related tests if present, smoke. Control-plane: non-`backlog` lib but core bridge runtime, require canary by policy.
2. Move runtime metrics/probe timing to `lib/common-probe.ps1`. Checks: ParseFile, probe tests, smoke.
3. Move summary/state IO as one atom to `lib/common-state.ps1`. Checks: state shape tests and smoke.
4. Move snapshots/context blocks to `lib/common-context.ps1`. Checks: prompt/context tests and smoke.
5. Move agent/channel state to `lib/common-agents.ps1`. Checks: channel-switch scenario and smoke.
6. Move test-channel cleanup to `lib/common-test-channel.ps1`. Checks: cleanup tests and smoke.
7. Move conversation IO/archive to `lib/common-conversation.ps1`. Checks: archive tests and smoke.

## Seam map: `lib/backlog-core.ps1` (2136 lines)

Natural seams:

- Severity, failure class, LLM priority and curator: `12-813`.
- Claim primitive helpers and control-plane path predicates: `815-1036`.
- Governor filters and claimability idle state: `1037-1432`.
- Bridge-self canary task creation: `1433-1503`.
- Approved/new runnable pickers: `1504-1617`.
- Operator batch reporting: `1618-1968`.
- Self-exec and risk/reflex helpers: `1969-2136`.

Internal dependencies:

- Claimability depends on control-plane predicates and bridge-self admission.
- Pickers depend on claimability and governor filters.
- Operator batch reporting depends on backlog item status but should not mutate claimability logic.
- Self-exec/risk helpers depend on control-plane path predicates.

Safe extraction order:

1. Move severity/failure/priority/curator to `lib/backlog-priority.ps1`. Checks: ParseFile, prioritizer tests, smoke. Control-plane: yes, requires bridge-self admission and canary.
2. Move claim primitive helpers and control-plane path predicates to `lib/backlog-claim-policy.ps1`, keeping the divergent Tier 2 helpers with this seam. Checks: claimability tests and smoke. Control-plane: yes.
3. Move governor filters and claimability idle state to `lib/backlog-claimability.ps1`. Checks: claimability report tests and smoke. Control-plane: yes.
4. Move bridge-self canary task creation to `lib/backlog-bridge-self-canary.ps1`. Checks: canary source-file test and smoke. Control-plane: yes.
5. Move approved/new runnable pickers to `lib/backlog-picker.ps1`. Checks: picker tests and smoke. Control-plane: yes.
6. Move operator batch reporting to `lib/backlog-operator-batch.ps1`. Checks: operator batch tests and smoke. Control-plane: yes.
7. Move self-exec/risk/reflex helpers to `lib/backlog-self-exec.ps1`. Checks: self-dev safety tests and smoke. Control-plane: yes.

## Seam map: `driver/81-loop-idle-claim.ps1` (1407 lines)

Natural seams:

- Workpack report formatting: functions at `2-84`.
- Interruptible idle sleep: `Invoke-DriverInterruptibleIdleSleep` at `86-132`.
- Idle/autonomy readiness and claim loop body: top-level code after the helper functions.
- Parallel dispatch and protected serial handoff: top-level workpack decision branches.
- Checkpoint/status emission: top-level status text and checkpoint writes.

Internal dependencies:

- The file is mostly top-level driver code, so pure extraction is riskier than in library modules.
- Helper functions are safe first moves. Top-level blocks should be wrapped only after a read-only trace confirms inputs/outputs and script-scope variables.
- Driver state depends on variables initialized by earlier numbered driver fragments; extraction must preserve dot-source order.

Safe extraction order:

1. Move only report formatting helpers to `lib/driver-workpack-report.ps1`; dot-source at the top of `driver/81-loop-idle-claim.ps1`. Checks: ParseFile for driver and new lib, workpack frontier tests, smoke, canary. Control-plane: yes.
2. Move idle sleep helper to `lib/driver-idle-sleep.ps1`. Same checks/admission.
3. Add no-op trace comments/markers around top-level claim-loop regions in a separate DISCUSS-approved atom before any top-level extraction.
4. If approved, extract the claim-loop top-level region into `Invoke-DriverIdleClaimLoop` in `lib/driver-idle-claim-loop.ps1`, with identical parameters passed explicitly. Checks: driver self-test, smoke, canary. Control-plane: yes.
5. Extract parallel dispatch/protected serial branch only after the claim-loop wrapper is stable. Checks: parallel collect guard, workpack packer tests, smoke, canary.

## Foundation #2 compliance

This plan removes size and coupling from existing files. It does not add a scheduler, worker, cache, state store, or new policy layer. The runtime entrypoints stay the same: old modules dot-source extracted files and expose the same functions. Every atom is reviewable as a move-only diff, then verified by Parser.ParseFile, the relevant existing tests, `tools/smoke.ps1`, and canary where control-plane files are touched.

## Atom contract template

Each implementation atom should include:

- `files`: source god-module plus exactly one new `lib/*` extraction file.
- `acceptance`: moved functions still resolve by original names; no call-site behavior changes; grep confirms no duplicate definitions outside the source and new extraction file.
- `checks`: Parser.ParseFile for touched PS1, targeted existing test suite, `tools/smoke.ps1`, canary for control-plane atoms.
- `bridge_self_admission`: `admitted:true`, `mode:"bridge_self_canary"`, `canary_required:true`, rollback plan = revert the move commit and remove the new dot-source.

## Summary

Recommended order is: finish Tier 2 primitive dedup, split `backlog-workpack` by low-level intake/classification/eligibility/frontier seams, split `backlog-core` by claimability/picker/batch seams, split `common` by runtime service seams, and touch `driver/81` last because top-level code makes pure moves harder.

[[PROJECT_DECISION: Tier 5 extraction must run after Tier 2 primitive dedup; divergent claim/workpack helpers stay with their domain seams until reviewed | file=decisions/2026-06-10_tier5-god-module-seam-map.md | trust=observed]]
[[PROJECT_DECISION: God-module decomposition atoms are pure move + dot-source changes with Parser.ParseFile, targeted tests, smoke, and bridge_self_canary for control-plane paths | file=decisions/2026-06-10_tier5-god-module-seam-map.md | trust=observed]]
