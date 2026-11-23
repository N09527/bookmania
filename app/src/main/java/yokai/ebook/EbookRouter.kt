package yokai.ebook

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.view.Menu
import android.view.MenuItem
import android.widget.Toast
import co.touchlab.kermit.Logger
import com.hippo.unifile.UniFile
import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import eu.kanade.tachiyomi.ui.reader.ReaderActivity
import eu.kanade.tachiyomi.util.system.toast
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.floor
import kotlin.math.min
import yokai.core.ebook.ContentClassifier
import yokai.core.ebook.ContentKind
import yokai.core.ebook.DrmProtectedException
import yokai.core.ebook.UnreadableFileException
import yokai.ebook.data.EbookDatabase
import yokai.ebook.data.EbookLocator
import yokai.ebook.settings.BookKey
import yokai.i18n.MR
import yokai.util.lang.getString

/** Thrown while loading a Local Source chapter that must be read in the text reader. */
class TextBookException(message: String) : Exception(message)

/**
 * Decides which reader opens a Local Source chapter.
 * - `.mobi` / `.azw3`: always the text reader (known from the file name, no I/O).
 * - `.epub`: the user's choice for the file if there is one (design question 7: switchable, remembered per
 *   chapter), else the automatic classification ([ContentClassifier]); comic-like EPUBs keep using the
 *   existing manga reader exactly as before. Both are kept in ebook.db, so the classification runs
 *   once per file rather than at every app start. A file that cannot be read at all goes to the text
 *   reader, which explains that it is damaged (stage 6, acceptance item 3).
 */
object EbookRouter {

    /** Kind per chapter, for this process (the user's choice or the classification). */
    private val epubKinds = ConcurrentHashMap<BookKey, ContentKind>()

    private fun extensionOf(chapterUrl: String) = chapterUrl.substringAfterLast('/').substringAfterLast('.', "")

    private fun isEpub(chapter: Chapter) = extensionOf(chapter.url).equals("epub", ignoreCase = true)

    private fun key(manga: Manga, chapter: Chapter) = BookKey(manga.source, manga.url, chapter.url)

    /** The user's choice, else the stored classification; null when the file was never classified. */
    private fun knownKind(context: Context, key: BookKey): ContentKind? {
        epubKinds[key]?.let { return it }
        val info = runCatching { EbookDatabase.get(context).info(key) }.getOrNull() ?: return null
        val kind = (info.kindUser ?: info.kindAuto)?.let { runCatching { ContentKind.valueOf(it) }.getOrNull() } ?: return null
        epubKinds[key] = kind
        return kind
    }

    /** An intent for the text reader when [chapter] is known to be a text book, otherwise null. */
    fun intentFor(context: Context, manga: Manga, chapter: Chapter): Intent? {
        if (manga.source != LocalSource.ID) return null
        val isText = LocalEbooks.isTextOnly(extensionOf(chapter.url)) ||
            (isEpub(chapter) && knownKind(context, key(manga, chapter)) == ContentKind.TEXT)
        return if (isText) EbookReaderActivity.newIntent(context, manga, chapter) else null
    }

    /** Called from ChapterLoader (I/O thread) for Local Source EPUB chapters. */
    fun isTextEpub(manga: Manga, chapter: Chapter, file: UniFile, context: Context): Boolean {
        val key = key(manga, chapter)
        knownKind(context, key)?.let { return it == ContentKind.TEXT }
        val kind = try {
            LocalEbooks.open(file, context).use { ContentClassifier.classify(it) }
        } catch (e: DrmProtectedException) {
            // The text reader explains DRM clearly; the image reader would show broken pages.
            ContentKind.TEXT
        } catch (e: UnreadableFileException) {
            // Not a ZIP, or one cut short: the image reader cannot open it either, and on the test emulator it
            // closed without a word (stage 6). The text reader explains that the file is damaged. Not stored,
            // so a replaced file is classified again.
            Logger.w(e) { "EPUB file cannot be read, the text reader explains it" }
            epubKinds[key] = ContentKind.TEXT
            return true
        } catch (e: Throwable) {
            // Damaged or unusual files keep the existing behaviour of the image reader (not stored, so a
            // replaced file is classified again).
            Logger.w(e) { "EPUB classification failed, using the image reader" }
            epubKinds[key] = ContentKind.COMIC
            return false
        }
        epubKinds[key] = kind
        runCatching { EbookDatabase.get(context).updateInfo(key) { it.copy(kindAuto = kind.name) } }
            .onFailure { Logger.w(it) { "Storing the EPUB classification failed" } }
        return kind == ContentKind.TEXT
    }

    /** Remembers the user's choice of reader for this EPUB chapter. */
    fun setKind(context: Context, manga: Manga, chapter: Chapter, kind: ContentKind) {
        val key = key(manga, chapter)
        epubKinds[key] = kind
        EbookDatabase.get(context).updateInfo(key) { it.copy(kindUser = kind.name) }
    }

    fun textBookException(context: Context) = TextBookException(context.getString(MR.strings.ebook_opens_in_text_reader))

    /**
     * Called from ChapterLoader (I/O thread) when the image reader found no pages in a chapter. For a Local
     * Source EPUB (a text book switched to images, or a book the classification took for a comic) the
     * text reader is used instead, from now on, with a notice; otherwise null (the usual "no pages" error).
     * Without this the image reader would close at once and the switch back to text could not be reached.
     */
    fun noImagePages(manga: Manga, chapter: Chapter, context: Context): TextBookException? {
        if (manga.source != LocalSource.ID || !isEpub(chapter)) return null
        runCatching { setKind(context, manga, chapter, ContentKind.TEXT) }
            .onFailure { Logger.w(it) { "Storing the reader choice failed" } }
        val notice = context.getString(MR.strings.ebook_no_image_pages)
        Handler(Looper.getMainLooper()).post { context.applicationContext.toast(notice, Toast.LENGTH_LONG) }
        return textBookException(context)
    }

    /** Replaces [activity] (the image reader) with the text reader, without a second transition. */
    fun handOff(activity: Activity, mangaId: Long?, chapterId: Long?, switchedByUser: Boolean = false): Boolean {
        if (mangaId == null || mangaId < 0 || chapterId == null || chapterId < 0) return false
        val intent = EbookReaderActivity.newIntent(activity, mangaId, chapterId)
            .putExtra(EbookReaderActivity.EXTRA_SWITCHED_FROM_IMAGES, switchedByUser)
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

    // region Image reader menu: "open as text" for Local Source EPUB chapters

    fun addImageReaderItems(context: Context, menu: Menu) {
        menu.add(Menu.NONE, MENU_OPEN_AS_TEXT, Menu.CATEGORY_SECONDARY, context.getString(MR.strings.ebook_open_as_text))
            .setShowAsAction(MenuItem.SHOW_AS_ACTION_NEVER)
    }

    fun prepareImageReaderItems(menu: Menu, manga: Manga?, chapter: Chapter?) {
        menu.findItem(MENU_OPEN_AS_TEXT)?.isVisible =
            manga != null && chapter != null && manga.source == LocalSource.ID && isEpub(chapter)
    }

    /** Handles the image reader's "open as text" item; true when [item] was it. */
    fun onImageReaderItem(activity: Activity, item: MenuItem, manga: Manga?, chapter: Chapter?): Boolean {
        if (item.itemId != MENU_OPEN_AS_TEXT) return false
        if (manga == null || chapter == null) return true
        setKind(activity, manga, chapter, ContentKind.TEXT)
        handOff(activity, manga.id, chapter.id, switchedByUser = true)
        return true
    }

    /**
     * Called from ChapterLoader (I/O thread) once the image reader has the pages of a chapter. The page
     * numbers the text reader writes to a chapter are an estimate of text pages, not image pages: used as
     * they are, the image reader could start past its last page and crash (PagerViewer takes
     * pages[requestedPage]), or start on its last page and mark the book read. For a Local Source EPUB whose
     * page numbers were written by the text reader, the image reader starts at the same fraction of the book
     * instead; a page out of range for another reason starts at the first page. Only the chapter object in
     * memory changes: the image reader writes its own page once it shows one.
     */
    fun fitImageReaderPage(context: Context, manga: Manga, chapter: Chapter, pageCount: Int) {
        if (manga.source != LocalSource.ID || !isEpub(chapter)) return
        val saved = if (chapter.read) null else runCatching { EbookDatabase.get(context).position(key(manga, chapter)) }.getOrNull()
        imageReaderStartPage(chapter.last_page_read, chapter.pages_left, saved, pageCount)?.let { chapter.last_page_read = it }
    }

    /**
     * See [fitImageReaderPage]: the page the image reader starts at, or null to keep [page]. [saved] is the
     * text reader's position of the chapter; its `chapterPage` equals [page] when the text reader wrote the
     * chapter's page numbers last.
     */
    internal fun imageReaderStartPage(page: Int, pagesLeft: Int, saved: EbookLocator?, pageCount: Int): Int? = when {
        pageCount <= 0 -> null
        saved?.chapterPage != null && saved.chapterPage == page -> {
            val total = page + pagesLeft
            val fraction = saved.total ?: if (total > 0) page.toDouble() / total else 0.0
            min(pageCount - 1, floor(fraction.coerceIn(0.0, 1.0) * pageCount).toInt())
        }
        page !in 0 until pageCount -> 0
        else -> null
    }

    /** From the text reader: reopens [chapter] in the image reader and remembers that choice. */
    fun openAsImages(activity: Activity, manga: Manga, chapter: Chapter) {
        setKind(activity, manga, chapter, ContentKind.COMIC)
        activity.startActivity(ReaderActivity.newIntent(activity, manga, chapter).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION))
        activity.finish()
        @Suppress("DEPRECATION")
        activity.overridePendingTransition(0, 0)
    }

    fun canOpenAsImages(chapter: Chapter) = isEpub(chapter)

    private const val MENU_OPEN_AS_TEXT = 0x5E0B // not used by the image reader's own menu

    // endregion
}
