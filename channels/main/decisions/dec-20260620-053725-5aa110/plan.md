# Plan: Memory Weakness Analysis
# DecisionId: dec-20260620-053725-5aa110
# Date: 2026-06-20
# Status: PLAN-ONLY — no memory code modified; improvements are specs for follow-up pass

## Statement

This task is reflection+design only. No files under lib/, tools/, or driver/ are modified here.
The two selected improvements are specifications for a follow-up pass.
No new layers, no new validators, no new monitoring services are introduced.
Foundation #2: harden and reuse existing mechanisms — do not proliferate.

---

## Section 1: 16-Weakness Table — Code-Verified Status

| # | Weakness | Status | Verdict + code reference |
|---|----------|--------|--------------------------|
| W1 | Authority levels mixed in recall render | b | `Get-MemoryRecall:1060` outputs `- (pct%) text` with no kind/trust prefix; separate section headers exist (ПЛЕЙБУК, НЕ ПОВТОРЯТЬ) but all other kinds render identically |
| W2 | Auto memory writes summaries, not deltas | b | `Update-ProjectMemoryAfterTask:285` writes free-text outcome; `Add-TaskMemory` has LLM gate (`Get-MemoryDistilled`) but no 4-question evidence structure enforced |
| W3 | Task-memory pollutes recall over time | b | importance: worklog=0.55 vs project_fact=0.75 (`Add-ProjectMemoryFromMarker:273`); `Invoke-MemoryDedup:1284` prunes by cosine; no TTL-by-kind rule |
| W4 | Freshness check depends on agent providing sha1 | b | `Test-MemoryHitFreshness:895` skips if no sha1 (`if (-not $hasSha1) { return $true }`); `verifyOnRecall=true` default active; but `ConvertFrom-ProjectMemoryMarker:257` does NOT auto-resolve sha1 at write |
| W5 | Detached memory-tail can silently die | c | `memory-tail.ps1:30-45` wraps all 3 blocks in bare `catch {}`; success logged to Add-Message only; no `memory_status.json` heartbeat; all failure is silent |
| W6 | Semantic recall retrieves similar-but-not-needed | b | `Get-MemoryRecall:1049` = pure semantic top-K; `Get-ProjectContextPack` adds structured facts-by-kind separately; no always-on invariant slot in the semantic recall path |
| W7 | Memory records can conflict with no supersede | c | No `superseded_by` field in memory schema; backlog has supersede (`lib/backlog-dedup.ps1:94`) but memory does NOT; `pinned` prevents deletion but not conflict |
| W8 | Code index can be stale independently | b | Code index exists and is queried; no freshness timestamp shown in prompt; no per-file partial reindex triggered on git diff |
| W9 | Decisions not all in vector memory | b | `Get-DecisionsRecall` reads decisions/ directly; `librarian.log` + `librarian.last` (`memory.ps1:154-158`) track consolidation; OneDrive ReparsePoint issue known |
| W10 | Fast-lane too blind to project invariants | b | `Test-IsTrivialTask` gates fast-lane (`lib/prompt-builder.ps1:553`); no mandatory safety pack (active invariants + blocking decisions) injected for fast-lane context |
| W11 | Agent-written markers can be irregular | b | Marker system exists (`[[PROJECT_FACT:...]]` etc.); driver prompt instructs use; no end-of-task "max 1-3 items" structured candidate block |
| W12 | Librarian can delete rare but important records | b | `Invoke-MemoryDedup:1309-1312` protects `pinned=true` only; no kind-guard for `project_decision`/`project_invariant`/`project_test` — semantic dedup can silently drop them |
| W13 | No recall quality evaluation | c | No replay test set; no `must_recall`/`must_not_recall` cases; `test-audit-context.ps1` tests audit context, not recall quality |
| W14 | Memory can prevent agent from reading actual code | b | Driver prompt references memory files; `Get-MemoryRecall:1060` renders no per-item trust signal except `[FROM BRIDGE - readonly]` for bridge-scoped records |
| W15 | Too many sources → duplicate context, no budget | b | `maxInjectChars=1200` per source (`memory.ps1:369`); no global context budget with priority-ordered eviction |
| W16 | Main principle: more contracts, fewer checks | b | Several contracts partial: stale-lazy-check (`verifyOnRecall=true`), evidence-fields, pinned-guard; missing: authority hierarchy in render, write budget, retention-by-kind |

Status codes: (a) already closed with code citation, (b) partially addressed, (c) really hurts / absent

---

## Section 2: 7-Priority Evaluation

| Priority | Status | Cost | Notes |
|----------|--------|------|-------|
| P1: Authority levels in prompt | ABSENT | CHEAPEST | Render-only: prefix `[kind/trust]` in `Get-MemoryRecall:1060` + disclaimer header; reuses existing fields |
| P2: Auto evidence enrichment | ABSENT | MEDIUM | File I/O at `ConvertFrom-ProjectMemoryMarker:257`; git commit NOT available in driver/84 sandbox (coder cannot reach .git) → only sha1+line_text |
| P3: One memory_status.json heartbeat | ABSENT | CHEAP (fast-follow only) | New file write = new mechanism → DEFERRED (Foundation #2 violation) |
| P4: Retention by type | PARTIAL | MEDIUM | importance scores vary; no explicit TTL/prune rules by kind; medium blast radius on delete logic |
| P5: Mixed recall (always-on invariants) | PARTIAL | HIGH | `Get-ProjectContextPack` provides separate structured block; always-on invariant slot inside semantic recall path requires architectural change |
| P6: Replay test set for recall quality | ABSENT | HIGH | New infrastructure; valuable but large scope |
| P7: Lazy stale check for recalled only | ALREADY DONE | — | `verifyOnRecall=true` default + `Set-MemoryHitsLastRecalled:927` fires `Test-MemoryHitFreshness` only on recalled items |

Cheapest to implement: **P1** (render-only, one function, no data mutation).  
Cheapest fast-follow (not adopted this pass): **P3** memory_status.json heartbeat.  
Why P3 excluded this pass: new monitoring mechanism → Foundation #2 (harden, do not proliferate).

---

## Section 3: Selected Improvements (Specifications — not yet implemented)

### Improvement #1: Authority/trust labels in Get-MemoryRecall render

**File**: `lib/memory.ps1` — function `Get-MemoryRecall` (lines 1043-1066)

**Change spec**: 
- Add a disclaimer header before the body: `подсказка, не истина; код — источник правды; worklog/hypothesis проверять по файлам`
- For each recalled item, prefix with `[kind/trust]` using existing `Get-MemoryKind` and `Get-MemoryTrust` helpers (already available at memory.ps1:695-716)
- Example output line: `- (79%) [project_worklog/observed] Task completed: ...`

**Reused mechanism**: existing `kind`/`trust` fields on every memory record (memory.ps1:677-716) + existing `Get-MemoryKind`/`Get-MemoryTrust` functions

**Adds**: NO new field, NO new validator, NO new layer

**Risk**: LOW — render-only, no data mutation, backwards-compatible

**Acceptance test**: `Get-MemoryRecall` output shows:
1. One disclaimer header line
2. Each entry prefixed with `[kind/trust]` extracted from the record
3. `project_decision` and `project_invariant` visually distinct from `project_worklog` and `memory_note`

**Open question to resolve at implementation**: Does `Get-MemoryRecall` read back kind/trust from the stored record (status a, render-only) or must it call `Get-AllMemories` to reload? (Currently it uses the `$h.Mem` object from `Search-Memory` which already carries all fields — confirm `$h.Mem.kind` and `$h.Mem.trust` are populated before assuming render-only change.)

---

### Improvement #2: Auto evidence enrichment at marker write

**Files**: `lib/project-context.ps1` — function `ConvertFrom-ProjectMemoryMarker` (lines 243-266)

**Change spec**:
- After parsing `evidence` dict from marker fields (line 257), if `evidence.file` is present but `evidence.sha1` is absent:
  1. Resolve file path relative to bridge root (use existing `Resolve-MemoryContainedPath` for safety)
  2. If file exists: compute SHA256 of file content; capture line text at `evidence.line` if provided
  3. Backfill `evidence.sha1` and `evidence.line_text` into the evidence object
  4. If file missing: silent skip (do not error)
- git commit NOT backfilled at this path (driver/84 synchronous marker-reply: `.git` unreachable from coder sandbox) → commit field deferred to optional librarian enrichment pass

**Lazy freshness folded in (sub-item)**:
- No code change needed: `Test-MemoryHitFreshness:895` already activates once `evidence.sha1` is present; `verifyOnRecall=true` is already default; `restaleOnSha1Mismatch=true` is already default
- Auto-enrichment at write is the PRECONDITION that makes lazy freshness actually fire for marker-written records

**Reused mechanism**: existing `evidence` schema fields (`file`, `sha1`, `line_text`) + existing `Test-MemoryHitFreshness` + existing `Resolve-MemoryContainedPath` for path safety

**Adds**: NO new evidence service, NO new validator

**Risk**: MEDIUM — file I/O at marker-write time (synchronous, driver/84 path); must be contained (path traversal guard via existing `Resolve-MemoryContainedPath`); missing file = silent skip; large files (sha256 of entire file) is fast but must not throw

**Acceptance test**:
1. A marker `[[PROJECT_FACT: foo | file=lib/memory.ps1 | line=1043]]` (no sha1) → after `Add-ProjectMemoryFromMarker`, the stored record has `evidence.sha1` (non-empty) and `evidence.line_text` containing the actual line content
2. If the file is then modified, a subsequent `Search-Memory` recall marks the entry `stale` via existing `Test-MemoryHitFreshness`
3. A marker with `file=nonexistent.ps1` → silent skip, evidence.sha1 remains absent

---

## Section 4: Deferred / Next-Pass

These were evaluated but NOT adopted in this pass (to respect 2-3 improvement cap and Foundation #2):

- **memory_status.json heartbeat** (P3): cheapest fast-follow; excluded because it is a new monitoring mechanism
- **Retention TTL by kind/source** (P4, W3): valuable but requires changes to dedup/delete logic; medium blast radius
- **Always-on invariant slot in recall** (P5, W6): architectural; risk of breaking existing context pack balance
- **Replay test set for recall quality** (P6, W13): new infrastructure; high value but large scope
- **Subject/predicate conflict model** (W7): no supersede field in memory schema; medium effort, blocks W7 fully
- **Kind-aware delete protection in Invoke-MemoryDedup** (W12): project_decision/project_invariant/project_test should not be dropped by cosine similarity; medium effort, low risk
- **Global context budget manager** (W15): cross-source token budget with priority eviction; architectural
- **Code index freshness banner in prompt** (W8): show index timestamp + changed-files warning
- **End-of-task MEMORY CANDIDATES structured block** (W11): max 1-3 items, explicit "nothing worth saving" option

Fast-follow order recommendation: P3 heartbeat → W12 kind-guard in dedup → W7 supersede field → W8 code index banner

---

## Operator Verification Checklist

- [ ] 16-row table: every status backed by file:symbol citation
- [ ] Status values are single letters: a, b, or c (rows W1/W5/W7/W13 = c; rest = a or b)
- [ ] Exactly 2 improvements selected; deferred list names all others
- [ ] Each improvement names the existing mechanism it reuses
- [ ] No new layer/validator/service introduced
- [ ] Improvement #2 notes git-commit limitation (driver/84 cannot reach .git)
- [ ] Lazy freshness is correctly marked as ALREADY DONE (P7), not as a new improvement
- [ ] memory_status.json heartbeat is named as cheapest fast-follow but explicitly excluded this pass
