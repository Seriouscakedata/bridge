# OKO e4 DatasetExporter Scope Block

Date: 2026-06-23

Task: `oko-e4-dataset-exporter`

The current Codex turn is scoped to the bridge workspace, while the task requires writes in:

- `C:\Users\rafie\bridge-projects\oko\src\oko\training\dataset_exporter.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_dataset_exporter.py`

Observed state:

- Bridge status is clean before this evidence file.
- `dataset_exporter.py` does not exist.
- `test_dataset_exporter.py` does not exist.
- OKO has an existing modified target file: `src/oko/training/crop_collector.py`.
- `CropRecord` already contains `frame_w` and `frame_h` from the merged worker.

Acceptance check run:

```text
python -m pytest tests/test_dataset_exporter.py -v -p no:cacheprovider

collected 0 items
ERROR: file or directory not found: tests/test_dataset_exporter.py
```

Required next action: reroute this atom to an OKO-scoped worker or grant the task a writable root for `C:\Users\rafie\bridge-projects\oko`.
