"""Memuat model dan menjalankan hapus background.

Urutan:
1. models/<MODEL_FILE> (.tflite hasil notebook) -> model asli (server Linux / Docker).
2. models/<ONNX_FILE> via onnxruntime (opsional) -> model asli yang sama, bila runtime TFLite
   tidak bisa dipasang di suatu platform.
3. Bila keduanya gagal:
   - ALLOW_PLACEHOLDER=true  -> model SEMENTARA (heuristik, bukan AI) agar alur end-to-end bisa diuji.
   - ALLOW_PLACEHOLDER=false -> server menolak permintaan dengan HTTP 503.
"""
import logging
import threading
import time
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageFilter

from . import config
from .pichanter_bg import BackgroundRemover

log = logging.getLogger("pichanter.ml")

PLACEHOLDER_VERSION = "placeholder-v0"


def placeholder_predict(x: np.ndarray) -> np.ndarray:
    """Pengganti model sementara: X[1,S,S,3] (0-255) -> mask[1,S,S,1] (0-1).

    Heuristik sederhana: warna background ditaksir dari piksel tepi gambar, piksel yang
    warnanya jauh dari background dianggap orang, lalu dibatasi bentuk elips setengah badan.
    Cukup untuk menguji UI; kualitasnya TIDAK mewakili model U-Net.
    """
    img = x[0].astype(np.float32)
    s = img.shape[0]
    border = np.concatenate([img[0], img[-1], img[:, 0], img[:, -1]])
    bg = np.median(border, axis=0)
    dist = np.linalg.norm(img - bg, axis=-1) / (255.0 * np.sqrt(3))
    color_prob = 1.0 / (1.0 + np.exp(-(dist - 0.12) * 30))

    yy, xx = np.mgrid[0:s, 0:s] / (s - 1)
    ellipse = ((xx - 0.5) / 0.42) ** 2 + ((yy - 0.62) / 0.55) ** 2
    prior = 1.0 / (1.0 + np.exp((ellipse - 1.0) * 12))

    m = color_prob * prior
    return m[None, ..., None].astype(np.float32)


def onnx_predictor(path):
    """(fungsi prediksi X[1,S,S,3] (0-255) -> mask[1,S,S,1], S) dari model ONNX (input/output sama dengan TFLite)."""
    import onnxruntime as ort

    opts = ort.SessionOptions()
    opts.intra_op_num_threads = config.MODEL_THREADS
    sess = ort.InferenceSession(str(path), sess_options=opts, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    shape = list(inp.shape[1:])
    if len(shape) != 3 or shape[2] != 3 or not isinstance(shape[0], int) or shape[0] != shape[1]:
        raise ValueError(f"bentuk input ONNX tidak sesuai: {inp.shape}")
    name = inp.name
    return (lambda x: sess.run(None, {name: x.astype(np.float32)})[0]), shape[0]


@dataclass
class Result:
    rgb: Image.Image          # foto asli setelah koreksi orientasi EXIF
    mask: Image.Image         # probabilitas orang (L, 0-255), resolusi asli
    cutout: Image.Image       # RGBA, background transparan
    inference_ms: float       # waktu model saja


class Engine:
    def __init__(self):
        self.remover: BackgroundRemover | None = None
        self.model_version: str | None = None
        self.placeholder = False
        self.error: str | None = None
        self._lock = threading.Lock()  # interpreter TFLite tidak thread-safe

    @property
    def ready(self) -> bool:
        return self.remover is not None

    def load(self):
        errors = []
        path = config.MODEL_DIR / config.MODEL_FILE
        try:
            if not path.exists():
                raise FileNotFoundError(f"file model tidak ditemukan: {path}")
            self.remover = BackgroundRemover(path, num_threads=config.MODEL_THREADS)
            self.model_version, self.placeholder, self.error = config.MODEL_VERSION, False, None
            log.info("Model dimuat: %s (%s)", path.name, self.model_version)
            return
        except Exception as e:  # noqa: BLE001 - pesan galat diteruskan ke /api/health
            errors.append(f"TFLite: {type(e).__name__}: {e}")

        onnx_path = config.MODEL_DIR / config.ONNX_FILE
        try:
            if not onnx_path.exists():
                raise FileNotFoundError(f"file ONNX tidak ditemukan: {onnx_path}")
            predict_fn, size = onnx_predictor(onnx_path)
            self.remover = BackgroundRemover(predict_fn=predict_fn, input_size=size)
            self.model_version, self.placeholder, self.error = config.ONNX_VERSION, False, None
            log.info("Runtime TFLite tidak tersedia, model ONNX dimuat: %s (%s)", onnx_path.name, self.model_version)
            return
        except Exception as e:  # noqa: BLE001
            errors.append(f"ONNX: {type(e).__name__}: {e}")

        self.error = " | ".join(errors)
        if config.ALLOW_PLACEHOLDER:
            self.remover = BackgroundRemover(predict_fn=placeholder_predict, input_size=256)
            self.model_version, self.placeholder = PLACEHOLDER_VERSION, True
            log.warning("Model asli belum tersedia (%s) -> memakai MODEL SEMENTARA.", self.error)
        else:
            self.remover, self.model_version = None, None
            log.error("Model gagal dimuat dan ALLOW_PLACEHOLDER=false: %s", self.error)

    def process(self, img: Image.Image, feather: float = config.FEATHER) -> Result:
        if not self.ready:
            raise RuntimeError("model belum dimuat")
        timing = {}
        predict = self.remover._predict

        def timed(x):
            t = time.perf_counter()
            y = predict(x)
            timing["ms"] = (time.perf_counter() - t) * 1000
            return y

        with self._lock:
            self.remover._predict = timed
            try:
                rgb, alpha = self.remover.predict_mask(img)
            finally:
                self.remover._predict = predict

        # Sama dengan BackgroundRemover.remove_background, tapi mask mentah ikut disimpan.
        mask = Image.fromarray((alpha * 255).astype(np.uint8), mode="L")
        a = mask.filter(ImageFilter.GaussianBlur(feather)) if feather > 0 else mask
        cutout = rgb.copy()
        cutout.putalpha(a)
        return Result(rgb=rgb, mask=mask, cutout=cutout, inference_ms=timing.get("ms", 0.0))


engine = Engine()
