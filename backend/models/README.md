# Folder model

Model terpasang: **v2** (input 384×384, Dice loss) dari `pichanter_bgremoval_v2/`. Model v0 (256 px) tetap ada di
`pichanter_bgremoval/` sebagai pembanding. Ukuran input dibaca otomatis dari file `.tflite`.

Salin file dari folder hasil notebook ke sini:

| File | Wajib | Dipakai untuk |
|---|---|---|
| `pichanter_bg_fp16.tflite` | ya | model utama (`MODEL_FILE`) |
| `pichanter_bg_int8dyn.tflite` | tidak | cadangan ringan (ganti `MODEL_FILE`) |
| `hasil_evaluasi.json` | ya | `GET /api/model`, halaman Info Model |
| `fig_*.png` | ya | grafik di halaman Info Model (`fig_11` v0 vs v1, `fig_12` v0 vs v2) |

Bila `pichanter_bg_fp16.tflite` belum ada, server memakai **model sementara** (heuristik, bukan AI)
selama `ALLOW_PLACEHOLDER=true`. Cek dengan `GET /api/health` → `"placeholder": true`.

`pichanter_bg.py` dari notebook boleh menimpa `backend/app/pichanter_bg.py` (isinya sama).
