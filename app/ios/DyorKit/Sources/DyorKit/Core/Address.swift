import Foundation

/// A 20-byte Ethereum address. Equality is byte-wise, so case differences never matter.
public struct Address: Hashable, Sendable, Codable, CustomStringConvertible {
    public let data: Data

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42, trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X"), let bytes = Data(hex: trimmed), bytes.count == 20 else { return nil }
        data = bytes
    }

    public init?(data: Data) {
        guard data.count == 20 else { return nil }
        self.data = data
    }

    /// For addresses that are known constants in source; traps on a typo so it cannot ship.
    public init(literal: String) {
        guard let address = Address(literal) else { preconditionFailure("Invalid address literal \(literal)") }
        self = address
    }

    public static let zero = Address(data: Data(repeating: 0, count: 20))!

    public var isZero: Bool { data.allSatisfy { $0 == 0 } }

    /// Lowercase `0x…`.
    public var hex: String { data.hexString }

    /// EIP-55 mixed-case checksum form, what users should see and copy.
    public var checksummed: String {
        let lower = data.map { String(format: "%02x", $0) }.joined()
        let hash = Keccak.hash256(lower)
        var out = "0x"
        for (i, ch) in lower.enumerated() {
            let nibble = (hash[i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0xF
            out.append(nibble >= 8 ? ch.uppercased() : String(ch))
        }
        return out
    }

    /// EIP-55 for typed or pasted input: an all-lowercase or all-uppercase address carries no checksum and passes as
    /// typed; a mixed-case one must match its checksum exactly, so a mistyped character in a copied address is caught
    /// before funds are sent to it. False when `string` is not an address at all.
    public static func hasValidChecksum(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = Address(trimmed) else { return false }
        let body = String(trimmed.dropFirst(2))
        if body == body.lowercased() || body == body.uppercased() { return true }
        return "0x" + body == address.checksummed
    }

    /// Typed or pasted recipient text as the person meant it (GR-4): surrounding spaces and line breaks trimmed, and the
    /// invisible characters a copy can carry removed wherever they are — zero-width spaces and joiners, word joiners,
    /// the byte-order mark, soft hyphens and the bidirectional controls, which can also make an address display in an
    /// order other than its characters. `removedInvisible` says whether any were there.
    public static func cleanedInput(_ text: String) -> (text: String, removedInvisible: Bool) {
        let scalars = text.unicodeScalars.filter { !invisible.contains($0.value) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, scalars.count != text.unicodeScalars.count)
    }

    /// U+00AD soft hyphen, U+034F grapheme joiner, U+061C Arabic letter mark, U+115F/U+1160 Hangul fillers, U+180E
    /// Mongolian vowel separator, U+200B–U+200F zero-width and directional marks, U+202A–U+202E directional
    /// embeddings and overrides, U+2060–U+2064 word joiner and invisible operators, U+2066–U+2069 directional isolates,
    /// U+3164 Hangul filler, U+FEFF byte-order mark.
    private static let invisible: Set<UInt32> = Set([0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x180E, 0x3164, 0xFEFF]
        + Array(0x200B...0x200F) + Array(0x202A...0x202E) + Array(0x2060...0x2064) + Array(0x2066...0x2069))

    /// Whether `scalar` is one of the invisible characters `cleanedInput` removes.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool { invisible.contains(scalar.value) }

    /// What is wrong with recipient text (after `cleanedInput`), in words a person can act on; nil when it is a valid
    /// address with a correct checksum, or empty (nothing to say yet).
    public static func inputProblem(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return L10n.tr("An address starts with 0x.") }
        let body = text.dropFirst(2)
        if body.contains(where: { $0.isWhitespace }) { return L10n.tr("This address has a space or line break inside it. Copy it again from the source.") }
        if let bad = body.first(where: { !$0.isHexDigit || !$0.isASCII }) { return L10n.tr("“\(String(bad))” can't be part of an address: it uses only 0–9 and a–f.") }
        guard body.count == 40 else { return L10n.tr("An address has 40 characters after 0x; this one has \(String(body.count)).") }
        guard hasValidChecksum(text) else {
            return L10n.tr("This address's capital letters don't match its checksum, so it may contain a typo. Copy it again from the source.")
        }
        return nil
    }

    /// `0x1234…abcd`, for rows and titles.
    public var short: String {
        let s = checksummed
        return "\(s.prefix(6))…\(s.suffix(4))"
    }

    public var description: String { checksummed }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let address = Address(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid address \(string)"))
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checksummed)
    }
}
