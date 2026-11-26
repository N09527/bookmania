import Foundation

/// A work as the library and the work page show it: the local folder and what the store knows about it.
public struct LibraryEntry: Identifiable, Sendable {
    public let work: LocalWork
    public let state: WorkState
    public let unread: Int
    public let readCount: Int
    public let bookmarks: Int
    /// When a chapter of the work was last read (milliseconds; 0 when never).
    public let lastRead: Int64
    /// The newest chapter file's date (milliseconds): the local source's "latest chapter".
    public let latestChapter: Int64
    /// When the app last found a new chapter of the work (milliseconds).
    public let dateFetched: Int64

    public var id: String { work.id }
    public var total: Int { work.chapters.count }
}

/// The library's sort, filters and display, under Android's preference keys and with its values (LibrarySort,
/// FilterBottomSheet, LibraryEntry.LAYOUT_*).
public final class LibraryPreferences: @unchecked Sendable {
    private let store: PreferenceStore

    public init(_ store: PreferenceStore) { self.store = store }

    public enum Keys {
        public static let sortingMode = "library_sorting_mode"
        public static let sortingAscending = "library_sorting_ascending"
        public static let filterUnread = "pref_filter_unread_key"
        public static let filterCompleted = "pref_filter_completed_key"
        public static let filterBookmarked = "pref_filter_bookmarked_key"
        public static let layout = "pref_display_library_layout"
        public static let unreadBadge = "unread_badge_type"
        public static let collapsedCategories = "collapsed_categories"
    }

    public static let types: [String: ReaderPreferences.PreferenceType] = [
        Keys.sortingMode: .int, Keys.sortingAscending: .bool, Keys.filterUnread: .int, Keys.filterCompleted: .int,
        Keys.filterBookmarked: .int, Keys.layout: .int, Keys.unreadBadge: .int,
    ]

    /// Sort modes (LibrarySort.mainValue): title 0, last read 1, latest chapter 2, unread 3, total chapters 4,
    /// date added 5, date fetched 6.
    public static let sortModes = [0, 1, 2, 3, 4, 5, 6]

    public var sortingMode: Int {
        get { store.string(Keys.sortingMode).flatMap { Int($0) }.flatMap { LibraryPreferences.sortModes.contains($0) ? $0 : nil } ?? 0 }
        set { store.set(Keys.sortingMode, String(newValue)) }
    }

    public var sortingAscending: Bool {
        get { store.string(Keys.sortingAscending) != "false" }
        set { store.set(Keys.sortingAscending, newValue ? "true" : "false") }
    }

    /// 0 off, 1 with unread chapters, 2 without unread chapters, 3 not started, 4 in progress.
    public var filterUnread: Int {
        get { tri(Keys.filterUnread, max: 4) }
        set { store.set(Keys.filterUnread, String(newValue)) }
    }

    /// 0 off, 1 completed only, 2 not completed.
    public var filterCompleted: Int {
        get { tri(Keys.filterCompleted, max: 2) }
        set { store.set(Keys.filterCompleted, String(newValue)) }
    }

    /// 0 off, 1 with bookmarks, 2 without bookmarks.
    public var filterBookmarked: Int {
        get { tri(Keys.filterBookmarked, max: 2) }
        set { store.set(Keys.filterBookmarked, String(newValue)) }
    }

    /// 0 list, 1 compact grid, 2 comfortable grid (default), 3 cover only grid.
    public var layout: Int {
        get { store.string(Keys.layout).flatMap { Int($0) }.flatMap { (0 ... 3).contains($0) ? $0 : nil } ?? 2 }
        set { store.set(Keys.layout, String(newValue)) }
    }

    /// Unread badges: 0 hidden, 1 a dot, 2 the number (default).
    public var unreadBadge: Int {
        get { store.string(Keys.unreadBadge).flatMap { Int($0) }.flatMap { (0 ... 2).contains($0) ? $0 : nil } ?? 2 }
        set { store.set(Keys.unreadBadge, String(newValue)) }
    }

    /// Ids of collapsed category sections (Android stores them as a string set; here comma separated).
    public var collapsedCategories: Set<Int64> {
        get { Set((store.string(Keys.collapsedCategories) ?? "").split(separator: ",").compactMap { Int64($0) }) }
        set { store.set(Keys.collapsedCategories, newValue.sorted().map(String.init).joined(separator: ",")) }
    }

    public var options: LibraryOptions {
        LibraryOptions(sort: sortingMode, ascending: sortingAscending, filterUnread: filterUnread,
                       filterCompleted: filterCompleted, filterBookmarked: filterBookmarked)
    }

    private func tri(_ key: String, max: Int) -> Int {
        store.string(key).flatMap { Int($0) }.flatMap { (0 ... max).contains($0) ? $0 : nil } ?? 0
    }
}

public struct LibraryOptions: Equatable, Sendable {
    public var sort = 0
    public var ascending = true
    public var filterUnread = 0
    public var filterCompleted = 0
    public var filterBookmarked = 0
    public var search = ""

    public init(sort: Int = 0, ascending: Bool = true, filterUnread: Int = 0, filterCompleted: Int = 0, filterBookmarked: Int = 0, search: String = "") {
        self.sort = sort
        self.ascending = ascending
        self.filterUnread = filterUnread
        self.filterCompleted = filterCompleted
        self.filterBookmarked = filterBookmarked
        self.search = search
    }

    public var hasFilters: Bool { filterUnread != 0 || filterCompleted != 0 || filterBookmarked != 0 }
}

/// A section of the library: a category with its works (nil category: the default one, for works without a category).
public struct LibrarySection: Identifiable, Sendable {
    public let category: LibraryCategory?
    public let items: [LibraryEntry]
    public var id: Int64 { category?.id ?? 0 }
}

/// Builds, filters and sorts the library (LibraryPresenter on Android).
public enum LibraryQuery {

    public static func item(_ work: LocalWork, _ state: LibraryState) -> LibraryEntry {
        var unread = 0, read = 0, bookmarks = 0
        var lastRead: Int64 = 0, latest: Int64 = 0, fetched: Int64 = 0
        for chapter in work.chapters {
            let c = state.chapters[chapter.id] ?? ChapterState()
            if c.read { read += 1 } else { unread += 1 }
            if c.bookmark { bookmarks += 1 }
            lastRead = max(lastRead, c.lastRead ?? 0)
            latest = max(latest, chapter.modified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
            fetched = max(fetched, c.dateFetch)
        }
        return LibraryEntry(work: work, state: state.works[work.id] ?? WorkState(), unread: unread, readCount: read,
                           bookmarks: bookmarks, lastRead: lastRead, latestChapter: latest, dateFetched: fetched)
    }

    /// Whether `item` passes the filters and the search (title, author, artist or a genre containing the text).
    public static func matches(_ item: LibraryEntry, _ o: LibraryOptions) -> Bool {
        switch o.filterUnread {
        case 1 where item.unread == 0: return false
        case 2 where item.unread > 0: return false
        case 3 where !(item.unread > 0 && item.readCount == 0): return false // not started
        case 4 where !(item.unread > 0 && item.readCount > 0): return false // in progress
        default: break
        }
        let completed = item.work.status == 2
        if o.filterCompleted == 1 && !completed { return false }
        if o.filterCompleted == 2 && completed { return false }
        if o.filterBookmarked == 1 && item.bookmarks == 0 { return false }
        if o.filterBookmarked == 2 && item.bookmarks > 0 { return false }
        let query = o.search.trimmed
        if !query.isEmpty {
            let fields = [item.work.title, item.work.author ?? "", item.work.artist ?? ""] + item.work.genres
            if !fields.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }) {
                return false
            }
        }
        return true
    }

    /// Sorts like Android's LibrarySort: "ascending" is A to Z, the most recently read / updated / added first, the
    /// fewest unread (works without unread chapters last) and the fewest chapters first; descending reverses it.
    public static func sorted(_ items: [LibraryEntry], _ o: LibraryOptions) -> [LibraryEntry] {
        let byTitle: (LibraryEntry, LibraryEntry) -> Bool = { LocalLibrary.naturalCompare($0.work.title, $1.work.title) == .orderedAscending }
        let ordered: (LibraryEntry, LibraryEntry) -> Bool
        switch o.sort {
        case 1: ordered = { $0.lastRead != $1.lastRead ? $0.lastRead > $1.lastRead : byTitle($0, $1) }
        case 2: ordered = { $0.latestChapter != $1.latestChapter ? $0.latestChapter > $1.latestChapter : byTitle($0, $1) }
        case 3:
            ordered = { a, b in
                if a.unread == b.unread { return byTitle(a, b) }
                if a.unread == 0 { return false }
                if b.unread == 0 { return true }
                return a.unread < b.unread
            }
        case 4: ordered = { $0.total != $1.total ? $0.total < $1.total : byTitle($0, $1) }
        case 5: ordered = { $0.state.dateAdded != $1.state.dateAdded ? $0.state.dateAdded > $1.state.dateAdded : byTitle($0, $1) }
        case 6: ordered = { $0.dateFetched != $1.dateFetched ? $0.dateFetched > $1.dateFetched : byTitle($0, $1) }
        default: ordered = byTitle
        }
        let result = items.sorted(by: ordered)
        return o.ascending ? result : result.reversed()
    }

    /// The library's sections: the works in the library, filtered and sorted, under each of their categories (a work
    /// can be in several); works without a category go to the default category, shown first when it has works.
    public static func sections(_ works: [LocalWork], _ state: LibraryState, _ o: LibraryOptions) -> [LibrarySection] {
        let items = works.map { item($0, state) }.filter { $0.state.favorite && matches($0, o) }
        let categories = state.categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        let known = Set(categories.map(\.id))
        var sections = [LibrarySection]()
        let uncategorized = items.filter { $0.state.categoryIds.allSatisfy { !known.contains($0) } }
        if !uncategorized.isEmpty || categories.isEmpty { sections.append(LibrarySection(category: nil, items: sorted(uncategorized, o))) }
        for category in categories {
            sections.append(LibrarySection(category: category, items: sorted(items.filter { $0.state.categoryIds.contains(category.id) }, o)))
        }
        return sections
    }

    /// The chapter list of a work with the sort and filters of its chapter flags (Manga.CHAPTER_*): by source order or
    /// chapter number (the local source sorts chapters by their names, so both use the natural order of the file
    /// names) or by upload date (the file's date); descending unless the ascending bit is set.
    public static func chapters(_ work: LocalWork, flags: Int, state: LibraryState) -> [LocalChapter] {
        var list = work.chapters
        if flags & ChapterFlags.sortingMask == ChapterFlags.sortingUploadDate {
            list.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        }
        if flags & ChapterFlags.sortMask == ChapterFlags.sortDescending { list.reverse() }
        return list.filter { chapter in
            let c = state.chapters[chapter.id] ?? ChapterState()
            switch flags & ChapterFlags.readMask {
            case ChapterFlags.showUnread where c.read: return false
            case ChapterFlags.showRead where !c.read: return false
            default: break
            }
            switch flags & ChapterFlags.bookmarkedMask {
            case ChapterFlags.showBookmarked where !c.bookmark: return false
            case ChapterFlags.showNotBookmarked where c.bookmark: return false
            default: break
            }
            return true
        }
    }

    /// The chapter to continue with: the first unread one in reading order (Android's "continue reading").
    public static func nextToRead(_ work: LocalWork, _ state: LibraryState) -> LocalChapter? {
        work.chapters.first { !(state.chapters[$0.id]?.read ?? false) }
    }
}
