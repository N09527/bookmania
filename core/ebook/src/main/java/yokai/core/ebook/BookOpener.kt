package yokai.core.ebook

import yokai.core.ebook.epub.EpubParser
import yokai.core.ebook.io.RandomAccessSource
import yokai.core.ebook.mobi.MobiParser

/** Opens any supported book file. The source is owned by the result, or closed on failure. */
object BookOpener {

    /** File extensions offered to Local Source (EPUB was already listed for image books). */
    val TEXT_BOOK_EXTENSIONS = setOf("epub", "mobi", "azw3")

    fun open(source: RandomAccessSource, extension: String? = null): Publication {
        val format = try {
            FormatDetector.detect(source, extension)
        } catch (e: Throwable) {
            source.close()
            throw CorruptBookException("Cannot read the file", e)
        }
        return when (format) {
            BookFormat.EPUB -> EpubParser.parse(source)
            BookFormat.MOBI, BookFormat.KF8 -> MobiParser.parse(source)
            BookFormat.KFX -> {
                source.close()
                throw UnsupportedBookException("KFX books are not supported")
            }
            BookFormat.UNKNOWN -> {
                source.close()
                throw CorruptBookException("Unknown or damaged book file")
            }
        }
    }
}
