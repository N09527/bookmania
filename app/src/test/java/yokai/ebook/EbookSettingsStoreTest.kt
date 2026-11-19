package yokai.ebook

import eu.kanade.tachiyomi.core.preference.Preference
import eu.kanade.tachiyomi.core.preference.PreferenceStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import yokai.ebook.settings.BookKey
import yokai.ebook.settings.EbookSettings
import yokai.ebook.settings.EbookSettings.Key
import yokai.ebook.settings.EbookSettingsStore
import yokai.ebook.settings.SettingsScope

class EbookSettingsStoreTest {

    private val prefs = FakePreferenceStore()
    private val store = EbookSettingsStore(prefs)
    private val bookA = BookKey(0, "Author/Series", "Author/Series/vol1.epub")
    private val bookA2 = BookKey(0, "Author/Series", "Author/Series/vol2.epub")
    private val bookB = BookKey(0, "Other", "Other/book.azw3")

    @Test
    fun `nothing set gives the defaults`() {
        assertEquals(EbookSettings.DEFAULTS, store.effective(bookA))
        assertEquals(SettingsScope.GLOBAL, store.initialScope(bookA))
        assertTrue(prefs.values.isEmpty())
    }

    @Test
    fun `global applies to every book, work to its files, file to one file`() {
        store.set(SettingsScope.GLOBAL, bookA, Key.FONT_SIZE, "24")
        store.set(SettingsScope.WORK, bookA, Key.FONT_SIZE, "28")
        store.set(SettingsScope.FILE, bookA, Key.LINE_HEIGHT, "1.5")

        assertEquals(28, store.effective(bookA).fontSize)
        assertEquals(1.5f, store.effective(bookA).lineHeight)
        assertEquals(28, store.effective(bookA2).fontSize) // same work
        assertEquals(1.8f, store.effective(bookA2).lineHeight) // file setting not shared
        assertEquals(24, store.effective(bookB).fontSize) // other work: global only
        assertEquals(SettingsScope.FILE, store.initialScope(bookA))
        assertEquals(SettingsScope.WORK, store.initialScope(bookA2))
        assertEquals(SettingsScope.GLOBAL, store.initialScope(bookB))
    }

    @Test
    fun `global values are stored under pref_ebook_ keys`() {
        store.set(SettingsScope.GLOBAL, bookA, Key.WRITING_MODE, EbookSettings.MODE_VERTICAL)
        assertEquals(EbookSettings.MODE_VERTICAL, prefs.values["pref_ebook_writingMode"])
    }

    @Test
    fun `overrides keep the book identity and ignore it when reading`() {
        store.set(SettingsScope.FILE, bookA, Key.INDENT, "1")
        val key = EbookSettingsStore.overrideKey(SettingsScope.FILE, bookA)
        assertTrue(key.startsWith("pref_ebook_override_"))
        val json = Json.parseToJsonElement(prefs.values.getValue(key) as String).jsonObject
        assertEquals("Author/Series/vol1.epub", json.getValue("_chapter").jsonPrimitive.content)
        assertEquals("1", json.getValue("indent").jsonPrimitive.content)
        assertEquals(mapOf("indent" to "1"), store.levelValues(SettingsScope.FILE, bookA))
    }

    @Test
    fun `levels of different books never share a key`() {
        val keys = listOf(
            EbookSettingsStore.overrideKey(SettingsScope.WORK, bookA),
            EbookSettingsStore.overrideKey(SettingsScope.WORK, bookB),
            EbookSettingsStore.overrideKey(SettingsScope.FILE, bookA),
            EbookSettingsStore.overrideKey(SettingsScope.FILE, bookA2),
            EbookSettingsStore.overrideKey(SettingsScope.WORK, bookA.copy(sourceId = 1)),
        )
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(
            EbookSettingsStore.overrideKey(SettingsScope.WORK, bookA),
            EbookSettingsStore.overrideKey(SettingsScope.WORK, bookA2),
        )
        assertNotEquals(keys[2], keys[3])
    }

    @Test
    fun `resolvedAt ignores nearer levels and overriddenBelow names the winner`() {
        store.set(SettingsScope.GLOBAL, bookA, Key.FONT_SIZE, "22")
        store.set(SettingsScope.WORK, bookA, Key.FONT_SIZE, "26")
        store.set(SettingsScope.WORK, bookA, Key.MARGIN_TOP, "40")
        store.set(SettingsScope.FILE, bookA, Key.FONT_SIZE, "30")

        assertEquals(22, store.resolvedAt(SettingsScope.GLOBAL, bookA).fontSize)
        assertEquals(26, store.resolvedAt(SettingsScope.WORK, bookA).fontSize)
        assertEquals(30, store.resolvedAt(SettingsScope.FILE, bookA).fontSize)

        assertEquals(
            mapOf(Key.FONT_SIZE to SettingsScope.FILE, Key.MARGIN_TOP to SettingsScope.WORK),
            store.overriddenBelow(SettingsScope.GLOBAL, bookA),
        )
        assertEquals(mapOf(Key.FONT_SIZE to SettingsScope.FILE), store.overriddenBelow(SettingsScope.WORK, bookA))
        assertTrue(store.overriddenBelow(SettingsScope.FILE, bookA).isEmpty())
    }

    @Test
    fun `clearing a level makes it inherit again`() {
        store.set(SettingsScope.GLOBAL, bookA, Key.FONT_SIZE, "22")
        store.set(SettingsScope.WORK, bookA, Key.FONT_SIZE, "26")
        store.set(SettingsScope.FILE, bookA, Key.FONT_SIZE, "30")

        store.clear(SettingsScope.FILE, bookA)
        assertEquals(26, store.effective(bookA).fontSize)
        store.clear(SettingsScope.WORK, bookA)
        assertEquals(22, store.effective(bookA).fontSize)
        store.clear(SettingsScope.GLOBAL, bookA)
        assertEquals(EbookSettings.DEFAULTS, store.effective(bookA))
        assertFalse(prefs.values.keys.any { it.startsWith("pref_ebook_") })
    }

    @Test
    fun `a broken override is ignored`() {
        prefs.values[EbookSettingsStore.overrideKey(SettingsScope.WORK, bookA)] = "{not json"
        assertEquals(EbookSettings.DEFAULTS, store.effective(bookA))
    }

    /** Only what [EbookSettingsStore] uses: string preferences. */
    private class FakePreferenceStore : PreferenceStore {
        val values = LinkedHashMap<String, Any>()

        override fun getString(key: String, defaultValue: String): Preference<String> = object : Preference<String> {
            override fun key() = key
            override fun get() = values[key] as String? ?: defaultValue
            override fun set(value: String) {
                values[key] = value
            }
            override fun isSet() = key in values
            override fun delete() {
                values.remove(key)
            }
            override fun defaultValue() = defaultValue
            override fun changes(): Flow<String> = throw UnsupportedOperationException()
            override fun stateIn(scope: CoroutineScope): StateFlow<String> = throw UnsupportedOperationException()
        }

        override fun getLong(key: String, defaultValue: Long): Preference<Long> = throw UnsupportedOperationException()
        override fun getInt(key: String, defaultValue: Int): Preference<Int> = throw UnsupportedOperationException()
        override fun getFloat(key: String, defaultValue: Float): Preference<Float> = throw UnsupportedOperationException()
        override fun getBoolean(key: String, defaultValue: Boolean): Preference<Boolean> = throw UnsupportedOperationException()
        override fun getStringSet(key: String, defaultValue: Set<String>): Preference<Set<String>> =
            throw UnsupportedOperationException()
        override fun <T> getObject(
            key: String,
            defaultValue: T,
            serializer: (T) -> String,
            deserializer: (String) -> T,
        ): Preference<T> = throw UnsupportedOperationException()
        override fun getAll(): Map<String, *> = values
    }
}
