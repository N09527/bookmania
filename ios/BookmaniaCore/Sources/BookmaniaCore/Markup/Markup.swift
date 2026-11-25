import Foundation

/// A forgiving XML / HTML parser for book documents, standing in for Jsoup on the Android side.
///
/// - XML mode (XHTML, OPF, NCX, navigation documents): an end tag closes the nearest open element with the same
///   name; self-closing tags (`<a id="x"/>`) are empty elements; tag and attribute names keep their case.
/// - HTML mode (MOBI 6 sections): names are lower-cased, void elements (`<br>`, `<img>`) never take children,
///   `script` and `style` are raw text, a new block closes an open `<p>` and a new `<li>` an open `<li>`, and the
///   result is always `html` > `head` + `body`.
///
/// Malformed markup never fails: unknown end tags are ignored and open elements are closed at the end.
public final class MLElement {
    public let name: String
    public var attributes: [(name: String, value: String)]
    public var children: [MLNode] = []
    public weak var parent: MLElement?

    public init(_ name: String, attributes: [(name: String, value: String)] = []) {
        self.name = name
        self.attributes = attributes
    }

    /// Local name without a namespace prefix, lower-cased (`dc:title` → `title`).
    public var localName: String { name.after(":").lowercased() }

    /// Attribute value (case-insensitive name), "" when missing.
    public func attr(_ key: String) -> String {
        let k = key.lowercased()
        return attributes.first { $0.name.lowercased() == k }?.value ?? ""
    }

    public func hasAttr(_ key: String) -> Bool {
        let k = key.lowercased()
        return attributes.contains { $0.name.lowercased() == k }
    }

    public func setAttr(_ key: String, _ value: String) {
        let k = key.lowercased()
        if let i = attributes.firstIndex(where: { $0.name.lowercased() == k }) {
            attributes[i].value = value
        } else {
            attributes.append((key, value))
        }
    }

    public func removeAttr(_ key: String) {
        let k = key.lowercased()
        attributes.removeAll { $0.name.lowercased() == k }
    }

    public func append(_ node: MLNode) {
        if case let .element(e) = node { e.parent = self }
        children.append(node)
    }

    public var childElements: [MLElement] {
        children.compactMap { if case let .element(e) = $0 { return e } else { return nil } }
    }

    public func childrenNamed(_ local: String) -> [MLElement] { childElements.filter { $0.localName == local } }

    public func firstChildNamed(_ local: String) -> MLElement? { childElements.first { $0.localName == local } }

    /// This element and all descendants, in document order.
    public var allElements: [MLElement] {
        var out = [MLElement]()
        func walk(_ e: MLElement) {
            out.append(e)
            for c in e.children { if case let .element(x) = c { walk(x) } }
        }
        walk(self)
        return out
    }

    /// All descendants (including this element) with the given local name.
    public func descendantsNamed(_ local: String) -> [MLElement] { allElements.filter { $0.localName == local } }

    /// Every text node (CDATA included, raw `script`/`style` data excluded), unmodified.
    public var wholeText: String {
        var s = ""
        func walk(_ e: MLElement) {
            for c in e.children {
                switch c {
                case let .text(t): s += t
                case let .element(x): walk(x)
                default: break
                }
            }
        }
        walk(self)
        return s
    }

    /// Text with white space collapsed and trimmed, a space between block elements (like Jsoup's `text()`).
    public var text: String {
        var s = ""
        func walk(_ e: MLElement) {
            for c in e.children {
                switch c {
                case let .text(t): s += t
                case let .element(x):
                    let block = MLElement.textBlocks.contains(x.localName)
                    if block { s += " " }
                    walk(x)
                    if block { s += " " }
                default: break
                }
            }
        }
        walk(self)
        return MLElement.collapse(s)
    }

    /// Raw data of `script`/`style` children (HTML mode).
    public var data: String {
        children.compactMap { if case let .data(d) = $0 { return d } else { return nil } }.joined()
    }

    public var parentElement: MLElement? { parent }

    static let textBlocks: Set<String> = ["p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th",
                                          "blockquote", "section", "article", "header", "footer", "dt", "dd", "pre", "hr",
                                          "ul", "ol", "table", "body", "title", "head", "nav", "aside", "figure", "figcaption"]

    static func collapse(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

public enum MLNode {
    case element(MLElement)
    case text(String)
    /// Raw text of `script`/`style` (HTML mode), written back unescaped.
    case data(String)
    case comment(String)
}

public enum Markup {
    public enum Mode { case xml, html }

    private static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link",
                                             "meta", "param", "source", "track", "wbr", "basefont", "bgsound", "frame", "image"]
    private static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes"]
    private static let rcData: Set<String> = ["title", "textarea"]
    private static let closesP: Set<String> = ["address", "article", "aside", "blockquote", "center", "details", "dialog",
                                                "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form",
                                                "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
                                                "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul",
                                                "li", "dd", "dt", "listing", "plaintext"]
    private static let scopeBoundary: Set<String> = ["html", "table", "td", "th", "caption", "marquee", "object", "applet", "button"]

    /// Parses bytes (UTF-8, or UTF-16 with a byte order mark). Returns the document node (name "#document").
    public static func parse(_ bytes: [UInt8], mode: Mode) -> MLElement {
        parse(decodeText(bytes), mode: mode)
    }

    public static func decodeText(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            return String(data: Data(bytes), encoding: .utf16BigEndian) ?? utf8(bytes)
        }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            return String(data: Data(bytes), encoding: .utf16LittleEndian) ?? utf8(bytes)
        }
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return utf8(bytes[3...])
        }
        return utf8(bytes)
    }

    public static func parse(_ text: String, mode: Mode) -> MLElement {
        var parser = Parser(chars: Array(text.unicodeScalars), html: mode == .html)
        parser.run()
        if mode == .html { normalizeHtml(parser.document) }
        return parser.document
    }

    /// First element child of a document (the root element), if any.
    public static func root(_ document: MLElement) -> MLElement? { document.childElements.first }

    private struct Parser {
        let chars: [Unicode.Scalar]
        let html: Bool
        let document = MLElement("#document")
        var stack: [MLElement]
        var i = 0
        var textBuffer = ""

        init(chars: [Unicode.Scalar], html: Bool) {
            self.chars = chars
            self.html = html
            self.stack = [document]
        }

        var current: MLElement { stack[stack.count - 1] }

        mutating func flushText() {
            if !textBuffer.isEmpty {
                current.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        func startsWith(_ s: String, at p: Int, caseInsensitive: Bool = false) -> Bool {
            var k = p
            for c in s.unicodeScalars {
                guard k < chars.count else { return false }
                let a = chars[k]
                if caseInsensitive {
                    if lower(a) != lower(c) { return false }
                } else if a != c {
                    return false
                }
                k += 1
            }
            return true
        }

        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
            (c.value >= 65 && c.value <= 90) ? Unicode.Scalar(c.value + 32)! : c
        }

        func find(_ s: String, from p: Int, caseInsensitive: Bool = false) -> Int? {
            var k = p
            while k < chars.count {
                if startsWith(s, at: k, caseInsensitive: caseInsensitive) { return k }
                k += 1
            }
            return nil
        }

        func string(_ from: Int, _ to: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: chars[from ..< max(from, min(to, chars.count))])
            return String(v)
        }

        static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }

        mutating func run() {
            while i < chars.count {
                let c = chars[i]
                if c == "<" {
                    if startsWith("<!--", at: i) {
                        flushText()
                        let end = find("-->", from: i + 4) ?? chars.count
                        current.append(.comment(string(i + 4, end)))
                        i = min(chars.count, end + 3)
                    } else if startsWith("<![CDATA[", at: i) {
                        let end = find("]]>", from: i + 9) ?? chars.count
                        textBuffer += string(i + 9, end)
                        i = min(chars.count, end + 3)
                    } else if startsWith("<!", at: i) || startsWith("<?", at: i) {
                        flushText()
                        let end = find(">", from: i + 2) ?? chars.count
                        i = min(chars.count, end + 1)
                    } else if startsWith("</", at: i), i + 2 < chars.count, isNameStart(chars[i + 2]) {
                        flushText()
                        endTag()
                    } else if i + 1 < chars.count, isNameStart(chars[i + 1]) {
                        flushText()
                        startTag()
                    } else {
                        textBuffer += "<"
                        i += 1
                    }
                } else if c == "&" {
                    textBuffer += entity()
                } else {
                    textBuffer.unicodeScalars.append(c)
                    i += 1
                }
            }
            flushText()
        }

        func isNameStart(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || c == "_" || c == ":"
        }

        mutating func readName() -> String {
            let start = i
            while i < chars.count {
                let c = chars[i]
                if Parser.isSpace(c) || c == "/" || c == ">" || c == "<" || c == "=" { break }
                i += 1
            }
            let name = string(start, i)
            return html ? name.lowercased() : name
        }

        mutating func skipSpace() {
            while i < chars.count && Parser.isSpace(chars[i]) { i += 1 }
        }

        mutating func startTag() {
            i += 1 // '<'
            let name = readName()
            var attributes = [(name: String, value: String)]()
            var selfClosing = false
            while i < chars.count {
                skipSpace()
                guard i < chars.count else { break }
                let c = chars[i]
                if c == ">" { i += 1; break }
                if c == "/" {
                    if i + 1 < chars.count && chars[i + 1] == ">" { selfClosing = true; i += 2; break }
                    i += 1
                    continue
                }
                if c == "<" { break } // a broken tag: let the next tag start here
                var attrName = readName()
                if attrName.isEmpty { i += 1; continue }
                if html { attrName = attrName.lowercased() }
                skipSpace()
                var value = ""
                if i < chars.count && chars[i] == "=" {
                    i += 1
                    skipSpace()
                    if i < chars.count && (chars[i] == "\"" || chars[i] == "'") {
                        let quote = chars[i]
                        i += 1
                        let start = i
                        while i < chars.count && chars[i] != quote { i += 1 }
                        value = decodeEntities(string(start, i))
                        if i < chars.count { i += 1 }
                    } else {
                        let start = i
                        while i < chars.count && !Parser.isSpace(chars[i]) && chars[i] != ">" { i += 1 }
                        value = decodeEntities(string(start, i))
                    }
                }
                if !attributes.contains(where: { $0.name == attrName }) { attributes.append((attrName, value)) }
            }
            openElement(name, attributes, selfClosing: selfClosing)
        }

        mutating func openElement(_ name: String, _ attributes: [(name: String, value: String)], selfClosing: Bool) {
            if html {
                let local = name
                if local == "html" || local == "body" || local == "head" {
                    if stack.contains(where: { $0.name == local }) { return }
                }
                if Markup.closesP.contains(local) { closeInScope("p") }
                if local == "li" { closeInScope("li", boundaries: ["ol", "ul"]) }
                if local == "dd" || local == "dt" {
                    closeInScope("dd", boundaries: ["dl"])
                    closeInScope("dt", boundaries: ["dl"])
                }
            }
            let el = MLElement(name, attributes: attributes)
            current.append(.element(el))
            if html {
                if Markup.void.contains(name) { return }
                if Markup.rawText.contains(name) || Markup.rcData.contains(name) {
                    if selfClosing { return }
                    let end = find("</" + name, from: i, caseInsensitive: true) ?? chars.count
                    let content = string(i, end)
                    if Markup.rcData.contains(name) {
                        if !content.isEmpty { el.append(.text(decodeEntities(content))) }
                    } else if !content.isEmpty {
                        el.append(.data(content))
                    }
                    i = end
                    if i < chars.count {
                        let close = find(">", from: i) ?? chars.count
                        i = min(chars.count, close + 1)
                    }
                    return
                }
                if selfClosing { return }
            } else if selfClosing {
                return
            }
            stack.append(el)
        }

        mutating func closeInScope(_ name: String, boundaries: Set<String> = []) {
            var k = stack.count - 1
            while k > 0 {
                let n = stack[k].name
                if n == name {
                    stack.removeSubrange(k...)
                    return
                }
                if Markup.scopeBoundary.contains(n) || boundaries.contains(n) { return }
                k -= 1
            }
        }

        mutating func endTag() {
            i += 2 // '</'
            let name = readName()
            let close = find(">", from: i) ?? chars.count
            i = min(chars.count, close + 1)
            if html && Markup.void.contains(name) { return }
            var k = stack.count - 1
            while k > 0 {
                if stack[k].name == name {
                    stack.removeSubrange(k...)
                    return
                }
                k -= 1
            }
        }

        /// Decodes the character reference at `i` (which is '&'); returns the text to append.
        mutating func entity() -> String {
            let start = i
            i += 1
            if i < chars.count && chars[i] == "#" {
                i += 1
                var hex = false
                if i < chars.count && (chars[i] == "x" || chars[i] == "X") { hex = true; i += 1 }
                let digitsStart = i
                while i < chars.count {
                    let c = chars[i]
                    let ok = hex ? c.properties.isASCIIHexDigit : (c.value >= 48 && c.value <= 57)
                    if !ok { break }
                    i += 1
                }
                let digits = string(digitsStart, i)
                guard !digits.isEmpty, let value = UInt32(digits, radix: hex ? 16 : 10) else {
                    i = start + 1
                    return "&"
                }
                if i < chars.count && chars[i] == ";" { i += 1 }
                if value == 0 || value > 0x10FFFF { return "\u{FFFD}" }
                if let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
                return "\u{FFFD}"
            }
            let nameStart = i
            while i < chars.count && (chars[i].properties.isASCIIHexDigit || (chars[i].value >= 65 && chars[i].value <= 90) ||
                                      (chars[i].value >= 97 && chars[i].value <= 122) || (chars[i].value >= 48 && chars[i].value <= 57)) {
                i += 1
            }
            let name = string(nameStart, i)
            if i < chars.count && chars[i] == ";", let decoded = Markup.entities[name] {
                i += 1
                return decoded
            }
            if html, let decoded = Markup.entities[name], Markup.legacyEntities.contains(name) {
                return decoded
            }
            i = start + 1
            return "&"
        }

        func decodeEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            var sub = Parser(chars: Array(s.unicodeScalars), html: html)
            var out = ""
            while sub.i < sub.chars.count {
                if sub.chars[sub.i] == "&" {
                    out += sub.entity()
                } else {
                    out.unicodeScalars.append(sub.chars[sub.i])
                    sub.i += 1
                }
            }
            return out
        }
    }

    /// HTML mode: `html` > `head` + `body`, with everything outside them moved into `body`.
    private static func normalizeHtml(_ document: MLElement) {
        let htmlEl: MLElement
        if let existing = document.childElements.first(where: { $0.name == "html" }) {
            htmlEl = existing
        } else {
            htmlEl = MLElement("html")
        }
        let head = htmlEl.childElements.first { $0.name == "head" } ?? MLElement("head")
        let body = htmlEl.childElements.first { $0.name == "body" } ?? MLElement("body")
        var bodyNodes = [MLNode]()
        // Children of html that are neither head nor body belong in the body (in document order).
        for c in htmlEl.children {
            if case let .element(e) = c, e === head || e === body { continue }
            bodyNodes.append(c)
        }
        // Nodes outside html: before it they go first, after it they go last.
        var before = [MLNode](), after = [MLNode]()
        var seenHtml = false
        for c in document.children {
            if case let .element(e) = c, e === htmlEl { seenHtml = true; continue }
            if seenHtml { after.append(c) } else { before.append(c) }
        }
        let existingBody = body.children
        body.children = []
        for n in before + bodyNodes + existingBody + after { body.append(n) }
        htmlEl.children = []
        htmlEl.append(.element(head))
        htmlEl.append(.element(body))
        document.children = []
        document.append(.element(htmlEl))
    }

    /// HTML named character references that books use (Latin-1, typography, a few symbols). Unknown names are
    /// kept as written.
    static let entities: [String: String] = {
        var m: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "shy": "\u{00AD}",
            "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
            "lrm": "\u{200E}", "rlm": "\u{200F}", "ndash": "\u{2013}", "mdash": "\u{2014}", "lsquo": "\u{2018}",
            "rsquo": "\u{2019}", "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
            "dagger": "\u{2020}", "Dagger": "\u{2021}", "bull": "\u{2022}", "hellip": "\u{2026}", "permil": "\u{2030}",
            "prime": "\u{2032}", "Prime": "\u{2033}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "oline": "\u{203E}",
            "euro": "\u{20AC}", "trade": "\u{2122}", "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}",
            "darr": "\u{2193}", "harr": "\u{2194}", "minus": "\u{2212}", "times": "\u{00D7}", "divide": "\u{00F7}",
            "middot": "\u{00B7}", "deg": "\u{00B0}", "plusmn": "\u{00B1}", "micro": "\u{00B5}", "para": "\u{00B6}",
            "sect": "\u{00A7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
            "iexcl": "\u{00A1}", "iquest": "\u{00BF}", "cent": "\u{00A2}", "pound": "\u{00A3}", "yen": "\u{00A5}",
            "curren": "\u{00A4}", "brvbar": "\u{00A6}", "uml": "\u{00A8}", "ordf": "\u{00AA}", "ordm": "\u{00BA}",
            "not": "\u{00AC}", "macr": "\u{00AF}", "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
            "acute": "\u{00B4}", "cedil": "\u{00B8}", "frac14": "\u{00BC}", "frac12": "\u{00BD}", "frac34": "\u{00BE}",
            "loz": "\u{25CA}", "spades": "\u{2660}", "clubs": "\u{2663}", "hearts": "\u{2665}", "diams": "\u{2666}",
            "infin": "\u{221E}", "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}", "asymp": "\u{2248}",
            "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}", "pi": "\u{03C0}",
            "sigma": "\u{03C3}", "omega": "\u{03C9}", "Omega": "\u{03A9}", "szlig": "\u{00DF}", "fnof": "\u{0192}",
            "circ": "\u{02C6}", "tilde": "\u{02DC}", "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}",
            "scaron": "\u{0161}", "Yuml": "\u{0178}",
        ]
        // Latin-1 letters À…ÿ by their HTML names.
        let latin: [(String, UInt32)] = [
            ("Agrave", 0xC0), ("Aacute", 0xC1), ("Acirc", 0xC2), ("Atilde", 0xC3), ("Auml", 0xC4), ("Aring", 0xC5),
            ("AElig", 0xC6), ("Ccedil", 0xC7), ("Egrave", 0xC8), ("Eacute", 0xC9), ("Ecirc", 0xCA), ("Euml", 0xCB),
            ("Igrave", 0xCC), ("Iacute", 0xCD), ("Icirc", 0xCE), ("Iuml", 0xCF), ("ETH", 0xD0), ("Ntilde", 0xD1),
            ("Ograve", 0xD2), ("Oacute", 0xD3), ("Ocirc", 0xD4), ("Otilde", 0xD5), ("Ouml", 0xD6), ("Oslash", 0xD8),
            ("Ugrave", 0xD9), ("Uacute", 0xDA), ("Ucirc", 0xDB), ("Uuml", 0xDC), ("Yacute", 0xDD), ("THORN", 0xDE),
            ("agrave", 0xE0), ("aacute", 0xE1), ("acirc", 0xE2), ("atilde", 0xE3), ("auml", 0xE4), ("aring", 0xE5),
            ("aelig", 0xE6), ("ccedil", 0xE7), ("egrave", 0xE8), ("eacute", 0xE9), ("ecirc", 0xEA), ("euml", 0xEB),
            ("igrave", 0xEC), ("iacute", 0xED), ("icirc", 0xEE), ("iuml", 0xEF), ("eth", 0xF0), ("ntilde", 0xF1),
            ("ograve", 0xF2), ("oacute", 0xF3), ("ocirc", 0xF4), ("otilde", 0xF5), ("ouml", 0xF6), ("oslash", 0xF8),
            ("ugrave", 0xF9), ("uacute", 0xFA), ("ucirc", 0xFB), ("uuml", 0xFC), ("yacute", 0xFD), ("thorn", 0xFE),
            ("yuml", 0xFF),
        ]
        for (name, code) in latin { m[name] = String(Character(Unicode.Scalar(code)!)) }
        return m
    }()

    /// Names HTML also accepts without the semicolon.
    static let legacyEntities: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]
}
