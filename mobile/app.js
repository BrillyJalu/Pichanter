/* Pichanter mobile (PWA) — Vue 3 tanpa tahap build.
 * Alur: pilih/ambil foto → diperkecil ke sisi terpanjang 1600 px → POST /api/jobs → hasil + ganti latar → unduh.
 */
const { createApp } = Vue;

const API = ((window.PICHANTER_CONFIG && window.PICHANTER_CONFIG.apiBase) || "").replace(/\/$/, "");
const MAX_MB = 25;            // batas server untuk file yang dikirim apa adanya
const MAX_INPUT_MB = 40;      // batas file yang diperkecil dulu di HP
const MAX_SIDE = 1600;
const KEEP_ORIGINAL_MAX_BYTES = 3 * 1024 * 1024;
const IMAGE_EXT = ["jpg", "jpeg", "jfif", "png", "webp", "heic", "heif", "avif", "bmp", "gif", "tif", "tiff", "svg"];
const HEALTH_INTERVAL_MS = 15000;

const COLORS = [
  { id: "none", label: "Transparan", hex: null },
  { id: "red", label: "Merah", hex: "D0021B" },
  { id: "blue", label: "Biru", hex: "0A4DA2" },
  { id: "white", label: "Putih", hex: "FFFFFF" },
];

const OFFLINE = { title: "Server offline", msg: "Tidak bisa terhubung ke server Pichanter. Periksa koneksi internet lalu coba lagi." };

// ---------------------------------------------------------------- pasang aplikasi
const UA = navigator.userAgent;
const IS_ANDROID = /Android/i.test(UA);
// APK menambahkan "PichanterAndroid/<versi>" ke user-agent sejak v1.1; APK v1.0 belum.
const UA_APK_VERSION = (UA.match(/PichanterAndroid\/([\d.]+)/) || [])[1] || null;
/** "1.10 (3)" > "1.9" ? */
function newerVersion(a, b) {
  const pa = String(a).split(" ")[0].split(".").map(Number), pb = String(b).split(" ")[0].split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) > (pb[i] || 0);
  }
  return false;
}
const IS_IOS = /iPhone|iPad|iPod/.test(UA) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const isStandalone = () =>
  window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true;

// Chrome/Edge mengirim event ini sekali, bisa sebelum Vue siap; simpan untuk tombol "Pasang di layar utama".
let installEvent = null;
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault();
  installEvent = e;
});

// ---------------------------------------------------------------- utilitas gambar
/** Dekode di HP. Mengembalikan { src, done } atau melempar bila browser tidak mengenal formatnya (mis. HEIC). */
async function decodeImage(file, svg) {
  if (!svg && "createImageBitmap" in window) {
    try {
      const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
      return { src: bmp, done: () => bmp.close && bmp.close() };
    } catch (_) { /* lanjut ke cara lama */ }
  }
  const url = URL.createObjectURL(file);
  const img = new Image();
  img.src = url;
  try {
    await img.decode();
  } catch (e) {
    URL.revokeObjectURL(url);
    throw e;
  }
  return { src: img, done: () => URL.revokeObjectURL(url) };
}

function canvasToBlob(canvas, type, quality) {
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("toBlob gagal"))), type, quality));
}

const tooBig = (file, limit) =>
  ({ title: "Foto terlalu besar", msg: `Ukuran foto ${formatBytes(file.size)} melebihi batas ${limit} MB.` });
const errName = (e) => String((e && (e.name || e.message)) || e || "?");

/** Baca beberapa byte awal: memastikan file bisa dibuka (izin, foto di cloud) dan mengenali formatnya. */
async function sniff(file) {
  const b = new Uint8Array(await file.slice(0, 64).arrayBuffer());
  const s = (i, n) => String.fromCharCode.apply(null, b.subarray(i, i + n));
  if (b[0] === 0xff && b[1] === 0xd8) return "JPG";
  if (s(1, 3) === "PNG") return "PNG";
  if (s(0, 4) === "RIFF" && s(8, 4) === "WEBP") return "WEBP";
  if (s(4, 4) === "ftyp") return /^avi[fs]/.test(s(8, 4)) ? "AVIF" : "HEIC";
  if (s(0, 4) === "GIF8") return "GIF";
  if (s(0, 2) === "BM") return "BMP";
  if (s(0, 4) === "II*\0" || s(0, 4) === "MM\0*") return "TIFF";
  if (/<svg|<\?xml/i.test(s(0, 64))) return "SVG";
  return "";
}

/**
 * Siapkan foto untuk diunggah. Semua format gambar diterima:
 * - bila browser HP bisa membacanya (JPG, PNG, WEBP, AVIF, BMP, GIF, SVG, ...), foto diperkecil ke sisi
 *   terpanjang 1600 px lalu dikirim sebagai JPEG (PRD: hemat kuota);
 * - bila ada langkah yang gagal di HP (format HEIC/TIFF, foto 50-200 MP yang kehabisan memori, WebView lama),
 *   file asli dikirim apa adanya dan server yang membaca, memutar, dan memperkecilnya.
 */
async function preparePhoto(file) {
  const ext = (file.name.split(".").pop() || "").toLowerCase();
  const info = `${file.type || "tipe ?"} · ${formatBytes(file.size)}`;
  const cannotOpen = (detail) => ({
    title: "Foto tidak bisa dibuka",
    msg: "File tidak bisa dibaca dari penyimpanan HP. Bila foto masih di cloud (Google Foto, OneDrive), unduh dulu ke HP lalu coba lagi, atau pakai Ambil Foto.",
    detail,
  });
  if (!file.size) throw cannotOpen(info + " · file kosong");

  let kind;
  try {
    kind = await sniff(file);
  } catch (e) {
    throw cannotOpen(`${info} · baca: ${errName(e)}`);
  }
  const svg = kind === "SVG" || file.type === "image/svg+xml" || ext === "svg";
  if (!kind && !(file.type || "").startsWith("image/") && !IMAGE_EXT.includes(ext)) {
    throw { title: "Bukan file gambar", msg: `${file.name || "File ini"} bukan foto. Pilih file gambar (JPG, PNG, HEIC, dll.).`, detail: info };
  }
  if (file.size > MAX_INPUT_MB * 1024 * 1024) throw tooBig(file, MAX_INPUT_MB);
  const label = kind || ext.toUpperCase() || "foto";

  // Cadangan: kirim file asli, server yang mengolah.
  const viaServer = (reason) => {
    if (svg) throw { title: "SVG tidak bisa dibaca", msg: "File SVG rusak atau memuat isi yang tidak didukung. Coba file lain.", detail: `${info} · ${reason}` };
    if (file.size > MAX_MB * 1024 * 1024) throw tooBig(file, MAX_MB);
    console.warn("Pichanter: foto diproses di server", label, info, reason);
    return { blob: file, url: null, serverConvert: true, label, reason, width: null, height: null, origWidth: null, origHeight: null, resized: false };
  };

  let dec;
  try {
    dec = await decodeImage(file, svg);
  } catch (e) {
    return viaServer("dekode: " + errName(e));
  }
  try {
    let origWidth = dec.src.naturalWidth || dec.src.width;
    let origHeight = dec.src.naturalHeight || dec.src.height;
    if (!origWidth || !origHeight) {
      if (!svg) throw new Error("ukuran 0");
      origWidth = origHeight = MAX_SIDE; // SVG tanpa ukuran
    }
    // SVG berupa vektor: selalu digambar dengan sisi terpanjang 1600 px.
    const scale = svg ? MAX_SIDE / Math.max(origWidth, origHeight) : Math.min(1, MAX_SIDE / Math.max(origWidth, origHeight));
    const width = Math.max(1, Math.round(origWidth * scale));
    const height = Math.max(1, Math.round(origHeight * scale));

    let blob = file;
    if (svg || scale < 1 || file.type !== "image/jpeg" || file.size > KEEP_ORIGINAL_MAX_BYTES) {
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext("2d");
      if (!ctx) throw new Error("canvas tidak tersedia");
      ctx.fillStyle = "#fff"; // gambar transparan → latar putih sebelum jadi JPEG
      ctx.fillRect(0, 0, width, height);
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(dec.src, 0, 0, width, height);
      blob = await canvasToBlob(canvas, "image/jpeg", 0.92);
      if (!blob.size) throw new Error("hasil kosong");
    }
    return { blob, url: URL.createObjectURL(blob), width, height, origWidth, origHeight, resized: !svg && scale < 1 };
  } catch (e) {
    return viaServer("perkecil: " + errName(e));
  } finally {
    dec.done();
  }
}

function apiError(status, body) {
  const detail = body && body.detail;
  const msg = typeof detail === "string" ? detail : "Terjadi kesalahan di server.";
  if (status === 413) return { title: "Foto terlalu besar", msg };
  if (status === 415) return { title: "Format tidak didukung", msg };
  if (status === 503) return { title: "Model belum siap", msg };
  if (status === 0) return OFFLINE;
  return { title: "Gagal memproses", msg, detail: "HTTP " + status };
}

/** Unggah dengan XHR agar progres unggah bisa ditampilkan. */
function uploadPhoto(blob, onProgress, onUploaded) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", API + "/api/jobs");
    xhr.timeout = 60000 + Math.round((blob.size / 1048576) * 10000); // + 10 dtk per MB untuk sinyal lemah
    xhr.responseType = "json";
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(Math.round((e.loaded / e.total) * 100));
    xhr.upload.onload = onUploaded;
    xhr.onload = () => (xhr.status === 201 ? resolve(xhr.response) : reject(apiError(xhr.status, xhr.response)));
    xhr.onerror = () => reject(OFFLINE);
    xhr.ontimeout = () => reject({ title: "Waktu habis", msg: "Server terlalu lama merespons. Coba lagi." });
    const fd = new FormData();
    fd.append("file", blob, blob.name || (blob.type === "image/jpeg" ? "foto.jpg" : "foto"));
    fd.append("source", "mobile");
    xhr.send(fd);
  });
}

function preload(src) {
  const img = new Image();
  img.src = src;
  return img.decode().catch(() => {});
}

function formatBytes(n) {
  if (n < 1024 * 1024) return Math.max(1, Math.round(n / 1024)) + " KB";
  return (n / 1024 / 1024).toFixed(1).replace(".", ",") + " MB";
}

function formatMs(ms) {
  if (ms == null) return "–";
  return ms < 1000 ? Math.round(ms) + " ms" : (ms / 1000).toFixed(1).replace(".", ",") + " dtk";
}

// ---------------------------------------------------------------- aplikasi
const app = createApp({
  data() {
    return {
      screen: "home",
      photo: null,
      job: null,
      preparing: false,
      busy: false,
      phase: "upload",
      progress: 0,
      clientMs: null,
      error: null,
      bg: null,
      customColor: "#2E7D32",
      comparing: false,
      saving: false,
      canShare: false,
      toast: "",
      server: { online: null, ready: false, placeholder: false, version: null },
      colors: COLORS,
      // pasang aplikasi
      isNative: false,
      isIOS: IS_IOS,
      standalone: isStandalone(),
      installHelp: false,
      apk: null,
      appVersion: UA_APK_VERSION, // versi APK bila berjalan di dalam APK
    };
  },

  computed: {
    status() {
      const s = this.server;
      if (s.online === null) return { kind: "checking", label: "Memeriksa…" };
      if (!s.online) return { kind: "offline", label: "Server offline" };
      if (!s.ready) return { kind: "offline", label: "Model belum siap" };
      if (s.placeholder) return { kind: "warn", label: "Model sementara" };
      return { kind: "online", label: "Online" };
    },
    resultSrc() {
      return this.job ? API + this.job.result_url : "";
    },
    isCustom() {
      return this.bg !== null && !COLORS.some((c) => c.hex === this.bg);
    },
    // PWA: tawarkan bila belum terpasang dan tidak sedang di dalam APK.
    showInstall() {
      return !this.isNative && !this.standalone;
    },
    // APK: hanya untuk HP Android (termasuk dari PWA yang sudah terpasang), tidak di dalam APK.
    showApk() {
      return !this.isNative && IS_ANDROID && !!this.apk;
    },
    apkHref() {
      return this.apk ? API + this.apk.url : "";
    },
    // Di dalam APK: tawarkan APK yang lebih baru dari server.
    apkUpdate() {
      return this.isNative && !!this.apk && !!this.appVersion && newerVersion(this.apk.version, this.appVersion);
    },
    apkSize() {
      return this.apk ? String(this.apk.size_mb).replace(".", ",") + " MB" : "";
    },
  },

  mounted() {
    history.replaceState({ screen: "home" }, "");
    window.addEventListener("popstate", this.onPopState);
    window.addEventListener("online", this.checkHealth);
    window.addEventListener("offline", this.markOffline);
    document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && this.checkHealth());
    this.checkHealth();
    this.healthTimer = setInterval(this.checkHealth, HEALTH_INTERVAL_MS);

    this.detectShare();
    setTimeout(this.detectShare, 1000); // bridge Capacitor bisa tersedia sedikit setelah halaman dimuat

    this.loadDownloads();
    window.addEventListener("appinstalled", () => {
      installEvent = null;
      this.standalone = true; // sembunyikan tombol pasang di tab browser ini juga
      this.showToast("Pichanter terpasang di layar utama");
    });
    window.matchMedia("(display-mode: standalone)").addEventListener?.("change", () => (this.standalone = isStandalone()));
  },

  methods: {
    formatBytes,
    formatMs,

    // ----- status server
    async checkHealth() {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 5000);
      try {
        const r = await fetch(API + "/api/health", { cache: "no-store", signal: ctrl.signal });
        const j = await r.json();
        this.server = { online: true, ready: !!j.model_loaded, placeholder: !!j.placeholder, version: j.model_version };
      } catch (_) {
        this.markOffline();
      } finally {
        clearTimeout(t);
      }
    },
    markOffline() {
      this.server = { ...this.server, online: false };
    },

    // ----- navigasi (tombol kembali Android ikut bekerja)
    go(screen, replace = false) {
      history[replace ? "replaceState" : "pushState"]({ screen }, "");
      this.screen = screen;
      window.scrollTo(0, 0);
    },
    goHome() {
      if (this.busy) return;
      if (this.screen !== "home") history.back();
    },
    onPopState(e) {
      this.installHelp = false;
      if (this.busy) { history.pushState({ screen: this.screen }, ""); return; }
      const target = (e.state && e.state.screen) || "home";
      this.screen = target === "result" && !this.job ? "home" : target;
      if (this.screen === "home") this.reset();
    },
    reset() {
      if (this.photo && this.photo.url && this.photo.url.startsWith("blob:")) URL.revokeObjectURL(this.photo.url);
      this.photo = null;
      this.job = null;
      this.bg = null;
      this.comparing = false;
    },

    // ----- pilih foto
    async onFile(e) {
      const file = e.target.files && e.target.files[0];
      e.target.value = "";
      if (!file) return;
      this.error = null;
      this.preparing = true;
      try {
        this.reset();
        this.photo = await preparePhoto(file);
        this.go("preview");
      } catch (err) {
        this.error = this.withVersion(err.title ? err : { title: "Gagal membuka foto", msg: String(err) });
      } finally {
        this.preparing = false;
      }
    },

    // ----- hapus background
    async process() {
      if (!this.photo || this.busy) return;
      this.error = null;
      this.busy = true;
      this.phase = "upload";
      this.progress = 0;
      const t0 = performance.now();
      try {
        const job = await uploadPhoto(this.photo.blob, (p) => (this.progress = p), () => (this.phase = "process"));
        await preload(API + job.result_url);
        // HEIC dkk. tidak bisa ditampilkan di HP: pakai foto asli yang sudah dikonversi server (JPG/PNG).
        if (!this.photo.url) this.photo.url = API + job.original_url;
        this.clientMs = performance.now() - t0;
        this.job = job;
        this.bg = null;
        this.server.online = true;
        this.go("result", true); // tombol kembali dari hasil → beranda
      } catch (err) {
        this.error = this.withVersion(err.title ? err : { title: "Gagal memproses", msg: String(err) });
        if (err === OFFLINE) this.markOffline();
      } finally {
        this.busy = false;
      }
    },

    // ----- simpan / bagikan
    native() {
      return window.PichanterNative && window.PichanterNative.available() ? window.PichanterNative : null;
    },
    detectShare() {
      let web = false;
      try {
        const probe = new File([new Blob()], "x.png", { type: "image/png" });
        web = !!(navigator.canShare && navigator.canShare({ files: [probe] }));
      } catch (_) { /* tidak didukung */ }
      this.isNative = !!this.native();
      this.canShare = web || this.isNative;
      if (this.isNative && !this.appVersion) this.appVersion = "1.0"; // APK lama tanpa penanda versi
    },

    // ----- pasang aplikasi
    async loadDownloads() {
      try {
        const r = await fetch(API + "/api/downloads", { cache: "no-store" });
        if (r.ok) this.apk = (await r.json()).apk;
      } catch (_) { /* menu APK cukup disembunyikan */ }
    },
    // Detail teknis di pesan galat (membantu melacak masalah di HP tertentu).
    withVersion(err) {
      if (!err.detail || !this.appVersion) return err;
      return { ...err, detail: `${err.detail} · APK ${this.appVersion}` };
    },
    async openApkUpdate() {
      const url = new URL(API + this.apk.url, location.href);
      try {
        await window.PichanterNative.openExternal(url.href); // APK >= 1.1: buka di browser HP
      } catch (_) {
        // APK 1.0 belum punya openExternal. Alamat http:// (beda skema) dibuka Capacitor di browser HP.
        url.protocol = "http:";
        location.href = url.href;
      }
    },
    async installPwa() {
      if (!installEvent) {
        this.installHelp = true; // iPhone / browser tanpa prompt otomatis -> petunjuk manual
        return;
      }
      const ev = installEvent;
      try {
        await ev.prompt(); // dialog pasang bawaan Chrome/Edge (event hanya bisa dipakai sekali)
      } catch (_) {
        this.installHelp = true; // prompt ditolak browser -> petunjuk manual, event tetap disimpan
        return;
      }
      installEvent = null;
      try {
        const { outcome } = await ev.userChoice;
        if (outcome !== "accepted") this.showToast("Bisa dipasang kapan saja dari menu ini");
      } catch (_) { /* abaikan */ }
    },
    resultFileName() {
      return `pichanter_${this.job.id.slice(0, 8)}${this.bg ? "_" + this.bg : ""}.png`;
    },
    resultDownloadUrl() {
      const q = new URLSearchParams({ download: "true" });
      if (this.bg) q.set("bg", this.bg);
      return `${API}${this.job.result_url}?${q}`;
    },
    nativeError(err, title) {
      const msg = String((err && err.message) || err || "");
      if (/HTTP 404|HTTP 410/.test(msg)) return { title: "Hasil sudah dihapus", msg: "Hasil disimpan maksimal 24 jam. Proses ulang fotonya." };
      if (/Unable to resolve|timeout|connect|ENETUNREACH/i.test(msg)) return OFFLINE;
      return { title, msg: msg.replace(/^Gagal (menyimpan|membagikan): /, "") || "Coba lagi." };
    },
    async fetchResult() {
      const r = await fetch(this.resultDownloadUrl());
      if (!r.ok) {
        const body = await r.json().catch(() => ({}));
        throw r.status === 404 || r.status === 410
          ? { title: "Hasil sudah dihapus", msg: "Hasil disimpan maksimal 24 jam. Proses ulang fotonya." }
          : apiError(r.status, body);
      }
      return r.blob();
    },
    async download() {
      this.saving = true;
      this.error = null;
      const name = this.resultFileName();
      try {
        const nat = this.native();
        if (nat) {
          await nat.saveImage(this.resultDownloadUrl(), name); // APK: simpan ke Galeri
          this.showToast("Tersimpan di Galeri › Pictures/Pichanter");
        } else {
          const blob = await this.fetchResult();
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = name;
          document.body.appendChild(a);
          a.click();
          a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 10000);
          this.showToast("Tersimpan: " + name);
        }
      } catch (err) {
        this.error = err.title ? err : this.native() ? this.nativeError(err, "Gagal menyimpan") : OFFLINE;
      } finally {
        this.saving = false;
      }
    },
    async share() {
      this.saving = true;
      const nat = this.native();
      try {
        if (nat) {
          await nat.shareImage(this.resultDownloadUrl(), this.resultFileName());
        } else {
          const blob = await this.fetchResult();
          const file = new File([blob], this.resultFileName(), { type: "image/png" });
          await navigator.share({ files: [file], title: "Pichanter" });
        }
      } catch (err) {
        if (err && err.name === "AbortError") return;
        this.error = err.title ? err : nat ? this.nativeError(err, "Gagal membagikan") : { title: "Gagal membagikan", msg: String(err.message || err) };
      } finally {
        this.saving = false;
      }
    },

    showToast(msg) {
      this.toast = msg;
      clearTimeout(this.toastTimer);
      this.toastTimer = setTimeout(() => (this.toast = ""), 2800);
    },
  },
});
app.mount("#app");

if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost")) {
  window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
}
