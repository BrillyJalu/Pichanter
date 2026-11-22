package id.my.jalulabs.pichanter;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.net.Uri;
import android.os.Environment;
import android.provider.MediaStore;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Fitur native yang tidak tersedia di WebView Android:
 *  - saveImage : unduh hasil dari server lalu simpan ke Galeri (Pictures/Pichanter) via MediaStore.
 *  - shareImage: unduh hasil lalu buka dialog Bagikan Android (WhatsApp, Drive, dll.).
 * Gambar diunduh langsung oleh kode native, jadi PNG besar tidak dilewatkan lewat bridge JavaScript.
 */
@CapacitorPlugin(name = "PichanterNative")
public class PichanterNativePlugin extends Plugin {

    private static final int MAX_BYTES = 40 * 1024 * 1024;
    private static final String FOLDER = Environment.DIRECTORY_PICTURES + "/Pichanter";

    private static class Download {
        byte[] bytes;
        String mime;
    }

    /** Hanya izinkan unduhan dari host server Pichanter yang sedang dimuat. */
    private Download fetch(PluginCall call) throws IOException {
        String src = call.getString("url");
        if (src == null) throw new IOException("URL kosong");
        URL url = new URL(src);
        String allowedHost = Uri.parse(getBridge().getServerUrl()).getHost();
        if (!("https".equals(url.getProtocol()) || "http".equals(url.getProtocol()))
                || allowedHost == null || !allowedHost.equalsIgnoreCase(url.getHost())) {
            throw new IOException("URL tidak diizinkan: " + src);
        }
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(30000);
        try {
            int code = conn.getResponseCode();
            if (code != 200) throw new IOException("Server membalas HTTP " + code);
            String mime = conn.getContentType();
            if (mime == null || !mime.startsWith("image/")) throw new IOException("Respons bukan gambar");
            try (InputStream in = conn.getInputStream(); ByteArrayOutputStream buf = new ByteArrayOutputStream()) {
                byte[] chunk = new byte[64 * 1024];
                int n;
                while ((n = in.read(chunk)) > 0) {
                    buf.write(chunk, 0, n);
                    if (buf.size() > MAX_BYTES) throw new IOException("File terlalu besar");
                }
                Download d = new Download();
                d.bytes = buf.toByteArray();
                d.mime = mime.split(";")[0].trim();
                return d;
            }
        } finally {
            conn.disconnect();
        }
    }

    private static String safeName(PluginCall call, String mime) {
        String name = call.getString("fileName", "pichanter");
        name = name.replaceAll("[^A-Za-z0-9._-]", "_");
        String ext = "image/jpeg".equals(mime) ? ".jpg" : ".png";
        if (!name.toLowerCase().endsWith(ext)) name = name.replaceAll("\\.[A-Za-z0-9]+$", "") + ext;
        return name;
    }

    /** Buka alamat di browser HP (dipakai untuk mengunduh APK versi baru). Hanya host server Pichanter. */
    @PluginMethod
    public void openExternal(PluginCall call) {
        try {
            String src = call.getString("url");
            Uri uri = Uri.parse(src == null ? "" : src);
            String allowedHost = Uri.parse(getBridge().getServerUrl()).getHost();
            if (!"https".equals(uri.getScheme()) || allowedHost == null || !allowedHost.equalsIgnoreCase(uri.getHost())) {
                throw new IOException("URL tidak diizinkan: " + src);
            }
            Intent view = new Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getActivity().runOnUiThread(() -> getActivity().startActivity(view));
            call.resolve();
        } catch (Exception e) {
            call.reject("Gagal membuka browser: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void saveImage(PluginCall call) {
        try {
            Download d = fetch(call);
            String name = safeName(call, d.mime);
            ContentResolver resolver = getContext().getContentResolver();
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME, name);
            values.put(MediaStore.Images.Media.MIME_TYPE, d.mime);
            values.put(MediaStore.Images.Media.RELATIVE_PATH, FOLDER);
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
            Uri uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IOException("Galeri menolak membuat file");
            try (OutputStream out = resolver.openOutputStream(uri)) {
                if (out == null) throw new IOException("Tidak bisa menulis ke galeri");
                out.write(d.bytes);
            } catch (IOException e) {
                resolver.delete(uri, null, null);
                throw e;
            }
            values.clear();
            values.put(MediaStore.Images.Media.IS_PENDING, 0);
            resolver.update(uri, values, null, null);

            JSObject ret = new JSObject();
            ret.put("uri", uri.toString());
            ret.put("folder", FOLDER);
            ret.put("fileName", name);
            call.resolve(ret);
        } catch (Exception e) {
            call.reject("Gagal menyimpan: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void shareImage(PluginCall call) {
        try {
            Download d = fetch(call);
            String name = safeName(call, d.mime);
            File dir = new File(getContext().getCacheDir(), "share");
            if (!dir.exists() && !dir.mkdirs()) throw new IOException("Tidak bisa membuat folder cache");
            File file = new File(dir, name);
            try (FileOutputStream out = new FileOutputStream(file)) {
                out.write(d.bytes);
            }
            Uri uri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", file);
            Intent send = new Intent(Intent.ACTION_SEND)
                    .setType(d.mime)
                    .putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            Intent chooser = Intent.createChooser(send, "Bagikan hasil Pichanter");
            getActivity().runOnUiThread(() -> getActivity().startActivity(chooser));
            call.resolve();
        } catch (Exception e) {
            call.reject("Gagal membagikan: " + e.getMessage(), e);
        }
    }
}
