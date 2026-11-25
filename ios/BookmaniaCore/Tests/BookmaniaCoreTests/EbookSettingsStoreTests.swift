import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct EbookSettingsStoreTests {
    private let book = BookKey(sourceId: 0, mangaUrl: "直排測試書", chapterUrl: "直排測試書/第1冊.epub")
    private let other = BookKey(sourceId: 0, mangaUrl: "直排測試書", chapterUrl: "直排測試書/第2冊.epub")

    @Test func threeLevelsAndTheirKeys() {
        let prefs = MemoryPreferenceStore()
        let store = EbookSettingsStore(prefs)
        store.set(.global, book, .fontSize, "22")
        store.set(.work, book, .fontSize, "24")
        store.set(.file, book, .lineHeight, "2.2")
        #expect(prefs.values["pref_ebook_fontSize"] == "22")
        #expect(store.effective(book).fontSize == 24)
        #expect(store.effective(book).lineHeight == 2.2)
        // The file level of another book of the same work does not apply to it; the work level does.
        #expect(store.effective(other).lineHeight == 1.8)
        #expect(store.effective(other).fontSize == 24)
        #expect(store.resolvedAt(.global, book).fontSize == 22)
        #expect(store.overriddenBelow(.global, book) == [.fontSize: .work, .lineHeight: .file])
        #expect(store.initialScope(book) == .file)
        #expect(store.initialScope(other) == .work)
        store.clear(.work, book)
        #expect(store.effective(other).fontSize == 22)
        #expect(store.initialScope(other) == .global)
    }

    @Test func overrideKeysMatchAndroid() throws {
        // sha1("work\0" + "0" + "\0" + "直排測試書"), as Android's EbookSettingsStore.overrideKey computes it.
        let key = EbookSettingsStore.overrideKey(.work, book)
        #expect(key.hasPrefix("pref_ebook_override_"))
        #expect(key == "pref_ebook_override_9f4baf6d93ec8d7030fcfddfe3b9397e17c9a47f") // computed with Python's hashlib
        let prefs = MemoryPreferenceStore()
        EbookSettingsStore(prefs).set(.file, book, .bold, "true")
        let stored = try #require(prefs.values[EbookSettingsStore.overrideKey(.file, book)])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String])
        #expect(object == ["bold": "true", "_source": "0", "_manga": "直排測試書", "_chapter": "直排測試書/第1冊.epub"])
    }
}
