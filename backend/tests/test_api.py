import io
import json
import time

from PIL import Image

from app import db
from app.main import cleanup_expired
from app.ml import engine
from conftest import make_photo


def post(client, data, name="foto.jpg", source="mobile", ctype="image/jpeg"):
    return client.post("/api/jobs", files={"file": (name, data, ctype)}, data={"source": source})


def test_health_reports_placeholder(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["model_loaded"] is True
    assert body["placeholder"] is True and body["model_version"] == "placeholder-v0"


def test_t1_remove_background_returns_transparent_png_full_size(client):
    r = post(client, make_photo(800, 600))
    assert r.status_code == 201, r.text
    job = r.json()
    assert job["status"] == "ok" and job["source"] == "mobile"
    assert (job["width"], job["height"]) == (800, 600)
    assert job["inference_ms"] >= 0 and job["total_ms"] >= job["inference_ms"]
    for key in ("result_url", "mask_url", "original_url"):
        assert client.get(job[key]).status_code == 200

    png = Image.open(io.BytesIO(client.get(job["result_url"]).content))
    assert png.mode == "RGBA" and png.size == (800, 600)
    alpha = png.getchannel("A")
    assert alpha.getpixel((5, 5)) < 30            # sudut (background) transparan
    assert alpha.getpixel((400, 400)) > 200       # tengah (orang) tetap


def test_thumbnail_is_small_transparent_webp_and_cached(client, tmp_root):
    job = post(client, make_photo(1600, 1200)).json()
    r = client.get(job["thumb_url"])
    assert r.status_code == 200 and r.headers["content-type"] == "image/webp"
    img = Image.open(io.BytesIO(r.content))
    assert img.size == (480, 360) and img.mode == "RGBA"
    assert (tmp_root / "storage" / job["id"] / "thumb.webp").exists()
    assert client.get(job["thumb_url"]).content == r.content


def test_exif_orientation_is_applied(client):
    job = post(client, make_photo(640, 480, exif_orientation=6)).json()
    assert (job["width"], job["height"]) == (480, 640)


def test_t2_replace_background_color(client):
    job = post(client, make_photo(320, 240)).json()
    r = client.get(job["result_url"], params={"bg": "FF0000", "format": "jpg", "download": True})
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert "attachment" in r.headers["content-disposition"]
    img = Image.open(io.BytesIO(r.content))
    assert img.size == (320, 240)
    rr, g, b = img.getpixel((3, 3))
    assert rr > 200 and g < 50 and b < 50

    r = client.get(job["result_url"], params={"bg": "#0000ff"})
    assert r.status_code == 200 and Image.open(io.BytesIO(r.content)).mode == "RGB"
    assert client.get(job["result_url"], params={"bg": "merah"}).status_code == 400
    assert client.get(job["result_url"], params={"format": "jpg"}).status_code == 400


def test_png_and_webp_accepted(client):
    for fmt, ctype in (("PNG", "image/png"), ("WEBP", "image/webp")):
        r = post(client, make_photo(200, 200, fmt=fmt), name="x." + fmt.lower(), ctype=ctype)
        assert r.status_code == 201, (fmt, r.text)


def test_t4_rejects_non_image(client):
    r = post(client, b"%PDF-1.4 bukan gambar", name="dokumen.pdf", ctype="application/pdf")
    assert r.status_code == 415
    assert "JPG" in r.json()["detail"]


def test_t4_rejects_oversized_file(client):
    from app import config
    big = b"\xff\xd8" + b"0" * (int(config.MAX_UPLOAD_MB * 1024 * 1024) + 10)
    r = post(client, big)
    assert r.status_code == 413
    assert client.get("/api/health").json()["status"] == "ok"   # server tetap jalan


def test_phone_and_common_formats_accepted(client):
    """Foto HP (HEIC, MPO Samsung, AVIF) dan format umum lain diterima; aslinya disimpan sebagai JPG/PNG."""
    import pillow_heif  # noqa: F401 - mendaftarkan encoder HEIF untuk membuat contoh foto

    cases = [("HEIF", "foto.heic", "image/heic", "image/jpeg"),
             ("MPO", "foto.jpg", "image/jpeg", "image/jpeg"),
             ("AVIF", "foto.avif", "image/avif", "image/jpeg"),
             ("BMP", "foto.bmp", "image/bmp", "image/jpeg"),
             ("GIF", "foto.gif", "image/gif", "image/jpeg"),
             ("TIFF", "foto.tif", "image/tiff", "image/jpeg")]
    for fmt, name, ctype, original_type in cases:
        r = post(client, make_photo(240, 180, fmt=fmt), name=name, ctype=ctype)
        assert r.status_code == 201, (fmt, r.text)
        job = r.json()
        assert (job["width"], job["height"]) == (240, 180), fmt
        orig = client.get(job["original_url"])
        assert orig.headers["content-type"] == original_type, fmt
        assert Image.open(io.BytesIO(orig.content)).size == (240, 180), fmt


def test_converted_transparent_original_kept_as_png(client):
    buf = io.BytesIO()
    Image.new("RGBA", (64, 64), (0, 0, 0, 0)).save(buf, format="TIFF")
    job = post(client, buf.getvalue(), name="logo.tif", ctype="image/tiff").json()
    assert client.get(job["original_url"]).headers["content-type"] == "image/png"


def test_huge_camera_photo_is_downscaled_not_rejected(client, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "PROCESS_MAX_SIDE", 1000)
    job = post(client, make_photo(3000, 2000, exif_orientation=6)).json()
    assert job["status"] == "ok" and max(job["width"], job["height"]) <= 1000
    assert job["height"] > job["width"]          # orientasi EXIF tetap diterapkan
    job = post(client, make_photo(2400, 1800, fmt="PNG"), name="x.png", ctype="image/png").json()
    assert (job["width"], job["height"]) == (1000, 750)


def test_rejects_unsupported_image_format(client):
    buf = io.BytesIO()
    Image.new("RGB", (32, 32)).save(buf, format="ICO")
    r = post(client, buf.getvalue(), name="a.ico", ctype="image/x-icon")
    assert r.status_code == 415 and "HEIC" in r.json()["detail"]
    svg = b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>'
    assert post(client, svg, name="a.svg", ctype="image/svg+xml").status_code == 415


def test_invalid_source_rejected(client):
    assert post(client, make_photo(100, 100), source="tablet").status_code == 422


def test_history_newest_first_and_filter(client):
    a = post(client, make_photo(100, 100), source="web").json()
    time.sleep(0.01)
    b = post(client, make_photo(100, 100), source="mobile").json()
    jobs = client.get("/api/jobs", params={"limit": 2}).json()
    assert [j["id"] for j in jobs] == [b["id"], a["id"]]
    assert all(j["source"] == "web" for j in client.get("/api/jobs", params={"source": "web"}).json())
    assert client.get(f"/api/jobs/{a['id']}").json()["source"] == "web"
    assert client.get("/api/jobs/tidak-ada").status_code == 404


def test_model_info_reads_evaluation_and_figures(client, tmp_root):
    models = tmp_root / "models"
    (models / "hasil_evaluasi.json").write_text(json.dumps({"test_mean": {"dice": 0.96}}))
    Image.new("RGB", (10, 10)).save(models / "fig_04_kurva_training.png")
    body = client.get("/api/model").json()
    assert body["evaluasi"]["test_mean"]["dice"] == 0.96
    assert body["figures"][0]["name"] == "fig_04_kurva_training.png"
    assert body["server_stats"]["jobs"] >= 1 and body["server_stats"]["avg_inference_ms"] is not None
    assert client.get(body["figures"][0]["url"]).status_code == 200
    assert client.get("/api/model/figures/..%2Fsecret.png").status_code == 404


def test_expired_jobs_are_deleted_with_files(client, tmp_root):
    job = post(client, make_photo(100, 100)).json()
    folder = tmp_root / "storage" / job["id"]
    assert folder.exists()
    with db.connect() as c:
        c.execute("UPDATE jobs SET expires_at = '2000-01-01T00:00:00+00:00' WHERE id = ?", (job["id"],))
    assert cleanup_expired() >= 1
    assert not folder.exists()
    assert client.get(f"/api/jobs/{job['id']}").status_code == 404


def test_refuses_when_model_missing_and_placeholder_disabled(client, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "ALLOW_PLACEHOLDER", False)
    engine.load()
    try:
        r = post(client, make_photo(100, 100))
        assert r.status_code == 503 and "Model belum siap" in r.json()["detail"]
        assert client.get("/api/health").json()["status"] == "model_error"
    finally:
        monkeypatch.setattr(config, "ALLOW_PLACEHOLDER", True)
        engine.load()


def test_cache_headers_keep_user_photos_out_of_shared_caches(client):
    """Di belakang Cloudflare: foto pengguna tidak boleh tersimpan di cache CDN."""
    job = post(client, make_photo()).json()
    for key in ("original_url", "mask_url"):
        cc = client.get(job[key]).headers["cache-control"]
        assert "no-store" in cc or "private" in cc, (key, cc)
    for key in ("result_url", "thumb_url"):
        assert "private" in client.get(job[key]).headers["cache-control"]
    assert client.get(f"/api/jobs/{job['id']}").headers["cache-control"] == "no-store"
    assert client.get("/api/health").headers["cache-control"] == "no-store"


def test_downloads_empty_when_apk_not_published(client, tmp_path, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "DOWNLOAD_DIR", tmp_path)
    assert client.get("/api/downloads").json() == {"apk": None}
    assert client.get("/download/pichanter.apk").status_code == 404


def test_download_apk_with_metadata(client, tmp_path, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "DOWNLOAD_DIR", tmp_path)
    (tmp_path / "pichanter.apk").write_bytes(b"PK\x03\x04" + b"0" * 2000)
    (tmp_path / "pichanter.apk.json").write_text(json.dumps({"version": "1.0 (1)", "sha256": "ab" * 32}))
    info = client.get("/api/downloads").json()["apk"]
    assert info["url"] == "/download/pichanter.apk" and info["version"] == "1.0 (1)" and info["sha256"] == "ab" * 32
    r = client.get(info["url"])
    assert r.status_code == 200 and r.content.startswith(b"PK")
    assert r.headers["content-type"] == "application/vnd.android.package-archive"
    assert "attachment" in r.headers["content-disposition"] and "pichanter.apk" in r.headers["content-disposition"]
    assert client.get("/download/lain.apk").status_code == 404           # hanya nama yang dikonfigurasi
    assert client.get("/download/..%2Fmodels%2Fx").status_code == 404
