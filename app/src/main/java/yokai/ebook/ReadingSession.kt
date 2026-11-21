package yokai.ebook

import eu.kanade.tachiyomi.data.database.models.Chapter
import eu.kanade.tachiyomi.data.preference.PreferencesHelper
import eu.kanade.tachiyomi.data.track.TrackService
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.util.chapter.updateTrackChapterRead
import yokai.domain.chapter.interactor.GetChapter
import yokai.domain.chapter.interactor.UpdateChapter
import yokai.domain.chapter.models.ChapterUpdate
import yokai.domain.history.interactor.UpsertHistory
import yokai.domain.library.LibraryPreferences
import yokai.domain.track.interactor.GetTrack
import yokai.ebook.data.EbookLocator
import yokai.ebook.data.PositionStore
import yokai.ebook.data.ReadingProgress
import yokai.ebook.settings.BookKey

/**
 * Saves the reading progress of one open text book the way the manga reader does for image chapters
 * (ReaderViewModel.saveChapterProgress, onChapterReadComplete, saveChapterHistory):
 *
 * - the exact position goes to ebook.db; the chapter's `last_page_read` / `pages_left` get the
 *   estimated page numbers ([ReadingProgress]) so the chapter list and Recents show "page X of Y";
 * - reaching the last page marks the chapter read, updates trackers (when "update tracking after
 *   reading" is on) and marks duplicate chapters read (when that library option is on);
 * - the reading time goes to the history when the reader is paused;
 * - in incognito mode nothing is saved, unless the manga has trackers (as in the manga reader).
 *
 * Everything here runs on a background thread.
 */
class ReadingSession(
    private val manga: Manga,
    val chapter: Chapter,
    private val key: BookKey,
    private val positions: PositionStore,
    private val preferences: PreferencesHelper,
    private val libraryPreferences: LibraryPreferences,
    private val getChapter: GetChapter,
    private val updateChapter: UpdateChapter,
    private val upsertHistory: UpsertHistory,
    private val getTrack: GetTrack,
    private val updateTracking: suspend (mangaId: Long?, chapterNumber: Float) -> List<Pair<TrackService, String?>> =
        { mangaId, number -> updateTrackChapterRead(preferences, mangaId, number, true) },
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** Whole-book progress, once the documents' character counts are known. */
    @Volatile var progress: ReadingProgress? = null

    private var hasTrackers = false
    private var readStart: Long? = null

    suspend fun init() {
        hasTrackers = getTrack.awaitAllByMangaId(manga.id).isNotEmpty()
    }

    private val shouldTrack get() = !preferences.incognitoMode().get() || hasTrackers

    /**
     * The position to restore, or null to start at the beginning. As in the manga reader, which opens a
     * read chapter at its first page and an unread one at `last_page_read`: a book left on its last page
     * or marked read starts from the beginning, and so does one whose progress was cleared in the chapter
     * list ("mark as unread" sets `last_page_read` to 0).
     *
     * When the user switched the book from the image reader ([switchedFromImages]), the page numbers and
     * the read state are the image reader's (it marks a chapter read on its last picture, and its first
     * picture is page 0), so the text position is taken back unless it was on the last page.
     */
    fun positionToRestore(switchedFromImages: Boolean = false): EbookLocator? {
        val saved = positions.position(key) ?: return null
        if (switchedFromImages) return saved.takeUnless { it.atEnd }
        val cleared = (saved.chapterPage ?: 0) > 0 && chapter.last_page_read == 0
        return saved.takeUnless { it.atEnd || chapter.read || cleared }
    }

    /**
     * Saves [locator]: the first page shown, [page] of the [pages] pages of document [spine] in the current
     * layout. Returns tracker errors to show, if the chapter was just finished.
     */
    suspend fun save(locator: EbookLocator, spine: Int, page: Int, pages: Int): List<Pair<TrackService, String?>> {
        if (!shouldTrack) return emptyList()
        val estimate = progress?.pages(spine, page, pages, locator.atEnd)
        positions.putPosition(key, locator.copy(chapterPage = estimate?.first))
        var errors = emptyList<Pair<TrackService, String?>>()
        if (locator.atEnd && !chapter.read) {
            chapter.read = true
            errors = onReadComplete()
        }
        if (estimate != null) {
            chapter.last_page_read = estimate.first
            chapter.pages_left = estimate.second - estimate.first
        }
        updateChapter.await(
            ChapterUpdate(
                id = chapter.id!!,
                read = chapter.read,
                lastPageRead = estimate?.first?.toLong(),
                pagesLeft = estimate?.let { (it.second - it.first).toLong() },
            ),
        )
        return errors
    }

    private suspend fun onReadComplete(): List<Pair<TrackService, String?>> {
        val errors = if (preferences.autoUpdateTrack().get()) updateTracking(manga.id, chapter.chapter_number) else emptyList()
        val markDuplicates = libraryPreferences.markDuplicateReadChapterAsRead().get()
            .contains(LibraryPreferences.MARK_DUPLICATE_READ_CHAPTER_READ_EXISTING)
        if (markDuplicates && chapter.isRecognizedNumber) {
            val duplicates = getChapter.awaitAll(manga.id!!, false)
                .filter { !it.read && it.id != chapter.id && it.isRecognizedNumber && it.chapter_number == chapter.chapter_number }
                .map { ChapterUpdate(id = it.id!!, read = true) }
            if (duplicates.isNotEmpty()) updateChapter.awaitAll(duplicates)
        }
        return errors
    }

    /** Starts timing a reading session (the reader is shown). Called on the main thread. */
    fun startTimer() {
        readStart = now()
    }

    /**
     * Stops the timer: (start, end) of the time read since [startTimer], or null when it was not running.
     * Called on the main thread when the reader is paused, so that a quick return to the reader (which
     * starts the timer again) cannot be mixed up with the time being saved.
     */
    fun stopTimer(): Pair<Long, Long>? {
        val start = readStart ?: return null
        readStart = null
        return start to now()
    }

    /** Adds a reading time from [stopTimer] to the chapter's history (not in incognito mode). */
    suspend fun saveReadingTime(start: Long, end: Long) {
        if (preferences.incognitoMode().get()) return
        upsertHistory.await(chapter.id!!, end, end - start)
    }

    suspend fun flushTimer() {
        val (start, end) = stopTimer() ?: return
        saveReadingTime(start, end)
    }
}
