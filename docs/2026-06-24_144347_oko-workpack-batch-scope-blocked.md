# OKO workpack batch scope block

Date: 2026-06-24 14:43:47

Task: execute two independent approved OKO workpacks in one verified pass.

Active coder scope for this turn is restricted to:

`C:\Users\rafie\OneDrive\Documents\bridge`

The requested workpacks require writes in the external repository:

`C:\Users\rafie\bridge-projects\oko`

## Verified state

Bridge worktree was clean before this evidence file:

```text
git -c safe.directory='C:/Users/rafie/OneDrive/Documents/bridge' -C 'C:\Users\rafie\OneDrive\Documents\bridge' status --short
<no output>
```

B-CN-03 is already present in OKO:

```text
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:26:session_id: str = ""
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:30:def __init__(self, labels_root: Path, session_id: str | None = None) -> None:
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:32:self._session_id = session_id if session_id is not None else uuid.uuid4().hex[:16]
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:64:crop_path = crops_dir / f"{self._session_id}_{frame_id:08d}_{uuid.uuid4().hex[:12]}.jpg"
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:71:"session_id": self._session_id,
C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py:96:session_id=self._session_id,
C:\Users\rafie\bridge-projects\oko\tests\test_crop_collector.py:80:def test_restart_safe_crop_names(tmp_path: Path) -> None:
C:\Users\rafie\bridge-projects\oko\tests\test_webcam_source.py:121:def test_restart_frame_id_reset(monkeypatch: pytest.MonkeyPatch) -> None:
```

A-FS-03 is still not present in OKO. `event_frame` stores the original buffer reference:

```text
258:                                    event_frame=(
259:                                        captured.image
260:                                        if isinstance(captured.image, __import__("numpy").ndarray)
261:                                        else None
262:                                    ),
```

`tests/test_live_pipeline.py` contains `test_event_frame_crop`, but no `test_immutable_event_frame` was found:

```text
869:def test_event_frame_crop(tmp_path: Path) -> None:
```

## Required follow-up

To complete A-FS-03, run a worker with write access to `C:\Users\rafie\bridge-projects\oko` and apply:

```python
event_frame=(
    captured.image.copy()
    if isinstance(captured.image, np.ndarray)
    else None
),
```

Then add `test_immutable_event_frame` in `tests/test_live_pipeline.py` and run:

```text
pytest tests/test_live_pipeline.py -k immutable_event_frame -v
pytest tests/test_live_pipeline.py -v
pytest tests/test_crop_collector.py tests/test_webcam_source.py -k restart -v
```

