package id.my.jalulabs.pichanter;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebView;

import androidx.activity.OnBackPressedCallback;

import com.getcapacitor.BridgeActivity;
import com.getcapacitor.WebViewListener;

public class MainActivity extends BridgeActivity {
    /** Jika server menerima koneksi tetapi tidak menjawab, tampilkan halaman offline setelah batas ini. */
    private static final long LOAD_TIMEOUT_MS = 15000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable pendingTimeout;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(PichanterNativePlugin.class); // harus sebelum super.onCreate
        super.onCreate(savedInstanceState);

        // Tombol kembali Android -> riwayat halaman PWA (hasil -> beranda); keluar hanya dari beranda.
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                WebView web = getBridge() != null ? getBridge().getWebView() : null;
                if (web != null && web.canGoBack()) {
                    web.goBack();
                } else {
                    setEnabled(false);
                    getOnBackPressedDispatcher().onBackPressed();
                    setEnabled(true);
                }
            }
        });

        // Batas waktu pemuatan pertama -> halaman offline (server.errorPath).
        // (WebView tidak memanggil onPageStarted selama server belum menjawab, jadi timer dipasang di sini.
        //  Tombol "Coba lagi" di offline.html mengecek server dulu dengan batas waktunya sendiri.)
        String errorUrl = getBridge().getErrorUrl();
        if (errorUrl != null) {
            WebView web = getBridge().getWebView();
            pendingTimeout = () -> {
                pendingTimeout = null;
                web.stopLoading();
                web.loadUrl(errorUrl);
            };
            handler.postDelayed(pendingTimeout, LOAD_TIMEOUT_MS);
        }
        getBridge().addWebViewListener(new WebViewListener() {
            @Override
            public void onPageCommitVisible(WebView view, String url) {
                cancelTimeout();
            }

            @Override
            public void onPageLoaded(WebView webView) {
                cancelTimeout();
            }

            @Override
            public void onReceivedError(WebView webView) {
                cancelTimeout();
            }
        });
    }

    private void cancelTimeout() {
        if (pendingTimeout != null) {
            handler.removeCallbacks(pendingTimeout);
            pendingTimeout = null;
        }
    }

    @Override
    public void onDestroy() {
        cancelTimeout();
        super.onDestroy();
    }
}
