package yokai.ebook.data

import android.app.Application
import co.touchlab.kermit.Logger
import eu.kanade.tachiyomi.data.backup.models.BackupChapter
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import yokai.ebook.settings.BookKey

/**
 * Carries the exact reading positions of text books (ebook.db) in backups, in the chapters' Bookmania
 * field [BackupChapter.bookmaniaEbookPosition] (decision 12 of the design). Called from the backup
 * creator and restorer; everything else about the backup is unchanged.
 */
object EbookBackup {

    private fun store(): PositionStore = EbookDatabase.get(Injekt.get<Application>())

    /** Adds the saved positions to [chapters] of [manga] (only Local Source has text books). */
    fun attachPositions(manga: Manga, chapters: List<BackupChapter>, positions: PositionStore = store()) {
        if (manga.source != LocalSource.ID || chapters.isEmpty()) return
        val saved = try {
            positions.positions(manga.source, manga.url)
        } catch (e: Exception) {
            Logger.e(e) { "Reading text book positions for the backup failed" }
            return
        }
        if (saved.isEmpty()) return
        chapters.forEach { chapter -> saved[chapter.url]?.let { chapter.bookmaniaEbookPosition = it.toJson() } }
    }

    /**
     * Writes the positions found in a restored backup, unless the device has a newer one for the same
     * file. Returns how many were written.
     */
    fun restorePositions(manga: Manga, chapters: List<BackupChapter>, positions: PositionStore = store()): Int {
        var written = 0
        chapters.forEach { chapter ->
            val locator = EbookLocator.fromJson(chapter.bookmaniaEbookPosition) ?: return@forEach
            try {
                if (positions.putPositionIfNewer(BookKey(manga.source, manga.url, chapter.url), locator)) written++
            } catch (e: Exception) {
                Logger.e(e) { "Restoring a text book position failed" }
            }
        }
        return written
    }
}
