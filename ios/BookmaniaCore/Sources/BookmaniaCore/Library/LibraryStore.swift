import Foundation

/// What the app knows about a chapter (a book file) beyond the file itself: what Android keeps in its database for the
/// chapter (read, bookmark, page numbers, fetch date), its history (last read, time read) and, for text books, the
/// exact position (Android's ebook.db). Keyed by the chapter URL of the local source ("work folder/file name").
public struct ChapterState: Codable, Equatable, Sendable {
    public var read = false
    public var bookmark = false
    /// Page index shown last (image books: the picture; text books: the estimate of ReadingProgress.pages).
    public var lastPageRead = 0
    public var pagesLeft = 0
    /// When the app first saw the file (milliseconds); the updates list orders by it.
    public var dateFetch: Int64 = 0
    /// The exact position in a text book.
    public var position: EbookLocator?
    /// History: when the chapter was last read (milliseconds), and how long it was read in all.
    public var lastRead: Int64?
    public var readDuration: Int64 = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case read, bookmark, lastPageRead, pagesLeft, dateFetch, position, lastRead, readDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        bookmark = try c.decodeIfPresent(Bool.self, forKey: .bookmark) ?? false
        lastPageRead = try c.decodeIfPresent(Int.self, forKey: .lastPageRead) ?? 0
        pagesLeft = try c.decodeIfPresent(Int.self, forKey: .pagesLeft) ?? 0
        dateFetch = try c.decodeIfPresent(Int64.self, forKey: .dateFetch) ?? 0
        position = try? c.decodeIfPresent(EbookLocator.self, forKey: .position)
        lastRead = try c.decodeIfPresent(Int64.self, forKey: .lastRead)
        readDuration = try c.decodeIfPresent(Int64.self, forKey: .readDuration) ?? 0
    }

    /// Nothing worth keeping (a chapter that was never touched).
    var isBlank: Bool { self == ChapterState() }
}

/// What the app knows about a work (a local source folder): Android's manga row for it.
public struct WorkState: Codable, Equatable, Sendable {
    /// In the library.
    public var favorite = false
    /// When it was added to the library (milliseconds).
    public var dateAdded: Int64 = 0
    public var categoryIds: [Int64] = []
    /// The chapter list's sort and filters, with the bits of Android's chapter_flags (ChapterFlags).
    public var chapterFlags = 0
    /// The image reader's reading mode for this work (Android's viewer_flags), nil for the default.
    public var viewerFlags: Int?

    public init() {}

    enum CodingKeys: String, CodingKey { case favorite, dateAdded, categoryIds, chapterFlags, viewerFlags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        dateAdded = try c.decodeIfPresent(Int64.self, forKey: .dateAdded) ?? 0
        categoryIds = try c.decodeIfPresent([Int64].self, forKey: .categoryIds) ?? []
        chapterFlags = try c.decodeIfPresent(Int.self, forKey: .chapterFlags) ?? 0
        viewerFlags = try c.decodeIfPresent(Int.self, forKey: .viewerFlags)
    }

    var isBlank: Bool { self == WorkState() }
}

/// A library category (Android's category: name, order, flags for its sort).
public struct LibraryCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var order: Int
    public var flags: Int

    public init(id: Int64, name: String, order: Int, flags: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
        self.flags = flags
    }
}

/// The chapter list's options in Android's chapter_flags bits (Manga.kt in the domain module).
public enum ChapterFlags {
    public static let sortDescending = 0x0
    public static let sortAscending = 0x1
    public static let sortMask = 0x1
    public static let showUnread = 0x2
    public static let showRead = 0x4
    public static let readMask = 0x6
    public static let showBookmarked = 0x20
    public static let showNotBookmarked = 0x40
    public static let bookmarkedMask = 0x60
    public static let sortingSource = 0x0
    public static let sortingNumber = 0x100
    public static let sortingUploadDate = 0x200
    public static let sortingMask = 0x300
    /// The work uses its own sort / filter instead of the app's defaults.
    public static let sortLocal = 0x1000
    public static let filterLocal = 0x2000
}

/// Everything the library store saves.
public struct LibraryState: Codable, Equatable, Sendable {
    public var works: [String: WorkState] = [:]
    public var chapters: [String: ChapterState] = [:]
    public var categories: [LibraryCategory] = []
    public var nextCategoryId: Int64 = 1
    public var version = 1

    public init() {}

    enum CodingKeys: String, CodingKey { case works, chapters, categories, nextCategoryId, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        works = try c.decodeIfPresent([String: WorkState].self, forKey: .works) ?? [:]
        chapters = try c.decodeIfPresent([String: ChapterState].self, forKey: .chapters) ?? [:]
        categories = try c.decodeIfPresent([LibraryCategory].self, forKey: .categories) ?? []
        nextCategoryId = try c.decodeIfPresent(Int64.self, forKey: .nextCategoryId) ?? 1
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

/// The library's state on disk, as one JSON file written atomically. Reads are served from memory; changes are
/// written shortly after they happen (coalesced), and at once with `flush()`. Safe to use from any thread.
public final class LibraryStore: @unchecked Sendable {
    private let file: URL?
    private let lock = NSLock()
    private var state: LibraryState
    private var dirty = false
    private var scheduled = false
    private let queue = DispatchQueue(label: "bookmania.library.store")
    private let delay: TimeInterval
    /// Called after every change (on the thread that made it).
    public var onChange: (@Sendable () -> Void)?

    /// A store kept in `file` (nil: in memory only, for tests).
    public init(file: URL?, delay: TimeInterval = 0.5) {
        self.file = file
        self.delay = delay
        if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(LibraryState.self, from: data) {
            state = decoded
        } else {
            state = LibraryState()
        }
    }

    /// A copy of the whole state.
    public var snapshot: LibraryState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func chapter(_ id: String) -> ChapterState {
        lock.lock()
        defer { lock.unlock() }
        return state.chapters[id] ?? ChapterState()
    }

    public func work(_ url: String) -> WorkState {
        lock.lock()
        defer { lock.unlock() }
        return state.works[url] ?? WorkState()
    }

    public var categories: [LibraryCategory] {
        lock.lock()
        defer { lock.unlock() }
        return state.categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Changes the state; the change is saved shortly after.
    public func update(_ change: (inout LibraryState) -> Void) {
        lock.lock()
        change(&state)
        // Untouched entries are not kept.
        state.chapters = state.chapters.filter { !$0.value.isBlank }
        state.works = state.works.filter { !$0.value.isBlank }
        dirty = true
        let schedule = !scheduled && file != nil
        if schedule { scheduled = true }
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.write() }
        }
        onChange?()
    }

    public func updateChapter(_ id: String, _ change: (inout ChapterState) -> Void) {
        update { state in
            var c = state.chapters[id] ?? ChapterState()
            change(&c)
            state.chapters[id] = c
        }
    }

    public func updateWork(_ url: String, _ change: (inout WorkState) -> Void) {
        update { state in
            var w = state.works[url] ?? WorkState()
            change(&w)
            state.works[url] = w
        }
    }

    /// Writes pending changes now (when the app goes to the background).
    public func flush() {
        queue.sync { self.write() }
    }

    private func write() {
        lock.lock()
        scheduled = false
        guard dirty, let file else {
            lock.unlock()
            return
        }
        dirty = false
        let copy = state
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(copy) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Categories

    @discardableResult
    public func addCategory(_ name: String) -> LibraryCategory {
        var created = LibraryCategory(id: 0, name: name, order: 0)
        update { state in
            created = LibraryCategory(id: state.nextCategoryId, name: name, order: (state.categories.map(\.order).max() ?? -1) + 1)
            state.nextCategoryId += 1
            state.categories.append(created)
        }
        return created
    }

    public func renameCategory(_ id: Int64, _ name: String) {
        update { state in
            if let i = state.categories.firstIndex(where: { $0.id == id }) { state.categories[i].name = name }
        }
    }

    public func deleteCategory(_ id: Int64) {
        update { state in
            state.categories.removeAll { $0.id == id }
            for (url, var w) in state.works where w.categoryIds.contains(id) {
                w.categoryIds.removeAll { $0 == id }
                state.works[url] = w
            }
        }
    }

    /// Puts the categories in this order (ids; others keep their place after them).
    public func reorderCategories(_ ids: [Int64]) {
        update { state in
            var order = 0
            for id in ids {
                if let i = state.categories.firstIndex(where: { $0.id == id }) {
                    state.categories[i].order = order
                    order += 1
                }
            }
            for i in state.categories.indices where !ids.contains(state.categories[i].id) {
                state.categories[i].order = order
                order += 1
            }
        }
    }
}

/// Character counts of text books (for whole-book progress), cached per file version so a book is counted once
/// (Android keeps them in ebook.db). Not part of backups.
public final class EbookInfoCache: @unchecked Sendable {
    private struct Entry: Codable {
        var size: Int64
        var modified: Double
        var counts: [Int]
    }

    private let file: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// The counts saved for this version of the file, or nil.
    public func counts(_ chapterId: String, size: Int64, modified: Double) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[chapterId], e.size == size, abs(e.modified - modified) < 0.001 else { return nil }
        return e.counts
    }

    public func store(_ chapterId: String, size: Int64, modified: Double, counts: [Int]) {
        lock.lock()
        entries[chapterId] = Entry(size: size, modified: modified, counts: counts)
        let copy = entries
        lock.unlock()
        guard let file, let data = try? JSONEncoder().encode(copy) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
