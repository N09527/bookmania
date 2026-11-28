import Foundation

/// The WebDAV sync, format 1 (docs/extensions-and-sync/sync-format.md): the same files and merge as Android's
/// core/sync (Kotlin). Both test suites read the fixtures under core/sync/src/test/resources/fixtures/sync.
public enum Sync {
    public static let format = 1
}

extension KeyedDecodingContainer {
    /// The value of `key`, or `fallback` when it is missing or null (missing fields take their defaults).
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

// MARK: - A setting's value

extension Sync {
    /// A JSON scalar, as Android's preferences are typed in the files ("string", "int", "bool").
    public enum Value: Codable, Equatable, Hashable, Sendable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let i = try? c.decode(Int64.self) { self = .int(i); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            self = .string(try c.decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .string(s): try c.encode(s)
            case let .int(i): try c.encode(i)
            case let .double(d): try c.encode(d)
            case let .bool(b): try c.encode(b)
            }
        }

        /// The text a preference store keeps (UserDefaults strings).
        public var text: String {
            switch self {
            case let .string(s): return s
            case let .int(i): return String(i)
            case let .double(d): return String(d)
            case let .bool(b): return b ? "true" : "false"
            }
        }
    }
}

// MARK: - Registers: what was changed, when (t, milliseconds) and by which device (d)

extension Sync {
    public struct WorkEntry: Codable, Equatable, Sendable {
        public var favorite = false
        public var added: Int64 = 0
        /// Category names (ids differ between devices), sorted.
        public var categories: [String] = []
        public var chapterFlags = 0
        public var viewerFlags: Int?
        public var t: Int64 = 0
        public var d = ""

        public init(favorite: Bool = false, added: Int64 = 0, categories: [String] = [], chapterFlags: Int = 0, viewerFlags: Int? = nil, t: Int64 = 0, d: String = "") {
            self.favorite = favorite
            self.added = added
            self.categories = categories
            self.chapterFlags = chapterFlags
            self.viewerFlags = viewerFlags
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case favorite, added, categories, chapterFlags, viewerFlags, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorite = try c.value(.favorite, false)
            added = try c.value(.added, 0)
            categories = try c.value(.categories, [])
            chapterFlags = try c.value(.chapterFlags, 0)
            viewerFlags = try c.decodeIfPresent(Int.self, forKey: .viewerFlags)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }

        public var value: WorkValue { WorkValue(favorite: favorite, added: added, categories: categories.sorted(), chapterFlags: chapterFlags, viewerFlags: viewerFlags) }
    }

    public struct CategoryEntry: Codable, Equatable, Sendable {
        public var order = 0
        public var flags = 0
        public var deleted = false
        public var t: Int64 = 0
        public var d = ""

        public init(order: Int = 0, flags: Int = 0, deleted: Bool = false, t: Int64 = 0, d: String = "") {
            self.order = order
            self.flags = flags
            self.deleted = deleted
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case order, flags, deleted, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try c.value(.order, 0)
            flags = try c.value(.flags, 0)
            deleted = try c.value(.deleted, false)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }

        public var value: CategoryValue { CategoryValue(order: order, flags: flags) }
    }

    public struct SettingEntry: Codable, Equatable, Sendable {
        /// "string", "int" or "bool".
        public var type = "string"
        /// nil when the setting was cleared.
        public var value: Value?
        public var t: Int64 = 0
        public var d = ""

        public init(type: String = "string", value: Value? = nil, t: Int64 = 0, d: String = "") {
            self.type = type
            self.value = value
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case type, value, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.value(.type, "string")
            value = try c.decodeIfPresent(Value.self, forKey: .value)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }

        public var setting: SettingValue { SettingValue(type: type, value: value) }
    }

    public struct ProgressPart: Codable, Equatable, Sendable {
        public var read = false
        /// The last page read, from 0.
        public var page = 0
        /// Pages left.
        public var left = 0
        public var t: Int64 = 0
        public var d = ""

        public init(read: Bool = false, page: Int = 0, left: Int = 0, t: Int64 = 0, d: String = "") {
            self.read = read
            self.page = page
            self.left = left
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case read, page, left, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            read = try c.value(.read, false)
            page = try c.value(.page, 0)
            left = try c.value(.left, 0)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }

        public var value: ProgressChange { ProgressChange(read: read, page: page, left: left) }
    }

    public struct BookmarkPart: Codable, Equatable, Sendable {
        public var value = false
        public var t: Int64 = 0
        public var d = ""

        public init(value: Bool = false, t: Int64 = 0, d: String = "") {
            self.value = value
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case value, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.value(.value, false)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }
    }

    public struct PositionPart: Codable, Equatable, Sendable {
        /// A text book's position, the JSON of backups' field 20101; nil when it was cleared.
        public var locator: String?
        public var t: Int64 = 0
        public var d = ""

        public init(locator: String? = nil, t: Int64 = 0, d: String = "") {
            self.locator = locator
            self.t = t
            self.d = d
        }

        enum CodingKeys: String, CodingKey { case locator, t, d }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            locator = try c.decodeIfPresent(String.self, forKey: .locator)
            t = try c.value(.t, 0)
            d = try c.value(.d, "")
        }
    }

    /// Merged by the larger value of each field; it has no t and d.
    public struct HistoryPart: Codable, Equatable, Sendable {
        public var lastRead: Int64 = 0
        public var duration: Int64 = 0

        public init(lastRead: Int64 = 0, duration: Int64 = 0) {
            self.lastRead = lastRead
            self.duration = duration
        }

        enum CodingKeys: String, CodingKey { case lastRead, duration }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastRead = try c.value(.lastRead, 0)
            duration = try c.value(.duration, 0)
        }
    }

    public struct ChapterEntry: Codable, Equatable, Sendable {
        public var progress: ProgressPart?
        public var bookmark: BookmarkPart?
        public var position: PositionPart?
        public var history: HistoryPart?

        public init(progress: ProgressPart? = nil, bookmark: BookmarkPart? = nil, position: PositionPart? = nil, history: HistoryPart? = nil) {
            self.progress = progress
            self.bookmark = bookmark
            self.position = position
            self.history = history
        }

        public var isEmpty: Bool { progress == nil && bookmark == nil && position == nil && history == nil }
    }
}

// MARK: - Files on the server

extension Sync {
    public struct DeviceFile: Codable, Equatable, Sendable {
        public var format = Sync.format
        public var device = ""
        public var name = ""
        /// "android" or "ios".
        public var platform = ""
        public var app = ""
        public var written: Int64 = 0

        public init(format: Int = Sync.format, device: String = "", name: String = "", platform: String = "", app: String = "", written: Int64 = 0) {
            self.format = format
            self.device = device
            self.name = name
            self.platform = platform
            self.app = app
            self.written = written
        }

        enum CodingKeys: String, CodingKey { case format, device, name, platform, app, written }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.value(.format, Sync.format)
            device = try c.value(.device, "")
            name = try c.value(.name, "")
            platform = try c.value(.platform, "")
            app = try c.value(.app, "")
            written = try c.value(.written, 0)
        }
    }

    public struct LibraryFile: Codable, Equatable, Sendable {
        public var format = Sync.format
        public var device = ""
        public var written: Int64 = 0
        public var works: [String: WorkEntry] = [:]
        public var categories: [String: CategoryEntry] = [:]
        public var settings: [String: SettingEntry] = [:]
        /// Work key → the `written` of this device's progress file of the work.
        public var progress: [String: Int64] = [:]

        public init(format: Int = Sync.format, device: String = "", written: Int64 = 0, works: [String: WorkEntry] = [:], categories: [String: CategoryEntry] = [:], settings: [String: SettingEntry] = [:], progress: [String: Int64] = [:]) {
            self.format = format
            self.device = device
            self.written = written
            self.works = works
            self.categories = categories
            self.settings = settings
            self.progress = progress
        }

        enum CodingKeys: String, CodingKey { case format, device, written, works, categories, settings, progress }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.value(.format, Sync.format)
            device = try c.value(.device, "")
            written = try c.value(.written, 0)
            works = try c.value(.works, [:])
            categories = try c.value(.categories, [:])
            settings = try c.value(.settings, [:])
            progress = try c.value(.progress, [:])
        }

        public var state: LibraryState { LibraryState(works: works, categories: categories, settings: settings) }
    }

    public struct ProgressFile: Codable, Equatable, Sendable {
        public var format = Sync.format
        public var device = ""
        public var written: Int64 = 0
        public var work = ""
        public var chapters: [String: ChapterEntry] = [:]

        public init(format: Int = Sync.format, device: String = "", written: Int64 = 0, work: String = "", chapters: [String: ChapterEntry] = [:]) {
            self.format = format
            self.device = device
            self.written = written
            self.work = work
            self.chapters = chapters
        }

        enum CodingKeys: String, CodingKey { case format, device, written, work, chapters }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.value(.format, Sync.format)
            device = try c.value(.device, "")
            written = try c.value(.written, 0)
            work = try c.value(.work, "")
            chapters = try c.value(.chapters, [:])
        }

        public var state: ProgressState { ProgressState(chapters: chapters) }
    }

    public struct FileItem: Codable, Equatable, Hashable, Sendable {
        /// The local source's work folder.
        public var work: String
        /// Inside the work folder, '/'-separated, at most two segments.
        public var path: String
        public var size: Int64
        public var t: Int64 = 0

        public init(work: String, path: String, size: Int64, t: Int64 = 0) {
            self.work = work
            self.path = path
            self.size = size
            self.t = t
        }

        enum CodingKeys: String, CodingKey { case work, path, size, t }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            work = try c.decode(String.self, forKey: .work)
            path = try c.decode(String.self, forKey: .path)
            size = try c.decode(Int64.self, forKey: .size)
            t = try c.value(.t, 0)
        }
    }

    public struct FilesFile: Codable, Equatable, Sendable {
        public var format = Sync.format
        public var device = ""
        public var written: Int64 = 0
        public var files: [FileItem] = []

        public init(format: Int = Sync.format, device: String = "", written: Int64 = 0, files: [FileItem] = []) {
            self.format = format
            self.device = device
            self.written = written
            self.files = files
        }

        enum CodingKeys: String, CodingKey { case format, device, written, files }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.value(.format, Sync.format)
            device = try c.value(.device, "")
            written = try c.value(.written, 0)
            files = try c.value(.files, [])
        }
    }
}

// MARK: - Merged states

extension Sync {
    public struct LibraryState: Codable, Equatable, Sendable {
        public var works: [String: WorkEntry] = [:]
        public var categories: [String: CategoryEntry] = [:]
        public var settings: [String: SettingEntry] = [:]

        public init(works: [String: WorkEntry] = [:], categories: [String: CategoryEntry] = [:], settings: [String: SettingEntry] = [:]) {
            self.works = works
            self.categories = categories
            self.settings = settings
        }

        enum CodingKeys: String, CodingKey { case works, categories, settings }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            works = try c.value(.works, [:])
            categories = try c.value(.categories, [:])
            settings = try c.value(.settings, [:])
        }
    }

    public struct ProgressState: Codable, Equatable, Sendable {
        public var chapters: [String: ChapterEntry] = [:]

        public init(chapters: [String: ChapterEntry] = [:]) { self.chapters = chapters }

        enum CodingKeys: String, CodingKey { case chapters }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapters = try c.value(.chapters, [:])
        }
    }
}

// MARK: - What a device has (no times): its snapshot, and the changes it is asked to make

extension Sync {
    public struct WorkValue: Codable, Equatable, Sendable {
        public var favorite = false
        public var added: Int64 = 0
        public var categories: [String] = []
        public var chapterFlags = 0
        public var viewerFlags: Int?

        public init(favorite: Bool = false, added: Int64 = 0, categories: [String] = [], chapterFlags: Int = 0, viewerFlags: Int? = nil) {
            self.favorite = favorite
            self.added = added
            self.categories = categories
            self.chapterFlags = chapterFlags
            self.viewerFlags = viewerFlags
        }

        enum CodingKeys: String, CodingKey { case favorite, added, categories, chapterFlags, viewerFlags }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorite = try c.value(.favorite, false)
            added = try c.value(.added, 0)
            categories = try c.value(.categories, [])
            chapterFlags = try c.value(.chapterFlags, 0)
            viewerFlags = try c.decodeIfPresent(Int.self, forKey: .viewerFlags)
        }

        public var isDefault: Bool { !favorite && categories.isEmpty }
        public func normalized() -> WorkValue {
            var v = self
            v.categories.sort()
            return v
        }
    }

    public struct CategoryValue: Codable, Equatable, Sendable {
        public var order = 0
        public var flags = 0

        public init(order: Int = 0, flags: Int = 0) {
            self.order = order
            self.flags = flags
        }

        enum CodingKeys: String, CodingKey { case order, flags }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try c.value(.order, 0)
            flags = try c.value(.flags, 0)
        }
    }

    public struct SettingValue: Codable, Equatable, Sendable {
        public var type = "string"
        public var value: Value?

        public init(type: String = "string", value: Value? = nil) {
            self.type = type
            self.value = value
        }

        enum CodingKeys: String, CodingKey { case type, value }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.value(.type, "string")
            value = try c.decodeIfPresent(Value.self, forKey: .value)
        }
    }

    /// A chapter as a device has it.
    public struct ChapterValue: Codable, Equatable, Sendable {
        public var read = false
        public var page = 0
        public var left = 0
        public var bookmark = false
        public var locator: String?
        public var lastRead: Int64 = 0
        public var duration: Int64 = 0

        public init(read: Bool = false, page: Int = 0, left: Int = 0, bookmark: Bool = false, locator: String? = nil, lastRead: Int64 = 0, duration: Int64 = 0) {
            self.read = read
            self.page = page
            self.left = left
            self.bookmark = bookmark
            self.locator = locator
            self.lastRead = lastRead
            self.duration = duration
        }

        enum CodingKeys: String, CodingKey { case read, page, left, bookmark, locator, lastRead, duration }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            read = try c.value(.read, false)
            page = try c.value(.page, 0)
            left = try c.value(.left, 0)
            bookmark = try c.value(.bookmark, false)
            locator = try c.decodeIfPresent(String.self, forKey: .locator)
            lastRead = try c.value(.lastRead, 0)
            duration = try c.value(.duration, 0)
        }

        public var progress: ProgressChange { ProgressChange(read: read, page: page, left: left) }
    }

    public struct LibrarySnapshot: Codable, Equatable, Sendable {
        public var works: [String: WorkValue] = [:]
        public var categories: [String: CategoryValue] = [:]
        public var settings: [String: SettingValue] = [:]

        public init(works: [String: WorkValue] = [:], categories: [String: CategoryValue] = [:], settings: [String: SettingValue] = [:]) {
            self.works = works
            self.categories = categories
            self.settings = settings
        }

        enum CodingKeys: String, CodingKey { case works, categories, settings }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            works = try c.value(.works, [:])
            categories = try c.value(.categories, [:])
            settings = try c.value(.settings, [:])
        }
    }

    public struct ProgressSnapshot: Codable, Equatable, Sendable {
        public var chapters: [String: ChapterValue] = [:]

        public init(chapters: [String: ChapterValue] = [:]) { self.chapters = chapters }

        enum CodingKeys: String, CodingKey { case chapters }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapters = try c.value(.chapters, [:])
        }
    }

    public struct LibraryChanges: Codable, Equatable, Sendable {
        /// Works to set (a work the device does not have may be created, or left out).
        public var works: [String: WorkValue] = [:]
        public var categories: [String: CategoryValue] = [:]
        public var deletedCategories: [String] = []
        /// Settings to set; a nil value removes the setting.
        public var settings: [String: SettingValue] = [:]

        public init(works: [String: WorkValue] = [:], categories: [String: CategoryValue] = [:], deletedCategories: [String] = [], settings: [String: SettingValue] = [:]) {
            self.works = works
            self.categories = categories
            self.deletedCategories = deletedCategories
            self.settings = settings
        }

        enum CodingKeys: String, CodingKey { case works, categories, deletedCategories, settings }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            works = try c.value(.works, [:])
            categories = try c.value(.categories, [:])
            deletedCategories = try c.value(.deletedCategories, [])
            settings = try c.value(.settings, [:])
        }

        public var isEmpty: Bool { works.isEmpty && categories.isEmpty && deletedCategories.isEmpty && settings.isEmpty }
    }

    public struct ProgressChange: Codable, Equatable, Sendable {
        public var read = false
        public var page = 0
        public var left = 0

        public init(read: Bool = false, page: Int = 0, left: Int = 0) {
            self.read = read
            self.page = page
            self.left = left
        }

        enum CodingKeys: String, CodingKey { case read, page, left }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            read = try c.value(.read, false)
            page = try c.value(.page, 0)
            left = try c.value(.left, 0)
        }

        public var isDefault: Bool { !read && page == 0 }
    }

    public struct PositionChange: Codable, Equatable, Sendable {
        public var locator: String?

        public init(locator: String? = nil) { self.locator = locator }
    }

    /// What changes in one chapter; a nil part does not change.
    public struct ChapterChange: Codable, Equatable, Sendable {
        public var progress: ProgressChange?
        public var bookmark: Bool?
        public var position: PositionChange?
        public var history: HistoryPart?

        public init(progress: ProgressChange? = nil, bookmark: Bool? = nil, position: PositionChange? = nil, history: HistoryPart? = nil) {
            self.progress = progress
            self.bookmark = bookmark
            self.position = position
            self.history = history
        }
    }

    public struct ProgressChanges: Codable, Equatable, Sendable {
        public var chapters: [String: ChapterChange] = [:]

        public init(chapters: [String: ChapterChange] = [:]) { self.chapters = chapters }

        enum CodingKeys: String, CodingKey { case chapters }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapters = try c.value(.chapters, [:])
        }

        public var isEmpty: Bool { chapters.isEmpty }
    }
}

// MARK: - What a device keeps between syncs

extension Sync {
    /// The library side of the last sync (see the Kotlin SyncBaseline): its merged result, the entries written to this
    /// device's data then ("w:<work key>", "c:<category>", "s:<setting key>"), the other devices' progress files
    /// already merged, this device's own progress files, the uploaded files and the works whose progress is pending.
    public struct Baseline: Codable, Equatable, Sendable {
        public var library = LibraryState()
        public var applied: Set<String> = []
        /// Device id → work key → `written` of that device's progress file when it was last merged.
        public var seen: [String: [String: Int64]] = [:]
        /// Work key → `written` of this device's progress file of the work.
        public var ownProgress: [String: Int64] = [:]
        public var uploadedLibrary: String?
        public var uploadedDevice: String?
        public var uploadedFiles: [FileItem] = []
        public var pending: Set<String> = []

        public init() {}

        enum CodingKeys: String, CodingKey { case library, applied, seen, ownProgress, uploadedLibrary, uploadedDevice, uploadedFiles, pending }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            library = try c.value(.library, LibraryState())
            applied = try c.value(.applied, [])
            seen = try c.value(.seen, [:])
            ownProgress = try c.value(.ownProgress, [:])
            uploadedLibrary = try c.decodeIfPresent(String.self, forKey: .uploadedLibrary)
            uploadedDevice = try c.decodeIfPresent(String.self, forKey: .uploadedDevice)
            uploadedFiles = try c.value(.uploadedFiles, [])
            pending = try c.value(.pending, [])
        }
    }

    /// One work's side of the last sync ("<chapter key>|progress", "|bookmark", "|position" in `applied`).
    public struct WorkBaseline: Codable, Equatable, Sendable {
        public var chapters: [String: ChapterEntry] = [:]
        public var applied: Set<String> = []
        public var uploaded: String?

        public init(chapters: [String: ChapterEntry] = [:], applied: Set<String> = [], uploaded: String? = nil) {
            self.chapters = chapters
            self.applied = applied
            self.uploaded = uploaded
        }

        enum CodingKeys: String, CodingKey { case chapters, applied, uploaded }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapters = try c.value(.chapters, [:])
            applied = try c.value(.applied, [])
            uploaded = try c.decodeIfPresent(String.self, forKey: .uploaded)
        }
    }

    /// JSON as the files are written: keys sorted (so equal content gives equal text), slashes not escaped.
    public static func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(value)) ?? Data(), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
