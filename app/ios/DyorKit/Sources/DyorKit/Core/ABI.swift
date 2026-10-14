import BigInt
import Foundation

/// Solidity ABI types, values, and the encoder/decoder (https://docs.soliditylang.org/en/latest/abi-spec.html).
public indirect enum ABIType: Hashable, Sendable {
    case uint(Int)
    case int(Int)
    case address
    case bool
    case fixedBytes(Int)
    case bytes
    case string
    case array(ABIType)
    case fixedArray(ABIType, Int)
    case tuple([ABIType])

    public var isDynamic: Bool {
        switch self {
        case .bytes, .string, .array: return true
        case .fixedArray(let inner, _): return inner.isDynamic
        case .tuple(let parts): return parts.contains { $0.isDynamic }
        default: return false
        }
    }

    /// Bytes a static value occupies in the head; dynamic values occupy one 32-byte offset word.
    var headSize: Int {
        if isDynamic { return 32 }
        switch self {
        case .fixedArray(let inner, let n): return inner.headSize * n
        case .tuple(let parts): return parts.reduce(0) { $0 + $1.headSize }
        default: return 32
        }
    }

    /// Canonical form used in function signatures, e.g. `(uint256,address)[]`.
    public var canonical: String {
        switch self {
        case .uint(let bits): return "uint\(bits)"
        case .int(let bits): return "int\(bits)"
        case .address: return "address"
        case .bool: return "bool"
        case .fixedBytes(let n): return "bytes\(n)"
        case .bytes: return "bytes"
        case .string: return "string"
        case .array(let inner): return inner.canonical + "[]"
        case .fixedArray(let inner, let n): return inner.canonical + "[\(n)]"
        case .tuple(let parts): return "(" + parts.map(\.canonical).joined(separator: ",") + ")"
        }
    }

    /// Parses one canonical type, including nested tuples and arrays: `(uint256,address)[]`.
    public static func parse(_ text: String) throws -> ABIType {
        var parser = TypeParser(text)
        let type = try parser.parseType()
        parser.skipSpaces()
        guard parser.atEnd else { throw ABIError.invalidType(text) }
        return type
    }

    /// Parses a comma-separated parameter list such as `uint256,(address,bool)[]`.
    public static func parseList(_ text: String) throws -> [ABIType] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        var parser = TypeParser("(" + trimmed + ")")
        guard case .tuple(let parts) = try parser.parseType() else { throw ABIError.invalidType(text) }
        return parts
    }
}

public indirect enum ABIValue: Equatable, Sendable {
    case uint(BigUInt)
    case int(BigInt)
    case address(Address)
    case bool(Bool)
    case bytes(Data)
    case string(String)
    case array([ABIValue])
    case tuple([ABIValue])

    public var uint: BigUInt {
        if case .uint(let v) = self { return v }
        if case .int(let v) = self, v.sign == .plus { return v.magnitude }
        preconditionFailure("ABI value is not an unsigned integer: \(self)")
    }
    public var int: BigInt {
        if case .int(let v) = self { return v }
        if case .uint(let v) = self { return BigInt(v) }
        preconditionFailure("ABI value is not an integer: \(self)")
    }
    public var address: Address {
        if case .address(let v) = self { return v }
        preconditionFailure("ABI value is not an address: \(self)")
    }
    public var bool: Bool {
        if case .bool(let v) = self { return v }
        preconditionFailure("ABI value is not a bool: \(self)")
    }
    public var bytes: Data {
        if case .bytes(let v) = self { return v }
        preconditionFailure("ABI value is not bytes: \(self)")
    }
    public var string: String {
        if case .string(let v) = self { return v }
        preconditionFailure("ABI value is not a string: \(self)")
    }
    /// Non-trapping accessors, for decoding tokens whose reads may not conform to the expected type.
    public var stringOrNil: String? { if case .string(let v) = self { return v } else { return nil } }
    public var uintOrNil: BigUInt? { if case .uint(let v) = self { return v } else { return nil } }
    public var elements: [ABIValue] {
        switch self {
        case .array(let v), .tuple(let v): return v
        default: preconditionFailure("ABI value is not a sequence: \(self)")
        }
    }
    public subscript(index: Int) -> ABIValue { elements[index] }

    // Convenience constructors for call arguments.
    public static func uint(_ value: Int) -> ABIValue { .uint(BigUInt(value)) }
    public static func uint(_ value: UInt64) -> ABIValue { .uint(BigUInt(value)) }
    public static func int(_ value: Int) -> ABIValue { .int(BigInt(value)) }
}

public enum ABIError: Error, LocalizedError, Equatable {
    case invalidType(String)
    case invalidSignature(String)
    case typeMismatch(expected: String)
    case truncated
    case invalidOffset
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidType(let t): return L10n.tr("Invalid ABI type: \(t)")
        case .invalidSignature(let s): return L10n.tr("Invalid function signature: \(s)")
        case .typeMismatch(let expected): return L10n.tr("ABI value does not match type \(expected)")
        case .truncated: return L10n.tr("ABI data is shorter than its declared layout")
        case .invalidOffset: return L10n.tr("ABI data contains an out-of-range offset")
        case .invalidUTF8: return L10n.tr("ABI string is not valid UTF-8")
        }
    }
}

public enum ABI {
    // MARK: Selectors and calls

    /// First four bytes of keccak256 of the canonical signature.
    public static func selector(_ signature: String) -> Data {
        Keccak.hash256(signature).prefix(4)
    }

    /// Encodes `signature(args)`: the selector followed by the ABI-encoded arguments.
    public static func encodeCall(_ signature: String, _ args: [ABIValue] = []) throws -> Data {
        let types = try parameterTypes(of: signature)
        return selector(signature) + (try encode(args, types))
    }

    /// The parameter types declared in a signature like `execOrders((uint256,uint8)[],bool)`.
    public static func parameterTypes(of signature: String) throws -> [ABIType] {
        guard let open = signature.firstIndex(of: "("), signature.hasSuffix(")") else { throw ABIError.invalidSignature(signature) }
        let inner = String(signature[signature.index(after: open)..<signature.index(before: signature.endIndex)])
        return try ABIType.parseList(inner)
    }

    // MARK: Encoding

    public static func encode(_ values: [ABIValue], _ types: [ABIType]) throws -> Data {
        guard values.count == types.count else { throw ABIError.typeMismatch(expected: ABIType.tuple(types).canonical) }
        var head = Data()
        var tail = Data()
        let headSize = types.reduce(0) { $0 + $1.headSize }
        for (value, type) in zip(values, types) {
            if type.isDynamic {
                head.append(BigUInt(headSize + tail.count).word)
                tail.append(try encodeValue(value, type))
            } else {
                head.append(try encodeValue(value, type))
            }
        }
        return head + tail
    }

    public static func encode(_ values: [ABIValue], _ signature: String) throws -> Data {
        try encode(values, try ABIType.parseList(signature))
    }

    private static func encodeValue(_ value: ABIValue, _ type: ABIType) throws -> Data {
        switch (type, value) {
        case (.uint(let bits), .uint(let v)):
            guard v.bitWidth <= bits else { throw ABIError.typeMismatch(expected: type.canonical) }
            return v.word
        case (.uint, .int(let v)) where v.sign == .plus:
            return v.magnitude.word
        case (.int(let bits), .int(let v)):
            guard v.bitWidth <= bits else { throw ABIError.typeMismatch(expected: type.canonical) }
            return twosComplement(v)
        case (.int, .uint(let v)):
            return v.word
        case (.address, .address(let a)):
            return a.data.leftPadded(to: 32)
        case (.bool, .bool(let b)):
            return BigUInt(b ? 1 : 0).word
        case (.fixedBytes(let n), .bytes(let d)):
            guard d.count == n else { throw ABIError.typeMismatch(expected: type.canonical) }
            return d.rightPadded(toMultipleOf: 32)
        case (.bytes, .bytes(let d)):
            return BigUInt(d.count).word + d.rightPadded(toMultipleOf: 32)
        case (.string, .string(let s)):
            let d = Data(s.utf8)
            return BigUInt(d.count).word + d.rightPadded(toMultipleOf: 32)
        case (.array(let inner), .array(let items)):
            return BigUInt(items.count).word + (try encode(items, Array(repeating: inner, count: items.count)))
        case (.fixedArray(let inner, let n), .array(let items)):
            guard items.count == n else { throw ABIError.typeMismatch(expected: type.canonical) }
            return try encode(items, Array(repeating: inner, count: n))
        case (.tuple(let parts), .tuple(let items)):
            return try encode(items, parts)
        default:
            throw ABIError.typeMismatch(expected: type.canonical)
        }
    }

    private static func twosComplement(_ v: BigInt) -> Data {
        if v.sign == .plus { return v.magnitude.word }
        let modulus = BigUInt(1) << 256
        return (modulus - v.magnitude).word
    }

    // MARK: Decoding

    /// How `string` values are decoded. A string on chain holds whatever bytes its writer chose — a coin's name is its
    /// creator's — so by default (`lossy`) bytes that aren't valid UTF-8 read as U+FFFD and the value still decodes: one
    /// coin's name can't fail a read of many. `strict` throws `ABIError.invalidUTF8` instead, for a string whose exact
    /// bytes matter (hashed or compared). Valid UTF-8 decodes the same either way.
    public enum StringDecoding: Sendable {
        case lossy
        case strict
    }

    public static func decode(_ data: Data, _ types: [ABIType], strings: StringDecoding = .lossy) throws -> [ABIValue] {
        try decodeTuple(data, types, base: 0, strings: strings)
    }

    public static func decode(_ data: Data, _ signature: String, strings: StringDecoding = .lossy) throws -> [ABIValue] {
        try decode(data, try ABIType.parseList(signature), strings: strings)
    }

    private static func decodeTuple(_ data: Data, _ types: [ABIType], base: Int, strings: StringDecoding) throws -> [ABIValue] {
        var values: [ABIValue] = []
        var cursor = base
        for type in types {
            if type.isDynamic {
                let offset = try readWord(data, at: cursor)
                guard offset < BigUInt(data.count) else { throw ABIError.invalidOffset }
                values.append(try decodeValue(data, type, at: base + Int(offset), strings: strings))
                cursor += 32
            } else {
                values.append(try decodeValue(data, type, at: cursor, strings: strings))
                cursor += type.headSize
            }
        }
        return values
    }

    private static func decodeValue(_ data: Data, _ type: ABIType, at position: Int, strings: StringDecoding) throws -> ABIValue {
        switch type {
        case .uint:
            return .uint(try readWord(data, at: position))
        case .int:
            let raw = try readWord(data, at: position)
            let signBit = BigUInt(1) << 255
            return raw >= signBit ? .int(-BigInt((BigUInt(1) << 256) - raw)) : .int(BigInt(raw))
        case .address:
            let word = try slice(data, position, 32)
            return .address(Address(data: word.suffix(20))!)
        case .bool:
            return .bool(try readWord(data, at: position) != 0)
        case .fixedBytes(let n):
            return .bytes(try slice(data, position, n))
        case .bytes:
            let length = try readLength(data, at: position)
            return .bytes(try slice(data, position + 32, length))
        case .string:
            let length = try readLength(data, at: position)
            let bytes = try slice(data, position + 32, length)
            if let s = String(data: bytes, encoding: .utf8) { return .string(s) }
            guard strings == .lossy else { throw ABIError.invalidUTF8 }
            // Each ill-formed sequence becomes U+FFFD (Unicode's maximal-subpart rule); the text around it is kept.
            return .string(String(decoding: bytes, as: UTF8.self))
        case .array(let inner):
            let count = try readLength(data, at: position)
            guard count <= data.count / 32 else { throw ABIError.truncated }
            return .array(try decodeTuple(data, Array(repeating: inner, count: count), base: position + 32, strings: strings))
        case .fixedArray(let inner, let n):
            return .array(try decodeTuple(data, Array(repeating: inner, count: n), base: position, strings: strings))
        case .tuple(let parts):
            return .tuple(try decodeTuple(data, parts, base: position, strings: strings))
        }
    }

    private static func readWord(_ data: Data, at position: Int) throws -> BigUInt {
        BigUInt(try slice(data, position, 32))
    }

    /// Reads a dynamic length/count word and bounds-checks it before narrowing to `Int`. A valid length can never
    /// exceed the payload size, so this rejects a malformed return (e.g. a `bytes32` symbol misdecoded as a dynamic
    /// `string`) by throwing rather than trapping on `Int(BigUInt)` overflow — which previously could crash the app.
    private static func readLength(_ data: Data, at position: Int) throws -> Int {
        let word = try readWord(data, at: position)
        guard word <= BigUInt(data.count) else { throw ABIError.truncated }
        return Int(word)
    }

    private static func slice(_ data: Data, _ position: Int, _ length: Int) throws -> Data {
        guard position >= 0, length >= 0, position + length <= data.count else { throw ABIError.truncated }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + length))
    }
}

// MARK: - Type parser

private struct TypeParser {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool { index >= chars.count }

    mutating func skipSpaces() { while !atEnd, chars[index] == " " { index += 1 } }

    mutating func parseType() throws -> ABIType {
        skipSpaces()
        var type: ABIType
        if peek == "(" {
            index += 1
            var parts: [ABIType] = []
            skipSpaces()
            if peek == ")" {
                index += 1
            } else {
                while true {
                    parts.append(try parseType())
                    skipSpaces()
                    guard let c = peek else { throw ABIError.invalidType(String(chars)) }
                    index += 1
                    if c == ")" { break }
                    guard c == "," else { throw ABIError.invalidType(String(chars)) }
                }
            }
            type = .tuple(parts)
        } else {
            var name = ""
            while let c = peek, c.isLetter || c.isNumber {
                name.append(c)
                index += 1
            }
            type = try elementary(name)
        }
        // Array suffixes, innermost first.
        while peek == "[" {
            index += 1
            var digits = ""
            while let c = peek, c.isNumber {
                digits.append(c)
                index += 1
            }
            guard peek == "]" else { throw ABIError.invalidType(String(chars)) }
            index += 1
            if digits.isEmpty {
                type = .array(type)
            } else {
                guard let n = Int(digits) else { throw ABIError.invalidType(String(chars)) }
                type = .fixedArray(type, n)
            }
        }
        return type
    }

    private var peek: Character? { atEnd ? nil : chars[index] }

    private func elementary(_ name: String) throws -> ABIType {
        switch name {
        case "address": return .address
        case "bool": return .bool
        case "bytes": return .bytes
        case "string": return .string
        case "uint": return .uint(256)
        case "int": return .int(256)
        default:
            if name.hasPrefix("uint"), let bits = Int(name.dropFirst(4)), bits > 0, bits <= 256, bits % 8 == 0 { return .uint(bits) }
            if name.hasPrefix("int"), let bits = Int(name.dropFirst(3)), bits > 0, bits <= 256, bits % 8 == 0 { return .int(bits) }
            if name.hasPrefix("bytes"), let n = Int(name.dropFirst(5)), n > 0, n <= 32 { return .fixedBytes(n) }
            throw ABIError.invalidType(name)
        }
    }
}
