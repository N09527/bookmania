import Foundation

/// Text size of a book, for whole-book progress (the progress slider, estimated page numbers) without laying out
/// every document (port of core/ebook `BookStats.kt`).
public enum BookStats {

    /// Non-whitespace characters in the body text of each spine item, in spine order (0 for items that are not
    /// (X)HTML documents or cannot be read). Ruby annotations count like other text, as in the reader shell's own
    /// count. Characters are counted in UTF-16 units, as on Android.
    public static func charCounts(_ publication: Publication) -> [Int] {
        publication.spine.map { item in
            let type = item.mediaType.lowercased()
            if !type.contains("html") && !type.contains("xml") { return 0 }
            guard let bytes = try? publication.open(item.href) else { return 0 }
            return countText(bytes)
        }
    }

    static func countText(_ bytes: [UInt8]) -> Int {
        let doc = Markup.parse(bytes, mode: .xml)
        let body = doc.allElements.first { $0.localName == "body" } ?? doc
        return countNonWhitespaceUTF16(body.wholeText)
    }
}
