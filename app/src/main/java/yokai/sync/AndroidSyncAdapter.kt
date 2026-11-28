package yokai.sync

import android.content.Context
import androidx.preference.PreferenceManager
import com.hippo.unifile.UniFile
import eu.kanade.tachiyomi.data.database.models.Category
import eu.kanade.tachiyomi.data.database.models.create
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import yokai.core.sync.ChapterValue
import yokai.core.sync.FileItem
import yokai.core.sync.LibraryChanges
import yokai.core.sync.LibrarySnapshot
import yokai.core.sync.ProgressChanges
import yokai.core.sync.ProgressSnapshot
import yokai.core.sync.SettingValue
import yokai.core.sync.SyncAdapter
import yokai.core.sync.SyncBaseline
import yokai.core.sync.SyncFileAccess
import yokai.core.sync.SyncIds
import yokai.core.sync.SyncJson
import yokai.core.sync.WorkBaseline
import yokai.core.sync.WorkValue
import yokai.domain.category.CategoryRepository
import yokai.domain.category.models.CategoryUpdate
import yokai.domain.chapter.ChapterRepository
import yokai.domain.chapter.models.ChapterUpdate
import yokai.domain.history.HistoryRepository
import yokai.domain.manga.MangaRepository
import yokai.domain.manga.models.MangaUpdate
import yokai.ebook.data.EbookDatabase
import yokai.ebook.data.EbookLocator
import yokai.ebook.data.PositionStore
import yokai.ebook.settings.BookKey

/**
 * The Android side of the WebDAV sync (yokai.core.sync): the library, the chapters, the history, the text book
 * positions (ebook.db) and the synced settings as snapshots, the writing of what other devices changed, the
 * baselines (files in the app's own storage), and the local source's files.
 */
class AndroidSyncAdapter(
    private val context: Context,
    private val mangaRepository: MangaRepository = Injekt.get(),
    private val chapterRepository: ChapterRepository = Injekt.get(),
    private val categoryRepository: CategoryRepository = Injekt.get(),
    private val historyRepository: HistoryRepository = Injekt.get(),
    private val positions: PositionStore = EbookDatabase.get(context),
) : SyncAdapter, SyncFileAccess {

    private val prefs = PreferenceManager.getDefaultSharedPreferences(context)
    private val dir = File(context.filesDir, "sync")
    private val worksDir = File(dir, "works")
    @Volatile private var baseline: SyncBaseline? = null

    private fun parse(work: String): Pair<Long, String>? {
        val i = work.indexOf(':')
        if (i <= 0) return null
        val source = work.substring(0, i).toLongOrNull() ?: return null
        return source to work.substring(i + 1)
    }

    private fun Manga.value(categories: List<String>) =
        WorkValue(favorite, date_added, categories.distinct().sorted(), chapter_flags, viewer_flags.takeIf { it != -1 })

    // region Library

    override fun librarySnapshot(): LibrarySnapshot = runBlocking {
        val categories = categoryRepository.getAll().filter { !it.isSystem && !it.isDynamic }
        val names = categories.mapNotNull { c -> c.id?.let { it.toLong() to c.name } }.toMap()
        val works = sortedMapOf<String, WorkValue>()
        for ((_, rows) in mangaRepository.getLibraryManga().groupBy { it.manga.id }) {
            val manga = rows.first().manga
            works[SyncIds.workKey(manga.source, manga.url)] = manga.value(rows.mapNotNull { names[it.category.toLong()] })
        }
        // Works of the last sync that are not in the library now: removing a work is a change too.
        for (key in loadBaseline().library.works.keys) {
            if (key in works) continue
            val (source, url) = parse(key) ?: continue
            val manga = mangaRepository.getMangaByUrlAndSource(url, source) ?: continue
            works[key] = manga.value(manga.id?.let { id -> categoryRepository.getAllByMangaId(id).map { it.name } } ?: emptyList())
        }
        val settings = sortedMapOf<String, SettingValue>()
        for ((key, value) in prefs.all) {
            val type = SyncSettingsKeys.type(key) ?: continue
            val json = when {
                type == "string" && value is String -> JsonPrimitive(value)
                type == "int" && value is Int -> JsonPrimitive(value)
                type == "bool" && value is Boolean -> JsonPrimitive(value)
                else -> null
            } ?: continue
            settings[key] = SettingValue(type, json)
        }
        LibrarySnapshot(works, categories.associate { it.name to yokai.core.sync.CategoryValue(it.order, it.flags) }, settings)
    }

    override fun applyLibrary(changes: LibraryChanges): Set<String> = runBlocking {
        val ids = mutableSetOf<String>()
        var categories = categoryRepository.getAll().filter { !it.isSystem && !it.isDynamic }
        for ((name, v) in changes.categories) {
            val existing = categories.firstOrNull { it.name == name }
            if (existing?.id != null) {
                categoryRepository.update(CategoryUpdate(existing.id!!.toLong(), order = v.order.toLong(), flags = v.flags.toLong()))
            } else {
                categoryRepository.insert(Category.create(name).apply { order = v.order; flags = v.flags })
            }
            ids += "c:$name"
        }
        for (name in changes.deletedCategories) {
            categories.firstOrNull { it.name == name }?.id?.let { categoryRepository.delete(it.toLong()) }
        }
        categories = categoryRepository.getAll()
        val idByName = categories.mapNotNull { c -> c.id?.let { c.name to it.toLong() } }.toMap()
        for ((key, v) in changes.works) {
            val (source, url) = parse(key) ?: continue
            var manga = mangaRepository.getMangaByUrlAndSource(url, source)
            if (manga == null) {
                // A local work arrives with its folder name; its book files follow with the file sync. An online
                // work needs its source and details, which this sync does not carry yet.
                if (source != LocalSource.ID) continue
                val created = Manga.create(url, url, source)
                created.id = mangaRepository.insert(created) ?: continue
                manga = created
            }
            val id = manga.id ?: continue
            mangaRepository.update(
                MangaUpdate(id, favorite = v.favorite, dateAdded = v.added, chapterFlags = v.chapterFlags, viewerFlags = v.viewerFlags ?: -1),
            )
            mangaRepository.setCategories(id, v.categories.mapNotNull { idByName[it] })
            ids += "w:$key"
        }
        val editor = prefs.edit()
        for ((key, s) in changes.settings) {
            val type = SyncSettingsKeys.type(key) ?: continue
            val value = s.value as? JsonPrimitive
            if (s.value == null) {
                editor.remove(key)
            } else {
                when (type) {
                    "string" -> editor.putString(key, value?.contentOrNull ?: continue)
                    "int" -> editor.putInt(key, value?.intOrNull ?: continue)
                    "bool" -> editor.putBoolean(key, value?.booleanOrNull ?: continue)
                    else -> continue
                }
            }
            ids += "s:$key"
        }
        editor.apply()
        ids
    }

    // endregion

    // region Progress

    override fun progressSnapshot(work: String): ProgressSnapshot = runBlocking {
        val (source, url) = parse(work) ?: return@runBlocking ProgressSnapshot()
        val manga = mangaRepository.getMangaByUrlAndSource(url, source) ?: return@runBlocking ProgressSnapshot()
        val id = manga.id ?: return@runBlocking ProgressSnapshot()
        val history = historyRepository.getAllByMangaId(id).associateBy { it.chapter_id }
        val located = runCatching { positions.positions(source, url) }.getOrDefault(emptyMap())
        ProgressSnapshot(
            chapterRepository.getChapters(id, false).associate { c ->
                val h = history[c.id]
                c.url to ChapterValue(
                    read = c.read,
                    page = c.last_page_read,
                    left = c.pages_left,
                    bookmark = c.bookmark,
                    locator = located[c.url]?.toJson(),
                    lastRead = h?.last_read ?: 0,
                    duration = h?.time_read ?: 0,
                )
            },
        )
    }

    override fun applyProgress(work: String, changes: ProgressChanges): Set<String> = runBlocking {
        val ids = mutableSetOf<String>()
        val (source, url) = parse(work) ?: return@runBlocking ids
        val manga = mangaRepository.getMangaByUrlAndSource(url, source) ?: return@runBlocking ids
        val mangaId = manga.id ?: return@runBlocking ids
        val chapters = chapterRepository.getChapters(mangaId, false).associateBy { it.url }
        val history = historyRepository.getAllByMangaId(mangaId).associateBy { it.chapter_id }
        val updates = mutableListOf<ChapterUpdate>()
        for ((key, c) in changes.chapters) {
            val chapter = chapters[key] ?: continue
            val chapterId = chapter.id ?: continue
            if (c.progress != null || c.bookmark != null) {
                updates += ChapterUpdate(
                    chapterId,
                    read = c.progress?.read,
                    lastPageRead = c.progress?.page?.toLong(),
                    pagesLeft = c.progress?.left?.toLong(),
                    bookmark = c.bookmark,
                )
                if (c.progress != null) ids += "$key|progress"
                if (c.bookmark != null) ids += "$key|bookmark"
            }
            c.position?.let { p ->
                val bookKey = BookKey(source, url, key)
                val text = p.locator
                if (text == null) {
                    positions.removePosition(bookKey)
                    ids += "$key|position"
                } else {
                    EbookLocator.fromJson(text)?.let {
                        positions.putPosition(bookKey, it)
                        ids += "$key|position"
                    }
                }
            }
            c.history?.let { h ->
                // The history query adds the time read; the merged value is the largest one.
                val current = history[chapterId]?.time_read ?: 0
                historyRepository.upsert(chapterId, h.lastRead, maxOf(0, h.duration - current))
            }
        }
        if (updates.isNotEmpty()) chapterRepository.updateAll(updates)
        ids
    }

    // endregion

    // region Baselines

    private fun write(file: File, text: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) {
            file.writeText(text)
            tmp.delete()
        }
    }

    private inline fun <reified T> read(file: File): T? =
        if (!file.exists()) null else runCatching { SyncJson.decodeFromString<T>(file.readText()) }.getOrNull()

    override fun loadBaseline(): SyncBaseline =
        baseline ?: (read<SyncBaseline>(File(dir, "baseline.json")) ?: SyncBaseline()).also { baseline = it }

    override fun saveBaseline(baseline: SyncBaseline) {
        write(File(dir, "baseline.json"), SyncJson.encodeToString(baseline))
        this.baseline = baseline
    }

    override fun loadWorkBaseline(work: String): WorkBaseline =
        read<WorkBaseline>(File(worksDir, SyncIds.progressFileName(work))) ?: WorkBaseline()

    override fun saveWorkBaseline(work: String, baseline: WorkBaseline) =
        write(File(worksDir, SyncIds.progressFileName(work)), SyncJson.encodeToString(baseline))

    /** Forgets everything of the last syncs (another server or account). */
    fun reset() {
        dir.deleteRecursively()
        baseline = null
    }

    // endregion

    // region Book files of the local source

    /**
     * The local source's folders, as the local source reads them (LocalSource.directories): a work is the folders of
     * that name in all of them, so its files are looked for in each.
     */
    private fun roots(): List<UniFile> = LocalSource.directories(context)

    override fun list(works: Collection<String>): List<FileItem> {
        val out = linkedMapOf<Pair<String, String>, FileItem>()
        val roots = roots()
        for (work in works) {
            for (root in roots) {
                val folder = root.findFile(work)?.takeIf { it.isDirectory } ?: continue
                for (f in folder.listFiles().orEmpty()) {
                    val name = f.name ?: continue
                    if (name.startsWith(".")) continue
                    if (f.isDirectory) {
                        for (g in f.listFiles().orEmpty()) {
                            val n = g.name ?: continue
                            if (n.startsWith(".") || g.isDirectory) continue
                            out.putIfAbsent(work to "$name/$n", FileItem(work, "$name/$n", g.length()))
                        }
                    } else {
                        out.putIfAbsent(work to name, FileItem(work, name, f.length()))
                    }
                }
            }
        }
        return out.values.toList()
    }

    private fun resolve(work: String, path: String): UniFile? {
        for (root in roots()) {
            var f: UniFile? = root.findFile(work)
            for (part in path.split('/')) f = f?.findFile(part)
            if (f != null && f.isFile) return f
        }
        return null
    }

    override fun open(work: String, path: String): InputStream =
        resolve(work, path)?.openInputStream() ?: throw IOException("$work/$path is not in the local source folders")

    override fun save(work: String, path: String, input: InputStream) {
        // Next to the work's other files when it has a folder already, else in the first folder the source reads.
        val roots = roots()
        val root = roots.firstOrNull { it.findFile(work)?.isDirectory == true } ?: roots.firstOrNull()
            ?: throw IOException("no local source folder")
        val parts = path.split('/')
        var folder = root.findFile(work) ?: root.createDirectory(work) ?: throw IOException("cannot create $work")
        if (parts.size == 2) {
            folder = folder.findFile(parts[0]) ?: folder.createDirectory(parts[0]) ?: throw IOException("cannot create ${parts[0]}")
        }
        val name = parts.last()
        if (folder.findFile(name) != null) throw IOException("$path exists")
        val tmp = folder.createFile(".bookmania-sync-" + UUID.randomUUID()) ?: throw IOException("cannot write in $work")
        try {
            (tmp.openOutputStream() ?: throw IOException("cannot write $path")).use { out -> input.copyTo(out) }
            if (!tmp.renameTo(name)) throw IOException("cannot name $path")
        } catch (e: Exception) {
            tmp.delete()
            throw if (e is IOException) e else IOException(e.message, e)
        }
    }

    // endregion
}
