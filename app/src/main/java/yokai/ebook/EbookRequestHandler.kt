package yokai.ebook

import android.content.res.AssetManager
import android.net.Uri
import android.webkit.WebResourceResponse
import co.touchlab.kermit.Logger
import java.io.ByteArrayInputStream
import java.io.IOException
import yokai.core.ebook.Publication
import yokai.core.ebook.XhtmlSanitizer
import yokai.core.ebook.mediaTypeFromName

/**
 * Serves the reader's virtual origin `https://appassets.androidplatform.net/`:
 * - `/shell/…` the reader shell from the app assets (`assets/ebook/`);
 * - `/book/…`  resources of the open book; (X)HTML documents are sanitized and get a strict CSP.
 * Every other request (other hosts, schemes, paths) is refused, so book content cannot reach the
 * network or any other file of the app. Called on WebView background threads.
 */
internal class EbookRequestHandler(private val assets: AssetManager) {

    @Volatile
    var publication: Publication? = null

    fun handle(url: Uri): WebResourceResponse {
        if (url.scheme != "https" || url.host != HOST || url.port != -1) return refuse(403, url)
        val path = url.path.orEmpty()
        return when {
            path.startsWith(SHELL_PREFIX) -> shell(path.removePrefix(SHELL_PREFIX))
            path.startsWith(BOOK_PREFIX) -> book(path.removePrefix(BOOK_PREFIX))
            else -> refuse(404, url)
        }
    }

    private fun shell(name: String): WebResourceResponse {
        if (name !in SHELL_FILES) return error(404)
        return try {
            val type = mediaTypeFromName(name) ?: "application/octet-stream"
            val headers = HashMap(NO_STORE)
            if (name.endsWith(".html")) headers["Content-Security-Policy"] = SHELL_CSP
            WebResourceResponse(type, "utf-8", 200, "OK", headers, assets.open("ebook/$name"))
        } catch (e: IOException) {
            error(404)
        }
    }

    /** [path] is already percent-decoded by [Uri.getPath]. */
    private fun book(path: String): WebResourceResponse {
        val pub = publication ?: return error(404)
        return try {
            val type = pub.mediaType(path) ?: mediaTypeFromName(path) ?: "application/octet-stream"
            val input = pub.open(path) ?: return error(404)
            if (type == "application/xhtml+xml" || type == "text/html") {
                val result = input.use { XhtmlSanitizer.sanitize(it.readBytes(), isHtml = type == "text/html") }
                val headers = HashMap(NO_STORE)
                headers["Content-Security-Policy"] = BOOK_CSP
                WebResourceResponse(
                    result.mediaType, "utf-8", 200, "OK", headers,
                    ByteArrayInputStream(result.text.toByteArray(Charsets.UTF_8)),
                )
            } else {
                val charset = if (type.startsWith("text/") || type == "image/svg+xml") "utf-8" else null
                WebResourceResponse(type, charset, 200, "OK", HashMap(NO_STORE), input)
            }
        } catch (e: Exception) {
            Logger.w(e) { "Failed to serve book resource" }
            error(500)
        }
    }

    private fun refuse(code: Int, url: Uri): WebResourceResponse {
        // Do not log the full URL: it can contain book content (titles, ids).
        Logger.d { "Blocked request: ${url.scheme}://${url.host}" }
        return error(code)
    }

    private fun error(code: Int): WebResourceResponse {
        val reason = when (code) {
            403 -> "Forbidden"
            404 -> "Not Found"
            else -> "Error"
        }
        return WebResourceResponse("text/plain", "utf-8", code, reason, HashMap(NO_STORE), ByteArrayInputStream(ByteArray(0)))
    }

    companion object {
        const val HOST = "appassets.androidplatform.net"
        const val ORIGIN = "https://$HOST"
        const val SHELL_PREFIX = "/shell/"
        const val BOOK_PREFIX = "/book/"
        const val SHELL_URL = "$ORIGIN${SHELL_PREFIX}reader.html"

        private val SHELL_FILES = setOf("reader.html", "reader.js")
        private val NO_STORE = mapOf("Cache-Control" to "no-store")

        /** Book documents: no scripts, nothing outside this origin. */
        const val BOOK_CSP = "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; " +
            "img-src 'self' data:; font-src 'self' data:; media-src 'self'; connect-src 'none'; frame-src 'none'; " +
            "object-src 'none'; base-uri 'none'; form-action 'none'"

        /** The shell: only its own script; book documents in same-origin frames. */
        const val SHELL_CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
            "img-src 'self' data:; font-src 'self' data:; frame-src 'self'; connect-src 'none'; " +
            "object-src 'none'; base-uri 'none'; form-action 'none'"

        /** URL of a book resource; each path segment is percent-encoded. */
        fun bookUrl(path: String, fragment: String? = null): String {
            val encoded = path.split('/').joinToString("/") { Uri.encode(it) }
            return ORIGIN + BOOK_PREFIX + encoded + (fragment?.let { "#" + Uri.encode(it) } ?: "")
        }

        /** Container path and fragment of a URL inside the book, or null for anything else. */
        fun bookPathOf(url: String): Pair<String, String?>? {
            val uri = Uri.parse(url)
            if (uri.scheme != "https" || uri.host != HOST) return null
            val path = uri.path ?: return null
            if (!path.startsWith(BOOK_PREFIX)) return null
            return path.removePrefix(BOOK_PREFIX) to uri.fragment
        }
    }
}
