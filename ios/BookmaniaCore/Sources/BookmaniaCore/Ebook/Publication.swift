import Foundation

public enum BookFormat: String, Sendable { case epub = "EPUB", mobi = "MOBI", kf8 = "KF8", kfx = "KFX", unknown = "UNKNOWN" }

/// Whether a book is read as text (WebView reader) or as images (the comic reader).
public enum ContentKind: String, Sendable { case text = "TEXT", comic = "COMIC" }

/// Page progression declared by the book.
public enum ReadingDirection: String, Sendable { case ltr = "LTR", rtl = "RTL", `default` = "DEFAULT" }

/// Writing mode the book appears to use; the reader's "follow the book" setting uses it.
public enum WritingModeHint: String, Sendable { case horizontal = "HORIZONTAL", vertical = "VERTICAL" }

public struct BookMetadata: Equatable, Sendable {
    public var title: String?
    public var authors: [String]
    public var languages: [String]
    public var identifier: String?
    public var description: String?
    /// Container path of the cover image, if the book declares one.
    public var coverHref: String?
    public var publisher: String?
    /// Publication date as written in the book (EPUB `dc:date`, MOBI EXTH 106).
    public var date: String?

    public init(title: String?, authors: [String], languages: [String], identifier: String?, description: String?,
                coverHref: String?, publisher: String? = nil, date: String? = nil) {
        self.title = title
        self.authors = authors
        self.languages = languages
        self.identifier = identifier
        self.description = description
        self.coverHref = coverHref
        self.publisher = publisher
        self.date = date
    }
}

public struct SpineItem: Equatable, Sendable {
    /// Container path, for example `OEBPS/text/ch01.xhtml` or `part0003.xhtml`.
    public var href: String
    public var mediaType: String
    public var linear: Bool

    public init(href: String, mediaType: String, linear: Bool = true) {
        self.href = href
        self.mediaType = mediaType
        self.linear = linear
    }
}

public struct TocEntry: Equatable, Sendable {
    public var title: String
    /// Container path with optional `#fragment`; nil for headings without a target.
    public var href: String?
    public var children: [TocEntry]

    public init(title: String, href: String?, children: [TocEntry] = []) {
        self.title = title
        self.href = href
        self.children = children
    }
}

/// A parsed book. Paths ("hrefs") are container paths: the web view requests them under the book's virtual
/// origin and the reader resolves them with `open`.
public protocol Publication: AnyObject {
    var format: BookFormat { get }
    var metadata: BookMetadata { get }
    var spine: [SpineItem] { get }
    var toc: [TocEntry] { get }
    var readingDirection: ReadingDirection { get }
    var writingModeHint: WritingModeHint { get }
    /// Fixed-layout books (EPUB `rendition:layout` = pre-paginated) are read as images.
    var isFixedLayout: Bool { get }

    /// Raw bytes of a resource (fonts already de-obfuscated), or nil when it does not exist.
    func open(_ href: String) throws -> [UInt8]?

    func mediaType(_ href: String) -> String?

    /// All resource paths, for diagnostics and tests.
    var resourcePaths: [String] { get }

    func close()
}

/// Media type from a file name, for resources the book does not describe itself.
public func mediaTypeFromName(_ name: String) -> String? {
    switch name.afterLast(".", missing: "").lowercased() {
    case "xhtml", "xht": return "application/xhtml+xml"
    case "html", "htm": return "text/html"
    case "css": return "text/css"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    case "bmp": return "image/bmp"
    case "ttf": return "font/ttf"
    case "otf": return "font/otf"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "ncx": return "application/x-dtbncx+xml"
    case "opf": return "application/oebps-package+xml"
    case "js": return "text/javascript"
    case "mp3": return "audio/mpeg"
    case "mp4": return "video/mp4"
    default: return nil
    }
}
