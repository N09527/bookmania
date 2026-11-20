package yokai.ebook

import eu.kanade.tachiyomi.core.preference.Preference
import eu.kanade.tachiyomi.data.database.models.ChapterImpl
import eu.kanade.tachiyomi.data.database.models.Track
import eu.kanade.tachiyomi.data.preference.PreferencesHelper
import eu.kanade.tachiyomi.domain.manga.models.Manga
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
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

class ReadingSessionTest {

    private class MemoryPositions : PositionStore {
        val map = HashMap<BookKey, EbookLocator>()
        override fun position(key: BookKey) = map[key]
        override fun positions(sourceId: Long, mangaUrl: String) =
            map.filterKeys { it.sourceId == sourceId && it.mangaUrl == mangaUrl }.mapKeys { it.key.chapterUrl }
        override fun putPosition(key: BookKey, locator: EbookLocator) {
            map[key] = locator
        }
    }

    private fun <T> pref(value: T): Preference<T> = mockk { every { get() } returns value }

    private val key = BookKey(0L, "works/book", "works/book/book.epub")
    private val positions = MemoryPositions()
    private val updates = mutableListOf<ChapterUpdate>()
    private val histories = mutableListOf<Triple<Long, Long, Long>>()
    private val trackingCalls = mutableListOf<Float>()
    private var clock = 1_000L

    private fun session(
        incognito: Boolean = false,
        autoTrack: Boolean = true,
        tracks: List<Track> = emptyList(),
        chapter: ChapterImpl = ChapterImpl().apply { id = 5; chapter_number = 3f },
        duplicates: Set<String> = emptySet(),
        otherChapters: List<ChapterImpl> = emptyList(),
    ): ReadingSession {
        val preferences = mockk<PreferencesHelper> {
            every { incognitoMode() } returns pref(incognito)
            every { autoUpdateTrack() } returns pref(autoTrack)
        }
        val libraryPreferences = mockk<LibraryPreferences> {
            every { markDuplicateReadChapterAsRead() } returns pref(duplicates)
        }
        val manga = mockk<Manga> { every { id } returns 7L }
        val getChapter = mockk<GetChapter> { coEvery { awaitAll(7L, false) } returns otherChapters + chapter }
        val updateChapter = mockk<UpdateChapter> {
            coEvery { await(any()) } answers { updates += firstArg<ChapterUpdate>(); true }
            coEvery { awaitAll(any()) } answers { updates += firstArg<List<ChapterUpdate>>(); true }
        }
        val upsertHistory = mockk<UpsertHistory> {
            coEvery { await(any<Long>(), any(), any()) } answers {
                histories += Triple(firstArg(), secondArg(), thirdArg()); 1L
            }
        }
        val getTrack = mockk<GetTrack> { coEvery { awaitAllByMangaId(7L) } returns tracks }
        return ReadingSession(
            manga, chapter, key, positions, preferences, libraryPreferences, getChapter, updateChapter, upsertHistory, getTrack,
            updateTracking = { _, number -> trackingCalls += number; emptyList() },
            now = { clock },
        )
    }

    private fun locator(atEnd: Boolean = false, progression: Double = 0.5) =
        EbookLocator(spine = 1, href = "b.xhtml", location = listOf(3, 0), text = "abcdef", progression = progression, atEnd = atEnd, updatedAt = clock)

    @Test
    fun `saves the position and the estimated page`() = runTest {
        val s = session()
        s.init()
        s.progress = ReadingProgress(intArrayOf(1000, 1000)) // 2 documents, 10 pages each in this layout
        s.save(locator(progression = 0.5), spine = 1, page = 5, pages = 10)
        assertEquals(locator(progression = 0.5).copy(chapterPage = 15), positions.map[key])
        // 10 estimated pages before the open document, which is on its page index 5 of 10: 15 of 20
        assertEquals(ChapterUpdate(id = 5, read = false, lastPageRead = 15, pagesLeft = 5), updates.single())
        assertTrue(trackingCalls.isEmpty())
    }

    @Test
    fun `without character counts the position is saved, the page numbers are left alone`() = runTest {
        val s = session()
        s.init()
        s.save(locator(), spine = 1, page = 0, pages = 10)
        assertEquals(ChapterUpdate(id = 5, read = false, lastPageRead = null, pagesLeft = null), updates.single())
    }

    @Test
    fun `the last page marks the chapter read and updates trackers once`() = runTest {
        val s = session()
        s.init()
        s.progress = ReadingProgress(intArrayOf(1000, 1000))
        s.save(locator(atEnd = true, progression = 0.95), spine = 1, page = 9, pages = 10)
        s.save(locator(atEnd = true, progression = 0.95), spine = 1, page = 9, pages = 10)
        assertEquals(listOf(3f), trackingCalls)
        assertEquals(ChapterUpdate(id = 5, read = true, lastPageRead = 19, pagesLeft = 1), updates.last())
        assertTrue(s.chapter.read)
    }

    @Test
    fun `no tracker update when the option is off`() = runTest {
        val s = session(autoTrack = false)
        s.init()
        s.save(locator(atEnd = true), spine = 1, page = 0, pages = 10)
        assertTrue(trackingCalls.isEmpty())
        assertEquals(true, updates.single().read)
    }

    @Test
    fun `duplicate chapters are marked read when the library option says so`() = runTest {
        val twin = ChapterImpl().apply { id = 6; chapter_number = 3f; read = false }
        val other = ChapterImpl().apply { id = 8; chapter_number = 4f; read = false }
        val s = session(duplicates = setOf(LibraryPreferences.MARK_DUPLICATE_READ_CHAPTER_READ_EXISTING), otherChapters = listOf(twin, other))
        s.init()
        s.save(locator(atEnd = true), spine = 1, page = 0, pages = 10)
        assertTrue(updates.contains(ChapterUpdate(id = 6, read = true)))
        assertTrue(updates.none { it.id == 8L })
    }

    @Test
    fun `incognito saves nothing unless the manga has trackers`() = runTest {
        val s = session(incognito = true)
        s.init()
        s.startTimer()
        s.save(locator(atEnd = true), spine = 1, page = 0, pages = 10)
        clock += 60_000
        s.flushTimer()
        assertTrue(positions.map.isEmpty())
        assertTrue(updates.isEmpty())
        assertTrue(histories.isEmpty())

        val tracked = session(incognito = true, tracks = listOf(mockk()))
        tracked.init()
        tracked.save(locator(), spine = 1, page = 0, pages = 10)
        assertEquals(1, positions.map.size)
        assertEquals(1, updates.size)
    }

    @Test
    fun `reading time goes to the history`() = runTest {
        val s = session()
        s.startTimer()
        clock += 90_000
        s.flushTimer()
        assertEquals(Triple(5L, clock, 90_000L), histories.single())
        s.flushTimer() // nothing more until the timer starts again
        assertEquals(1, histories.size)
    }

    @Test
    fun `the timer is stopped before the time is saved, so a quick return keeps timing`() = runTest {
        val s = session()
        s.startTimer()
        clock += 30_000
        val span = s.stopTimer()!! // reader paused
        clock += 1_000
        s.startTimer() // back to the reader before the time was written
        s.saveReadingTime(span.first, span.second)
        clock += 20_000
        s.flushTimer()
        assertEquals(listOf(30_000L, 20_000L), histories.map { it.third })
    }

    @Test
    fun `a book left on its last page opens at the start again`() = runTest {
        val s = session()
        positions.map[key] = locator(atEnd = true)
        assertNull(s.positionToRestore())
        positions.map[key] = locator(atEnd = false)
        assertEquals(locator(atEnd = false), s.positionToRestore())
    }

    @Test
    fun `like the manga reader, a read chapter and one marked unread in the chapter list start from the beginning`() = runTest {
        positions.map[key] = locator().copy(chapterPage = 12)
        val unread = ChapterImpl().apply { id = 5; last_page_read = 12; pages_left = 8 }
        assertEquals(locator().copy(chapterPage = 12), session(chapter = unread).positionToRestore())
        val read = ChapterImpl().apply { id = 5; read = true; last_page_read = 12; pages_left = 8 }
        assertNull(session(chapter = read).positionToRestore())
        // "mark as unread" sets last_page_read and pages_left to 0
        val cleared = ChapterImpl().apply { id = 5; last_page_read = 0; pages_left = 0 }
        assertNull(session(chapter = cleared).positionToRestore())
        // a position saved before the page numbers were known (chapterPage null) is still restored
        positions.map[key] = locator()
        assertEquals(locator(), session(chapter = cleared).positionToRestore())
        // and so is one on the book's first page (page 0 is what the chapter list holds anyway)
        positions.map[key] = locator().copy(chapterPage = 0)
        assertEquals(locator().copy(chapterPage = 0), session(chapter = cleared).positionToRestore())
    }

    @Test
    fun `a restored backup keeps the newer position`() {
        positions.map[key] = locator().copy(updatedAt = 200)
        assertEquals(false, positions.putPositionIfNewer(key, locator().copy(updatedAt = 100, progression = 0.1)))
        assertEquals(200L, positions.map[key]!!.updatedAt)
        assertEquals(true, positions.putPositionIfNewer(key, locator().copy(updatedAt = 300, progression = 0.9)))
        assertEquals(0.9, positions.map[key]!!.progression, 1e-9)
    }
}
