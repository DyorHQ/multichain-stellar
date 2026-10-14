import BigInt
import Foundation

/// EIP-712 typed-data hashing (`keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(message))`). Perpl's API-key
/// enrollment returns an opaque typed-data blob that must be hashed to (a) sign with the wallet and (b) prove
/// possession of the Ed25519 key — both over the same 32-byte digest. This mirrors ethers `TypedDataEncoder.hash`;
/// it is validated against the canonical "Ether Mail" example vector in the tests.
public enum EIP712 {
    public struct Field: Sendable, Equatable {
        public let name: String
        public let type: String
        public init(name: String, type: String) { self.name = name; self.type = type }
    }

    public struct TypedData {
        public let domain: [String: Any]
        public let types: [String: [Field]]
        public let primaryType: String
        public let message: [String: Any]

        public init(domain: [String: Any], types: [String: [Field]], primaryType: String, message: [String: Any]) {
            self.domain = domain
            self.types = types
            self.primaryType = primaryType
            self.message = message
        }
    }

    public enum EIP712Error: Error { case malformed(String) }

    /// Parse the opaque `typed_data` object (as decoded by `JSONSerialization`) into a `TypedData`.
    public static func parse(_ json: [String: Any]) throws -> TypedData {
        guard let domain = json["domain"] as? [String: Any],
              let rawTypes = json["types"] as? [String: Any],
              let primaryType = json["primaryType"] as? String,
              let message = json["message"] as? [String: Any]
        else { throw EIP712Error.malformed("typed_data missing domain/types/primaryType/message") }
        var types: [String: [Field]] = [:]
        for (typeName, fieldsAny) in rawTypes {
            guard let fields = fieldsAny as? [[String: Any]] else { throw EIP712Error.malformed("types.\(typeName)") }
            types[typeName] = fields.compactMap { field in
                guard let name = field["name"] as? String, let type = field["type"] as? String else { return nil }
                return Field(name: name, type: type)
            }
        }
        return TypedData(domain: domain, types: types, primaryType: primaryType, message: message)
    }

    /// The 32-byte digest a wallet signs and the Ed25519 proof-of-possession covers.
    public static func digest(_ data: TypedData) throws -> Data {
        var out = Data([0x19, 0x01])
        out += try hashStruct("EIP712Domain", data.domain, data.types)
        out += try hashStruct(data.primaryType, data.message, data.types)
        return Keccak.hash256(out)
    }

    // MARK: Encoding

    static func hashStruct(_ type: String, _ value: [String: Any], _ types: [String: [Field]]) throws -> Data {
        Keccak.hash256(try typeHash(type, types) + encodeData(type, value, types))
    }

    static func typeHash(_ type: String, _ types: [String: [Field]]) throws -> Data {
        Keccak.hash256(Data(try encodeType(type, types).utf8))
    }

    /// `Type(field1,field2,…)` for the primary type, then every referenced struct type in alphabetical order.
    static func encodeType(_ primary: String, _ types: [String: [Field]]) throws -> String {
        var deps: Set<String> = []
        collectDependencies(primary, types, into: &deps)
        deps.remove(primary)
        let ordered = [primary] + deps.sorted()
        return try ordered.map { name in
            guard let fields = types[name] else { throw EIP712Error.malformed("unknown type \(name)") }
            return "\(name)(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        }.joined()
    }

    private static func collectDependencies(_ type: String, _ types: [String: [Field]], into deps: inout Set<String>) {
        let base = type.hasSuffix("]") ? String(type[..<type.firstIndex(of: "[")!]) : type
        guard types[base] != nil, !deps.contains(base) else { return }
        deps.insert(base)
        for field in types[base] ?? [] { collectDependencies(field.type, types, into: &deps) }
    }

    static func encodeData(_ type: String, _ value: [String: Any], _ types: [String: [Field]]) throws -> Data {
        var out = Data()
        for field in types[type] ?? [] {
            out += try encodeField(field.type, value[field.name] as Any, types)
        }
        return out
    }

    /// One 32-byte word (atomic) or a 32-byte hash (dynamic / array / struct).
    static func encodeField(_ type: String, _ value: Any, _ types: [String: [Field]]) throws -> Data {
        if type.hasSuffix("]") {
            let element = String(type[..<type.lastIndex(of: "[")!])
            let items = value as? [Any] ?? []
            var packed = Data()
            for item in items { packed += try encodeField(element, item, types) }
            return Keccak.hash256(packed)
        }
        if types[type] != nil {
            guard let object = value as? [String: Any] else { throw EIP712Error.malformed("expected object for \(type)") }
            return try hashStruct(type, object, types)
        }
        switch type {
        case "string":
            return Keccak.hash256(Data((value as? String ?? "").utf8))
        case "bytes":
            return Keccak.hash256(bytes(value))
        case "bool":
            let truthy: Bool
            if let flag = value as? Bool { truthy = flag } else { truthy = ((try? integer(value)) ?? BigInt(0)) != 0 }
            return BigUInt(truthy ? 1 : 0).word
        case "address":
            return bytes(value).leftPadded(to: 32)
        default:
            if type.hasPrefix("bytes") { // bytesN — left-aligned, right-padded
                var data = bytes(value)
                if data.count < 32 { data += Data(repeating: 0, count: 32 - data.count) }
                return data.prefix(32)
            }
            // uint*/int* — 32-byte big-endian, two's complement for negatives
            let n = try integer(value)
            if n.sign == .minus {
                let modulus = BigInt(1) << 256
                return BigUInt((modulus + n).magnitude % BigUInt(modulus.magnitude)).word
            }
            return n.magnitude.word
        }
    }

    // MARK: Value coercion

    private static func bytes(_ value: Any) -> Data {
        if let data = value as? Data { return data }
        if let string = value as? String { return Data(hex: string) ?? Data() }
        return Data()
    }

    private static func integer(_ value: Any) throws -> BigInt {
        switch value {
        case let n as Int: return BigInt(n)
        case let n as Int64: return BigInt(n)
        case let n as UInt64: return BigInt(n)
        case let n as NSNumber: return BigInt(n.int64Value)
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                guard let v = BigUInt(trimmed.dropFirst(2), radix: 16) else { throw EIP712Error.malformed("hex int \(s)") }
                return BigInt(v)
            }
            guard let v = BigInt(trimmed) else { throw EIP712Error.malformed("int \(s)") }
            return v
        default:
            throw EIP712Error.malformed("unsupported integer value")
        }
    }
}
