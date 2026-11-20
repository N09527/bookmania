package yokai.ebook.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import yokai.ebook.settings.BookKey

/**
 * Bookmania's own small database `ebook.db`, separate from the app's main database so that the main
 * database keeps upstream's migrations (design 5.5): reading positions of text books, and per book
 * file the text/comic classification and the character counts used for whole-book progress.
 *
 * Rows are keyed by (source id, manga url, chapter url): URLs survive a backup and restore, database
 * ids do not. Use from a background thread.
 */
class EbookDatabase private constructor(context: Context) :
    SQLiteOpenHelper(context, NAME, null, VERSION), PositionStore, BookInfoStore {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE position (
                source INTEGER NOT NULL, manga_url TEXT NOT NULL, chapter_url TEXT NOT NULL,
                locator TEXT NOT NULL, updated_at INTEGER NOT NULL,
                PRIMARY KEY (source, manga_url, chapter_url))""",
        )
        db.execSQL(
            """CREATE TABLE book (
                source INTEGER NOT NULL, manga_url TEXT NOT NULL, chapter_url TEXT NOT NULL,
                kind_auto TEXT, kind_user TEXT,
                file_size INTEGER, file_modified INTEGER, char_counts TEXT,
                PRIMARY KEY (source, manga_url, chapter_url))""",
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    // region positions

    override fun position(key: BookKey): EbookLocator? =
        readableDatabase.query("position", arrayOf("locator"), WHERE, args(key), null, null, null).use { c ->
            if (c.moveToFirst()) EbookLocator.fromJson(c.getString(0)) else null
        }

    override fun positions(sourceId: Long, mangaUrl: String): Map<String, EbookLocator> {
        val result = LinkedHashMap<String, EbookLocator>()
        readableDatabase.query(
            "position", arrayOf("chapter_url", "locator"), "source = ? AND manga_url = ?",
            arrayOf(sourceId.toString(), mangaUrl), null, null, null,
        ).use { c ->
            while (c.moveToNext()) EbookLocator.fromJson(c.getString(1))?.let { result[c.getString(0)] = it }
        }
        return result
    }

    override fun putPosition(key: BookKey, locator: EbookLocator) {
        val values = keyValues(key).apply {
            put("locator", locator.toJson())
            put("updated_at", locator.updatedAt)
        }
        writableDatabase.insertWithOnConflict("position", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    // endregion

    // region book info

    override fun info(key: BookKey): BookInfo? =
        readableDatabase.query(
            "book", arrayOf("kind_auto", "kind_user", "file_size", "file_modified", "char_counts"),
            WHERE, args(key), null, null, null,
        ).use { c ->
            if (!c.moveToFirst()) return null
            BookInfo(
                kindAuto = c.getString(0),
                kindUser = c.getString(1),
                fileSize = if (c.isNull(2)) null else c.getLong(2),
                fileModified = if (c.isNull(3)) null else c.getLong(3),
                charCounts = c.getString(4)?.let(BookInfo::parseCounts),
            )
        }

    override fun updateInfo(key: BookKey, change: (BookInfo) -> BookInfo) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val updated = change(info(key) ?: BookInfo())
            val values = keyValues(key).apply {
                put("kind_auto", updated.kindAuto)
                put("kind_user", updated.kindUser)
                put("file_size", updated.fileSize)
                put("file_modified", updated.fileModified)
                put("char_counts", updated.charCounts?.joinToString(","))
            }
            db.insertWithOnConflict("book", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // endregion

    private fun args(key: BookKey) = arrayOf(key.sourceId.toString(), key.mangaUrl, key.chapterUrl)

    private fun keyValues(key: BookKey) = ContentValues().apply {
        put("source", key.sourceId)
        put("manga_url", key.mangaUrl)
        put("chapter_url", key.chapterUrl)
    }

    companion object {
        const val NAME = "ebook.db"
        private const val VERSION = 1
        private const val WHERE = "source = ? AND manga_url = ? AND chapter_url = ?"

        @Volatile private var instance: EbookDatabase? = null

        fun get(context: Context): EbookDatabase =
            instance ?: synchronized(this) {
                instance ?: EbookDatabase(context.applicationContext).also { instance = it }
            }
    }
}

/** Reading positions of text books. */
interface PositionStore {
    fun position(key: BookKey): EbookLocator?

    /** Positions of the chapters (files) of one work, by chapter url (for backups). */
    fun positions(sourceId: Long, mangaUrl: String): Map<String, EbookLocator>

    fun putPosition(key: BookKey, locator: EbookLocator)

    /** Keeps the newer of the stored position and [locator] (a restored backup must not undo newer reading). */
    fun putPositionIfNewer(key: BookKey, locator: EbookLocator): Boolean {
        val current = position(key)
        if (current != null && current.updatedAt >= locator.updatedAt) return false
        putPosition(key, locator)
        return true
    }
}

/** Per book file: classification and character counts. */
interface BookInfoStore {
    fun info(key: BookKey): BookInfo?

    fun updateInfo(key: BookKey, change: (BookInfo) -> BookInfo)
}

data class BookInfo(
    /** Automatic classification ("TEXT" / "COMIC") of an EPUB, cached so it is not repeated at every start. */
    val kindAuto: String? = null,
    /** The user's choice for this file, which wins over [kindAuto]. */
    val kindUser: String? = null,
    /** File size and modification time the character counts were computed for. */
    val fileSize: Long? = null,
    val fileModified: Long? = null,
    val charCounts: IntArray? = null,
) {
    /** The cached counts, if they were computed for this version of the file. */
    fun countsFor(size: Long, modified: Long): IntArray? =
        charCounts?.takeIf { fileSize == size && fileModified == modified }

    override fun equals(other: Any?): Boolean = other is BookInfo && kindAuto == other.kindAuto &&
        kindUser == other.kindUser && fileSize == other.fileSize && fileModified == other.fileModified &&
        charCounts.contentEquals(other.charCounts)

    override fun hashCode(): Int = listOf(kindAuto, kindUser, fileSize, fileModified, charCounts?.contentHashCode()).hashCode()

    companion object {
        fun parseCounts(text: String): IntArray? =
            if (text.isEmpty()) IntArray(0) else runCatching { text.split(',').map { it.trim().toInt() }.toIntArray() }.getOrNull()
    }
}
