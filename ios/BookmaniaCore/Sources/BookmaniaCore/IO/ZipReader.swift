import Foundation

/// Minimal ZIP reader working on a `RandomAccessSource` (no temporary copies). Reads the central directory once;
/// entries are decompressed on demand. Supports STORED and DEFLATED entries and ZIP64. Decompressed sizes are
/// capped to defend against decompression bombs. (Port of core/ebook `ZipReader.kt`.)
public final class ZipReader {

    public struct Entry: Sendable {
        public let name: String
        public let method: Int
        public let flags: Int
        public let compressedSize: Int64
        public let size: Int64
        public let localHeaderOffset: Int64

        public var isDirectory: Bool { name.hasSuffix("/") }
        public var isEncrypted: Bool { flags & 1 != 0 }
    }

    public struct Limits: Sendable {
        public var maxEntries: Int64 = 50_000
        public var maxEntrySize: Int64 = 512 << 20
        public var maxCompressionRatio: Int64 = 2_000

        public init(maxEntries: Int64 = 50_000, maxEntrySize: Int64 = 512 << 20, maxCompressionRatio: Int64 = 2_000) {
            self.maxEntries = maxEntries
            self.maxEntrySize = maxEntrySize
            self.maxCompressionRatio = maxCompressionRatio
        }
    }

    private let source: RandomAccessSource
    private let limits: Limits

    /// Entries keyed by their exact name.
    public let entries: [String: Entry]
    /// Entry names in central-directory order.
    public let names: [String]
    private let lowerCaseIndex: [String: String]

    public init(source: RandomAccessSource, limits: Limits = Limits()) throws {
        self.source = source
        self.limits = limits
        let list: [Entry]
        do {
            list = try ZipReader.readCentralDirectory(source, limits)
        } catch let e as BookError {
            throw e
        } catch {
            throw BookError.unreadable("Cannot read the ZIP directory")
        }
        var map = [String: Entry]()
        var order = [String]()
        var lower = [String: String]()
        for e in list {
            if map[e.name] == nil { order.append(e.name) }
            map[e.name] = e
            let key = e.name.lowercased()
            if lower[key] == nil { lower[key] = e.name }
        }
        entries = map
        names = order
        lowerCaseIndex = lower
    }

    public func has(_ name: String) -> Bool { find(name) != nil }

    /// Exact match first, then a case-insensitive match (some books get the case of links wrong).
    public func find(_ name: String) -> Entry? {
        if let e = entries[name] { return e }
        if let actual = lowerCaseIndex[name.lowercased()] { return entries[actual] }
        return nil
    }

    /// Decompressed bytes of an entry, or nil when it does not exist.
    public func readBytes(_ name: String) throws -> [UInt8]? {
        guard let e = find(name) else { return nil }
        return try read(e)
    }

    public func readText(_ name: String) throws -> String? {
        guard let bytes = try readBytes(name) else { return nil }
        return utf8(bytes)
    }

    public func read(_ e: Entry) throws -> [UInt8] {
        if e.isEncrypted { throw BookError.corrupt("Encrypted ZIP entry: \(e.name)") }
        if e.size > limits.maxEntrySize { throw BookError.corrupt("Entry too large: \(e.name)") }
        let header = try source.read(at: e.localHeaderOffset, count: 30)
        if try le32(header, 0) != ZipReader.localSig { throw BookError.corrupt("Bad local header for \(e.name)") }
        let dataStart = e.localHeaderOffset + 30 + Int64(try le16(header, 26)) + Int64(try le16(header, 28))
        guard e.compressedSize >= 0, e.compressedSize <= Int64(Int.max / 2) else { throw BookError.corrupt("Bad entry size: \(e.name)") }
        let raw = try source.read(at: dataStart, count: Int(e.compressedSize))
        let cap = Int(min(e.size, limits.maxEntrySize))
        switch e.method {
        case 0:
            return raw
        case 8:
            if e.compressedSize > 0 && e.size / e.compressedSize > limits.maxCompressionRatio {
                throw BookError.corrupt("Suspicious compression ratio: \(e.name)")
            }
            do {
                return try Inflate.raw(raw, maxOutput: cap, expectedSize: cap)
            } catch let error as BookError {
                if case let .corrupt(message) = error { throw BookError.corrupt("\(message): \(e.name)") }
                throw error
            }
        default:
            throw BookError.corrupt("Unsupported compression method \(e.method): \(e.name)")
        }
    }

    public func close() { source.close() }

    private static let localSig: Int64 = 0x0403_4b50
    private static let centralSig: Int64 = 0x0201_4b50
    private static let eocdSig: Int64 = 0x0605_4b50
    private static let zip64EocdSig: Int64 = 0x0606_4b50
    private static let zip64LocatorSig: Int64 = 0x0706_4b50

    private static func readCentralDirectory(_ source: RandomAccessSource, _ limits: Limits) throws -> [Entry] {
        let size = source.size
        if size < 22 { throw BookError.unreadable("File too small to be a ZIP archive") }
        let tailLen = Int(min(size, 22 + 0xFFFF))
        let tailStart = size - Int64(tailLen)
        let tail = try source.read(at: tailStart, count: tailLen)
        var eocd = -1
        var i = tailLen - 22
        while i >= 0 {
            if try le32(tail, i) == eocdSig { eocd = i; break }
            i -= 1
        }
        if eocd < 0 { throw BookError.unreadable("ZIP end-of-directory record not found (file truncated?)") }
        var total = Int64(try le16(tail, eocd + 10))
        var cdSize = try le32(tail, eocd + 12)
        var cdOffset = try le32(tail, eocd + 16)
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: the locator sits right before the classic record.
            let locAt = tailStart + Int64(eocd) - 20
            if locAt >= 0 {
                let loc = try source.read(at: locAt, count: 20)
                if try le32(loc, 0) == zip64LocatorSig {
                    let z64At = try le64(loc, 8)
                    let z64 = try source.read(at: z64At, count: 56)
                    if try le32(z64, 0) != zip64EocdSig { throw BookError.corrupt("Bad ZIP64 directory record") }
                    total = try le64(z64, 32)
                    cdSize = try le64(z64, 40)
                    cdOffset = try le64(z64, 48)
                }
            }
        }
        if total > limits.maxEntries { throw BookError.corrupt("Too many ZIP entries: \(total)") }
        if cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > size { throw BookError.corrupt("ZIP directory outside the file") }
        let cd = try source.read(at: cdOffset, count: Int(cdSize))
        var out = [Entry]()
        out.reserveCapacity(Int(total))
        var p = 0
        var n: Int64 = 0
        while n < total {
            if p + 46 > cd.count { throw BookError.corrupt("Bad ZIP directory entry #\(n)") }
            if try le32(cd, p) != centralSig { throw BookError.corrupt("Bad ZIP directory entry #\(n)") }
            let flags = try le16(cd, p + 8)
            let method = try le16(cd, p + 10)
            var csize = try le32(cd, p + 20)
            var usize = try le32(cd, p + 24)
            let nameLen = try le16(cd, p + 28)
            let extraLen = try le16(cd, p + 30)
            let commentLen = try le16(cd, p + 32)
            var lho = try le32(cd, p + 42)
            guard p + 46 + nameLen <= cd.count else { throw BookError.corrupt("Bad ZIP directory entry #\(n)") }
            let nameBytes = Array(cd[p + 46 ..< p + 46 + nameLen])
            let name = decodeName(nameBytes, utf8Flag: flags & 0x800 != 0)
            // ZIP64 extra field (0x0001): only the fields that overflowed are present, in order.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = try le16(cd, e)
                let len = try le16(cd, e + 2)
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF { usize = try le64(cd, q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = try le64(cd, q); q += 8 }
                    if lho == 0xFFFF_FFFF { lho = try le64(cd, q) }
                }
                e += 4 + len
            }
            if lho < 0 || lho >= size { throw BookError.corrupt("ZIP entry outside the file: \(name)") }
            out.append(Entry(name: name, method: method, flags: flags, compressedSize: csize, size: usize, localHeaderOffset: lho))
            p += 46 + nameLen + extraLen + commentLen
            n += 1
        }
        return out
    }

    /// Names without the UTF-8 flag are usually UTF-8 anyway in e-books; fall back to CP437 otherwise.
    private static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if utf8Flag { return utf8(bytes) }
        if let s = String(validating: bytes, as: UTF8.self) { return s }
        return cp437(bytes)
    }
}

/// IBM code page 437 (the original ZIP file name encoding).
func cp437(_ bytes: [UInt8]) -> String {
    var s = String.UnicodeScalarView()
    for b in bytes {
        if b < 0x80 {
            s.append(Unicode.Scalar(b))
        } else {
            s.append(cp437High[Int(b) - 0x80])
        }
    }
    return String(s)
}

private let cp437High: [Unicode.Scalar] = Array(
    "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}".unicodeScalars
)
