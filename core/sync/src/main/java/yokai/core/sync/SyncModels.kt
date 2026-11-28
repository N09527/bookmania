package yokai.core.sync

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/**
 * The files of the WebDAV sync, format 1 (docs/extensions-and-sync/sync-format.md). The iOS version reads and writes
 * the same JSON (ios/BookmaniaCore/Sources/BookmaniaCore/Sync); both test suites read the files under
 * core/sync/src/test/resources/fixtures/sync.
 */
const val SYNC_FORMAT = 1

/** Unknown fields are ignored, missing fields take their defaults and null fields are left out. */
val SyncJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

// region Registers: what was changed, when (t, milliseconds) and by which device (d)

@Serializable
data class WorkEntry(
    val favorite: Boolean = false,
    val added: Long = 0,
    /** Category names (ids differ between devices), sorted. */
    val categories: List<String> = emptyList(),
    val chapterFlags: Int = 0,
    val viewerFlags: Int? = null,
    val t: Long = 0,
    val d: String = "",
) {
    val value get() = WorkValue(favorite, added, categories.sorted(), chapterFlags, viewerFlags)
}

@Serializable
data class CategoryEntry(
    val order: Int = 0,
    val flags: Int = 0,
    val deleted: Boolean = false,
    val t: Long = 0,
    val d: String = "",
) {
    val value get() = CategoryValue(order, flags)
}

@Serializable
data class SettingEntry(
    /** "string", "int" or "bool". */
    val type: String = "string",
    /** The value; null when the setting was cleared. */
    val value: JsonElement? = null,
    val t: Long = 0,
    val d: String = "",
) {
    val setting get() = SettingValue(type, value)
}

@Serializable
data class ProgressPart(
    val read: Boolean = false,
    /** The last page read, from 0. */
    val page: Int = 0,
    /** Pages left. */
    val left: Int = 0,
    val t: Long = 0,
    val d: String = "",
)

@Serializable
data class BookmarkPart(val value: Boolean = false, val t: Long = 0, val d: String = "")

@Serializable
data class PositionPart(
    /** A text book's position, the JSON of backups' field 20101; null when it was cleared. */
    val locator: String? = null,
    val t: Long = 0,
    val d: String = "",
)

/** Merged by the larger value of each field; it has no t and d. */
@Serializable
data class HistoryPart(val lastRead: Long = 0, val duration: Long = 0)

@Serializable
data class ChapterEntry(
    val progress: ProgressPart? = null,
    val bookmark: BookmarkPart? = null,
    val position: PositionPart? = null,
    val history: HistoryPart? = null,
)

// endregion

// region Files on the server

@Serializable
data class DeviceFile(
    val format: Int = SYNC_FORMAT,
    val device: String = "",
    val name: String = "",
    /** "android" or "ios". */
    val platform: String = "",
    val app: String = "",
    val written: Long = 0,
)

@Serializable
data class LibraryFile(
    val format: Int = SYNC_FORMAT,
    val device: String = "",
    val written: Long = 0,
    val works: Map<String, WorkEntry> = emptyMap(),
    val categories: Map<String, CategoryEntry> = emptyMap(),
    val settings: Map<String, SettingEntry> = emptyMap(),
    /** Work key → the `written` of this device's progress file of the work. */
    val progress: Map<String, Long> = emptyMap(),
) {
    val state get() = LibraryState(works, categories, settings)
}

@Serializable
data class ProgressFile(
    val format: Int = SYNC_FORMAT,
    val device: String = "",
    val written: Long = 0,
    val work: String = "",
    val chapters: Map<String, ChapterEntry> = emptyMap(),
) {
    val state get() = ProgressState(chapters)
}

@Serializable
data class FileItem(
    /** The local source's work folder. */
    val work: String,
    /** Inside the work folder, '/'-separated, at most two segments. */
    val path: String,
    val size: Long,
    val t: Long = 0,
)

@Serializable
data class FilesFile(
    val format: Int = SYNC_FORMAT,
    val device: String = "",
    val written: Long = 0,
    val files: List<FileItem> = emptyList(),
)

// endregion

// region Merged states

@Serializable
data class LibraryState(
    val works: Map<String, WorkEntry> = emptyMap(),
    val categories: Map<String, CategoryEntry> = emptyMap(),
    val settings: Map<String, SettingEntry> = emptyMap(),
)

@Serializable
data class ProgressState(val chapters: Map<String, ChapterEntry> = emptyMap())

// endregion

// region What a device has (no times): its snapshot, and the changes it is asked to make

@Serializable
data class WorkValue(
    val favorite: Boolean = false,
    val added: Long = 0,
    val categories: List<String> = emptyList(),
    val chapterFlags: Int = 0,
    val viewerFlags: Int? = null,
) {
    val isDefault get() = !favorite && categories.isEmpty()
    fun normalized() = copy(categories = categories.sorted())
}

@Serializable
data class CategoryValue(val order: Int = 0, val flags: Int = 0)

@Serializable
data class SettingValue(val type: String = "string", val value: JsonElement? = null)

/** A chapter as a device has it. */
@Serializable
data class ChapterValue(
    val read: Boolean = false,
    val page: Int = 0,
    val left: Int = 0,
    val bookmark: Boolean = false,
    val locator: String? = null,
    val lastRead: Long = 0,
    val duration: Long = 0,
)

@Serializable
data class LibrarySnapshot(
    val works: Map<String, WorkValue> = emptyMap(),
    val categories: Map<String, CategoryValue> = emptyMap(),
    val settings: Map<String, SettingValue> = emptyMap(),
)

@Serializable
data class ProgressSnapshot(val chapters: Map<String, ChapterValue> = emptyMap())

@Serializable
data class LibraryChanges(
    /** Works to set (a work the device does not have may be created, or left out). */
    val works: Map<String, WorkValue> = emptyMap(),
    val categories: Map<String, CategoryValue> = emptyMap(),
    val deletedCategories: List<String> = emptyList(),
    /** Settings to set; a null value removes the setting. */
    val settings: Map<String, SettingValue> = emptyMap(),
) {
    val isEmpty get() = works.isEmpty() && categories.isEmpty() && deletedCategories.isEmpty() && settings.isEmpty()
}

@Serializable
data class ProgressChange(val read: Boolean = false, val page: Int = 0, val left: Int = 0)

@Serializable
data class PositionChange(val locator: String? = null)

/** What changes in one chapter; a null part does not change. */
@Serializable
data class ChapterChange(
    val progress: ProgressChange? = null,
    val bookmark: Boolean? = null,
    val position: PositionChange? = null,
    val history: HistoryPart? = null,
)

@Serializable
data class ProgressChanges(val chapters: Map<String, ChapterChange> = emptyMap()) {
    val isEmpty get() = chapters.isEmpty()
}

// endregion

// region What a device keeps between syncs

/**
 * The library side of the last sync: its merged result, the entries written to this device's data then ([applied]:
 * "w:<work key>", "c:<category>", "s:<setting key>"), the other devices' progress files already merged ([seen]) and
 * this device's own progress files ([ownProgress]).
 */
@Serializable
data class SyncBaseline(
    val library: LibraryState = LibraryState(),
    val applied: Set<String> = emptySet(),
    /** Device id → work key → `written` of that device's progress file when it was last merged. */
    val seen: Map<String, Map<String, Long>> = emptyMap(),
    /** Work key → `written` of this device's progress file of the work. */
    val ownProgress: Map<String, Long> = emptyMap(),
    /** The content (without `written`) of the library.json last uploaded, to skip uploading the same again. */
    val uploadedLibrary: String? = null,
    /** The content (without `written`) of the device.json last uploaded. */
    val uploadedDevice: String? = null,
    /** The files this device uploaded (its files.json). */
    val uploadedFiles: List<FileItem> = emptyList(),
    /** Works whose progress could not be sent (no connection), sent with the next library sync. */
    val pending: Set<String> = emptySet(),
)

/** One work's side of the last sync ([applied]: "<chapter key>|progress", "|bookmark", "|position"). */
@Serializable
data class WorkBaseline(
    val chapters: Map<String, ChapterEntry> = emptyMap(),
    val applied: Set<String> = emptySet(),
    val uploaded: String? = null,
)

// endregion
