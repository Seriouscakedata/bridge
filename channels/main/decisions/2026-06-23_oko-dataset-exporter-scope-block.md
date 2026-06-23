# OKO dataset exporter scope block

Date: 2026-06-23

Task: `oko-e4-dataset-exporter`

Requested touch-set:

- `C:\Users\rafie\bridge-projects\oko\src\oko\training\dataset_exporter.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_dataset_exporter.py`
- implied: `C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py`
- implied: `C:\Users\rafie\bridge-projects\oko\src\oko\training\eval_harness.py`

Observed runtime scope for this Codex turn: `C:\Users\rafie\OneDrive\Documents\bridge` only.

Result: blocked. The task requires editing and committing files in the external OKO repository, but the active autonomous-task scope explicitly says not to change projects or files outside bridge. The filesystem sandbox also exposes writable roots for bridge only, so applying the requested OKO patch from this turn would violate scope.

Factual checks:

- Bridge status check with safe.directory override returned no changed files before evidence creation.
- OKO status is dirty before this task, with existing unrelated runtime artifacts such as `runs/oko-events.jsonl`, `AUTOTRAIN_PLAN.md`, and many `runs/incidents/*.mp4` files. These must not be mixed into the dataset-exporter commit.
- `C:\Users\rafie\bridge-projects\oko\src\oko\training\dataset_exporter.py` does not exist.
- `C:\Users\rafie\bridge-projects\oko\tests\test_dataset_exporter.py` does not exist.
- `CropRecord` in `crop_collector.py` currently has no `frame_w` / `frame_h` fields.

Required next execution context:

- Run Codex with writable project root `C:\Users\rafie\bridge-projects\oko`.
- Restrict git add to the requested OKO files only.
- Do not add existing unrelated `runs/` artifacts.
- Run:
  - `python -m pytest tests/test_dataset_exporter.py tests/test_crop_collector.py tests/test_eval_harness.py -v`
- Commit in OKO only:
  - `feat(training): DatasetExporter YOLO format with hard negatives`

