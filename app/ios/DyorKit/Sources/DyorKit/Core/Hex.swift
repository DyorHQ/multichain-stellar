import BigInt
import Foundation

public extension Data {
    /// Parses `0x`-prefixed or bare hex. Odd-length input is left-padded with a zero nibble, as JSON-RPC quantities are.
    init?(hex: String) {
        var s = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        if s.isEmpty {
            self.init()
            return
        }
        if s.count % 2 == 1 { s = "0" + s }
        var out = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    /// Lowercase `0x…` hex.
    var hexString: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }

    /// Left-pads with zeros to `count` bytes (no-op when already longer).
    func leftPadded(to count: Int) -> Data {
        self.count >= count ? self : Data(repeating: 0, count: count - self.count) + self
    }

    /// Right-pads with zeros up to the next multiple of `multiple`.
    func rightPadded(toMultipleOf multiple: Int) -> Data {
        let remainder = count % multiple
        return remainder == 0 ? self : self + Data(repeating: 0, count: multiple - remainder)
    }
}

public extension BigUInt {
    /// Parses a JSON-RPC quantity (`0x…`).
    init?(hexQuantity: String) {
        let s = hexQuantity.hasPrefix("0x") || hexQuantity.hasPrefix("0X") ? String(hexQuantity.dropFirst(2)) : hexQuantity
        if s.isEmpty {
            self = 0
            return
        }
        guard let value = BigUInt(s, radix: 16) else { return nil }
        self = value
    }

    /// Minimal `0x…` quantity encoding (no leading zeros), as JSON-RPC requires.
    var hexQuantity: String { "0x" + String(self, radix: 16) }

    /// Big-endian bytes, left-padded to 32.
    var word: Data { serialize().leftPadded(to: 32) }
}
