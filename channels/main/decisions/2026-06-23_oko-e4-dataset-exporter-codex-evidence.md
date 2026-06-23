# OKO e4 DatasetExporter evidence

Task: `oko-e4-dataset-exporter`

Observed files:

- `C:\Users\rafie\bridge-projects\oko\src\oko\training\crop_collector.py`
- `C:\Users\rafie\bridge-projects\oko\src\oko\training\dataset_exporter.py`
- `C:\Users\rafie\bridge-projects\oko\tests\test_dataset_exporter.py`

Planner RUNJOB verification:

```text
cd C:\Users\rafie\bridge-projects\oko && python -m pytest tests/test_dataset_exporter.py -v
collected 4 items
tests/test_dataset_exporter.py::test_export_creates_structure PASSED
tests/test_dataset_exporter.py::test_label_yolo_format PASSED
tests/test_dataset_exporter.py::test_data_yaml_fields PASSED
tests/test_dataset_exporter.py::test_hard_negative_class_id PASSED
4 passed in 0.14s
```

Codex sandbox verification:

```text
git -c safe.directory='C:/Users/rafie/bridge-projects/oko' -C 'C:\Users\rafie\bridge-projects\oko' status --short -- src/oko/training/crop_collector.py src/oko/training/dataset_exporter.py tests/test_dataset_exporter.py
 M src/oko/training/crop_collector.py
?? src/oko/training/dataset_exporter.py
?? tests/test_dataset_exporter.py
```

Codex commit attempt:

```text
git -c safe.directory='C:/Users/rafie/bridge-projects/oko' -C 'C:\Users\rafie\bridge-projects\oko' add src/oko/training/crop_collector.py src/oko/training/dataset_exporter.py tests/test_dataset_exporter.py
fatal: Unable to create 'C:/Users/rafie/bridge-projects/oko/.git/index.lock': Permission denied
```

Conclusion: implementation and tests are present, but OKO git commit must be performed by a non-sandbox runner or correctly scoped OKO worker.
