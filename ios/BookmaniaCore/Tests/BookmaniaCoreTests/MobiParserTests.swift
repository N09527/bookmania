import Foundation
import Testing
@testable import BookmaniaCore

@Suite struct MobiParserTests {
    private func open(_ name: String) throws -> Publication {
        try BookOpener.open(try Fixtures.source(name), extension: name.afterLast(".", missing: ""))
    }

    /// Text of all spine documents, in reading order.
    private func allText(_ pub: Publication) throws -> String {
        try pub.spine.map { item in
            let bytes = try #require(try pub.open(item.href))
            return Markup.parse(bytes, mode: .html).text
        }.joined(separator: "\n")
    }

    /// Every paragraph marker 【第N段】 (N = 1..count) appears exactly once, in order.
    private func expectParagraphsComplete(_ text: String, _ count: Int) {
        let fw = Array("０１２３４５６７８９")
        let found = Rx("【第([０-９]+)段】").findAll(text).map { m in
            Int(String(m.group(1).map { Character(String(fw.firstIndex(of: $0)!)) }))!
        }
        #expect(found == Array(1 ... count))
    }

    @Test func azw3IsRebuiltCompletely() throws {
        let pub = try open("zh-horizontal.azw3")
        defer { pub.close() }
        #expect(pub.format == .kf8)
        #expect(pub.metadata.title == "橫排測試書")
        #expect(pub.metadata.authors == ["Bookmania 測試"])
        #expect(pub.spine.count >= 3)
        #expect(pub.writingModeHint == .horizontal)
        expectParagraphsComplete(try allText(pub), 120)
        #expect(pub.toc.map(\.title) == ["第1章", "第2章", "第3章"])
        for entry in pub.toc {
            let href = try #require(entry.href)
            #expect(try pub.open(href) != nil)
        }
        #expect(ContentClassifier.classify(pub) == .text)
    }

    @Test func verticalAzw3KeepsDirectionAndWritingMode() throws {
        let pub = try open("zh-vertical.azw3")
        defer { pub.close() }
        #expect(pub.format == .kf8)
        #expect(pub.readingDirection == .rtl)
        #expect(pub.writingModeHint == .vertical)
        expectParagraphsComplete(try allText(pub), 120)
        // every kindle: link is rewritten to a book path, and those paths resolve
        let link = Rx(##"(?:src|href)="\.\./((?:images|styles|fonts)/[^"#]+)""##)
        for item in pub.spine {
            let html = utf8(try #require(try pub.open(item.href)))
            #expect(!html.contains("kindle:"))
            for m in link.findAll(html) { #expect(try pub.open(m.group(1)) != nil, "\(m.group(1))") }
        }
        if let cover = pub.metadata.coverHref { #expect(try pub.open(cover) != nil) }
    }

    @Test func jointMobiUsesItsKF8Part() throws {
        let pub = try open("zh-vertical-joint.mobi")
        defer { pub.close() }
        #expect(pub.format == .kf8)
        expectParagraphsComplete(try allText(pub), 120)
    }

    @Test func mobi6IsSplitIntoSectionsWithAllText() throws {
        let pub = try open("zh-horizontal-mobi6.mobi")
        defer { pub.close() }
        #expect(pub.format == .mobi)
        #expect(pub.metadata.title == "橫排測試書")
        #expect(pub.spine.count >= 3)
        expectParagraphsComplete(try allText(pub), 120)
    }

    @Test func mobi6TableOfContentsFromTheNCXIndex() throws {
        let pub = try open("zh-horizontal-mobi6.mobi")
        defer { pub.close() }
        #expect(pub.toc.map(\.title) == ["第1章", "第2章", "第3章"])
        for entry in pub.toc {
            let href = try #require(entry.href)
            let parts = href.split(separator: "#").map(String.init)
            let (path, anchor) = (parts[0], parts[1])
            let html = utf8(try #require(try pub.open(path)))
            // The entry points at an anchor in its section, at the start of the chapter's heading.
            let doc = Markup.parse(html, mode: .html)
            #expect(doc.allElements.contains { $0.attr("id") == anchor })
            let after = html.components(separatedBy: "id=\"\(anchor)\"").dropFirst().joined(separator: "id=\"\(anchor)\"")
            let number = entry.title.after("第").before("章")
            let text = String(Markup.parse(after, mode: .html).text.prefix(40))
                .replacingOccurrences(of: "１", with: "1").replacingOccurrences(of: "２", with: "2").replacingOccurrences(of: "３", with: "3")
            #expect(text.contains(number), "\(entry.title): \(text)")
        }
        #expect(pub.toc.map { e in pub.spine.firstIndex { $0.href == e.href!.before("#") } } == [0, 1, 2])
    }

    @Test func mobi6HasNoBlankSections() throws {
        for name in ["zh-horizontal-mobi6.mobi", "text-with-images-mobi6.mobi"] {
            let pub = try open(name)
            defer { pub.close() }
            for item in pub.spine {
                let doc = Markup.parse(try #require(try pub.open(item.href)), mode: .html)
                #expect(!doc.text.trimmed.isEmpty || doc.allElements.contains { $0.localName == "img" }, "\(name) \(item.href)")
            }
        }
    }

    @Test func mobi6ImagesAreRewrittenToBookPaths() throws {
        let pub = try open("text-with-images-mobi6.mobi")
        defer { pub.close() }
        let html = try pub.spine.map { utf8(try #require(try pub.open($0.href))) }.joined()
        let srcs = Rx(#"src="\.\./(images/\d{5}\.\w+)""#).findAll(html).map { $0.group(1) }
        #expect(srcs.count >= 3)
        for src in srcs { #expect((try pub.open(src)?.count ?? 0) > 100, "\(src)") }
    }

    @Test func mobi6ParagraphWidthAndHeightBecomeCSS() throws {
        #expect(Mobi6Publication.mobiBlockStyle(#"<p height="11pt" width="1em">"#) ==
            #"<p style="text-indent: 1em; -webkit-margin-before: 11pt; margin-block-start: 11pt;">"#)
        #expect(Mobi6Publication.mobiBlockStyle(#"<p height="0pt" width="-2em" style="color:red">"#) ==
            #"<p style="text-indent: -2em; -webkit-margin-start: 2em; margin-inline-start: 2em; color:red">"#)
        #expect(Mobi6Publication.mobiBlockStyle(#"<div width="20">"#) == #"<div width="20">"#)
        let pub = try open("zh-horizontal-mobi6.mobi")
        defer { pub.close() }
        let html = utf8(try #require(try pub.open(pub.spine[1].href)))
        #expect(html.contains("text-indent: 1em"))
        #expect(!Rx(#"<p[^>]*\swidth="#).containsMatch(html))
    }

    @Test func drmFlaggedMobiIsRefused() {
        #expect(bookError { _ = try open("drm-flagged.mobi") }?.drmScheme != nil)
    }
}

@Suite struct WritingModeDetectorTests {
    private func doc(_ htmlAttrs: String = "", body: String = "<p>文字</p>") -> [UInt8] {
        Array(#"<html xmlns="http://www.w3.org/1999/xhtml" \#(htmlAttrs)><head><title>t</title></head><body>\#(body)</body></html>"#.utf8)
    }

    private func detect(css: [String] = [], docs: [[UInt8]]? = nil, pwm: String? = nil,
                        direction: ReadingDirection = .default, languages: [String] = ["zh-Hant"]) -> WritingModeHint {
        WritingModeDetector.detect(stylesheets: css, firstDocuments: docs ?? [doc()], primaryWritingMode: pwm,
                                   direction: direction, languages: languages)
    }

    @Test func calibresHorizontalRlFillerDoesNotOverrideVerticalCSSOnTheRoot() {
        #expect(detect(css: [".calibre { -epub-writing-mode: vertical-rl; writing-mode: vertical-rl }"],
                       docs: [doc("class=\"calibre\"")], pwm: "horizontal-rl", direction: .rtl) == .vertical)
    }

    @Test func inlineStyleAndElementSelectorsOnHtmlOrBodyCount() {
        #expect(detect(docs: [doc("style=\"writing-mode: vertical-rl\"")]) == .vertical)
        #expect(detect(css: ["body { -webkit-writing-mode: vertical-rl }"]) == .vertical)
        let withStyle = utf8(doc(body: "<p>x</p>")).replacingOccurrences(of: "<head>", with: "<head><style>html{writing-mode:tb-rl}</style>")
        #expect(detect(docs: [Array(withStyle.utf8)]) == .vertical)
    }

    @Test func verticalMetadataIsUsedWhenTheCSSSaysNothingAboutTheRoot() {
        #expect(detect(pwm: "vertical-rl") == .vertical)
        #expect(detect(pwm: "horizontal-lr") == .horizontal)
    }

    @Test func anExplicitlyHorizontalRootWinsOverTheRightToLeftCJKFallback() {
        #expect(detect(css: ["html { writing-mode: horizontal-tb }", "div.title { writing-mode: vertical-rl }"], direction: .rtl) == .horizontal)
    }

    @Test func rightToLeftCJKBooksWithVerticalRulesElsewhereAreVertical() {
        let css = ["div.main { writing-mode: vertical-rl }"]
        #expect(detect(css: css, direction: .rtl) == .vertical)
        #expect(detect(css: css, pwm: "horizontal-rl", direction: .rtl) == .vertical)
        #expect(detect(css: css, direction: .ltr) == .horizontal)
        #expect(detect(css: css, direction: .rtl, languages: ["ar"]) == .horizontal)
    }

    @Test func noEvidenceMeansHorizontal() {
        #expect(detect() == .horizontal)
        #expect(detect(docs: [Array("not xml at all <<<".utf8)]) == .horizontal)
    }
}

@Suite struct FontInspectorTests {
    private func font(_ name: String) throws -> [UInt8] { try Fixtures.bytes("fonts/\(name)") }

    @Test func trueTypeFontWithVerticalMetricsAndVert() throws {
        let info = try FontInspector.inspect(try font("vertical-ok.ttf"))
        #expect(info.format == .trueType)
        #expect(info.hasVerticalMetrics)
        #expect(info.hasVerticalGlyphs)
        #expect(info.supportsVertical)
        // The Traditional Chinese name is preferred over the English one.
        #expect(info.familyName == "書狂測試直排")
    }

    @Test func fontWithoutVerticalDataIsReported() throws {
        let info = try FontInspector.inspect(try font("horizontal-only.ttf"))
        #expect(!info.hasVerticalMetrics)
        #expect(!info.hasVerticalGlyphs)
        #expect(!info.supportsVertical)
        #expect(info.familyName == "Bookmania Test Horizontal")
    }

    @Test func cffOpenTypeFontWithVrt2() throws {
        let info = try FontInspector.inspect(try font("vertical-cff.otf"))
        #expect(info.format == .openTypeCFF)
        #expect(info.supportsVertical)
        #expect(info.familyName == "Bookmania Test CFF")
    }

    @Test func collectionsWOFFAndOtherFilesAreRefused() throws {
        #expect(throws: InvalidFontError.self) { try FontInspector.inspect(Array("ttcf".utf8) + [UInt8](repeating: 0, count: 12)) }
        #expect(throws: InvalidFontError.self) { try FontInspector.inspect(Array("wOF2".utf8) + [UInt8](repeating: 0, count: 40)) }
        let epub = try Fixtures.bytes("zh-vertical.epub")
        #expect(throws: InvalidFontError.self) { try FontInspector.inspect(epub) }
        #expect(throws: InvalidFontError.self) { try FontInspector.inspect([UInt8](repeating: 0, count: 5)) }
        // A real font cut short: the table directory points outside the file.
        let cut = Array(try font("vertical-ok.ttf").prefix(200))
        #expect(throws: InvalidFontError.self) { try FontInspector.inspect(cut) }
    }
}
