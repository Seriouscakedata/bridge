# Chapter 1 Implementation Spec — OKO Scene Memory (SceneModel/SceneStore scaffold)

**Target repo:** `C:\Users\rafie\bridge-projects\oko`
**Files to create:** `src/oko/memory/scene.py`, `tests/test_scene_memory.py`
**Commit message:** `feat(scene-memory): Chapter 1 — SceneModel/SceneStore scaffold + unit tests`

---

## Module constants (top of file)

```python
SCHEMA_VERSION: int = 1
DEFAULT_WARMUP_FRAMES: int = 3600   # ~2 min at 30fps
GRID_ROWS: int = 12
GRID_COLS: int = 16
EMA_ALPHA: float = 0.05
```

---

## Imports

```python
from __future__ import annotations
import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
import numpy as np
```

---

## `_iou(a, b) -> float` (module-level)

Compute IoU of two normalized `[x1, y1, x2, y2]` bboxes.

```python
def _iou(a: tuple, b: tuple) -> float:
    ix1 = max(a[0], b[0]); iy1 = max(a[1], b[1])
    ix2 = min(a[2], b[2]); iy2 = min(a[3], b[3])
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter == 0.0:
        return 0.0
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0
```

---

## `@dataclass BackgroundPlate`

Fields:
- `grid: np.ndarray` — shape `(GRID_ROWS, GRID_COLS, 3)`, dtype `float32` — EMA of pixel RGB per cell
- `hit_count: np.ndarray` — shape `(GRID_ROWS, GRID_COLS)`, dtype `int32` — how many updates per cell

Methods:
- `@classmethod create() -> BackgroundPlate` — returns zero-initialized plate
- `def update(self, row: int, col: int, pixel_rgb: tuple[float, float, float], moving: bool) -> None`
  — if `moving=True`: do nothing (skip update, motion gate)
  — if `moving=False`: apply EMA: `self.grid[row, col] = (1 - EMA_ALPHA) * self.grid[row, col] + EMA_ALPHA * np.array(pixel_rgb, dtype=np.float32)`; increment `self.hit_count[row, col]`

---

## `@dataclass SpatialGrid`

Records which YOLO classes are "normal" per cell via confidence-weighted accumulation.

Fields:
- `conf_sum: dict[tuple[int,int], dict[str, float]]` — accumulated confidence per (row,col,class)
- `hit_count: dict[tuple[int,int], int]` — total observations per cell

Methods:
- `@classmethod create() -> SpatialGrid`
- `def observe(self, row: int, col: int, class_name: str, conf: float) -> None`
  — add `conf` to `conf_sum[(row,col)][class_name]`, increment `hit_count[(row,col)]`
- `def normal_classes(self, row: int, col: int, *, min_conf_ratio: float = 0.1) -> set[str]`
  — for each class in cell, compute `class_conf_sum / total_conf_sum_in_cell`; return classes where ratio >= `min_conf_ratio`

---

## `@dataclass FurnitureEntry`

Fields: `class_name: str`, `bbox_norm: tuple[float,float,float,float]`, `hit_count: int = 0`, `promoted: bool = False`

---

## `@dataclass FurnitureRegistry`

Signature-keyed furniture store. Keys entries by `class_name + bbox_norm` (rounded to 2dp).

Fields:
- `entries: dict[str, FurnitureEntry] = field(default_factory=dict)`
- `promotion_threshold: int = DEFAULT_WARMUP_FRAMES // 4`
- `max_size: int = 256`

Methods:
- `@staticmethod _sig(class_name: str, bbox_norm: tuple) -> str`
  — returns `f"{class_name}:{bbox_norm[0]:.2f},{bbox_norm[1]:.2f},{bbox_norm[2]:.2f},{bbox_norm[3]:.2f}"`
- `def observe(self, class_name: str, bbox_norm: tuple, *, iou_threshold: float = 0.6) -> str`
  — search existing entries for same `class_name` with IoU >= `iou_threshold`
  — if found: increment `hit_count`, set `promoted=True` if `hit_count >= promotion_threshold`; return its sig
  — if NOT found AND `len(entries) >= max_size`: evict entry with lowest `hit_count` among non-promoted (if all are promoted, evict lowest `hit_count` overall)
  — create new `FurnitureEntry(class_name, bbox_norm, hit_count=1)`, key = `_sig(class_name, bbox_norm)`, add to entries; return sig
- `def is_promoted(self, sig: str) -> bool` — return `entries[sig].promoted` if exists, else `False`
- `def promoted_entries(self) -> list[FurnitureEntry]` — return entries where `promoted=True`

---

## `@dataclass SceneModel`

Pure state holder — NO I/O in update paths.

Fields:
- `camera_id: str`
- `plate: BackgroundPlate`
- `grid: SpatialGrid`
- `furniture: FurnitureRegistry`
- `frame_count: int = 0`
- `schema_version: int = SCHEMA_VERSION`
- `warmup_frames: int = DEFAULT_WARMUP_FRAMES`

Methods:
- `@property def is_ready(self) -> bool` — `return self.frame_count >= self.warmup_frames`
- `def tick(self) -> None` — `self.frame_count += 1`
- `def to_dict(self) -> dict` — returns `{schema_version, camera_id, frame_count, warmup_frames}`
- `@classmethod def from_dict(cls, d: dict) -> SceneModel` — tolerate missing fields with defaults; creates new empty plate/grid/furniture (they are loaded separately by SceneStore)

---

## `class SceneStore`

Per-camera lifecycle + persistence. NOT a dataclass (has mutable internal state).

Fields (set in `__init__`):
- `root: Path`
- `_models: dict[str, SceneModel] = {}`
- `_save_throttle: dict[str, float] = {}`
- `save_interval_sec: float = 30.0`

Methods:
- `def _camera_dir(self, camera_id: str) -> Path` — `return self.root / camera_id`
- `def get_or_create(self, camera_id: str, **kwargs) -> SceneModel`
  — if already in `_models`: return it
  — try `load(camera_id)` — if returns non-None: cache in `_models`, return
  — else: create new `SceneModel(camera_id=camera_id, plate=BackgroundPlate.create(), grid=SpatialGrid.create(), furniture=FurnitureRegistry(), **kwargs)`, cache, return
- `def save(self, camera_id: str, *, force: bool = False) -> None`
  — throttle check: if not force AND `time.monotonic() - _save_throttle.get(camera_id, 0.0) < save_interval_sec`: return
  — update `_save_throttle[camera_id] = time.monotonic()`
  — model = `_models.get(camera_id)`; if None: return
  — d = `_camera_dir(camera_id)`; `d.mkdir(parents=True, exist_ok=True)`
  — ATOMIC writes via temp-then-rename:
    - `plate_grid.npy` ← `model.plate.grid`
    - `plate_hits.npy` ← `model.plate.hit_count`
    - `grid.json` ← `{schema_version, conf_sum: {"{r},{c}": {class: val, ...}, ...}, hit_count: {"{r},{c}": n, ...}}`
    - `furniture.json` ← `{schema_version, entries: {sig: {class_name, bbox_norm, hit_count, promoted}}, promotion_threshold, max_size}`
    - `meta.json` ← `model.to_dict()`
  — For npy: `np.save(tmp_path, arr); tmp_path.replace(final_path)` (use `.tmp` suffix)
  — For json: `tmp.write_text(json.dumps(data), encoding='utf-8'); tmp.replace(final)`
- `def load(self, camera_id: str) -> SceneModel | None`
  — try: read `meta.json`, `from_dict`, then populate plate/grid/furniture from `_load_*`
  — on any exception: `logging.warning(...)`, return None
  — if meta.json doesn't exist: return None
- `def _load_plate(self, d: Path) -> BackgroundPlate` — try load npy files, on failure return `BackgroundPlate.create()`
- `def _load_grid(self, d: Path) -> SpatialGrid` — try load grid.json, parse keys back to tuples, on failure return `SpatialGrid.create()`
- `def _load_furniture(self, d: Path) -> FurnitureRegistry` — try load furniture.json, reconstruct entries, on failure return `FurnitureRegistry()`

---

## Tests: `tests/test_scene_memory.py`

Use `pytest` with `tmp_path` fixture. Import: `from oko.memory.scene import SceneModel, SceneStore, BackgroundPlate, SpatialGrid, FurnitureRegistry`.

```python
# 1. test_scene_store_create_and_get
# SceneStore(root=tmp_path) -> get_or_create("cam1") -> assert model.camera_id == "cam1"

# 2. test_scene_store_save_and_reload
# store=SceneStore(root=tmp_path); m=get_or_create("cam1"); tick 10 times
# save("cam1", force=True)
# store2=SceneStore(root=tmp_path); m2=get_or_create("cam1"); assert m2.frame_count == 10

# 3. test_atomic_save_no_partial_write
# save(force=True); assert all 5 files exist: meta.json, grid.json, furniture.json, plate_grid.npy, plate_hits.npy

# 4. test_tolerant_load_missing_files
# camera_dir = tmp_path/"cam_empty"; camera_dir.mkdir()
# SceneStore(root=tmp_path).load("cam_empty") == None  # no exception

# 5. test_tolerant_load_corrupt_json
# camera_dir = tmp_path/"cam_bad"; camera_dir.mkdir()
# (camera_dir/"meta.json").write_text("NOT JSON", encoding="utf-8")
# SceneStore(root=tmp_path).load("cam_bad") == None  # no exception

# 6. test_warmup_flag
# m = SceneModel(camera_id="c", plate=..., grid=..., furniture=..., warmup_frames=5)
# tick 4 times -> assert not m.is_ready
# tick 1 more -> assert m.is_ready

# 7. test_furniture_registry_promotion
# reg = FurnitureRegistry(promotion_threshold=4)
# bbox = (0.1, 0.1, 0.3, 0.3)
# observe 5 times with same class+bbox (IoU=1.0)
# assert reg.is_promoted(sig) == True

# 8. test_furniture_registry_iou_merge
# reg = FurnitureRegistry()
# observe ("chair", (0.10, 0.10, 0.30, 0.30))
# observe ("chair", (0.11, 0.11, 0.31, 0.31))  # IoU > 0.6
# assert len(reg.entries) == 1
# assert list(reg.entries.values())[0].hit_count == 2

# 9. test_background_plate_no_update_on_moving
# plate = BackgroundPlate.create()
# plate.update(0, 0, (255.0, 128.0, 64.0), moving=True)
# assert plate.hit_count[0, 0] == 0

# 10. test_background_plate_ema_update
# plate = BackgroundPlate.create()
# plate.update(0, 0, (255.0, 128.0, 64.0), moving=False)
# assert plate.hit_count[0, 0] == 1
# assert plate.grid[0, 0].sum() > 0

# 11. test_spatial_grid_normal_classes
# grid = SpatialGrid.create()
# for _ in range(5): grid.observe(0, 0, "person", 0.9)
# grid.observe(0, 0, "cat", 0.1)
# assert "person" in grid.normal_classes(0, 0)

# 12. test_scene_store_throttle
# store = SceneStore(root=tmp_path, save_interval_sec=9999.0)
# m = store.get_or_create("cam1"); store.save("cam1", force=True)  # first write
# meta = (tmp_path/"cam1"/"meta.json")
# mtime1 = meta.stat().st_mtime
# store.save("cam1")  # throttled, should NOT write
# mtime2 = meta.stat().st_mtime
# assert mtime1 == mtime2
```

---

## Verification steps (run in `C:\Users\rafie\bridge-projects\oko`):

```
python -m pytest tests/test_scene_memory.py -v   # must be all green
python -m pytest                                  # full suite, no regressions
python -c "from oko.memory.scene import SceneModel, SceneStore; print('import ok')"
```

---

## Git commit

```
git add src/oko/memory/scene.py tests/test_scene_memory.py
git commit -m "feat(scene-memory): Chapter 1 — SceneModel/SceneStore scaffold + unit tests"
```

Then write `[[VERIFIED: chapter-1 | pytest output here]]`.
