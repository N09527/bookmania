package yokai.core.sync

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.Base64
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.BufferedSink

class SyncException(val kind: Kind, message: String, val status: Int = 0, cause: Throwable? = null) :
    Exception(message, cause) {
    enum class Kind {
        /** The address is not https or not a URL. */
        Config,

        /** 401 or 403: the account or its permissions. */
        Auth,

        /** Another HTTP status. */
        Http,

        /** No connection, a timeout, a TLS error. */
        Network,

        /** A response that is not what WebDAV or the sync format says. */
        Format,
    }
}

/** A request body written on demand (a file is streamed, not read into memory). */
class HttpBody(val contentType: String, val length: Long, val writeTo: (OutputStream) -> Unit) {
    companion object {
        fun bytes(contentType: String, bytes: ByteArray) = HttpBody(contentType, bytes.size.toLong()) { it.write(bytes) }
    }
}

class HttpRequest(val method: String, val url: String, val headers: Map<String, String> = emptyMap(), val body: HttpBody? = null)

/** [headers] have lower-case names. */
class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray)

/** How requests are sent: OkHttp in the app, a fake server in tests. */
interface HttpTransport {
    /**
     * Sends [request]. With [sink], the body of a 2xx response is handed to it and [HttpResponse.body] is empty;
     * otherwise the body is read, up to [MAX_BODY] bytes.
     */
    fun execute(request: HttpRequest, sink: ((InputStream) -> Unit)? = null): HttpResponse

    companion object {
        const val MAX_BODY = 32L * 1024 * 1024
    }
}

class OkHttpTransport(private val client: OkHttpClient) : HttpTransport {
    override fun execute(request: HttpRequest, sink: ((InputStream) -> Unit)?): HttpResponse {
        val body = request.body?.let { b ->
            object : okhttp3.RequestBody() {
                override fun contentType() = b.contentType.toMediaTypeOrNull()
                override fun contentLength() = b.length
                override fun writeTo(sink: BufferedSink) {
                    val out = sink.outputStream()
                    b.writeTo(out)
                    out.flush()
                }
            }
        }
        val builder = Request.Builder().url(request.url).method(request.method, body)
        for ((k, v) in request.headers) builder.header(k, v)
        try {
            client.newCall(builder.build()).execute().use { response ->
                val headers = response.headers.names().associate { it.lowercase() to (response.header(it) ?: "") }
                val stream = response.body.byteStream()
                if (sink != null && response.code in 200..299) {
                    sink(stream)
                    return HttpResponse(response.code, headers, ByteArray(0))
                }
                return HttpResponse(response.code, headers, readLimited(stream))
            }
        } catch (e: SyncException) {
            throw e
        } catch (e: java.io.IOException) {
            throw SyncException(SyncException.Kind.Network, e.message ?: e.javaClass.simpleName, cause = e)
        } catch (e: IllegalArgumentException) {
            throw SyncException(SyncException.Kind.Config, e.message ?: "invalid request", cause = e)
        }
    }

    private fun readLimited(stream: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val n = stream.read(buffer)
            if (n < 0) break
            total += n
            if (total > HttpTransport.MAX_BODY) throw SyncException(SyncException.Kind.Format, "response too large")
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }
}

/** An entry of a collection listing. */
data class DavEntry(val name: String, val collection: Boolean, val etag: String?, val length: Long?)

/**
 * The few WebDAV requests the sync needs (sync-format.md section 6), on paths given as unencoded segments below
 * [baseUrl].
 */
class WebDavClient(
    baseUrl: String,
    user: String,
    password: String,
    private val transport: HttpTransport,
    requireHttps: Boolean = true,
) {
    val base: String
    private val auth = "Basic " + Base64.getEncoder().encodeToString("$user:$password".toByteArray(Charsets.UTF_8))

    init {
        val trimmed = baseUrl.trim()
        val scheme = trimmed.substringBefore("://", "").lowercase()
        if (scheme != "https" && (requireHttps || scheme != "http")) {
            throw SyncException(SyncException.Kind.Config, "the server address must start with https://")
        }
        if (trimmed.substringAfter("://").substringBefore('/').isEmpty()) {
            throw SyncException(SyncException.Kind.Config, "the server address has no host")
        }
        base = if (trimmed.endsWith("/")) trimmed else "$trimmed/"
    }

    fun url(path: List<String>, collection: Boolean = false): String {
        val p = path.joinToString("/") { encodeSegment(it) }
        return base + p + if (collection && p.isNotEmpty()) "/" else ""
    }

    private fun send(method: String, path: List<String>, collection: Boolean, headers: Map<String, String> = emptyMap(), body: HttpBody? = null, sink: ((InputStream) -> Unit)? = null): HttpResponse {
        val response = transport.execute(HttpRequest(method, url(path, collection), headers + ("Authorization" to auth), body), sink)
        if (response.status == 401 || response.status == 403) {
            throw SyncException(SyncException.Kind.Auth, "$method ${path.joinToString("/")}: ${response.status}", response.status)
        }
        return response
    }

    private fun fail(method: String, path: List<String>, response: HttpResponse): Nothing =
        throw SyncException(SyncException.Kind.Http, "$method ${path.joinToString("/")}: ${response.status}", response.status)

    /** Creates the collection; one that exists already is fine (405). */
    fun mkcol(path: List<String>) {
        val r = send("MKCOL", path, collection = true)
        if (r.status !in 200..299 && r.status != 405) fail("MKCOL", path, r)
    }

    /** Creates every collection of [path], from the top. */
    fun ensureCollections(path: List<String>) {
        for (n in 1..path.size) mkcol(path.subList(0, n))
    }

    /** The entries of a collection (Depth 1), without the collection itself; empty when it does not exist. */
    fun list(path: List<String>): List<DavEntry> {
        val body = HttpBody.bytes("application/xml; charset=utf-8", PROPFIND.toByteArray(Charsets.UTF_8))
        val r = send("PROPFIND", path, collection = true, headers = mapOf("Depth" to "1"), body = body)
        if (r.status == 404) return emptyList()
        if (r.status != 207) fail("PROPFIND", path, r)
        return parseMultistatus(r.body.decodeToString(), url(path, collection = true))
    }

    /** The file, or null when it does not exist. */
    fun get(path: List<String>): ByteArray? {
        val r = send("GET", path, collection = false)
        if (r.status == 404) return null
        if (r.status !in 200..299) fail("GET", path, r)
        return r.body
    }

    /** Streams the file to [sink]; false when it does not exist. */
    fun download(path: List<String>, sink: (InputStream) -> Unit): Boolean {
        val r = send("GET", path, collection = false, sink = sink)
        if (r.status == 404) return false
        if (r.status !in 200..299) fail("GET", path, r)
        return true
    }

    fun put(path: List<String>, body: HttpBody) {
        val r = send("PUT", path, collection = false, body = body)
        if (r.status !in 200..299) fail("PUT", path, r)
    }

    fun putJson(path: List<String>, json: String) =
        put(path, HttpBody.bytes("application/json; charset=utf-8", json.toByteArray(Charsets.UTF_8)))

    companion object {
        const val DAV = "DAV:"

        private const val PROPFIND = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>"""

        private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

        /** RFC 3986 percent-encoding of one path segment (UTF-8; only unreserved characters stay). */
        fun encodeSegment(segment: String): String {
            val out = StringBuilder()
            for (b in segment.toByteArray(Charsets.UTF_8)) {
                val c = b.toInt() and 0xFF
                if (c < 0x80 && UNRESERVED.indexOf(c.toChar()) >= 0) {
                    out.append(c.toChar())
                } else {
                    out.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xF])
                }
            }
            return out.toString()
        }

        private fun isHex(c: Char) = c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'

        /** Percent-decoding (UTF-8); a malformed escape is kept as it is. */
        fun decodePath(text: String): String {
            if ('%' !in text) return text
            val bytes = ByteArrayOutputStream()
            var i = 0
            while (i < text.length) {
                if (text[i] == '%' && i + 2 < text.length && isHex(text[i + 1]) && isHex(text[i + 2])) {
                    bytes.write(text.substring(i + 1, i + 3).toInt(16))
                    i += 3
                    continue
                }
                val cp = Character.codePointAt(text, i)
                bytes.write(String(Character.toChars(cp)).toByteArray(Charsets.UTF_8))
                i += Character.charCount(cp)
            }
            return bytes.toString(Charsets.UTF_8.name())
        }

        /** The path part of an href, which can be a full URL or an absolute path, decoded, without a final slash. */
        private fun hrefPath(href: String): String {
            val h = href.trim()
            val path = if ("://" in h) "/" + h.substringAfter("://").substringAfter('/', "") else h
            return decodePath(path.substringBefore('?')).trimEnd('/')
        }

        /** The entries of a 207 response to PROPFIND [requested], without the requested collection itself. */
        fun parseMultistatus(xml: String, requested: String): List<DavEntry> {
            val root = try {
                MiniXml.parse(xml)
            } catch (e: XmlFormatException) {
                throw SyncException(SyncException.Kind.Format, "PROPFIND: ${e.message}", cause = e)
            }
            if (root.namespace != DAV || root.name != "multistatus") throw SyncException(SyncException.Kind.Format, "PROPFIND: not a multistatus")
            val self = hrefPath(requested)
            val entries = mutableListOf<DavEntry>()
            for (response in root.all(DAV, "response")) {
                val href = response.child(DAV, "href")?.text ?: continue
                val path = hrefPath(href)
                if (path == self || path.isEmpty()) continue
                val name = path.substringAfterLast('/')
                var collection = false
                var etag: String? = null
                var length: Long? = null
                for (propstat in response.all(DAV, "propstat")) {
                    val status = propstat.child(DAV, "status")?.text ?: ""
                    if (" 200" !in status) continue
                    val prop = propstat.child(DAV, "prop") ?: continue
                    if (prop.child(DAV, "resourcetype")?.child(DAV, "collection") != null) collection = true
                    prop.child(DAV, "getetag")?.text?.trim()?.takeIf { it.isNotEmpty() }?.let { etag = it }
                    prop.child(DAV, "getcontentlength")?.text?.trim()?.toLongOrNull()?.let { length = it }
                }
                entries += DavEntry(name, collection, etag, length)
            }
            return entries
        }
    }
}
