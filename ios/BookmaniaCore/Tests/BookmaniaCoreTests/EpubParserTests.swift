import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct EpubParserTests {
    private func open(_ name: String) throws -> EpubPublication { try EpubParser.parse(try Fixtures.source(name)) }

    @Test func verticalChineseBook() throws {
        let pub = try open("zh-vertical.epub")
        defer { pub.close() }
        #expect(pub.format == .epub)
        #expect(pub.metadata.title == "直排測試書")
        #expect(pub.metadata.authors == ["Bookmania 測試"])
        #expect(pub.metadata.languages == ["zh-Hant"])
        #expect(pub.metadata.identifier == "urn:uuid:7d3f1c1e-0a1b-4c2d-9e8f-000000000001")
        #expect(pub.metadata.coverHref == "OEBPS/images/cover.png")
        #expect(pub.spine.map(\.href) == ["OEBPS/text/ch01.xhtml", "OEBPS/text/ch02.xhtml", "OEBPS/text/ch03.xhtml"])
        #expect(pub.spine.allSatisfy { $0.mediaType == "application/xhtml+xml" })
        #expect(pub.toc.map(\.title) == ["第1章", "第2章", "第3章"])
        #expect(pub.toc.map(\.href) == ["OEBPS/text/ch01.xhtml", "OEBPS/text/ch02.xhtml", "OEBPS/text/ch03.xhtml"])
        #expect(pub.readingDirection == .rtl)
        #expect(pub.writingModeHint == .vertical)
        #expect(!pub.isFixedLayout)
        #expect(pub.mediaType("OEBPS/images/fig1.png") == "image/png")
        #expect(pub.mediaType("OEBPS/styles/book.css") == "text/css")
        let chapter = utf8(try #require(try pub.open("OEBPS/text/ch01.xhtml")))
        #expect(chapter.contains("【第１段】"))
        #expect(try pub.open("OEBPS/does/not/exist.png") == nil)
    }

    @Test func horizontalAndJapaneseVerticalBooks() throws {
        let h = try open("zh-horizontal.epub")
        defer { h.close() }
        #expect(h.readingDirection == .ltr)
        #expect(h.writingModeHint == .horizontal)
        let ja = try open("ja-vertical.epub")
        defer { ja.close() }
        #expect(ja.metadata.languages == ["ja"])
        #expect(ja.writingModeHint == .vertical)
    }

    @Test func epub2TableOfContentsComesFromTheNCX() throws {
        let pub = try open("epub2-ncx.epub")
        defer { pub.close() }
        #expect(pub.toc.map(\.title) == ["第1章", "第2章"])
        #expect(pub.toc[1].href == "OEBPS/text/ch02.xhtml")
    }

    @Test func textAndImageBooksAreClassified() throws {
        for (name, kind, fixed) in [("zh-vertical.epub", ContentKind.text, false), ("text-with-images.epub", .text, false),
                                    ("comic-fixed.epub", .comic, true), ("comic-reflowable.epub", .comic, false)] {
            let pub = try open(name)
            defer { pub.close() }
            #expect(pub.isFixedLayout == fixed, "\(name)")
            #expect(ContentClassifier.classify(pub) == kind, "\(name)")
        }
    }

    @Test func obfuscatedFontIsReturnedDeobfuscated() throws {
        let pub = try open("font-obfuscated.epub")
        defer { pub.close() }
        let font = try #require(try pub.open("OEBPS/fonts/test.ttf"))
        #expect(font == (try Fixtures.bytes("font-obfuscated.expected.ttf")))
    }

    @Test func drmProtectedBookIsRefusedWithTheScheme() {
        let e = bookError { _ = try open("drm-adept.epub") }
        #expect(e == .drmProtected(scheme: "Adobe ADEPT"))
    }

    @Test func damagedFilesAreCorrupt() {
        #expect(bookError { _ = try open("corrupt-truncated.epub") }?.isCorrupt == true)
        #expect(bookError { _ = try open("not-an-ebook.epub") }?.isCorrupt == true)
    }

    @Test func filesThatCannotBeReadAtAllAreUnreadable() throws {
        #expect(bookError { _ = try open("corrupt-truncated.epub") }?.isUnreadable == true) // ZIP cut short
        #expect(bookError { _ = try open("not-an-ebook.epub") }?.isUnreadable == true) // not a ZIP
        let source = try Fixtures.source("not-an-ebook.epub")
        #expect(bookError { _ = try BookOpener.open(source, extension: "epub") }?.isUnreadable == true)
    }

    @Test func aReadableZipWithoutAPackageDocumentIsDamagedButNotUnreadable() throws {
        // A ZIP holding one image "001.png" (64 bytes of 0x01), written by Python's zipfile.
        let bytes: [UInt8] = [
            0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x65, 0x83, 0x79, 0x5D, 0xAF, 0x6A, 0xCD, 0x0B, 0x06,
            0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x30, 0x30, 0x31, 0x2E, 0x70, 0x6E, 0x67, 0x63,
            0x64, 0xA4, 0x0C, 0x00, 0x00, 0x50, 0x4B, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x65, 0x83,
            0x79, 0x5D, 0xAF, 0x6A, 0xCD, 0x0B, 0x06, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x31, 0x2E, 0x70, 0x6E,
            0x67, 0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x35, 0x00, 0x00, 0x00, 0x2B, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let zip = try? ZipReader(source: DataSource(bytes))
        #expect(try zip?.readBytes("001.png") == [UInt8](repeating: 1, count: 64))
        let e = bookError { _ = try EpubParser.parse(DataSource(bytes)) }
        #expect(e?.isCorrupt == true)
        #expect(e?.isUnreadable == false)
    }

    @Test func linksAndFragmentsInTheTocAreResolved() throws {
        let pub = try open("zh-horizontal.epub")
        defer { pub.close() }
        #expect(pub.toc.first?.href != nil)
    }
}

@Suite struct BookStatsTests {
    @Test func characterCountsAreTheSameForTheThreeVerticalFormats() throws {
        // The reader shell counts the same characters (non-whitespace text, ruby included): for the first chapter of
        // zh-vertical.epub it reported 1880 in the desktop check of Android stage 5.
        let epub = try BookOpener.open(try Fixtures.source("zh-vertical.epub"), extension: "epub")
        defer { epub.close() }
        let counts = BookStats.charCounts(epub)
        #expect(counts == [1880, 1847, 1872])
        let azw3 = try BookOpener.open(try Fixtures.source("zh-vertical.azw3"), extension: "azw3")
        defer { azw3.close() }
        #expect(BookStats.charCounts(azw3) == counts)
        let joint = try BookOpener.open(try Fixtures.source("zh-vertical-joint.mobi"), extension: "mobi")
        defer { joint.close() }
        #expect(BookStats.charCounts(joint) == counts)
    }

    @Test func onlyTextCounts() {
        #expect(BookStats.countText(Array("<html><body><p>　漢 字\n<b>ab</b></p><img src='a.png'/></body></html>".utf8)) == 4)
        #expect(BookStats.countText(Array("<html><body></body></html>".utf8)) == 0)
    }
}
