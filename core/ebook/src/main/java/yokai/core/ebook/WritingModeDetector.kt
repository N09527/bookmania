package yokai.core.ebook

import java.io.ByteArrayInputStream
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser

/**
 * Works out whether a book is typeset vertically, for the reader's "follow the book" setting.
 *
 * Evidence, strongest first:
 * 1. a `writing-mode` that applies to `html`/`body` of the first documents (inline style, or a
 *    CSS rule whose selector matches them) — this is what a browser would actually render;
 * 2. a vertical primary writing mode in the metadata (OPF `primary-writing-mode`, MOBI EXTH 525);
 * 3. right-to-left CJK books with vertical rules anywhere.
 *
 * A *horizontal* primary writing mode is not used as evidence: Calibre writes `horizontal-rl`
 * into every right-to-left KF8 book that has none (calibre/ebooks/mobi/writer8/mobi.py,
 * "Without this the Kindle renderer does not respect page_progression_direction"), including
 * books whose CSS is vertical.
 */
object WritingModeDetector {
    private val VERTICAL_DECL = Regex("""(?:-epub-|-webkit-)?writing-mode\s*:\s*(?:vertical-rl|vertical-lr|tb-rl|tb)\b""", RegexOption.IGNORE_CASE)
    private val HORIZONTAL_DECL = Regex("""(?:-epub-|-webkit-)?writing-mode\s*:\s*(?:horizontal-tb|lr-tb|lr)\b""", RegexOption.IGNORE_CASE)
    private val CSS_RULE = Regex("""([^{}@;]+)\{([^{}]*)\}""")
    private val CSS_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

    fun detect(
        stylesheets: Sequence<String>,
        firstDocuments: Sequence<ByteArray>,
        primaryWritingMode: String?,
        direction: ReadingDirection,
        languages: List<String>,
        documentsAreHtml: Boolean = false,
    ): WritingModeHint {
        val vertical = ArrayList<String>()
        val horizontal = ArrayList<String>()
        stylesheets.forEach { collect(it, vertical, horizontal) }
        var rootHorizontal = false
        for (bytes in firstDocuments) {
            val doc = runCatching {
                Jsoup.parse(ByteArrayInputStream(bytes), null, "", if (documentsAreHtml) Parser.htmlParser() else Parser.xmlParser())
            }.getOrNull() ?: continue
            doc.getAllElements().filter { it.local() == "style" }.forEach { collect(it.data().ifEmpty { it.text() }, vertical, horizontal) }
            for (el in doc.getAllElements().filter { it.local() == "html" || it.local() == "body" }) {
                val style = el.attr("style")
                if (VERTICAL_DECL.containsMatchIn(style) || vertical.any { matches(el, it) }) return WritingModeHint.VERTICAL
                if (HORIZONTAL_DECL.containsMatchIn(style) || horizontal.any { matches(el, it) }) rootHorizontal = true
            }
        }
        if (rootHorizontal) return WritingModeHint.HORIZONTAL
        if (primaryWritingMode?.contains("vertical", ignoreCase = true) == true) return WritingModeHint.VERTICAL
        val cjk = languages.any { it.lowercase().startsWith("ja") || it.lowercase().startsWith("zh") }
        return if (direction == ReadingDirection.RTL && cjk && vertical.isNotEmpty()) WritingModeHint.VERTICAL else WritingModeHint.HORIZONTAL
    }

    private fun collect(css: String, vertical: MutableList<String>, horizontal: MutableList<String>) {
        val text = CSS_COMMENT.replace(css, " ")
        for (m in CSS_RULE.findAll(text)) {
            val body = m.groupValues[2]
            val target = when {
                VERTICAL_DECL.containsMatchIn(body) -> vertical
                HORIZONTAL_DECL.containsMatchIn(body) -> horizontal
                else -> continue
            }
            m.groupValues[1].split(',').map { it.trim() }.filter { it.isNotEmpty() }.forEach(target::add)
        }
    }

    private fun matches(el: Element, selector: String): Boolean = try {
        el.`is`(selector)
    } catch (_: Exception) {
        false
    }

    private fun Element.local(): String = tagName().substringAfter(':').lowercase()
}
