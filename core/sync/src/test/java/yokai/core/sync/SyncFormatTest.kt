package yokai.core.sync

import java.io.File
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** The example files of sync-format.md (fixtures/sync/formats), which the iOS core tests read too. */
class SyncFormatTest {

    private fun fixture(name: String) = File("src/test/resources/fixtures/sync/formats/$name").readText()

    private val a = "6f1c2b9e-3d4a-4e5f-8a7b-1c2d3e4f5a6b"

    @Test
    fun `library file`() {
        val f = SyncJson.decodeFromString<LibraryFile>(fixture("library.json"))
        assertEquals(1, f.format)
        assertEquals(a, f.device)
        val work = f.works.getValue("0:直排測試書 EPUB")
        assertEquals(WorkEntry(true, 1_700_000_000_000, listOf("小說"), 4097, null, 1_764_300_000_000, a), work)
        // Missing fields take their defaults.
        assertEquals(WorkEntry(false, 0, emptyList(), 0, null, 1_764_200_000_000, "0a9b8c7d-6e5f-4a3b-2c1d-0e9f8a7b6c5d"), f.works.getValue("2499283573021220255:/manga/1"))
        assertEquals(CategoryEntry(0, 0, false, 1_764_300_000_000, a), f.categories.getValue("小說"))
        assertTrue(f.categories.getValue("舊分類").deleted)
        assertEquals(JsonPrimitive("24"), f.settings.getValue("pref_ebook_fontSize").value)
        assertEquals(JsonPrimitive(4), f.settings.getValue("pref_reader_theme_key").value)
        assertEquals(JsonPrimitive(false), f.settings.getValue("pref_ebook_gutter_shadow").value)
        assertNull(f.settings.getValue("pref_ebook_override_0123").value)
        assertEquals("bool", f.settings.getValue("pref_ebook_gutter_shadow").type)
        assertEquals(mapOf("0:直排測試書 EPUB" to 1_764_300_000_000), f.progress)
        // What is written reads back the same.
        assertEquals(f, SyncJson.decodeFromString<LibraryFile>(SyncJson.encodeToString(f)))
    }

    @Test
    fun `progress file`() {
        val f = SyncJson.decodeFromString<ProgressFile>(fixture("progress.json"))
        assertEquals("0:直排測試書 EPUB", f.work)
        val c = f.chapters.getValue("直排測試書 EPUB/zh-vertical.epub")
        assertEquals(ProgressPart(false, 12, 30, 1_764_300_000_000, a), c.progress)
        assertEquals(BookmarkPart(true, 1_764_200_000_000, a), c.bookmark)
        assertEquals(1_700_000_000_000, SyncMerge.locatorTime(c.position!!.locator))
        assertTrue(c.position!!.locator!!.contains("【第１３段】"))
        assertEquals(HistoryPart(1_764_300_000_000, 120_000), c.history)
        val read = f.chapters.getValue("直排測試書 EPUB/zh-horizontal.epub")
        assertEquals(ProgressPart(true, 0, 0, 1_764_100_000_000, "0a9b8c7d-6e5f-4a3b-2c1d-0e9f8a7b6c5d"), read.progress)
        // A position part without a locator: the position was cleared.
        assertNull(read.position!!.locator)
        assertNull(read.bookmark)
        assertEquals(f, SyncJson.decodeFromString<ProgressFile>(SyncJson.encodeToString(f)))
    }

    @Test
    fun `files and device files`() {
        val f = SyncJson.decodeFromString<FilesFile>(fixture("files.json"))
        assertEquals(
            listOf(
                FileItem("直排測試書 EPUB", "zh-vertical.epub", 48213, 1_764_300_000_000),
                FileItem("漫畫測試", "第01話/001.jpg", 120934, 1_764_300_000_000),
            ),
            f.files,
        )
        assertTrue(f.files.all(SyncNames::valid))
        val d = SyncJson.decodeFromString<DeviceFile>(fixture("device.json"))
        assertEquals(DeviceFile(1, a, "Pixel 9", "android", "1.3.0", 1_764_300_000_000), d)
    }

    @Test
    fun `a file of a newer format is recognised`() {
        assertEquals(2, SyncJson.decodeFromString<LibraryFile>(fixture("library-newer.json")).format)
    }

    @Test
    fun `identifiers`() {
        assertEquals("0:直排測試書 EPUB", SyncIds.localWorkKey("直排測試書 EPUB"))
        assertEquals("直排測試書 EPUB", SyncIds.localFolder("0:直排測試書 EPUB"))
        assertNull(SyncIds.localFolder("123:/m/1"))
        // SHA-1 of the UTF-8 bytes; the iOS tests check the same names.
        assertEquals("da39a3ee5e6b4b0d3255bfef95601890afd80709.json", SyncIds.progressFileName(""))
        assertEquals(SyncIds.progressFileName("0:直排測試書 EPUB"), SyncIds.progressFileName("0:直排測試書 EPUB"))
        assertEquals(36, SyncIds.newDeviceId().length)
    }

    @Test
    fun `names from the server are checked before anything is written`() {
        for (bad in listOf("", ".", "..", ".hidden", "a/b", "a\\b", "nul\u0000", "tab\t", "x".repeat(256))) {
            assertFalse(SyncNames.validSegment(bad), bad)
        }
        assertTrue(SyncNames.validSegment("第01話"))
        assertTrue(SyncNames.validPath("第01話/001.jpg"))
        assertFalse(SyncNames.validPath("a/b/c.jpg"))
        assertFalse(SyncNames.validPath("../secret"))
        assertFalse(SyncNames.valid(FileItem("..", "x.epub", 1)))
        assertFalse(SyncNames.valid(FileItem("作品", "/x.epub", 1)))
    }
}
