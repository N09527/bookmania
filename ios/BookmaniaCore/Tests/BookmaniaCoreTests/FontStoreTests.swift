import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct FontStoreTests {
    @Test func importListAndDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-fonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = MemoryPreferenceStore()
        let store = FontStore(directory: dir, store: prefs)
        let pending = try store.read(Fixtures.url("fonts/vertical-ok.ttf"))
        #expect(pending.name == "書狂測試直排")
        let font = try store.save(pending)
        #expect(FontStore.isId(font.id))
        #expect(font.fileExtension == "ttf")
        #expect(font.vertical)
        #expect(store.list() == [font])
        let file = try #require(store.file(font.id))
        #expect(FileManager.default.fileExists(atPath: file.path))
        // The list is stored with Android's field names.
        #expect(prefs.values["__APP_STATE_ebook_fonts"]?.contains("\"extension\":\"ttf\"") == true)
        #expect(store.file("../../etc") == nil)
        store.delete(font.id)
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: InvalidFontError.self) { _ = try store.read(Fixtures.url("zh-vertical.epub")) }
    }
}
