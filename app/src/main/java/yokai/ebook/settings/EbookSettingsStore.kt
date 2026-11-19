package yokai.ebook.settings

import eu.kanade.tachiyomi.core.preference.PreferenceStore
import java.security.MessageDigest
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Which level a change applies to. */
enum class SettingsScope { GLOBAL, WORK, FILE }

/** Identifies a book for per-work and per-file settings (URLs are stable across backups, ids are not). */
data class BookKey(val sourceId: Long, val mangaUrl: String, val chapterUrl: String)

/**
 * Stores the three levels in the app's preferences, so they are included in backups like the
 * other preferences: global values as `pref_ebook_<key>`, and per-work / per-file overrides as one
 * JSON object each under `pref_ebook_override_<hash>`.
 */
class EbookSettingsStore(private val store: PreferenceStore) {

    private val json = Json { ignoreUnknownKeys = true }
    private val mapSerializer = MapSerializer(String.serializer(), String.serializer())

    fun effective(book: BookKey): EbookSettings =
        EbookSettings.resolve(global(), overrides(SettingsScope.WORK, book), overrides(SettingsScope.FILE, book))

    /** Values a level sets itself (the global level returns only the keys that were changed). */
    fun levelValues(scope: SettingsScope, book: BookKey): Map<String, String> =
        if (scope == SettingsScope.GLOBAL) global() else overrides(scope, book)

    /** The settings as seen from [scope]: that level and the ones above it, ignoring nearer levels. */
    fun resolvedAt(scope: SettingsScope, book: BookKey): EbookSettings = when (scope) {
        SettingsScope.GLOBAL -> EbookSettings.resolve(global())
        SettingsScope.WORK -> EbookSettings.resolve(global(), overrides(SettingsScope.WORK, book))
        SettingsScope.FILE -> effective(book)
    }

    /** Keys that a level nearer than [scope] sets for [book], with the nearest such level (which wins). */
    fun overriddenBelow(scope: SettingsScope, book: BookKey): Map<EbookSettings.Key, SettingsScope> {
        val nearer = SettingsScope.entries.filter { it.ordinal > scope.ordinal }.reversed() // nearest first
        val result = LinkedHashMap<EbookSettings.Key, SettingsScope>()
        nearer.forEach { level ->
            overrides(level, book).keys.mapNotNull { EbookSettings.Key.of(it) }.forEach { result.putIfAbsent(it, level) }
        }
        return result
    }

    /** The level the settings panel starts on: the nearest one that already has values for [book], else global. */
    fun initialScope(book: BookKey): SettingsScope = when {
        overrides(SettingsScope.FILE, book).isNotEmpty() -> SettingsScope.FILE
        overrides(SettingsScope.WORK, book).isNotEmpty() -> SettingsScope.WORK
        else -> SettingsScope.GLOBAL
    }

    fun set(scope: SettingsScope, book: BookKey, key: EbookSettings.Key, value: String) {
        if (scope == SettingsScope.GLOBAL) {
            store.getString(globalKey(key)).set(value)
        } else {
            val map = overrides(scope, book).toMutableMap()
            map[key.id] = value
            writeOverrides(scope, book, map)
        }
    }

    /** Removes everything [scope] sets, so it inherits again (global: back to the defaults). */
    fun clear(scope: SettingsScope, book: BookKey) {
        if (scope == SettingsScope.GLOBAL) {
            EbookSettings.Key.entries.forEach { store.getString(globalKey(it)).delete() }
        } else {
            store.getString(overrideKey(scope, book)).delete()
        }
    }

    private fun global(): Map<String, String> = EbookSettings.Key.entries.mapNotNull { k ->
        val pref = store.getString(globalKey(k))
        if (pref.isSet()) k.id to pref.get() else null
    }.toMap()

    private fun overrides(scope: SettingsScope, book: BookKey): Map<String, String> {
        val text = store.getString(overrideKey(scope, book)).get()
        if (text.isEmpty()) return emptyMap()
        val decoded = runCatching { json.decodeFromString(mapSerializer, text) }.getOrNull() ?: return emptyMap()
        // Only setting keys; the identity fields written with them are ignored here.
        return decoded.filterKeys { EbookSettings.Key.of(it) != null }
    }

    private fun writeOverrides(scope: SettingsScope, book: BookKey, values: Map<String, String>) {
        val pref = store.getString(overrideKey(scope, book))
        if (values.isEmpty()) {
            pref.delete()
            return
        }
        // The identity is stored alongside, so a backup stays readable and can be re-keyed if needed.
        val identity = buildMap {
            put("_source", book.sourceId.toString())
            put("_manga", book.mangaUrl)
            if (scope == SettingsScope.FILE) put("_chapter", book.chapterUrl)
        }
        pref.set(json.encodeToString(mapSerializer, identity + values))
    }

    companion object {
        private const val PREFIX = "pref_ebook_"

        fun globalKey(key: EbookSettings.Key) = PREFIX + key.id

        fun overrideKey(scope: SettingsScope, book: BookKey): String {
            val identity = when (scope) {
                SettingsScope.WORK -> "work\u0000${book.sourceId}\u0000${book.mangaUrl}"
                SettingsScope.FILE -> "file\u0000${book.sourceId}\u0000${book.mangaUrl}\u0000${book.chapterUrl}"
                SettingsScope.GLOBAL -> error("The global level has no override key")
            }
            val digest = MessageDigest.getInstance("SHA-1").digest(identity.toByteArray(Charsets.UTF_8))
            return PREFIX + "override_" + digest.joinToString("") { "%02x".format(it) }
        }
    }
}
