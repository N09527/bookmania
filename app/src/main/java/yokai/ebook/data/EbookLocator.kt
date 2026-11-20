package yokai.ebook.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * A reading position in a text book, as saved in ebook.db and in backups (as JSON).
 *
 * It is restored in this order (the reader shell's `resolvePosition`): [location] when the text there
 * still matches [text]; else the occurrence of [text] nearest to [progression]; else [progression].
 * A page without text (a picture) has no location and is saved by its page ([pageProgression]).
 */
@Serializable
data class EbookLocator(
    /** Spine index and path of the document; the path wins when the spine changed. */
    val spine: Int,
    val href: String,
    /** [text node index, offset] of the first character of the page in the shell's text walk. */
    val location: List<Int>? = null,
    /** Non-whitespace text from [location] on, to find the place again when the location does not match. */
    val text: String = "",
    /** Fraction of the document's text before [location] (0..1). */
    val progression: Double = 0.0,
    /** Page fraction (page / pages), only for a page without text. */
    val pageProgression: Double? = null,
    /** Whole-book fraction (0..1), from the documents' character counts; null when they were not known. */
    val total: Double? = null,
    /** The page was the last one of the book. */
    val atEnd: Boolean = false,
    /**
     * The chapter's `last_page_read` written together with this position (the estimated page), or null
     * when no page numbers were written. If the chapter list later shows no progress although this was
     * above 0, the progress was cleared there ("mark as unread") and the book starts from the beginning.
     */
    val chapterPage: Int? = null,
    val updatedAt: Long = 0,
    val version: Int = 1,
) {
    fun toJson(): String = JSON.encodeToString(serializer(), this)

    companion object {
        private val JSON = Json { ignoreUnknownKeys = true; encodeDefaults = false }

        /** Null for anything that is not a locator this version can use. */
        fun fromJson(json: String?): EbookLocator? {
            if (json.isNullOrBlank()) return null
            return try {
                JSON.decodeFromString(serializer(), json).takeIf { it.isValid() }
            } catch (e: Exception) {
                null
            }
        }
    }

    private fun isValid(): Boolean =
        spine >= 0 && progression in 0.0..1.0 && (location == null || (location.size == 2 && location.all { it >= 0 })) &&
            (pageProgression == null || pageProgression in 0.0..1.0) && (total == null || total in 0.0..1.0) &&
            (chapterPage == null || chapterPage >= 0)
}
