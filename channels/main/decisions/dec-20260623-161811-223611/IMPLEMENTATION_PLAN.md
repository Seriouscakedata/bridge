# OKO Nightly Loop + Empty Frame Sampling Implementation Plan

DecisionId: dec-20260623-161811-223611
Scope of this artifact: bridge durable plan only. Do not edit `C:\Users\rafie\bridge-projects\oko` from the bridge planning turn.

## Accepted Direction

Build OKO's empty-scene collection and a guarded nightly retraining loop. The plan keeps the safety boundary first: prove and, if needed, fix `FinetuneGate` before any unattended promotion path exists.

Storage and export semantics are intentionally different:

- Storage metadata may use `class_name=background` or `class_name=empty`.
- YOLO export must represent empty/background examples as images with empty label files.
- The YOLO `names` list must not gain a synthetic `background` object class.

## Execution Order

1. Safety core: verify `FinetuneGate` by code and add regression coverage that rejects a worse candidate.
2. Atomic promotion: replace unlink/copy promotion with an atomic pointer or `os.replace` style swap and rollback marker.
3. Empty-scene sampling: extend `CropCollector` with timer, no-detection threshold, and scene-memory `background_only` triggers.
4. Empty and hard-negative metadata: write negative examples under `runs/labels/<cam>/` with provenance and hashes.
5. Dataset export: emit negative examples as empty YOLO label files, add deterministic balancing and manifest counts.
6. Gemini training-time labeling: add thresholds, abstention/agreement handling, spot-check sampling, and a hard ban on Gemini labels in held-out eval.
7. Nightly scheduler: implement phases separately, with ledger/idempotency, GPU lock, inference degraded/pause mode, night-window watchdog, and CLI trigger.
8. First real training: default to `dry_run=true`, `auto_promote=false`, notify Telegram with before/after metrics and gate verdict.

## Review Gates

- Every atom is one implementation file plus one focused test file where possible.
- Every atom runs `pytest oko` or a narrower OKO pytest target plus the final full `pytest oko`.
- Architect-Claude reviews each atom before marking done.
- No auto-promotion is enabled until the operator confirms one dry-run night.

## Open Questions For Operator Or Architect

- Trigger mechanism: existing bridge nightly mechanism or a dedicated Windows scheduled task for OKO.
- Trusted held-out source: human-labeled subset or reserved trusted slice; never Gemini-labeled.
- Initial balance policy: placeholder is positive:empty:hard-negative `3:1:1`, tune from real manifest counts.
- Gemini thresholds: exact confidence cutoff, abstention rule, and spot-check rate.
- Empty sampling cadence: choose 5 or 10 minutes and the no-detection frame threshold from live volume.
- GPU contention policy: full live inference pause or degraded mode, with acceptable latency/availability.

## Durable Atom List

The machine-readable atom list is stored in `implementation_atoms.json` next to this plan. It is intentionally external-repo scoped and should be executed by the OKO project runner, not by this bridge-only planning turn.
