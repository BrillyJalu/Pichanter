import io
import os
import sys
import tempfile
from pathlib import Path

import pytest
from PIL import Image

# Arahkan storage & model ke folder sementara SEBELUM app diimpor.
_TMP = Path(tempfile.mkdtemp(prefix="pichanter_test_"))
os.environ.update(
    STORAGE_DIR=str(_TMP / "storage"),
    DB_PATH=str(_TMP / "storage" / "test.db"),
    MODEL_DIR=str(_TMP / "models"),
    ALLOW_PLACEHOLDER="true",
    CLEANUP_INTERVAL_S="3600",
)
(_TMP / "models").mkdir()
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def tmp_root() -> Path:
    return _TMP


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c


def make_photo(w=640, h=480, fmt="JPEG", exif_orientation=None) -> bytes:
    """Foto sintetis: latar hijau polos + 'orang' (elips abu-abu) di tengah."""
    img = Image.new("RGB", (w, h), (40, 180, 60))
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    d.ellipse([w * 0.3, h * 0.15, w * 0.7, h * 1.1], fill=(200, 160, 140))
    buf = io.BytesIO()
    kw = {}
    if exif_orientation:
        exif = Image.Exif()
        exif[0x0112] = exif_orientation
        kw["exif"] = exif
    img.save(buf, format=fmt, **kw)
    return buf.getvalue()
