package yokai.ebook

import android.app.Activity
import android.content.Context
import android.content.Intent
import co.touchlab.kermit.Logger
import com.hippo.unifile.UniFile
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.source.LocalSource
import java.util.concurrent.ConcurrentHashMap
import yokai.core.ebook.ContentClassifier
import yokai.core.ebook.ContentKind
import yokai.core.ebook.DrmProtectedException
import yokai.i18n.MR
import yokai.util.lang.getString

/** Thrown while loading a Local Source chapter that must be read in the text reader. */
class TextBookException(message: String) : Exception(message)

/**
 * Decides which reader opens a Local Source chapter.
 * - `.mobi` / `.azw3`: always the text reader (known from the file name, no I/O).
 * - `.epub`: classified once in the background (ContentClassifier); comic-like EPUBs keep using
 *   the existing manga reader exactly as before.
 */
object EbookRouter {

    /** Classification per chapter url, for this process. */
    private val epubKinds = ConcurrentHashMap<String, ContentKind>()

    private fun extensionOf(chapterUrl: String) = chapterUrl.substringAfterLast('/').substringAfterLast('.', "")

    /** An intent for the text reader when [chapter] is known to be a text book, otherwise null. */
    fun intentFor(context: Context, manga: Manga, chapter: Chapter): Intent? {
        if (manga.source != LocalSource.ID) return null
        val ext = extensionOf(chapter.url)
        val isText = LocalEbooks.isTextOnly(ext) ||
            (ext.equals("epub", ignoreCase = true) && epubKinds[chapter.url] == ContentKind.TEXT)
        return if (isText) EbookReaderActivity.newIntent(context, manga, chapter) else null
    }

    /** Called from ChapterLoader (I/O thread) for Local Source EPUB chapters. */
    fun isTextEpub(chapterUrl: String, file: UniFile, context: Context): Boolean {
        epubKinds[chapterUrl]?.let { return it == ContentKind.TEXT }
        val kind = try {
            LocalEbooks.open(file, context).use { ContentClassifier.classify(it) }
        } catch (e: DrmProtectedException) {
            // The text reader explains DRM clearly; the image reader would show broken pages.
            ContentKind.TEXT
        } catch (e: Throwable) {
            // Damaged or unusual files keep the existing behaviour of the image reader.
            Logger.w(e) { "EPUB classification failed, using the image reader" }
            ContentKind.COMIC
        }
        epubKinds[chapterUrl] = kind
        return kind == ContentKind.TEXT
    }

    fun textBookException(context: Context) = TextBookException(context.getString(MR.strings.ebook_opens_in_text_reader))

    /** Replaces [activity] (the image reader) with the text reader, without a second transition. */
    fun handOff(activity: Activity, mangaId: Long?, chapterId: Long?): Boolean {
        if (mangaId == null || mangaId < 0 || chapterId == null || chapterId < 0) return false
        val intent = EbookReaderActivity.newIntent(activity, mangaId, chapterId)
            .addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        activity.startActivity(intent)
        activity.finish()
        @Suppress("DEPRECATION")
        activity.overridePendingTransition(0, 0)
        return true
    }

    /** For the image reader's initial load: hands off when [error] says the chapter is a text book. */
    fun handOffOnError(activity: Activity, error: Throwable): Boolean {
        if (error !is TextBookException) return false
        val extras = activity.intent.extras ?: return false
        return handOff(activity, extras.getLong("manga", -1L), extras.getLong("chapter", -1L))
    }
}
