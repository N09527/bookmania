package yokai.sync

import android.app.Application
import android.os.Build
import co.touchlab.kermit.Logger
import eu.kanade.tachiyomi.BuildConfig
import eu.kanade.tachiyomi.domain.manga.models.Manga
import eu.kanade.tachiyomi.source.LocalSource
import eu.kanade.tachiyomi.source.SourceManager
import eu.kanade.tachiyomi.util.chapter.syncChaptersWithSource
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import yokai.core.sync.DeviceInfo
import yokai.core.sync.OkHttpTransport
import yokai.core.sync.SyncEngine
import yokai.core.sync.SyncException
import yokai.core.sync.SyncIds
import yokai.core.sync.WebDavClient
import yokai.domain.category.CategoryRepository
import yokai.domain.manga.MangaRepository

/**
 * The WebDAV sync of this device (docs/extensions-and-sync): one engine for the configured account, used one call
 * at a time. The library is synced when the app comes to the foreground and after the library or the synced
 * settings change; a work's progress before a reader opens it (waiting at most [PULL_TIMEOUT_MS]) and after it
 * leaves (in a background job).
 */
class SyncManager(private val app: Application) {

    private val prefs: SyncPreferences by lazy { Injekt.get() }
    val adapter by lazy { AndroidSyncAdapter(app) }
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var cached: Pair<String, SyncEngine>? = null
    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .build()
    }

    /** Changes the sync writes itself must not schedule another sync. */
    @Volatile private var applyingUntil = 0L

    fun isConfigured() = prefs.enabled().get() && prefs.serverUrl().get().isNotBlank()

    private fun deviceId(): String {
        var id = prefs.deviceId().get()
        if (id.isBlank()) {
            id = SyncIds.newDeviceId()
            prefs.deviceId().set(id)
        }
        return id
    }

    private fun engine(): SyncEngine? {
        if (!isConfigured()) return null
        val url = prefs.serverUrl().get().trim()
        val user = prefs.user().get()
        val password = SyncSecrets.decrypt(prefs.passwordCipher().get()) ?: ""
        val signature = "$url\u0000$user\u0000${password.hashCode()}"
        cached?.takeIf { it.first == signature }?.let { return it.second }
        val dav = WebDavClient(url, user, password, OkHttpTransport(client))
        val device = DeviceInfo(deviceId(), "${Build.MANUFACTURER} ${Build.MODEL}".trim(), "android", BuildConfig.VERSION_NAME)
        return SyncEngine(dav, device, adapter).also { cached = signature to it }
    }

    private inline fun <T> record(block: () -> T): T {
        try {
            val result = block()
            prefs.lastSync().set(System.currentTimeMillis())
            prefs.lastError().set("")
            return result
        } catch (e: SyncException) {
            prefs.lastError().set(e.message ?: e.kind.name)
            throw e
        }
    }

    /** Marks the sync's own writes (their change notifications arrive a moment later). */
    private inline fun <T> applying(block: () -> T): T {
        applyingUntil = Long.MAX_VALUE
        try {
            return block()
        } finally {
            applyingUntil = System.currentTimeMillis() + 3_000
        }
    }

    /** Syncs the library, the settings and the progress other devices changed. */
    suspend fun syncLibrary(): SyncEngine.LibraryResult? = withContext(Dispatchers.IO) {
        mutex.withLock {
            val engine = engine() ?: return@withLock null
            record { applying { engine.syncLibrary() } }
        }
    }

    suspend fun syncWork(work: String, push: Boolean): SyncEngine.WorkResult? = withContext(Dispatchers.IO) {
        mutex.withLock {
            val engine = engine() ?: return@withLock null
            record { applying { engine.syncWork(work, push) } }
        }
    }

    /**
     * Before a reader opens [manga]: takes the other devices' progress, waiting at most [PULL_TIMEOUT_MS]. On a
     * timeout the sync goes on in the background and the reader opens with what this device has.
     */
    suspend fun pullBeforeReading(manga: Manga) {
        if (!isConfigured()) return
        val work = SyncIds.workKey(manga.source, manga.url)
        val job = scope.async {
            runCatching { syncWork(work, push = false) }.onFailure { Logger.w(it) { "Sync before reading failed" } }
        }
        withTimeoutOrNull(PULL_TIMEOUT_MS) { job.await() }
    }

    /** After a reader leaves [manga]: sends its progress in a background job (kept until there is a connection). */
    fun requestPush(manga: Manga) {
        if (!isConfigured()) return
        SyncWorker.push(app, SyncIds.workKey(manga.source, manga.url))
    }

    fun requestLibrarySync(delaySeconds: Long = 0) {
        if (!isConfigured()) return
        SyncWorker.library(app, delaySeconds)
    }

    /** The book files of the local source works in the library; their chapters are read again after downloads. */
    suspend fun syncFiles(): SyncEngine.FilesResult? = withContext(Dispatchers.IO) {
        if (!prefs.syncFiles().get()) return@withContext null
        val result = mutex.withLock {
            val engine = engine() ?: return@withLock null
            val works = Injekt.get<MangaRepository>().getFavorites().filter { it.source == LocalSource.ID }.map { it.url }
            record { engine.syncFiles(adapter, works) }
        } ?: return@withContext null
        prefs.lastConflicts().set(result.conflicts.map { "${it.work}/${it.path}" }.toSet())
        val changed = result.downloaded.map { it.work }.toSet()
        if (changed.isNotEmpty()) {
            val mangaRepository = Injekt.get<MangaRepository>()
            val source = Injekt.get<SourceManager>().get(LocalSource.ID)
            for (folder in changed) {
                val manga = mangaRepository.getMangaByUrlAndSource(folder, LocalSource.ID) ?: continue
                runCatching {
                    if (source != null) syncChaptersWithSource(source.getChapterList(manga), manga, source)
                    // Progress of chapters that only now have their files.
                    syncWork(SyncIds.localWorkKey(folder), push = false)
                }.onFailure { Logger.w(it) { "Reading the chapters of $folder after the file sync failed" } }
            }
        }
        result
    }

    /** Tries an account before it is saved: null when it works, else what went wrong. */
    suspend fun test(url: String, user: String, password: String): String? = withContext(Dispatchers.IO) {
        try {
            val dav = WebDavClient(url, user, password, OkHttpTransport(client))
            dav.ensureCollections(listOf("Bookmania", "sync-v1"))
            dav.list(listOf("Bookmania", "sync-v1"))
            null
        } catch (e: SyncException) {
            e.message ?: e.kind.name
        }
    }

    /** A new server or account: the last syncs' baselines do not apply to it. */
    fun reset() {
        cached = null
        adapter.reset()
        prefs.lastSync().set(0)
        prefs.lastError().set("")
        prefs.lastConflicts().set(emptySet())
    }

    /** Schedules a library sync after the library or a synced setting changes (not after the sync's own writes). */
    @OptIn(FlowPreview::class)
    fun start() {
        val libraryChanges = merge(
            Injekt.get<MangaRepository>().getLibraryMangaAsFlow().drop(1).map { },
            Injekt.get<CategoryRepository>().getAllAsFlow().drop(1).map { },
        )
        libraryChanges
            .filter { System.currentTimeMillis() > applyingUntil }
            .debounce(LIBRARY_DEBOUNCE_MS)
            .onEach { requestLibrarySync() }
            .launchIn(scope)
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key != null && SyncSettingsKeys.type(key) != null && System.currentTimeMillis() > applyingUntil) {
                requestLibrarySync(LIBRARY_DEBOUNCE_MS / 1000)
            }
        }
        settingsListener = listener
        androidx.preference.PreferenceManager.getDefaultSharedPreferences(app).registerOnSharedPreferenceChangeListener(listener)
    }

    // A strong reference: SharedPreferences keeps its listeners weakly.
    private var settingsListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    companion object {
        const val PULL_TIMEOUT_MS = 5_000L
        const val LIBRARY_DEBOUNCE_MS = 15_000L
    }
}
