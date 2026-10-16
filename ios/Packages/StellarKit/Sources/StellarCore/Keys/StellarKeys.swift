import Crypto
import Foundation

/// An ed25519 Stellar key held in memory for as long as a signature needs it. Create it from the secret the account
/// method gives (SEP-5 phrase, email seed + pepper, imported key), sign, let it go.
public struct StellarSigner: Sendable {
    private let key: Curve25519.Signing.PrivateKey
    public let publicKey: [UInt8]

    public init(seed: [UInt8]) throws {
        guard seed.count == 32 else { throw KeyError.badSeed }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        publicKey = Array(key.publicKey.rawRepresentation)
    }

    /// From an S… secret.
    public init(secret: String) throws {
        try self.init(seed: try StrKey.decode(.seed, secret))
    }

    public var address: String { StrKey.accountID(publicKey) }

    /// The S… secret, for Settings → Export Stellar key (email and imported-key accounts only).
    public var secret: String { StrKey.encode(.seed, Array(key.rawRepresentation)) }

    public func sign(_ data: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(data)))
    }

    /// The 4-byte hint Stellar puts beside a signature (last 4 bytes of the public key).
    public var hint: [UInt8] { Array(publicKey.suffix(4)) }

    /// SEP-53 message signing: ed25519 over sha256("Stellar Signed Message:\n" + message), base64.
    public func signMessage(_ message: String) throws -> String {
        Data(try sign(Self.sep53Digest(message))).base64EncodedString()
    }

    /// What a SEP-53 signature of `message` signs: sha256("Stellar Signed Message:\n" + message).
    public static func sep53Digest(_ message: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(("Stellar Signed Message:\n" + message).utf8)))
    }

    public static func verify(address: String, message: [UInt8], signature: [UInt8]) -> Bool {
        guard let pub = try? StrKey.decode(.accountID, address),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(Data(signature), for: Data(message))
    }
}

public enum KeyError: Error, Equatable {
    case badSeed
    case badMnemonic
}

/// How a DyorHQ account's Stellar key is derived from the secret it already has (docs/ARCHITECTURE.md §3.2).
public enum StellarDerivation {
    /// SEP-5: BIP-39 seed → SLIP-10 ed25519 m/44'/148'/index'. Same 24 words as the Monad key (Mera passkey phrase,
    /// imported phrase), so any SEP-5 wallet restores the same Stellar account.
    public static func sep5(mnemonic: String, passphrase: String = "", index: UInt32 = 0) throws -> StellarSigner {
        let words = mnemonic.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count) else { throw KeyError.badMnemonic }
        let seed = Mnemonic.seed(phrase: words.joined(separator: " "), passphrase: passphrase)
        return try StellarSigner(seed: slip10(seed: seed, path: [44, 148, index]))
    }

    /// Email & password accounts (v2): HKDF-SHA256(seed ‖ pepper, salt "dyorhq/email-wallet/v2", info
    /// "stellar-ed25519"). Same input as the Monad key, different info string, so neither key reveals the other.
    public static func emailV2(seed: [UInt8], pepper: [UInt8]) throws -> StellarSigner {
        let ikm = SymmetricKey(data: seed + pepper)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data("dyorhq/email-wallet/v2".utf8), info: Data("stellar-ed25519".utf8), outputByteCount: 32)
        return try StellarSigner(seed: key.withUnsafeBytes { Array($0) })
    }

    /// Accounts imported from a raw secp256k1 private key (no phrase): HKDF over the key.
    public static func fromSecp256k1(privateKey: [UInt8]) throws -> StellarSigner {
        guard privateKey.count == 32 else { throw KeyError.badSeed }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: privateKey), salt: Data("dyorhq/stellar/v1".utf8), info: Data("ed25519-from-secp256k1".utf8), outputByteCount: 32)
        return try StellarSigner(seed: key.withUnsafeBytes { Array($0) })
    }

    /// SLIP-10 for ed25519: hardened derivation only.
    static func slip10(seed: [UInt8], path: [UInt32]) -> [UInt8] {
        var i = Array(HMAC<SHA512>.authenticationCode(for: Data(seed), using: SymmetricKey(data: Data("ed25519 seed".utf8))))
        var key = Array(i[0..<32])
        var chain = Array(i[32..<64])
        for index in path {
            let hardened = index | 0x8000_0000
            var data: [UInt8] = [0] + key
            data += [UInt8(hardened >> 24), UInt8((hardened >> 16) & 0xff), UInt8((hardened >> 8) & 0xff), UInt8(hardened & 0xff)]
            i = Array(HMAC<SHA512>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(chain))))
            key = Array(i[0..<32])
            chain = Array(i[32..<64])
        }
        return key
    }
}

/// BIP-39 (English).
public enum Mnemonic {
    public static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()

    /// 24 words from 32 bytes of entropy (8-bit checksum).
    public static func phrase(entropy: [UInt8]) -> String? {
        guard [16, 20, 24, 28, 32].contains(entropy.count), words.count == 2048 else { return nil }
        let checksumBits = entropy.count / 4
        let hash = Array(SHA256.hash(data: Data(entropy)))
        var bits: [Bool] = []
        for byte in entropy + [hash[0]] { for i in (0..<8).reversed() { bits.append((byte >> UInt8(i)) & 1 == 1) } }
        bits = Array(bits.prefix(entropy.count * 8 + checksumBits))
        var out: [String] = []
        for chunk in stride(from: 0, to: bits.count, by: 11) {
            let idx = bits[chunk..<(chunk + 11)].reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }
            out.append(words[idx])
        }
        return out.joined(separator: " ")
    }

    /// Whether every word is in the list and the checksum matches.
    public static func isValid(_ phrase: String) -> Bool {
        let list = phrase.split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(list.count) else { return false }
        var bits: [Bool] = []
        for w in list {
            guard let idx = words.firstIndex(of: w) else { return false }
            for i in (0..<11).reversed() { bits.append((idx >> i) & 1 == 1) }
        }
        let entropyBits = bits.count * 32 / 33
        var entropy: [UInt8] = []
        for chunk in stride(from: 0, to: entropyBits, by: 8) {
            entropy.append(UInt8(bits[chunk..<(chunk + 8)].reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }))
        }
        let hash = Array(SHA256.hash(data: Data(entropy)))
        let cs = bits.count - entropyBits
        for i in 0..<cs where bits[entropyBits + i] != ((hash[0] >> UInt8(7 - i)) & 1 == 1) { return false }
        return true
    }

    /// PBKDF2-HMAC-SHA512(phrase, "mnemonic" + passphrase, 2048) → 64 bytes. (NFKD is a no-op for the English list.)
    public static func seed(phrase: String, passphrase: String = "") -> [UInt8] {
        let password = SymmetricKey(data: Data(phrase.decomposedStringWithCompatibilityMapping.utf8))
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        var u = Array(HMAC<SHA512>.authenticationCode(for: Data(salt + [0, 0, 0, 1]), using: password))
        var out = u
        for _ in 1..<2048 {
            u = Array(HMAC<SHA512>.authenticationCode(for: Data(u), using: password))
            for j in 0..<out.count { out[j] ^= u[j] }
        }
        return out
    }
}
