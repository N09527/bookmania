import Foundation

// Format knowledge: MobileRead wiki ("MOBI", "PalmDOC", "KF8") and foliate-js `mobi.js` (MIT License,
// Copyright (c) 2022 John Factotum), which this implementation follows through the Kotlin port in core/ebook;
// see core/ebook/NOTICE-foliate-js.txt.

let nullIndex: Int64 = 0xFFFF_FFFF

/// Forward variable-length integer used in INDX records: the high bit marks the last byte.
func varLen(_ b: [UInt8], _ start: Int) -> (value: Int64, length: Int) {
    var value: Int64 = 0
    var length = 0
    var i = start
    while i < b.count && length < 4 {
        let byte = Int64(b[i])
        value = value << 7 | (byte & 0x7F)
        length += 1
        i += 1
        if byte & 0x80 != 0 { break }
    }
    return (value, length)
}

/// Variable-length integer stored backwards at the end of a text record (trailing entries).
func varLenFromEnd(_ b: [UInt8], _ end: Int) -> Int {
    var value = 0
    var i = max(0, end - 4)
    while i < end {
        let byte = Int(b[i])
        if byte & 0x80 != 0 { value = 0 }
        value = value << 7 | (byte & 0x7F)
        i += 1
    }
    return value
}

func countBitsSet(_ x: Int) -> Int { x.nonzeroBitCount }

func countUnsetEnd(_ x: Int) -> Int { x == 0 ? 0 : x.trailingZeroBitCount }

/// PalmDOC LZ77 decompression.
enum PalmDoc {
    static func decompress(_ input: [UInt8], maxOutput: Int = 1 << 20) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count * 2)
        var i = 0
        while i < input.count {
            let byte = Int(input[i])
            if byte == 0 {
                out.append(0)
            } else if byte <= 8 {
                // copy the next 1-8 bytes literally
                let end = min(i + 1 + byte, input.count)
                if i + 1 < end { out.append(contentsOf: input[i + 1 ..< end]) }
                i += byte
            } else if byte <= 0x7F {
                out.append(UInt8(byte))
            } else if byte <= 0xBF {
                // length-distance pair
                if i + 1 >= input.count { break }
                i += 1
                let pair = byte << 8 | Int(input[i])
                let distance = (pair & 0x3FFF) >> 3
                let length = (pair & 0x7) + 3
                if distance == 0 || distance > out.count { throw BookError.corrupt("Bad PalmDOC back-reference") }
                for _ in 0 ..< length { out.append(out[out.count - distance]) }
            } else {
                // space + character
                out.append(0x20)
                out.append(UInt8(byte ^ 0x80))
            }
            if out.count > maxOutput { throw BookError.corrupt("PalmDOC record decompresses beyond its limit") }
            i += 1
        }
        return out
    }
}

/// HUFF/CDIC ("huffdic") decompression used by many Kindle books.
final class HuffCdic {
    private var table1 = [Int64](repeating: 0, count: 256)
    private var minCode = [Int64](repeating: 0, count: 33)
    private var maxCode = [Int64](repeating: 0, count: 33)
    private var dictionary = [[UInt8]]()
    private var resolved = [Bool]()
    private let lock = NSLock()

    init(huffRecord: [UInt8], cdicRecords: [[UInt8]]) throws {
        if ascii(huffRecord, 0, 4) != "HUFF" { throw BookError.corrupt("Invalid HUFF record") }
        let offset1 = Int(try be32(huffRecord, 8))
        let offset2 = Int(try be32(huffRecord, 12))
        for i in 0 ..< 256 { table1[i] = try be32(huffRecord, offset1 + i * 4) }
        for len in 1 ... 32 {
            minCode[len] = try be32(huffRecord, offset2 + (len - 1) * 8)
            maxCode[len] = try be32(huffRecord, offset2 + (len - 1) * 8 + 4)
        }
        var total: Int64 = -1
        for record in cdicRecords {
            if ascii(record, 0, 4) != "CDIC" { throw BookError.corrupt("Invalid CDIC record") }
            let headerLength = Int(try be32(record, 4))
            if total < 0 { total = try be32(record, 8) }
            let codeLength = Int(try be32(record, 12))
            guard codeLength >= 0 && codeLength < 32 else { throw BookError.corrupt("Invalid CDIC record") }
            let n = Int(min(Int64(1) << codeLength, total - Int64(dictionary.count)))
            if n <= 0 { continue }
            for i in 0 ..< n {
                let offset = try be16(record, headerLength + i * 2)
                let x = try be16(record, headerLength + offset)
                let length = x & 0x7FFF
                let start = headerLength + offset + 2
                if start + length > record.count { throw BookError.corrupt("CDIC entry outside its record") }
                dictionary.append(Array(record[start ..< start + length]))
                resolved.append(x & 0x8000 != 0)
            }
        }
    }

    func decompress(_ input: [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return try decompress(input, depth: 0)
    }

    private func decompress(_ input: [UInt8], depth: Int) throws -> [UInt8] {
        if depth > 32 { throw BookError.corrupt("HUFF/CDIC recursion too deep") }
        var out = [UInt8]()
        out.reserveCapacity(input.count * 3)
        let bitLength = Int64(input.count) * 8
        var pos: Int64 = 0
        while pos < bitLength {
            let bits = read32(input, pos)
            let entry = table1[Int(bits >> 24)]
            var codeLength = Int(entry & 0x1F)
            var value = (entry & 0xFFFF_FFFF) >> 8
            if entry & 0x80 == 0 {
                while codeLength < 32 && (bits >> Int64(32 - codeLength)) < minCode[codeLength] { codeLength += 1 }
                value = maxCode[codeLength]
            }
            if codeLength == 0 { throw BookError.corrupt("Bad HUFF code") }
            pos += Int64(codeLength)
            if pos > bitLength { break }
            let code = Int(value - (bits >> Int64(32 - codeLength)))
            if code < 0 || code >= dictionary.count { throw BookError.corrupt("HUFF code outside the dictionary") }
            if !resolved[code] {
                dictionary[code] = try decompress(dictionary[code], depth: depth + 1)
                resolved[code] = true
            }
            out.append(contentsOf: dictionary[code])
        }
        return out
    }

    /// 32 bits starting at bit `from` (big-endian), zero-padded past the end.
    private func read32(_ b: [UInt8], _ from: Int64) -> Int64 {
        let startByte = Int(from >> 3)
        let shift = Int(from & 7)
        var v: Int64 = 0
        for k in 0 ..< 5 {
            let idx = startByte + k
            v = v << 8 | (idx < b.count ? Int64(b[idx]) : 0)
        }
        return (v >> Int64(8 - shift)) & 0xFFFF_FFFF
    }
}
