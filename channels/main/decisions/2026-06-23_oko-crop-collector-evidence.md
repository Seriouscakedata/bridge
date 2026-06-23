# OKO CropCollector Evidence

Task: `oko-e2-crop-collector`

External repository: `C:\Users\rafie\bridge-projects\oko`

Observed implementation commit:

```text
760dc74 feat(training): CropCollector for person/animal crop labeling
```

Verification:

```text
python -c "<pytest wrapper for Windows 0o700 basetemp ACL>" ...

collected 4 items
test_collect_creates_directories PASSED
test_collect_saves_crop_file PASSED
test_collect_writes_jsonl PASSED
test_collect_clamps_bbox PASSED

4 passed in 0.12s
```

Note: direct `python -m pytest tests/test_crop_collector.py -v` failed before test bodies because
the sandbox user cannot access pytest's default `0o700` basetemp directories on this Windows host.
The wrapper only normalizes `Path.mkdir(mode=0o700)` to the default mkdir mode before invoking pytest;
OKO source and tests are not modified by the wrapper.
