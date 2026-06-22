# DISCUSS_E: Open Questions Before Implementation

Status: `DRAFT_FOR_OPERATOR_REVIEW`

These are blocking design parameters for implementation. The architecture is approved as a design direction, but code work should not begin until the operator accepts or edits these defaults.

## A. Approved Envelope Defaults

Proposed default: in-envelope replanning may change only local navigation and recovery steps inside the same app, target identity, success criterion, and risk tier. Any new app, account, chat, high-risk effect class, destructive/system setting path, or budget overrun requires re-approval or STOP.

Operator question: should any app-switching be allowed inside one high-level task without re-approval?

## B. Budgets And Thresholds

Proposed defaults for first implementation:

- max executable steps per task: 20;
- max local retries per node: 2;
- max local replans per task: 3;
- max consecutive verification failures: 2;
- oscillation window: 4 recent world states with repeated A/B pattern;
- low-confidence cutoff: verifier confidence below 0.70;
- max task wall time: operator-configurable, default 10 minutes for non-send/non-destructive tasks.

Operator question: are these conservative enough for early pilots?

## C. Postcondition Authoring

Proposed default: combine per-skill postcondition templates with LLM-filled parameters, then validate against schema. Operator-specified postconditions may override templates for sensitive tasks. Free-form postconditions are invalid unless they compile to schema.

Operator question: should the first version ship only with template-derived postconditions?

## D. Independent Verifier And Risk Policy

Proposed default:

- risk policy: deterministic rules over typed action, target, context, envelope, and sequence path;
- verifier: hybrid deterministic checks plus separate model prompt only for perception/semantic ambiguity;
- high-risk success requires at least two evidence sources when available.

Operator question: should verifier use a different model/provider from planner for stronger independence?

## E. STOP Safe-State Reporting

Proposed default: report `known`, `unknown`, and `irreversible` effects instead of promising rollback. Before irreversible actions, create an audit checkpoint containing target, payload, risk class, confirmation id, and pre-act evidence.

Operator question: what diagnostic format should the operator receive for partial state?

## F. Vision Escalation Thresholds

Proposed defaults:

- ambiguity: more than one plausible target or verifier confidence below 0.80;
- progress stall: no relevant state delta after one wait/retry cycle;
- oscillation: repeated A/B state pattern in the last 4 observations;
- vision budget: max 3 vision calls per normal task before asking operator, unless high-risk verification needs one final evidence check.

Operator question: prioritize lower cost or fewer false stops?

## G. Capability Coverage

Proposed default: missing capability leads to self-STOP and a request for a new declared skill. The planner should not improvise generic GUI automation outside vocabulary.

Operator question: should there be a sandboxed "manual UI path" capability later, or keep v1 strictly skill-bound?

## H. Audit Retention

Proposed default: append structured audit records for plan, decisions, risk classifications, confirmations, verification evidence, replans, and STOP diagnostics. Retention follows bridge channel logs unless operator sets a shorter policy for screen-sensitive tasks.

Operator question: should screen captures be stored, redacted, or summarized only?
