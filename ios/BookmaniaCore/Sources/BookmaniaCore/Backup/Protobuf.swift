import Foundation

/// A minimal Protocol Buffers writer and reader, enough for Android's backup format (kotlinx.serialization ProtoBuf:
/// varint integers and booleans, 32-bit floats, length-delimited strings, bytes and messages; repeated fields written
/// one element per field, packed ones accepted when reading).
public struct ProtoWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ wireType: Int) { varint(UInt64(field << 3 | wireType)) }

    /// int32 / int64 (negative numbers take ten bytes, as protobuf requires).
    public mutating func int(_ field: Int, _ value: Int64) {
        tag(field, 0)
        varint(UInt64(bitPattern: value))
    }

    public mutating func int(_ field: Int, _ value: Int) { int(field, Int64(value)) }

    public mutating func bool(_ field: Int, _ value: Bool) {
        tag(field, 0)
        varint(value ? 1 : 0)
    }

    public mutating func float(_ field: Int, _ value: Float) {
        tag(field, 5)
        let bits = value.bitPattern
        for i in 0 ..< 4 { bytes.append(UInt8((bits >> (8 * UInt32(i))) & 0xFF)) }
    }

    public mutating func data(_ field: Int, _ value: [UInt8]) {
        tag(field, 2)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func string(_ field: Int, _ value: String) { data(field, Array(value.utf8)) }

    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        data(field, inner.bytes)
    }
}

/// One field read from a message.
public struct ProtoField {
    public let number: Int
    public let wireType: Int
    /// The varint, or the 32 / 64 bits of a fixed field.
    public let integer: UInt64
    /// The bytes of a length-delimited field.
    public let payload: ArraySlice<UInt8>

    public var int64: Int64 { Int64(bitPattern: integer) }
    /// int32: the low 32 bits, as protobuf decodes a 64-bit varint into int32.
    public var int32: Int { Int(Int32(truncatingIfNeeded: Int64(bitPattern: integer))) }
    public var bool: Bool { integer != 0 }
    public var float: Float { Float(bitPattern: UInt32(truncatingIfNeeded: integer)) }
    public var string: String { String(decoding: payload, as: UTF8.self) }
    public var bytes: [UInt8] { Array(payload) }

    /// The varints of a packed repeated field, or this field's own value when it is not packed.
    public var ints: [Int64] {
        if wireType != 2 { return [int64] }
        var r = ProtoReader(payload)
        var out = [Int64]()
        while let v = try? r.readVarint() { out.append(Int64(bitPattern: v)) }
        return out
    }
}

public struct ProtoError: Error, CustomStringConvertible {
    public let description: String
}

public struct ProtoReader {
    private let data: ArraySlice<UInt8>
    private var position: Int

    public init(_ data: ArraySlice<UInt8>) {
        self.data = data
        position = data.startIndex
    }

    public init(_ data: [UInt8]) { self.init(data[...]) }

    public var atEnd: Bool { position >= data.endIndex }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < data.endIndex else { throw ProtoError(description: "Truncated varint") }
            let b = data[position]
            position += 1
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { throw ProtoError(description: "Varint too long") }
        }
    }

    /// The next field, or nil at the end of the message.
    public mutating func next() throws -> ProtoField? {
        if atEnd { return nil }
        let key = try readVarint()
        let number = Int(key >> 3), wireType = Int(key & 7)
        guard number > 0 else { throw ProtoError(description: "Bad field number") }
        switch wireType {
        case 0:
            return ProtoField(number: number, wireType: 0, integer: try readVarint(), payload: [])
        case 1, 5:
            let size = wireType == 1 ? 8 : 4
            guard position + size <= data.endIndex else { throw ProtoError(description: "Truncated fixed field") }
            var v: UInt64 = 0
            for i in 0 ..< size { v |= UInt64(data[position + i]) << (8 * UInt64(i)) }
            position += size
            return ProtoField(number: number, wireType: wireType, integer: v, payload: [])
        case 2:
            let length = try readVarint()
            guard length <= UInt64(data.endIndex - position) else { throw ProtoError(description: "Truncated field \(number)") }
            let start = position
            position += Int(length)
            return ProtoField(number: number, wireType: 2, integer: length, payload: data[start ..< position])
        default:
            throw ProtoError(description: "Unsupported wire type \(wireType)")
        }
    }

    /// Every field of the message.
    public static func fields(_ data: ArraySlice<UInt8>) throws -> [ProtoField] {
        var reader = ProtoReader(data)
        var out = [ProtoField]()
        while let field = try reader.next() { out.append(field) }
        return out
    }
}

/// gzip, as Android's backups are written: the reader accepts any deflate stream (Inflate.gzip); the writer uses
/// stored (uncompressed) deflate blocks, which every inflater reads.
public enum Gzip {
    public static func compress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]
        var offset = 0
        repeat {
            let size = min(65_535, data.count - offset)
            let final = offset + size >= data.count
            out.append(final ? 1 : 0) // BFINAL, BTYPE 00 (stored)
            out.append(UInt8(size & 0xFF))
            out.append(UInt8(size >> 8))
            out.append(UInt8(~size & 0xFF))
            out.append(UInt8((~size >> 8) & 0xFF))
            out.append(contentsOf: data[offset ..< offset + size])
            offset += size
        } while offset < data.count
        let crc = crc32(data)
        for i in 0 ..< 4 { out.append(UInt8((crc >> (8 * UInt32(i))) & 0xFF)) }
        let size = UInt32(truncatingIfNeeded: data.count)
        for i in 0 ..< 4 { out.append(UInt8((size >> (8 * UInt32(i))) & 0xFF)) }
        return out
    }

    public static func isGzip(_ data: [UInt8]) -> Bool { data.count > 2 && data[0] == 0x1F && data[1] == 0x8B }

    private static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
