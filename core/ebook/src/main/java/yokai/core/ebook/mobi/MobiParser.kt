package yokai.core.ebook.mobi

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import org.jsoup.Jsoup
import yokai.core.ebook.BookException
import yokai.core.ebook.BookFormat
import yokai.core.ebook.BookMetadata
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.Publication
import yokai.core.ebook.ReadingDirection
import yokai.core.ebook.SpineItem
import yokai.core.ebook.TocEntry
import yokai.core.ebook.WritingModeDetector
import yokai.core.ebook.WritingModeHint
import yokai.core.ebook.io.RandomAccessSource

/** Opens MOBI 6, KF8 (AZW3) and joint MOBI files. DRM-protected files are refused. */
object MobiParser {
    fun parse(source: RandomAccessSource): Publication {
        return try {
            val file = MobiFile(source)
            if (file.isKf8) Kf8Publication(file, source) else Mobi6Publication(file, source)
        } catch (e: Throwable) {
            source.close()
            throw if (e is BookException) e else CorruptBookException("Not a readable MOBI/AZW3 file: ${e.message}", e)
        }
    }
}

/** Paths and helpers shared by both MOBI flavours. */
internal abstract class MobiPublicationBase(
    protected val file: MobiFile,
    private val source: RandomAccessSource,
) : Publication {
    protected val headers get() = file.headers
    protected val charset get() = file.headers.charset

    private val extensionCache = HashMap<Int, String>()

    /** Book-relative path of resource [id] (1-based), choosing the folder from the record type. */
    @Synchronized
    protected fun resourcePath(id: Int): String {
        val magic = file.resourceMagic(id)
        if (magic == "FONT") return "fonts/%05d.ttf".format(id)
        val ext = extensionCache.getOrPut(id) {
            val head = file.resource(id)?.let { it.copyOf(minOf(it.size, 16)) } ?: ByteArray(0)
            sniffImageExtension(head)
        }
        return "images/%05d.%s".format(id, ext)
    }

    override val metadata: BookMetadata by lazy {
        val h = file.baseHeaders.takeIf { it.exth.isNotEmpty() } ?: headers
        val coverOffset = (h.exthUint(201) ?: h.exthUint(202))?.takeIf { it < NULL_INDEX }
        BookMetadata(
            title = h.exthString(503) ?: h.title.toString(h.charset).trim().ifEmpty { null },
            authors = h.exthStrings(100),
            languages = h.exthStrings(524).ifEmpty { listOfNotNull(mobiLanguage(h.localeLanguage, h.localeRegion)) },
            identifier = h.exthString(104) ?: h.exthString(113) ?: h.uid.toString(),
            description = h.exthString(103),
            coverHref = coverOffset?.let { resourcePath(it.toInt() + 1) },
            publisher = h.exthString(101),
            date = h.exthString(106),
        )
    }

    override val readingDirection: ReadingDirection by lazy {
        when ((headers.exthString(527) ?: file.baseHeaders.exthString(527))?.lowercase()) {
            "rtl" -> ReadingDirection.RTL
            "ltr" -> ReadingDirection.LTR
            else -> ReadingDirection.DEFAULT
        }
    }

    override val isFixedLayout: Boolean get() = (headers.exthString(122) ?: file.baseHeaders.exthString(122)) == "true"

    override fun mediaType(href: String): String? {
        val path = href.substringBefore('#')
        return when {
            path.startsWith("text/") && path.endsWith(".xhtml") -> "application/xhtml+xml"
            path.startsWith("text/") -> "text/html"
            path.startsWith("styles/") -> "text/css"
            path.startsWith("fonts/") -> "font/ttf"
            path.endsWith(".svg") -> "image/svg+xml"
            path.endsWith(".jpg") -> "image/jpeg"
            path.endsWith(".png") -> "image/png"
            path.endsWith(".gif") -> "image/gif"
            path.endsWith(".bmp") -> "image/bmp"
            path.endsWith(".webp") -> "image/webp"
            else -> null
        }
    }

    /** Images and fonts; the subclass handles documents and stylesheets. */
    protected fun openResource(path: String): InputStream? {
        RESOURCE_PATH.matchEntire(path)?.let { m ->
            val id = m.groupValues[2].toInt()
            return file.resource(id)?.let(::ByteArrayInputStream)
        }
        return null
    }

    override fun close() = source.close()

    companion object {
        private val RESOURCE_PATH = Regex("""(images|fonts)/(\d{5})\.\w+""")

        fun sniffImageExtension(b: ByteArray): String = when {
            b.size >= 3 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() -> "jpg"
            b.size >= 4 && b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte() && b[2] == 'N'.code.toByte() -> "png"
            b.size >= 4 && String(b, 0, 4, Charsets.ISO_8859_1) == "GIF8" -> "gif"
            b.size >= 2 && b[0] == 'B'.code.toByte() && b[1] == 'M'.code.toByte() -> "bmp"
            b.size >= 12 && String(b, 0, 4, Charsets.ISO_8859_1) == "RIFF" && String(b, 8, 4, Charsets.ISO_8859_1) == "WEBP" -> "webp"
            else -> "bin"
        }
    }
}

/** A small LRU cache for assembled documents (the reader may load a document in two frames). */
internal class DocumentCache(private val capacity: Int = 6) {
    private val map = object : LinkedHashMap<String, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?) = size > capacity
    }

    @Synchronized
    fun get(key: String, make: () -> ByteArray): ByteArray = map[key] ?: make().also { map[key] = it }
}

/** KF8 (AZW3, and the KF8 part of joint MOBI files): XHTML rebuilt from skeletons and fragments. */
internal class Kf8Publication(file: MobiFile, source: RandomAccessSource) : MobiPublicationBase(file, source) {
    override val format = BookFormat.KF8

    private data class Skel(val numFrag: Int, val offset: Int, val length: Int)
    private data class Frag(val insertOffset: Int, val index: Long, val offset: Int, val length: Int)
    private data class Section(val number: Int, val skel: Skel, val frags: List<Frag>, val length: Int)

    private val flows: List<Pair<Int, Int>>
    private val sections: List<Section>
    private val cache = DocumentCache()

    init {
        val h = file.headers
        flows = if (h.fdst != NULL_INDEX) {
            val rec = file.partRecord(h.fdst)
            if (ascii(rec, 0, 4) != "FDST") throw CorruptBookException("Missing FDST record")
            val n = be32(rec, 8).toInt()
            (0 until n).map { i -> be32(rec, 12 + i * 8).toInt() to be32(rec, 16 + i * 8).toInt() }
        } else {
            emptyList()
        }
        if (h.skelIndex == NULL_INDEX || h.fragIndex == NULL_INDEX) throw CorruptBookException("KF8 index missing")
        val load: (Int) -> ByteArray = file::record
        val skels = MobiIndex.read(file.start + h.skelIndex.toInt(), load, h.charset).entries.map { e ->
            Skel(
                numFrag = (e.tag(1) ?: 0L).toInt(),
                offset = (e.tag(6, 0) ?: throw CorruptBookException("Bad skeleton entry")).toInt(),
                length = (e.tag(6, 1) ?: throw CorruptBookException("Bad skeleton entry")).toInt(),
            )
        }
        val fragData = MobiIndex.read(file.start + h.fragIndex.toInt(), load, h.charset)
        val frags = fragData.entries.mapIndexed { i, e ->
            Frag(
                insertOffset = e.name.trim().toIntOrNull() ?: throw CorruptBookException("Bad fragment entry"),
                index = e.tag(4) ?: i.toLong(),
                offset = (e.tag(6, 0) ?: 0L).toInt(),
                length = (e.tag(6, 1) ?: 0L).toInt(),
            )
        }
        var fragStart = 0
        sections = skels.mapIndexed { i, skel ->
            val end = minOf(frags.size, fragStart + skel.numFrag)
            val list = frags.subList(minOf(fragStart, end), end)
            fragStart = end
            Section(i, skel, list, skel.length + list.sumOf { it.length })
        }
    }

    override val spine: List<SpineItem> by lazy {
        sections.filter { it.frags.isNotEmpty() }.map { SpineItem(partPath(it.number), "application/xhtml+xml") }
    }

    override val resourcePaths: Collection<String> get() = spine.map { it.href }

    override val toc: List<TocEntry> by lazy {
        runCatching { readNcx() }.getOrDefault(emptyList())
    }

    override val writingModeHint: WritingModeHint by lazy {
        val css = flows.indices.drop(1).asSequence().mapNotNull { flowText(it) }.filter { !it.trimStart().startsWith("<") }
        val docs = spine.asSequence().take(3).mapNotNull { runCatching { partBytes(it.href) }.getOrNull() }
        WritingModeDetector.detect(
            css, docs,
            headers.exthString(525) ?: file.baseHeaders.exthString(525),
            readingDirection, metadata.languages,
        )
    }

    override fun open(href: String): InputStream? {
        val path = href.substringBefore('#')
        if (path.startsWith("text/part")) return runCatching { partBytes(path) }.getOrNull()?.let(::ByteArrayInputStream)
        FLOW_PATH.matchEntire(path)?.let { m ->
            val text = flowText(m.groupValues[2].toInt()) ?: return null
            return ByteArrayInputStream(rewriteLinks(text, fromDir = m.groupValues[1]).toByteArray(Charsets.UTF_8))
        }
        return openResource(path)
    }

    private fun partPath(sectionNumber: Int) = "text/part%04d.xhtml".format(sectionNumber)

    private fun partBytes(path: String): ByteArray = cache.get(path) {
        val number = PART_PATH.matchEntire(path)?.groupValues?.get(1)?.toInt() ?: throw CorruptBookException("Unknown part $path")
        val section = sections.getOrNull(number) ?: throw CorruptBookException("Unknown part $path")
        val html = assemble(section).toString(charset)
        addAidIds(rewriteLinks(html, fromDir = "text")).toByteArray(Charsets.UTF_8)
    }

    private fun assemble(section: Section): ByteArray {
        val text = file.fullText
        val skel = section.skel
        val end = skel.offset + section.length
        if (skel.offset < 0 || end > text.size) throw CorruptBookException("Part outside the text")
        val raw = text.copyOfRange(skel.offset, end)
        var skeleton = raw.copyOfRange(0, minOf(skel.length, raw.size))
        for (frag in section.frags) {
            val insert = (frag.insertOffset - skel.offset).coerceIn(0, skeleton.size)
            val off = skel.length + frag.offset
            if (off < 0 || off + frag.length > raw.size) throw CorruptBookException("Fragment outside its part")
            val fragRaw = raw.copyOfRange(off, off + frag.length)
            skeleton = skeleton.copyOfRange(0, insert) + fragRaw + skeleton.copyOfRange(insert, skeleton.size)
        }
        return skeleton
    }

    private fun flowText(index: Int): String? {
        val (start, end) = flows.getOrNull(index) ?: return null
        val text = file.fullText
        if (start < 0 || end > text.size || start > end) return null
        return String(text, start, end - start, charset)
    }

    /** Rewrites `kindle:` URIs to book paths relative to [fromDir] ("text" or "styles"). */
    private fun rewriteLinks(s: String, fromDir: String): String {
        val up = if (fromDir.isEmpty()) "" else "../"
        var out = KINDLE_POS.replace(s) { m ->
            val fid = m.groupValues[1].toLongOrNull(32) ?: return@replace m.value
            val off = m.groupValues[2].toLongOrNull(32) ?: 0L
            posHref(fid, off)?.let { target -> if (fromDir == "text") target.removePrefix("text/") else "$up$target" } ?: "#"
        }
        out = KINDLE_RESOURCE.replace(out) { m ->
            val id = m.groupValues[2].toIntOrNull(32) ?: return@replace m.value
            val mime = m.groupValues[3]
            when (m.groupValues[1]) {
                "embed" -> up + resourcePath(id)
                else -> up + if (mime == "image/svg+xml") "images/flow%04d.svg".format(id) else "styles/flow%04d.css".format(id)
            }
        }
        return out
    }

    /** Book path (with fragment) for a `kindle:pos:fid:…:off:…` link. */
    private fun posHref(fid: Long, off: Long): String? {
        val section = sections.firstOrNull { s -> s.frags.any { it.index == fid } } ?: return null
        val path = partPath(section.number)
        val frag = section.frags.first { it.index == fid }
        val text = file.fullText
        val start = section.skel.offset + section.skel.length + frag.offset
        val from = (start + off).toInt()
        val until = minOf(text.size, start + frag.length)
        if (from < 0 || from >= until) return path
        val tail = String(text, from, minOf(until - from, 4096), charset)
        val m = ANCHOR_ATTR.find(tail) ?: return path
        val (attr, value) = m.destructured
        return if (attr.equals("aid", ignoreCase = true)) "$path#aid-$value" else "$path#$value"
    }

    /** KF8 position links often point at `aid` attributes; give those elements a matching id. */
    private fun addAidIds(html: String): String = START_TAG.replace(html) { m ->
        val tag = m.value
        if (!tag.contains("aid=") || ID_ATTR.containsMatchIn(tag)) return@replace tag
        val aid = AID_ATTR.find(tag)?.groupValues?.get(2) ?: return@replace tag
        val close = if (tag.endsWith("/>")) tag.length - 2 else tag.length - 1
        tag.substring(0, close) + " id=\"aid-$aid\"" + tag.substring(close)
    }

    private fun readNcx(): List<TocEntry> {
        val h = file.headers
        if (h.ncxIndex == NULL_INDEX) return emptyList()
        val data = MobiIndex.read(file.start + h.ncxIndex.toInt(), file::record, h.charset)
        data class Item(val index: Int, val label: String, val level: Long?, val fid: Long?, val off: Long?, val parent: Long?)
        val items = data.entries.mapIndexed { i, e ->
            Item(i, data.cncx[e.tag(3)?.toInt()].orEmpty().trim(), e.tag(4), e.tag(6, 0), e.tag(6, 1), e.tag(21))
        }
        fun build(item: Item, depth: Int): TocEntry {
            val children = if (depth > 16) emptyList() else items.filter { it.parent == item.index.toLong() }.map { build(it, depth + 1) }
            val href = item.fid?.let { posHref(it, item.off ?: 0L) }
            return TocEntry(item.label.ifEmpty { "…" }, href, children)
        }
        return items.filter { it.level == 0L || it.parent == null }.map { build(it, 0) }
    }

    companion object {
        private val PART_PATH = Regex("""text/part(\d{4})\.xhtml""")
        private val FLOW_PATH = Regex("""(styles|images)/flow(\d{4})\.(?:css|svg)""")
        private val KINDLE_POS = Regex("""kindle:pos:fid:(\w+):off:(\w+)""")
        private val KINDLE_RESOURCE = Regex("""kindle:(flow|embed):(\w+)(?:\?mime=([\w/+.-]+))?""")
        private val ANCHOR_ATTR = Regex("""\s(id|name|aid)\s*=\s*['"]([^'"]*)['"]""", RegexOption.IGNORE_CASE)
        private val START_TAG = Regex("""<[A-Za-z][^<>]*>""")
        private val ID_ATTR = Regex("""\sid\s*=""", RegexOption.IGNORE_CASE)
        private val AID_ATTR = Regex("""\said\s*=\s*(['"])([^'"]*)\1""")
    }
}

/** MOBI 6: one HTML stream split at page breaks; `filepos` links and `recindex` images. */
internal class Mobi6Publication(file: MobiFile, source: RandomAccessSource) : MobiPublicationBase(file, source) {
    override val format = BookFormat.MOBI
    override val writingModeHint: WritingModeHint
        get() = if ((headers.exthString(525) ?: "").contains("vertical", true)) WritingModeHint.VERTICAL else WritingModeHint.HORIZONTAL

    private val raw: ByteArray = file.fullText
    private val sections: List<Pair<Int, Int>>
    private val fileposList: List<Int>
    private val cache = DocumentCache()

    init {
        val iso = String(raw, Charsets.ISO_8859_1) // one char per byte: regex offsets are byte offsets
        val breaks = PAGEBREAK.findAll(iso).map { it.range.first }.toList()
        val bounds = (listOf(0) + breaks + raw.size).distinct()
        sections = bounds.zipWithNext().filter { (a, b) -> b > a }
        fileposList = FILEPOS_IN_TAG.findAll(iso).mapNotNull { it.groupValues[1].toIntOrNull() }
            .filter { it in 0 until raw.size }.toSortedSet().toList()
    }

    override val spine: List<SpineItem> by lazy { sections.indices.map { SpineItem(sectionPath(it), "text/html") } }

    override val resourcePaths: Collection<String> get() = spine.map { it.href }

    override val toc: List<TocEntry> by lazy { runCatching { readToc() }.getOrDefault(emptyList()) }

    override fun open(href: String): InputStream? {
        val path = href.substringBefore('#')
        SECTION_PATH.matchEntire(path)?.let { m ->
            val i = m.groupValues[1].toInt()
            if (i !in sections.indices) return null
            return ByteArrayInputStream(cache.get(path) { sectionHtml(i).toByteArray(Charsets.UTF_8) })
        }
        return openResource(path)
    }

    private fun sectionPath(i: Int) = "text/section%04d.html".format(i)

    private fun sectionOf(pos: Int): Int = sections.indexOfFirst { (_, end) -> end > pos }.let { if (it < 0) sections.lastIndex else it }

    private fun sectionHtml(i: Int): String {
        val (start, end) = sections[i]
        val out = ByteArrayOutputStream(end - start + 256)
        var prev = start
        for (pos in fileposList) {
            if (pos < start || pos >= end) continue
            out.write(raw, prev, pos - prev)
            out.write("<a id=\"filepos$pos\"></a>".toByteArray(Charsets.US_ASCII))
            prev = pos
        }
        out.write(raw, prev, end - prev)
        var html = out.toByteArray().toString(charset)
        html = PAGEBREAK.replace(html, "")
        html = A_TAG.replace(html) { m ->
            val tag = m.value
            val pos = FILEPOS_ATTR.find(tag)?.groupValues?.get(1)?.toIntOrNull() ?: return@replace tag
            val href = "${sectionPath(sectionOf(pos)).removePrefix("text/")}#filepos$pos"
            FILEPOS_ATTR.replace(tag, " href=\"$href\"")
        }
        html = IMG_TAG.replace(html) { m ->
            val tag = m.value
            val id = RECINDEX_ATTR.find(tag)?.groupValues?.get(1)?.toIntOrNull() ?: return@replace tag
            RECINDEX_ATTR.replace(tag, " src=\"../${resourcePath(id)}\"")
        }
        return html
    }

    private fun readToc(): List<TocEntry> {
        val first = String(raw, sections.first().first, sections.first().second - sections.first().first, Charsets.ISO_8859_1)
        val reference = REFERENCE_TAG.findAll(first).firstOrNull { TOC_TYPE.containsMatchIn(it.value) } ?: return emptyList()
        val pos = FILEPOS_ATTR.find(reference.value)?.groupValues?.get(1)?.toIntOrNull() ?: return emptyList()
        val i = sectionOf(pos)
        val doc = Jsoup.parse(sectionHtml(i))
        return doc.select("a[href]").mapNotNull { a ->
            val href = a.attr("href")
            if (!href.startsWith("section")) return@mapNotNull null
            val title = a.text().trim().ifEmpty { return@mapNotNull null }
            TocEntry(title, "text/$href")
        }
    }

    companion object {
        private val PAGEBREAK = Regex("""<\s*(?:mbp:)?pagebreak[^>]*>""", RegexOption.IGNORE_CASE)
        private val FILEPOS_IN_TAG = Regex("""<[^<>]+filepos=['"]?(\d+)[^<>]*>""", RegexOption.IGNORE_CASE)
        private val FILEPOS_ATTR = Regex("""\sfilepos\s*=\s*['"]?0*(\d+)['"]?""", RegexOption.IGNORE_CASE)
        private val RECINDEX_ATTR = Regex("""\srecindex\s*=\s*['"]?0*(\d+)['"]?""", RegexOption.IGNORE_CASE)
        private val A_TAG = Regex("""<a\b[^<>]*>""", RegexOption.IGNORE_CASE)
        private val IMG_TAG = Regex("""<img\b[^<>]*>""", RegexOption.IGNORE_CASE)
        private val REFERENCE_TAG = Regex("""<reference\b[^<>]*>""", RegexOption.IGNORE_CASE)
        private val TOC_TYPE = Regex("""type\s*=\s*['"]?[^'">]*\btoc\b""", RegexOption.IGNORE_CASE)
        private val SECTION_PATH = Regex("""text/section(\d{4})\.html""")
    }
}

/** MOBI locale codes (subset of the full table; enough for a language hint). */
internal fun mobiLanguage(language: Int, region: Int): String? {
    if (language == 4) {
        return listOf("zh", "zh-TW", "zh-CN", "zh-HK", "zh-SG").getOrNull(region shr 2) ?: "zh"
    }
    return mapOf(
        1 to "ar", 2 to "bg", 3 to "ca", 5 to "cs", 6 to "da", 7 to "de", 8 to "el", 9 to "en", 10 to "es",
        11 to "fi", 12 to "fr", 13 to "he", 14 to "hu", 15 to "is", 16 to "it", 17 to "ja", 18 to "ko",
        19 to "nl", 20 to "no", 21 to "pl", 22 to "pt", 24 to "ro", 25 to "ru", 26 to "hr", 27 to "sk",
        29 to "sv", 30 to "th", 31 to "tr", 33 to "id", 34 to "uk", 41 to "fa", 42 to "vi", 57 to "hi",
    )[language]
}
