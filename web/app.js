/* Pichanter dashboard web — Vue 3 tanpa tahap build.
 * Halaman: #/ (Riwayat), #/job/<id> (Detail), #/model (Info Model), #/unduh (Unduh Aplikasi).
 */
const { createApp } = Vue;

// PRD menargetkan hasil HP tampil di web <= 5 dtk; polling 3 dtk memberi ruang untuk waktu proses.
const POLL_MS = 3000;
const HEALTH_MS = 15000;
const HISTORY_LIMIT = 60;
const MAX_MB = 25;
const IMAGE_EXT = ["jpg", "jpeg", "jfif", "png", "webp", "heic", "heif", "avif", "bmp", "gif", "tif", "tiff", "svg"];

/** SVG tidak bisa dibaca server: gambar di browser menjadi PNG (sisi terpanjang 1600 px). */
async function rasterizeSvg(file) {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    let w = img.naturalWidth, h = img.naturalHeight;
    if (!w || !h) w = h = 1600;
    const scale = 1600 / Math.max(w, h);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(w * scale));
    canvas.height = Math.max(1, Math.round(h * scale));
    canvas.getContext("2d").drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((ok, fail) => canvas.toBlob((b) => (b ? ok(b) : fail(new Error("toBlob"))), "image/png"));
    return new File([blob], file.name.replace(/\.svg$/i, "") + ".png", { type: "image/png" });
  } finally {
    URL.revokeObjectURL(url);
  }
}

// Target dari PRD; angka paper dari Shahi & Li (2023).
const KPI_DEFS = [
  { key: "dice", label: "Dice", target: 0.95, dir: "min", paper: 0.9745 },
  { key: "iou", label: "IoU", target: 0.9, dir: "min", paper: null },
  { key: "mad", label: "MAD", target: 0.03, dir: "max", paper: 0.0182 },
];
const SECONDARY = [
  { key: "precision", label: "Precision" },
  { key: "recall", label: "Recall" },
  { key: "pixel_acc", label: "Pixel accuracy" },
  { key: "soft_dice", label: "Soft Dice" },
  { key: "mse", label: "MSE" },
];
const FIG_TITLES = {
  fig_01_contoh_data: "Contoh data dan mask",
  fig_02_distribusi_foreground: "Distribusi luas foreground",
  fig_03_augmentasi: "Contoh augmentasi",
  fig_04_kurva_training: "Kurva training",
  fig_05_distribusi_metrik: "Distribusi metrik test",
  fig_06_kasus_terbaik: "Kasus terbaik",
  fig_07_kasus_terburuk: "Kasus terburuk",
  fig_08_uji_ketahanan: "Uji ketahanan",
  fig_09_demo_hapus_background: "Demo hapus background",
  fig_10_uji_foto_sendiri: "Uji foto sendiri",
  fig_11_perbandingan_v0_v1: "Perbandingan v0 (Dice loss) vs v1 (BCE+Dice)",
  fig_12_perbandingan_v0_v2: "Perbandingan v0 (256 px) vs v2 (384 px)",
};
const COLORS = [
  { label: "Merah", hex: "D0021B" },
  { label: "Biru", hex: "0A4DA2" },
  { label: "Putih", hex: "FFFFFF" },
];

const nf = (d) => new Intl.NumberFormat("id-ID", { minimumFractionDigits: d, maximumFractionDigits: d });
const rtf = new Intl.RelativeTimeFormat("id", { numeric: "auto" });
const dtf = new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "medium" });
const df = new Intl.DateTimeFormat("id-ID", { dateStyle: "medium" });

function parseRoute() {
  const h = location.hash.replace(/^#/, "") || "/";
  const m = h.match(/^\/job\/([\w-]+)/);
  if (m) return { name: "job", id: m[1] };
  if (h.startsWith("/model")) return { name: "model" };
  if (h.startsWith("/unduh")) return { name: "unduh" };
  return { name: "history" };
}

async function getJSON(url) {
  const r = await fetch(url, { cache: "no-store" });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(body.detail || r.statusText), { status: r.status });
  return body;
}

createApp({
  data() {
    return {
      route: parseRoute(),
      server: { online: null, ready: false, placeholder: false },
      now: Date.now(),
      // riwayat
      jobs: [],
      filter: "all",
      counts: { all: 0, mobile: 0, web: 0 },
      historyOk: true,
      historyLoaded: false,
      freshIds: new Set(),
      knownIds: null,
      // unggah
      dragOver: false,
      uploading: false,
      uploadPhase: "upload",
      uploadProgress: 0,
      error: null,
      // detail
      job: null,
      jobError: null,
      detailBg: "D0021B",
      colors: COLORS,
      // model
      model: null,
      modelError: null,
      // unduh aplikasi
      downloads: null,
      downloadsError: null,
      pwaTab: /iPhone|iPad|iPod/.test(navigator.userAgent) ? "ios" : /Android/.test(navigator.userAgent) ? "android" : "laptop",
      pwaTabs: [
        { id: "android", label: "Android" },
        { id: "ios", label: "iPhone" },
        { id: "laptop", label: "Laptop" },
      ],
      // dialog
      qrOpen: false,
      lightbox: null,
      sourceFilters: [
        { id: "all", label: "Semua" },
        { id: "mobile", label: "Mobile" },
        { id: "web", label: "Web" },
      ],
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
    ev() {
      return this.model && this.model.evaluasi;
    },
    kpis() {
      const mean = (this.ev && this.ev.test_mean) || {};
      return KPI_DEFS.map((d) => {
        const value = mean[d.key];
        const pass = value != null && (d.dir === "min" ? value >= d.target : value <= d.target);
        return { ...d, value, pass, targetText: (d.dir === "min" ? "≥ " : "≤ ") + nf(2).format(d.target) };
      });
    },
    secondaryMetrics() {
      const mean = (this.ev && this.ev.test_mean) || {};
      return SECONDARY.map((m) => ({ ...m, value: mean[m.key] })).filter((m) => m.value != null);
    },
    worstRobust() {
      const rows = (this.ev && this.ev.uji_ketahanan) || [];
      return rows.reduce((w, r) => (!w || r.penurunan_dice > w.penurunan_dice ? r : w), null);
    },
    mobileUrl() {
      return location.origin + "/app/";
    },
    qrSvg() {
      return this.qrOpen ? this.qrFor(this.mobileUrl) : "";
    },
    apkAbsUrl() {
      return this.downloads && this.downloads.apk ? location.origin + this.downloads.apk.url : "";
    },
  },

  watch: {
    route: { handler: "onRoute", immediate: false },
  },

  mounted() {
    window.addEventListener("hashchange", () => (this.route = parseRoute()));
    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { this.qrOpen = false; this.lightbox = null; }
    });
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") { this.checkHealth(); this.tick(); }
    });
    this.checkHealth();
    setInterval(this.checkHealth, HEALTH_MS);
    setInterval(this.tick, POLL_MS);
    setInterval(() => (this.now = Date.now()), 30000);
    this.onRoute();
  },

  methods: {
    // ----- format
    fmtNum(v, d) { return v == null ? "–" : nf(d).format(v); },
    fmtInt(v) { return v == null ? "–" : nf(0).format(v); },
    fmtCompact(v) {
      if (v == null) return "–";
      if (v >= 1e6) return nf(2).format(v / 1e6) + " jt";
      if (v >= 1e3) return nf(0).format(v / 1e3) + " rb";
      return nf(0).format(v);
    },
    fmtMs(ms) {
      if (ms == null) return "–";
      return ms < 1000 ? nf(ms < 10 ? 1 : 0).format(ms) + " ms" : nf(2).format(ms / 1000) + " dtk";
    },
    fmtDateTime(iso) { return iso ? dtf.format(new Date(iso)) : "–"; },
    fmtDate(iso) { return iso ? df.format(new Date(iso)) : "–"; },
    qrFor(text, cellSize = 6) {
      if (!text || typeof qrcode !== "function") return "";
      const qr = qrcode(0, "M");
      qr.addData(text);
      qr.make();
      return qr.createSvgTag({ cellSize, margin: 2, scalable: true });
    },
    fmtRelative(iso) {
      const s = (new Date(iso).getTime() - this.now) / 1000;
      const a = Math.abs(s);
      if (a < 45) return s < 0 ? "baru saja" : "sebentar lagi";
      if (a < 3600) return rtf.format(Math.round(s / 60), "minute");
      if (a < 86400) return rtf.format(Math.round(s / 3600), "hour");
      return rtf.format(Math.round(s / 86400), "day");
    },
    figTitle(name) {
      const stem = name.replace(/\.png$/, "");
      return FIG_TITLES[stem] || stem.replace(/^fig_\d+_/, "").replace(/_/g, " ");
    },

    // ----- status & polling
    async checkHealth() {
      try {
        const j = await getJSON("/api/health");
        this.server = { online: true, ready: !!j.model_loaded, placeholder: !!j.placeholder };
      } catch (_) {
        this.server = { ...this.server, online: false };
      }
    },
    tick() {
      if (document.visibilityState !== "visible") return;
      this.now = Date.now();
      if (this.route.name === "history") this.loadHistory();
    },
    onRoute() {
      window.scrollTo(0, 0);
      this.error = null;
      if (this.route.name === "history") this.loadHistory();
      if (this.route.name === "job") this.loadJob(this.route.id);
      if (this.route.name === "model") this.loadModel();
      if (this.route.name === "unduh") this.loadDownloads();
    },

    // ----- riwayat
    setFilter(id) {
      this.filter = id;
      this.knownIds = null; // jangan sorot kartu lama sebagai "baru" saat ganti filter
      this.loadHistory();
    },
    async loadHistory() {
      try {
        const all = await getJSON(`/api/jobs?limit=${HISTORY_LIMIT}`);
        this.counts = {
          all: all.length,
          mobile: all.filter((j) => j.source === "mobile").length,
          web: all.filter((j) => j.source === "web").length,
        };
        const list = this.filter === "all" ? all : all.filter((j) => j.source === this.filter);
        if (this.knownIds) {
          const fresh = list.filter((j) => !this.knownIds.has(j.id)).map((j) => j.id);
          if (fresh.length) {
            this.freshIds = new Set([...this.freshIds, ...fresh]);
            setTimeout(() => {
              this.freshIds = new Set([...this.freshIds].filter((id) => !fresh.includes(id)));
            }, 4000);
          }
        }
        this.knownIds = new Set(list.map((j) => j.id));
        this.jobs = list;
        this.historyOk = true;
      } catch (_) {
        this.historyOk = false;
      } finally {
        this.historyLoaded = true;
      }
    },

    // ----- unggah dari web (F10)
    onPick(e) {
      const f = e.target.files && e.target.files[0];
      e.target.value = "";
      if (f) this.upload(f);
    },
    onDrop(e) {
      this.dragOver = false;
      const f = e.dataTransfer.files && e.dataTransfer.files[0];
      if (f) this.upload(f);
    },
    async upload(file) {
      if (this.uploading) return;
      this.error = null;
      const ext = (file.name.split(".").pop() || "").toLowerCase();
      if (file.type && !file.type.startsWith("image/") && !IMAGE_EXT.includes(ext)) {
        this.error = { title: "Bukan file gambar.", msg: `${file.name} bukan foto. Pilih JPG, PNG, HEIC, WEBP, atau format gambar lain.` };
        return;
      }
      if (file.type === "image/svg+xml" || ext === "svg") {
        try {
          file = await rasterizeSvg(file);
        } catch (_) {
          this.error = { title: "SVG tidak bisa dibaca.", msg: "File SVG rusak atau memuat isi yang tidak didukung." };
          return;
        }
      }
      if (file.size > MAX_MB * 1024 * 1024) {
        this.error = { title: "Foto terlalu besar.", msg: `Batas ukuran ${MAX_MB} MB.` };
        return;
      }
      this.uploading = true;
      this.uploadPhase = "upload";
      this.uploadProgress = 0;
      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/api/jobs");
      xhr.responseType = "json";
      xhr.timeout = 60000;
      xhr.upload.onprogress = (e) => e.lengthComputable && (this.uploadProgress = Math.round((e.loaded / e.total) * 100));
      xhr.upload.onload = () => (this.uploadPhase = "process");
      xhr.onload = () => {
        this.uploading = false;
        if (xhr.status === 201) {
          location.hash = "#/job/" + xhr.response.id;
        } else {
          const d = xhr.response && xhr.response.detail;
          this.error = { title: "Gagal memproses.", msg: typeof d === "string" ? d : "Terjadi kesalahan di server." };
        }
      };
      xhr.onerror = xhr.ontimeout = () => {
        this.uploading = false;
        this.error = { title: "Server offline.", msg: "Tidak bisa terhubung ke server Pichanter." };
      };
      const fd = new FormData();
      fd.append("file", file, file.name);
      fd.append("source", "web");
      xhr.send(fd);
    },

    // ----- detail
    async loadJob(id) {
      this.job = null;
      this.jobError = null;
      try {
        this.job = await getJSON(`/api/jobs/${encodeURIComponent(id)}`);
      } catch (e) {
        this.jobError = e.status === 404 ? "Job tidak ditemukan atau sudah kedaluwarsa" : "Gagal memuat job";
      }
    },

    // ----- unduh aplikasi
    async loadDownloads() {
      this.downloadsError = null;
      try {
        this.downloads = await getJSON("/api/downloads");
      } catch (e) {
        this.downloadsError = e.message;
      }
    },

    // ----- model
    async loadModel() {
      this.modelError = null;
      try {
        this.model = await getJSON("/api/model");
      } catch (e) {
        this.modelError = e.message;
      }
    },
  },
}).mount("#app");
