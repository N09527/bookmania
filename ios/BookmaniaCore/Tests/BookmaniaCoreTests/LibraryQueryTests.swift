import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct LibraryQueryTests {
    private func work(_ id: String, chapters: [String], status: Int = 0, author: String? = nil, days: [Double] = []) -> LocalWork {
        var w = LocalWork(id: id, folder: URL(fileURLWithPath: "/local/\(id)"), title: id, chapters: [])
        w.author = author
        w.status = status
        w.chapters = chapters.enumerated().map { i, name in
            LocalChapter(id: "\(id)/\(name).epub", file: URL(fileURLWithPath: "/local/\(id)/\(name).epub"), kind: .epub, fileTitle: name,
                         modified: i < days.count ? Date(timeIntervalSince1970: days[i] * 86_400) : nil)
        }
        return w
    }

    private func library() -> ([LocalWork], LibraryState) {
        let works = [
            work("甲", chapters: ["1", "2", "3"], status: 2, author: "作者甲", days: [1, 2, 3]),
            work("乙", chapters: ["1"], days: [10]),
            work("丙", chapters: ["1", "2"], days: [5, 6]),
            work("丁", chapters: ["1"]), // not in the library
        ]
        var state = LibraryState()
        for (i, id) in ["甲", "乙", "丙"].enumerated() {
            var w = WorkState()
            w.favorite = true
            w.dateAdded = Int64(100 + i)
            state.works[id] = w
        }
        var read = ChapterState()
        read.read = true
        read.lastRead = 50
        state.chapters["甲/1.epub"] = read
        var bookmarked = ChapterState()
        bookmarked.bookmark = true
        bookmarked.lastRead = 70
        bookmarked.dateFetch = 9
        state.chapters["丙/2.epub"] = bookmarked
        var allRead = ChapterState()
        allRead.read = true
        state.chapters["乙/1.epub"] = allRead
        return (works, state)
    }

    private func titles(_ s: [LibrarySection]) -> [String] { s.flatMap { $0.items.map(\.work.title) } }

    @Test func onlyTheLibraryAndItsFilters() {
        let (works, state) = library()
        #expect(Set(titles(LibraryQuery.sections(works, state, LibraryOptions()))) == ["甲", "乙", "丙"])
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterUnread: 1))).sorted() == ["丙", "甲"].sorted())
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterUnread: 2))) == ["乙"])
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterUnread: 3))) == ["丙"]) // not started
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterUnread: 4))) == ["甲"]) // in progress
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterCompleted: 1))) == ["甲"])
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(filterBookmarked: 1))) == ["丙"])
        #expect(titles(LibraryQuery.sections(works, state, LibraryOptions(search: "作者"))) == ["甲"])
    }

    @Test func sortsLikeAndroid() {
        let (works, state) = library()
        func order(_ sort: Int, _ ascending: Bool = true) -> [String] {
            titles(LibraryQuery.sections(works, state, LibraryOptions(sort: sort, ascending: ascending)))
        }
        #expect(order(1) == ["丙", "甲", "乙"]) // last read: the most recent first, never read last
        #expect(order(2) == ["乙", "丙", "甲"]) // latest chapter: newest first
        #expect(order(3) == ["丙", "甲", "乙"]) // unread: 2, 2 (by title: 丙 U+4E19 before 甲 U+7532), then none
        #expect(order(4) == ["乙", "丙", "甲"]) // total chapters: fewest first
        #expect(order(5) == ["丙", "乙", "甲"]) // date added: newest first
        #expect(order(5, false) == ["甲", "乙", "丙"])
    }

    @Test func categories() {
        let (works, base) = library()
        var state = base
        state.categories = [LibraryCategory(id: 1, name: "B", order: 1), LibraryCategory(id: 2, name: "A", order: 0)]
        state.works["甲"]!.categoryIds = [1, 2]
        state.works["乙"]!.categoryIds = [1]
        let sections = LibraryQuery.sections(works, state, LibraryOptions())
        #expect(sections.map { $0.category?.name } == [nil, "A", "B"])
        #expect(sections[0].items.map(\.work.title) == ["丙"])
        #expect(sections[1].items.map(\.work.title) == ["甲"])
        #expect(Set(sections[2].items.map(\.work.title)) == ["甲", "乙"])
        // Without uncategorized works there is no default section.
        state.works["丙"]!.categoryIds = [2]
        #expect(LibraryQuery.sections(works, state, LibraryOptions()).map { $0.category?.name } == ["A", "B"])
    }

    @Test func chapterListFlags() {
        let (works, state) = library()
        let w = works[0]
        func names(_ flags: Int) -> [String] { LibraryQuery.chapters(w, flags: flags, state: state).map(\.fileTitle) }
        #expect(names(0) == ["3", "2", "1"]) // Android's default: descending
        #expect(names(ChapterFlags.sortAscending) == ["1", "2", "3"])
        #expect(names(ChapterFlags.sortAscending | ChapterFlags.showUnread) == ["2", "3"])
        #expect(names(ChapterFlags.sortAscending | ChapterFlags.showRead) == ["1"])
        #expect(LibraryQuery.nextToRead(w, state)?.fileTitle == "2")
    }

    @Test func preferencesUseAndroidKeys() {
        let store = MemoryPreferenceStore()
        let prefs = LibraryPreferences(store)
        #expect(prefs.layout == 2 && prefs.unreadBadge == 2 && prefs.sortingAscending && prefs.sortingMode == 0)
        prefs.sortingMode = 3
        prefs.sortingAscending = false
        prefs.filterUnread = 1
        prefs.collapsedCategories = [3, 1]
        #expect(store.values["library_sorting_mode"] == "3")
        #expect(store.values["library_sorting_ascending"] == "false")
        #expect(store.values["pref_filter_unread_key"] == "1")
        #expect(prefs.collapsedCategories == [1, 3])
        #expect(prefs.options == LibraryOptions(sort: 3, ascending: false, filterUnread: 1))
    }

    @Test func localWorkDetails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-work-\(UUID().uuidString)/作品")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data(#"{"title":"作品名","artist":"繪者","genre":["奇幻","冒險"],"status":2}"#.utf8).write(to: dir.appendingPathComponent("details.json"))
        let w = LocalLibrary.work(at: dir)
        #expect(w.title == "作品名" && w.artist == "繪者" && w.genres == ["奇幻", "冒險"] && w.status == 2)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("details.json"))
        let xml = #"<?xml version="1.0"?><ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema"><Series>系列</Series><Penciller>畫</Penciller><Genre>A, B</Genre><ty:PublishingStatusTachiyomi>Ongoing</ty:PublishingStatusTachiyomi></ComicInfo>"#
        try Data(xml.utf8).write(to: dir.appendingPathComponent("ComicInfo.xml"))
        let c = LocalLibrary.work(at: dir)
        #expect(c.title == "系列" && c.artist == "畫" && c.genres == ["A", "B"] && c.status == 1)
    }
}
