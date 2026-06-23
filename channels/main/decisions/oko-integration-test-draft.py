"""End-to-end integration smoke for the autotrain pipeline (no real GPU required)."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

from oko.training.crop_collector import CropRecord
from oko.training.dataset_exporter import DatasetExporter
from oko.training.eval_harness import EvalHarness
from oko.training.finetune_gate import FinetuneGate


def _make_record(idx: int, class_name: str, camera_id: str = "cam0") -> CropRecord:
    return CropRecord(
        camera_id=camera_id,
        frame_id=idx,
        timestamp=float(idx),
        class_name=class_name,
        confidence=0.9,
        bbox_abs=(idx * 10, idx * 5, 50, 40),
        cell=(idx % 12, idx % 16),
        vlm_description=f"desc-{idx}",
        crop_path=f"/tmp/crop-{idx}.jpg",
        frame_w=640,
        frame_h=480,
    )


def _write_index(labels_root: Path, records: list[CropRecord]) -> None:
    by_camera: dict[str, list[CropRecord]] = {}
    for r in records:
        by_camera.setdefault(r.camera_id, []).append(r)
    for camera_id, recs in by_camera.items():
        cam_dir = labels_root / camera_id
        cam_dir.mkdir(parents=True, exist_ok=True)
        with (cam_dir / "index.jsonl").open("w", encoding="utf-8") as f:
            for r in recs:
                f.write(json.dumps({
                    "camera_id": r.camera_id,
                    "frame_id": r.frame_id,
                    "timestamp": r.timestamp,
                    "class_name": r.class_name,
                    "confidence": r.confidence,
                    "bbox_abs": list(r.bbox_abs),
                    "cell": list(r.cell),
                    "vlm_description": r.vlm_description,
                    "crop_path": r.crop_path,
                }) + "\n")


def test_autotrain_integration_smoke(tmp_path: Path) -> None:
    # 1. Create 12 mock CropRecord (8 person + 4 chair)
    crops: list[CropRecord] = (
        [_make_record(i, "person") for i in range(8)]
        + [_make_record(i + 8, "chair") for i in range(4)]
    )
    assert len(crops) == 12  # assertion 1

    # Write index.jsonl so FinetuneGate.check_readiness can count samples
    tmp_labels_root = tmp_path / "labels"
    _write_index(tmp_labels_root, crops)

    # 2. EvalHarness.freeze_held_out → held-out created
    eval_root = tmp_path / "eval"
    harness = EvalHarness(tmp_labels_root, eval_root)
    train_crops, held_out = harness.freeze_held_out(crops, fraction=0.2, seed=42)

    held_out_path = eval_root / "held_out.jsonl"
    assert held_out_path.exists()  # assertion 2
    assert len(held_out) >= 1      # assertion 3

    # 3. Repeat freeze_held_out → same held-out (idempotency)
    content_before = held_out_path.read_text(encoding="utf-8")
    train_crops2, held_out2 = harness.freeze_held_out(crops, fraction=0.2, seed=42)
    content_after = held_out_path.read_text(encoding="utf-8")

    assert [r.crop_path for r in held_out] == [r.crop_path for r in held_out2]  # assertion 4

    # 4. DatasetExporter.export(train_crops, tmp_output) → data.yaml exists
    tmp_output = tmp_path / "dataset"
    DatasetExporter().export(train_crops, tmp_output)

    data_yaml_path = tmp_output / "data.yaml"
    assert data_yaml_path.exists()  # assertion 5

    # 5. FinetuneGate.check_readiness(tmp_labels_root, min_samples=100) → False (12 < 100)
    ready = FinetuneGate(config={}).check_readiness(tmp_labels_root, min_samples=100)
    assert ready is False  # assertion 6

    # 6. data.yaml nc=3, images/train/ and labels/train/ exist
    data = yaml.safe_load(data_yaml_path.read_text(encoding="utf-8"))
    assert data["nc"] == 3  # assertion 7
    assert (tmp_output / "images" / "train").is_dir()  # assertion 8
    assert (tmp_output / "labels" / "train").is_dir()  # assertion 9

    # 7. held_out.jsonl not changed after second freeze
    assert content_after == content_before  # assertion 10

    # Final: run whole suite via subprocess (guard against recursive invocation)
    if os.getenv("_OKO_INTEGRATION_SUBPROCESS"):
        return
    tests_dir = Path(__file__).resolve().parent
    env = {**os.environ, "_OKO_INTEGRATION_SUBPROCESS": "1"}
    result = subprocess.run(
        [sys.executable, "-m", "pytest", str(tests_dir), "-q", "--tb=short"],
        cwd=str(tests_dir.parent),
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, (  # assertion 11
        f"pytest tests/ -q returned {result.returncode}:\n"
        f"{result.stdout[-3000:]}\n{result.stderr[-1000:]}"
    )
