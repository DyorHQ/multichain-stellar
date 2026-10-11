import Foundation

/// Stellar's StrKey encoding (SEP-23): version byte · payload · CRC16-XModem (little-endian), base32 without padding.
public enum StrKey {
    public enum Version: UInt8 {
        case accountID = 0x30 // G
        case seed = 0x90 // S
        case contract = 0x10 // C
        case muxed = 0x60 // M

        var expectedLength: Int { self == .muxed ? 40 : 32 }
    }

    public enum Failure: Error, Equatable {
        case invalidBase32
        case wrongVersion
        case wrongLength
        case badChecksum
    }

    public static func encode(_ version: Version, _ payload: [UInt8]) -> String {
        var data = [version.rawValue] + payload
        let crc = crc16(data)
        data += [UInt8(crc & 0xff), UInt8(crc >> 8)]
        return Base32.encode(data)
    }

    public static func decode(_ version: Version, _ text: String) throws -> [UInt8] {
        guard let raw = Base32.decode(text), raw.count >= 3 else { throw Failure.invalidBase32 }
        guard raw[0] == version.rawValue else { throw Failure.wrongVersion }
        let body = Array(raw[0..<(raw.count - 2)])
        let crc = crc16(body)
        guard raw[raw.count - 2] == UInt8(crc & 0xff), raw[raw.count - 1] == UInt8(crc >> 8) else { throw Failure.badChecksum }
        let payload = Array(body.dropFirst())
        guard payload.count == version.expectedLength else { throw Failure.wrongLength }
        return payload
    }

    public static func isValid(_ version: Version, _ text: String) -> Bool {
        (try? decode(version, text)) != nil
    }

    public static func accountID(_ key: [UInt8]) -> String { encode(.accountID, key) }
    public static func contractID(_ hash: [UInt8]) -> String { encode(.contract, hash) }

    /// CRC16-XModem (poly 0x1021, init 0).
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

/// RFC 4648 base32 (uppercase, no padding), as StrKey uses it.
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    private static let lookup: [UInt8: UInt8] = {
        var m: [UInt8: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { m[c] = UInt8(i) }
        return m
    }()

    static func encode(_ data: [UInt8]) -> String {
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        var buffer = 0
        var bits = 0
        for c in text.utf8 {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xff))
                bits -= 8
            }
            buffer &= 0xffff
        }
        // Leftover bits must be zero padding (canonical encoding only).
        if bits >= 5 || (buffer & ((1 << bits) - 1)) != 0 { return nil }
        return out
    }
}
