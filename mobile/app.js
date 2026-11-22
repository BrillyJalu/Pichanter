/* Pichanter mobile (PWA) — Vue 3 tanpa tahap build.
 * Alur: pilih/ambil foto → diperkecil ke sisi terpanjang 1600 px → POST /api/jobs → hasil + ganti latar → unduh.
 */
const { createApp } = Vue;

const API = ((window.PICHANTER_CONFIG && window.PICHANTER_CONFIG.apiBase) || "").replace(/\/$/, "");
const MAX_MB = 10;
const MAX_SIDE = 1600;
const KEEP_ORIGINAL_MAX_BYTES = 3 * 1024 * 1024;
const ACCEPT = ["image/jpeg", "image/png", "image/webp"];
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
async function decodeImage(file) {
  if ("createImageBitmap" in window) {
    try {
      return await createImageBitmap(file, { imageOrientation: "from-image" });
    } catch (_) { /* lanjut ke cara lama */ }
  }
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } finally {
    URL.revokeObjectURL(url);
  }
}

function canvasToBlob(canvas, type, quality) {
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("toBlob gagal"))), type, quality));
}

/** Validasi + perkecil foto di HP agar hemat kuota (PRD: sisi terpanjang 1600 px). */
async function preparePhoto(file) {
  const ext = (file.name.split(".").pop() || "").toLowerCase();
  const typeOk = file.type ? ACCEPT.includes(file.type) : ["jpg", "jpeg", "png", "webp"].includes(ext);
  if (!typeOk) {
    throw { title: "Format tidak didukung", msg: `File ${file.name || ""} bukan JPG, PNG, atau WEBP.` };
  }
  if (file.size > MAX_MB * 1024 * 1024) {
    throw { title: "Foto terlalu besar", msg: `Ukuran foto ${formatBytes(file.size)} melebihi batas ${MAX_MB} MB.` };
  }

  let bmp;
  try {
    bmp = await decodeImage(file);
  } catch (_) {
    throw { title: "Foto tidak bisa dibaca", msg: "File rusak atau formatnya tidak dikenali. Coba foto lain." };
  }
  const origWidth = bmp.naturalWidth || bmp.width;
  const origHeight = bmp.naturalHeight || bmp.height;
  const scale = Math.min(1, MAX_SIDE / Math.max(origWidth, origHeight));
  const width = Math.round(origWidth * scale);
  const height = Math.round(origHeight * scale);

  let blob = file;
  if (scale < 1 || file.type !== "image/jpeg" || file.size > KEEP_ORIGINAL_MAX_BYTES) {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff"; // PNG transparan → latar putih sebelum jadi JPEG
    ctx.fillRect(0, 0, width, height);
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(bmp, 0, 0, width, height);
    blob = await canvasToBlob(canvas, "image/jpeg", 0.92);
  }
  if (bmp.close) bmp.close();

  return { blob, url: URL.createObjectURL(blob), width, height, origWidth, origHeight, resized: scale < 1 };
}

function apiError(status, body) {
  const detail = body && body.detail;
  const msg = typeof detail === "string" ? detail : "Terjadi kesalahan di server.";
  if (status === 413) return { title: "Foto terlalu besar", msg };
  if (status === 415) return { title: "Format tidak didukung", msg };
  if (status === 503) return { title: "Model belum siap", msg };
  if (status === 0) return OFFLINE;
  return { title: "Gagal memproses", msg };
}

/** Unggah dengan XHR agar progres unggah bisa ditampilkan. */
function uploadPhoto(blob, onProgress, onUploaded) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", API + "/api/jobs");
    xhr.timeout = 60000;
    xhr.responseType = "json";
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(Math.round((e.loaded / e.total) * 100));
    xhr.upload.onload = onUploaded;
    xhr.onload = () => (xhr.status === 201 ? resolve(xhr.response) : reject(apiError(xhr.status, xhr.response)));
    xhr.onerror = () => reject(OFFLINE);
    xhr.ontimeout = () => reject({ title: "Waktu habis", msg: "Server terlalu lama merespons. Coba lagi." });
    const fd = new FormData();
    fd.append("file", blob, blob.type === "image/jpeg" ? "foto.jpg" : blob.name || "foto");
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
      if (this.photo) URL.revokeObjectURL(this.photo.url);
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
        this.error = err.title ? err : { title: "Gagal membuka foto", msg: String(err) };
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
        this.clientMs = performance.now() - t0;
        this.job = job;
        this.bg = null;
        this.server.online = true;
        this.go("result", true); // tombol kembali dari hasil → beranda
      } catch (err) {
        this.error = err.title ? err : { title: "Gagal memproses", msg: String(err) };
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
    },

    // ----- pasang aplikasi
    async loadDownloads() {
      try {
        const r = await fetch(API + "/api/downloads", { cache: "no-store" });
        if (r.ok) this.apk = (await r.json()).apk;
      } catch (_) { /* menu APK cukup disembunyikan */ }
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
