import Foundation

/// Matches simple CSS selectors against parsed elements, enough for `WritingModeDetector` (which only asks about
/// `html` and `body`): type and universal selectors, `.class`, `#id`, attribute selectors, `:root`, and the
/// descendant and child combinators. Anything else (sibling combinators, other pseudo-classes) does not match.
/// Jsoup's `Element.is(selector)` plays this part on Android.
enum CSSSelector {

    static func matches(_ el: MLElement, _ selector: String) -> Bool {
        guard let parts = parse(selector) else { return false }
        return match(el, parts, parts.count - 1)
    }

    private enum Combinator { case descendant, child }

    private struct Compound {
        var type: String? // lower-cased local name; nil = any
        var classes: [String] = []
        var ids: [String] = []
        var attrs: [(name: String, op: String?, value: String)] = []
        var root = false
    }

    private struct Part {
        var compound: Compound
        /// Combinator to the part on the left (nil for the first part).
        var combinator: Combinator?
    }

    private static func parse(_ selector: String) -> [Part]? {
        let chars = Array(selector.trimmed.unicodeScalars)
        guard !chars.isEmpty else { return nil }
        var parts = [Part]()
        var i = 0
        var pending: Combinator? = nil
        while i < chars.count {
            // combinators and white space
            var sawSpace = false
            while i < chars.count && isSpace(chars[i]) { sawSpace = true; i += 1 }
            guard i < chars.count else { break }
            if chars[i] == ">" {
                pending = .child
                i += 1
                continue
            }
            if chars[i] == "+" || chars[i] == "~" || chars[i] == "," { return nil }
            if sawSpace && !parts.isEmpty && pending == nil { pending = .descendant }
            guard let (compound, next) = parseCompound(chars, i) else { return nil }
            parts.append(Part(compound: compound, combinator: parts.isEmpty ? nil : (pending ?? .descendant)))
            pending = nil
            i = next
        }
        return parts.isEmpty ? nil : parts
    }

    private static func parseCompound(_ c: [Unicode.Scalar], _ start: Int) -> (Compound, Int)? {
        var comp = Compound()
        var i = start
        func ident() -> String {
            let s = i
            while i < c.count, isIdent(c[i]) { i += 1 }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: c[s ..< i])
            return String(v)
        }
        if i < c.count && c[i] == "*" {
            i += 1
        } else if i < c.count && isIdent(c[i]) {
            var name = ident()
            if i < c.count && c[i] == "|" { i += 1; name = ident() }
            comp.type = name.lowercased()
        }
        var any = comp.type != nil || (start < c.count && c[start] == "*")
        while i < c.count && !isSpace(c[i]) && c[i] != ">" && c[i] != "+" && c[i] != "~" {
            switch c[i] {
            case ".":
                i += 1
                let name = ident()
                if name.isEmpty { return nil }
                comp.classes.append(name.lowercased())
            case "#":
                i += 1
                let name = ident()
                if name.isEmpty { return nil }
                comp.ids.append(name)
            case "[":
                i += 1
                let end = c[i...].firstIndex(of: "]") ?? c.count
                var v = String.UnicodeScalarView()
                v.append(contentsOf: c[i ..< end])
                guard let attr = parseAttr(String(v)) else { return nil }
                comp.attrs.append(attr)
                i = min(c.count, end + 1)
            case ":":
                i += 1
                if i < c.count && c[i] == ":" { return nil } // pseudo-elements never match an element
                let name = ident().lowercased()
                if name == "root" { comp.root = true } else { return nil }
            default:
                return nil
            }
            any = true
        }
        return any ? (comp, i) : nil
    }

    private static func parseAttr(_ s: String) -> (name: String, op: String?, value: String)? {
        for op in ["~=", "|=", "^=", "$=", "*=", "="] {
            if let r = s.range(of: op) {
                let name = s[..<r.lowerBound].trimmed.lowercased()
                var value = s[r.upperBound...].trimmed
                if value.hasSuffix(" i") || value.hasSuffix(" I") { value = String(value.dropLast(2)).trimmed }
                if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                    value = String(value.dropFirst().dropLast())
                }
                return name.isEmpty ? nil : (name, op, value)
            }
        }
        let name = s.trimmed.lowercased()
        return name.isEmpty ? nil : (name, nil, "")
    }

    private static func match(_ el: MLElement, _ parts: [Part], _ index: Int) -> Bool {
        guard matchCompound(el, parts[index].compound) else { return false }
        if index == 0 { return true }
        switch parts[index].combinator {
        case .child:
            guard let p = el.parent, p.name != "#document" else { return false }
            return match(p, parts, index - 1)
        case .descendant, .none:
            var p = el.parent
            while let a = p, a.name != "#document" {
                if match(a, parts, index - 1) { return true }
                p = a.parent
            }
            return false
        }
    }

    private static func matchCompound(_ el: MLElement, _ c: Compound) -> Bool {
        if let t = c.type, el.localName != t { return false }
        if c.root, let p = el.parent, p.name != "#document" { return false }
        if !c.classes.isEmpty {
            let classes = Set(el.attr("class").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { $0.lowercased() })
            if !c.classes.allSatisfy(classes.contains) { return false }
        }
        for id in c.ids where el.attr("id") != id { return false }
        for a in c.attrs {
            guard el.hasAttr(a.name) else { return false }
            let v = el.attr(a.name)
            switch a.op {
            case nil: continue
            case "=": if v != a.value { return false }
            case "~=": if !v.split(separator: " ").contains(Substring(a.value)) { return false }
            case "|=": if !(v == a.value || v.hasPrefix(a.value + "-")) { return false }
            case "^=": if a.value.isEmpty || !v.hasPrefix(a.value) { return false }
            case "$=": if a.value.isEmpty || !v.hasSuffix(a.value) { return false }
            case "*=": if a.value.isEmpty || !v.contains(a.value) { return false }
            default: return false
            }
        }
        return true
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }

    private static func isIdent(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || (c.value >= 48 && c.value <= 57) || c == "-" || c == "_" || c.value > 0x7F
    }
}
