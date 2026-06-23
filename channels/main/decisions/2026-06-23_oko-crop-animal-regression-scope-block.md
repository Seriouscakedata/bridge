# OKO CropCollector Animal Regression Scope Block

Date: 2026-06-23

Task: `[oko] РЕГРЕСС-ТЕСТ: CropCollector ДОЛЖЕН собирать кропы для ANIMAL-событий`

External repository: `C:\Users\rafie\bridge-projects\oko`

Current execution scope: `C:\Users\rafie\OneDrive\Documents\bridge` only.

Result: blocked for code changes. The task requires adding tests and changing Python files in the external OKO repository, but the active autonomous-task scope says not to change projects or files outside bridge. This turn therefore performed a read-only audit and recorded exact evidence instead of modifying OKO.

## Read-Only Audit

Observed existing live fix:

- `src/oko/pipeline/live.py` imports private `oko.events.builder._class_is_animal`.
- Trigger matching now checks:
  - `built_event.event.event_type.startswith(_cn)`, preserving `person_entered_zone` + `person`.
  - `built_event.event.event_type.startswith("animal") and _class_is_animal(_cn)`, fixing `animal_entered_zone` + `cat` / `dog`.

Required regression test is not present:

- No `tests/test_crop_animal_regression.py`.
- Only crop-related test file found: `tests/test_crop_collector.py`.

Downstream audit result:

- `incident-video trigger`: no category-vs-specific-class comparison found. Video output is attached from delayed `pending.frames` in `LivePipeline._resolve_vlm_event`.
- `identity crops`: no implemented identity crop trigger found. Current identity references are limited to track metadata/TODO-level pipeline context.
- `DatasetExporter hard negatives`: confirmed analogous class/category bug exists in `src/oko/training/dataset_exporter.py`.

## Evidence Command

Read-only command:

```powershell
$env:PYTHONPATH='src'; @'
from oko.events.builder import _class_is_animal
from oko.training.dataset_exporter import _class_id

def old_match(event_type, class_name):
    return event_type.startswith(class_name)

print('old_match_animal_cat=', old_match('animal_entered_zone', 'cat'))
print('old_match_person_person=', old_match('person_entered_zone', 'person'))
print('current_class_is_animal_cat=', _class_is_animal('cat'))
print('dataset_exporter_class_id_cat=', _class_id('cat'))
print('dataset_exporter_class_id_dog=', _class_id('dog'))
print('dataset_exporter_class_id_animal=', _class_id('animal'))
print('dataset_exporter_class_id_person=', _class_id('person'))
'@ | python -
```

Output:

```text
old_match_animal_cat= False
old_match_person_person= True
current_class_is_animal_cat= True
dataset_exporter_class_id_cat= 0
dataset_exporter_class_id_dog= 0
dataset_exporter_class_id_animal= 1
dataset_exporter_class_id_person= 0
```

Interpretation:

- The old code would miss `animal_entered_zone` + `cat`.
- The old code still matched `person_entered_zone` + `person`.
- The live fix's animal classifier recognizes `cat`.
- `DatasetExporter._class_id("cat")` and `_class_id("dog")` currently return `0`, which is the `person` YOLO class id, instead of `1`, the `animal` id.

## Required OKO-Scoped Patch

Run the next worker with writable root `C:\Users\rafie\bridge-projects\oko`. Restrict `git add` to this touch-set only:

- `src/oko/events/builder.py`
- `src/oko/events/__init__.py`
- `src/oko/pipeline/live.py`
- `src/oko/training/dataset_exporter.py`
- `tests/test_crop_animal_regression.py`
- likely `tests/test_dataset_exporter.py` if it exists or is appropriate for exporter coverage

Required code changes:

- Rename `_class_is_animal` to public `class_is_animal`.
- Keep `_class_is_animal = class_is_animal` as a compatibility alias only if existing tests/imports need it.
- Export `class_is_animal` from `oko.events.__init__` if that package uses explicit exports.
- Update `LivePipeline` to import/use `class_is_animal`.
- Update `DatasetExporter._class_id()` so specific animal classes (`cat`, `dog`, etc.) map to class id `1`, not default `0`.

Required tests:

- Add a regression test for delayed `animal_entered_zone` with detection `class_name="cat"`:
  - proves old matcher `event_type.startswith(class_name)` is false;
  - proves `pending.trigger_detection` is not `None`;
  - proves `CropCollector.collect()` writes crop file and `index.jsonl`;
  - proves JSONL has `class_name == "cat"`.
- Add analogous `person_entered_zone` + `class_name="person"` test.
- Add/exporter coverage that `cat` and `dog` map to YOLO animal id `1`, while `person` remains `0`.

Required verification in OKO:

```powershell
python -m pytest tests/test_crop_animal_regression.py -v
python -m pytest tests/ -v --tb=short
```

Note: OKO working tree was already dirty before this task, including runtime artifacts under `runs/`. Do not stage unrelated existing files.
