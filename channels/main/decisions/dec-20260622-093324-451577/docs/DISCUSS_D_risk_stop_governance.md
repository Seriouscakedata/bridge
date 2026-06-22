# DISCUSS_D: Risk, STOP, And Operator Governance

Status: `DRAFT_FOR_OPERATOR_REVIEW`
Related decisions: DA006, DA007, DA009

## Decision

Risk classification and operator control sit outside the planner. The planner can propose intent and risk hints; it cannot authorize itself.

## Risk Ladder

Risk is classified by independent policy from typed action, target, perceived context, approved envelope, and predicted effect:

- `low`: read-only observation, navigation without mutation.
- `medium`: local reversible edits such as typing into a draft field.
- `high`: sending messages, changing system/app settings, destructive operations, irreversible external effects, credential/payment/security-sensitive flows.
- `critical`: unknown/unclassifiable effect, identity ambiguity for a real person/account, suspected prompt injection, policy conflict, or action outside approved envelope.

Unknown defaults to `critical`.

## Sequence-Level Risk

Per-step risk is not enough. Before executing each ready node, policy must evaluate path risk:

- does the path make a high-risk effect reachable;
- does a sequence of low/medium steps prepare an irreversible action;
- does the current node move toward a target outside the approved envelope;
- does observed screen content attempt to steer risk or policy.

If sequence-level risk is higher than the current step risk, the higher tier wins.

## Confirmation And TOCTOU

High-risk effects require synchronous operator confirmation. After confirmation and before actuation, LAPA must re-prove the target, payload, and relevant UI state. If target/payload/state changed during the confirmation delay, confirmation is stale and the system asks again or stops.

## STOP Semantics

Operator STOP is checked before every gate and before recovery/replan. Planner self-STOP fires on:

- budget exhaustion;
- low confidence;
- repeated verification failure;
- oscillation;
- unresolvable ambiguity;
- unexpected high-risk state;
- operator-defined boundary.

STOP means halt further action and report:

- last known state;
- uncertain state;
- already emitted effects;
- irreversible effects, if any;
- suggested safe next step.

STOP does not claim it can rollback an already sent message, deleted file, or completed OS effect.

## Test Criteria

- Planner mislabels send as low risk; policy still requires confirmation.
- Individually low-risk path reaches a destructive/system setting state; sequence-level gate escalates.
- Operator STOP before a recovery step halts and emits diagnostic.
- Confirmation delay changes target/payload; post-confirm re-prove catches staleness.
- Unknown effect defaults to critical.
