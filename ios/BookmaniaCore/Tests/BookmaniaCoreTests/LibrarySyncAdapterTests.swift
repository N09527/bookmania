import Foundation
import Testing
@testable import BookmaniaCore

/// The iOS adapter between the library store and the sync, against another (fake) device through the in-memory
/// server.
@Suite struct LibrarySyncAdapterTests {
    final class Clock: @unchecked Sendable { var now: Int64 = 2_000_000 }

    let server = InMemoryWebDAV()
    let clock = Clock()
    let store = LibraryStore(file: nil)
    let prefs = MemoryPreferenceStore()
    let root: URL
    let adapter: LibrarySyncAdapter
    let ios: SyncEngine
    let other = FakeDevice("a0000000-0000-4000-8000-00000000000a")
    let otherSync: SyncEngine

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sync-adapter-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = prefs
        adapter = LibrarySyncAdapter(store: store, preferences: prefs, allPreferences: { prefs.values }, localRoot: root, directory: tmp.appendingPathComponent("sync"))
        let dav = try WebDAVClient(baseURL: server.base, user: "reader", password: "secret", transport: server)
        let clock = clock
        ios = SyncEngine(dav: dav, device: Sync.DeviceInfo(id: "b0000000-0000-4000-8000-00000000000b", name: "iPad", platform: "ios", app: "t"), adapter: adapter) { clock.now }
        otherSync = SyncEngine(dav: dav, device: Sync.DeviceInfo(id: other.id, name: "phone", platform: "android", app: "t"), adapter: other) { clock.now }
    }

    @Test func libraryCategoriesAndSettingsMapToTheStore() async throws {
        let book = SyncIds.localWorkKey("直排測試書")
        other.works[book] = Sync.WorkValue(favorite: true, added: 1000, categories: ["小說"], chapterFlags: 0x1001, viewerFlags: 2)
        other.categories["小說"] = Sync.CategoryValue(order: 0, flags: 0)
        other.works["123:/manga/1"] = Sync.WorkValue(favorite: true, added: 1000)
        other.settings["pref_ebook_fontSize"] = Sync.SettingValue(type: "string", value: .string("26"))
        other.settings["pref_reader_theme_key"] = Sync.SettingValue(type: "int", value: .int(4))
        other.settings["pref_ebook_gutter_shadow"] = Sync.SettingValue(type: "bool", value: .bool(false))
        other.settings["incognito_mode"] = Sync.SettingValue(type: "bool", value: .bool(true))
        _ = try await otherSync.syncLibrary()

        clock.now += 1000
        _ = try await ios.syncLibrary()
        let state = store.snapshot
        let category = try #require(state.categories.first { $0.name == "小說" })
        #expect(state.works["直排測試書"]?.favorite == true)
        #expect(state.works["直排測試書"]?.dateAdded == 1000)
        #expect(state.works["直排測試書"]?.categoryIds == [category.id])
        #expect(state.works["直排測試書"]?.chapterFlags == 0x1001)
        #expect(state.works["直排測試書"]?.viewerFlags == 2)
        // An online work stays on the server for later; the iOS store has only local works.
        #expect(state.works.count == 1)
        #expect(prefs.string("pref_ebook_fontSize") == "26")
        #expect(prefs.string("pref_reader_theme_key") == "4")
        #expect(prefs.string("pref_ebook_gutter_shadow") == "false")
        // Incognito mode is not synced (it never reached the server either).
        #expect(prefs.string("incognito_mode") == nil)

        // Removed from the library and the category deleted on the iPad.
        clock.now += 1000
        store.update { s in
            s.works["直排測試書"] = nil
            s.categories = []
        }
        prefs.set("pref_reader_theme_key", "1")
        _ = try await ios.syncLibrary()
        clock.now += 1000
        _ = try await otherSync.syncLibrary()
        #expect(other.works[book]?.favorite == false)
        #expect(other.categories["小說"] == nil)
        #expect(other.settings["pref_reader_theme_key"]?.value == .int(1))
        #expect(other.works["123:/manga/1"]?.favorite == true)
    }

    @Test func progressPositionsAndHistory() async throws {
        let book = SyncIds.localWorkKey("作品")
        let locator = EbookLocator(spine: 2, href: "c.xhtml", location: [3, 0], text: "位置", progression: 0.4, updatedAt: 5000)
        other.works[book] = Sync.WorkValue(favorite: true, added: 1)
        other.setChapter(book, "作品/a.epub", Sync.ChapterValue(read: true, page: 30, lastRead: 5000, duration: 60000))
        other.setChapter(book, "作品/b.epub", Sync.ChapterValue(page: 4, left: 20, bookmark: true, locator: locator.toJSON(), lastRead: 5000, duration: 1000))
        _ = try await otherSync.syncLibrary()
        _ = try await otherSync.syncWork(book, push: true)

        clock.now += 1000
        // The files are not on the iPad yet: the progress is kept for when they arrive.
        _ = try await ios.syncLibrary()
        #expect(store.chapter("作品/a.epub").read == true)
        #expect(store.chapter("作品/a.epub").lastPageRead == 30)
        #expect(store.chapter("作品/a.epub").readDuration == 60000)
        #expect(store.chapter("作品/b.epub").position == locator)
        #expect(store.chapter("作品/b.epub").bookmark == true)
        #expect(store.chapter("作品/b.epub").lastRead == 5000)

        // Reading on, on the iPad, then clearing the position.
        clock.now += 1000
        store.updateChapter("作品/b.epub") { c in
            c.lastPageRead = 9
            c.lastRead = clock.now
            c.readDuration = 4000
            c.position = nil
        }
        _ = try await ios.syncWork(book, push: true)
        clock.now += 1000
        _ = try await otherSync.syncWork(book, push: false)
        #expect(other.chapter(book, "作品/b.epub") == Sync.ChapterValue(page: 9, left: 20, bookmark: true, locator: nil, lastRead: clock.now - 1000, duration: 4000))
    }

    @Test func bookFilesGoToTheLocalSourceFolder() async throws {
        let book = SyncIds.localWorkKey("漫畫")
        other.works[book] = Sync.WorkValue(favorite: true, added: 1)
        other.files["漫畫/第01話/001.jpg"] = Data(repeating: 7, count: 300)
        other.files["漫畫/cover.jpg"] = Data(repeating: 8, count: 50)
        _ = try await otherSync.syncLibrary()
        _ = try await otherSync.syncFiles(other, libraryWorks: ["漫畫"])

        _ = try await ios.syncLibrary()
        let down = try await ios.syncFiles(adapter, libraryWorks: ["漫畫"])
        #expect(Set(down.downloaded.map(\.path)) == ["第01話/001.jpg", "cover.jpg"])
        #expect(try Data(contentsOf: root.appendingPathComponent("漫畫/第01話/001.jpg")) == Data(repeating: 7, count: 300))
        #expect(Set(adapter.list(works: ["漫畫"]).map(\.path)) == ["第01話/001.jpg", "cover.jpg"])
        // A file of its own goes up.
        try Data(repeating: 9, count: 10).write(to: root.appendingPathComponent("漫畫/第02話.cbz"))
        let up = try await ios.syncFiles(adapter, libraryWorks: ["漫畫"])
        #expect(up.uploaded.map(\.path) == ["第02話.cbz"])
        #expect(server.files["Bookmania/sync-v1/files/漫畫/第02話.cbz"] == Data(repeating: 9, count: 10))
    }
}
