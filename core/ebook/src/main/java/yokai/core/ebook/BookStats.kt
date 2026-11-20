package yokai.core.ebook

import java.io.ByteArrayInputStream
import org.jsoup.Jsoup
import org.jsoup.parser.Parser

/**
 * Text size of a book, for whole-book progress (the progress slider, the estimated page numbers in
 * the chapter list) without laying out every document.
 */
object BookStats {

    /**
     * Non-whitespace characters in the body text of each spine item, in spine order (0 for items that
     * are not (X)HTML documents or cannot be read). Ruby annotations count like other text, as in the
     * reader shell's own count.
     */
    fun charCounts(publication: Publication): IntArray = IntArray(publication.spine.size) { i ->
        val item = publication.spine[i]
        val type = item.mediaType.lowercase()
        if ("html" !in type && "xml" !in type) return@IntArray 0
        val bytes = try {
            publication.open(item.href)?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        } ?: return@IntArray 0
        countText(bytes)
    }

    internal fun countText(bytes: ByteArray): Int {
        val doc = Jsoup.parse(ByteArrayInputStream(bytes), null, "", Parser.xmlParser())
        val body = doc.getAllElements().firstOrNull { it.tagName().substringAfter(':').equals("body", true) } ?: doc
        // wholeText keeps every text node (Element.text() would also include them, but normalizes
        // spaces first); only non-whitespace characters are counted either way.
        return body.wholeText().count { !it.isWhitespace() }
    }
}
