import Foundation

/// SHA-1 (FIPS 180-4), for EPUB font de-obfuscation only (not for security). CryptoKit is not available on Linux.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301, h1: UInt32 = 0xEFCD_AB89, h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476, h4: UInt32 = 0xC3D2_E1F0
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0 ..< 8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 80)
        var chunk = 0
        while chunk < data.count {
            for i in 0 ..< 16 {
                let p = chunk + i * 4
                w[i] = UInt32(data[p]) << 24 | UInt32(data[p + 1]) << 16 | UInt32(data[p + 2]) << 8 | UInt32(data[p + 3])
            }
            for i in 16 ..< 80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0 ..< 80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0 ..< 20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20 ..< 40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40 ..< 60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = b << 30 | b >> 2
                b = a
                a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
            chunk += 64
        }
        var out = [UInt8]()
        for h in [h0, h1, h2, h3, h4] {
            out.append(UInt8(h >> 24)); out.append(UInt8(truncatingIfNeeded: h >> 16))
            out.append(UInt8(truncatingIfNeeded: h >> 8)); out.append(UInt8(truncatingIfNeeded: h))
        }
        return out
    }
}
