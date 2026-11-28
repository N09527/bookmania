import BookmaniaCore
import Foundation

/// The local source and the library state together, for the screens (Android's library, manga details, recents
/// presenters). Scans `local/` in the background; follows the library store.
@MainActor
final class LibraryModel: ObservableObject {
    /// Every work of the local source.
    @Published private(set) var works: [LocalWork] = []
    @Published private(set) var state = LibraryState()
    @Published private(set) var isScanning = false
    /// Changes when the library's sort, filters or display change, so the views read the preferences again.
    @Published var optionsVersion = 0

    let env = AppEnvironment.shared
    let preferences: LibraryPreferences
    private var observer: NSObjectProtocol?
    private var filesObserver: NSObjectProtocol?

    init() {
        preferences = LibraryPreferences(env.preferences)
        state = env.library.snapshot
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state = AppEnvironment.shared.library.snapshot }
        }
        // Book files the WebDAV sync downloaded.
        filesObserver = NotificationCenter.default.addObserver(forName: .syncDownloadedFiles, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let store = env.library
        Task.detached(priority: .userInitiated) {
            AppPaths.prepare()
            let found = LocalLibrary.scan(root: AppPaths.local)
            // A chapter seen for the first time gets its fetch date (the updates list).
            let now = nowMillis()
            let known = store.snapshot.chapters
            let new = found.flatMap(\.chapters).filter { (known[$0.id]?.dateFetch ?? 0) == 0 }
            if !new.isEmpty {
                store.update { state in
                    for chapter in new {
                        var c = state.chapters[chapter.id] ?? ChapterState()
                        c.dateFetch = now
                        state.chapters[chapter.id] = c
                    }
                }
            }
            await MainActor.run {
                self.works = found
                self.isScanning = false
            }
        }
    }

    func work(_ id: String) -> LocalWork? { works.first { $0.id == id } }

    func item(_ work: LocalWork) -> LibraryEntry { LibraryQuery.item(work, state) }

    func chapterState(_ id: String) -> ChapterState { state.chapters[id] ?? ChapterState() }

    func workState(_ id: String) -> WorkState { state.works[id] ?? WorkState() }

    var categories: [LibraryCategory] { state.categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }

    func sections(search: String) -> [LibrarySection] {
        var options = preferences.options
        options.search = search
        return LibraryQuery.sections(works, state, options)
    }

    // MARK: Library

    func addToLibrary(_ work: LocalWork, categories: [Int64]) {
        env.library.updateWork(work.id) { w in
            w.favorite = true
            if w.dateAdded == 0 { w.dateAdded = nowMillis() }
            w.categoryIds = categories
        }
    }

    func removeFromLibrary(_ work: LocalWork) {
        env.library.updateWork(work.id) { $0.favorite = false }
    }

    func setCategories(_ work: LocalWork, _ ids: [Int64]) {
        env.library.updateWork(work.id) { $0.categoryIds = ids }
    }

    func setChapterFlags(_ work: LocalWork, _ flags: Int) {
        env.library.updateWork(work.id) { $0.chapterFlags = flags | ChapterFlags.sortLocal | ChapterFlags.filterLocal }
    }

    // MARK: Chapters

    func setRead(_ chapters: [LocalChapter], _ read: Bool) {
        env.library.update { state in
            for chapter in chapters {
                var c = state.chapters[chapter.id] ?? ChapterState()
                c.read = read
                // As on Android, "mark as unread" clears the progress too.
                if !read {
                    c.lastPageRead = 0
                    c.pagesLeft = 0
                }
                state.chapters[chapter.id] = c
            }
        }
    }

    func setBookmark(_ chapters: [LocalChapter], _ bookmark: Bool) {
        env.library.update { state in
            for chapter in chapters {
                var c = state.chapters[chapter.id] ?? ChapterState()
                c.bookmark = bookmark
                state.chapters[chapter.id] = c
            }
        }
    }

    /// Marks the chapters before `chapter` (reading order) read.
    func markPreviousRead(_ chapter: LocalChapter, in work: LocalWork) {
        guard let index = work.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
        setRead(Array(work.chapters[..<index]), true)
    }

    // MARK: History and updates

    struct HistoryEntry: Identifiable {
        let work: LocalWork
        let chapter: LocalChapter
        let state: ChapterState
        var id: String { chapter.id }
    }

    /// Chapters read, the most recent first.
    var history: [HistoryEntry] {
        works.flatMap { work in
            work.chapters.compactMap { chapter -> HistoryEntry? in
                guard let c = state.chapters[chapter.id], c.lastRead != nil else { return nil }
                return HistoryEntry(work: work, chapter: chapter, state: c)
            }
        }
        .sorted { ($0.state.lastRead ?? 0) > ($1.state.lastRead ?? 0) }
    }

    /// New chapters of the works in the library, the newest first.
    var updates: [HistoryEntry] {
        works.filter { state.works[$0.id]?.favorite == true }.flatMap { work in
            work.chapters.map { HistoryEntry(work: work, chapter: $0, state: state.chapters[$0.id] ?? ChapterState()) }
        }
        .sorted { a, b in
            a.state.dateFetch != b.state.dateFetch ? a.state.dateFetch > b.state.dateFetch
                : LocalLibrary.naturalCompare(a.chapter.fileTitle, b.chapter.fileTitle) == .orderedDescending
        }
    }

    func removeFromHistory(_ chapter: LocalChapter) {
        env.library.updateChapter(chapter.id) { c in
            c.lastRead = nil
            c.readDuration = 0
        }
    }

    func clearHistory() {
        env.library.update { state in
            for (id, var c) in state.chapters where c.lastRead != nil {
                c.lastRead = nil
                c.readDuration = 0
                state.chapters[id] = c
            }
        }
    }
}
