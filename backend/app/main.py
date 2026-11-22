"""Pichanter API - satu backend untuk PWA/APK mobile dan dashboard web.

Jalankan (dari folder backend/):  uvicorn app.main:app --reload --port 8000
Dokumentasi otomatis: http://localhost:8000/docs
"""
import asyncio
import io
import json
import logging
import re
import shutil
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageOps, UnidentifiedImageError

from . import config, db
from .ml import engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("pichanter.api")

Image.MAX_IMAGE_PIXELS = config.MAX_PIXELS
try:  # foto HEIC/HEIF (bawaan banyak HP Samsung, Xiaomi, dan iPhone)
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:  # pragma: no cover - tanpa pillow-heif, HEIC ditolak dengan 415
    log.warning("pillow-heif tidak terpasang; foto HEIC/HEIF tidak didukung")

# Disimpan apa adanya (bisa langsung ditampilkan browser). MPO = JPEG multi-gambar dari kamera HP.
PASSTHROUGH_FORMATS = {"JPEG": "jpg", "MPO": "jpg", "PNG": "png", "WEBP": "webp"}
# Dibaca lalu disimpan ulang sebagai JPG (atau PNG bila transparan) agar bisa ditampilkan di semua browser.
CONVERT_FORMATS = {"HEIF", "AVIF", "BMP", "GIF", "TIFF"}
FORMATS_TEXT = "JPG, PNG, WEBP, HEIC, AVIF, BMP, GIF, atau TIFF"
MEDIA_TYPES = {"jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"}
FIG_RE = re.compile(r"^fig_[\w\-]+\.png$")
THUMB_SIDE = 480


# ---------------------------------------------------------------- lifecycle
def cleanup_expired() -> int:
    rows = db.pop_expired(db.now_iso())
    for r in rows:
        shutil.rmtree(config.STORAGE_DIR / r["id"], ignore_errors=True)
    if rows:
        log.info("Hapus otomatis %d job kedaluwarsa", len(rows))
    return len(rows)


async def cleanup_loop():
    while True:
        try:
            await asyncio.to_thread(cleanup_expired)
        except Exception:  # noqa: BLE001
            log.exception("Pembersihan otomatis gagal")
        await asyncio.sleep(config.CLEANUP_INTERVAL_S)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    config.STORAGE_DIR.mkdir(parents=True, exist_ok=True)
    db.init()
    engine.load()
    task = asyncio.create_task(cleanup_loop())
    yield
    task.cancel()


app = FastAPI(
    title="Pichanter API",
    version="1.2.0",
    description="Hapus background foto orang dengan U-Net + MobileNetV3 (TFLite). "
                "Dipakai bersama oleh aplikasi mobile (PWA/APK) dan dashboard web.",
    lifespan=lifespan,
)
app.add_middleware(CORSMiddleware, allow_origins=config.CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"])


@app.middleware("http")
async def cache_policy(request, call_next):
    """Aturan cache untuk proxy/CDN di depan server (Cloudflare men-cache .png/.js secara default).

    - /api/model/figures/*  : grafik publik, boleh di-cache 1 jam.
    - /api/* lainnya        : foto pengguna & data -> jangan pernah disimpan di cache bersama
                              (endpoint yang sudah memberi `private, ...` dibiarkan).
    - file frontend         : `no-cache` -> selalu divalidasi ulang (ETag), jadi pembaruan langsung terlihat.
    """
    response = await call_next(request)
    if "cache-control" not in response.headers:
        path = request.url.path
        if path.startswith("/api/model/figures/"):
            response.headers["Cache-Control"] = "public, max-age=3600"
        elif path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        else:
            response.headers["Cache-Control"] = "no-cache"
    return response


# ---------------------------------------------------------------- helpers
def job_out(j: dict) -> dict:
    base = f"/api/jobs/{j['id']}"
    ok = j["status"] == "ok"
    return {
        "id": j["id"],
        "created_at": j["created_at"],
        "expires_at": j["expires_at"],
        "source": j["source"],
        "status": j["status"],
        "error": j["error"],
        "width": j["width"],
        "height": j["height"],
        "inference_ms": round(j["inference_ms"], 1) if j["inference_ms"] is not None else None,
        "total_ms": round(j["total_ms"], 1) if j["total_ms"] is not None else None,
        "model_version": j["model_version"],
        "original_url": f"{base}/original" if j["original_path"] else None,
        "result_url": f"{base}/result.png" if ok else None,
        "mask_url": f"{base}/mask.png" if ok else None,
        "thumb_url": f"{base}/thumb.webp" if ok else None,
    }


def require_job(job_id: str) -> dict:
    j = db.get_job(job_id)
    if not j:
        raise HTTPException(404, "Job tidak ditemukan atau sudah kedaluwarsa (disimpan maks. 24 jam).")
    return j


def stored_file(j: dict, key: str):
    if not j.get(key):
        raise HTTPException(404, "File tidak tersedia untuk job ini.")
    p = config.STORAGE_DIR / j[key]
    if not p.exists():
        raise HTTPException(410, "File sudah dihapus dari server.")
    return p


def parse_hex(color: str) -> tuple[int, int, int]:
    c = color.strip().lstrip("#")
    if not re.fullmatch(r"[0-9a-fA-F]{6}", c):
        raise HTTPException(400, "Parameter bg harus warna hex 6 digit, mis. FF0000.")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def read_upload(file: UploadFile) -> bytes:
    limit = int(config.MAX_UPLOAD_MB * 1024 * 1024)
    data = file.file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(413, f"Ukuran file melebihi {config.MAX_UPLOAD_MB:g} MB.")
    if not data:
        raise HTTPException(400, "File kosong.")
    return data


def open_image(data: bytes) -> tuple[Image.Image, str, bytes]:
    """Buka foto unggahan. Mengembalikan (gambar, ekstensi simpan, byte foto asli yang disimpan)."""
    try:
        img = Image.open(io.BytesIO(data))
        fmt = img.format
        if getattr(img, "n_frames", 1) > 1:
            img.seek(0)  # GIF/TIFF/MPO berlapis: pakai gambar pertama
        side = config.PROCESS_MAX_SIDE
        if fmt in ("JPEG", "MPO") and max(img.size) > side:
            # Kamera 50-200 MP: dekode JPEG langsung di skala 1/2, 1/4, ... (hemat memori dan waktu).
            s = side / max(img.size)
            img.draft("RGB", (round(img.width * s), round(img.height * s)))
        img.load()
        if max(img.size) > side:
            img = ImageOps.exif_transpose(img)
            img.thumbnail((side, side), Image.Resampling.LANCZOS)
    except Image.DecompressionBombError:
        raise HTTPException(413, "Resolusi gambar terlalu besar.")
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError):
        raise HTTPException(415, f"File bukan gambar yang bisa dibaca. Gunakan {FORMATS_TEXT}.")
    if fmt in PASSTHROUGH_FORMATS:
        return img, PASSTHROUGH_FORMATS[fmt], data
    if fmt not in CONVERT_FORMATS:
        raise HTTPException(415, f"Format {fmt} tidak didukung. Gunakan {FORMATS_TEXT}.")

    img = ImageOps.exif_transpose(img)
    transparent = img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info)
    img = img.convert("RGBA" if transparent else "RGB")
    buf = io.BytesIO()
    if transparent:
        img.save(buf, "PNG", compress_level=3)
        return img, "png", buf.getvalue()
    img.save(buf, "JPEG", quality=92)
    return img, "jpg", buf.getvalue()


# ---------------------------------------------------------------- API
@app.get("/api/health", tags=["sistem"], summary="Status server dan model")
def health():
    return {
        "status": "ok" if engine.ready else "model_error",
        "model_loaded": engine.ready,
        "model_version": engine.model_version,
        "placeholder": engine.placeholder,
        "model_error": engine.error if (engine.placeholder or not engine.ready) else None,
        "time": db.now_iso(),
    }


@app.post("/api/jobs", tags=["jobs"], status_code=201, summary="Hapus background satu foto")
def create_job(
    file: UploadFile = File(..., description="Foto JPG/PNG/WEBP/HEIC/AVIF/BMP/GIF/TIFF, maks. 25 MB"),
    source: Literal["mobile", "web"] = Form("web", description="Asal permintaan"),
):
    t0 = time.perf_counter()
    if not engine.ready:
        raise HTTPException(503, f"Model belum siap di server: {engine.error}")

    data = read_upload(file)
    img, ext, original = open_image(data)

    job_id = str(uuid.uuid4())
    created = datetime.now(timezone.utc)
    job = {
        "id": job_id,
        "created_at": created.isoformat(timespec="milliseconds"),
        "expires_at": (created + timedelta(hours=config.RETENTION_HOURS)).isoformat(timespec="milliseconds"),
        "source": source,
        "model_version": engine.model_version,
    }
    folder = config.STORAGE_DIR / job_id
    folder.mkdir(parents=True)
    (folder / f"original.{ext}").write_bytes(original)
    job["original_path"] = f"{job_id}/original.{ext}"

    try:
        res = engine.process(img)
        res.cutout.save(folder / "result.png", optimize=False, compress_level=3)
        res.mask.save(folder / "mask.png", compress_level=3)
    except Exception as e:  # noqa: BLE001 - dicatat sebagai job gagal
        log.exception("Proses job %s gagal", job_id)
        job.update(status="error", error=f"{type(e).__name__}: {e}",
                   total_ms=(time.perf_counter() - t0) * 1000)
        db.insert_job(job)
        raise HTTPException(500, "Gagal memproses foto. Coba foto lain.")

    job.update(
        result_path=f"{job_id}/result.png",
        mask_path=f"{job_id}/mask.png",
        width=res.rgb.width,
        height=res.rgb.height,
        inference_ms=res.inference_ms,
        total_ms=(time.perf_counter() - t0) * 1000,
        status="ok",
    )
    db.insert_job(job)
    log.info("job=%s source=%s size=%dx%d infer=%.1fms total=%.1fms model=%s",
             job_id, source, res.rgb.width, res.rgb.height, job["inference_ms"], job["total_ms"],
             job["model_version"])
    return job_out(job | {"error": None})


@app.get("/api/jobs", tags=["jobs"], summary="Riwayat terbaru (semua perangkat)")
def list_jobs(
    limit: int = Query(20, ge=1, le=100),
    source: Literal["mobile", "web"] | None = Query(None, description="Filter asal perangkat"),
):
    return [job_out(j) for j in db.list_jobs(limit, source)]


@app.get("/api/jobs/{job_id}", tags=["jobs"], summary="Detail satu job")
def get_job(job_id: str):
    return job_out(require_job(job_id))


@app.delete("/api/jobs/{job_id}", tags=["jobs"], status_code=204, summary="Hapus satu foto dari riwayat",
            description="Menghapus baris di database beserta foto asli, mask, hasil, dan thumbnail di server. "
                        "Dashboard dan perangkat lain ikut tidak menampilkannya pada pembaruan berikutnya.")
def delete_job(job_id: str):
    j = db.delete_job(job_id)
    if not j:
        raise HTTPException(404, "Job tidak ditemukan atau sudah dihapus.")
    shutil.rmtree(config.STORAGE_DIR / j["id"], ignore_errors=True)
    log.info("job=%s dihapus manual (source=%s)", j["id"], j["source"])
    return Response(status_code=204)


@app.get("/api/jobs/{job_id}/result.png", tags=["jobs"], summary="Unduh hasil ukuran asli",
         response_class=Response, responses={200: {"content": {"image/png": {}, "image/jpeg": {}}}})
def get_result(
    job_id: str,
    bg: str | None = Query(None, description="Warna latar hex, mis. FF0000. Kosong = transparan."),
    format: Literal["png", "jpg"] = Query("png", description="jpg hanya bisa dipakai bersama bg"),
    download: bool = Query(False, description="true = paksa unduh (Content-Disposition: attachment)"),
):
    j = require_job(job_id)
    path = stored_file(j, "result_path")
    name = f"pichanter_{job_id[:8]}"
    disp = "attachment" if download else "inline"

    if bg is None:
        if format == "jpg":
            raise HTTPException(400, "JPG tidak mendukung transparansi; tambahkan parameter bg.")
        return FileResponse(path, media_type="image/png",
                            headers={"Content-Disposition": f'{disp}; filename="{name}.png"',
                                     "Cache-Control": "private, max-age=86400"})

    color = parse_hex(bg)
    cut = Image.open(path)
    out = Image.new("RGB", cut.size, color)
    out.paste(cut, mask=cut.getchannel("A"))
    buf = io.BytesIO()
    if format == "jpg":
        out.save(buf, format="JPEG", quality=92)
        media, ext = "image/jpeg", "jpg"
    else:
        out.save(buf, format="PNG", compress_level=3)
        media, ext = "image/png", "png"
    suffix = bg.strip().lstrip("#").upper()
    return Response(buf.getvalue(), media_type=media,
                    headers={"Content-Disposition": f'{disp}; filename="{name}_{suffix}.{ext}"',
                             "Cache-Control": "private, max-age=86400"})


@app.get("/api/jobs/{job_id}/thumb.webp", tags=["jobs"], summary="Thumbnail hasil (sisi terpanjang 480 px)",
         response_class=FileResponse)
def get_thumb(job_id: str):
    j = require_job(job_id)
    src = stored_file(j, "result_path")
    thumb = src.with_name("thumb.webp")
    if not thumb.exists():
        img = Image.open(src)
        img.thumbnail((THUMB_SIDE, THUMB_SIDE), Image.LANCZOS)
        tmp = thumb.with_suffix(".tmp")
        img.save(tmp, format="WEBP", quality=82, method=4)
        tmp.replace(thumb)
    return FileResponse(thumb, media_type="image/webp", headers={"Cache-Control": "private, max-age=86400"})


@app.get("/api/jobs/{job_id}/mask.png", tags=["jobs"], summary="Mask probabilitas orang",
         response_class=FileResponse)
def get_mask(job_id: str):
    return FileResponse(stored_file(require_job(job_id), "mask_path"), media_type="image/png")


@app.get("/api/jobs/{job_id}/original", tags=["jobs"], summary="Foto asli", response_class=FileResponse)
def get_original(job_id: str):
    p = stored_file(require_job(job_id), "original_path")
    return FileResponse(p, media_type=MEDIA_TYPES.get(p.suffix.lstrip("."), "application/octet-stream"))


@app.get("/api/model", tags=["model"], summary="Info dan metrik model")
def model_info():
    eval_path = config.MODEL_DIR / "hasil_evaluasi.json"
    evaluasi = None
    if eval_path.exists():
        try:
            evaluasi = json.loads(eval_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            log.warning("hasil_evaluasi.json tidak valid")
    figures = sorted(p.name for p in config.MODEL_DIR.glob("fig_*.png")) if config.MODEL_DIR.exists() else []
    model_file = config.MODEL_DIR / config.MODEL_FILE
    return {
        "model_version": engine.model_version,
        "placeholder": engine.placeholder,
        "model_file": config.MODEL_FILE if model_file.exists() else None,
        "model_size_mb": round(model_file.stat().st_size / 1e6, 2) if model_file.exists() else None,
        "evaluasi": evaluasi,
        "figures": [{"name": f, "url": f"/api/model/figures/{f}"} for f in figures],
        "server_stats": db.stats(),
    }


@app.get("/api/model/figures/{name}", tags=["model"], summary="Gambar grafik dari notebook",
         response_class=FileResponse)
def model_figure(name: str):
    p = config.MODEL_DIR / name
    if not FIG_RE.fullmatch(name) or not p.exists():
        raise HTTPException(404, "Gambar tidak ditemukan.")
    return FileResponse(p, media_type="image/png")


# ---------------------------------------------------------------- unduh aplikasi
APK_MEDIA_TYPE = "application/vnd.android.package-archive"


@app.get("/api/downloads", tags=["aplikasi"], summary="Info file aplikasi yang bisa diunduh (APK Android)")
def downloads():
    apk = config.DOWNLOAD_DIR / config.APK_FILE
    if not apk.is_file():
        return {"apk": None}
    meta = {}
    meta_path = apk.with_name(apk.name + ".json")  # ditulis oleh android-app/build.mjs
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            log.warning("%s tidak valid", meta_path.name)
    st = apk.stat()
    return {"apk": {
        "url": f"/download/{config.APK_FILE}",
        "size_mb": round(st.st_size / 1e6, 1),
        "version": meta.get("version"),
        "built_at": meta.get("built_at") or datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
        "min_android": meta.get("min_android", "10"),
        "sha256": meta.get("sha256"),
    }}


@app.get("/download/{name}", tags=["aplikasi"], summary="Unduh APK Android", response_class=FileResponse)
def download_apk(name: str):
    apk = config.DOWNLOAD_DIR / config.APK_FILE
    if name != config.APK_FILE or not apk.is_file():
        raise HTTPException(404, "File aplikasi belum tersedia.")
    return FileResponse(apk, media_type=APK_MEDIA_TYPE, filename=config.APK_FILE,
                        headers={"Cache-Control": "no-cache"})


# ---------------------------------------------------------------- frontend (tahap 2-3)
if config.MOBILE_DIR.is_dir():
    app.mount("/app", StaticFiles(directory=config.MOBILE_DIR, html=True), name="mobile")
if config.WEB_DIR.is_dir():
    app.mount("/", StaticFiles(directory=config.WEB_DIR, html=True), name="web")
else:
    @app.get("/", include_in_schema=False)
    def root():
        return RedirectResponse("/docs")
