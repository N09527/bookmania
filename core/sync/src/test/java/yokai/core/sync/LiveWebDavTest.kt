package yokai.core.sync

import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable

/**
 * The Android side of the cross-platform test against a real WebDAV server (core/sync/interop/run.sh); skipped
 * unless BOOKMANIA_WEBDAV_URL is set. The iOS side is SyncLiveTests (Swift). Both use the data in [Interop].
 */
@EnabledIfEnvironmentVariable(named = "BOOKMANIA_WEBDAV_URL", matches = ".+")
class LiveWebDavTest {

    object Interop {
        const val ANDROID = "a1111111-1111-4111-8111-111111111111"
        const val IOS = "b2222222-2222-4222-8222-222222222222"
        const val FOLDER = "互通測試"
        val BOOK = SyncIds.localWorkKey(FOLDER)
        const val CH1 = "$FOLDER/第1冊.epub"
        const val CH2 = "$FOLDER/第2冊.epub"
        const val T1 = 1_764_300_000_000
        const val T2 = 1_764_400_000_000
        val LOCATOR = """{"spine":3,"href":"OEBPS/text/ch04.xhtml","location":[12,0],"text":"互通的位置","progression":0.5,"updatedAt":$T1}"""
        fun bytes(n: Int, seed: Int) = ByteArray(n) { ((it * 31 + seed) % 251).toByte() }
    }

    private val role = System.getenv("BOOKMANIA_WEBDAV_ROLE") ?: ""

    private fun engine(d: FakeDevice) = SyncEngine(
        WebDavClient(
            System.getenv("BOOKMANIA_WEBDAV_URL"),
            System.getenv("BOOKMANIA_WEBDAV_USER") ?: "",
            System.getenv("BOOKMANIA_WEBDAV_PASSWORD") ?: "",
            OkHttpTransport(OkHttpClient()),
            requireHttps = false, // the local test server
        ),
        DeviceInfo(d.id, "Android interop test", "android", "test"),
        d,
    )

    @Test
    fun `cross-platform sync on a real server`() {
        when (role) {
            "android-write" -> write()
            "android-check" -> check()
            else -> fail("BOOKMANIA_WEBDAV_ROLE must be android-write or android-check")
        }
    }

    private fun write() {
        val a = FakeDevice(Interop.ANDROID)
        a.works[Interop.BOOK] = WorkValue(favorite = true, added = Interop.T1 - 1000, categories = listOf("互通"))
        a.categories["互通"] = CategoryValue(order = 0, flags = 0)
        a.settings["pref_ebook_fontSize"] = SettingValue("string", JsonPrimitive("26"))
        a.settings["pref_reader_theme_key"] = SettingValue("int", JsonPrimitive(4))
        a.settings["pref_ebook_gutter_shadow"] = SettingValue("bool", JsonPrimitive(false))
        a.setChapter(Interop.BOOK, Interop.CH1, ChapterValue(read = true, page = 41, lastRead = Interop.T1, duration = 600_000))
        a.setChapter(Interop.BOOK, Interop.CH2, ChapterValue(page = 12, left = 30, bookmark = true, locator = Interop.LOCATOR, lastRead = Interop.T1, duration = 120_000))
        a.files["${Interop.FOLDER}/第1冊.epub"] = Interop.bytes(2000, 1)
        a.files["${Interop.FOLDER}/第2冊.epub"] = Interop.bytes(1500, 2)
        val sync = engine(a)
        sync.syncLibrary()
        assertEquals(true, sync.syncWork(Interop.BOOK, push = true).uploaded)
        assertEquals(2, sync.syncFiles(a, listOf(Interop.FOLDER)).uploaded.size)
    }

    private fun check() {
        // The same device again (a new process: no baseline), holding what it wrote before.
        val a = FakeDevice(Interop.ANDROID)
        a.works[Interop.BOOK] = WorkValue(favorite = true, added = Interop.T1 - 1000, categories = listOf("互通"))
        a.setChapter(Interop.BOOK, Interop.CH1, ChapterValue(read = true, page = 41, lastRead = Interop.T1, duration = 600_000))
        a.setChapter(Interop.BOOK, Interop.CH2, ChapterValue(page = 12, left = 30, bookmark = true, locator = Interop.LOCATOR, lastRead = Interop.T1, duration = 120_000))
        engine(a).syncWork(Interop.BOOK, push = false)
        // What the iOS side read further (SyncLiveTests).
        assertEquals(ChapterValue(page = 20, left = 22, bookmark = true, locator = Interop.LOCATOR, lastRead = Interop.T2, duration = 180_000), a.chapter(Interop.BOOK, Interop.CH2))
        assertEquals(ChapterValue(read = true, page = 41, lastRead = Interop.T1, duration = 600_000), a.chapter(Interop.BOOK, Interop.CH1))
    }
}
