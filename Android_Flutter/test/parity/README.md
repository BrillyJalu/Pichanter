# Uji Paritas Mask (P1 — HP vs Python `pichanter_bg.py`)

Target PRD: **Dice antar-mask ≥ 0,99** pada 20 foto uji.

## Struktur Folder
- `photos/` — taruh foto uji (JPG/PNG/WEBP). Awalnya diisi 3 foto contoh + 2 varian rotasi EXIF; tambahkan 20 foto set test v2 atau foto sendiri saat tersedia.
- `refs/` — mask referensi hasil Python (`generate_parity_refs.py`).
- `device_out/` — mask hasil Android/Flutter yang ditarik dari emulator/HP via `adb pull`.

## Cara Menjalankan
Dari folder `Android_Flutter/`:

```powershell
# 1. Buat mask referensi Python
..\backend\.venv\Scripts\python.exe tools\generate_parity_refs.py

# 2. Dorong foto uji ke penyimpanan aplikasi di emulator/HP
adb shell "mkdir -p /sdcard/Android/data/id.my.jalulabs.pichanter_mobile/files/parity_in && chmod 777 /sdcard/Android/data/id.my.jalulabs.pichanter_mobile/files/parity_in"
adb push test/parity/photos/. /sdcard/Android/data/id.my.jalulabs.pichanter_mobile/files/parity_in/
adb shell "chmod 666 /sdcard/Android/data/id.my.jalulabs.pichanter_mobile/files/parity_in/*"

# 3. Tekan tombol "Jalankan Uji Paritas" di layar spike aplikasi

# 4. Tarik hasil mask dari emulator/HP lalu bandingkan
adb pull /sdcard/Android/data/id.my.jalulabs.pichanter_mobile/files/parity_out/. test/parity/device_out/
..\backend\.venv\Scripts\python.exe tools\compare_parity.py
```
