# OKO workpack batch 2026-06-24 13:42

Scope: bridge-side evidence only.

The requested batch targets the external OKO repository at
`C:\Users\rafie\bridge-projects\oko`, while the active autonomous task scope
states: only `C:\Users\rafie\OneDrive\Documents\bridge`; do not change other
projects/files outside bridge.

Observed state from read-only checks:

- bridge working tree was clean before this evidence file was created.
- OKO `crop_collector.py`, `test_crop_collector.py`, and `test_webcam_source.py`
  already contain the B-CN-03 `session_id` / restart-safe crop-name changes.
- OKO `live.py` still stores `_PendingVlmEvent.event_frame` as the original
  `captured.image` reference, using `__import__("numpy").ndarray`; the A-FS-03
  immutable event-frame fix was not present in the checked source.
- OKO working tree contains unrelated runtime/untracked artifacts under `runs/`
  and temporary pytest directories, so direct cleanup or merge repair from the
  bridge-scoped sandbox would risk touching user/project data outside the
  allowed scope.

Required next action outside this restricted coder scope:

- Apply A-FS-03 in OKO via the external-repo dispatcher or an operator-approved
  OKO-scoped worker:
  `captured.image.copy() if isinstance(captured.image, np.ndarray) else None`
  and add `test_immutable_event_frame`.
- Run `pytest tests/test_live_pipeline.py -k immutable_event_frame -v`.
- Re-run the combined touched regression for the OKO files after merge.
