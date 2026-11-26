import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct ComicBookTests {
    @Test func imageNames() {
        #expect(ComicBooks.isImageName("001.JPG"))
        #expect(ComicBooks.isImageName("dir/p2.webp"))
        #expect(!ComicBooks.isImageName("ComicInfo.xml"))
        #expect(!ComicBooks.isImageName("dir/._001.jpg")) // macOS metadata
        #expect(!ComicBooks.isImageName("noextension"))
    }

    @Test func comicEpubsListTheirImagesInReadingOrder() throws {
        for name in ["comic-fixed.epub", "comic-reflowable.epub"] {
            let pub = try BookOpener.open(try Fixtures.source(name), extension: "epub")
            let book = try EpubComic(pub)
            defer { book.close() }
            #expect(book.pageCount >= 2, "\(name)")
            for i in 0 ..< book.pageCount {
                let bytes = try book.pageData(i)
                #expect(bytes.count > 8, "\(name) \(book.pageName(i))")
            }
        }
        // A text book has (almost) no image pages.
        let text = try EpubComic(try BookOpener.open(try Fixtures.source("zh-vertical.epub"), extension: "epub"))
        defer { text.close() }
        #expect(text.pageCount <= 1)
    }

    @Test func archivesAndFoldersInNaturalOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-comic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["10.png", "2.png", "1.png", "notes.txt", ".hidden.png"] {
            try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]).write(to: dir.appendingPathComponent(name))
        }
        let folder = try FolderComic(dir)
        #expect((0 ..< folder.pageCount).map(folder.pageName) == ["1.png", "2.png", "10.png"])
        // An archive: the EPUB fixtures are ZIP files with images inside.
        let archive = try ArchiveComic(try Fixtures.source("comic-fixed.epub"))
        defer { archive.close() }
        let names = (0 ..< archive.pageCount).map(archive.pageName)
        #expect(!names.isEmpty)
        #expect(names == names.sorted { LocalLibrary.naturalCompare($0, $1) == .orderedAscending })
        #expect(names.allSatisfy(ComicBooks.isImageName))
    }

    @Test func startPageAndProgress() {
        var state = ChapterState()
        #expect(ComicProgress.startPage(state, pageCount: 10) == 0)
        state.lastPageRead = 4
        #expect(ComicProgress.startPage(state, pageCount: 10) == 4)
        #expect(ComicProgress.startPage(state, pageCount: 3) == 0) // out of range
        state.read = true
        #expect(ComicProgress.startPage(state, pageCount: 10) == 0) // a read chapter starts at the first page
        // Page numbers written by the text reader (an estimate of text pages) become the same fraction of the book.
        var fromText = ChapterState()
        fromText.lastPageRead = 30
        fromText.pagesLeft = 70
        fromText.position = EbookLocator(spine: 1, href: "a", total: 0.3, chapterPage: 30)
        #expect(ComicProgress.startPage(fromText, pageCount: 20) == 6)

        let store = LibraryStore(file: nil)
        #expect(!ComicProgress.save(store, chapterId: "w/c", page: 3, pageCount: 10))
        #expect(store.chapter("w/c").lastPageRead == 3 && store.chapter("w/c").pagesLeft == 7 && !store.chapter("w/c").read)
        #expect(ComicProgress.save(store, chapterId: "w/c", page: 9, pageCount: 10))
        #expect(store.chapter("w/c").read && store.chapter("w/c").pagesLeft == 1)
        #expect(ComicProgress.save(store, chapterId: "w/d", page: 8, pageCount: 10, extraPage: true))
    }
}
