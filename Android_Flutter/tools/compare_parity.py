"""Membandingkan mask hasil Android/Flutter vs mask referensi Python (uji paritas P1 & P2).

Target PRD: Dice antar-mask >= 0,99.

Cara pakai:
    ..\\backend\\.venv\\Scripts\\python.exe tools\\compare_parity.py
    ..\\backend\\.venv\\Scripts\\python.exe tools\\compare_parity.py --device-dir test\\parity\\device_out
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ANDROID_DIR = Path(__file__).resolve().parent.parent
REFS_DIR = ANDROID_DIR / "test" / "parity" / "refs"
DEFAULT_DEVICE_DIR = ANDROID_DIR / "test" / "parity" / "device_out"


def dice_binary(a: np.ndarray, b: np.ndarray, threshold: int = 128) -> float:
    ba = a >= threshold
    bb = b >= threshold
    sa = int(ba.sum())
    sb = int(bb.sum())
    if sa == 0 and sb == 0:
        return 1.0
    inter = int((ba & bb).sum())
    return (2.0 * inter) / (sa + sb)


def soft_dice(a: np.ndarray, b: np.ndarray) -> float:
    fa = a.astype(np.float64) / 255.0
    fb = b.astype(np.float64) / 255.0
    denom = float(fa.sum() + fb.sum())
    if denom == 0.0:
        return 1.0
    return float((2.0 * (fa * fb).sum()) / denom)


def mad_01(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.abs(a.astype(np.float64) - b.astype(np.float64)).mean() / 255.0)


def load_gray(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("L"), dtype=np.uint8)


def main() -> int:
    parser = argparse.ArgumentParser(description="Uji paritas mask Android vs Python (P1/P2).")
    parser.add_argument("--refs-dir", type=Path, default=REFS_DIR)
    parser.add_argument("--device-dir", type=Path, default=DEFAULT_DEVICE_DIR)
    parser.add_argument("--target-dice", type=float, default=0.99)
    args = parser.parse_args()

    manifest_path = args.refs_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"ERROR: manifest referensi belum ada: {manifest_path}. Jalankan generate_parity_refs.py dulu.", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    items = manifest.get("items", [])
    if not items:
        print("ERROR: manifest kosong.", file=sys.stderr)
        return 1

    print(f"Membandingkan {len(items)} foto (ref={args.refs_dir} vs device={args.device_dir})\n")
    print(f"{'Foto':38s} | {'Size':9s} | {'Dice384':7s} | {'DiceFull':8s} | {'DiceAlph':8s} | {'MADAlph':7s} | Status")
    print("-" * 102)

    d384_list, dfull_list, dalpha_list, mad_list = [], [], [], []
    missing = 0
    failed = 0

    for it in items:
        stem = it["stem"]
        ref_384 = args.refs_dir / f"{stem}_mask384.png"
        ref_full = args.refs_dir / f"{stem}_mask_full.png"
        ref_alpha = args.refs_dir / f"{stem}_alpha.png"

        dev_384 = args.device_dir / f"{stem}_mask384.png"
        dev_full = args.device_dir / f"{stem}_mask_full.png"
        dev_alpha = args.device_dir / f"{stem}_alpha.png"

        if not (dev_384.exists() and dev_full.exists() and dev_alpha.exists()):
            print(f"{it['file'][:38]:38s} | {'-':9s} | MISSING output perangkat di {args.device_dir}")
            missing += 1
            continue

        r384, d384 = load_gray(ref_384), load_gray(dev_384)
        rfull, dfull = load_gray(ref_full), load_gray(dev_full)
        ralpha, dalpha = load_gray(ref_alpha), load_gray(dev_alpha)

        if rfull.shape != dfull.shape or ralpha.shape != dalpha.shape:
            print(f"{it['file'][:38]:38s} | SHAPE MISMATCH ref={rfull.shape} vs dev={dfull.shape}")
            failed += 1
            continue

        s384 = dice_binary(r384, d384)
        sfull = dice_binary(rfull, dfull)
        salpha = dice_binary(ralpha, dalpha)
        mad = mad_01(ralpha, dalpha)

        d384_list.append(s384)
        dfull_list.append(sfull)
        dalpha_list.append(salpha)
        mad_list.append(mad)

        ok = min(s384, sfull, salpha) >= args.target_dice
        if not ok:
            failed += 1
        status = "LULUS" if ok else "GAGAL"
        size_str = f"{it['width']}x{it['height']}"
        print(f"{it['file'][:38]:38s} | {size_str:9s} | {s384:7.5f} | {sfull:8.5f} | {salpha:8.5f} | {mad:7.5f} | {status}")

    print("-" * 102)
    if dalpha_list:
        mean_384 = float(np.mean(d384_list))
        mean_full = float(np.mean(dfull_list))
        mean_alpha = float(np.mean(dalpha_list))
        min_alpha = float(np.min(dalpha_list))
        mean_mad = float(np.mean(mad_list))
        print(
            f"RATA-RATA ({len(dalpha_list)} foto): "
            f"Dice384={mean_384:.5f} | DiceFull={mean_full:.5f} | DiceAlpha={mean_alpha:.5f} "
            f"(min={min_alpha:.5f}) | MAD={mean_mad:.5f}"
        )
        timings_path = args.device_dir / "timings.json"
        if timings_path.exists():
            t = json.loads(timings_path.read_text(encoding="utf-8"))
            print(f"Ringkasan waktu perangkat: {json.dumps(t.get('summary', {}), ensure_ascii=False)}")

    if missing > 0 or failed > 0:
        print(f"\nHASIL: BELUM LULUS (missing={missing}, gagal<{args.target_dice}={failed})")
        return 1

    print(f"\nHASIL: LULUS PARITAS (semua foto Dice >= {args.target_dice})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
