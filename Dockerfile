# Pichanter: backend FastAPI + model TFLite + PWA (/app) + dashboard (/), satu container.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app/backend
COPY backend/requirements.txt .
RUN pip install -r requirements.txt

# Struktur sama dengan repo: config.py mencari ../mobile dan ../web relatif terhadap backend/.
COPY backend/app ./app
COPY backend/models ./models
COPY backend/downloads ./downloads
COPY mobile /app/mobile
COPY web /app/web

# Data (SQLite + foto, dihapus otomatis setelah 24 jam) di volume, jalan sebagai user non-root.
RUN useradd --system --uid 10001 --home-dir /data pichanter \
    && mkdir -p /data/storage && chown -R pichanter /data
USER pichanter
ENV STORAGE_DIR=/data/storage \
    DB_PATH=/data/pichanter.db \
    ALLOW_PLACEHOLDER=false
VOLUME ["/data"]

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import json,urllib.request,sys; h=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/health',timeout=4)); sys.exit(0 if h.get('model_loaded') else 1)"

# 1 worker: interpreter TFLite dikunci per proses, SQLite + loop pembersihan cukup satu.
# --proxy-headers: di belakang Cloudflare Tunnel, skema/IP asli dibaca dari header X-Forwarded-*.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
