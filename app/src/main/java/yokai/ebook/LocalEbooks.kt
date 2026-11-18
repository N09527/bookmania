package yokai.ebook

import android.content.Context
import com.hippo.unifile.UniFile
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.util.system.extension
import java.io.FileInputStream
import java.io.InputStream
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Locale
import yokai.core.archive.util.openFileDescriptor
import yokai.core.ebook.BookOpener
import yokai.core.ebook.Publication
import yokai.core.ebook.io.FileChannelSource
import yokai.core.ebook.io.RandomAccessSource

/** Local Source support for text-book files. EPUB keeps its existing handling in LocalSource. */
object LocalEbooks {

    /** Extensions that are only readable by the text reader (EPUB can be either). */
    val TEXT_ONLY_EXTENSIONS = setOf("mobi", "azw3")

    fun isTextOnly(extension: String?): Boolean = extension?.lowercase() in TEXT_ONLY_EXTENSIONS

    fun isTextOnly(file: UniFile): Boolean = !file.isDirectory && isTextOnly(file.extension)

    /** Random access to the file; works for file:// and content:// locations. */
    fun source(file: UniFile, context: Context): RandomAccessSource {
        val pfd = file.openFileDescriptor(context, "r")
        return try {
            val stream = FileInputStream(pfd.fileDescriptor)
            FileChannelSource(stream.channel) {
                stream.close()
                pfd.close()
            }
        } catch (e: Throwable) {
            pfd.close()
            throw e
        }
    }

    /** Opens the book; throws the core:ebook exceptions (DRM, damaged, unsupported). */
    fun open(file: UniFile, context: Context): Publication = BookOpener.open(source(file, context), file.extension)

    fun coverStream(pub: Publication): InputStream? = pub.metadata.coverHref?.let { pub.open(it) }

    /** Same fields as the EPUB metadata of LocalSource (yokai.util.fillMetadata). */
    fun fillMetadata(pub: Publication, chapter: SChapter, manga: SManga) {
        val md = pub.metadata
        md.authors.firstOrNull()?.let { manga.author = it }
        md.description?.let { manga.description = it }
        md.title?.let { chapter.name = it }
        (md.publisher ?: md.authors.firstOrNull())?.let { chapter.scanlator = it }
        md.date?.let { parseDate(it) }?.let { chapter.date_upload = it }
    }

    /** ISO 8601 dates such as `2026-11-18`, `2026-11-18T06:21:55Z` or `2026-11-18T06:21:55.145693+00:00`. */
    internal fun parseDate(text: String): Long? {
        val t = text.trim().replace(FRACTION, "")
        for (pattern in listOf("yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mmXXX", "yyyy-MM-dd")) {
            try {
                val format = SimpleDateFormat(pattern, Locale.ROOT).apply { isLenient = false }
                return format.parse(t)?.time
            } catch (_: ParseException) {
                // try the next pattern
            }
        }
        return null
    }

    private val FRACTION = Regex("""(?<=:\d\d)\.\d+""")
}
