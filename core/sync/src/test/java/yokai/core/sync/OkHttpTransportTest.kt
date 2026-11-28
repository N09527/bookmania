package yokai.core.sync

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import okhttp3.OkHttpClient
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The OkHttp transport over a real (local, plain HTTP/1.1) connection to the in-memory server. */
class OkHttpTransportTest {

    private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val base = "http://127.0.0.1:${socket.localPort}/remote/"
    private val dav = InMemoryWebDav(base = base)
    private val methods = mutableListOf<String>()

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val s = runCatching { socket.accept() }.getOrNull() ?: break
                runCatching { s.use(::serve) }
            }
        }
    }

    @AfterEach
    fun stop() = socket.close()

    private fun readLine(input: InputStream): String {
        val out = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0 || b == '\n'.code) break
            if (b != '\r'.code) out.write(b)
        }
        return out.toString(Charsets.UTF_8.name())
    }

    /** One request per connection; the response closes it. */
    private fun serve(s: Socket) {
        val input = BufferedInputStream(s.getInputStream())
        val (method, target) = readLine(input).split(' ').let { it[0] to it[1] }
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = readLine(input)
            if (line.isEmpty()) break
            headers[line.substringBefore(':').trim()] = line.substringAfter(':').trim()
        }
        val length = headers.entries.firstOrNull { it.key.equals("Content-Length", true) }?.value?.toInt() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) break
            read += n
        }
        synchronized(methods) { methods += method }
        val auth = headers.entries.firstOrNull { it.key.equals("Authorization", true) }?.value
        val request = HttpRequest(
            method,
            "http://127.0.0.1:${socket.localPort}$target",
            if (auth != null) mapOf("Authorization" to auth) else emptyMap(),
            if (length > 0 || method == "PUT") HttpBody.bytes("application/octet-stream", body) else null,
        )
        val response = dav.execute(request)
        val out = s.getOutputStream()
        val head = StringBuilder("HTTP/1.1 ${response.status} X\r\nContent-Length: ${response.body.size}\r\nConnection: close\r\n")
        for ((k, v) in response.headers) head.append("$k: $v\r\n")
        head.append("\r\n")
        out.write(head.toString().toByteArray())
        out.write(response.body)
        out.flush()
    }

    @Test
    fun `WebDAV methods, authentication and streamed bodies through OkHttp`() {
        val client = WebDavClient(base, "reader", "secret", OkHttpTransport(OkHttpClient()), requireHttps = false)
        client.ensureCollections(listOf("Bookmania", "作品 A"))
        val data = ByteArray(300_000) { (it % 251).toByte() }
        client.put(listOf("Bookmania", "作品 A", "第1冊.epub"), HttpBody("application/octet-stream", data.size.toLong()) { out ->
            data.inputStream().copyTo(out)
        })
        assertEquals(listOf(DavEntry("第1冊.epub", false, null, data.size.toLong())), client.list(listOf("Bookmania", "作品 A")))
        val out = ByteArrayOutputStream()
        assertTrue(client.download(listOf("Bookmania", "作品 A", "第1冊.epub")) { it.copyTo(out) })
        assertArrayEquals(data, out.toByteArray())
        assertEquals(null, client.get(listOf("Bookmania", "none.json")))
        assertTrue(listOf("MKCOL", "PUT", "PROPFIND", "GET").all { it in methods })

        val wrong = WebDavClient(base, "reader", "nope", OkHttpTransport(OkHttpClient()), requireHttps = false)
        val e = runCatching { wrong.list(listOf("Bookmania")) }.exceptionOrNull() as SyncException
        assertEquals(SyncException.Kind.Auth, e.kind)
    }
}
