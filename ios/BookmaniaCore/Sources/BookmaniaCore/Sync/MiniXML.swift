import Foundation

/// A small XML reader for WebDAV responses, which are untrusted input (as Android's MiniXml): document type
/// declarations are skipped and never processed, so no entity is defined or fetched; only the five predefined
/// entities and character references are decoded. Element names are resolved to (namespace, local name).
public struct XMLNode: Sendable {
    public let namespace: String
    public let name: String
    public let children: [XMLNode]
    public let text: String

    public func child(_ namespace: String, _ name: String) -> XMLNode? {
        children.first { $0.namespace == namespace && $0.name == name }
    }

    public func all(_ namespace: String, _ name: String) -> [XMLNode] {
        children.filter { $0.namespace == namespace && $0.name == name }
    }
}

public struct XMLFormatError: Error, Sendable {
    public let message: String
}

public enum MiniXML {
    private final class Builder {
        let prefix: String?
        let local: String
        let namespaces: [String: String]
        var children: [XMLNode] = []
        var text = ""

        init(prefix: String?, local: String, namespaces: [String: String]) {
            self.prefix = prefix
            self.local = local
            self.namespaces = namespaces
        }

        func finish() -> XMLNode {
            XMLNode(namespace: namespaces[prefix ?? ""] ?? "", name: local, children: children, text: text)
        }
    }

    public static func parse(_ xml: String) throws -> XMLNode {
        let s = Array(xml.unicodeScalars)
        var i = 0
        var stack: [Builder] = []

        func starts(_ marker: String, _ at: Int) -> Bool {
            let m = Array(marker.unicodeScalars)
            guard at + m.count <= s.count else { return false }
            for k in 0 ..< m.count where s[at + k] != m[k] { return false }
            return true
        }

        func index(of marker: String, from: Int) -> Int? {
            let m = Array(marker.unicodeScalars)
            guard !m.isEmpty, s.count >= m.count else { return nil }
            var j = from
            while j <= s.count - m.count {
                if s[j] == m[0], starts(marker, j) { return j }
                j += 1
            }
            return nil
        }

        func string(_ from: Int, _ to: Int) -> String {
            var u = String.UnicodeScalarView()
            u.append(contentsOf: s[from ..< to])
            return String(u)
        }

        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\r" || c == "\t" }

        while i < s.count {
            if s[i] != "<" {
                let end = index(of: "<", from: i) ?? s.count
                stack.last?.text += decode(string(i, end))
                i = end
                continue
            }
            if starts("<?", i) {
                guard let end = index(of: "?>", from: i) else { throw XMLFormatError(message: "unterminated ?>") }
                i = end + 2
            } else if starts("<!--", i) {
                guard let end = index(of: "-->", from: i) else { throw XMLFormatError(message: "unterminated comment") }
                i = end + 3
            } else if starts("<![CDATA[", i) {
                guard let end = index(of: "]]>", from: i + 9) else { throw XMLFormatError(message: "unterminated CDATA") }
                stack.last?.text += string(i + 9, end)
                i = end + 3
            } else if starts("<!", i) {
                // <!DOCTYPE ...> with an optional internal subset in brackets, skipped whole.
                var j = i + 2
                var depth = 0
                var quote: Unicode.Scalar?
                var done = false
                while j < s.count {
                    let c = s[j]
                    if let q = quote {
                        if c == q { quote = nil }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == "[" {
                        depth += 1
                    } else if c == "]" {
                        depth -= 1
                    } else if c == ">" && depth <= 0 {
                        done = true
                        break
                    }
                    j += 1
                }
                guard done else { throw XMLFormatError(message: "unterminated declaration") }
                i = j + 1
            } else if starts("</", i) {
                guard let end = index(of: ">", from: i) else { throw XMLFormatError(message: "unterminated end tag") }
                guard let b = stack.popLast() else { throw XMLFormatError(message: "unexpected end tag") }
                let node = b.finish()
                i = end + 1
                guard let parent = stack.last else { return node }
                parent.children.append(node)
            } else {
                i += 1
                let nameStart = i
                while i < s.count, !isSpace(s[i]), s[i] != ">", s[i] != "/" { i += 1 }
                let qname = string(nameStart, i)
                guard !qname.isEmpty else { throw XMLFormatError(message: "empty tag name") }
                var namespaces = stack.last?.namespaces ?? [:]
                var selfClosing = false
                while true {
                    while i < s.count, isSpace(s[i]) { i += 1 }
                    guard i < s.count else { throw XMLFormatError(message: "unterminated tag") }
                    if s[i] == ">" {
                        i += 1
                        break
                    }
                    if starts("/>", i) {
                        i += 2
                        selfClosing = true
                        break
                    }
                    let attrStart = i
                    while i < s.count, s[i] != "=", !isSpace(s[i]), s[i] != ">", s[i] != "/" { i += 1 }
                    let attr = string(attrStart, i)
                    while i < s.count, isSpace(s[i]) { i += 1 }
                    var value = ""
                    if i < s.count, s[i] == "=" {
                        i += 1
                        while i < s.count, isSpace(s[i]) { i += 1 }
                        guard i < s.count else { throw XMLFormatError(message: "unterminated attribute") }
                        let q = s[i]
                        if q == "\"" || q == "'" {
                            var end = i + 1
                            while end < s.count, s[end] != q { end += 1 }
                            guard end < s.count else { throw XMLFormatError(message: "unterminated attribute") }
                            value = decode(string(i + 1, end))
                            i = end + 1
                        } else {
                            let vs = i
                            while i < s.count, !isSpace(s[i]), s[i] != ">" { i += 1 }
                            value = string(vs, i)
                        }
                    }
                    if attr == "xmlns" {
                        namespaces[""] = value
                    } else if attr.hasPrefix("xmlns:") {
                        namespaces[String(attr.dropFirst(6))] = value
                    }
                }
                let parts = qname.split(separator: ":", maxSplits: 1).map(String.init)
                let b = parts.count == 2
                    ? Builder(prefix: parts[0], local: parts[1], namespaces: namespaces)
                    : Builder(prefix: nil, local: qname, namespaces: namespaces)
                if selfClosing {
                    let node = b.finish()
                    guard let parent = stack.last else { return node }
                    parent.children.append(node)
                } else {
                    stack.append(b)
                }
            }
        }
        throw XMLFormatError(message: "no root element")
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.firstIndex(of: ";") {
                let name = String(after[..<semi])
                var decoded: String?
                switch name {
                case "lt": decoded = "<"
                case "gt": decoded = ">"
                case "amp": decoded = "&"
                case "quot": decoded = "\""
                case "apos": decoded = "'"
                default:
                    if name.hasPrefix("#x") || name.hasPrefix("#X") {
                        decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(scalar)
                    } else if name.hasPrefix("#") {
                        decoded = UInt32(name.dropFirst(1)).flatMap(scalar)
                    }
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }

    private static func scalar(_ v: UInt32) -> String? {
        guard v >= 1, let u = Unicode.Scalar(v) else { return nil }
        return String(Character(u))
    }
}
