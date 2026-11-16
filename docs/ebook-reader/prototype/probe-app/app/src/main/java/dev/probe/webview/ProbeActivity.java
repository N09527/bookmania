package dev.probe.webview;

import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * Test-only probe. Mirrors the planned production setup: a virtual https origin served by
 * shouldInterceptRequest (no file/content access), strict CSP on book documents, every other
 * request answered with 403 and logged.
 */
public class ProbeActivity extends Activity {
    static final String TAG = "WVPROBE";
    static final String HOST = "appassets.androidplatform.net";
    static final String BOOK_CSP = "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
            + "font-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
        WebView.setWebContentsDebuggingEnabled(true);
        WebView wv = new WebView(this);
        WebSettings s = wv.getSettings();
        s.setJavaScriptEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setGeolocationEnabled(false);
        s.setDomStorageEnabled(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        boolean blockNetwork = getIntent().getBooleanExtra("blockNetwork", false);
        s.setBlockNetworkLoads(blockNetwork);
        Log.i(TAG, "blockNetworkLoads=" + blockNetwork + " ua=" + s.getUserAgentString());
        wv.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onConsoleMessage(ConsoleMessage m) {
                Log.i(TAG, "console " + m.messageLevel() + ": " + m.message());
                return true;
            }
        });
        wv.setWebViewClient(new WebViewClient() {
            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
                Uri u = req.getUrl();
                if (!"https".equals(u.getScheme()) || !HOST.equals(u.getHost())) {
                    Log.w(TAG, "BLOCKED " + u);
                    return new WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", new HashMap<>(), new ByteArrayInputStream(new byte[0]));
                }
                String path = u.getPath() == null ? "" : u.getPath().replaceFirst("^/+", "");
                if (path.contains("..") || !(path.startsWith("reader/") || path.startsWith("book/") || path.startsWith("fonts/"))) {
                    Log.w(TAG, "DENIED path " + path);
                    return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", new HashMap<>(), new ByteArrayInputStream(new byte[0]));
                }
                try {
                    InputStream in = getAssets().open(path);
                    Map<String, String> h = new HashMap<>();
                    h.put("Cache-Control", "no-store");
                    if (path.startsWith("book/")) h.put("Content-Security-Policy", BOOK_CSP);
                    return new WebResourceResponse(mime(path), mime(path).startsWith("text") || path.endsWith(".xhtml") ? "utf-8" : null, 200, "OK", h, in);
                } catch (IOException e) {
                    Log.w(TAG, "missing asset " + path);
                    return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", new HashMap<>(), new ByteArrayInputStream(new byte[0]));
                }
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                Log.w(TAG, "NAV BLOCKED " + req.getUrl() + " mainFrame=" + req.isForMainFrame());
                return true;
            }
        });
        setContentView(wv);
        String url = getIntent().getStringExtra("url");
        wv.loadUrl(url != null ? url : "https://" + HOST + "/reader/reader.html");
    }

    static String mime(String p) {
        if (p.endsWith(".html")) return "text/html";
        if (p.endsWith(".js")) return "text/javascript";
        if (p.endsWith(".xhtml")) return "application/xhtml+xml";
        if (p.endsWith(".css")) return "text/css";
        if (p.endsWith(".svg")) return "image/svg+xml";
        if (p.endsWith(".otf")) return "font/otf";
        if (p.endsWith(".ttf")) return "font/ttf";
        return "application/octet-stream";
    }
}
