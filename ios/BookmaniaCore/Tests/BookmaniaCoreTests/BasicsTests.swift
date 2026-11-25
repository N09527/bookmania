import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct BookPathsTests {
    @Test func relativeLinksResolveAgainstTheDocumentDirectory() {
        #expect(BookPaths.resolve("OEBPS/text/ch01.xhtml", "../images/fig%201.png") == "OEBPS/images/fig 1.png")
        #expect(BookPaths.resolve("OEBPS/text/ch01.xhtml", "ch02.xhtml#p2") == "OEBPS/text/ch02.xhtml#p2")
        #expect(BookPaths.resolve("OEBPS/text/ch01.xhtml", "#note1") == "OEBPS/text/ch01.xhtml#note1")
        #expect(BookPaths.resolve("OEBPS/content.opf", "/root.css") == "root.css")
        #expect(BookPaths.resolve("a.xhtml", "../../escape.png") == nil)
        #expect(BookPaths.resolve("a.xhtml", "https://example.com/") == nil)
        #expect(BookPaths.resolve("a.xhtml", "mailto:x@example.com") == nil)
    }

    @Test func externalDetection() {
        #expect(BookPaths.isExternal("https://example.com"))
        #expect(BookPaths.isExternal("javascript:alert(1)"))
        #expect(!BookPaths.isExternal("text/ch01.xhtml"))
        #expect(BookPaths.isExternal("C:/x"))
        #expect(!BookPaths.isExternal("ch01.xhtml#a:b"))
    }

    @Test func percentDecodingKeepsPlusSignsAndHandlesUTF8() {
        #expect(BookPaths.percentDecode("a+b%E6%B8%AC.xhtml") == "a+b測.xhtml")
        #expect(BookPaths.percentDecode("bad%zz") == "bad%zz")
        #expect(BookPaths.percentEncodePath("text/第 1.xhtml") == "text/%E7%AC%AC%201.xhtml")
    }
}

@Suite struct FormatDetectorTests {
    @Test func formatsAreRecognisedFromContent() throws {
        let cases: [(String, BookFormat)] = [
            ("zh-vertical.epub", .epub), ("corrupt-truncated.epub", .epub), ("zh-horizontal-mobi6.mobi", .mobi),
            ("zh-vertical.azw3", .mobi), ("zh-vertical-joint.mobi", .mobi),
        ]
        for (name, format) in cases {
            let source = try Fixtures.source(name)
            defer { source.close() }
            #expect(try FormatDetector.detect(source, extension: name.afterLast(".", missing: "")) == format, "\(name)")
        }
        let notBook = try Fixtures.source("not-an-ebook.epub")
        defer { notBook.close() }
        #expect(try FormatDetector.detect(notBook, extension: "epub") == .unknown)
        #expect(try FormatDetector.detect(DataSource([0x43, 0x4F, 0x4E, 0x54, 2, 0, 0, 0])) == .kfx)
    }
}

@Suite struct ZipReaderTests {
    @Test func entriesAndContents() throws {
        let zip = try ZipReader(source: try Fixtures.source("zh-vertical.epub"))
        defer { zip.close() }
        #expect(try zip.readText("mimetype") == "application/epub+zip")
        #expect(zip.has("META-INF/container.xml"))
        #expect(zip.has("meta-inf/CONTAINER.xml")) // case-insensitive fallback
        #expect(zip.find("missing") == nil)
    }

    @Test func oversizedEntriesAreRefused() throws {
        let zip = try ZipReader(source: try Fixtures.source("zh-vertical.epub"), limits: .init(maxEntrySize: 10))
        defer { zip.close() }
        let e = bookError { _ = try zip.readBytes("OEBPS/content.opf") }
        #expect(e?.isCorrupt == true)
    }
}

@Suite struct InflateTests {
    static let text = Array(String(repeating: "Bookmania 測試 ", count: 40).utf8)

    @Test func zlibAndGzip() throws {
        let zlib: [UInt8] = [0x78, 0xDA, 0x73, 0xCA, 0xCF, 0xCF, 0xCE, 0x4D, 0xCC, 0xCB, 0x4C, 0x54, 0x78, 0xB6, 0x63, 0xCD, 0x8B,
                             0x95, 0xCB, 0x14, 0x9C, 0x46, 0x05, 0x46, 0x05, 0x06, 0x9F, 0x00, 0x00, 0xB3, 0x37, 0x4C, 0xE0]
        #expect(try Inflate.zlib(zlib, maxOutput: 1 << 20) == Self.text)
        let gzip: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x73, 0xCA, 0xCF, 0xCF, 0xCE, 0x4D,
                             0xCC, 0xCB, 0x4C, 0x54, 0x78, 0xB6, 0x63, 0xCD, 0x8B, 0x95, 0xCB, 0x14, 0x9C, 0x46, 0x05, 0x46,
                             0x05, 0x06, 0x9F, 0x00, 0x00, 0x82, 0x84, 0xF5, 0xAB, 0xA8, 0x02, 0x00, 0x00]
        #expect(try Inflate.gzip(gzip, maxOutput: 1 << 20) == Self.text)
        // The output limit is enforced.
        #expect(bookError { _ = try Inflate.zlib(zlib, maxOutput: 100) }?.isCorrupt == true)
        // Truncated data fails instead of returning part of the text silently.
        #expect(bookError { _ = try Inflate.zlib(Array(zlib.prefix(20)), maxOutput: 1 << 20) }?.isCorrupt == true)
    }

    @Test func sha1() {
        let hex = SHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
        let long = SHA1.hash(Array(String(repeating: "a", count: 1000).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(long == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }
}

@Suite struct XhtmlSanitizerTests {
    private func clean(_ xml: String) -> String { XhtmlSanitizer.sanitize(Array(xml.utf8)).text }

    @Test func scriptsHandlersAndJavascriptLinksAreRemoved() {
        let out = clean("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title/><script>alert(1)</script></head>
            <body onload="x()"><p onclick="y()">文<a href="javascript:alert(2)">連結</a><a href=" JaVa
            Script:alert(3)">x</a><a href="ch02.xhtml#a">ok</a></p><iframe src="https://example.com/"/>
            <form action="https://e.com"><input name="q"/></form></body></html>
            """)
        #expect(!out.contains("<script"))
        #expect(!out.contains("alert"))
        #expect(!out.contains("onload"))
        #expect(!out.contains("onclick"))
        #expect(!out.contains("<iframe"))
        #expect(!out.contains("<form"))
        #expect(out.contains("href=\"ch02.xhtml#a\""))
        #expect(out.contains("<title></title>"))
        #expect(out.hasPrefix("<!DOCTYPE html>"))
    }

    @Test func xhtmlStructureSurvivesHTMLSerialisation() {
        let out = clean("""
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-Hant"><head>
            <style type="text/css"><![CDATA[ p > a { color: red } ]]></style></head>
            <body><p>一<br/>二<a id="anchor"/>三&#160;四</p><div/></body></html>
            """)
        #expect(out.contains("p > a { color: red }"))
        #expect(out.contains("一<br>二<a id=\"anchor\"></a>三"))
        #expect(out.contains("<div></div>"))
        #expect(out.contains("lang=\"zh-Hant\""))
        #expect(!out.contains("</br>"))
    }

    @Test func htmlDocumentsAreParsedAsHTML() {
        let html = """
            <html><head><guide><reference type="toc" title="x" filepos=0000000012 /></guide></head>
            <body><p width="1em">一<br>二<img src="../images/00001.jpg" width=500>三<p>四&nbsp;五</body></html>
            """
        let out = XhtmlSanitizer.sanitize(Array(html.utf8), isHtml: true).text
        #expect(out.contains("一<br>二<img src=\"../images/00001.jpg\" width=\"500\">三</p><p>四\u{00A0}五</p>"))
        #expect(!out.contains("</br>"))
        #expect(!out.contains("</img>"))
        // The same markup parsed as XML would nest everything inside <br> and <img>.
        #expect(XhtmlSanitizer.sanitize(Array(html.utf8)).text.contains("</img>"))
    }

    @Test func objectIsUnwrappedAndSVGDocumentsStaySVG() {
        #expect(clean(#"<html><body><object data="x.svg" type="image/svg+xml"><img src="x.png"/></object></body></html>"#)
            .contains("<img src=\"x.png\">"))
        let svg = XhtmlSanitizer.sanitize(Array(#"<svg xmlns="http://www.w3.org/2000/svg" onload="evil()"><script>evil()</script><image href="a.png"/></svg>"#.utf8))
        #expect(svg.mediaType == "image/svg+xml")
        #expect(!svg.text.contains("evil"))
    }
}
