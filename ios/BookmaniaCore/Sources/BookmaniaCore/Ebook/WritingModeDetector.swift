import Foundation

/// Works out whether a book is typeset vertically, for the reader's "follow the book" setting (port of core/ebook
/// `WritingModeDetector.kt`).
///
/// Evidence, strongest first:
/// 1. a `writing-mode` that applies to `html`/`body` of the first documents (inline style, or a CSS rule whose
///    selector matches them) — this is what a browser would actually render;
/// 2. a vertical primary writing mode in the metadata (OPF `primary-writing-mode`, MOBI EXTH 525);
/// 3. right-to-left CJK books with vertical rules anywhere.
///
/// A *horizontal* primary writing mode is not used as evidence: Calibre writes `horizontal-rl` into every
/// right-to-left KF8 book that has none, including books whose CSS is vertical.
public enum WritingModeDetector {
    private static let verticalDecl = Rx(#"(?:-epub-|-webkit-)?writing-mode\s*:\s*(?:vertical-rl|vertical-lr|tb-rl|tb)\b"#, ignoreCase: true)
    private static let horizontalDecl = Rx(#"(?:-epub-|-webkit-)?writing-mode\s*:\s*(?:horizontal-tb|lr-tb|lr)\b"#, ignoreCase: true)
    private static let cssRule = Rx(#"([^{}@;]+)\{([^{}]*)\}"#)
    private static let cssComment = Rx(#"/\*.*?\*/"#, dotAll: true)

    public static func detect<S: Sequence, D: Sequence>(
        stylesheets: S,
        firstDocuments: D,
        primaryWritingMode: String?,
        direction: ReadingDirection,
        languages: [String],
        documentsAreHtml: Bool = false
    ) -> WritingModeHint where S.Element == String, D.Element == [UInt8] {
        var vertical = [String]()
        var horizontal = [String]()
        for css in stylesheets { collect(css, &vertical, &horizontal) }
        var rootHorizontal = false
        for bytes in firstDocuments {
            let doc = Markup.parse(bytes, mode: documentsAreHtml ? .html : .xml)
            for style in doc.allElements where style.localName == "style" {
                let d = style.data
                collect(d.isEmpty ? style.text : d, &vertical, &horizontal)
            }
            for el in doc.allElements where el.localName == "html" || el.localName == "body" {
                let inline = el.attr("style")
                if verticalDecl.containsMatch(inline) || vertical.contains(where: { CSSSelector.matches(el, $0) }) {
                    return .vertical
                }
                if horizontalDecl.containsMatch(inline) || horizontal.contains(where: { CSSSelector.matches(el, $0) }) {
                    rootHorizontal = true
                }
            }
        }
        if rootHorizontal { return .horizontal }
        if primaryWritingMode?.lowercased().contains("vertical") == true { return .vertical }
        let cjk = languages.contains { $0.lowercased().hasPrefix("ja") || $0.lowercased().hasPrefix("zh") }
        return direction == .rtl && cjk && !vertical.isEmpty ? .vertical : .horizontal
    }

    private static func collect(_ css: String, _ vertical: inout [String], _ horizontal: inout [String]) {
        let text = cssComment.replace(css, with: " ")
        for m in cssRule.findAll(text) {
            let body = m.group(2)
            let isVertical: Bool
            if verticalDecl.containsMatch(body) {
                isVertical = true
            } else if horizontalDecl.containsMatch(body) {
                isVertical = false
            } else {
                continue
            }
            let selectors = m.group(1).split(separator: ",").map { $0.trimmed }.filter { !$0.isEmpty }
            if isVertical { vertical += selectors } else { horizontal += selectors }
        }
    }
}

extension Substring {
    var trimmed: String { String(self).trimmed }
}
