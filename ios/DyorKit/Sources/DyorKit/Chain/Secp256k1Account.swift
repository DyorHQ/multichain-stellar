import BigInt
import Foundation
import P256K // re-exports its own `Digest`; do not also import CryptoKit here or the name becomes ambiguous

/// A locally-held Ethereum account: the user's own secp256k1 private key, imported into the app and used to sign
/// on-device. The raw key stays in memory only as long as the account object lives; callers store it in the
/// Keychain, never on a server. This is what makes "import your wallet" self-custodial without Privy.
public struct Secp256k1Account: Sendable {
    /// The 32-byte private key. Sensitive — never log, transmit, or persist outside the device Keychain.
    public let privateKey: Data
    public let address: Address

    /// The secp256k1 group order n. A valid private key is in 1..<n.
    public static let curveOrder = BigUInt("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", radix: 16)!

    public init?(privateKey: Data) {
        guard privateKey.count == 32 else { return nil }
        let scalar = BigUInt(privateKey)
        guard scalar > 0, scalar < Secp256k1Account.curveOrder else { return nil }
        guard let key = try? P256K.Signing.PrivateKey(dataRepresentation: privateKey) else { return nil }
        // Uncompressed public key is 65 bytes: 0x04 || X(32) || Y(32). The address is the last 20 bytes of the
        // keccak-256 of the 64-byte X||Y. `uncompressedRepresentation` serializes it explicitly and reliably.
        let pub = key.publicKey.uncompressedRepresentation
        guard pub.count == 65 else { return nil }
        let hash = Keccak.hash256(Data(pub.suffix(64)))
        guard let address = Address(data: Data(hash.suffix(20))) else { return nil }
        self.privateKey = privateKey
        self.address = address
    }

    public init?(privateKeyHex: String) {
        var hex = privateKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hex.hasPrefix("0x"), !hex.hasPrefix("0X") { hex = "0x" + hex }
        guard let data = Data(hex: hex) else { return nil }
        self.init(privateKey: data)
    }

    // MARK: Signing

    /// Signs a raw 32-byte hash and returns the 65-byte `[r || s || v]` signature with `v` as 27/28 — the shape
    /// EIP-191 personal_sign and EIP-712 both use. libsecp256k1 always produces a low-S (canonical) signature.
    public func sign(hash32: Data) throws -> Data {
        let (r, s, recid) = try rawSign(hash32: hash32)
        var out = Data()
        out.append(r)
        out.append(s)
        out.append(UInt8(recid) + 27)
        return out
    }

    /// EIP-191 personal_sign over an arbitrary message: signs keccak256("\u{19}Ethereum Signed Message:\n<len>" ‖ message).
    public func signMessage(_ message: Data) throws -> Data {
        let prefix = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8)
        let digest = Keccak.hash256(prefix + message)
        return try sign(hash32: digest)
    }

    /// Signs a prepared EIP-1559 transaction and returns the RLP-encoded signed transaction (`0x02…`), ready for
    /// `eth_sendRawTransaction`. The type-2 signature uses `yParity` (0/1), not 27/28.
    public func sign(_ tx: PreparedTransaction) throws -> Data {
        let hash = Keccak.hash256(RLP.unsignedPayload(tx))
        let (r, s, recid) = try rawSign(hash32: hash)
        return RLP.signedTransaction(tx, v: UInt8(recid), r: BigUInt(r), s: BigUInt(s))
    }

    /// Recovers the signer's address from a 32-byte hash and a 65-byte `[r || s || v]` signature (v 27/28 or 0/1).
    /// The inverse of `sign(hash32:)`; used in tests to prove a signature is over the expected preimage, and
    /// available to verify an EIP-191/712 signature on-device.
    public static func recover(hash32: Data, signature: Data) -> Address? {
        guard hash32.count == 32, signature.count == 65 else { return nil }
        var v = signature[signature.startIndex + 64]
        if v >= 27 { v -= 27 }
        guard v <= 1,
              let sig = try? P256K.Recovery.ECDSASignature(compactRepresentation: signature.prefix(64), recoveryId: Int32(v)),
              let recovered = try? P256K.Recovery.PublicKey(RawDigest32(hash32), signature: sig),
              let signing = try? P256K.Signing.PublicKey(dataRepresentation: recovered.dataRepresentation, format: .compressed)
        else { return nil }
        let bytes = signing.uncompressedRepresentation
        guard bytes.count == 65 else { return nil }
        return Address(data: Data(Keccak.hash256(Data(bytes.suffix(64))).suffix(20)))
    }

    private func rawSign(hash32: Data) throws -> (r: Data, s: Data, recid: Int32) {
        guard hash32.count == 32 else { throw Secp256k1Error.badHashLength }
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey)
        let signature = try key.signature(for: RawDigest32(hash32))
        let compact = try signature.compactRepresentation
        // compact.signature is 64 bytes: R(32) || S(32).
        let r = compact.signature.prefix(32)
        let s = compact.signature.suffix(32)
        return (Data(r), Data(s), compact.recoveryId)
    }
}

extension Secp256k1Account: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: the private key must never appear in a `print`, log, string interpolation, or crash
    /// reflection. Only the (public) address is shown.
    public var description: String { "Secp256k1Account(\(address.short), privateKey: <redacted>)" }
    public var debugDescription: String { description }
}

public enum Secp256k1Error: Error { case badHashLength }

/// Wraps an already-computed 32-byte hash (e.g. a keccak-256 digest) so it can be signed by swift-secp256k1's
/// `signature(for: some Digest)` without the library applying a second hash. Keccak is not a digest type, so this
/// bridges it. It conforms to P256K's own `Digest` protocol (swift-secp256k1 vends its own, distinct from
/// CryptoKit's — using the bare name here is ambiguous).
struct RawDigest32: Digest {
    static var byteCount: Int { 32 }
    let bytes: Data

    init(_ data: Data) { bytes = data }

    func makeIterator() -> Data.Iterator { bytes.makeIterator() }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
    static func == (lhs: RawDigest32, rhs: RawDigest32) -> Bool { lhs.bytes == rhs.bytes }
    var description: String { "RawDigest32(32 bytes)" }
}
