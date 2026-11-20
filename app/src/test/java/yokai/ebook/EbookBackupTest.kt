package yokai.ebook

import eu.kanade.tachiyomi.data.backup.models.BackupChapter
import eu.kanade.tachiyomi.data.backup.models.BackupManga
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import io.mockk.every
import io.mockk.mockk
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.protobuf.ProtoBuf
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import yokai.ebook.data.EbookBackup
import yokai.ebook.data.EbookLocator
import yokai.ebook.data.PositionStore
import yokai.ebook.settings.BookKey

@OptIn(ExperimentalSerializationApi::class)
class EbookBackupTest {

    private class MemoryPositions : PositionStore {
        val map = HashMap<BookKey, EbookLocator>()
        override fun position(key: BookKey) = map[key]
        override fun positions(sourceId: Long, mangaUrl: String) =
            map.filterKeys { it.sourceId == sourceId && it.mangaUrl == mangaUrl }.mapKeys { it.key.chapterUrl }
        override fun putPosition(key: BookKey, locator: EbookLocator) {
            map[key] = locator
        }
    }

    private fun manga(sourceId: Long) = mockk<Manga> {
        every { source } returns sourceId
        every { url } returns "直排測試書 EPUB"
    }

    private val locator = EbookLocator(
        spine = 1, href = "OEBPS/text/ch02.xhtml", location = listOf(55, 0), text = "【第１３段】長一點的段落",
        progression = 0.29, total = 0.43, updatedAt = 1_700_000_000_000,
    )

    @Test
    fun `positions travel with the chapters of a local work`() {
        val device = MemoryPositions()
        device.map[BookKey(LocalSource.ID, "直排測試書 EPUB", "直排測試書 EPUB/zh-vertical.epub")] = locator
        val chapters = listOf(
            BackupChapter(url = "直排測試書 EPUB/zh-vertical.epub", name = "直排測試書"),
            BackupChapter(url = "直排測試書 EPUB/other.epub", name = "other"),
        )
        EbookBackup.attachPositions(manga(LocalSource.ID), chapters, device)
        assertEquals(locator.toJson(), chapters[0].bookmaniaEbookPosition)
        assertNull(chapters[1].bookmaniaEbookPosition)

        // The field survives the backup's protobuf encoding.
        val bytes = ProtoBuf.encodeToByteArray(BackupManga.serializer(), BackupManga(source = LocalSource.ID, url = "直排測試書 EPUB", chapters = chapters))
        val decoded = ProtoBuf.decodeFromByteArray(BackupManga.serializer(), bytes)
        assertEquals(locator.toJson(), decoded.chapters[0].bookmaniaEbookPosition)

        val other = MemoryPositions()
        assertEquals(1, EbookBackup.restorePositions(manga(LocalSource.ID), decoded.chapters, other))
        assertEquals(locator, other.map[BookKey(LocalSource.ID, "直排測試書 EPUB", "直排測試書 EPUB/zh-vertical.epub")])
    }

    @Test
    fun `restore keeps a newer position on the device`() {
        val key = BookKey(LocalSource.ID, "直排測試書 EPUB", "直排測試書 EPUB/zh-vertical.epub")
        val device = MemoryPositions()
        val newer = locator.copy(updatedAt = locator.updatedAt + 1, progression = 0.9)
        device.map[key] = newer
        val chapters = listOf(BackupChapter(url = key.chapterUrl, name = "x", bookmaniaEbookPosition = locator.toJson()))
        assertEquals(0, EbookBackup.restorePositions(manga(LocalSource.ID), chapters, device))
        assertEquals(newer, device.map[key])
    }

    @Test
    fun `other sources are left alone and a backup without the field still decodes`() {
        val device = MemoryPositions()
        device.map[BookKey(5L, "直排測試書 EPUB", "a")] = locator
        val chapters = listOf(BackupChapter(url = "a", name = "a"))
        EbookBackup.attachPositions(manga(5L), chapters, device)
        assertNull(chapters[0].bookmaniaEbookPosition)

        // A chapter written without the Bookmania field (e.g. by upstream Yokai) has no position.
        val plain = ProtoBuf.encodeToByteArray(BackupChapter.serializer(), BackupChapter(url = "a", name = "a", lastPageRead = 3))
        val decoded = ProtoBuf.decodeFromByteArray(BackupChapter.serializer(), plain)
        assertNull(decoded.bookmaniaEbookPosition)
        assertEquals(3, decoded.lastPageRead)
        assertEquals(0, EbookBackup.restorePositions(manga(LocalSource.ID), listOf(decoded), device))
    }
}
