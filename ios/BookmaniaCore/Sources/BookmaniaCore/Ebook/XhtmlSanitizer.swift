import Foundation

/// Turns a book document into safe markup for the reader's web view (port of core/ebook `XhtmlSanitizer.kt`).
///
/// XHTML documents are parsed as XML, which keeps their structure (self-closing elements, CDATA, named entities);
/// `text/html` documents (MOBI 6 sections) are parsed as HTML, which understands `<br>` and `<img>` without a
/// closing slash. Both are cleaned and written out as HTML5 (`<!DOCTYPE html>`, served as text/html). The writer
/// emits explicit end tags, so `<title/>` or `<a id="x"/>` keep their meaning, and malformed XHTML never ends up as
/// an XML error page.
///
/// Scripts can never run in the reader (sandboxed frames and a strict CSP); removing them here is one more layer.
/// SVG documents are kept as SVG.
public enum XhtmlSanitizer {

    public struct Result: Equatable {
        public let text: String
        public let mediaType: String
    }

    /// Removed together with their content.
    private static let drop: Set<String> = [
        "script", "iframe", "frame", "frameset", "embed", "applet", "base", "portal",
        "form", "input", "button", "select", "textarea", "option", "datalist", "keygen",
    ]

    /// Removed, but their children are kept (fallback content).
    private static let unwrap: Set<String> = ["object"]

    private static let voidElements: Set<String> = ["area", "br", "col", "hr", "img", "link", "meta", "source", "track", "wbr", "param"]

    private static let rawTextElements: Set<String> = ["style"]

    private static let urlAttrs: Set<String> = [
        "href", "src", "xlink:href", "action", "formaction", "poster", "background", "data",
        "cite", "longdesc", "srcset", "lowsrc", "dynsrc", "usemap", "manifest", "ping",
    ]

    private static let badURL = Rx(#"^(?:javascript|vbscript|livescript|data:(?:text/html|application/(?:x-)?(?:xhtml|javascript|ecmascript)))"#, ignoreCase: true)

    private static let empty = "<!DOCTYPE html>\n<html><head></head><body></body></html>"

    public static func sanitize(_ bytes: [UInt8], isHtml: Bool = false) -> Result {
        let doc = Markup.parse(bytes, mode: isHtml ? .html : .xml)
        guard let root = Markup.root(doc) else { return Result(text: empty, mediaType: "text/html") }
        clean(root)
        if root.localName == "svg" {
            var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            writeXml(root, &sb)
            return Result(text: sb, mediaType: "image/svg+xml")
        }
        let html: MLElement
        if root.localName == "html" {
            html = root
        } else {
            html = MLElement("html")
            html.append(.element(MLElement("head")))
            let body = MLElement("body")
            body.append(.element(root))
            html.append(.element(body))
        }
        var sb = "<!DOCTYPE html>\n"
        sb.reserveCapacity(bytes.count + 64)
        write(.element(html), &sb)
        return Result(text: sb, mediaType: "text/html")
    }

    private static func clean(_ root: MLElement) {
        cleanChildren(root)
        cleanAttributes(root)
    }

    /// Removes dropped elements, cleans attributes and turns style content into raw data, depth first.
    private static func cleanChildren(_ el: MLElement) {
        var kept = [MLNode]()
        for child in el.children {
            guard case let .element(c) = child else {
                kept.append(child)
                continue
            }
            let name = c.localName
            if drop.contains(name) { continue }
            if name == "meta" && c.hasAttr("http-equiv") { continue }
            if name == "link" && !isStylesheetLink(c) { continue }
            cleanAttributes(c)
            if rawTextElements.contains(name) {
                var css = ""
                for n in c.children {
                    switch n {
                    case let .data(d): css += d
                    case let .text(t): css += t
                    default: break
                    }
                }
                c.children = css.isEmpty ? [] : [.data(css)]
            } else {
                cleanChildren(c)
            }
            if unwrap.contains(name) {
                for n in c.children {
                    if case let .element(x) = n { x.parent = el }
                    kept.append(n)
                }
            } else {
                kept.append(child)
            }
        }
        el.children = kept
    }

    private static func cleanAttributes(_ el: MLElement) {
        el.attributes.removeAll { attr in
            let k = attr.name.lowercased()
            if k.hasPrefix("on") || k == "srcdoc" || k == "formaction" { return true }
            if urlAttrs.contains(k) {
                let compact = String(String.UnicodeScalarView(attr.value.unicodeScalars.filter {
                    !($0.properties.isWhitespace || $0.properties.generalCategory == .control)
                }))
                return badURL.containsMatch(compact)
            }
            return false
        }
        // HTML only honours `lang`; XHTML books often only set `xml:lang`. CJK glyph choice (punctuation position in
        // vertical text) depends on it.
        if el.hasAttr("xml:lang") && !el.hasAttr("lang") { el.attributes.append(("lang", el.attr("xml:lang"))) }
    }

    private static func isStylesheetLink(_ el: MLElement) -> Bool {
        let rel = el.attr("rel").lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        let href = el.attr("href").trimmed
        return rel.contains("stylesheet") && !href.isEmpty && !BookPaths.isExternal(href)
    }

    private static func write(_ node: MLNode, _ sb: inout String) {
        switch node {
        case let .element(el):
            sb += "<" + el.name
            for a in el.attributes {
                sb += " " + a.name + "=\""
                escape(a.value, &sb, attribute: true)
                sb += "\""
            }
            sb += ">"
            if voidElements.contains(el.localName) && el.children.isEmpty { return }
            for c in el.children { write(c, &sb) }
            sb += "</" + el.name + ">"
        case let .data(d):
            sb += d.replacingOccurrences(of: "</", with: "<\\/")
        case let .text(t):
            escape(t, &sb, attribute: false)
        case .comment:
            break
        }
    }

    /// SVG documents are written back as XML (empty elements self-closed).
    private static func writeXml(_ el: MLElement, _ sb: inout String) {
        sb += "<" + el.name
        for a in el.attributes {
            sb += " " + a.name + "=\""
            escape(a.value, &sb, attribute: true)
            sb += "\""
        }
        if el.children.isEmpty {
            sb += " />"
            return
        }
        sb += ">"
        for c in el.children {
            switch c {
            case let .element(x): writeXml(x, &sb)
            case let .text(t): escape(t, &sb, attribute: false)
            case let .data(d): escape(d, &sb, attribute: false)
            case .comment: break
            }
        }
        sb += "</" + el.name + ">"
    }

    private static func escape(_ s: String, _ sb: inout String, attribute: Bool) {
        for c in s.unicodeScalars {
            switch c {
            case "&": sb += "&amp;"
            case "<": sb += "&lt;"
            case ">": sb += "&gt;"
            case "\"" where attribute: sb += "&quot;"
            default: sb.unicodeScalars.append(c)
            }
        }
    }
}
