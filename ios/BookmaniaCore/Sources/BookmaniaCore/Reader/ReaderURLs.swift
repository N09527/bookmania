import Foundation

/// The reader's private origin `bookmania://reader/` (the iOS counterpart of Android's
/// `https://appassets.androidplatform.net/`, see EbookRequestHandler.kt):
/// - `/shell/…` the reader shell (`reader.html`, `reader.js`, shared with Android);
/// - `/book/…`  resources of the open book; (X)HTML documents are sanitized and get a strict CSP;
/// - `/fonts/<id>` a font the user imported (only by id).
/// Every other URL is refused, so book content cannot reach the network or any other file of the app.
public enum ReaderURLs {
    public static let scheme = "bookmania"
    public static let host = "reader"
    public static let origin = "bookmania://reader"
    public static let shellPrefix = "/shell/"
    public static let bookPrefix = "/book/"
    public static let fontsPrefix = "/fonts/"
    public static let shellURL = origin + shellPrefix + "reader.html"
    public static let shellFiles: Set<String> = ["reader.html", "reader.js"]

    /// Book documents: no scripts, nothing outside this origin (the policy of Android). Besides 'self', the
    /// `bookmania:` scheme is listed explicitly, in case WebKit does not count a custom scheme as 'self'; it only
    /// serves the routes below.
    public static let bookCSP = "default-src 'self' bookmania:; script-src 'none'; style-src 'self' bookmania: 'unsafe-inline'; " +
        "img-src 'self' bookmania: data:; font-src 'self' bookmania: data:; media-src 'self' bookmania:; connect-src 'none'; " +
        "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    /// The shell: only its own script; book documents in same-origin frames.
    public static let shellCSP = "default-src 'self' bookmania:; script-src 'self' bookmania:; style-src 'self' bookmania: 'unsafe-inline'; " +
        "img-src 'self' bookmania: data:; font-src 'self' bookmania: data:; frame-src 'self' bookmania:; connect-src 'none'; " +
        "object-src 'none'; base-uri 'none'; form-action 'none'"

    public enum Route: Equatable {
        case shell(String)
        case book(String)
        case font(String)
    }

    /// What a request asks for, or nil when it must be refused.
    public static func route(_ url: URL) -> Route? {
        guard url.scheme == scheme, url.host == host, url.port == nil else { return nil }
        let path = url.path
        if path.hasPrefix(shellPrefix) {
            let name = String(path.dropFirst(shellPrefix.count))
            return shellFiles.contains(name) ? .shell(name) : nil
        }
        if path.hasPrefix(bookPrefix) {
            let p = String(path.dropFirst(bookPrefix.count))
            return p.isEmpty ? nil : .book(p)
        }
        if path.hasPrefix(fontsPrefix) {
            let id = String(path.dropFirst(fontsPrefix.count))
            return fontId.matches(id) ? .font(id) : nil
        }
        return nil
    }

    /// URL of a book resource (each path segment percent-encoded).
    public static func bookURL(_ path: String, fragment: String? = nil) -> String {
        var s = origin + bookPrefix + BookPaths.percentEncodePath(path)
        if let fragment { s += "#" + BookPaths.percentEncodePath(fragment) }
        return s
    }

    /// URL of an imported font (the id is checked again when it is requested).
    public static func fontURL(_ id: String) -> String { origin + fontsPrefix + id }

    /// Container path and fragment of a URL inside the book, or nil for anything else.
    public static func bookPath(of urlString: String) -> (path: String, fragment: String?)? {
        guard let url = URL(string: urlString), case let .book(path)? = route(url) else { return nil }
        return (path, url.fragment.map { BookPaths.percentDecode($0) })
    }

    /// WebKit content rules: block every load except this origin and inline data.
    public static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^bookmania://reader/"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    private static let fontId = Rx("[0-9a-f]{32}")
}

/// The settings object the shell's `open` and `relayout` take (EbookReaderActivity.settingsJson on Android).
public struct ShellSettings: Equatable, Sendable {
    public var vertical: Bool
    public var rtl: Bool
    /// "off", "on" or "landscape".
    public var columns: String = "landscape"
    /// nil: the book's own font; otherwise ["kind": "sans" | "serif"] or ["kind": "imported", "url": …].
    public var font: [String: String]? = nil
    public var bold = false
    public var fontSize = 20
    public var lineHeight = 1.8
    public var letterSpacing = 0.0
    /// nil: as the book says ("依書籍").
    public var indent: Double? = nil
    public var paragraphSpacing: Double? = nil
    public var marginTop = 32, marginBottom = 32, marginLeft = 20, marginRight = 20
    public var background = "#FFFFFF"
    public var textColor = "#000000"
    public var dark = false

    public init(vertical: Bool, rtl: Bool) {
        self.vertical = vertical
        self.rtl = rtl
    }

    /// JSON text for the shell (keys in a fixed order, nulls for the book's own values).
    public func json() -> String {
        func num(_ v: Double) -> String {
            // 1.8 rather than 1.8000000000000000444
            let s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
            var t = s
            while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
            return t.isEmpty ? "0" : t
        }
        func str(_ s: String) -> String {
            var out = "\""
            for c in s.unicodeScalars {
                switch c {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if c.value < 0x20 || c == "\u{2028}" || c == "\u{2029}" {
                        out += String(format: "\\u%04x", c.value)
                    } else {
                        out.unicodeScalars.append(c)
                    }
                }
            }
            return out + "\""
        }
        var fontJSON = "null"
        if let font {
            fontJSON = "{" + font.keys.sorted().map { "\(str($0)):\(str(font[$0]!))" }.joined(separator: ",") + "}"
        }
        return "{\"vertical\":\(vertical),\"rtl\":\(rtl),\"columns\":\(str(columns)),\"font\":\(fontJSON),\"bold\":\(bold)," +
            "\"fontSize\":\(fontSize),\"lineHeight\":\(num(lineHeight)),\"letterSpacing\":\(num(letterSpacing))," +
            "\"indent\":\(indent.map(num) ?? "null"),\"paragraphSpacing\":\(paragraphSpacing.map(num) ?? "null")," +
            "\"margins\":{\"top\":\(marginTop),\"bottom\":\(marginBottom),\"left\":\(marginLeft),\"right\":\(marginRight)}," +
            "\"background\":\(str(background)),\"textColor\":\(str(textColor)),\"dark\":\(dark)}"
    }

    /// A string as a JavaScript string literal (JSON quoting).
    public static func jsString(_ s: String) -> String {
        var settings = ShellSettings(vertical: false, rtl: false)
        settings.background = s
        let json = settings.json()
        // Reuse the quoting of json(): take the "background" value back out.
        let start = json.range(of: "\"background\":")!.upperBound
        let end = json.range(of: ",\"textColor\"")!.lowerBound
        return String(json[start ..< end])
    }
}
