#!/usr/bin/env node
/**
 * Build APK Pichanter.
 *
 *   npm run apk                                   -> https://pichanter.jalulabs.my.id
 *   npm run apk -- --url https://domain-lain.tld   -> alamat server lain
 *   npm run apk -- --url http://10.0.2.2:8000      -> uji di emulator (backend di laptop)
 *
 * Langkah: tulis capacitor.config.json + halaman offline -> (cap add android bila belum ada)
 * -> pasang kustomisasi native dari folder native/ -> cap sync -> gradlew assembleDebug -> dist/.
 */
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const ANDROID = path.join(ROOT, "android");
const APP_ID = "id.my.jalulabs.pichanter";
const APP_NAME = "Pichanter";
const MIN_SDK = 29; // PRD: Android 10+
const GRADLE_VERSION = "8.14.3"; // sesuai template Capacitor 8 + AGP 8.13
// Versi APK. Naikkan keduanya setiap rilis (versionCode harus selalu bertambah agar bisa dipasang menimpa).
//  1.0 (1): rilis awal
//  1.1 (2): semua format foto (HEIC, MPO, AVIF, SVG, ...), cadangan proses di server bila HP gagal
//           memperkecil foto, versi di user-agent, tombol "Versi baru tersedia"
const VERSION_NAME = "1.1";
const VERSION_CODE = 2;

// ---------------------------------------------------------------- argumen
const args = process.argv.slice(2);
const arg = (name, def) => {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
};
const base = arg("url", process.env.PICHANTER_URL || "https://pichanter.jalulabs.my.id").replace(/\/+$/, "");
const startUrl = new URL("/app/", base + "/").href;
const parsed = new URL(startUrl);
if (!["http:", "https:"].includes(parsed.protocol)) throw new Error("URL harus http/https: " + base);
const cleartext = parsed.protocol === "http:";
console.log(`\n▶ APK Pichanter → ${startUrl}${cleartext ? "  (HTTP, hanya untuk uji)" : ""}\n`);

const run = (cmd, opts = {}) => {
  console.log("$ " + cmd);
  execSync(cmd, { stdio: "inherit", cwd: ROOT, ...opts });
};

// ---------------------------------------------------------------- 1. config + www
const config = {
  appId: APP_ID,
  appName: APP_NAME,
  webDir: "www",
  server: {
    url: startUrl,
    cleartext,
    errorPath: "offline.html",
  },
  android: {
    appendUserAgent: `PichanterAndroid/${VERSION_NAME}`, // dibaca PWA: versi APK + tawaran pembaruan
    allowMixedContent: cleartext, // build uji HTTP: halaman offline lokal (https://localhost) perlu cek server http
    webContentsDebuggingEnabled: cleartext, // bisa diperiksa via chrome://inspect hanya pada build uji
  },
  plugins: {
    SystemBars: { insetsHandling: "css", initialViewportFitValueHint: "cover" },
  },
};
writeFileSync(path.join(ROOT, "capacitor.config.json"), JSON.stringify(config, null, 2) + "\n");

const offlineTpl = readFileSync(path.join(ROOT, "native", "offline.html"), "utf8");
mkdirSync(path.join(ROOT, "www"), { recursive: true });
writeFileSync(path.join(ROOT, "www", "offline.html"), offlineTpl.replaceAll("__START_URL__", startUrl));
writeFileSync(
  path.join(ROOT, "www", "index.html"),
  `<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=${startUrl}">` +
    `<title>Pichanter</title><a href="${startUrl}">Buka Pichanter</a>\n`
);

// ---------------------------------------------------------------- 2. proyek Android
if (!existsSync(ANDROID)) run("npx cap add android");

// ---------------------------------------------------------------- 3. kustomisasi native (idempoten)
const pkgDir = path.join(ANDROID, "app", "src", "main", "java", ...APP_ID.split("."));
cpSync(path.join(ROOT, "native", "java"), pkgDir, { recursive: true });
cpSync(path.join(ROOT, "native", "res"), path.join(ANDROID, "app", "src", "main", "res"), { recursive: true });

function patch(file, fn) {
  const before = readFileSync(file, "utf8");
  const after = fn(before);
  if (after !== before) {
    writeFileSync(file, after);
    console.log("  patched " + path.relative(ROOT, file));
  }
}

patch(path.join(ANDROID, "app", "build.gradle"), (s) =>
  s.replace(/versionCode\s+\d+/, `versionCode ${VERSION_CODE}`).replace(/versionName\s+"[^"]*"/, `versionName "${VERSION_NAME}"`)
);
patch(path.join(ANDROID, "variables.gradle"), (s) => s.replace(/minSdkVersion = \d+/, `minSdkVersion = ${MIN_SDK}`));

// Kunci versi Gradle: AGP 8.x (Capacitor 8) tidak jalan di Gradle >= 9.6. Tawaran "upgrade wrapper"
// dari ekstensi VS Code akan membuat build gagal, jadi selalu kembalikan ke versi template.
patch(path.join(ANDROID, "gradle", "wrapper", "gradle-wrapper.properties"), (s) =>
  s.replace(/^distributionUrl=.*$/m, `distributionUrl=https\\://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-all.zip`)
);

// Kunci JDK Gradle ke JDK 21 bawaan Android Studio. Tanpa ini, ekstensi Java VS Code menjalankan Gradle
// dengan JDK 25 bawaannya dan gagal ("Unsupported class file major version 69").
// Di mesin tanpa Android Studio di lokasi standar, baris ini dihapus agar Gradle memakai JAVA_HOME.
const studioJbr = "C:\\Program Files\\Android\\Android Studio\\jbr";
const hasStudioJbr = process.platform === "win32" && existsSync(studioJbr);
patch(path.join(ANDROID, "gradle.properties"), (s) => {
  s = s.replace(/^org\.gradle\.java\.home=.*\r?\n?/m, "");
  if (hasStudioJbr) s = s.replace(/\s*$/, "\n") + `org.gradle.java.home=${studioJbr.replaceAll("\\", "/").replace(":", "\\:")}\n`;
  return s;
});

patch(path.join(ANDROID, "app", "src", "main", "AndroidManifest.xml"), (s) => {
  if (!s.includes("android.permission.CAMERA")) {
    s = s.replace(
      "<uses-permission android:name=\"android.permission.INTERNET\" />",
      "<uses-permission android:name=\"android.permission.INTERNET\" />\n" +
        "    <uses-permission android:name=\"android.permission.CAMERA\" />\n" +
        "    <uses-feature android:name=\"android.hardware.camera\" android:required=\"false\" />"
    );
  }
  if (!s.includes("android:screenOrientation")) {
    s = s.replace("android:name=\".MainActivity\"", "android:name=\".MainActivity\"\n            android:screenOrientation=\"portrait\"");
  }
  return s;
});

// Catatan: file_paths.xml bawaan Capacitor sudah memuat <cache-path path="."/>, jadi cache/share/ bisa dibagikan.

// ---------------------------------------------------------------- 4. sync + gradle
run("npx cap sync android");

const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || path.join(os.homedir(), "AppData", "Local", "Android", "Sdk");
writeFileSync(path.join(ANDROID, "local.properties"), `sdk.dir=${sdk.replaceAll("\\", "\\\\").replaceAll(":", "\\:")}\n`);

const env = { ...process.env, ANDROID_HOME: sdk };
if (hasStudioJbr) env.JAVA_HOME = studioJbr; // JDK 21 bawaan Android Studio

const gradlew = path.join(ANDROID, process.platform === "win32" ? "gradlew.bat" : "gradlew");
run(`"${gradlew}" assembleDebug --console=plain`, { cwd: ANDROID, env });

// ---------------------------------------------------------------- 5. hasil
const apkDir = path.join(ANDROID, "app", "build", "outputs", "apk", "debug");
const apk = readdirSync(apkDir).find((f) => f.endsWith(".apk"));
mkdirSync(path.join(ROOT, "dist"), { recursive: true });
const outName = cleartext ? `pichanter-uji-${parsed.hostname.replaceAll(".", "-")}.apk` : "pichanter.apk";
const out = path.join(ROOT, "dist", outName);
cpSync(path.join(apkDir, apk), out);
console.log(`\n✔ APK siap: ${out}\n  Server: ${startUrl}\n`);

// ---------------------------------------------------------------- 6. terbitkan ke menu "Unduh Aplikasi"
// Hanya APK produksi (HTTPS). Backend menyajikannya di /download/pichanter.apk; deploy/deploy.sh ikut mengirimnya.
if (!cleartext) {
  const dlDir = path.join(ROOT, "..", "backend", "downloads");
  mkdirSync(dlDir, { recursive: true });
  const dest = path.join(dlDir, "pichanter.apk");
  cpSync(out, dest);
  const meta = {
    version: `${VERSION_NAME} (${VERSION_CODE})`,
    built_at: new Date().toISOString(),
    server: startUrl,
    min_android: "10",
    sha256: createHash("sha256").update(readFileSync(dest)).digest("hex"),
  };
  writeFileSync(dest + ".json", JSON.stringify(meta, null, 2) + "\n");
  console.log(`✔ Diterbitkan untuk menu Unduh Aplikasi: ${path.relative(path.join(ROOT, ".."), dest)}\n`);
}
