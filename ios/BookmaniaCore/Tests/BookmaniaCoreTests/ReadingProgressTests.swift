import Foundation
import Testing
@testable import BookmaniaCore

/// The cases of Android's ReadingProgressTest and ReadingSessionTest.
@Suite struct ReadingProgressTests {
    // Three documents: an image-only page (0 characters), 1000 and 3000 characters.
    private let progress = ReadingProgress([0, 1000, 3000])

    @Test func wholeBookFraction() {
        #expect(abs(progress.total(0, 0.5)) < 1e-9)
        #expect(abs(progress.total(1, 0)) < 1e-9)
        #expect(abs(progress.total(1, 0.5) - 0.125) < 1e-9)
        #expect(abs(progress.total(2, 0) - 0.25) < 1e-9)
        #expect(abs(progress.total(2, 1) - 1) < 1e-9)
        #expect(abs(progress.total(2, 7) - 1) < 1e-9)
        #expect(abs(progress.total(9, 0.5)) < 1e-9)
    }

    @Test func fractionOfTheBookBackToADocument() {
        #expect(progress.locate(0) == (1, 0))
        #expect(progress.locate(0.125).0 == 1)
        #expect(abs(progress.locate(0.125).1 - 0.5) < 1e-9)
        #expect(progress.locate(0.5).0 == 2)
        #expect(abs(progress.locate(0.5).1 - 1.0 / 3) < 1e-9)
        #expect(progress.locate(1) == (2, 1))
    }

    @Test func aBookWithoutTextCountsDocumentsAsEqualParts() {
        let pictures = ReadingProgress([0, 0, 0, 0])
        #expect(abs(pictures.total(0, 0)) < 1e-9)
        #expect(abs(pictures.total(2, 0.5) - 0.625) < 1e-9)
        #expect(abs(pictures.total(3, 1) - 1) < 1e-9)
        #expect(pictures.locate(0.625).0 == 2)
        #expect(abs(pictures.locate(0.625).1 - 0.5) < 1e-9)
        #expect(pictures.locate(1) == (3, 1))
        #expect(ReadingProgress([]).locate(0.7) == (0, 0))
        #expect(pictures.pages(1, page: 0, pages: 3, atEnd: false) == nil)
    }

    @Test func pageNumbersAreEstimatedWithTheOpenDocumentsPageSize() {
        #expect(progress.pages(1, page: 0, pages: 10, atEnd: false)! == (0, 40))
        #expect(progress.pages(1, page: 4, pages: 10, atEnd: false)! == (4, 40))
        #expect(progress.pages(2, page: 0, pages: 25, atEnd: false)! == (8, 33))
        #expect(progress.pages(2, page: 12, pages: 25, atEnd: false)! == (20, 33))
        #expect(progress.pages(2, page: 24, pages: 25, atEnd: true)! == (32, 33))
        #expect(progress.pages(2, page: 99, pages: 25, atEnd: false)! == (32, 33))
        #expect(progress.pages(0, page: 0, pages: 1, atEnd: false) == nil)
        #expect(progress.pages(1, page: 0, pages: 0, atEnd: false) == nil)
    }

    @Test func locatorJSONRoundTripAndValidation() throws {
        let locator = EbookLocator(spine: 2, href: "OEBPS/text/ch02.xhtml", location: [17, 4], text: "【第１３段】長一點的段落",
                                   progression: 0.29, total: 0.4, atEnd: false, updatedAt: 1_700_000_000_000)
        #expect(EbookLocator.fromJSON(locator.toJSON()) == locator)
        let picturePage = EbookLocator(spine: 0, href: "a.xhtml", pageProgression: 0.5)
        #expect(EbookLocator.fromJSON(picturePage.toJSON()) == picturePage)
        #expect(EbookLocator.fromJSON(#"{"spine":1,"href":"b.xhtml","futureField":3}"#) == EbookLocator(spine: 1, href: "b.xhtml"))
        #expect(EbookLocator.fromJSON(#"{"spine":1,"href":"b.xhtml","progression":1.5}"#) == nil)
        #expect(EbookLocator.fromJSON(#"{"spine":-1,"href":"b.xhtml"}"#) == nil)
        #expect(EbookLocator.fromJSON(#"{"spine":1,"href":"b.xhtml","location":[3]}"#) == nil)
        #expect(EbookLocator.fromJSON("not json") == nil)
        #expect(EbookLocator.fromJSON(nil) == nil)
        // Defaults are left out, as Android writes them; the slash in a path is not escaped.
        #expect(EbookLocator(spine: 1, href: "a/b.xhtml").toJSON() == #"{"href":"a/b.xhtml","spine":1}"#)
        // A locator written by Android (kotlinx.serialization, declaration order, defaults left out) is read.
        let android = #"{"spine":1,"href":"OEBPS/text/ch02.xhtml","location":[55,0],"text":"【第１３段】長一點的段落","progression":0.29,"total":0.43,"updatedAt":1700000000000}"#
        let parsed = try #require(EbookLocator.fromJSON(android))
        #expect(parsed.location == [55, 0] && parsed.total == 0.43 && parsed.updatedAt == 1_700_000_000_000 && !parsed.atEnd)
    }

    @Test func shellTargets() {
        #expect(EbookLocator(spine: 0, href: "a", pageProgression: 0.5).shellTarget == #"{"pageProgression":0.5}"#)
        let target = EbookLocator(spine: 0, href: "a", location: [3, 1], text: "abcd", progression: 0.25).shellTarget
        #expect(target == #"{"location":[3,1],"progression":0.25,"text":"abcd"}"#)
    }
}

@Suite struct ReadingSessionTests {
    private let chapterId = "直排測試書 EPUB/zh-vertical.epub"

    private func locator(progression: Double = 0.5, atEnd: Bool = false) -> EbookLocator {
        EbookLocator(spine: 1, href: "b.xhtml", location: [3, 0], text: "abcd", progression: progression, atEnd: atEnd, updatedAt: 5)
    }

    private final class Clock: @unchecked Sendable {
        var now: Int64 = 1_000_000
    }

    @Test func savesThePositionAndTheEstimatedPage() {
        let store = LibraryStore(file: nil)
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { false })
        session.progress = ReadingProgress([1000, 1000])
        // Document 1 on 10 pages (100 characters each): 10 pages before it, 20 in all.
        #expect(!session.save(locator(), spine: 1, page: 5, pages: 10))
        let c = store.chapter(chapterId)
        #expect(c.position == { var l = locator(); l.chapterPage = 15; return l }())
        #expect(c.lastPageRead == 15 && c.pagesLeft == 5 && !c.read)
    }

    @Test func withoutCharacterCountsThePageNumbersAreLeftAlone() {
        let store = LibraryStore(file: nil)
        store.updateChapter(chapterId) { $0.lastPageRead = 3; $0.pagesLeft = 7 }
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { false })
        session.save(locator(), spine: 1, page: 5, pages: 10)
        let c = store.chapter(chapterId)
        #expect(c.position?.chapterPage == nil)
        #expect(c.lastPageRead == 3 && c.pagesLeft == 7)
    }

    @Test func theLastPageMarksTheChapterReadOnce() {
        let store = LibraryStore(file: nil)
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { false })
        session.progress = ReadingProgress([1000, 1000])
        #expect(session.save(locator(progression: 1, atEnd: true), spine: 1, page: 9, pages: 10))
        #expect(store.chapter(chapterId).read)
        #expect(store.chapter(chapterId).lastPageRead == 19 && store.chapter(chapterId).pagesLeft == 1)
        #expect(!session.save(locator(progression: 1, atEnd: true), spine: 1, page: 9, pages: 10))
    }

    @Test func incognitoSavesNothing() {
        let store = LibraryStore(file: nil)
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { true })
        session.save(locator(), spine: 1, page: 5, pages: 10)
        session.saveReadingTime(0, 90_000)
        #expect(store.snapshot.chapters.isEmpty)
    }

    @Test func readingTimeGoesToTheHistory() {
        let store = LibraryStore(file: nil)
        let clock = Clock()
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { false }, now: { clock.now })
        session.startTimer()
        clock.now += 30_000
        session.flushTimer()
        #expect(store.chapter(chapterId).readDuration == 30_000)
        #expect(store.chapter(chapterId).lastRead == clock.now)
        session.flushTimer() // not running: nothing more
        session.startTimer()
        clock.now += 20_000
        let span = session.stopTimer()!
        session.startTimer() // a quick return keeps timing
        session.saveReadingTime(span.0, span.1)
        #expect(store.chapter(chapterId).readDuration == 50_000)
    }

    @Test func whereTheBookOpens() {
        let store = LibraryStore(file: nil)
        let session = ReadingSession(store: store, chapterId: chapterId, incognito: { false })
        #expect(session.positionToRestore() == nil)
        store.updateChapter(chapterId) { $0.position = locator(atEnd: true) }
        #expect(session.positionToRestore() == nil) // left on its last page
        store.updateChapter(chapterId) { $0.position = locator() }
        #expect(session.positionToRestore() == locator())
        store.updateChapter(chapterId) { $0.read = true }
        #expect(session.positionToRestore() == nil) // read
        store.updateChapter(chapterId) { c in
            c.read = false
            var l = locator()
            l.chapterPage = 12
            c.position = l
            c.lastPageRead = 0 // cleared in the chapter list
        }
        #expect(session.positionToRestore() == nil)
        #expect(session.positionToRestore(switchedFromImages: true)?.chapterPage == 12)
        store.updateChapter(chapterId) { $0.lastPageRead = 12; $0.pagesLeft = 8 }
        #expect(session.positionToRestore()?.chapterPage == 12)
        #expect(abs(session.estimatedFraction()! - 0.6) < 1e-9)
    }
}

@Suite struct LibraryStoreTests {
    @Test func savesAndLoadsTheState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        let store = LibraryStore(file: file, delay: 0)
        let category = store.addCategory("小說")
        store.addCategory("漫畫")
        store.updateWork("作品") { w in
            w.favorite = true
            w.dateAdded = 42
            w.categoryIds = [category.id]
        }
        store.updateChapter("作品/1.epub") { c in
            c.read = true
            c.position = EbookLocator(spine: 1, href: "a.xhtml")
        }
        store.updateChapter("作品/2.epub") { _ in } // untouched: not kept
        store.flush()
        let loaded = LibraryStore(file: file)
        #expect(loaded.snapshot == store.snapshot)
        #expect(loaded.snapshot.chapters.count == 1)
        #expect(loaded.work("作品").categoryIds == [category.id])
        #expect(loaded.categories.map(\.name) == ["小說", "漫畫"])
        loaded.reorderCategories([loaded.categories[1].id])
        #expect(loaded.categories.map(\.name) == ["漫畫", "小說"])
        loaded.deleteCategory(category.id)
        #expect(loaded.work("作品").categoryIds.isEmpty)
        #expect(loaded.categories.map(\.name) == ["漫畫"])
        // A file written by a later version with more fields is still read.
        let newer = #"{"works":{"w":{"favorite":true,"later":1}},"chapters":{"w/a":{"read":true,"later":[1]}},"version":2}"#
        try Data(newer.utf8).write(to: file)
        let forward = LibraryStore(file: file)
        #expect(forward.work("w").favorite && forward.chapter("w/a").read)
    }

    @Test func characterCountsAreKeptPerFileVersion() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookmania-info-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ebook-info.json")
        let cache = EbookInfoCache(file: file)
        cache.store("w/a.epub", size: 100, modified: 5, counts: [1, 2, 3])
        let reloaded = EbookInfoCache(file: file)
        #expect(reloaded.counts("w/a.epub", size: 100, modified: 5) == [1, 2, 3])
        #expect(reloaded.counts("w/a.epub", size: 101, modified: 5) == nil)
        #expect(reloaded.counts("w/b.epub", size: 100, modified: 5) == nil)
        // The reader of an EPUB: the classification, then the user's choice wins.
        #expect(reloaded.kind("w/a.epub") == nil)
        reloaded.setAutoKind("w/a.epub", EbookInfoCache.kindComic)
        #expect(reloaded.kind("w/a.epub") == "COMIC")
        reloaded.setUserKind("w/a.epub", EbookInfoCache.kindText)
        #expect(EbookInfoCache(file: file).kind("w/a.epub") == "TEXT")
    }
}
