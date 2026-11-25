import Foundation

/// Result of reading an imported font file.
public struct FontInfo: Equatable, Sendable {
    /// Family name for display; nil when the font has no usable name.
    public let familyName: String?
    public let format: FontFormat
    /// `vhea` and `vmtx` tables: advances and origins for vertical layout.
    public let hasVerticalMetrics: Bool
    /// A GSUB `vert` or `vrt2` feature: vertical forms of punctuation and brackets.
    public let hasVerticalGlyphs: Bool

    /// True when the font is expected to typeset vertical text properly.
    public var supportsVertical: Bool { hasVerticalMetrics && hasVerticalGlyphs }
}

public enum FontFormat: String, Sendable {
    case trueType = "ttf", openTypeCFF = "otf"
    public var fileExtension: String { rawValue }
}

public struct InvalidFontError: Error, Equatable {
    public let message: String
}

/// Reads the table directory of a TrueType / OpenType font (no rendering). Font collections (.ttc), WOFF and WOFF2
/// are refused: the reader only imports single TTF / OTF files (port of core/ebook `FontInspector.kt`).
public enum FontInspector {

    private static let maxTables = 512

    public static func inspect(_ bytes: [UInt8]) throws -> FontInfo {
        if bytes.count < 12 { throw InvalidFontError(message: "File too small for a font") }
        let format: FontFormat
        let tag = try u32(bytes, 0)
        switch tag {
        case 0x0001_0000, 0x7472_7565: format = .trueType // 'true': old Apple TrueType
        case 0x4F54_544F: format = .openTypeCFF // 'OTTO'
        case 0x7474_6366: throw InvalidFontError(message: "Font collections (.ttc) are not supported")
        case 0x774F_4646, 0x774F_4632: throw InvalidFontError(message: "WOFF fonts are not supported")
        default: throw InvalidFontError(message: "Not a TrueType or OpenType font (0x\(String(tag, radix: 16)))")
        }
        let numTables = try u16(bytes, 4)
        if numTables == 0 || numTables > maxTables { throw InvalidFontError(message: "Bad table count \(numTables)") }
        var tables = [String: Range<Int>]()
        for i in 0 ..< numTables {
            let p = 12 + i * 16
            if p + 16 > bytes.count { throw InvalidFontError(message: "Truncated table directory") }
            let tagName = latin1(bytes[p ..< p + 4])
            let offset = try u32(bytes, p + 8)
            let length = try u32(bytes, p + 12)
            if offset + length > Int64(bytes.count) { throw InvalidFontError(message: "Table \(tagName) lies outside the file") }
            tables[tagName] = Int(offset) ..< Int(offset + length)
        }
        let required = format == .trueType ? ["cmap", "glyf", "loca"] : ["cmap", "CFF "]
        let missing = required.filter { tables[$0] == nil && !($0 == "CFF " && tables["CFF2"] != nil) }
        if !missing.isEmpty { throw InvalidFontError(message: "Missing tables: \(missing.joined(separator: ", "))") }

        return FontInfo(
            familyName: tables["name"].flatMap { try? familyName(bytes, $0) },
            format: format,
            hasVerticalMetrics: tables["vhea"] != nil && tables["vmtx"] != nil,
            hasVerticalGlyphs: tables["GSUB"].flatMap { try? hasFeature(bytes, $0, ["vert", "vrt2"]) } ?? false
        )
    }

    private static func hasFeature(_ b: [UInt8], _ gsub: Range<Int>, _ tags: Set<String>) throws -> Bool {
        let base = gsub.lowerBound
        let featureList = base + (try u16(b, base + 6))
        if !gsub.contains(featureList) { return false }
        let count = try u16(b, featureList)
        for i in 0 ..< count {
            let p = featureList + 2 + i * 6
            if p + 6 > gsub.upperBound { return false }
            if tags.contains(latin1(b[p ..< p + 4])) { return true }
        }
        return false
    }

    /// Prefers the typographic family (ID 16) over the legacy family (ID 1), Windows / Unicode records over Mac
    /// ones, and Traditional Chinese, then other Chinese, then English, then any.
    private static func familyName(_ b: [UInt8], _ name: Range<Int>) throws -> String? {
        let base = name.lowerBound
        let count = try u16(b, base + 2)
        let storage = base + (try u16(b, base + 4))
        var best: (text: String, score: Int)?
        for i in 0 ..< count {
            let p = base + 6 + i * 12
            if p + 12 > name.upperBound { break }
            let platform = try u16(b, p)
            let encoding = try u16(b, p + 2)
            let language = try u16(b, p + 4)
            let nameId = try u16(b, p + 6)
            let length = try u16(b, p + 8)
            let offset = storage + (try u16(b, p + 10))
            if nameId != 1 && nameId != 16 { continue }
            if offset + length > name.upperBound { continue }
            let raw = Array(b[offset ..< offset + length])
            let text: String
            if platform == 3 && (encoding == 1 || encoding == 10) || platform == 0 {
                text = utf16BE(raw)
            } else if platform == 1 && encoding == 0 {
                text = latin1(raw)
            } else {
                continue
            }
            let t = text.trimmed
            if t.isEmpty { continue }
            let languageScore: Int
            if platform == 3 && language == 0x0404 { languageScore = 40 } // zh-TW
            else if platform == 3 && (language == 0x0C04 || language == 0x1404) { languageScore = 35 } // zh-HK, zh-MO
            else if platform == 3 && (language == 0x0804 || language == 0x1004) { languageScore = 30 } // zh-CN, zh-SG
            else if platform == 3 && language == 0x0409 { languageScore = 20 } // en-US
            else if platform == 0 { languageScore = 10 }
            else { languageScore = 5 }
            let score = languageScore + (nameId == 16 ? 1 : 0)
            if best == nil || score > best!.score { best = (t, score) }
        }
        return best?.text
    }

    private static func utf16BE(_ b: [UInt8]) -> String {
        var units = [UInt16]()
        var i = 0
        while i + 1 < b.count {
            units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func u16(_ b: [UInt8], _ i: Int) throws -> Int {
        guard i >= 0, i + 2 <= b.count else { throw InvalidFontError(message: "Read outside the font") }
        return Int(b[i]) << 8 | Int(b[i + 1])
    }

    private static func u32(_ b: [UInt8], _ i: Int) throws -> Int64 {
        guard i >= 0, i + 4 <= b.count else { throw InvalidFontError(message: "Read outside the font") }
        return Int64(b[i]) << 24 | Int64(b[i + 1]) << 16 | Int64(b[i + 2]) << 8 | Int64(b[i + 3])
    }
}
