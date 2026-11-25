import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct LocalLibraryTests {
    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-local-\(UUID().uuidString)")
        let fm = FileManager.default
        let work = root.appendingPathComponent("直排測試書")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        for name in ["第10冊.epub", "第2冊.azw3", "第1冊.mobi", "notes.txt", ".hidden.epub", "cover.jpg"] {
            try Data([1, 2, 3]).write(to: work.appendingPathComponent(name))
        }
        try fm.createDirectory(at: work.appendingPathComponent("圖片集"), withIntermediateDirectories: true)
        try #"<?xml version="1.0"?><ComicInfo><Series>直排測試書（叢書）</Series><Writer>Bookmania 測試</Writer><Summary>簡介</Summary></ComicInfo>"#
            .write(to: work.appendingPathComponent("ComicInfo.xml"), atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("Another")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([1]).write(to: other.appendingPathComponent("a.cbz"))
        try #"{"title":"另一部","author":"甲","description":"乙"}"#.write(to: other.appendingPathComponent("details.json"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: root.appendingPathComponent("stray.epub")) // files directly in local/ are not works
        return root
    }

    @Test func worksAndChaptersFollowTheAndroidLayout() throws {
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let works = LocalLibrary.scan(root: root)
        #expect(works.map(\.id) == ["Another", "直排測試書"])
        let another = works[0]
        #expect(another.title == "另一部")
        #expect(another.author == "甲")
        #expect(another.description == "乙")
        #expect(another.chapters.map(\.kind) == [.archive])
        let book = works[1]
        #expect(book.title == "直排測試書（叢書）") // ComicInfo has priority
        #expect(book.author == "Bookmania 測試")
        #expect(book.coverFile?.lastPathComponent == "cover.jpg")
        // Natural order by code point, as Android sorts names: 圖 (U+5716) comes before 第 (U+7B2C).
        #expect(book.chapters.map(\.fileTitle) == ["圖片集", "第1冊", "第2冊", "第10冊"])
        #expect(book.chapters.map(\.id) == ["直排測試書/圖片集", "直排測試書/第1冊.mobi", "直排測試書/第2冊.azw3", "直排測試書/第10冊.epub"])
        #expect(book.chapters.map(\.kind) == [.folder, .mobi, .azw3, .epub])
    }
}
