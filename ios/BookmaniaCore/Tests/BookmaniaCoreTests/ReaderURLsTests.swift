import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct ReaderURLsTests {
    @Test func routes() {
        #expect(ReaderURLs.route(URL(string: ReaderURLs.shellURL)!) == .shell("reader.html"))
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/shell/other.js")!) == nil)
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/book/OEBPS/text/ch01.xhtml")!) == .book("OEBPS/text/ch01.xhtml"))
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/book/OEBPS/%E7%AC%AC%201.xhtml")!) == .book("OEBPS/第 1.xhtml"))
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/fonts/0123456789abcdef0123456789abcdef")!) == .font("0123456789abcdef0123456789abcdef"))
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/fonts/../x")!) == nil)
        #expect(ReaderURLs.route(URL(string: "https://reader/book/a.xhtml")!) == nil)
        #expect(ReaderURLs.route(URL(string: "bookmania://other/book/a.xhtml")!) == nil)
        #expect(ReaderURLs.route(URL(string: "bookmania://reader/etc/passwd")!) == nil)
    }

    @Test func bookURLsRoundTrip() throws {
        let url = ReaderURLs.bookURL("OEBPS/text/第 1章.xhtml", fragment: "注1")
        #expect(url.hasPrefix("bookmania://reader/book/OEBPS/text/%E7%AC%AC%201"))
        let parsed = try #require(ReaderURLs.bookPath(of: url))
        #expect(parsed.path == "OEBPS/text/第 1章.xhtml")
        #expect(parsed.fragment == "注1")
        #expect(ReaderURLs.bookPath(of: "https://example.com/book/a.xhtml") == nil)
    }

    @Test func shellSettingsJSON() throws {
        var s = ShellSettings(vertical: true, rtl: true)
        s.lineHeight = 1.8
        s.background = "#202125"
        let json = s.json()
        #expect(json.contains("\"lineHeight\":1.8,"))
        #expect(json.contains("\"indent\":null"))
        #expect(json.contains("\"font\":null"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["vertical"] as? Bool == true)
        #expect(object["fontSize"] as? Int == 20)
        #expect((object["margins"] as? [String: Any])?["top"] as? Int == 32)
        s.font = ["kind": "imported", "url": ReaderURLs.fontURL("0123456789abcdef0123456789abcdef")]
        let withFont = try #require(try JSONSerialization.jsonObject(with: Data(s.json().utf8)) as? [String: Any])
        #expect((withFont["font"] as? [String: String])?["kind"] == "imported")
        #expect(ShellSettings.jsString("a\"b\\c\n") == "\"a\\\"b\\\\c\\n\"")
    }
}
