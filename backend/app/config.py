"""Konfigurasi dari environment / file .env (lihat .env.example)."""
import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent  # folder backend/
load_dotenv(BASE_DIR / ".env")


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


def _path(name: str, default: str) -> Path:
    p = Path(os.getenv(name, default))
    return p if p.is_absolute() else BASE_DIR / p


MODEL_DIR = _path("MODEL_DIR", "models")
MODEL_FILE = os.getenv("MODEL_FILE", "pichanter_bg_fp16.tflite")
MODEL_VERSION = os.getenv("MODEL_VERSION", "unet-mnv3l-384-fp16-v2")
# Cadangan bila runtime TFLite tidak tersedia (mis. laptop Windows): model ONNX yang sama via onnxruntime.
ONNX_FILE = os.getenv("ONNX_FILE", "pichanter_bg.onnx")
ONNX_VERSION = os.getenv("ONNX_VERSION", "unet-mnv3l-384-onnx-v2")
MODEL_THREADS = int(os.getenv("MODEL_THREADS", "4"))
# Jika file model belum ada / gagal dimuat: true = pakai model sementara, false = tolak permintaan (503).
ALLOW_PLACEHOLDER = _bool("ALLOW_PLACEHOLDER", True)

STORAGE_DIR = _path("STORAGE_DIR", "storage")
DB_PATH = _path("DB_PATH", "storage/pichanter.db")
RETENTION_HOURS = float(os.getenv("RETENTION_HOURS", "24"))
CLEANUP_INTERVAL_S = int(os.getenv("CLEANUP_INTERVAL_S", "600"))

MAX_UPLOAD_MB = float(os.getenv("MAX_UPLOAD_MB", "25"))
# Pengaman "decompression bomb": Pillow menolak gambar > 2 x MAX_PIXELS (bawaan 240 MP, cukup untuk kamera 200 MP).
MAX_PIXELS = int(os.getenv("MAX_PIXELS", str(120_000_000)))
# Foto lebih besar dari ini (sisi terpanjang) diperkecil dulu agar hemat memori server.
PROCESS_MAX_SIDE = int(os.getenv("PROCESS_MAX_SIDE", "6000"))
FEATHER = float(os.getenv("FEATHER", "1.5"))

CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",") if o.strip()]

# File APK Android untuk menu "Unduh Aplikasi" (diisi otomatis oleh `npm run apk` di android-app/).
DOWNLOAD_DIR = _path("DOWNLOAD_DIR", "downloads")
APK_FILE = os.getenv("APK_FILE", "pichanter.apk")

# Folder frontend (diisi pada tahap berikutnya); disajikan bila ada.
MOBILE_DIR = _path("MOBILE_DIR", "../mobile")
WEB_DIR = _path("WEB_DIR", "../web")
