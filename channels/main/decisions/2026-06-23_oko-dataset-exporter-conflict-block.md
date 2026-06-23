# OKO dataset exporter conflict block

Time: 2026-06-23 07:49:31 +03:00

Task: `oko-e4-dataset-exporter`

Result: blocked in this Codex turn.

Observed state:

- Bridge worktree status was clean via `git -c safe.directory='C:/Users/rafie/OneDrive/Documents/bridge' -C 'C:\Users\rafie\OneDrive\Documents\bridge' status --short`.
- OKO status for target files: `src/oko/training/crop_collector.py` is modified; `src/oko/training/dataset_exporter.py` and `tests/test_dataset_exporter.py` are absent.
- `crop_collector.py` already contains `frame_w` and `frame_h` fields and writes them to JSONL/`CropRecord`.
- Probe write to `C:\Users\rafie\bridge-projects\oko\.codex_write_probe.tmp` was rejected by sandbox policy before execution.
- `python -m pytest tests/test_dataset_exporter.py -v` in OKO failed because `tests/test_dataset_exporter.py` does not exist.
- `python -m pytest tests/test_crop_collector.py -v` could not run to code assertions because pytest temp creation is denied under `C:\Users\rafie\AppData\Local\Temp\pytest-of-rafie`; reruns with `--basetemp C:\tmp\pytest-oko-crop` and bridge `.tmp` were also denied.

Conclusion:

The conflict cannot be resolved from this turn because the missing OKO files are outside the writable roots. A correctly scoped OKO worker is needed to create `src/oko/training/dataset_exporter.py`, `tests/test_dataset_exporter.py`, stage only the target files, and run pytest with a writable temp directory.
