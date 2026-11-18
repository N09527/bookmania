package yokai.core.ebook.epub

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import yokai.core.ebook.BookException
import yokai.core.ebook.BookFormat
import yokai.core.ebook.BookMetadata
import yokai.core.ebook.BookPaths
import yokai.core.ebook.CorruptBookException
import yokai.core.ebook.DrmProtectedException
import yokai.core.ebook.Publication
import yokai.core.ebook.ReadingDirection
import yokai.core.ebook.SpineItem
import yokai.core.ebook.TocEntry
import yokai.core.ebook.WritingModeHint
import yokai.core.ebook.io.RandomAccessSource
import yokai.core.ebook.io.ZipReader
import yokai.core.ebook.mediaTypeFromName

class EpubPublication internal constructor(
    private val zip: ZipReader,
    override val metadata: BookMetadata,
    override val spine: List<SpineItem>,
    override val toc: List<TocEntry>,
    override val readingDirection: ReadingDirection,
    override val writingModeHint: WritingModeHint,
    override val isFixedLayout: Boolean,
    private val mediaTypes: Map<String, String>,
    /** Container path -> obfuscation algorithm. */
    private val obfuscation: Map<String, String>,
    private val uniqueIdentifier: String?,
    private val uuidIdentifier: String?,
    /** Path of the package document (OPF). */
    val packagePath: String,
) : Publication {
    override val format = BookFormat.EPUB

    override val resourcePaths: Collection<String> get() = zip.entries.keys

    override fun open(href: String): InputStream? {
        val entry = zip.find(BookPaths.splitFragment(href).first) ?: return null
        val algorithm = obfuscation[entry.name] ?: return zip.open(entry)
        val bytes = zip.open(entry).use { it.readBytes() }
        return ByteArrayInputStream(FontObfuscation.deobfuscate(bytes, algorithm, uniqueIdentifier, uuidIdentifier))
    }

    override fun mediaType(href: String): String? {
        val path = BookPaths.splitFragment(href).first
        val name = zip.find(path)?.name ?: path
        return mediaTypes[name] ?: mediaTypeFromName(name)
    }

    override fun close() = zip.close()
}

object EpubParser {
    private const val CONTAINER = "META-INF/container.xml"
    private const val APPLE_OPTIONS = "META-INF/com.apple.ibooks.display-options.xml"
    private const val CSS_BUDGET = 4L shl 20

    private val VERTICAL_DECL = Regex("""(?:-epub-|-webkit-)?writing-mode\s*:\s*(?:vertical-rl|vertical-lr|tb-rl)\b""", RegexOption.IGNORE_CASE)
    private val CSS_RULE = Regex("""([^{}@;]+)\{([^{}]*)\}""")
    private val CSS_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

    /** Parses an EPUB. The source is owned by the result (closed with it), or closed on failure. */
    fun parse(source: RandomAccessSource): EpubPublication {
        val zip = try {
            ZipReader(source)
        } catch (e: Throwable) {
            source.close()
            throw if (e is BookException) e else CorruptBookException("Not a readable EPUB", e)
        }
        return try {
            parse(zip)
        } catch (e: Throwable) {
            zip.close()
            throw if (e is BookException) e else CorruptBookException("Not a readable EPUB: ${e.message}", e)
        }
    }

    private data class Item(val id: String, val path: String, val mediaType: String, val properties: Set<String>)

    private class Encryption(val obfuscated: Map<String, String>, val drmScheme: String?)

    internal fun parse(zip: ZipReader): EpubPublication {
        val encryption = readEncryption(zip)
        encryption.drmScheme?.let { throw DrmProtectedException(it) }

        val opfPath = findPackagePath(zip)
        val opfBytes = zip.readBytes(opfPath) ?: throw CorruptBookException("Package document missing: $opfPath")
        val pkg = parseXml(opfBytes).descendantsNamed("package").firstOrNull()
            ?: throw CorruptBookException("Invalid package document")

        // Metadata
        val md = pkg.descendantsNamed("metadata").firstOrNull()
        val uidRef = pkg.attr("unique-identifier")
        val identifiers = md?.descendantsNamed("identifier").orEmpty()
        val uniqueId = (identifiers.firstOrNull { uidRef.isNotEmpty() && it.attr("id") == uidRef } ?: identifiers.firstOrNull())
            ?.text()?.trim()?.ifEmpty { null }
        val uuidId = identifiers.map { it.text().trim() }.firstOrNull { FontObfuscation.adobeKey(it) != null }
        val metas = md?.descendantsNamed("meta").orEmpty()
        fun metaProperty(p: String) = metas.firstOrNull { it.attr("property") == p }?.text()?.trim()
        fun metaName(n: String) = metas.firstOrNull { it.attr("name").equals(n, ignoreCase = true) }?.attr("content")?.trim()

        // Manifest
        val items = pkg.descendantsNamed("manifest").firstOrNull()?.childrenNamed("item").orEmpty().mapNotNull { el ->
            val href = el.attr("href").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val resolved = BookPaths.resolve(opfPath, href) ?: return@mapNotNull null
            val path = BookPaths.splitFragment(resolved).first
            val actual = zip.find(path)?.name ?: path
            val mediaType = el.attr("media-type").trim().ifEmpty { mediaTypeFromName(actual) ?: "application/octet-stream" }
            Item(el.attr("id"), actual, mediaType, el.attr("properties").split(' ', '\t', '\n').filter { it.isNotBlank() }.toSet())
        }
        val byId = items.associateBy { it.id }

        // Spine
        val spineEl = pkg.descendantsNamed("spine").firstOrNull()
        val itemRefs = spineEl?.childrenNamed("itemref").orEmpty()
        val spine = itemRefs.mapNotNull { ref ->
            val item = byId[ref.attr("idref")] ?: return@mapNotNull null
            if (!zip.has(item.path)) return@mapNotNull null
            SpineItem(item.path, item.mediaType, linear = !ref.attr("linear").equals("no", ignoreCase = true))
        }
        if (spine.isEmpty()) throw CorruptBookException("The book has no readable content (empty spine)")
        val direction = when (spineEl?.attr("page-progression-direction")?.trim()?.lowercase()) {
            "rtl" -> ReadingDirection.RTL
            "ltr" -> ReadingDirection.LTR
            else -> ReadingDirection.DEFAULT
        }

        // Layout
        val fixed = metaProperty("rendition:layout") == "pre-paginated" ||
            metaName("fixed-layout") == "true" ||
            (itemRefs.isNotEmpty() && itemRefs.all { "rendition:layout-pre-paginated" in it.attr("properties") }) ||
            appleFixedLayout(zip)

        // Cover
        val cover = items.firstOrNull { "cover-image" in it.properties }?.path
            ?: metaName("cover")?.let { id -> byId[id]?.takeIf { it.mediaType.startsWith("image/") }?.path }

        // Table of contents: EPUB 3 navigation document, then EPUB 2 NCX.
        var toc = items.firstOrNull { "nav" in it.properties }?.let { runCatching { parseNav(zip, it.path) }.getOrNull() }.orEmpty()
        if (toc.isEmpty()) {
            val ncx = spineEl?.attr("toc")?.let { byId[it] } ?: items.firstOrNull { it.mediaType == "application/x-dtbncx+xml" }
            toc = ncx?.let { runCatching { parseNcx(zip, it.path) }.getOrNull() }.orEmpty()
        }

        val languages = md?.descendantsNamed("language")?.map { it.text().trim() }?.filter { it.isNotEmpty() }.orEmpty()
        val metadata = BookMetadata(
            title = md?.descendantsNamed("title")?.firstOrNull()?.text()?.trim()?.ifEmpty { null },
            authors = md?.descendantsNamed("creator")?.map { it.text().trim() }?.filter { it.isNotEmpty() }.orEmpty(),
            languages = languages,
            identifier = uniqueId,
            description = md?.descendantsNamed("description")?.firstOrNull()?.text()?.trim()?.ifEmpty { null },
            coverHref = cover,
        )
        val writingMode = detectWritingMode(zip, items, spine, metaName("primary-writing-mode"), direction, languages)

        return EpubPublication(
            zip = zip,
            metadata = metadata,
            spine = spine,
            toc = toc,
            readingDirection = direction,
            writingModeHint = writingMode,
            isFixedLayout = fixed,
            mediaTypes = items.associate { it.path to it.mediaType },
            obfuscation = encryption.obfuscated.mapKeys { (k, _) -> zip.find(k)?.name ?: k },
            uniqueIdentifier = uniqueId,
            uuidIdentifier = uuidId,
            packagePath = opfPath,
        )
    }

    private fun findPackagePath(zip: ZipReader): String {
        val container = zip.readBytes(CONTAINER)?.let { parseXml(it) }
        val fromContainer = container?.descendantsNamed("rootfile")
            ?.firstOrNull { it.attr("media-type").isBlank() || it.attr("media-type").trim() == "application/oebps-package+xml" }
            ?.attr("full-path")?.let { BookPaths.resolve("", it) }
            ?.let { zip.find(it)?.name }
        return fromContainer
            ?: zip.entries.keys.firstOrNull { it.endsWith(".opf", ignoreCase = true) }
            ?: throw CorruptBookException("No package document (OPF) found")
    }

    /** Font obfuscation is fine; any other encryption, or known DRM files, means DRM. */
    private fun readEncryption(zip: ZipReader): Encryption {
        val knownScheme = when {
            zip.has("META-INF/license.lcpl") -> "Readium LCP"
            zip.has("META-INF/sinf.xml") -> "Apple FairPlay"
            else -> null
        }
        val bytes = zip.readBytes("META-INF/encryption.xml") ?: return Encryption(emptyMap(), knownScheme)
        val obfuscated = HashMap<String, String>()
        var otherEncryption = false
        for (data in parseXml(bytes).descendantsNamed("encrypteddata")) {
            val algorithm = data.descendantsNamed("encryptionmethod").firstOrNull()?.attr("Algorithm")?.trim().orEmpty()
            val uri = data.descendantsNamed("cipherreference").firstOrNull()?.attr("URI")?.trim().orEmpty()
            val path = BookPaths.resolve("", uri)?.let { BookPaths.splitFragment(it).first } ?: continue
            if (FontObfuscation.isObfuscation(algorithm)) obfuscated[path] = algorithm else otherEncryption = true
        }
        val scheme = knownScheme ?: if (otherEncryption) {
            if (zip.has("META-INF/rights.xml")) "Adobe ADEPT" else "unknown"
        } else {
            null
        }
        return Encryption(obfuscated, scheme)
    }

    private fun appleFixedLayout(zip: ZipReader): Boolean {
        val bytes = zip.readBytes(APPLE_OPTIONS) ?: return false
        return parseXml(bytes).descendantsNamed("option")
            .any { it.attr("name") == "fixed-layout" && it.text().trim() == "true" }
    }

    private fun parseNav(zip: ZipReader, navPath: String): List<TocEntry> {
        val doc = parseXml(zip.readBytes(navPath) ?: return emptyList())
        val navs = doc.descendantsNamed("nav")
        val nav = navs.firstOrNull { el -> el.attr("epub:type").split(' ').contains("toc") || el.attr("role") == "doc-toc" }
            ?: navs.firstOrNull()
            ?: return emptyList()
        val ol = nav.childrenNamed("ol").firstOrNull() ?: nav.descendantsNamed("ol").firstOrNull() ?: return emptyList()
        return parseNavList(ol, navPath)
    }

    private fun parseNavList(ol: Element, base: String): List<TocEntry> = ol.childrenNamed("li").mapNotNull { li ->
        val label = li.children().firstOrNull { it.local() == "a" || it.local() == "span" }
        val title = label?.text()?.trim().orEmpty()
        val href = label?.takeIf { it.local() == "a" }?.attr("href")?.takeIf { it.isNotBlank() }?.let { BookPaths.resolve(base, it) }
        val children = li.childrenNamed("ol").firstOrNull()?.let { parseNavList(it, base) }.orEmpty()
        if (title.isEmpty() && children.isEmpty()) null else TocEntry(title.ifEmpty { "…" }, href, children)
    }

    private fun parseNcx(zip: ZipReader, ncxPath: String): List<TocEntry> {
        val doc = parseXml(zip.readBytes(ncxPath) ?: return emptyList())
        val navMap = doc.descendantsNamed("navmap").firstOrNull() ?: return emptyList()
        return parseNavPoints(navMap, ncxPath)
    }

    private fun parseNavPoints(parent: Element, base: String): List<TocEntry> = parent.childrenNamed("navpoint").map { np ->
        val title = np.firstChildNamed("navlabel")?.descendantsNamed("text")?.firstOrNull()?.text()?.trim().orEmpty()
        val src = np.firstChildNamed("content")?.attr("src")?.takeIf { it.isNotBlank() }?.let { BookPaths.resolve(base, it) }
        TocEntry(title.ifEmpty { "…" }, src, parseNavPoints(np, base))
    }

    /**
     * "Follow the book" needs to know whether the book is set vertically. Evidence, in order:
     * the `primary-writing-mode` meta, a vertical `writing-mode` that applies to `html`/`body`
     * of the first documents (inline style, or a CSS rule whose selector matches them).
     */
    private fun detectWritingMode(
        zip: ZipReader,
        items: List<Item>,
        spine: List<SpineItem>,
        primaryWritingMode: String?,
        direction: ReadingDirection,
        languages: List<String>,
    ): WritingModeHint {
        primaryWritingMode?.let {
            if (it.contains("vertical", ignoreCase = true)) return WritingModeHint.VERTICAL
            if (it.contains("horizontal", ignoreCase = true)) return WritingModeHint.HORIZONTAL
        }
        val verticalSelectors = ArrayList<String>()
        var budget = CSS_BUDGET
        for (item in items) {
            if (item.mediaType != "text/css") continue
            val entry = zip.find(item.path) ?: continue
            if (entry.size > budget) break
            budget -= entry.size
            zip.readText(entry.name)?.let { collectVerticalSelectors(it, verticalSelectors) }
        }
        for (s in spine.filter { it.linear }.take(3)) {
            val doc = runCatching { parseXml(zip.readBytes(s.href) ?: return@runCatching null) }.getOrNull() ?: continue
            doc.descendantsNamed("style").forEach { collectVerticalSelectors(it.data(), verticalSelectors) }
            for (el in doc.descendantsNamed("html") + doc.descendantsNamed("body")) {
                if (VERTICAL_DECL.containsMatchIn(el.attr("style"))) return WritingModeHint.VERTICAL
                if (verticalSelectors.any { sel -> matches(el, sel) }) return WritingModeHint.VERTICAL
            }
        }
        val cjk = languages.any { it.lowercase().startsWith("ja") || it.lowercase().startsWith("zh") }
        return if (direction == ReadingDirection.RTL && cjk && verticalSelectors.isNotEmpty()) {
            WritingModeHint.VERTICAL
        } else {
            WritingModeHint.HORIZONTAL
        }
    }

    private fun collectVerticalSelectors(css: String, out: MutableList<String>) {
        val text = CSS_COMMENT.replace(css, " ")
        for (m in CSS_RULE.findAll(text)) {
            if (VERTICAL_DECL.containsMatchIn(m.groupValues[2])) {
                m.groupValues[1].split(',').map { it.trim() }.filter { it.isNotEmpty() }.forEach(out::add)
            }
        }
    }

    private fun matches(el: Element, selector: String): Boolean = try {
        el.`is`(selector)
    } catch (_: Exception) {
        false
    }

    internal fun parseXml(bytes: ByteArray): Document =
        Jsoup.parse(ByteArrayInputStream(bytes), null, "", Parser.xmlParser())
}

/** Local name of an element, ignoring any namespace prefix (`dc:title` -> `title`). */
internal fun Element.local(): String = tagName().substringAfter(':').lowercase()

internal fun Element.childrenNamed(name: String): List<Element> = children().filter { it.local() == name }

internal fun Element.firstChildNamed(name: String): Element? = children().firstOrNull { it.local() == name }

/** All descendants (including this element) with the given local name. */
internal fun Element.descendantsNamed(name: String): List<Element> = getAllElements().filter { it.local() == name }
