import Foundation

/// Decides whether a book is read as text or with the image (comic) reader. The user can override the result per
/// book; this is only the automatic default (port of core/ebook `ContentClassifier.kt`).
public enum ContentClassifier {

    public struct Stats: Equatable {
        public let documents: Int
        public let textChars: Int
        public let images: Int
        public let documentsWithImages: Int
    }

    /// Average non-space characters per document below which a book counts as "images only".
    public static let maxTextPerDoc = 50

    /// Fraction of documents that must contain an image for an image book.
    public static let minImageRatio = 0.5

    public static func classify(_ publication: Publication, maxDocuments: Int = 40) -> ContentKind {
        if publication.isFixedLayout { return .comic }
        return classify(stats(publication, maxDocuments: maxDocuments))
    }

    public static func classify(_ stats: Stats) -> ContentKind {
        if stats.documents == 0 { return .text }
        let avgText = Double(stats.textChars) / Double(stats.documents)
        let imageRatio = Double(stats.documentsWithImages) / Double(stats.documents)
        return avgText < Double(maxTextPerDoc) && imageRatio >= minImageRatio ? .comic : .text
    }

    public static func stats(_ publication: Publication, maxDocuments: Int = 40) -> Stats {
        var docs = 0, text = 0, images = 0, withImages = 0
        for item in publication.spine {
            if docs >= maxDocuments { break }
            if !item.linear { continue }
            let type = item.mediaType.lowercased()
            if !type.contains("html") && !type.contains("xml") { continue }
            guard let bytes = try? publication.open(item.href) else { continue }
            let doc = Markup.parse(bytes, mode: .xml)
            let body = doc.allElements.first { $0.localName == "body" } ?? doc
            text += countNonWhitespaceUTF16(body.text)
            let n = body.allElements.filter { el in
                switch el.localName {
                case "img", "image": return true
                case "object": return el.attr("type").hasPrefix("image/")
                default: return false
                }
            }.count
            images += n
            if n > 0 { withImages += 1 }
            docs += 1
        }
        return Stats(documents: docs, textChars: text, images: images, documentsWithImages: withImages)
    }
}
