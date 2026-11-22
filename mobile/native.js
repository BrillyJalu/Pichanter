/* Jembatan ke fitur native saat PWA berjalan di dalam APK (Capacitor).
 * Di browser biasa available() = false dan aplikasi memakai cara web (unduh <a download>, Web Share).
 */
window.PichanterNative = (function () {
  let plugin = null;

  function get() {
    const C = window.Capacitor;
    if (!C || typeof C.isNativePlatform !== "function" || !C.isNativePlatform()) return null;
    if (!plugin) plugin = (C.Plugins && C.Plugins.PichanterNative) || (C.registerPlugin && C.registerPlugin("PichanterNative"));
    return plugin;
  }

  const abs = (url) => new URL(url, location.href).href;

  return {
    available: () => !!get(),
    /** Unduh url lalu simpan ke Galeri (Pictures/Pichanter). */
    saveImage: (url, fileName) => get().saveImage({ url: abs(url), fileName }),
    /** Unduh url lalu buka dialog Bagikan Android. */
    shareImage: (url, fileName) => get().shareImage({ url: abs(url), fileName }),
    /** Buka alamat di browser HP (mis. unduh APK baru). Hanya ada di APK >= 1.1. */
    openExternal: (url) => (get() ? get().openExternal({ url: abs(url) }) : Promise.reject(new Error("bukan APK"))),
  };
})();
