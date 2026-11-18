package yokai.core.ebook

import java.io.ByteArrayInputStream
import org.jsoup.Jsoup
import org.jsoup.parser.Parser

/**
 * Decides whether a book is read as text or with the existing image (manga) reader.
 * The user can override the result per book; this is only the automatic default.
 */
object ContentClassifier {

    data class Stats(val documents: Int, val textChars: Long, val images: Int, val documentsWithImages: Int)

    /** Average non-space characters per document below which a book counts as "images only". */
    const val MAX_TEXT_PER_DOC = 50

    /** Fraction of documents that must contain an image for an image book. */
    const val MIN_IMAGE_RATIO = 0.5

    fun classify(publication: Publication, maxDocuments: Int = 40): ContentKind {
        if (publication.isFixedLayout) return ContentKind.COMIC
        val stats = stats(publication, maxDocuments)
        return classify(stats)
    }

    fun classify(stats: Stats): ContentKind {
        if (stats.documents == 0) return ContentKind.TEXT
        val avgText = stats.textChars.toDouble() / stats.documents
        val imageRatio = stats.documentsWithImages.toDouble() / stats.documents
        return if (avgText < MAX_TEXT_PER_DOC && imageRatio >= MIN_IMAGE_RATIO) ContentKind.COMIC else ContentKind.TEXT
    }

    fun stats(publication: Publication, maxDocuments: Int = 40): Stats {
        var docs = 0
        var text = 0L
        var images = 0
        var withImages = 0
        for (item in publication.spine) {
            if (docs >= maxDocuments) break
            if (!item.linear) continue
            val type = item.mediaType.lowercase()
            if ("html" !in type && "xml" !in type) continue
            val bytes = publication.open(item.href)?.use { it.readBytes() } ?: continue
            val doc = Jsoup.parse(ByteArrayInputStream(bytes), null, "", Parser.xmlParser())
            val body = doc.getAllElements().firstOrNull { it.tagName().substringAfter(':').equals("body", true) } ?: doc
            text += body.text().count { !it.isWhitespace() }
            val n = body.getAllElements().count {
                when (it.tagName().substringAfter(':').lowercase()) {
                    "img", "image" -> true
                    "object" -> it.attr("type").startsWith("image/")
                    else -> false
                }
            }
            images += n
            if (n > 0) withImages++
            docs++
        }
        return Stats(docs, text, images, withImages)
    }
}
