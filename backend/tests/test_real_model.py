"""Uji model asli di backend/models (dilewati bila file .tflite belum dipasang)."""
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from app import config
from app.ml import Engine

MODELS = Path(__file__).resolve().parent.parent / "models"
TFLITE = MODELS / "pichanter_bg_fp16.tflite"

pytestmark = pytest.mark.skipif(not TFLITE.exists(), reason="model asli belum dipasang di backend/models")


def test_real_tflite_model_loads_and_predicts(monkeypatch):
    monkeypatch.setattr(config, "MODEL_DIR", MODELS)
    eng = Engine()
    eng.load()
    assert eng.ready and not eng.placeholder
    assert eng.model_version == config.MODEL_VERSION

    img = Image.new("RGB", (640, 480), (120, 160, 200))
    res = eng.process(img)
    assert res.cutout.size == (640, 480) and res.cutout.mode == "RGBA"
    mask = np.asarray(res.mask)
    assert mask.shape == (480, 640) and mask.dtype == np.uint8
    assert res.inference_ms > 0
