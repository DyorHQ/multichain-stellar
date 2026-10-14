import BigInt
import Foundation

/// IPFS links as creators and token lists write them, read one way for every caller: Moment media
/// (`MomentsMath.gatewayURLs`), NFT metadata and art (`NFTMetadata.gatewayURL`) and coin pictures (`ImageSourcePolicy`).
/// `path` finds the CID and what follows it in any of the three forms; each caller then applies its own rule — which
/// gateways, how strict a CID it takes (`isCID` parses one; NFT metadata keeps its looser test), whether a query stays.
public enum IPFS {
    /// `<cid>[/…]` as `uri` writes it, from any of the forms an IPFS link takes, or nil when it is none of them:
    /// - `ipfs://<cid>[/…]` (a leading `ipfs/` after the scheme, which some writers add, dropped), the query and fragment
    ///   kept as written;
    /// - `https://<any host>/ipfs/<cid>[/…]`, the path form every gateway serves;
    /// - `https://<cid>.ipfs.<host>[/…]`, the subdomain form.
    /// Nothing but the form is checked: not the CID, the path, the host, a port or credentials (`path(_ components:)`).
    public static func path(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("ipfs://") {
            return String(trimmed.dropFirst("ipfs://".count)).replacingOccurrences(of: "ipfs/", with: "", options: [.anchored])
        }
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https" else { return nil }
        return path(components)
    }

    /// `path` for an https link already parsed: the path form first, then the subdomain form. The percent-encoded path is
    /// kept as it is.
    public static func path(_ components: URLComponents) -> String? {
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let path = components.percentEncodedPath
        if path.lowercased().hasPrefix("/ipfs/") { return String(path.dropFirst("/ipfs/".count)) }
        let labels = host.split(separator: ".")
        if labels.count >= 3, labels[1] == "ipfs" { return String(labels[0]) + path }
        return nil
    }

    /// The CID at the start of `path` (everything before its first slash).
    public static func cid(of path: String) -> String {
        path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    /// Whether `text` is a CID, decoded rather than pattern-matched: a CIDv0 (46 characters of base58btc, "Qm…", a
    /// sha2-256 multihash) or a CIDv1 — a multibase prefix (`b`/`B` base32, `z` base58btc, `f`/`F` base16, `k`/`K`
    /// base36) then version 1, a content codec and a multihash whose declared length is exactly what is left. At most
    /// 128 characters.
    public static func isCID(_ text: String) -> Bool {
        guard (2...128).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        if text.count == 46, text.hasPrefix("Qm") {
            guard let bytes = baseN(String(text), alphabet: base58) else { return false }
            return bytes.count == 34 && bytes[0] == 0x12 && bytes[1] == 0x20
        }
        let body = String(text.dropFirst())
        let bytes: [UInt8]?
        switch text.first {
        case "b": bytes = base32(body)
        case "B": bytes = base32(body.lowercased())
        case "z": bytes = baseN(body, alphabet: base58)
        case "f", "F": bytes = base16(body.lowercased())
        case "k", "K": bytes = baseN(body.lowercased(), alphabet: base36)
        default: bytes = nil
        }
        guard let bytes else { return false }
        var at = 0
        guard varint(bytes, &at) == 1, varint(bytes, &at) != nil, varint(bytes, &at) != nil, let length = varint(bytes, &at) else { return false }
        return length > 0 && bytes.count - at == Int(length)
    }

    private static let base58 = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// An unsigned LEB128 varint at `at` (moved past it), at most 9 bytes; nil when the bytes end first.
    private static func varint(_ bytes: [UInt8], _ at: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 63, by: 7) {
            guard at < bytes.count else { return nil }
            let byte = bytes[at]
            at += 1
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    /// RFC 4648 base32, lower case, no padding; nil for any other character, a character more than the bytes need, or
    /// bits left over that aren't zero.
    private static func base32(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in text {
            guard let digit = base32Alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(digit)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        guard bits < 5, buffer & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return bytes
    }

    private static func base16(_ text: String) -> [UInt8]? {
        guard text.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// A big-endian number in `alphabet`'s base, each leading zero digit a leading zero byte (base58btc, base36).
    private static func baseN(_ text: String, alphabet: [Character]) -> [UInt8]? {
        guard !text.isEmpty else { return nil }
        var value = BigUInt(0)
        let base = BigUInt(alphabet.count)
        for character in text {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * base + BigUInt(digit)
        }
        let zeros = text.prefix { $0 == alphabet[0] }.count
        return [UInt8](repeating: 0, count: zeros) + [UInt8](value.serialize())
    }
}
