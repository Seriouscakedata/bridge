# PROJECT_BRIEF: LAPA Planner Layer

## Purpose

LAPA already has reliable hands: a five-gate execution loop, declared skills (`open`, `type`, `telegram`), and vision fallback for canvas/element-location cases. The missing layer is autonomous high-level task planning: today the operator decomposes a goal into concrete actions; LAPA executes those concrete actions.

This design adds an advisory planner layer above the existing hands. The planner reasons about the operator's high-level goal, proposes a high-level plan, and later helps select the next step. It does not touch the OS, UI, files, Telegram, or settings directly. Every executable action still passes through the existing five-gate loop.

## Non-Negotiable Constraints

- Discuss-First: produce `PROJECT_BRIEF -> DISCUSS_* -> PROJECT_MAP -> PROJECT_PLAN -> CONTRACT.json` and stop for operator review.
- No executable atoms or atomic GUI actions before approval.
- Planner is advisory-only; the five-gate loop remains the single execution chokepoint.
- Fail closed on ambiguity, missing state, failed verification, risk escalation, and vision disagreement.
- Declared-risk ladder is deterministic and cannot be overridden by the LLM.
- Sends, system settings, destructive operations, and unknown action classes require confirmation or denial.
- STOP is available before every gate and before recovery/replan.
- Screen/OCR/vision text is untrusted data, never instructions.

## Desired End State

After operator approval and later implementation, LAPA can receive a high-level task, produce a high-level TaskGraph, obtain review, then execute closed-loop:

1. Sense the current context.
2. Plan the next approved high-level step.
3. Compile only that step into typed loop actions just in time.
4. Execute via the existing five-gate loop.
5. Verify the node postcondition.
6. Recover or replan within the approved envelope.
7. Stop and report when safety, scope, confidence, or verification requires it.

## Discuss-First Deliverable Boundary

This package is a design artifact only. It intentionally does not integrate code, create executable atoms, or enable autonomy. Implementation success tests from the original task are preserved as post-approval acceptance tests, not as claims that the system has already been built.

## Operator Review Needed

The operator should approve or revise:

- Initial task classes for rollout.
- STOP budgets and confidence thresholds.
- Replan-depth and material-divergence limits.
- Allow/confirm/deny ownership and change-control.
- Vision confidence thresholds and audit retention.
- Whether the proposed `CONTRACT.json` is acceptable for implementation planning.
