import Foundation

/// Identifies a book file from its first bytes (the extension is only a hint).
public enum FormatDetector {

    public static func detect(_ source: RandomAccessSource, extension ext: String? = nil) throws -> BookFormat {
        let size = source.size
        if size < 4 { return .unknown }
        let head = try source.read(at: 0, count: Int(min(size, 128)))
        let e = ext?.lowercased()

        if head[0] == UInt8(ascii: "P") && head[1] == UInt8(ascii: "K") && head[2] == 3 && head[3] == 4 {
            // OCF requires an uncompressed "mimetype" entry first; many books ignore that, so the extension is
            // accepted as well. A damaged EPUB is still reported as EPUB here; the parser then explains that it is
            // damaged.
            let nameLen = head.count >= 30 ? Int(head[26]) | Int(head[27]) << 8 : 0
            let firstName = head.count >= 30 + nameLen ? latin1(head[30 ..< 30 + nameLen]) : ""
            if firstName == "mimetype" || e == "epub" { return .epub }
            return .unknown
        }
        if size >= 68 {
            switch ascii(head, 60, 8) {
            case "BOOKMOBI", "TEXtREAd": return .mobi
            default: break
            }
        }
        // KFX containers ("CONT") and DRM-wrapped KFX ("êDRMIONî") are not supported.
        if ascii(head, 0, 4) == "CONT" { return .kfx }
        if head.count >= 8 && head[0] == 0xEA && ascii(head, 1, 6) == "DRMION" { return .kfx }
        return .unknown
    }
}

/// Opens any supported book file. The source is owned by the result, or closed on failure.
public enum BookOpener {

    /// File extensions of text books.
    public static let textBookExtensions: Set<String> = ["epub", "mobi", "azw3"]

    public static func open(_ source: RandomAccessSource, extension ext: String? = nil) throws -> Publication {
        let format: BookFormat
        do {
            format = try FormatDetector.detect(source, extension: ext)
        } catch {
            source.close()
            throw BookError.unreadable("Cannot read the file")
        }
        switch format {
        case .epub:
            return try EpubParser.parse(source)
        case .mobi, .kf8:
            return try MobiParser.parse(source)
        case .kfx:
            source.close()
            throw BookError.unsupported("KFX books are not supported")
        case .unknown:
            source.close()
            throw BookError.unreadable("Unknown or damaged book file")
        }
    }
}
