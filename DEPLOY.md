# Deploy Pichanter ke home server

Target: **https://pichanter.jalulabs.my.id** (dashboard di `/`, aplikasi mobile/PWA di `/app/`,
API di `/api/`, dokumentasi API di `/docs`). Server: `jalu@192.168.1.7`, HTTPS lewat **Cloudflare Tunnel**,
sehingga tidak perlu membuka port di router. Aplikasi bersifat publik (tanpa login).

```
HP / APK / browser ──HTTPS──> Cloudflare ──tunnel──> cloudflared ──HTTP──> 172.17.0.1:8010 → container pichanter:8000
                                                     (sudah ada di server)        FastAPI + TFLite + PWA + dashboard
```

## 1. Sekali saja: siapkan akses

**SSH tanpa password** (di laptop, PowerShell). Lewati `ssh-keygen` bila sudah punya key.

```powershell
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh jalu@192.168.1.7 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh jalu@192.168.1.7 "docker compose version"
```

Perintah terakhir harus berhasil tanpa `sudo`. Kalau muncul *permission denied* soal Docker, jalankan
`sudo usermod -aG docker jalu` di server, lalu logout dan login lagi.

**Hostname publik di tunnel yang sudah ada.** Tidak perlu membuat tunnel baru, token, maupun aplikasi
Cloudflare Access. Cukup tambahkan satu hostname ke tunnel jalulabs yang sudah melayani subdomain lain
(misalnya `api.jalulabs.my.id`). Pengunjung langsung masuk tanpa login.

Cek dulu cara tunnel di server dikelola:

```sh
ls /etc/cloudflared ~/.cloudflared 2>/dev/null
systemctl cat cloudflared 2>/dev/null | grep ExecStart
```

- **Ada `config.yml` berisi `ingress:`** (dikelola lokal). Tambahkan aturan ini **di atas** baris terakhir
  `- service: http_status:404`:

  ```yaml
    - hostname: pichanter.jalulabs.my.id
      service: http://172.17.0.1:8010
  ```

  Lalu buat DNS-nya dan muat ulang cloudflared:

  ```sh
  cloudflared tunnel list                                   # lihat nama tunnel
  cloudflared tunnel route dns <nama-tunnel> pichanter.jalulabs.my.id
  sudo systemctl restart cloudflared                        # atau: docker restart <container-cloudflared>
  ```

- **`ExecStart` berisi `--token`** (dikelola dari dashboard). Buka tunnel yang sama di dashboard Cloudflare,
  tempat hostname `api` didaftarkan, lalu tambahkan hostname: subdomain `pichanter`, domain `jalulabs.my.id`,
  type **HTTP**, URL `172.17.0.1:8010`. DNS dibuat otomatis.

File `~/pichanter/.env` tidak wajib. Nilai bawaannya sudah benar (`172.17.0.1:8010`, sama polanya dengan
KuisKilat di `172.17.0.1:3000`).

## 2. Deploy (setiap ada perubahan)

Di laptop, jalankan dari Git Bash di folder proyek:

```bash
bash deploy/deploy.sh
```

Script ini:

- mengirim `backend/`, model, `mobile/`, dan `web/` ke `~/pichanter`;
- menjalankan `docker compose up -d --build`;
- menunggu container berstatus *healthy*.

File `.env` dan data foto di volume `pichanter-data` tidak disentuh.

## 3. Cek setelah deploy

| Cek | Hasil yang diharapkan |
|---|---|
| `https://pichanter.jalulabs.my.id/api/health` | `"model_loaded": true`, `"placeholder": false`, `model_version` `unet-mnv3l-384-fp16-v2` |
| Buka `/` di laptop | Dashboard; halaman Info Model menampilkan metrik v2 dan 12 grafik |
| Buka `/app/` di HP | Bisa ambil atau pilih foto, background terhapus dalam ±1–3 detik |
| APK `android-app/dist/pichanter.apk` | Terbuka langsung ke `/app/` (tanpa build ulang) |

## Perintah berguna di server

```sh
cd ~/pichanter
docker compose ps                     # status
docker compose logs -f pichanter      # log aplikasi
curl http://172.17.0.1:8010/api/health   # cek langsung tanpa lewat Cloudflare
docker compose restart pichanter
docker compose down                   # berhenti (data tetap di volume)
```

## Catatan

- **Model gagal dimuat → HTTP 503.** Di produksi `ALLOW_PLACEHOLDER=false`, jadi server menolak permintaan
  alih-alih memakai model sementara.
- **Foto pengguna tidak di-cache Cloudflare.** Respons `/api/` dikirim dengan header `no-store` atau `private`,
  dan file aplikasi dengan header `no-cache`, sehingga pembaruan langsung terlihat setelah deploy.
- **Cadangan demo bila internet putus.** Buat `~/pichanter/.env` berisi `PICHANTER_BIND=0.0.0.0`, deploy ulang, lalu build
  APK uji untuk jaringan lokal:

  ```bash
  npm run apk -- --url http://192.168.1.7:8010
  ```

  Hasilnya `android-app/dist/pichanter-uji-192-168-1-7.apk`.
