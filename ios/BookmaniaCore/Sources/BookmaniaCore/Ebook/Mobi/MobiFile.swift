import Foundation

// Swift port of parts of foliate-js mobi.js (MIT License, Copyright (c) 2022 John Factotum), via core/ebook.

/// Header values of one MOBI "record 0" (the MOBI 6 part or the KF8 part of a file).
final class MobiHeaders {
    let compression: Int
    let numTextRecords: Int
    let encryption: Int
    let headerLength: Int
    let encodingValue: Int64
    let uid: Int64
    let version: Int64
    let titleOffset: Int
    let titleLength: Int
    let localeLanguage: Int
    let localeRegion: Int
    let firstResource: Int64
    let huffRecord: Int64
    let huffCount: Int64
    let exthFlags: Int64
    let extraDataFlags: Int
    let ncxIndex: Int64
    let fdst: Int64
    let fragIndex: Int64
    let skelIndex: Int64
    let guideIndex: Int64
    let exth: [Int: [[UInt8]]]
    let title: [UInt8]

    init(_ record0: [UInt8]) throws {
        compression = try be16(record0, 0)
        numTextRecords = try be16(record0, 8)
        encryption = try be16(record0, 12)
        if ascii(record0, 16, 4) != "MOBI" { throw BookError.corrupt("Missing MOBI header") }
        headerLength = Int(try be32(record0, 20))
        encodingValue = try be32(record0, 28)
        uid = try be32(record0, 32)
        version = try be32(record0, 36)
        titleOffset = Int(try be32(record0, 84))
        titleLength = Int(try be32(record0, 88))
        guard record0.count > 95 else { throw BookError.corrupt("Read outside a record") }
        localeRegion = Int(record0[94])
        localeLanguage = Int(record0[95])
        firstResource = be32or(record0, 108, nullIndex)
        huffRecord = be32or(record0, 112, nullIndex)
        huffCount = be32or(record0, 116, 0)
        exthFlags = be32or(record0, 128, 0)
        let headerEnd = 16 + headerLength
        extraDataFlags = headerLength >= 0xE4 && 244 <= record0.count ? ((try? be16(record0, 242)) ?? 0) : 0
        ncxIndex = headerEnd >= 248 ? be32or(record0, 244, nullIndex) : nullIndex
        let kf8 = version >= 8
        fdst = kf8 ? be32or(record0, 192, nullIndex) : nullIndex
        fragIndex = kf8 ? be32or(record0, 248, nullIndex) : nullIndex
        skelIndex = kf8 ? be32or(record0, 252, nullIndex) : nullIndex
        guideIndex = kf8 ? be32or(record0, 260, nullIndex) : nullIndex
        exth = exthFlags & 0x40 != 0 ? MobiHeaders.readExth(record0, headerEnd) : [:]
        if titleOffset >= 0 && titleOffset < record0.count {
            title = Array(record0[titleOffset ..< min(record0.count, titleOffset + max(0, titleLength))])
        } else {
            title = []
        }
    }

    var encoding: TextEncoding { encodingValue == 65001 ? .utf8 : .windows1252 }

    func exthString(_ type: Int) -> String? {
        guard let first = exth[type]?.first else { return nil }
        return encoding.decode(first).trimmed.nilIfEmpty
    }

    func exthStrings(_ type: Int) -> [String] {
        (exth[type] ?? []).map { encoding.decode($0).trimmed }.filter { !$0.isEmpty }
    }

    func exthUint(_ type: Int) -> Int64? {
        guard let b = exth[type]?.first else { return nil }
        var v: Int64 = 0
        for x in b { v = v << 8 | Int64(x) }
        return v
    }

    private static func readExth(_ record0: [UInt8], _ start: Int) -> [Int: [[UInt8]]] {
        if ascii(record0, start, 4) != "EXTH" { return [:] }
        guard let count = try? be32(record0, start + 8) else { return [:] }
        var out = [Int: [[UInt8]]]()
        var p = start + 12
        var i: Int64 = 0
        while i < count {
            if p + 8 > record0.count { break }
            guard let type = try? be32(record0, p), let length64 = try? be32(record0, p + 4) else { break }
            let length = Int(length64)
            if length < 8 || p + length > record0.count { break }
            out[Int(type), default: []].append(Array(record0[p + 8 ..< p + length]))
            p += length
            i += 1
        }
        return out
    }
}

/// A MOBI/KF8 file: PDB record table plus the headers of the part that will be read. For "joint" files (MOBI 6 +
/// KF8) the KF8 part is used, like Kindle devices do.
final class MobiFile {
    private let source: RandomAccessSource
    private let offsets: [Int64]
    let numRecords: Int

    /// Headers of the first record 0 (the MOBI 6 part in joint files).
    let baseHeaders: MobiHeaders
    /// Headers of the part being read.
    let headers: MobiHeaders
    /// Record index of the part's record 0 (0, or the KF8 boundary).
    let start: Int
    let isKf8: Bool
    /// Absolute record index of resource #1 (images, fonts …).
    let resourceStart: Int64

    private let lock = NSLock()
    private var huffCache: HuffCdic?
    private var fullTextCache: [UInt8]?

    init(_ source: RandomAccessSource) throws {
        self.source = source
        if source.size < 86 { throw BookError.corrupt("File too small for a MOBI book") }
        let head = try source.read(at: 0, count: 78)
        numRecords = try be16(head, 76)
        if numRecords < 2 { throw BookError.corrupt("No records in the MOBI file") }
        let table = try source.read(at: 78, count: numRecords * 8)
        var offs = [Int64]()
        offs.reserveCapacity(numRecords)
        for i in 0 ..< numRecords { offs.append(try be32(table, i * 8)) }
        for i in 0 ..< numRecords {
            let end = i + 1 < numRecords ? offs[i + 1] : source.size
            if offs[i] < 78 + Int64(numRecords) * 8 || offs[i] > end || end > source.size {
                throw BookError.corrupt("Bad MOBI record table")
            }
        }
        offsets = offs
        baseHeaders = try MobiHeaders(MobiFile.readRecord(source, offs, 0))
        if baseHeaders.encryption != 0 {
            throw BookError.drmProtected(scheme: baseHeaders.encryption == 1 ? "Mobipocket (legacy)" : "Mobipocket / Kindle")
        }
        resourceStart = baseHeaders.firstResource
        var h = baseHeaders
        var s = 0
        var kf8 = baseHeaders.version >= 8
        if !kf8, let boundary = baseHeaders.exthUint(121), boundary >= 1, boundary < Int64(numRecords) {
            if let record = try? MobiFile.readRecord(source, offs, Int(boundary)), let kf8Headers = try? MobiHeaders(record),
               kf8Headers.version >= 8 {
                h = kf8Headers
                s = Int(boundary)
                kf8 = true
            }
        }
        if h.encryption != 0 { throw BookError.drmProtected(scheme: "Mobipocket / Kindle") }
        headers = h
        start = s
        isKf8 = kf8
    }

    private static func readRecord(_ source: RandomAccessSource, _ offsets: [Int64], _ i: Int) throws -> [UInt8] {
        if i < 0 || i >= offsets.count { throw BookError.corrupt("Record \(i) out of range") }
        let begin = offsets[i]
        let end = i + 1 < offsets.count ? offsets[i + 1] : source.size
        let length = end - begin
        if length > 64 << 20 { throw BookError.corrupt("Record \(i) is too large") }
        return try source.read(at: begin, count: Int(length))
    }

    func record(_ i: Int) throws -> [UInt8] { try MobiFile.readRecord(source, offsets, i) }

    func magic(_ i: Int) -> String {
        if i < 0 || i >= numRecords { return "" }
        let end = i + 1 < numRecords ? offsets[i + 1] : source.size
        if end - offsets[i] < 4 { return "" }
        guard let b = try? source.read(at: offsets[i], count: 4) else { return "" }
        return latin1(b)
    }

    /// Record relative to the part being read.
    func partRecord(_ i: Int64) throws -> [UInt8] { try record(start + Int(i)) }

    private func huff() throws -> HuffCdic? {
        if headers.compression != 17480 { return nil }
        if let h = huffCache { return h }
        let first = start + Int(headers.huffRecord)
        var cdic = [[UInt8]]()
        if headers.huffCount > 1 {
            for k in 1 ..< Int(headers.huffCount) { cdic.append(try record(first + k)) }
        }
        let h = try HuffCdic(huffRecord: try record(first), cdicRecords: cdic)
        huffCache = h
        return h
    }

    /// Decompressed text of text record `i` (0-based), trailing entries removed.
    func text(_ i: Int) throws -> [UInt8] {
        let data = try record(start + 1 + i)
        var end = data.count
        let flags = headers.extraDataFlags
        var f = flags >> 1
        while f != 0 {
            if f & 1 != 0 { end -= varLenFromEnd(data, max(0, end)) }
            f >>= 1
        }
        if flags & 1 != 0 && end > 0 { end -= Int(data[end - 1] & 0x3) + 1 }
        if end < 0 { throw BookError.corrupt("Bad trailing entries in text record \(i)") }
        let trimmed = Array(data[0 ..< end])
        switch headers.compression {
        case 1: return trimmed
        case 2: return try PalmDoc.decompress(trimmed)
        case 17480:
            guard let h = try huff() else { throw BookError.corrupt("Missing HUFF records") }
            return try h.decompress(trimmed)
        default: throw BookError.corrupt("Unknown MOBI compression \(headers.compression)")
        }
    }

    /// All text of the part, decompressed and concatenated (computed once).
    func fullText() throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let t = fullTextCache { return t }
        var out = [UInt8]()
        for i in 0 ..< headers.numTextRecords {
            out.append(contentsOf: try text(i))
            if out.count > MobiFile.maxText { throw BookError.corrupt("Book text is too large") }
        }
        fullTextCache = out
        return out
    }

    /// Raw bytes of resource number `id` (1-based, as in `recindex` and `kindle:embed`).
    func resource(_ id: Int) throws -> [UInt8]? {
        if resourceStart == nullIndex || id < 1 { return nil }
        let index = resourceStart + Int64(id) - 1
        if index >= Int64(numRecords) { return nil }
        let data = try record(Int(index))
        switch ascii(data, 0, 4) {
        case "FONT": return try MobiFile.decodeFont(data)
        case "VIDE", "AUDI": return Array(data[min(12, data.count)...])
        default: return data
        }
    }

    func resourceMagic(_ id: Int) -> String {
        if resourceStart == nullIndex || id < 1 { return "" }
        return magic(Int(resourceStart) + id - 1)
    }

    private static let maxText = 256 << 20

    /// FONT records: optionally XOR-obfuscated, optionally zlib-compressed.
    static func decodeFont(_ record: [UInt8]) throws -> [UInt8] {
        let flags = try be32(record, 8)
        let dataStart = Int(try be32(record, 12))
        let keyLength = Int(try be32(record, 16))
        let keyStart = Int(try be32(record, 20))
        if dataStart < 0 || dataStart > record.count { throw BookError.corrupt("Bad FONT record") }
        var data = Array(record[dataStart...])
        if flags & 2 != 0 && keyLength > 0 && keyStart + keyLength <= record.count {
            let key = Array(record[keyStart ..< keyStart + keyLength])
            let n = min(keyLength == 16 ? 1024 : 1040, data.count)
            for i in 0 ..< n { data[i] ^= key[i % key.count] }
        }
        if flags & 1 != 0 {
            return (try? Inflate.zlib(data, maxOutput: 64 << 20)) ?? data
        }
        return data
    }
}
