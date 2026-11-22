# Folder unduhan

`pichanter.apk` dan `pichanter.apk.json` di sini diisi otomatis oleh `npm run apk` (folder `android-app/`)
untuk build produksi (HTTPS). Backend menyajikannya di `/download/pichanter.apk`, dan info versinya di
`GET /api/downloads`, untuk menu **Unduh Aplikasi** di dashboard dan aplikasi mobile.

File APK tidak di-commit (lihat `.gitignore`); `deploy/deploy.sh` ikut mengirimnya ke server.
