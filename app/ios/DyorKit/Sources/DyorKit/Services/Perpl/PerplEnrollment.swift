import BigInt
import Foundation

/* Perpl's API-key enrollment hands back EIP-712 typed data for the wallet to sign, and the wallets on this path sign
   a raw 32-byte digest with no prompt that could show what it is. So the server's payload is never trusted as is: a
   spoofed or compromised endpoint could return a token permit, an order, a registration of ITS OWN Ed25519 key
   against this wallet, or a builder fee the user never agreed to. Before anything is signed, the payload must match,
   field for field, the one genuine shape (observed from app.perpl.xyz on 2026-09-23), be bound to this wallet and to
   the key this device generated, and carry exactly the terms the app asked for. The digest that gets signed is then
   recomputed on device from a canonical rebuild of the validated values, never taken from the server. */

/// Why an enrollment payload was refused. Every reason is the app's own wording; no server text reaches the UI.
public enum PerplEnrollmentError: Error, LocalizedError, Equatable {
    case wrongChain
    case wrongDomain(String)
    case disallowedType
    case wrongTypes
    case foreignSigner
    case foreignKey
    case wrongScope
    case builderFee
    case unexpectedTerms(String)
    case stale
    case unexpectedShape(String)
    case digestMismatch

    public var errorDescription: String? {
        L10n.tr("DyorHQ refused to sign Perpl's trading-key request because \(reason). Nothing was signed. Try again later.")
    }

    private var reason: String {
        switch self {
        case .wrongChain: return L10n.string(LocalizedStringResource("it is for a different network", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .wrongDomain(let field): return L10n.string(LocalizedStringResource("its signing domain is not Perpl's (\(field))", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.” The value is a field of the request, in English."))
        case .disallowedType: return L10n.string(LocalizedStringResource("it is not an API-key registration", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .wrongTypes: return L10n.string(LocalizedStringResource("its fields are not an API-key registration's", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .foreignSigner: return L10n.string(LocalizedStringResource("it names a different wallet", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .foreignKey: return L10n.string(LocalizedStringResource("it registers a key this device did not create", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .wrongScope: return L10n.string(LocalizedStringResource("it asks for permissions the app did not request", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .builderFee: return L10n.string(LocalizedStringResource("it adds a builder fee you never agreed to", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .unexpectedTerms(let field): return L10n.string(LocalizedStringResource("it changes the key's terms (\(field))", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.” The value is a term of the request, in English."))
        case .stale: return L10n.string(LocalizedStringResource("it is expired or this device's clock is off", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        case .unexpectedShape(let what): return L10n.string(LocalizedStringResource("it is malformed (\(what))", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.” The value names the part of the request, in English."))
        case .digestMismatch: return L10n.string(LocalizedStringResource("its hash does not match its contents", bundle: L10n.kit, comment: "Why DyorHQ refused to sign, completing “DyorHQ refused to sign Perpl’s trading-key request because <this>.”"))
        }
    }
}

public enum PerplEnrollment {
    /// The only primary type the wallet will ever sign on this path.
    public static let primaryType = "PerplRegisterApiKey"
    public static let allowedPrimaryTypes: Set<String> = [primaryType]
    public static let domainName = "perpl.xyz"
    public static let domainVersion = "1"
    /// Monad mainnet, the only network the app trades on.
    public static let chainId = 143
    /// The enrollment signature is checked by Perpl's API only, so its domain names no contract: the zero address,
    /// not the Exchange. Pinned, so the signature can never be replayed to a contract that verifies EIP-712.
    public static let verifyingContract = Address.zero
    /// The non-builder statement. A builder-bound key carries a different one naming the builder and its fee.
    // not localized: the statement Perpl's request carries, compared with it as it is
    public static let statement = "I authorize the creation of Perpl API key with the specified scope and parameters"
    /// How far the payload's issue `time` may sit from this device's clock, either way. The payload is validated the
    /// moment it arrives, so anything older is a replay (or a badly wrong clock).
    public static let maxClockSkew: TimeInterval = 15 * 60

    public static let domainFields: [EIP712.Field] = [
        .init(name: "name", type: "string"),
        .init(name: "version", type: "string"),
        .init(name: "chainId", type: "uint256"),
        .init(name: "verifyingContract", type: "address"),
        .init(name: "salt", type: "bytes32"),
    ]

    public static let messageFields: [EIP712.Field] = [
        .init(name: "signer", type: "address"),
        .init(name: "statement", type: "string"),
        .init(name: "publicKey", type: "string"),
        .init(name: "scope", type: "string"),
        .init(name: "label", type: "string"),
        .init(name: "expiresAt", type: "string"),
        .init(name: "ipCidrs", type: "string"),
        .init(name: "origin", type: "string"),
        .init(name: "builderId", type: "string"),
        .init(name: "maxBuilderFeePer100K", type: "string"),
        .init(name: "time", type: "uint64"),
    ]

    public struct Validated {
        /// The canonical rebuild of the validated payload; what the digest is computed from.
        public let typedData: EIP712.TypedData
        /// The 32-byte digest to sign (wallet) and to prove possession over (Ed25519).
        public let digest: Data
    }

    /// Checks the server's `typed_data` against the request the app made — `chainId`, `address`, `publicKeyHex`,
    /// `scopeMask` and `label` are exactly what was sent to `/api-key/payload`, which asks for no expiry, no IP
    /// allow-list and no builder code — and returns the digest to sign. Throws `PerplEnrollmentError` on any deviation.
    public static func validate(_ json: [String: Any], chainId: Int, address: String, publicKeyHex: String, scopeMask: Int,
                                label: String, now: Date = Date()) throws -> Validated {
        // not localized: the parts a refusal names ("salt", "IP allow-list", "message fields") are the request's own,
        // in English inside the translated sentence, as its translator comments say
        try requireKeys(json, ["types", "primaryType", "domain", "message"], "typed data")
        guard let primary = json["primaryType"] as? String, allowedPrimaryTypes.contains(primary) else {
            throw PerplEnrollmentError.disallowedType
        }
        guard let types = json["types"] as? [String: Any], Set(types.keys) == ["EIP712Domain", primaryType],
              fields(types["EIP712Domain"]) == domainFields, fields(types[primaryType]) == messageFields
        else { throw PerplEnrollmentError.wrongTypes }

        // Domain: name, version, chain and contract pinned; the salt is a per-payload nonce, so only its form is checked.
        guard let domain = json["domain"] as? [String: Any], Set(domain.keys) == Set(domainFields.map(\.name)) else {
            throw PerplEnrollmentError.wrongDomain("fields")
        }
        guard domain["name"] as? String == domainName else { throw PerplEnrollmentError.wrongDomain("name") }
        guard domain["version"] as? String == domainVersion else { throw PerplEnrollmentError.wrongDomain("version") }
        guard chainId == Self.chainId, integer(domain["chainId"]) == BigUInt(chainId) else { throw PerplEnrollmentError.wrongChain }
        guard let contractHex = domain["verifyingContract"] as? String, isStrictHex(contractHex, bytes: 20),
              let contract = Address(contractHex), contract == verifyingContract
        else { throw PerplEnrollmentError.wrongDomain("contract") }
        guard let saltHex = domain["salt"] as? String, isStrictHex(saltHex, bytes: 32), let salt = Data(hex: saltHex), salt.count == 32
        else { throw PerplEnrollmentError.wrongDomain("salt") }

        // Message: every field present, nothing extra, strings where the type says string.
        guard let message = json["message"] as? [String: Any], Set(message.keys) == Set(messageFields.map(\.name)) else {
            throw PerplEnrollmentError.unexpectedShape("message fields")
        }
        var text: [String: String] = [:]
        for field in messageFields where field.type == "string" {
            guard let value = message[field.name] as? String else { throw PerplEnrollmentError.unexpectedShape("message values") }
            text[field.name] = value
        }

        // Bound to this wallet and to the Ed25519 key this device generated (sent base64url, unpadded).
        guard let wallet = Address(address), let signerHex = message["signer"] as? String, isStrictHex(signerHex, bytes: 20),
              let signer = Address(signerHex), signer == wallet
        else { throw PerplEnrollmentError.foreignSigner }
        guard let publicKey = Data(hex: publicKeyHex), publicKey.count == 32, text["publicKey"] == PerplAuth.base64url(publicKey) else {
            throw PerplEnrollmentError.foreignKey
        }
        // The server normalizes trade to read|trade (trade implies read); accept that or the exact mask, nothing wider.
        let normalized = scopeMask & PerplScope.trade != 0 ? scopeMask | PerplScope.read : scopeMask
        guard (1...PerplScope.all).contains(scopeMask), let scope = text["scope"], [String(scopeMask), String(normalized)].contains(scope) else {
            throw PerplEnrollmentError.wrongScope
        }
        guard text["builderId"] == "0", text["maxBuilderFeePer100K"] == "0" else { throw PerplEnrollmentError.builderFee }
        guard text["statement"] == statement else { throw PerplEnrollmentError.unexpectedTerms("statement") }
        guard text["label"] == label else { throw PerplEnrollmentError.unexpectedTerms("label") }
        guard text["expiresAt"] == "0" else { throw PerplEnrollmentError.unexpectedTerms("expiry") }
        guard text["ipCidrs"] == "" else { throw PerplEnrollmentError.unexpectedTerms("IP allow-list") }
        guard text["origin"] == "" else { throw PerplEnrollmentError.unexpectedTerms("origin") }
        let nowMs = BigInt(Int(now.timeIntervalSince1970 * 1000))
        guard let time = integer(message["time"]), time <= BigUInt(UInt64.max),
              (BigInt(time) - nowMs).magnitude <= BigUInt(Int(maxClockSkew * 1000))
        else { throw PerplEnrollmentError.stale }

        // Rebuild from the pinned types and validated values only, and sign that digest. It must equal the digest of
        // the server's own structure (which is what Perpl verifies against); by construction it does, so a
        // difference means the encoder saw something the checks above did not.
        let canonical = EIP712.TypedData(
            domain: ["name": domainName, "version": domainVersion, "chainId": chainId,
                     "verifyingContract": verifyingContract.hex, "salt": salt.hexString],
            types: ["EIP712Domain": domainFields, primaryType: messageFields],
            primaryType: primaryType,
            message: ["signer": signer.checksummed, "statement": statement, "publicKey": PerplAuth.base64url(publicKey),
                      "scope": scope, "label": label, "expiresAt": "0", "ipCidrs": "", "origin": "",
                      "builderId": "0", "maxBuilderFeePer100K": "0", "time": String(time)])
        let digest = try EIP712.digest(canonical)
        guard (try? EIP712.digest(EIP712.parse(json))) == digest else { throw PerplEnrollmentError.digestMismatch }
        return Validated(typedData: canonical, digest: digest)
    }

    // MARK: Helpers

    private static func requireKeys(_ object: [String: Any], _ expected: Set<String>, _ what: String) throws {
        guard Set(object.keys) == expected else { throw PerplEnrollmentError.unexpectedShape(what) }
    }

    /// A type's field list, only if every entry is exactly `{name, type}`.
    private static func fields(_ raw: Any?) -> [EIP712.Field]? {
        guard let list = raw as? [[String: Any]] else { return nil }
        var out: [EIP712.Field] = []
        for entry in list {
            guard entry.count == 2, let name = entry["name"] as? String, let type = entry["type"] as? String else { return nil }
            out.append(.init(name: name, type: type))
        }
        return out
    }

    /// `0x` and exactly `bytes` bytes of ASCII hex digits, as the genuine payload writes them. `Data(hex:)` (and so
    /// `Address`) alone would also take surrounding whitespace or a sign inside a pair ("+f").
    private static func isStrictHex(_ value: String, bytes: Int) -> Bool {
        value.count == 2 + 2 * bytes && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// A non-negative integer from a JSON number, a decimal string or a `0x` hex string.
    private static func integer(_ value: Any?) -> BigUInt? {
        if let string = value as? String {
            let hex = string.hasPrefix("0x") || string.hasPrefix("0X")
            let digits = hex ? string.dropFirst(2) : Substring(string)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && (hex ? $0.isHexDigit : $0.isNumber) }) else { return nil }
            return BigUInt(digits, radix: hex ? 16 : 10)
        }
        if let number = value as? Int, number >= 0 { return BigUInt(number) }
        return nil
    }
}
