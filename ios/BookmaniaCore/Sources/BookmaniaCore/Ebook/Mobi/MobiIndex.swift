import Foundation

// Swift port of parts of foliate-js mobi.js (MIT License, Copyright (c) 2022 John Factotum), via core/ebook.

/// One entry of an INDX table: its name and tag values.
struct IndexEntry {
    let name: String
    let tags: [Int: [Int64]]

    func tag(_ tag: Int, _ i: Int = 0) -> Int64? {
        guard let values = tags[tag], i < values.count else { return nil }
        return values[i]
    }
}

struct IndexData {
    let entries: [IndexEntry]
    let cncx: [Int: String]
}

/// Reads an INDX index (header record, entry records, CNCX string records).
enum MobiIndex {

    static func read(_ firstRecord: Int, _ loadRecord: (Int) throws -> [UInt8], _ fallback: TextEncoding) throws -> IndexData {
        let header = try loadRecord(firstRecord)
        if ascii(header, 0, 4) != "INDX" { throw BookError.corrupt("Invalid INDX record") }
        let headerLength = Int(try be32(header, 4))
        let numRecords = Int(try be32(header, 24))
        let encodingValue = try be32(header, 28)
        let numCncx = Int(try be32(header, 52))
        let encoding: TextEncoding
        switch encodingValue {
        case 65001: encoding = .utf8
        case 1252: encoding = .windows1252
        default: encoding = fallback
        }
        if numRecords < 0 || numRecords > 10_000 || numCncx < 0 || numCncx > 10_000 {
            throw BookError.corrupt("Unreasonable INDX size")
        }

        // TAGX: the tag table describing how entries are encoded.
        if ascii(header, headerLength, 4) != "TAGX" { throw BookError.corrupt("Invalid TAGX section") }
        let tagxLength = Int(try be32(header, headerLength + 4))
        let numControlBytes = Int(try be32(header, headerLength + 8))
        let numTags = max(0, (tagxLength - 12) / 4)
        var tagTable = [[Int]]()
        for i in 0 ..< numTags {
            let p = headerLength + 12 + i * 4
            guard p + 4 <= header.count else { throw BookError.corrupt("Invalid TAGX section") }
            tagTable.append((0 ..< 4).map { Int(header[p + $0]) }) // tag, values per entry, mask, end flag
        }

        // CNCX: strings referenced by offset (records come right after the entry records).
        var cncx = [Int: String]()
        var recordOffset = 0
        for i in 0 ..< numCncx {
            let record = try loadRecord(firstRecord + numRecords + i + 1)
            var pos = 0
            while pos < record.count {
                let index = pos
                let (len, lenBytes) = varLen(record, pos)
                if lenBytes == 0 { break }
                pos += lenBytes
                let end = min(record.count, pos + Int(len))
                cncx[recordOffset + index] = encoding.decode(record[pos ..< max(pos, end)])
                pos = max(pos, end)
            }
            recordOffset += 0x10000
        }

        var entries = [IndexEntry]()
        for r in 0 ..< numRecords {
            let record = try loadRecord(firstRecord + 1 + r)
            if ascii(record, 0, 4) != "INDX" { throw BookError.corrupt("Invalid INDX entry record") }
            let idxt = Int(try be32(record, 20))
            let count = Int(try be32(record, 24))
            for j in 0 ..< count {
                let offset = try be16(record, idxt + 4 + 2 * j)
                guard offset < record.count else { throw BookError.corrupt("Index entry outside its record") }
                let nameLength = Int(record[offset])
                guard offset + 1 + nameLength <= record.count else { throw BookError.corrupt("Index entry outside its record") }
                let name = latin1(record[offset + 1 ..< offset + 1 + nameLength])
                entries.append(IndexEntry(name: name, tags: try readTags(record, offset + 1 + nameLength, numControlBytes, tagTable)))
            }
        }
        return IndexData(entries: entries, cncx: cncx)
    }

    private struct Pending {
        let tag: Int
        let valueCount: Int?
        let valueBytes: Int64?
        let valuesPerEntry: Int
    }

    private static func readTags(_ record: [UInt8], _ startPos: Int, _ numControlBytes: Int, _ tagTable: [[Int]]) throws -> [Int: [Int64]] {
        var controlByteIndex = 0
        var pos = startPos + numControlBytes
        var pending = [Pending]()
        for t in tagTable {
            let (tag, valuesPerEntry, mask, end) = (t[0], t[1], t[2], t[3])
            if end & 1 != 0 {
                controlByteIndex += 1
                continue
            }
            guard startPos + controlByteIndex < record.count else { throw BookError.corrupt("Index entry outside its record") }
            let value = Int(record[startPos + controlByteIndex]) & mask
            if value == mask {
                if countBitsSet(mask) > 1 {
                    let (v, len) = varLen(record, pos)
                    pending.append(Pending(tag: tag, valueCount: nil, valueBytes: v, valuesPerEntry: valuesPerEntry))
                    pos += len
                } else {
                    pending.append(Pending(tag: tag, valueCount: 1, valueBytes: nil, valuesPerEntry: valuesPerEntry))
                }
            } else {
                pending.append(Pending(tag: tag, valueCount: value >> countUnsetEnd(mask), valueBytes: nil, valuesPerEntry: valuesPerEntry))
            }
        }
        var tags = [Int: [Int64]]()
        for p in pending {
            var values = [Int64]()
            if let count = p.valueCount {
                for _ in 0 ..< count * p.valuesPerEntry {
                    let (v, len) = varLen(record, pos)
                    values.append(v)
                    pos += len
                }
            } else {
                var consumed: Int64 = 0
                while consumed < (p.valueBytes ?? 0) {
                    let (v, len) = varLen(record, pos)
                    if len == 0 { break }
                    values.append(v)
                    pos += len
                    consumed += Int64(len)
                }
            }
            tags[p.tag] = values
        }
        return tags
    }
}
