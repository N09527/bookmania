import Foundation

/// A reading position in a text book (port of Android's yokai/ebook/data/EbookLocator.kt), saved with the chapter and
/// carried in backups as JSON in the same format as on Android (BackupChapter field 20101), so a position moves between
/// the two versions.
///
/// It is restored in this order (the reader shell's `resolvePosition`): `location` when the text there still matches
/// `text`; else the occurrence of `text` nearest to `progression`; else `progression`. A page without text (a picture)
/// has no location and is saved by its page (`pageProgression`).
public struct EbookLocator: Codable, Equatable, Sendable {
    /// Spine index and path of the document; the path wins when the spine changed.
    public var spine: Int
    public var href: String
    /// [text node index, offset] of the first character of the page in the shell's text walk.
    public var location: [Int]?
    /// Non-whitespace text from `location` on, to find the place again when the location does not match.
    public var text: String
    /// Fraction of the document's text before `location` (0...1).
    public var progression: Double
    /// Page fraction (page / pages), only for a page without text.
    public var pageProgression: Double?
    /// Whole-book fraction (0...1), from the documents' character counts; nil when they were not known.
    public var total: Double?
    /// The page was the last one of the book.
    public var atEnd: Bool
    /// The chapter's `lastPageRead` written together with this position (the estimated page), or nil when no page
    /// numbers were written. If the chapter list later shows no progress although this was above 0, the progress was
    /// cleared there ("mark as unread") and the book starts from the beginning.
    public var chapterPage: Int?
    /// Milliseconds since 1970.
    public var updatedAt: Int64
    public var version: Int

    public init(spine: Int, href: String, location: [Int]? = nil, text: String = "", progression: Double = 0,
                pageProgression: Double? = nil, total: Double? = nil, atEnd: Bool = false, chapterPage: Int? = nil,
                updatedAt: Int64 = 0, version: Int = 1) {
        self.spine = spine
        self.href = href
        self.location = location
        self.text = text
        self.progression = progression
        self.pageProgression = pageProgression
        self.total = total
        self.atEnd = atEnd
        self.chapterPage = chapterPage
        self.updatedAt = updatedAt
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case spine, href, location, text, progression, pageProgression, total, atEnd, chapterPage, updatedAt, version
    }

    // Missing keys take their defaults and unknown keys are ignored, as with Android's Json { ignoreUnknownKeys }.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spine = try c.decode(Int.self, forKey: .spine)
        href = try c.decode(String.self, forKey: .href)
        location = try c.decodeIfPresent([Int].self, forKey: .location)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        progression = try c.decodeIfPresent(Double.self, forKey: .progression) ?? 0
        pageProgression = try c.decodeIfPresent(Double.self, forKey: .pageProgression)
        total = try c.decodeIfPresent(Double.self, forKey: .total)
        atEnd = try c.decodeIfPresent(Bool.self, forKey: .atEnd) ?? false
        chapterPage = try c.decodeIfPresent(Int.self, forKey: .chapterPage)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    // Defaults are left out, as Android writes them (encodeDefaults = false).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spine, forKey: .spine)
        try c.encode(href, forKey: .href)
        try c.encodeIfPresent(location, forKey: .location)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if progression != 0 { try c.encode(progression, forKey: .progression) }
        try c.encodeIfPresent(pageProgression, forKey: .pageProgression)
        try c.encodeIfPresent(total, forKey: .total)
        if atEnd { try c.encode(atEnd, forKey: .atEnd) }
        try c.encodeIfPresent(chapterPage, forKey: .chapterPage)
        if updatedAt != 0 { try c.encode(updatedAt, forKey: .updatedAt) }
        if version != 1 { try c.encode(version, forKey: .version) }
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Nil for anything that is not a locator this version can use.
    public static func fromJSON(_ json: String?) -> EbookLocator? {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let locator = try? JSONDecoder().decode(EbookLocator.self, from: Data(json.utf8)) else { return nil }
        return locator.isValid ? locator : nil
    }

    var isValid: Bool {
        spine >= 0 && (0 ... 1).contains(progression)
            && (location.map { $0.count == 2 && $0.allSatisfy { $0 >= 0 } } ?? true)
            && (pageProgression.map { (0 ... 1).contains($0) } ?? true)
            && (total.map { (0 ... 1).contains($0) } ?? true)
            && (chapterPage.map { $0 >= 0 } ?? true)
    }

    /// The shell's open target for this position (see reader.js start()).
    public var shellTarget: String {
        var object = [String: Any]()
        if location == nil, let pageProgression {
            object["pageProgression"] = pageProgression
        } else {
            if let location { object["location"] = location }
            if !text.isEmpty { object["text"] = text }
            object["progression"] = progression
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "'start'" }
        return s
    }
}

/// Whole-book progress of a text book from the character counts of its documents (BookStats) and the position in the
/// open document (port of Android's ReadingProgress.kt). Text books have no fixed pages: the chapter list's
/// "page X of Y" is an estimate with the page size of the current layout (characters per page of the open document).
public struct ReadingProgress: Sendable {
    public let charCounts: [Int]
    private let totalChars: Int64

    public init(_ charCounts: [Int]) {
        self.charCounts = charCounts
        totalChars = charCounts.reduce(Int64(0)) { $0 + Int64($1) }
    }

    /// Characters of the documents before `spine`.
    private func charsBefore(_ spine: Int) -> Int64 {
        var sum: Int64 = 0
        for i in 0 ..< min(spine, charCounts.count) { sum += Int64(charCounts[i]) }
        return sum
    }

    /// Fraction of the book (0...1) at `docFraction` of document `spine`. A book without any text counts each
    /// document as an equal part instead.
    public func total(_ spine: Int, _ docFraction: Double) -> Double {
        guard charCounts.indices.contains(spine) else { return 0 }
        let f = min(max(docFraction, 0), 1)
        if totalChars <= 0 { return min(max((Double(spine) + f) / Double(charCounts.count), 0), 1) }
        return min(max((Double(charsBefore(spine)) + f * Double(charCounts[spine])) / Double(totalChars), 0), 1)
    }

    /// Document and fraction in it for a fraction of the book (the progress slider).
    public func locate(_ total: Double) -> (Int, Double) {
        if charCounts.isEmpty { return (0, 0) }
        if totalChars <= 0 {
            let x = min(max(total, 0), 1) * Double(charCounts.count)
            let index = min(charCounts.count - 1, Int(x))
            return (index, min(max(x - Double(index), 0), 1))
        }
        let target = min(max(total, 0), 1) * Double(totalChars)
        var before = 0.0
        for (i, n) in charCounts.enumerated() {
            if n > 0 && target < before + Double(n) { return (i, min(max((target - before) / Double(n), 0), 1)) }
            before += Double(n)
        }
        let last = max(0, charCounts.lastIndex { $0 > 0 } ?? 0)
        return (last, 1)
    }

    /// Page numbers for the chapter list: (index of the current page, number of pages). The open document counts with
    /// its real pages (`page` of `pages` in the current layout); the other documents are estimated with its page size.
    /// Nil when the open document has no text to measure with.
    public func pages(_ spine: Int, page: Int, pages: Int, atEnd: Bool) -> (Int, Int)? {
        guard charCounts.indices.contains(spine) else { return nil }
        let docChars = charCounts[spine]
        if docChars <= 0 || pages <= 0 || totalChars <= 0 { return nil }
        let charsPerPage = Double(docChars) / Double(pages)
        let before = Double(charsBefore(spine))
        let beforePages = Int((before / charsPerPage).rounded())
        let afterPages = Int(((Double(totalChars) - before - Double(docChars)) / charsPerPage).rounded())
        let totalPages = max(1, beforePages + pages + afterPages)
        let current = atEnd ? totalPages - 1 : min(totalPages - 1, beforePages + max(0, page))
        return (current, totalPages)
    }
}
