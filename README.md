# Pichanter — Hapus Background Foto dengan U-Net MobileNetV3

Prototipe aplikasi AI untuk UTS Pembelajaran Mesin (Magister Informatika UII).
Pengguna memilih atau memotret foto orang, lalu background-nya dihapus oleh model segmentasi
**U-Net + encoder MobileNetV3-Large** yang dilatih sendiri. Hasilnya bisa disimpan sebagai PNG transparan.

**Aplikasi:** https://pichanter.jalulabs.my.id
— dashboard web di `/`, aplikasi mobile (PWA) di `/app/`, dokumentasi API di `/docs`.

> Brilly Jalu Kumara Biseka · NIM 25917018

## Permasalahan

Menghapus background foto orang (pas foto, foto produk, konten media sosial) biasanya butuh aplikasi
desain berbayar atau layanan daring yang mengunggah foto ke pihak ketiga. Pichanter memakai model
ringan (±3,5 juta parameter, 7,1 MB) yang bisa dijalankan di server sederhana maupun langsung di HP.

## Arsitektur

```
HP (PWA / APK) ─┐
                ├─HTTPS─> Cloudflare Tunnel ─> FastAPI (Docker, home server)
Browser web ────┘                               ├─ /api/jobs  → LiteRT/TFLite (model v2, 384×384)
                                                ├─ /app/      → PWA Vue 3
                                                ├─ /          → dashboard web Vue 3
                                                └─ SQLite + penyimpanan foto (dihapus otomatis 24 jam)
```

Selain itu ada aplikasi **Android Flutter offline** (`Android_Flutter/`) yang menjalankan model yang sama
langsung di HP tanpa server.

## Model

| Bagian | Isi |
|---|---|
| Acuan | Shahi & Li (2023), *IJNDI* 2(2):100004, doi:10.53941/ijndi.2023.100004 |
| Dataset | [Kaggle nikhilroxtomar/person-segmentation](https://www.kaggle.com/datasets/nikhilroxtomar/person-segmentation), 5.678 pasang foto–mask |
| Pembagian data | train 4.542 / val 567 / test 569 (seed 42, dibagi sebelum augmentasi) |
| Arsitektur | U-Net, encoder MobileNetV3-Large (ImageNet), decoder 128/64/48/32, output sigmoid |
| Parameter | 3.543.417 |
| Training | Dice loss, Adam 1e-4, ReduceLROnPlateau, EarlyStopping; 66 epoch (terbaik epoch 56), 87,5 menit |
| Input | 384 × 384 |

Hasil pada **569 gambar test** (model v2 yang dipakai di produksi):

| Metrik | Nilai |
|---|---|
| Dice rata-rata | 0,9356 |
| IoU rata-rata | 0,8898 |
| Dice global | 0,9553 |
| Precision / Recall | 0,9354 / 0,9469 |
| MAD / MSE | 0,0219 / 0,0216 |
| Ukuran TFLite fp16 | 7,1 MB |

Eksperimen yang dibandingkan (uji Wilcoxon + syarat selisih minimal 0,005):

| Versi | Perubahan | Dice | Keputusan |
|---|---|---|---|
| v0 | Input 256, Dice loss | 0,9113 | baseline |
| v1 | BCE + Dice loss | 0,9137 | tidak berbeda nyata (p = 0,51) |
| v2 | Input 384 | 0,9356 | **dipakai** (p = 3,9e-42; objek kecil naik 0,781 → 0,855) |

Grafik, metrik per gambar, uji ketahanan, dan perbandingan ada di `pichanter_bgremoval/`,
`pichanter_bgremoval_v1/`, dan `pichanter_bgremoval_v2/`. Notebook training ada di `notebooks/`.

## Struktur folder

| Folder | Isi |
|---|---|
| `notebooks/` | Notebook Colab training dan evaluasi (v0, v1, v2) |
| `pichanter_bgremoval*/` | Hasil eksperimen: metrik, grafik, log training |
| `backend/` | FastAPI + LiteRT, model produksi di `backend/models/`, tes di `backend/tests/` |
| `web/` | Dashboard web (Vue 3) |
| `mobile/` | Aplikasi mobile PWA (Vue 3) |
| `android-app/` | Pembungkus APK (Capacitor) untuk PWA |
| `Android_Flutter/` | Aplikasi Android offline (Flutter + LiteRT), lihat README di dalamnya |
| `deploy/`, `Dockerfile`, `docker-compose.yml` | Deploy ke server, lihat [DEPLOY.md](DEPLOY.md) |

## Menjalankan secara lokal

```bash
cd backend
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
cp .env.example .env               # opsional
uvicorn app.main:app --reload --port 8000
```

Buka http://localhost:8000 (dashboard) dan http://localhost:8000/app/ (PWA). Tes: `pytest` dari folder `backend/`.

Dengan Docker:

```bash
docker compose up -d --build       # http://172.17.0.1:8010, atau set PICHANTER_BIND di .env
```

## API utama

| Method | Endpoint | Fungsi |
|---|---|---|
| `POST` | `/api/jobs` | Unggah foto, kembalikan hasil hapus background |
| `GET` | `/api/jobs`, `/api/jobs/{id}` | Riwayat dan detail hasil |
| `DELETE` | `/api/jobs/{id}` | Hapus satu foto dari riwayat (baris database + semua file-nya), balasan 204 |
| `GET` | `/api/model` | Info dan metrik model |
| `GET` | `/api/health` | Status server dan model |

Dokumentasi lengkap: `/docs` (Swagger).

## Keamanan dan privasi

- Repo ini tidak memuat kredensial atau API key. Pengaturan rahasia hanya di file `.env` di server
  (lihat `.env.example`), dan `.env` diabaikan oleh Git.
- Foto yang diunggah ke server dihapus otomatis setelah 24 jam.
- Aplikasi Flutter berjalan sepenuhnya di HP; build release tidak memiliki izin internet.
