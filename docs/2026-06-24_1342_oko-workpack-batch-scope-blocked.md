# OKO workpack batch scope block

Date: 2026-06-24

Task: execute two independent approved OKO workpacks in one verified pass.

Result: blocked by active task scope. The current coder instruction says the autonomous task scope is only the bridge repository:

`C:\Users\rafie\OneDrive\Documents\bridge`

and explicitly says not to change other projects or files outside bridge. The selected workpacks target the external OKO repository:

`C:\Users\rafie\bridge-projects\oko`

## Read-only findings

Checked files:

- `C:\Users\rafie\bridge-projects\oko\src\oko\pipeline\live.py`
- `C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_live_pipeline.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_crop_collector.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_webcam_source.py`

Observed with `Select-String`:

- `B-CN-03` appears applied: `CropCollector` has `session_id`, crop filenames include session id, records include `session_id`, and restart tests exist.
- `A-FS-03` is still not applied: `live.py` stores `_PendingVlmEvent.event_frame` as `captured.image` directly, using `__import__("numpy").ndarray`, with no `.copy()`.

Relevant snippet from `live.py`:

```python
event_frame=(
    captured.image
    if isinstance(captured.image, __import__("numpy").ndarray)
    else None
),
```

## Required next action

To complete the OKO workpack, rerun the task with scope explicitly allowing edits in:

`C:\Users\rafie\bridge-projects\oko`

Then apply `A-FS-03` by storing an immutable copy at trigger time and adding `test_immutable_event_frame`.
