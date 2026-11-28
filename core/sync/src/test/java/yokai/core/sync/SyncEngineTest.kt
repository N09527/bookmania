package yokai.core.sync

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.JsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** Two devices (an Android phone and an iPad, say) syncing through one server. */
class SyncEngineTest {

    private val server = InMemoryWebDav()
    private var now = 1_000_000L
    private val phone = FakeDevice("a0000000-0000-4000-8000-000000000001")
    private val pad = FakeDevice("b0000000-0000-4000-8000-000000000002")

    private fun engine(d: FakeDevice, platform: String) = SyncEngine(
        WebDavClient(server.base, "reader", "secret", server),
        DeviceInfo(d.id, "test $platform", platform, "1.3.0"),
        d,
    ) { now }

    private val phoneSync = engine(phone, "android")
    private val padSync = engine(pad, "ios")

    private val book = SyncIds.localWorkKey("直排測試書")
    private val ch1 = "直排測試書/第1冊.epub"
    private val ch2 = "直排測試書/第2冊.epub"

    private fun tick(ms: Long = 1000) {
        now += ms
    }

    @Test
    fun `the library and settings go both ways`() {
        phone.works[book] = WorkValue(favorite = true, added = now, categories = listOf("小說"))
        phone.categories["小說"] = CategoryValue(0, 0)
        phone.settings["pref_ebook_fontSize"] = SettingValue("string", JsonPrimitive("24"))
        phoneSync.syncLibrary()
        assertTrue(server.files.keys.any { it.endsWith("/devices/${phone.id}/library.json") })
        assertTrue(server.files.keys.any { it.endsWith("/devices/${phone.id}/device.json") })

        tick()
        pad.settings["pref_ebook_fontSize"] = SettingValue("string", JsonPrimitive("18")) // the iPad's own, older choice
        padSync.syncLibrary()
        assertEquals(WorkValue(true, phone.works.getValue(book).added, listOf("小說")), pad.works[book])
        assertEquals(CategoryValue(0, 0), pad.categories["小說"])
        // First sync of the iPad: the settings on the server win.
        assertEquals(JsonPrimitive("24"), pad.settings.getValue("pref_ebook_fontSize").value)

        // Removed from the library on the iPad, later.
        tick()
        pad.works[book] = pad.works.getValue(book).copy(favorite = false, categories = emptyList())
        pad.categories.remove("小說")
        padSync.syncLibrary()
        tick()
        phoneSync.syncLibrary()
        assertFalse(phone.works.getValue(book).favorite)
        assertNull(phone.categories["小說"])
    }

    @Test
    fun `progress follows the reader across devices`() {
        for (d in listOf(phone, pad)) {
            d.works[book] = WorkValue(favorite = true, added = 1)
            d.setChapter(book, ch1, ChapterValue())
            d.setChapter(book, ch2, ChapterValue())
        }
        phoneSync.syncLibrary()
        padSync.syncLibrary()

        // Reading on the phone; leaving the reader sends the progress.
        tick()
        phoneSync.syncWork(book, push = false)
        tick(60_000)
        phone.setChapter(book, ch1, ChapterValue(read = true, page = 99, lastRead = now, duration = 60_000))
        phone.setChapter(book, ch2, ChapterValue(page = 7, left = 93, locator = """{"spine":2,"href":"c.xhtml","updatedAt":$now}""", lastRead = now, duration = 30_000))
        assertTrue(phoneSync.syncWork(book, push = true).uploaded)

        // Opening the book on the iPad takes it.
        tick(60_000)
        padSync.syncWork(book, push = false)
        assertEquals(ChapterValue(read = true, page = 99, lastRead = phone.chapter(book, ch1)!!.lastRead, duration = 60_000), pad.chapter(book, ch1))
        assertEquals(phone.chapter(book, ch2), pad.chapter(book, ch2))

        // Reading on; back on the phone.
        tick(60_000)
        pad.setChapter(book, ch2, pad.chapter(book, ch2)!!.copy(page = 20, left = 80, lastRead = now, duration = 90_000))
        padSync.syncWork(book, push = true)
        tick(60_000)
        phoneSync.syncWork(book, push = false)
        assertEquals(20, phone.chapter(book, ch2)!!.page)
        assertEquals(90_000, phone.chapter(book, ch2)!!.duration)

        // Leaving the reader sends the merged progress once; with nothing new, nothing is sent again.
        phoneSync.syncWork(book, push = true)
        val puts = server.requests.count { it.startsWith("PUT") }
        phoneSync.syncWork(book, push = true)
        assertEquals(puts, server.requests.count { it.startsWith("PUT") })
    }

    @Test
    fun `progress changed elsewhere is pulled by the library sync`() {
        for (d in listOf(phone, pad)) {
            d.works[book] = WorkValue(favorite = true, added = 1)
            d.setChapter(book, ch1, ChapterValue())
        }
        phoneSync.syncLibrary()
        padSync.syncLibrary()
        tick()
        phone.setChapter(book, ch1, ChapterValue(read = true, lastRead = now))
        phoneSync.syncWork(book, push = true)
        tick()
        val result = padSync.syncLibrary()
        assertEquals(listOf(book), result.works.map { it.work })
        assertTrue(pad.chapter(book, ch1)!!.read)
        // Already merged: not pulled again.
        tick()
        assertTrue(padSync.syncLibrary().works.isEmpty())
    }

    @Test
    fun `progress that could not be sent is sent later`() {
        phone.works[book] = WorkValue(favorite = true, added = 1)
        phone.setChapter(book, ch1, ChapterValue())
        phoneSync.syncLibrary()
        tick()
        phone.setChapter(book, ch1, ChapterValue(page = 5, lastRead = now))
        server.offline = true
        assertEquals(SyncException.Kind.Network, assertThrows(SyncException::class.java) { phoneSync.syncWork(book, push = true) }.kind)
        assertEquals(setOf(book), phone.baseline.pending)
        server.offline = false
        tick()
        phoneSync.syncLibrary()
        assertTrue(phone.baseline.pending.isEmpty())
        val name = SyncIds.progressFileName(book)
        val file = SyncJson.decodeFromString<ProgressFile>(server.text("Bookmania/sync-v1/devices/${phone.id}/progress/$name")!!)
        assertEquals(5, file.chapters.getValue(ch1).progress!!.page)
    }

    @Test
    fun `book files are uploaded and downloaded, never overwritten`() {
        val folder = "直排測試書"
        phone.works[book] = WorkValue(favorite = true, added = 1)
        phone.files["$folder/第1冊.epub"] = ByteArray(1000) { 1 }
        phone.files["$folder/cover.jpg"] = ByteArray(10) { 2 }
        phone.files["其他/不在書櫃.epub"] = ByteArray(5)
        phoneSync.syncLibrary()
        val up = phoneSync.syncFiles(phone, listOf(folder))
        assertEquals(setOf("第1冊.epub", "cover.jpg"), up.uploaded.map { it.path }.toSet())
        assertEquals(1000, server.files.getValue("Bookmania/sync-v1/files/$folder/第1冊.epub").size)
        assertFalse(server.files.keys.any { "不在書櫃" in it })

        // The iPad gets the work from the library sync, then its files.
        padSync.syncLibrary()
        assertTrue(pad.works.getValue(book).favorite)
        pad.files["$folder/cover.jpg"] = ByteArray(12) // a different cover of its own
        val down = padSync.syncFiles(pad, listOf(folder))
        assertEquals(listOf("第1冊.epub"), down.downloaded.map { it.path })
        assertEquals(listOf("cover.jpg"), down.conflicts.map { it.path })
        assertEquals(12, pad.files.getValue("$folder/cover.jpg").size)
        assertTrue(pad.files.getValue("$folder/第1冊.epub").all { it == 1.toByte() })

        // A second run does nothing.
        val again = phoneSync.syncFiles(phone, listOf(folder))
        assertTrue(again.uploaded.isEmpty() && again.downloaded.isEmpty())
    }

    @Test
    fun `names that could escape the folder are not downloaded`() {
        // Another device's list, written by hand as a broken or hostile client could.
        server.collections += listOf("Bookmania", "Bookmania/sync-v1", "Bookmania/sync-v1/devices", "Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003")
        server.files["Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003/files.json"] =
            """{"format":1,"files":[{"work":"作品","path":"../../secret","size":1},{"work":"..","path":"x.epub","size":1},{"work":"作品","path":"ok.epub","size":3}]}""".toByteArray()
        server.collections += listOf("Bookmania/sync-v1/files", "Bookmania/sync-v1/files/作品")
        server.files["Bookmania/sync-v1/files/作品/ok.epub"] = byteArrayOf(1, 2, 3)
        pad.works[SyncIds.localWorkKey("作品")] = WorkValue(favorite = true, added = 1)
        val result = padSync.syncFiles(pad, listOf("作品", ".."))
        assertEquals(listOf("ok.epub"), result.downloaded.map { it.path })
        assertEquals(2, result.rejected.size)
        assertEquals(setOf("作品/ok.epub"), pad.files.keys)
    }

    @Test
    fun `a download of the wrong size is not kept`() {
        server.collections += listOf("Bookmania", "Bookmania/sync-v1", "Bookmania/sync-v1/devices", "Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003")
        server.files["Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003/files.json"] =
            """{"format":1,"files":[{"work":"作品","path":"a.epub","size":10}]}""".toByteArray()
        server.collections += listOf("Bookmania/sync-v1/files", "Bookmania/sync-v1/files/作品")
        server.files["Bookmania/sync-v1/files/作品/a.epub"] = ByteArray(4)
        val result = padSync.syncFiles(pad, listOf("作品"))
        assertTrue(result.downloaded.isEmpty())
        assertEquals(1, result.failed.size)
        assertTrue(pad.files.isEmpty())
    }

    @Test
    fun `files of a newer format are left out`() {
        server.collections += listOf("Bookmania", "Bookmania/sync-v1", "Bookmania/sync-v1/devices", "Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003")
        server.files["Bookmania/sync-v1/devices/c0000000-0000-4000-8000-000000000003/library.json"] =
            """{"format":2,"works":{"0:X":{"favorite":true,"t":5,"d":"c"}}}""".toByteArray()
        val result = padSync.syncLibrary()
        assertEquals(listOf("c0000000-0000-4000-8000-000000000003"), result.newerFormat)
        assertTrue(pad.works.isEmpty())
    }

    @Test
    fun `a wrong password stops the sync`() {
        val wrong = SyncEngine(WebDavClient(server.base, "reader", "nope", server), DeviceInfo(pad.id, "x", "ios", "1"), pad) { now }
        assertEquals(SyncException.Kind.Auth, assertThrows(SyncException::class.java) { wrong.syncLibrary() }.kind)
        assertEquals(SyncException.Kind.Auth, assertThrows(SyncException::class.java) { wrong.syncWork(book, push = true) }.kind)
        assertTrue(pad.baseline.pending.isEmpty())
    }
}
