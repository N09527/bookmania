package yokai.core.sync

import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

data class DeviceInfo(val id: String, val name: String, val platform: String, val app: String)

/** What a platform gives the engine: its data as snapshots, the writing of changes, and the baselines. */
interface SyncAdapter {
    fun librarySnapshot(): LibrarySnapshot

    /** Writes [changes]; returns the ids ("w:", "c:", "s:") of the entries written. */
    fun applyLibrary(changes: LibraryChanges): Set<String>

    fun progressSnapshot(work: String): ProgressSnapshot

    /** Writes the changes of a work's chapters; returns the parts written ("<chapter>|progress", "|bookmark", "|position"). */
    fun applyProgress(work: String, changes: ProgressChanges): Set<String>

    fun loadBaseline(): SyncBaseline
    fun saveBaseline(baseline: SyncBaseline)
    fun loadWorkBaseline(work: String): WorkBaseline
    fun saveWorkBaseline(work: String, baseline: WorkBaseline)
}

/** The local source's files, for the book file sync. */
interface SyncFileAccess {
    /** The files in the folders of [works] and in their subfolders (one level), without hidden files; `t` is unused. */
    fun list(works: Collection<String>): List<FileItem>

    fun open(work: String, path: String): InputStream

    /**
     * Writes a file that does not exist yet, creating its folder. The data has to go to a temporary file first and be
     * moved into place only when [input] was read to its end without an exception.
     */
    fun save(work: String, path: String, input: InputStream)
}

/** The flows of sync-format.md section 5. One engine per account; calls must not run at the same time. */
class SyncEngine(
    private val dav: WebDavClient,
    private val device: DeviceInfo,
    private val adapter: SyncAdapter,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class WorkResult(val work: String, val changes: ProgressChanges, val uploaded: Boolean)

    data class LibraryResult(
        val changes: LibraryChanges,
        val works: List<WorkResult>,
        /** Devices whose files have a newer format, left out. */
        val newerFormat: List<String>,
    )

    data class FilesResult(
        val uploaded: List<FileItem> = emptyList(),
        val downloaded: List<FileItem> = emptyList(),
        /** Same path, different size: nothing done. */
        val conflicts: List<FileItem> = emptyList(),
        /** Names that fail the checks of [SyncNames]. */
        val rejected: List<FileItem> = emptyList(),
        val failed: List<Pair<FileItem, String>> = emptyList(),
    )

    private val root = listOf("Bookmania", "sync-v1")
    private val devicesDir = root + "devices"
    private val ownDir = devicesDir + device.id
    private val filesDir = root + "files"
    private val madeCollections = mutableSetOf<List<String>>()
    private var deviceList: List<String>? = null

    private fun ensure(path: List<String>) {
        for (n in 1..path.size) {
            val p = path.subList(0, n).toList()
            if (p in madeCollections) continue
            if (dav.mkcol(p) && p == ownDir) forgetUploads()
            madeCollections += p
        }
    }

    private fun ensureFolders() {
        ensure(ownDir + "progress")
        ensure(filesDir)
    }

    /**
     * This device's folder had to be created: the server has nothing of this device (its first sync, or the files
     * on the server were removed). What this device uploaded is sent again (sync-format.md section 5.1): library.json
     * and device.json, the progress of the works it had sent (now pending), and its book files.
     */
    private fun forgetUploads() {
        val b = adapter.loadBaseline()
        for (work in b.ownProgress.keys) {
            val wb = adapter.loadWorkBaseline(work)
            if (wb.uploaded != null) adapter.saveWorkBaseline(work, wb.copy(uploaded = null))
        }
        if (b.ownProgress.isEmpty() && b.uploadedLibrary == null && b.uploadedDevice == null && b.uploadedFiles.isEmpty()) return
        adapter.saveBaseline(
            b.copy(
                ownProgress = emptyMap(),
                uploadedLibrary = null,
                uploadedDevice = null,
                uploadedFiles = emptyList(),
                pending = b.pending + b.ownProgress.keys,
            ),
        )
    }

    /** The other devices' ids: listed again with [refresh], else the last listing (if there is one). */
    fun otherDevices(refresh: Boolean = true): List<String> {
        val cached = deviceList
        if (!refresh && cached != null) return cached
        val list = dav.list(devicesDir)
            .filter { it.collection && it.name != device.id && SyncNames.validSegment(it.name) }
            .map { it.name }
            .sorted()
        deviceList = list
        return list
    }

    private inline fun <reified T> decode(bytes: ByteArray?): T? =
        bytes?.let { runCatching { SyncJson.decodeFromString<T>(it.decodeToString()) }.getOrNull() }

    // region Library

    /**
     * Syncs the library and the settings, then the progress of works another device changed, of works this device
     * could not send, and of [libraryWorks] whose progress changed here (in the reader or not, e.g. marked as read in
     * the library); finding that needs no network.
     */
    fun syncLibrary(libraryWorks: Collection<String> = emptyList()): LibraryResult {
        // Each library sync checks the folders again, so a server that lost them is noticed (forgetUploads).
        madeCollections.clear()
        ensureFolders()
        val newer = mutableListOf<String>()
        val remotes = mutableListOf<LibraryFile>()
        for (id in otherDevices(refresh = true)) {
            val file = decode<LibraryFile>(dav.get(devicesDir + id + "library.json")) ?: continue
            if (file.format > SYNC_FORMAT) {
                newer += id
                continue
            }
            remotes += file.copy(device = id)
        }
        var baseline = adapter.loadBaseline()
        val snapshot = adapter.librarySnapshot()
        val now = clock()
        val local = SyncMerge.annotate(snapshot, baseline, now, device.id)
        val merged = SyncMerge.merge(local, remotes.map { it.state }, now, device.id)
        val (changes, equal) = SyncMerge.changes(merged, snapshot)
        val applied = if (changes.isEmpty) emptySet() else adapter.applyLibrary(changes)
        baseline = upload(baseline.copy(library = merged, applied = equal + applied), now)
        adapter.saveBaseline(baseline)

        // Progress another device rewrote since it was merged here, and progress this device could not send.
        val pull = sortedSetOf<String>()
        for (r in remotes) {
            for ((work, written) in r.progress) {
                if (written > (baseline.seen[r.device]?.get(work) ?: 0)) pull += work
            }
        }
        val works = mutableListOf<WorkResult>()
        for (work in (pull + baseline.pending + libraryWorks).toSortedSet()) {
            val changedHere = hasLocalChanges(work)
            if (work !in pull && work !in baseline.pending && !changedHere) continue
            works += syncWork(work, push = work in baseline.pending || changedHere, refreshDevices = false, sendLibrary = false)
        }
        // library.json once for all the works sent above, not once per work.
        if (works.isNotEmpty()) adapter.saveBaseline(upload(adapter.loadBaseline(), clock()))
        // A progress file listed but missing must not be asked for again and again.
        if (pull.isNotEmpty()) {
            var b = adapter.loadBaseline()
            val seen = b.seen.toMutableMap()
            for (r in remotes) {
                val m = (seen[r.device] ?: emptyMap()).toMutableMap()
                for ((work, written) in r.progress) if (work in pull) m[work] = maxOf(m[work] ?: 0, written)
                seen[r.device] = m
            }
            b = b.copy(seen = seen)
            adapter.saveBaseline(b)
        }
        return LibraryResult(changes, works, newer)
    }

    /** Sends library.json and device.json when their content changed. */
    private fun upload(baseline: SyncBaseline, now: Long): SyncBaseline {
        var b = baseline
        val library = b.library
        val content = SyncJson.encodeToString(LibraryFile(SYNC_FORMAT, device.id, 0, library.works, library.categories, library.settings, b.ownProgress))
        if (content != b.uploadedLibrary) {
            val file = LibraryFile(SYNC_FORMAT, device.id, now, library.works, library.categories, library.settings, b.ownProgress)
            dav.putJson(ownDir + "library.json", SyncJson.encodeToString(file))
            b = b.copy(uploadedLibrary = content)
        }
        val deviceContent = SyncJson.encodeToString(DeviceFile(SYNC_FORMAT, device.id, device.name, device.platform, device.app, 0))
        if (deviceContent != b.uploadedDevice) {
            val file = DeviceFile(SYNC_FORMAT, device.id, device.name, device.platform, device.app, now)
            dav.putJson(ownDir + "device.json", SyncJson.encodeToString(file))
            b = b.copy(uploadedDevice = deviceContent)
        }
        return b
    }

    // endregion

    // region One work

    /** Whether this device's chapters of [work] changed since the work's last sync (no network). */
    fun hasLocalChanges(work: String): Boolean {
        val base = adapter.loadWorkBaseline(work)
        val local = SyncMerge.annotate(adapter.progressSnapshot(work), base, clock(), device.id)
        return local.chapters != base.chapters
    }

    /**
     * Merges a work's progress with the other devices' and writes the result here. With [push] (leaving the reader),
     * this device's progress file and library.json are sent too; if that fails, the work is kept as pending. Without
     * [sendLibrary], library.json is left to the caller (a library sync sends it once for many works).
     */
    fun syncWork(work: String, push: Boolean, refreshDevices: Boolean = true, sendLibrary: Boolean = true): WorkResult {
        try {
            ensureFolders()
            val name = SyncIds.progressFileName(work)
            val remotes = mutableListOf<ProgressFile>()
            for (id in otherDevices(refreshDevices)) {
                val file = decode<ProgressFile>(dav.get(devicesDir + id + "progress" + name)) ?: continue
                if (file.format > SYNC_FORMAT || file.work != work) continue
                remotes += file.copy(device = id)
            }
            val base = adapter.loadWorkBaseline(work)
            val snapshot = adapter.progressSnapshot(work)
            val now = clock()
            val local = SyncMerge.annotate(snapshot, base, now, device.id)
            val merged = SyncMerge.mergeProgress(local, remotes.map { it.state }, now, device.id)
            val (changes, equal) = SyncMerge.changes(merged, snapshot)
            val applied = if (changes.isEmpty) emptySet() else adapter.applyProgress(work, changes)
            var nextBase = WorkBaseline(merged.chapters, equal + applied, base.uploaded)

            var lib = adapter.loadBaseline()
            val seen = lib.seen.toMutableMap()
            for (r in remotes) {
                val m = (seen[r.device] ?: emptyMap()).toMutableMap()
                m[work] = maxOf(m[work] ?: 0, r.written)
                seen[r.device] = m
            }
            lib = lib.copy(seen = seen)
            var uploaded = false
            if (push) {
                val content = SyncJson.encodeToString(ProgressFile(SYNC_FORMAT, device.id, 0, work, merged.chapters))
                if (content != base.uploaded && merged.chapters.isNotEmpty()) {
                    val file = ProgressFile(SYNC_FORMAT, device.id, now, work, merged.chapters)
                    dav.putJson(ownDir + "progress" + name, SyncJson.encodeToString(file))
                    nextBase = nextBase.copy(uploaded = content)
                    lib = lib.copy(ownProgress = (lib.ownProgress + (work to now)).toSortedMap())
                    uploaded = true
                }
                lib = lib.copy(pending = lib.pending - work)
                if (sendLibrary) lib = upload(lib, now)
            }
            adapter.saveWorkBaseline(work, nextBase)
            adapter.saveBaseline(lib)
            return WorkResult(work, changes, uploaded)
        } catch (e: SyncException) {
            if (push && e.kind != SyncException.Kind.Auth && e.kind != SyncException.Kind.Config) {
                val lib = adapter.loadBaseline()
                if (work !in lib.pending) adapter.saveBaseline(lib.copy(pending = lib.pending + work))
            }
            throw e
        }
    }

    // endregion

    // region Book files

    /** sync-format.md section 5.3, for the local source works in the library ([libraryWorks]: their folders). */
    fun syncFiles(access: SyncFileAccess, libraryWorks: Collection<String>): FilesResult {
        ensureFolders()
        var baseline = adapter.loadBaseline()
        val remote = linkedMapOf<Pair<String, String>, FileItem>()
        for (id in otherDevices()) {
            val f = decode<FilesFile>(dav.get(devicesDir + id + "files.json")) ?: continue
            if (f.format > SYNC_FORMAT) continue
            for (item in f.files) remote.putIfAbsent(item.work to item.path, item)
        }
        for (item in baseline.uploadedFiles) remote.putIfAbsent(item.work to item.path, item)
        val works = libraryWorks.toSet()
        val local = access.list(works).filter { it.work in works }.associateBy { it.work to it.path }

        val uploads = mutableListOf<FileItem>()
        val conflicts = mutableListOf<FileItem>()
        val rejected = mutableListOf<FileItem>()
        val downloads = mutableListOf<FileItem>()
        for ((key, item) in local) {
            val r = remote[key]
            when {
                r == null -> if (SyncNames.valid(item)) uploads += item else rejected += item
                r.size != item.size -> conflicts += item
            }
        }
        for ((key, item) in remote) {
            if (item.work !in works || key in local) continue
            if (SyncNames.valid(item)) downloads += item else rejected += item
        }

        val uploaded = mutableListOf<FileItem>()
        val downloaded = mutableListOf<FileItem>()
        val failed = mutableListOf<Pair<FileItem, String>>()
        for (item in uploads) {
            try {
                val segments = item.path.split('/')
                ensure(filesDir + item.work + segments.dropLast(1))
                dav.put(filesDir + item.work + segments, HttpBody("application/octet-stream", item.size) { out ->
                    access.open(item.work, item.path).use { it.copyTo(out) }
                })
                val done = item.copy(t = clock())
                baseline = baseline.copy(uploadedFiles = baseline.uploadedFiles + done)
                adapter.saveBaseline(baseline)
                uploaded += done
            } catch (e: SyncException) {
                if (e.kind == SyncException.Kind.Auth) throw e
                failed += item to (e.message ?: e.kind.name)
            } catch (e: IOException) {
                failed += item to (e.message ?: "read error")
            }
        }
        if (uploaded.isNotEmpty()) {
            val file = FilesFile(SYNC_FORMAT, device.id, clock(), baseline.uploadedFiles)
            dav.putJson(ownDir + "files.json", SyncJson.encodeToString(file))
        }
        for (item in downloads) {
            try {
                val found = dav.download(filesDir + item.work + item.path.split('/')) { input ->
                    access.save(item.work, item.path, SizeCheckedInputStream(input, item.size))
                }
                if (found) downloaded += item else failed += item to "not on the server"
            } catch (e: SyncException) {
                if (e.kind == SyncException.Kind.Auth) throw e
                failed += item to (e.message ?: e.kind.name)
            } catch (e: IOException) {
                failed += item to (e.message ?: "write error")
            }
        }
        return FilesResult(uploaded, downloaded, conflicts, rejected, failed)
    }

    /** Fails a download that is longer or shorter than the size its list gives. */
    private class SizeCheckedInputStream(input: InputStream, private val expected: Long) : FilterInputStream(input) {
        private var count = 0L

        private fun counted(n: Int): Int {
            if (n < 0) {
                if (count != expected) throw IOException("size $count, expected $expected")
                return n
            }
            count += n
            if (count > expected) throw IOException("longer than $expected bytes")
            return n
        }

        override fun read(): Int {
            val b = super.read()
            counted(if (b < 0) -1 else 1)
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int = counted(super.read(b, off, len))
    }

    // endregion

}
