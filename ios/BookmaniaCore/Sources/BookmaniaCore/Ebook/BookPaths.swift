import Foundation

/// Helpers for container paths (ZIP entry names) and the relative URLs books use to point at them.
public enum BookPaths {

    /// Directory part of a container path, without the trailing slash ("" for the root).
    public static func dirOf(_ path: String) -> String { path.beforeLast("/", missing: "") }

    /// Splits `a/b.xhtml#frag` into the path and the fragment (without '#').
    public static func splitFragment(_ href: String) -> (path: String, fragment: String?) {
        guard let i = href.firstIndex(of: "#") else { return (href, nil) }
        let fragment = String(href[href.index(after: i)...])
        return (String(href[..<i]), fragment.isEmpty ? nil : fragment)
    }

    /// True for URLs that leave the book (http:, mailto:, data:, javascript: …).
    public static func isExternal(_ href: String) -> Bool {
        let t = href.trimmed
        guard let colon = t.firstIndex(of: ":") else { return false }
        let scheme = t[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Resolves a relative, percent-encoded `href` against the directory of `basePath`. Returns a decoded container
    /// path with its `#fragment` kept, or nil when the link is external or climbs above the container root.
    public static func resolve(_ basePath: String, _ href: String) -> String? {
        let trimmed = href.trimmed
        if trimmed.isEmpty || isExternal(trimmed) { return nil }
        let (pathPart, fragment) = splitFragment(trimmed)
        let decoded = percentDecode(pathPart.before("?"))
        let joined: String
        if decoded.isEmpty {
            joined = basePath
        } else if decoded.hasPrefix("/") {
            joined = String(decoded.drop(while: { $0 == "/" }))
        } else {
            let dir = dirOf(basePath)
            joined = dir.isEmpty ? decoded : "\(dir)/\(decoded)"
        }
        guard let normalized = normalize(joined) else { return nil }
        if let fragment { return "\(normalized)#\(fragment)" }
        return normalized
    }

    /// Resolves `.` and `..`; returns nil if the path climbs above the root.
    public static func normalize(_ path: String) -> String? {
        var out = [Substring]()
        for seg in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false) {
            switch seg {
            case "", ".": continue
            case "..":
                if out.isEmpty { return nil }
                out.removeLast()
            default: out.append(seg)
            }
        }
        return out.joined(separator: "/")
    }

    /// Percent-decoding as UTF-8 (a '+' stays a '+': these are paths, not form data).
    public static func percentDecode(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var out = [UInt8]()
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "%"), i + 2 < chars.count + 0, i + 2 <= chars.count - 1,
               let hi = hexValue(chars[i + 1]), let lo = hexValue(chars[i + 2]) {
                out.append(UInt8(hi << 4 | lo))
                i += 3
            } else {
                out.append(c)
                i += 1
            }
        }
        return utf8(out)
    }

    /// Percent-encodes a container path for use in a URL (keeps '/').
    public static func percentEncodePath(_ path: String) -> String {
        var sb = ""
        for c in path.utf8 {
            let ch = Character(Unicode.Scalar(c))
            if c < 0x80 && (ch.isLetter || ch.isNumber) || "-._~/!$&'()*+,;=:@".contains(ch) && c < 0x80 {
                sb.append(ch)
            } else {
                sb += String(format: "%%%02X", c)
            }
        }
        return sb
    }

    private static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}
