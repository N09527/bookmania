import Foundation

/// EPUB font obfuscation (not DRM): the first bytes of an embedded font are XOR-ed with a key derived from the
/// book's identifier, so fonts cannot be copied out of the ZIP as-is. Reading systems are expected to undo it
/// (EPUB 3 "Font Obfuscation"; Adobe's older variant).
public enum FontObfuscation {
    public static let idpf = "http://www.idpf.org/2008/embedding"
    public static let adobe = "http://ns.adobe.com/pdf/enc#RC"

    public static func isObfuscation(_ algorithm: String) -> Bool { algorithm == idpf || algorithm == adobe }

    /// IDPF: SHA-1 of the unique identifier with all white space removed; first 1040 bytes.
    static func idpfKey(_ uniqueIdentifier: String) -> [UInt8] {
        let cleaned = uniqueIdentifier.filter { $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" && $0 != "\r\n" }
        return SHA1.hash(Array(cleaned.utf8))
    }

    /// Adobe: the 16 bytes of the book's UUID; first 1024 bytes. Nil when no UUID is available.
    static func adobeKey(_ identifier: String) -> [UInt8]? {
        var id = identifier.lowercased()
        if id.hasPrefix("urn:uuid:") { id.removeFirst("urn:uuid:".count) }
        let hex = id.filter { $0.isASCII && ($0.isNumber || ("a" ... "f").contains($0)) }
        guard hex.count == 32 else { return nil }
        let chars = Array(hex)
        return (0 ..< 16).map { UInt8(String(chars[$0 * 2 ... $0 * 2 + 1]), radix: 16)! }
    }

    /// Undoes (or applies; XOR is symmetric) the obfuscation.
    static func xor(_ data: inout [UInt8], key: [UInt8], count: Int) {
        let n = min(count, data.count)
        for i in 0 ..< n { data[i] ^= key[i % key.count] }
    }

    static func deobfuscate(_ data: [UInt8], algorithm: String, uniqueIdentifier: String?, uuidIdentifier: String?) -> [UInt8] {
        var out = data
        switch algorithm {
        case idpf:
            if let id = uniqueIdentifier { xor(&out, key: idpfKey(id), count: 1040) }
        case adobe:
            if let id = uuidIdentifier ?? uniqueIdentifier, let key = adobeKey(id) { xor(&out, key: key, count: 1024) }
        default:
            break
        }
        return out
    }
}
