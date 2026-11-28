package yokai.core.sync

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.Base64

/**
 * A WebDAV server in memory, with the behaviour of RFC 4918 that the sync relies on: MKCOL fails with 405 on an
 * existing resource and 409 without a parent, PUT needs the parent collection, PROPFIND lists one level. Options
 * make it answer like different servers do (namespace prefixes, full-URL hrefs, unencoded hrefs).
 */
class InMemoryWebDav(
    val base: String = "https://dav.example/remote/",
    private val user: String = "reader",
    private val password: String = "secret",
    private val prefix: String = "d",
    private val fullUrlHrefs: Boolean = false,
    private val encodeHrefs: Boolean = true,
) : HttpTransport {
    /** Decoded paths below [base], without a final slash; "" is the base itself. */
    val collections = sortedSetOf("")
    val files = sortedMapOf<String, ByteArray>()
    val requests = mutableListOf<String>()
    var offline = false

    fun text(path: String) = files[path]?.decodeToString()

    override fun execute(request: HttpRequest, sink: ((InputStream) -> Unit)?): HttpResponse {
        if (offline) throw SyncException(SyncException.Kind.Network, "offline")
        require(request.url.startsWith(base)) { "outside the base: ${request.url}" }
        val path = WebDavClient.decodePath(request.url.removePrefix(base)).trimEnd('/')
        requests += "${request.method} $path"
        val expected = "Basic " + Base64.getEncoder().encodeToString("$user:$password".toByteArray())
        if (request.headers["Authorization"] != expected) return response(401)
        val parent = path.substringBeforeLast('/', "")
        return when (request.method) {
            "MKCOL" -> when {
                path in collections || path in files -> response(405)
                parent !in collections -> response(409)
                else -> {
                    collections += path
                    response(201)
                }
            }
            "PUT" -> when {
                path in collections -> response(405)
                parent !in collections -> response(409)
                else -> {
                    val out = ByteArrayOutputStream()
                    request.body!!.writeTo(out)
                    val existed = path in files
                    files[path] = out.toByteArray()
                    response(if (existed) 204 else 201)
                }
            }
            "GET" -> {
                val bytes = files[path] ?: return response(404)
                if (sink != null) {
                    sink(ByteArrayInputStream(bytes))
                    response(200)
                } else {
                    HttpResponse(200, mapOf("etag" to "\"${bytes.contentHashCode()}\""), bytes)
                }
            }
            "PROPFIND" -> when {
                path in collections -> multistatus(path, children(path))
                path in files -> multistatus(path, emptyList(), selfIsFile = true)
                else -> response(404)
            }
            else -> response(405)
        }
    }

    private fun response(status: Int) = HttpResponse(status, emptyMap(), ByteArray(0))

    private fun children(path: String): List<Pair<String, Boolean>> {
        val start = if (path.isEmpty()) "" else "$path/"
        val dirs = collections.filter { it.startsWith(start) && it != path && '/' !in it.removePrefix(start) }.map { it to true }
        val fs = files.keys.filter { it.startsWith(start) && '/' !in it.removePrefix(start) }.map { it to false }
        return dirs + fs
    }

    private fun href(path: String, collection: Boolean): String {
        val basePath = "/" + base.substringAfter("://").substringAfter('/')
        val encoded = if (encodeHrefs) path.split('/').joinToString("/") { WebDavClient.encodeSegment(it) } else path
        val p = basePath + encoded + if (collection && path.isNotEmpty()) "/" else ""
        return if (fullUrlHrefs) base.substringBefore("://") + "://" + base.substringAfter("://").substringBefore('/') + p else p
    }

    private fun multistatus(path: String, children: List<Pair<String, Boolean>>, selfIsFile: Boolean = false): HttpResponse {
        val p = if (prefix.isEmpty()) "" else "$prefix:"
        val ns = if (prefix.isEmpty()) "xmlns=\"DAV:\"" else "xmlns:$prefix=\"DAV:\""
        val sb = StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<${p}multistatus $ns>")
        fun entry(path: String, collection: Boolean) {
            sb.append("<${p}response><${p}href>").append(href(path, collection)).append("</${p}href><${p}propstat><${p}prop>")
            if (collection) {
                sb.append("<${p}resourcetype><${p}collection/></${p}resourcetype>")
            } else {
                sb.append("<${p}resourcetype/><${p}getcontentlength>").append(files[path]?.size ?: 0).append("</${p}getcontentlength>")
            }
            sb.append("</${p}prop><${p}status>HTTP/1.1 200 OK</${p}status></${p}propstat></${p}response>")
        }
        entry(path, !selfIsFile)
        for ((child, collection) in children) entry(child, collection)
        sb.append("</${p}multistatus>")
        return HttpResponse(207, mapOf("content-type" to "application/xml"), sb.toString().toByteArray())
    }
}

/** A device's data in memory, as an adapter would read and write a real library. */
class FakeDevice(val id: String) : SyncAdapter, SyncFileAccess {
    val works = sortedMapOf<String, WorkValue>()
    val categories = sortedMapOf<String, CategoryValue>()
    val settings = sortedMapOf<String, SettingValue>()

    /** Work → chapter → value; a chapter missing here is a book file this device does not have. */
    val chapters = sortedMapOf<String, MutableMap<String, ChapterValue>>()

    /** Works this device can create when another device asks (false: an online work the iOS version lacks). */
    var canCreate: (String) -> Boolean = { SyncIds.localFolder(it) != null }

    var baseline = SyncBaseline()
    val workBaselines = sortedMapOf<String, WorkBaseline>()
    val files = sortedMapOf<String, ByteArray>()

    fun chapter(work: String, key: String) = chapters[work]?.get(key)

    fun setChapter(work: String, key: String, value: ChapterValue) {
        chapters.getOrPut(work) { sortedMapOf() }[key] = value
    }

    override fun librarySnapshot() = LibrarySnapshot(works.toMap(), categories.toMap(), settings.toMap())

    override fun applyLibrary(changes: LibraryChanges): Set<String> {
        val ids = mutableSetOf<String>()
        for ((k, v) in changes.works) {
            if (k in works || canCreate(k)) {
                works[k] = v
                ids += "w:$k"
            }
        }
        for ((k, v) in changes.categories) {
            categories[k] = v
            ids += "c:$k"
        }
        for (k in changes.deletedCategories) categories.remove(k)
        for ((k, v) in changes.settings) {
            if (v.value == null) settings.remove(k) else settings[k] = v
            ids += "s:$k"
        }
        return ids
    }

    override fun progressSnapshot(work: String) = ProgressSnapshot(chapters[work]?.toMap() ?: emptyMap())

    override fun applyProgress(work: String, changes: ProgressChanges): Set<String> {
        val ids = mutableSetOf<String>()
        val map = chapters[work] ?: return ids
        for ((key, c) in changes.chapters) {
            var v = map[key] ?: continue
            c.progress?.let {
                v = v.copy(read = it.read, page = it.page, left = it.left)
                ids += "$key|progress"
            }
            c.bookmark?.let {
                v = v.copy(bookmark = it)
                ids += "$key|bookmark"
            }
            c.position?.let {
                v = v.copy(locator = it.locator)
                ids += "$key|position"
            }
            c.history?.let { v = v.copy(lastRead = it.lastRead, duration = it.duration) }
            map[key] = v
        }
        return ids
    }

    override fun loadBaseline() = baseline
    override fun saveBaseline(baseline: SyncBaseline) {
        this.baseline = baseline
    }

    override fun loadWorkBaseline(work: String) = workBaselines[work] ?: WorkBaseline()
    override fun saveWorkBaseline(work: String, baseline: WorkBaseline) {
        workBaselines[work] = baseline
    }

    override fun list(works: Collection<String>) = files.entries
        .map { (k, v) -> FileItem(k.substringBefore('/'), k.substringAfter('/'), v.size.toLong()) }
        .filter { it.work in works }

    override fun open(work: String, path: String): InputStream = ByteArrayInputStream(files.getValue("$work/$path"))

    override fun save(work: String, path: String, input: InputStream) {
        val bytes = input.readBytes() // throws before anything is kept when the size is wrong
        files["$work/$path"] = bytes
    }
}
