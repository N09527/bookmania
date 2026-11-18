package yokai.core.ebook

import java.io.Closeable
import java.io.InputStream

enum class BookFormat { EPUB, MOBI, KF8, KFX, UNKNOWN }

/** Whether a book is read as text (WebView reader) or as images (the existing manga reader). */
enum class ContentKind { TEXT, COMIC }

/** Page progression declared by the book. */
enum class ReadingDirection { LTR, RTL, DEFAULT }

/** Writing mode the book appears to use; the reader's "follow the book" setting uses it. */
enum class WritingModeHint { HORIZONTAL, VERTICAL }

data class BookMetadata(
    val title: String?,
    val authors: List<String>,
    val languages: List<String>,
    val identifier: String?,
    val description: String?,
    /** Container path of the cover image, if the book declares one. */
    val coverHref: String?,
)

data class SpineItem(
    /** Container path, for example `OEBPS/text/ch01.xhtml` or `part0003.xhtml`. */
    val href: String,
    val mediaType: String,
    val linear: Boolean = true,
)

data class TocEntry(
    val title: String,
    /** Container path with optional `#fragment`; null for headings without a target. */
    val href: String?,
    val children: List<TocEntry> = emptyList(),
)

/**
 * A parsed book. Paths ("hrefs") are container paths: the WebView requests them under the
 * book's virtual origin and the reader resolves them with [open].
 */
interface Publication : Closeable {
    val format: BookFormat
    val metadata: BookMetadata
    val spine: List<SpineItem>
    val toc: List<TocEntry>
    val readingDirection: ReadingDirection
    val writingModeHint: WritingModeHint
    /** Fixed-layout books (EPUB `rendition:layout` = pre-paginated) are read as images. */
    val isFixedLayout: Boolean

    /** Raw bytes of a resource (fonts already de-obfuscated), or null when it does not exist. */
    fun open(href: String): InputStream?

    fun mediaType(href: String): String?

    /** All resource paths, for diagnostics and tests. */
    val resourcePaths: Collection<String>
}

/** Media type from a file name, for resources the book does not describe itself. */
fun mediaTypeFromName(name: String): String? = when (name.substringAfterLast('.', "").lowercase()) {
    "xhtml", "xht" -> "application/xhtml+xml"
    "html", "htm" -> "text/html"
    "css" -> "text/css"
    "jpg", "jpeg" -> "image/jpeg"
    "png" -> "image/png"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "svg" -> "image/svg+xml"
    "bmp" -> "image/bmp"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ncx" -> "application/x-dtbncx+xml"
    "opf" -> "application/oebps-package+xml"
    "js" -> "text/javascript"
    "mp3" -> "audio/mpeg"
    "mp4" -> "video/mp4"
    else -> null
}
