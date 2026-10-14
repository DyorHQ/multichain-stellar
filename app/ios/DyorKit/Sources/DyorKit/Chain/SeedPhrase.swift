import BigInt
import CryptoKit
import Foundation
import P256K

/// Imports a user's existing wallet from a BIP-39 seed phrase or a raw private key, entirely on-device. Seed phrases
/// are validated (word list + checksum) and derived down the standard Ethereum path m/44'/60'/0'/0/index (BIP-32/44),
/// the same path MetaMask, Rabby and OKX use, so the imported address matches what the user sees in their wallet.
public enum WalletImport {
    /// Derives the account at `m/44'/60'/0'/0/accountIndex` from a seed phrase, or nil if the phrase is invalid.
    public static func account(fromMnemonic phrase: String, passphrase: String = "", accountIndex: UInt32 = 0) -> Secp256k1Account? {
        guard let seed = Mnemonic.seed(phrase: phrase, passphrase: passphrase) else { return nil }
        guard let master = HDNode(seed: seed) else { return nil }
        let path: [UInt32] = [44 | HDNode.hardened, 60 | HDNode.hardened, 0 | HDNode.hardened, 0, accountIndex]
        guard let node = master.derive(path: path) else { return nil }
        return Secp256k1Account(privateKey: node.privateKey)
    }

    /// Imports directly from a 32-byte private key (with or without a `0x` prefix).
    public static func account(fromPrivateKey hex: String) -> Secp256k1Account? {
        Secp256k1Account(privateKeyHex: hex)
    }

    /// Whether a phrase is a well-formed BIP-39 mnemonic (word count, word list, and checksum all valid).
    public static func isValidMnemonic(_ phrase: String) -> Bool { Mnemonic.isValid(phrase) }

    /// How many words the phrase has after trimming — for live validation hints.
    public static func wordCount(_ phrase: String) -> Int { Mnemonic.words(phrase).count }
}

/// BIP-39 mnemonic handling: validation against the English word list + checksum, and PBKDF2 seed derivation.
enum Mnemonic {
    static func words(_ phrase: String) -> [String] {
        phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
    }

    static func isValid(_ phrase: String) -> Bool {
        let words = words(phrase)
        guard [12, 15, 18, 21, 24].contains(words.count) else { return false }
        var indices = [Int]()
        for word in words {
            guard let index = BIP39Wordlist.index(of: word) else { return false }
            indices.append(index)
        }
        // Rebuild the entropy+checksum bits and verify the checksum.
        var bits = [Bool]()
        bits.reserveCapacity(indices.count * 11)
        for index in indices {
            for shift in stride(from: 10, through: 0, by: -1) { bits.append((index >> shift) & 1 == 1) }
        }
        let checksumLength = words.count / 3          // 12→4 … 24→8
        let entropyLength = bits.count - checksumLength
        guard entropyLength % 8 == 0 else { return false }
        var entropy = [UInt8]()
        var i = 0
        while i < entropyLength {
            var byte: UInt8 = 0
            for b in 0..<8 { byte = (byte << 1) | (bits[i + b] ? 1 : 0) }
            entropy.append(byte)
            i += 8
        }
        let hash = Array(SHA256.hash(data: Data(entropy)))
        var hashBits = [Bool]()
        for byte in hash.prefix((checksumLength + 7) / 8) {
            for shift in stride(from: 7, through: 0, by: -1) { hashBits.append((byte >> shift) & 1 == 1) }
        }
        return Array(hashBits.prefix(checksumLength)) == Array(bits[entropyLength...])
    }

    /// BIP-39 encoding: `entropy` (16, 20, 24, 28 or 32 bytes) plus its SHA-256 checksum bits, in 11-bit words.
    static func phrase(fromEntropy entropy: Data) -> String? {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { return nil }
        let checksumLength = entropy.count / 4 // bits: 128→4 … 256→8
        var bits = [Bool]()
        bits.reserveCapacity(entropy.count * 8 + checksumLength)
        for byte in entropy { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> shift) & 1 == 1) } }
        let hash = Array(SHA256.hash(data: entropy))
        for i in 0..<checksumLength { bits.append((hash[i / 8] >> (7 - i % 8)) & 1 == 1) }
        var words = [String]()
        for start in stride(from: 0, to: bits.count, by: 11) {
            var index = 0
            for bit in bits[start..<start + 11] { index = (index << 1) | (bit ? 1 : 0) }
            words.append(BIP39Wordlist.words[index])
        }
        return words.joined(separator: " ")
    }

    /// PBKDF2-HMAC-SHA512, 2048 iterations, 64-byte seed. Returns nil for an invalid mnemonic.
    static func seed(phrase: String, passphrase: String = "") -> Data? {
        guard isValid(phrase) else { return nil }
        let normalized = words(phrase).joined(separator: " ")
        let password = Data(normalized.decomposedStringWithCompatibilityMapping.utf8)
        let salt = Data(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return PBKDF2.sha512(password: password, salt: salt, iterations: 2048, keyLength: 64)
    }
}

/// PBKDF2-HMAC-SHA512 built on CryptoKit (avoids a CommonCrypto module dependency). Only the single-block case
/// (keyLength ≤ 64) is needed here — the BIP-39 seed is exactly 64 bytes.
enum PBKDF2 {
    static func sha512(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1]) // INT_32_BE(1)
        var u = Data(HMAC<SHA512>.authenticationCode(for: block, using: key))
        var t = u
        if iterations > 1 {
            for _ in 2...iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for i in 0..<t.count { t[i] ^= u[i] }
            }
        }
        return Data(t.prefix(keyLength))
    }
}

/// A BIP-32 HD node — a private key plus chain code — with hardened and normal child derivation over secp256k1.
struct HDNode {
    let privateKey: Data   // 32 bytes
    let chainCode: Data    // 32 bytes

    static let hardened: UInt32 = 0x8000_0000

    /// The master node from a seed: I = HMAC-SHA512("Bitcoin seed", seed).
    init?(seed: Data) {
        let i = Data(HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: Data("Bitcoin seed".utf8))))
        guard i.count == 64 else { return nil }
        let key = i.prefix(32)
        let scalar = BigUInt(key)
        guard scalar > 0, scalar < Secp256k1Account.curveOrder else { return nil }
        privateKey = Data(key)
        chainCode = Data(i.suffix(32))
    }

    private init(privateKey: Data, chainCode: Data) {
        self.privateKey = privateKey
        self.chainCode = chainCode
    }

    func derive(path: [UInt32]) -> HDNode? {
        var node = self
        for index in path {
            guard let child = node.child(index: index) else { return nil }
            node = child
        }
        return node
    }

    /// CKDpriv from BIP-32.
    func child(index: UInt32) -> HDNode? {
        var data = Data()
        if index & HDNode.hardened != 0 {
            data.append(0)
            data.append(privateKey)
        } else {
            guard let pub = try? P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .compressed).publicKey.dataRepresentation else { return nil }
            data.append(pub) // 33-byte compressed public key
        }
        data.append(contentsOf: withUnsafeBytes(of: index.bigEndian) { Array($0) })

        let i = Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: chainCode)))
        let il = BigUInt(i.prefix(32))
        let n = Secp256k1Account.curveOrder
        guard il < n else { return nil }
        let childScalar = (il + BigUInt(privateKey)) % n
        guard childScalar > 0 else { return nil }
        return HDNode(privateKey: childScalar.serializeBE32(), chainCode: Data(i.suffix(32)))
    }
}

extension BigUInt {
    /// Left-padded 32-byte big-endian serialization (secp256k1 scalars are always 32 bytes).
    func serializeBE32() -> Data {
        let raw = serialize()
        if raw.count >= 32 { return Data(raw.suffix(32)) }
        return Data(repeating: 0, count: 32 - raw.count) + raw
    }
}

extension BIP39Wordlist {
    /// Word → index lookup, memoized so validating a phrase is not O(n) per word over 2048 entries.
    static func index(of word: String) -> Int? { lookup[word] }
    private static let lookup: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
}
