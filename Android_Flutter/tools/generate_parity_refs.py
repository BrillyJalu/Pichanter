"""Menghasilkan mask referensi Python (pichanter_bg.py + model fp16 v2) untuk uji paritas P1.

Cara pakai (dari folder Android_Flutter/ atau root proyek):
    ..\\backend\\.venv\\Scripts\\python.exe tools\\generate_parity_refs.py

Foto uji dibaca dari:  Android_Flutter/test/parity/photos/
Hasil referensi:       Android_Flutter/test/parity/refs/
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps

ANDROID_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = ANDROID_DIR.parent
sys.path.insert(0, str(PROJECT_ROOT / "backend" / "app"))

from pichanter_bg import BackgroundRemover  # noqa: E402

PHOTOS_DIR = ANDROID_DIR / "test" / "parity" / "photos"
REFS_DIR = ANDROID_DIR / "test" / "parity" / "refs"
MODEL_PATH = ANDROID_DIR / "assets" / "models" / "pichanter_bg_fp16.tflite"
ALLOWED_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def main() -> int:
    if not MODEL_PATH.exists():
        print(f"ERROR: Model tidak ditemukan: {MODEL_PATH}", file=sys.stderr)
        return 1

    PHOTOS_DIR.mkdir(parents=True, exist_ok=True)
    REFS_DIR.mkdir(parents=True, exist_ok=True)

    photos = sorted(p for p in PHOTOS_DIR.iterdir() if p.is_file() and p.suffix.lower() in ALLOWED_EXTS)
    if not photos:
        print(f"Belum ada foto uji di {PHOTOS_DIR}. Salin foto JPG/PNG/WEBP ke folder tersebut.")
        return 1

    remover = BackgroundRemover(MODEL_PATH, num_threads=4)
    print(f"Model dimuat: {MODEL_PATH.name} (input {remover.size}x{remover.size}), {len(photos)} foto uji")

    manifest = {
        "model": MODEL_PATH.name,
        "input_size": remover.size,
        "feather": 1.5,
        "threshold": 0.5,
        "items": [],
    }

    for photo in photos:
        t0 = time.perf_counter()
        with Image.open(photo) as img:
            rgb = ImageOps.exif_transpose(img).convert("RGB")
            x = np.asarray(rgb.resize((remover.size, remover.size), Image.BILINEAR), dtype=np.float32)[None]

            t_inf0 = time.perf_counter()
            raw = np.asarray(remover._predict(x))[0, ..., 0]
            infer_ms = (time.perf_counter() - t_inf0) * 1000.0

            mask_small_u8 = (np.clip(raw, 0.0, 1.0) * 255.0).astype(np.uint8)
            mask_small_img = Image.fromarray(mask_small_u8, mode="L")
            mask_full_img = mask_small_img.resize(rgb.size, Image.BILINEAR)
            alpha_img = mask_full_img.filter(ImageFilter.GaussianBlur(1.5))

            stem = photo.stem
            mask_small_img.save(REFS_DIR / f"{stem}_mask384.png")
            mask_full_img.save(REFS_DIR / f"{stem}_mask_full.png")
            alpha_img.save(REFS_DIR / f"{stem}_alpha.png")

            fg_pct = float((mask_small_u8 >= 128).mean() * 100.0)
            total_ms = (time.perf_counter() - t0) * 1000.0

            manifest["items"].append({
                "file": photo.name,
                "stem": stem,
                "width": rgb.width,
                "height": rgb.height,
                "fg_pct": round(fg_pct, 2),
                "python_infer_ms": round(infer_ms, 2),
                "python_total_ms": round(total_ms, 2),
            })
            print(f"  [OK] {photo.name:42s} {rgb.width}x{rgb.height} | fg={fg_pct:5.1f}% | infer={infer_ms:5.1f}ms")

    (REFS_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"\nReferensi disimpan di: {REFS_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
