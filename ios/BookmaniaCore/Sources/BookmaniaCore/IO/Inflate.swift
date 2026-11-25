import Foundation

/// DEFLATE decompression (RFC 1951), with the zlib (RFC 1950) and gzip (RFC 1952) wrappers. Written in Swift so the
/// same code runs on iOS and in the Linux unit tests. The structure follows zlib's reference decoder "puff"
/// (Mark Adler): canonical Huffman codes decoded from code-length counts.
enum Inflate {

    /// Raw DEFLATE data. Throws `BookError.corrupt` for bad or truncated data, or when the output would grow past
    /// `maxOutput` bytes (decompression bombs, entries larger than declared).
    static func raw(_ input: [UInt8], maxOutput: Int, expectedSize: Int? = nil) throws -> [UInt8] {
        var state = State(input: input, maxOutput: maxOutput)
        state.out.reserveCapacity(min(maxOutput, expectedSize ?? input.count * 3))
        try state.run()
        return state.out
    }

    /// zlib stream: 2-byte header, DEFLATE data, Adler-32 (not checked).
    static func zlib(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        guard input.count >= 2 else { throw BookError.corrupt("zlib data too short") }
        let cmf = Int(input[0]), flg = Int(input[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0 else { throw BookError.corrupt("Not zlib data") }
        guard flg & 0x20 == 0 else { throw BookError.corrupt("zlib preset dictionary not supported") }
        return try raw(Array(input[2...]), maxOutput: maxOutput)
    }

    /// gzip member: header (with optional extra, name, comment and header CRC), DEFLATE data, CRC-32, size.
    static func gzip(_ input: [UInt8], maxOutput: Int) throws -> [UInt8] {
        guard input.count >= 18, input[0] == 0x1F, input[1] == 0x8B, input[2] == 8 else {
            throw BookError.corrupt("Not gzip data")
        }
        let flags = input[3]
        var p = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= input.count else { throw BookError.corrupt("Bad gzip header") }
            p += 2 + (Int(input[p]) | Int(input[p + 1]) << 8)
        }
        if flags & 0x08 != 0 { while p < input.count && input[p] != 0 { p += 1 }; p += 1 } // FNAME
        if flags & 0x10 != 0 { while p < input.count && input[p] != 0 { p += 1 }; p += 1 } // FCOMMENT
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p < input.count else { throw BookError.corrupt("Bad gzip header") }
        let out = try raw(Array(input[p...]), maxOutput: maxOutput)
        return out
    }

    private struct Huffman {
        var count = [Int](repeating: 0, count: maxBits + 1)
        var symbol: [Int]

        init(lengths: ArraySlice<Int>) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for len in lengths { count[len] += 1 }
            if count[0] == lengths.count { return } // no codes: complete, but decoding will fail
            var left = 1
            for len in 1 ... maxBits {
                left <<= 1
                left -= count[len]
                if left < 0 { throw BookError.corrupt("Over-subscribed Huffman code") }
            }
            var offs = [Int](repeating: 0, count: maxBits + 1)
            for len in 1 ..< maxBits { offs[len + 1] = offs[len] + count[len] }
            for (i, len) in lengths.enumerated() where len != 0 {
                symbol[offs[len]] = i
                offs[len] += 1
            }
            // An incomplete code is allowed only for a single length-1 code (RFC 1951 3.2.7); puff checks this per
            // use, here a bad code simply fails to decode.
        }
    }

    private static let maxBits = 15
    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 0, count: 288 + 30)
        for i in 0 ..< 144 { lengths[i] = 8 }
        for i in 144 ..< 256 { lengths[i] = 9 }
        for i in 256 ..< 280 { lengths[i] = 7 }
        for i in 280 ..< 288 { lengths[i] = 8 }
        for i in 288 ..< 318 { lengths[i] = 5 }
        // swiftlint:disable:next force_try
        return (try! Huffman(lengths: lengths[0 ..< 288]), try! Huffman(lengths: lengths[288 ..< 318]))
    }()

    private struct State {
        let input: [UInt8]
        let maxOutput: Int
        var pos = 0
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var out: [UInt8] = []

        init(input: [UInt8], maxOutput: Int) {
            self.input = input
            self.maxOutput = maxOutput
        }

        @inline(__always) mutating func bits(_ need: Int) throws -> Int {
            while bitCount < need {
                guard pos < input.count else { throw BookError.corrupt("Unexpected end of compressed data") }
                bitBuffer |= UInt64(input[pos]) << UInt64(bitCount)
                pos += 1
                bitCount += 8
            }
            let value = Int(bitBuffer & ((1 << UInt64(need)) - 1))
            bitBuffer >>= UInt64(need)
            bitCount -= need
            return value
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1 ... Inflate.maxBits {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw BookError.corrupt("Bad Huffman code")
        }

        mutating func run() throws {
            var last = false
            repeat {
                last = try bits(1) == 1
                switch try bits(2) {
                case 0: try stored()
                case 1: try codes(Inflate.fixedTables.0, Inflate.fixedTables.1)
                case 2: try dynamic()
                default: throw BookError.corrupt("Invalid block type")
                }
            } while !last
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard pos + 4 <= input.count else { throw BookError.corrupt("Unexpected end of compressed data") }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            pos += 4
            guard len == (~nlen & 0xFFFF) else { throw BookError.corrupt("Bad stored block length") }
            guard pos + len <= input.count else { throw BookError.corrupt("Unexpected end of compressed data") }
            guard out.count + len <= maxOutput else { throw BookError.corrupt("Data larger than declared") }
            out.append(contentsOf: input[pos ..< pos + len])
            pos += len
        }

        mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
            while true {
                var symbol = try decode(lencode)
                if symbol < 256 {
                    guard out.count < maxOutput else { throw BookError.corrupt("Data larger than declared") }
                    out.append(UInt8(symbol))
                } else if symbol == 256 {
                    return
                } else {
                    symbol -= 257
                    guard symbol < 29 else { throw BookError.corrupt("Bad length code") }
                    let length = Inflate.lengthBase[symbol] + (try bits(Inflate.lengthExtra[symbol]))
                    let ds = try decode(distcode)
                    guard ds < 30 else { throw BookError.corrupt("Bad distance code") }
                    let dist = Inflate.distBase[ds] + (try bits(Inflate.distExtra[ds]))
                    guard dist <= out.count else { throw BookError.corrupt("Distance too far back") }
                    guard out.count + length <= maxOutput else { throw BookError.corrupt("Data larger than declared") }
                    var from = out.count - dist
                    for _ in 0 ..< length {
                        out.append(out[from])
                        from += 1
                    }
                }
            }
        }

        mutating func dynamic() throws {
            let nlen = try bits(5) + 257
            let ndist = try bits(5) + 1
            let ncode = try bits(4) + 4
            guard nlen <= 286, ndist <= 30 else { throw BookError.corrupt("Bad dynamic block counts") }
            var lengths = [Int](repeating: 0, count: 320)
            for i in 0 ..< ncode { lengths[Inflate.codeLengthOrder[i]] = try bits(3) }
            let lencode = try Huffman(lengths: lengths[0 ..< 19])
            var index = 0
            while index < nlen + ndist {
                var symbol = try decode(lencode)
                if symbol < 16 {
                    lengths[index] = symbol
                    index += 1
                } else {
                    var len = 0
                    if symbol == 16 {
                        guard index > 0 else { throw BookError.corrupt("Repeat with no first length") }
                        len = lengths[index - 1]
                        symbol = 3 + (try bits(2))
                    } else if symbol == 17 {
                        symbol = 3 + (try bits(3))
                    } else {
                        symbol = 11 + (try bits(7))
                    }
                    guard index + symbol <= nlen + ndist else { throw BookError.corrupt("Too many code lengths") }
                    for _ in 0 ..< symbol {
                        lengths[index] = len
                        index += 1
                    }
                }
            }
            guard lengths[256] != 0 else { throw BookError.corrupt("No end-of-block code") }
            let litLen = try Huffman(lengths: lengths[0 ..< nlen])
            let dist = try Huffman(lengths: lengths[nlen ..< nlen + ndist])
            try codes(litLen, dist)
        }
    }
}
