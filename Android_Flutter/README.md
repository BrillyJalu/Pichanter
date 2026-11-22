# Pichanter Mobile — Android Flutter Offline

Aplikasi Android (Flutter) untuk menghapus dan mengganti background foto orang **100% di perangkat (on-device)** tanpa server dan tanpa koneksi internet, menggunakan model **U-Net + MobileNetV3-Large v2 (`pichanter_bg_fp16.tflite`, 7,15 MB)** yang dijalankan melalui **LiteRT (`flutter_litert`)**.

---

## 1. Fitur Utama & Privasi

- **100% Offline & Privasi Penuh**: Build release **tidak memiliki izin `android.permission.INTERNET`** di `AndroidManifest.xml` (diverifikasi dengan `aapt2 dump permissions` dan aturan `tools:node="remove"` pada `android/app/src/release/AndroidManifest.xml`). Foto dan hasil tidak pernah keluar dari HP.
- **Ambil & Pilih Foto (F1)**: Kamera atau galeri (JPG/PNG/WEBP/HEIC) dengan koreksi orientasi EXIF otomatis.
- **Hapus Background On-Device (F2)**: Berjalan di background worker isolate (`GPU (LiteRT)` dengan fallback otomatis `CPU (4 thread)` XNNPACK) lengkap dengan indikator tahapan dan tombol **Batal**.
- **Pratinjau & Bandingkan (F3)**: Pratinjau hasil di atas latar kotak-kotak (*checkerboard*) + interaksi **tahan untuk lihat foto asli**.
- **Ganti Warna Latar (F4)**: Transparan, Merah pas foto (`#D0021B`), Biru pas foto (`#0A4DA2`), Putih (`#FFFFFF`), atau **Warna bebas** (dialog pemilih warna HSV + kode Hex 6 digit).
- **Simpan Resolusi Asli ke Galeri (F5)**: Ekspor **PNG transparan**, **PNG berlatar warna**, atau **JPG berlatar warna** dalam resolusi asli foto ke album `Galeri › Pictures/Pichanter`.
- **Bagikan Hasil (F6)**: Bagikan langsung ke WhatsApp, Google Drive, atau aplikasi lain melalui lembar bagikan Android (`share_plus`).
- **Riwayat Lokal SQLite (F7)**: Setiap hasil otomatis disimpan ke database SQLite lokal (`pichanter_history.db`) dan penyimpanan internal aplikasi; ketuk kartu untuk membuka ulang & mengedit latar/tepi tanpa inferensi AI ulang, atau tahan kartu untuk menghapus.
- **Pengaturan Tepi & Ambang Mask (F8)**: Slider **Kehalusan tepi (Feather `0,0–5,0 px`)** dan **Potong tegas (Ambang mask `0,10–0,90`)** yang memperbarui mask secara langsung tanpa menjalankan ulang model AI.
- **Tentang Model & Privasi (F11)**: Layar informasi spesifikasi model v2, status akselerator LiteRT aktif, hasil uji paritas P1/P2, tabel metrik data test (569 gambar), dan hasil uji ketahanan.

---

## 2. Arsitektur 4 Lapisan & Struktur Folder

Seluruh kode aplikasi berada di dalam folder `Android_Flutter/` (terpisah dari backend/PWA UTS):

```text
Android_Flutter/
├── pubspec.yaml
├── pubspec.lock
├── README.md
├── assets/
│   └── models/
│       └── pichanter_bg_fp16.tflite      # Model U-Net + MobileNetV3-Large v2 (384x384, FP16, 7,15 MB)
├── dist/
│   └── pichanter-mobile-arm64-release.apk # APK Release produksi (arm64-v8a)
├── lib/
│   ├── main.dart                          # Entry point, MultiProvider, tema Material 3 Light/Dark (#5B3FE6)
│   ├── screens/                           # Lapisan 1 — UI (4 layar utama + Tentang Model)
│   │   ├── beranda_screen.dart
│   │   ├── proses_screen.dart
│   │   ├── hasil_screen.dart
│   │   ├── riwayat_screen.dart
│   │   └── tentang_screen.dart
│   ├── state/                             # Lapisan 2 — State Management (Provider / ChangeNotifier)
│   │   ├── editor_controller.dart
│   │   └── history_controller.dart
│   ├── services/                          # Lapisan 3 & 4 — Pipeline Gambar, Runtime LiteRT, Penyimpanan & Share
│   │   ├── model_service.dart             # Worker isolate LiteRT: CompiledModel (GPU) + fallback Interpreter (CPU)
│   │   ├── image_service.dart             # Pipeline fixed-point identik pichanter_bg.py (Pillow BILINEAR + GaussianBlur)
│   │   ├── storage_service.dart           # Simpan Galeri (gal) + Riwayat SQLite (sqflite)
│   │   ├── share_service.dart             # Bagikan file hasil (share_plus)
│   │   ├── parity_service.dart            # Runner batch uji paritas P1 di perangkat
│   │   └── benchmark_service.dart         # Runner uji P2 (GPU vs CPU), L1 (10x 12 MP), dan M1 (5x 12 MP)
│   └── widgets/
│       └── checkerboard.dart              # Latar kotak-kotak & dialog pemilih warna bebas
├── test/
│   ├── widget_test.dart                   # Unit test pipeline ImageService (preprocess, refine, export PNG/JPG)
│   └── parity/                            # Foto uji, mask referensi Python (refs/), dan hasil perangkat (device_out/)
│       └── README.md
└── tools/
    ├── generate_parity_refs.py            # Pembuat mask referensi dari pichanter_bg.py
    └── compare_parity.py                  # Pembanding Dice & MAD mask Android vs Python
```

---

## 3. Versi Paket Terkunci (`pubspec.lock`)

| Kebutuhan | Paket | Versi Terkunci | Catatan |
|---|---|---|---|
| SDK | Flutter / Dart | `3.50.1` / `3.14.0` | Channel `stable`, Android `minSdk = 24` |
| Inferensi AI | `flutter_litert` | `4.2.0` | `CompiledModel` (GPU) + `Interpreter` (CPU XNNPACK) di worker isolate |
| Olah gambar | `image` | `4.13.1` | Decode JPG/PNG/WEBP, EXIF transpose, encode PNG/JPG |
| Ambil foto | `image_picker` | `1.2.4` | Kamera & galeri |
| Database lokal | `sqflite` | `2.4.6` | Metadata riwayat lokal (`pichanter_history.db`) |
| Path penyimpanan | `path_provider` / `path` | `2.1.6` / `1.9.1` | Direktori dokumen & cache aplikasi |
| Simpan ke Galeri | `gal` | `3.0.1` | MediaStore album `Pictures/Pichanter` |
| Bagikan hasil | `share_plus` | `13.3.1` | `SharePlus.instance.share` (`ACTION_SEND`) |
| State management | `provider` | `6.1.5+1` | `ChangeNotifierProvider` untuk `EditorController` & `HistoryController` |
| Komponen UI | `material_ui` | `1.1.0` | Material 3 (`useMaterial3: true`) |

---

## 4. Hasil Pengujian (P1, P2, L1/L2, M1, F1–F3)

### P1 — Paritas Mask Android vs Python (`pichanter_bg.py`)
Target PRD: **Dice antar-mask ≥ 0,99**.
Pipeline Dart mengimplementasikan filter bilinear anti-aliased (*tent/triangle filter*) dan separable Gaussian blur (`sigma = 1,5`) dengan aritmetika fixed-point (`1 << 14`) yang meniru `PIL.Image.BILINEAR` dan `PIL.ImageFilter.GaussianBlur(1.5)`:

| Foto Uji | Resolusi (EXIF) | Dice 384 | Dice Full | **Dice Alpha (blur 1,5)** | MAD | Status |
|---|---:|---:|---:|---:|---:|---|
| `01_office_12mp.jpg` | `4032×3024` | `0,99836` | `0,99833` | **`0,99833`** | `0,00047` | **LULUS** |
| `02_group_portrait.png` | `1447×1087` | `0,99982` | `0,99986` | **`0,99979`** | `0,00034` | **LULUS** |
| `03_infografis.jpg` | `2400×1792` | `0,99690` | `0,99704` | **`0,99705`** | `0,00106` | **LULUS** |
| `04_exif_orient6.jpg` | `900×1200` | `0,99686` | `0,99684` | **`0,99683`** | `0,00118` | **LULUS** |
| `05_exif_orient8.jpg` | `900×1200` | `0,99756` | `0,99742` | **`0,99737`** | `0,00076` | **LULUS** |
| **Rata-rata** | — | **`0,99790`** | **`0,99790`** | **`0,99787`** *(min `0,99683`)* | **`0,00076`** | **LULUS (≥ 0,99)** |

### P2 — Paritas Akselerator (`CompiledModel` GPU vs `Interpreter` CPU)
- Saat aplikasi dimulai, `ModelService` secara otomatis menguji `CompiledModel` (`CompiledModelConfig.gpuWithCpuFallback(precision: Precision.fp32)`) terhadap `Interpreter` (CPU) di dalam worker isolate.
- Hasil di emulator (`Medium_Phone_API_36.1`): **`Dice = 1,00000`** (`max_abs_diff = 0,00018`, `MAD = 0,00000`), waktu inferensi **GPU `15,4–18,2 ms`** vs **CPU `165,8–205,6 ms`** (~10× lebih cepat).
- Bila pada HP tertentu driver GPU tidak didukung atau menghasilkan `Dice < 0,99`, `ModelService` otomatis menutup `CompiledModel` dan memakai `Interpreter` (CPU 4 thread).

### L1/L2 — Latensi 10× Foto 12 MP (`4032×3024`) & M1 — Memori Puncak
Dari `test/parity/device_out/benchmark_stage4.json` (10× pemrosesan foto 12 MP berturut-turut):
- **Pra-proses rata-rata**: `870,1–974,2 ms`
- **Inferensi AI rata-rata**: **`18,2 ms`** (GPU) / **`194,6 ms`** (CPU 4 thread)
- **Pasca-proses rata-rata** (upscale 12 MP + blur 1,5 px + pratinjau): **`460,5–503,1 ms`**
- **Total rata-rata per foto 12 MP**: **`1.511,5 ms` (`1,51 detik`)** pada GPU dan **`1.535,4 ms` (`1,54 detik`)** pada CPU (run tercepat **`1.400,5 ms`**, memenuhi target **≤ 2 detik**).
- **Memori puncak (M1)**: **`338,0 MB` PSS** (`start 275,4 MB` → `peak 338,0 MB` → `end 336,3 MB`, memenuhi target **≤ 400 MB**, 0 crash, 0 memory leak).

---

## 5. Ukuran APK Release, Audit Izin Offline (F1) & Cara Mem-build

### Hasil Build Release (`dist/`)
Dibangun dengan `flutter build apk --release --split-per-abi` agar pustaka native LiteRT (`libLiteRt.so` & `libLiteRtClGlAccelerator.so`) hanya menyertakan ABI target:

| File APK Release (`dist/`) | ABI Target | Ukuran File | Target PRD | Status |
|---|---|---:|---:|---|
| `dist/pichanter-mobile-arm64-release.apk` | `arm64-v8a` (HP Android modern) | **`33,43 MB`** (`35.056.900` byte) | `≤ 40 MB` | **LULUS** |
| `dist/pichanter-mobile-armeabi-v7a-release.apk` | `armeabi-v7a` (ARM 32-bit) | **`26,69 MB`** (`27.989.106` byte) | `≤ 40 MB` | **LULUS** |
| `dist/pichanter-mobile-x64-release.apk` | `x86_64` (Emulator Android) | **`37,43 MB`** (`39.251.535` byte) | `≤ 40 MB` | **LULUS** |

### Audit Izin `AndroidManifest.xml` (`aapt2 dump permissions`) & Uji Mode Pesawat (F1)
```text
package: id.my.jalulabs.pichanter_mobile
uses-permission: name='android.permission.WRITE_EXTERNAL_STORAGE' maxSdkVersion='29'
permission: id.my.jalulabs.pichanter_mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
uses-permission: name='id.my.jalulabs.pichanter_mobile.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
```
- **Tidak ada `android.permission.INTERNET`** maupun izin jaringan lain di APK release.
- **Uji Mode Pesawat (F1)**: APK Release diinstal bersih dan diuji dengan `cmd connectivity airplane-mode enable` (100% offline) — pemrosesan foto 12 MP (`4032×3024`) selesai dalam **`1,45 detik`** di **`GPU (LiteRT)`** dan berhasil disimpan ke `Galeri › Pichanter/` serta database SQLite lokal tanpa error.

### Perintah Build & Verifikasi
Jalankan semua perintah dari dalam folder `Android_Flutter/`:

```powershell
# Analisis kode & jalankan unit test
flutter analyze
flutter test

# Jalankan di perangkat/emulator yang tersambung
flutter run

# Build APK Release per-ABI (arm64-v8a <= 40 MB, tanpa izin INTERNET)
flutter build apk --release --split-per-abi

# Audit izin manifest pada APK Release arm64-v8a
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.1.0\aapt2.exe" dump permissions build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

Untuk menjalankan ulang uji paritas **P1** (misalnya setelah menambahkan 20 foto uji ke `test/parity/photos/`), ikuti langkah di [`test/parity/README.md`](test/parity/README.md).
