# PROJECT_BRIEF: LAPA Planner Layer

Decision id: `dec-20260622-093324-451577`
Status: `DRAFT_FOR_OPERATOR_REVIEW`
Scope: design package only, stored inside bridge. No executable atoms are generated before operator approval.

## Goal

LAPA currently provides reliable operator "hands": a 5-gate loop, concrete skills (`open`, `type`, `telegram`), and vision support for canvas/visual locating. The missing layer is autonomous high-level task planning: given an operator intent, LAPA should decompose it into a sequence of loop actions such as `open -> perceive -> navigate -> act`, verify progress, recover when blocked, and stop or ask for approval when the task crosses safety boundaries.

The proposed planner is not a new actuator. It is a strictly additive orchestrator over the existing reliable hands. It selects the next typed loop-action and sends that action through the existing gates.

## Non-Negotiable Constraints

- Discuss-First: deliver `PROJECT_BRIEF -> DISCUSS_* -> PROJECT_MAP -> PROJECT_PLAN -> CONTRACT.json` for operator review before implementation.
- No executable atoms, code commits for implementation, or external LAPA edits before approval of `PROJECT_PLAN` and `CONTRACT.json`.
- The planner must never bypass the 5-gate loop.
- The planner must never self-declare risk as authoritative; risk is determined by an independent deterministic policy.
- Fail-closed default: unknown capability, unknown risk, unverifiable success, ambiguous target, or out-of-envelope replan stops or asks the operator.
- STOP must be checked before every gate and before recovery/replan. STOP cannot promise rollback of already emitted OS effects; it must produce a partial-state report for irreversible or uncertain effects.

## Accepted Design Decisions

- DA001: additive orchestration over the existing 5-gate loop.
- DA002: per-step plan, pre-verify, execute-via-loop, post-verify, recover discipline.
- DA003: LLM hierarchical decomposition into a typed mutable task graph with dependencies, preconditions, postconditions, and recovery paths.
- DA004: every executable subgoal carries a machine-checkable postcondition verified through perception, with vision fallback.
- DA005: vision participates in planning as world-model input, mismatch detector, stuck/oscillation detector, and postcondition judge.
- DA006: risk ladder is independent and deterministic; high-risk effects require synchronous operator confirmation.
- DA007: operator hard STOP plus planner self-STOP on budgets, low confidence, repeated failure, ambiguity, unexpected risk, or operator boundaries.
- DA008: bounded recovery ladder: diagnose, bounded retry, local replan, ask operator, stop.
- DA009: operator approval is scoped to the TaskContract and risk envelope; in-envelope replanning is allowed, out-of-envelope replanning requires re-approval or STOP.
- DA010: typed action vocabulary only; no free-form code or invented actions.
- DA011: generator-verifier separation; the planner is not the sole judge of success or safety.
- DA012: cheap-perception-first; escalate to vision for canvas, ambiguity, mismatch, progress stall, or postcondition verification that cannot be resolved cheaply.

## Red-Team Corrections Folded Into This Package

- Sequence-level risk is added on top of per-step risk to catch emergent high-risk paths.
- Screen content is treated as untrusted input and isolated from planner instructions.
- Goal-level verification is required after all per-step postconditions pass.
- STOP semantics are narrowed to "halt plus report known/unknown/irreversible state", not "rollback all effects".
- Post-confirm re-prove is required before high-risk execution to close the human-confirmation TOCTOU window.

## Review Gate

The operator must approve `PROJECT_PLAN.md` and `CONTRACT.json` before any implementation or backlog atom generation.
