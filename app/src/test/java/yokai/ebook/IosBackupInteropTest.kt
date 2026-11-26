package yokai.ebook

import eu.kanade.tachiyomi.data.backup.models.Backup
import eu.kanade.tachiyomi.data.backup.models.BackupCategory
import eu.kanade.tachiyomi.data.backup.models.BackupChapter
import eu.kanade.tachiyomi.data.backup.models.BackupHistory
import eu.kanade.tachiyomi.data.backup.models.BackupManga
import eu.kanade.tachiyomi.data.backup.models.BackupPreference
import eu.kanade.tachiyomi.data.backup.models.BackupSource
import eu.kanade.tachiyomi.data.backup.models.BooleanPreferenceValue
import eu.kanade.tachiyomi.data.backup.models.IntPreferenceValue
import eu.kanade.tachiyomi.data.backup.models.StringPreferenceValue
import eu.kanade.tachiyomi.source.LocalSource
import java.io.File
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.protobuf.ProtoBuf
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import yokai.ebook.data.EbookLocator

/**
 * The iOS version (ios/) reads and writes this app's backup files. The two fixtures were written by each side:
 * `ios-backup.tachibk` by the iOS version's BackupMapper (Swift), `android-backup.tachibk` by this app's serializers
 * (set BOOKMANIA_WRITE_BACKUP_FIXTURE to a path to write it again). The iOS core tests read the Android one.
 */
@OptIn(ExperimentalSerializationApi::class)
class IosBackupInteropTest {

    private val dir = File("../core/ebook/src/test/resources/fixtures/backup")

    /** A backup file as BackupUtil.decodeBackup reads it: gzip, then the app's ProtoBuf parser. */
    private fun bytes(name: String) = GZIPInputStream(File(dir, name).inputStream()).use { it.readBytes() }

    private fun read(name: String) = ProtoBuf.decodeFromByteArray(Backup.serializer(), bytes(name))

    private val position = EbookLocator(
        spine = 1, href = "OEBPS/text/ch02.xhtml", location = listOf(55, 0), text = "【第１３段】長一點的段落",
        progression = 0.29, total = 0.43, chapterPage = 12, updatedAt = 1_700_000_000_000,
    )

    @Test
    fun `a backup written by the iOS version`() {
        val backup = read("ios-backup.tachibk")
        assertEquals(listOf("直排測試書 EPUB", "漫畫測試"), backup.backupManga.map { it.url })

        val text = backup.backupManga[0]
        assertEquals(LocalSource.ID, text.source)
        assertEquals("直排測試書", text.title)
        assertEquals("Bookmania 測試", text.author)
        assertEquals(listOf("小說"), text.genre)
        assertEquals(2, text.status)
        assertTrue(text.favorite)
        assertEquals(1_700_000_000_000, text.dateAdded)
        assertEquals(listOf(0), text.categories)
        assertEquals(0x1001, text.chapterFlags)
        assertNull(text.viewer_flags)
        // The local source's order: the highest chapter first.
        assertEquals(listOf("直排測試書 EPUB/zh-vertical.epub", "直排測試書 EPUB/zh-horizontal.epub"), text.chapters.map { it.url })
        val vertical = text.chapters[0]
        assertEquals("zh-vertical", vertical.name)
        assertEquals(false, vertical.read)
        assertEquals(true, vertical.bookmark)
        assertEquals(12, vertical.lastPageRead)
        assertEquals(30, vertical.pagesLeft)
        assertEquals(1_700_000_000_500, vertical.dateFetch)
        assertEquals(1_600_000_000_000, vertical.dateUpload)
        assertEquals(0, vertical.sourceOrder)
        assertEquals(position, EbookLocator.fromJson(vertical.bookmaniaEbookPosition))
        assertEquals(true, text.chapters[1].read)
        assertEquals(listOf(BackupHistory("直排測試書 EPUB/zh-vertical.epub", 1_700_000_100_000, 120_000)), text.history)

        val comic = backup.backupManga[1]
        assertEquals(false, comic.favorite)
        assertEquals(1, comic.viewer_flags)
        assertEquals(true, comic.chapters.single().read)
        assertEquals(5, comic.chapters.single().lastPageRead)

        assertEquals(listOf("小說" to 0, "漫畫" to 1), backup.backupCategories.map { it.name to it.order })
        assertEquals(listOf(BackupSource("Local source", 0)), backup.backupSources)
        val prefs = backup.backupPreferences.associate { it.key to it.value }
        assertEquals(StringPreferenceValue("24"), prefs["pref_ebook_fontSize"])
        assertEquals(BooleanPreferenceValue(false), prefs["pref_ebook_gutter_shadow"])
        assertEquals(IntPreferenceValue(4), prefs["pref_reader_theme_key"])
        assertEquals(StringPreferenceValue("slide"), prefs["pref_ebook_page_turn"])
    }

    /** What `android-backup.tachibk` holds. */
    private fun androidBackup() = Backup(
        backupManga = listOf(
            BackupManga(
                source = LocalSource.ID,
                url = "直排測試書 EPUB",
                title = "直排測試書",
                author = "Bookmania 測試",
                genre = listOf("小說"),
                status = 2,
                dateAdded = 1_700_000_000_000,
                chapters = listOf(
                    BackupChapter(
                        url = "直排測試書 EPUB/zh-vertical.epub", name = "zh-vertical", bookmark = true, lastPageRead = 12,
                        dateFetch = 1_700_000_000_500, dateUpload = 1_600_000_000_000, chapterNumber = 1f, pagesLeft = 30,
                        bookmaniaEbookPosition = position.toJson(),
                    ),
                    BackupChapter(url = "直排測試書 EPUB/zh-horizontal.epub", name = "zh-horizontal", read = true, sourceOrder = 1),
                ),
                categories = listOf(1),
                chapterFlags = 0x1001,
                viewer_flags = 2,
                history = listOf(BackupHistory("直排測試書 EPUB/zh-vertical.epub", 1_700_000_100_000, 120_000)),
            ),
            BackupManga(
                source = LocalSource.ID, url = "漫畫測試", favorite = false, viewer_flags = 1,
                chapters = listOf(BackupChapter(url = "漫畫測試/comic.cbz", name = "comic", read = true, lastPageRead = 5, pagesLeft = 1)),
            ),
            BackupManga(source = 2499283573021220255, url = "/manga/1", title = "Online"),
        ),
        backupCategories = listOf(BackupCategory("漫畫", 0), BackupCategory("小說", 1)),
        backupSources = listOf(BackupSource("Local source", LocalSource.ID), BackupSource("Online", 2499283573021220255)),
        backupPreferences = listOf(
            BackupPreference("pref_ebook_fontSize", StringPreferenceValue("24")),
            BackupPreference("pref_ebook_gutter_shadow", BooleanPreferenceValue(false)),
            BackupPreference("pref_reader_theme_key", IntPreferenceValue(4)),
        ),
    )

    @Test
    fun `the Android fixture is what this app writes`() {
        val encoded = ProtoBuf.encodeToByteArray(Backup.serializer(), androidBackup())
        System.getenv("BOOKMANIA_WRITE_BACKUP_FIXTURE")?.let { path ->
            GZIPOutputStream(File(path).outputStream()).use { it.write(encoded) }
        }
        assertArrayEquals(encoded, bytes("android-backup.tachibk"))
    }
}
