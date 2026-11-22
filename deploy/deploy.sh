#!/usr/bin/env bash
# Kirim kode ke home server lalu build & jalankan ulang container (satu koneksi SSH).
# Pakai (Git Bash di Windows / Linux / macOS), dari folder mana saja:
#   bash deploy/deploy.sh                 # default jalu@192.168.1.7, folder ~/pichanter
#   bash deploy/deploy.sh user@host       # server lain
# Butuh: ssh ke server, Docker + Docker Compose v2 di server (user boleh menjalankan docker).
# File .env di server (opsional) dan volume data TIDAK disentuh.
set -euo pipefail

HOST="${1:-jalu@192.168.1.7}"
DIR="${DEPLOY_DIR:-pichanter}"
cd "$(dirname "$0")/.."

for f in backend/models/pichanter_bg_fp16.tflite backend/models/hasil_evaluasi.json; do
  [ -f "$f" ] || { echo "File wajib tidak ada: $f" >&2; exit 1; }
done
[ -f backend/downloads/pichanter.apk ] \
  || echo "PERINGATAN: backend/downloads/pichanter.apk belum ada -> menu Unduh APK kosong (jalankan npm run apk di android-app/)"

REMOTE=$(cat <<EOF
set -e
mkdir -p "$DIR" && cd "$DIR"
rm -rf backend mobile web
tar xzf -
echo "==> Kode diterima di ~/$DIR"
echo "==> Build & jalankan"
docker compose up -d --build --remove-orphans
docker image prune -f >/dev/null
echo "==> Menunggu container sehat"
for i in \$(seq 1 45); do
  s=\$(docker inspect -f '{{.State.Health.Status}}' pichanter 2>/dev/null || echo none)
  [ "\$s" = healthy ] && break
  sleep 2
done
docker compose ps
echo "health container: \$s"
docker exec pichanter python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/api/health').read().decode())"
[ "\$s" = healthy ] || { echo "Container belum sehat. Log:"; docker compose logs --tail 40 pichanter; exit 1; }
EOF
)

echo "==> Mengirim kode ke $HOST:~/$DIR"
tar czf - --exclude='__pycache__' --exclude='*.pyc' \
    Dockerfile .dockerignore docker-compose.yml .env.example \
    backend/requirements.txt backend/app backend/models backend/downloads mobile web \
  | ssh "$HOST" "bash -c \"\$(echo $(printf '%s' "$REMOTE" | base64 | tr -d '\n') | base64 -d)\""

echo "==> Selesai. Cek di server: curl http://172.17.0.1:8010/api/health"
echo "    Cek dari luar:  https://pichanter.jalulabs.my.id/api/health"
