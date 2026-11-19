package yokai.ebook.settings

import android.content.Context
import android.net.Uri
import eu.kanade.tachiyomi.core.preference.Preference
import eu.kanade.tachiyomi.core.preference.PreferenceStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import yokai.core.ebook.font.FontInfo
import yokai.core.ebook.font.FontInspector
import yokai.core.ebook.font.InvalidFontException

/** A font the user imported (TTF / OTF). */
@Serializable
data class ImportedFont(val id: String, val name: String, val extension: String, val vertical: Boolean)

/**
 * Imported fonts live in the app's private files (`files/ebook-fonts/<id>.<ttf|otf>`); the list is
 * app state (not in backups, like the files themselves).
 */
class FontStore(private val context: Context, store: PreferenceStore) {

    private val listPref = store.getString(Preference.appStateKey("ebook_fonts"))
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(ImportedFont.serializer())
    private val dir get() = File(context.filesDir, "ebook-fonts")

    fun list(): List<ImportedFont> {
        val text = listPref.get()
        if (text.isEmpty()) return emptyList()
        return runCatching { json.decodeFromString(serializer, text) }.getOrDefault(emptyList())
            .filter { ID.matches(it.id) && fileOf(it)?.isFile == true }
    }

    fun find(id: String): ImportedFont? = list().firstOrNull { it.id == id }

    /** The font file for [id], or null; ids are validated so no other file can be reached. */
    fun file(id: String): File? = find(id)?.let(::fileOf)

    private fun fileOf(font: ImportedFont): File? {
        if (!ID.matches(font.id) || font.extension !in setOf("ttf", "otf")) return null
        return File(dir, "${font.id}.${font.extension}")
    }

    /** Reads and checks a font chosen by the user; nothing is saved yet. */
    fun read(uri: Uri): Pending {
        val resolver = context.contentResolver
        // With the size known, the file is read into one exactly sized buffer (CJK fonts are often
        // 10-30 MB; a growing buffer would hold up to three copies at once).
        val declared = runCatching { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1L
        if (declared > MAX_BYTES) throw InvalidFontException("Font larger than ${MAX_BYTES shr 20} MB")
        val bytes = resolver.openInputStream(uri)?.use { input ->
            val out = SizedOutputStream(if (declared > 0) declared.toInt() else 1 shl 20)
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_BYTES) throw InvalidFontException("Font larger than ${MAX_BYTES shr 20} MB")
            }
            out.bytes()
        } ?: throw InvalidFontException("Cannot read the file")
        val info = FontInspector.inspect(bytes)
        val fallbackName = uri.lastPathSegment?.substringAfterLast('/')?.substringBeforeLast('.')
        return Pending(bytes, info, info.familyName ?: fallbackName ?: "Font")
    }

    /** Returns its buffer without a copy when it is exactly full. */
    private class SizedOutputStream(size: Int) : ByteArrayOutputStream(size) {
        fun bytes(): ByteArray = if (count == buf.size) buf else toByteArray()
    }

    fun save(pending: Pending): ImportedFont {
        val font = ImportedFont(
            id = UUID.randomUUID().toString().replace("-", ""),
            name = pending.name,
            extension = pending.info.format.extension,
            vertical = pending.info.supportsVertical,
        )
        dir.mkdirs()
        File(dir, "${font.id}.${font.extension}").writeBytes(pending.bytes)
        listPref.set(json.encodeToString(serializer, list() + font))
        return font
    }

    fun delete(id: String) {
        val font = find(id) ?: return
        fileOf(font)?.delete()
        listPref.set(json.encodeToString(serializer, list().filter { it.id != id }))
    }

    class Pending(val bytes: ByteArray, val info: FontInfo, val name: String)

    companion object {
        private val ID = Regex("[0-9a-f]{32}")
        private const val MAX_BYTES = 64 shl 20
    }
}
