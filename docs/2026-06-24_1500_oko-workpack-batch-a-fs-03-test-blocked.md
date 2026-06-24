# OKO workpack batch: A-FS-03 test remains blocked by scope

Current coder scope is limited to:

```text
C:\Users\rafie\OneDrive\Documents\bridge
```

The remaining workpack change belongs to the external OKO repository:

```text
C:\Users\rafie\bridge-projects\oko
```

## Verified read-only state

Command:

```powershell
Select-String -Path 'C:\Users\rafie\bridge-projects\oko\src\oko\pipeline\live.py','C:\Users\rafie\bridge-projects\oko\tests\test_live_pipeline.py' -Pattern 'event_frame=','captured\.image\.copy\(','test_immutable_event_frame','test_event_frame_crop','test_bbox_source_frame_binding'
```

Relevant output:

```text
C:\Users\rafie\bridge-projects\oko\src\oko\pipeline\live.py:258:event_frame=(
C:\Users\rafie\bridge-projects\oko\src\oko\pipeline\live.py:259:captured.image.copy()
C:\Users\rafie\bridge-projects\oko\tests\test_live_pipeline.py:869:def test_event_frame_crop(tmp_path: Path) -> None:
C:\Users\rafie\bridge-projects\oko\tests\test_live_pipeline.py:947:def test_bbox_source_frame_binding(tmp_path: Path) -> None:
```

Interpretation:

- A-FS-03 code fix is present in `live.py`.
- `test_immutable_event_frame` is still absent from `tests/test_live_pipeline.py`.

## Targeted pytest check

Command:

```powershell
$env:PYTHONDONTWRITEBYTECODE='1'; python -m pytest tests/test_live_pipeline.py -k immutable_event_frame -q -p no:cacheprovider --basetemp 'C:\tmp\oko_immutable_event_frame_pytest'
```

Working directory:

```text
C:\Users\rafie\bridge-projects\oko
```

Output:

```text
27 deselected in 0.16s
```

Interpretation: the requested regression test is not present, so the A-FS-03 acceptance cannot be fully verified from the current bridge-only coder scope.
