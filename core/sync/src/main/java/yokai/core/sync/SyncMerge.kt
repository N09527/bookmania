package yokai.core.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * The merge of sync-format.md: every register takes the newest of its versions (the larger t, then the larger d),
 * the history takes the largest of each field. [annotate] turns a device's snapshot into registers, using the
 * baseline of the last sync to tell what this device changed since; [changes] lists what the device has to write
 * to take the merged result.
 */
object SyncMerge {

    fun newer(t1: Long, d1: String, t2: Long, d2: String) = t1 > t2 || (t1 == t2 && d1 > d2)

    private fun WorkEntry.newerThan(o: WorkEntry) = newer(t, d, o.t, o.d)
    private fun CategoryEntry.newerThan(o: CategoryEntry) = newer(t, d, o.t, o.d)
    private fun SettingEntry.newerThan(o: SettingEntry) = newer(t, d, o.t, o.d)
    private fun ProgressPart.newerThan(o: ProgressPart) = newer(t, d, o.t, o.d)
    private fun BookmarkPart.newerThan(o: BookmarkPart) = newer(t, d, o.t, o.d)
    private fun PositionPart.newerThan(o: PositionPart) = newer(t, d, o.t, o.d)

    private fun pick(a: WorkEntry?, b: WorkEntry?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b
    private fun pick(a: CategoryEntry?, b: CategoryEntry?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b
    private fun pick(a: SettingEntry?, b: SettingEntry?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b
    private fun pick(a: ProgressPart?, b: ProgressPart?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b
    private fun pick(a: BookmarkPart?, b: BookmarkPart?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b
    private fun pick(a: PositionPart?, b: PositionPart?) = if (a == null) b else if (b == null || a.newerThan(b) || a == b) a else b

    private fun maxHistory(a: HistoryPart?, b: HistoryPart?): HistoryPart? {
        val h = HistoryPart(maxOf(a?.lastRead ?: 0, b?.lastRead ?: 0), maxOf(a?.duration ?: 0, b?.duration ?: 0))
        return if (h.lastRead == 0L && h.duration == 0L) null else h
    }

    private fun WorkValue.entry(t: Long, d: String) = WorkEntry(favorite, added, categories.sorted(), chapterFlags, viewerFlags, t, d)
    private fun CategoryValue.entry(t: Long, d: String) = CategoryEntry(order, flags, false, t, d)
    private fun SettingValue.entry(t: Long, d: String) = SettingEntry(type, value, t, d)
    private val ProgressPart.value get() = ProgressChange(read, page, left)
    private val ChapterValue.progress get() = ProgressChange(read, page, left)
    private val ProgressChange.isDefault get() = !read && page == 0

    /** The `updatedAt` a position records, or 0. */
    fun locatorTime(locator: String?): Long {
        if (locator == null) return 0
        return runCatching { Json.parseToJsonElement(locator).jsonObject["updatedAt"]?.jsonPrimitive?.longOrNull }
            .getOrNull() ?: 0
    }

    // region Library

    /** This device's library as registers (sync-format.md section 4). */
    fun annotate(snapshot: LibrarySnapshot, baseline: SyncBaseline, now: Long, device: String): LibraryState {
        val applied = baseline.applied
        val works = baseline.library.works.toMutableMap()
        for ((key, raw) in snapshot.works) {
            val local = raw.normalized()
            val base = works[key]
            if ("w:$key" in applied) {
                if (base == null || base.value != local) {
                    // Added again since the last sync: that time; otherwise the change is only known now.
                    val t = if (local.favorite && local.added > (base?.t ?: 0)) local.added else now
                    works[key] = local.entry(t, device)
                }
            } else if (!local.isDefault) {
                works[key] = pick(local.entry(if (local.favorite) local.added else 0, device), base)!!
            }
        }
        val categories = baseline.library.categories.toMutableMap()
        for ((name, local) in snapshot.categories) {
            val base = categories[name]
            if ("c:$name" in applied) {
                if (base == null || base.deleted || base.value != local) categories[name] = local.entry(now, device)
            } else {
                categories[name] = pick(local.entry(0, device), base)!!
            }
        }
        val settings = baseline.library.settings.toMutableMap()
        for ((key, local) in snapshot.settings) {
            val base = settings[key]
            if ("s:$key" in applied) {
                if (base == null || base.setting != local) settings[key] = local.entry(now, device)
            } else {
                settings[key] = pick(local.entry(0, device), base)!!
            }
        }
        for (id in applied) {
            if (id.startsWith("c:")) {
                val name = id.substring(2)
                val base = categories[name]
                if (name !in snapshot.categories && base != null && !base.deleted) {
                    categories[name] = CategoryEntry(deleted = true, t = now, d = device)
                }
            } else if (id.startsWith("s:")) {
                val key = id.substring(2)
                val base = settings[key]
                if (key !in snapshot.settings && base != null && base.value != null) {
                    settings[key] = SettingEntry(base.type, null, now, device)
                }
            }
        }
        return LibraryState(works.toSortedMap(), categories.toSortedMap(), settings.toSortedMap())
    }

    /**
     * Merges this device's registers ([local], from [annotate]) with the other devices'. An entry that only this
     * device has, from its first sync (t = 0), becomes a change made [now]: the first device's data then win against
     * a device that joins later, as sync-format.md section 4 says, instead of the device ids deciding.
     */
    fun merge(local: LibraryState, remotes: List<LibraryState>, now: Long, device: String): LibraryState {
        val m = merge(listOf(local) + remotes)
        return LibraryState(
            m.works.mapValues { (k, e) -> if (e.t == 0L && e.d == device && remotes.none { k in it.works }) e.copy(t = now) else e }.toSortedMap(),
            m.categories.mapValues { (k, e) -> if (e.t == 0L && e.d == device && remotes.none { k in it.categories }) e.copy(t = now) else e }.toSortedMap(),
            m.settings.mapValues { (k, e) -> if (e.t == 0L && e.d == device && remotes.none { k in it.settings }) e.copy(t = now) else e }.toSortedMap(),
        )
    }

    internal fun merge(states: List<LibraryState>): LibraryState {
        val works = sortedMapOf<String, WorkEntry>()
        val categories = sortedMapOf<String, CategoryEntry>()
        val settings = sortedMapOf<String, SettingEntry>()
        for (s in states) {
            for ((k, v) in s.works) works[k] = pick(works[k], v)!!
            for ((k, v) in s.categories) categories[k] = pick(categories[k], v)!!
            for ((k, v) in s.settings) settings[k] = pick(settings[k], v)!!
        }
        return LibraryState(works, categories, settings)
    }

    /** What the device has to write to take [merged], and the entries it already has ("w:", "c:", "s:" ids). */
    fun changes(merged: LibraryState, snapshot: LibrarySnapshot): Pair<LibraryChanges, Set<String>> {
        val equal = mutableSetOf<String>()
        val works = sortedMapOf<String, WorkValue>()
        for ((key, e) in merged.works) {
            val local = snapshot.works[key]?.normalized()
            when {
                local == e.value -> equal += "w:$key"
                local == null && e.value.isDefault -> Unit
                else -> works[key] = e.value
            }
        }
        val categories = sortedMapOf<String, CategoryValue>()
        val deleted = mutableListOf<String>()
        for ((name, e) in merged.categories) {
            val local = snapshot.categories[name]
            when {
                e.deleted -> if (local != null) deleted += name
                local == e.value -> equal += "c:$name"
                else -> categories[name] = e.value
            }
        }
        val settings = sortedMapOf<String, SettingValue>()
        for ((key, e) in merged.settings) {
            val local = snapshot.settings[key]
            when {
                local == e.setting -> equal += "s:$key"
                e.value == null && local == null -> Unit
                else -> settings[key] = e.setting
            }
        }
        return LibraryChanges(works, categories, deleted.sorted(), settings) to equal
    }

    // endregion

    // region Progress of one work

    /** This device's chapters of a work as registers (sync-format.md section 4). */
    fun annotate(snapshot: ProgressSnapshot, baseline: WorkBaseline, now: Long, device: String): ProgressState {
        val applied = baseline.applied
        val chapters = baseline.chapters.toMutableMap()
        for ((key, local) in snapshot.chapters) {
            val base = chapters[key] ?: ChapterEntry()
            var progress = base.progress
            val lp = local.progress
            if ("$key|progress" in applied) {
                if (progress == null || progress.value != lp) {
                    val t = if (local.lastRead > (progress?.t ?: 0)) local.lastRead else now
                    progress = ProgressPart(lp.read, lp.page, lp.left, t, device)
                }
            } else if (!lp.isDefault) {
                progress = pick(ProgressPart(lp.read, lp.page, lp.left, local.lastRead, device), progress)
            }
            var bookmark = base.bookmark
            if ("$key|bookmark" in applied) {
                if (bookmark == null || bookmark.value != local.bookmark) bookmark = BookmarkPart(local.bookmark, now, device)
            } else if (local.bookmark) {
                bookmark = pick(BookmarkPart(true, 0, device), bookmark)
            }
            var position = base.position
            if ("$key|position" in applied) {
                if (position == null || position.locator != local.locator) {
                    val recorded = locatorTime(local.locator)
                    position = PositionPart(local.locator, if (recorded > (position?.t ?: 0)) recorded else now, device)
                }
            } else if (local.locator != null) {
                position = pick(PositionPart(local.locator, locatorTime(local.locator), device), position)
            }
            val history = maxHistory(base.history, HistoryPart(local.lastRead, local.duration))
            val entry = ChapterEntry(progress, bookmark, position, history)
            if (entry != ChapterEntry()) chapters[key] = entry
        }
        return ProgressState(chapters.toSortedMap())
    }

    /** Merges this device's chapters with the other devices'; first-sync parts only this device has become changes made [now]. */
    fun mergeProgress(local: ProgressState, remotes: List<ProgressState>, now: Long, device: String): ProgressState {
        val m = mergeProgress(listOf(local) + remotes)
        fun alone(key: String, part: (ChapterEntry) -> Any?) = remotes.none { r -> r.chapters[key]?.let(part) != null }
        return ProgressState(
            m.chapters.mapValues { (k, c) ->
                ChapterEntry(
                    c.progress?.let { if (it.t == 0L && it.d == device && alone(k) { e -> e.progress }) it.copy(t = now) else it },
                    c.bookmark?.let { if (it.t == 0L && it.d == device && alone(k) { e -> e.bookmark }) it.copy(t = now) else it },
                    c.position?.let { if (it.t == 0L && it.d == device && alone(k) { e -> e.position }) it.copy(t = now) else it },
                    c.history,
                )
            }.toSortedMap(),
        )
    }

    internal fun mergeProgress(states: List<ProgressState>): ProgressState {
        val chapters = sortedMapOf<String, ChapterEntry>()
        for (s in states) {
            for ((k, v) in s.chapters) {
                val c = chapters[k]
                chapters[k] = if (c == null) {
                    v
                } else {
                    ChapterEntry(
                        pick(c.progress, v.progress),
                        pick(c.bookmark, v.bookmark),
                        pick(c.position, v.position),
                        maxHistory(c.history, v.history),
                    )
                }
            }
        }
        return ProgressState(chapters)
    }

    /** What the device has to write to take [merged], and the parts it already has ("<key>|progress" and so on). */
    fun changes(merged: ProgressState, snapshot: ProgressSnapshot): Pair<ProgressChanges, Set<String>> {
        val equal = mutableSetOf<String>()
        val changes = sortedMapOf<String, ChapterChange>()
        for ((key, e) in merged.chapters) {
            val local = snapshot.chapters[key]
            var progress: ProgressChange? = null
            var bookmark: Boolean? = null
            var position: PositionChange? = null
            var history: HistoryPart? = null
            e.progress?.let { p ->
                when {
                    local?.progress == p.value -> equal += "$key|progress"
                    local == null && p.value.isDefault -> Unit
                    else -> progress = p.value
                }
            }
            e.bookmark?.let { b ->
                when {
                    local?.bookmark == b.value -> equal += "$key|bookmark"
                    local == null && !b.value -> Unit
                    else -> bookmark = b.value
                }
            }
            e.position?.let { p ->
                when {
                    local?.locator == p.locator -> equal += "$key|position"
                    local == null && p.locator == null -> Unit
                    else -> position = PositionChange(p.locator)
                }
            }
            e.history?.let { h ->
                val lastRead = maxOf(h.lastRead, local?.lastRead ?: 0)
                val duration = maxOf(h.duration, local?.duration ?: 0)
                if (lastRead != (local?.lastRead ?: 0) || duration != (local?.duration ?: 0)) {
                    history = HistoryPart(lastRead, duration)
                }
            }
            if (progress != null || bookmark != null || position != null || history != null) {
                changes[key] = ChapterChange(progress, bookmark, position, history)
            }
        }
        return ProgressChanges(changes) to equal
    }

    // endregion
}
