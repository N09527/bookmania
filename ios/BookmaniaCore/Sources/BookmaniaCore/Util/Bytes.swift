import Foundation

// Byte helpers shared by the ZIP, MOBI and font readers. Reads outside the buffer throw instead of trapping:
// book files are untrusted input.

@inline(__always) func le16(_ b: [UInt8], _ i: Int) throws -> Int {
    guard i >= 0, i + 2 <= b.count else { throw BookError.corrupt("Read outside the data") }
    return Int(b[i]) | Int(b[i + 1]) << 8
}

@inline(__always) func le32(_ b: [UInt8], _ i: Int) throws -> Int64 {
    Int64(try le16(b, i)) | Int64(try le16(b, i + 2)) << 16
}

@inline(__always) func le64(_ b: [UInt8], _ i: Int) throws -> Int64 {
    let lo = UInt64(try le32(b, i)), hi = UInt64(try le32(b, i + 4))
    return Int64(bitPattern: lo | hi << 32)
}

@inline(__always) func be16(_ b: [UInt8], _ i: Int) throws -> Int {
    guard i >= 0, i + 2 <= b.count else { throw BookError.corrupt("Read outside a record") }
    return Int(b[i]) << 8 | Int(b[i + 1])
}

@inline(__always) func be32(_ b: [UInt8], _ i: Int) throws -> Int64 {
    guard i >= 0, i + 4 <= b.count else { throw BookError.corrupt("Read outside a record") }
    return Int64(b[i]) << 24 | Int64(b[i + 1]) << 16 | Int64(b[i + 2]) << 8 | Int64(b[i + 3])
}

/// `be32` with a default when the field lies outside the record (short MOBI headers).
func be32or(_ b: [UInt8], _ i: Int, _ fallback: Int64) -> Int64 {
    (i >= 0 && i + 4 <= b.count) ? ((try? be32(b, i)) ?? fallback) : fallback
}

/// ISO-8859-1 text of `n` bytes at `i`, or "" when out of range.
func ascii(_ b: [UInt8], _ i: Int, _ n: Int) -> String {
    guard i >= 0, n >= 0, i + n <= b.count else { return "" }
    return latin1(b[i ..< i + n])
}

/// One character per byte (U+0000…U+00FF), so offsets in the string are byte offsets.
func latin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var s = String.UnicodeScalarView()
    for byte in bytes { s.append(Unicode.Scalar(byte)) }
    return String(s)
}

/// UTF-8 with invalid sequences replaced by U+FFFD (like `String(bytes, UTF_8)` on the JVM).
func utf8<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    String(decoding: bytes, as: UTF8.self)
}

extension String {
    var utf8Bytes: [UInt8] { Array(self.utf8) }
}

/// Text encodings used by MOBI files.
enum TextEncoding: Sendable {
    case utf8, windows1252, latin1

    func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        switch self {
        case .utf8: return BookmaniaCore.utf8(bytes)
        case .latin1: return BookmaniaCore.latin1(bytes)
        case .windows1252: return cp1252(bytes)
        }
    }
}

/// Windows-1252: Latin-1 except 0x80…0x9F; the five undefined bytes there become U+FFFD.
func cp1252<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var s = String.UnicodeScalarView()
    for byte in bytes {
        if byte >= 0x80 && byte <= 0x9F {
            s.append(cp1252High[Int(byte) - 0x80] ?? "\u{FFFD}")
        } else {
            s.append(Unicode.Scalar(byte))
        }
    }
    return String(s)
}

private let cp1252High: [Unicode.Scalar?] = [
    "\u{20AC}", nil, "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
    "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", nil, "\u{017D}", nil,
    nil, "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
    "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", nil, "\u{017E}", "\u{0178}",
]

/// Whitespace as Kotlin's `Char.isWhitespace()` sees it (space, line and paragraph separators, and the ASCII
/// controls \t \n \u{0B} \f \r \u{1C}…\u{1F}), so character counts match the Android version.
func isKotlinWhitespace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09 ... 0x0D, 0x1C ... 0x1F: return true
    default: break
    }
    switch s.properties.generalCategory {
    case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
    default: return false
    }
}

/// Number of UTF-16 code units of the non-whitespace characters (what a Kotlin `count { !it.isWhitespace() }`
/// over a String returns).
func countNonWhitespaceUTF16(_ s: String) -> Int {
    var n = 0
    for scalar in s.unicodeScalars where !isKotlinWhitespace(scalar) { n += scalar.utf16.count }
    return n
}

extension String {
    /// Kotlin `substringBefore`.
    public func before(_ delimiter: Character) -> String {
        if let i = firstIndex(of: delimiter) { return String(self[..<i]) }
        return self
    }

    /// Kotlin `substringAfter` (the whole string when the delimiter is missing).
    public func after(_ delimiter: Character) -> String {
        if let i = firstIndex(of: delimiter) { return String(self[index(after: i)...]) }
        return self
    }

    /// Kotlin `substringAfterLast(delimiter, missing)`.
    public func afterLast(_ delimiter: Character, missing: String) -> String {
        if let i = lastIndex(of: delimiter) { return String(self[index(after: i)...]) }
        return missing
    }

    /// Kotlin `substringBeforeLast(delimiter, missing)`.
    public func beforeLast(_ delimiter: Character, missing: String) -> String {
        if let i = lastIndex(of: delimiter) { return String(self[..<i]) }
        return missing
    }

    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil for an empty string (Kotlin `ifEmpty { null }`).
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Zero-padded decimal, as `"%05d".format(n)`.
func padded(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}
