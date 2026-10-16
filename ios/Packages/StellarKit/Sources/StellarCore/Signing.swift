import Crypto
import Foundation

/// Something that signs 32-byte hashes as one Stellar account: a key on this iPhone (`StellarSigner`), or one held
/// elsewhere that answers over the network (a Privy wallet, LiteClient's `PrivyStellarSigner`). A signature is used
/// only once it verifies for `address` (`verifiedSignature`): `TransactionEnvelope.sign(using:network:)` and
/// `sep53Signature(for:)` check it.
public protocol StellarHashSigner: Sendable {
    /// The account's address (G…).
    var address: String { get }
    /// The Ed25519 signature (64 bytes) of `hash` (32 bytes).
    func signHash(_ hash: [UInt8]) async throws -> [UInt8]
}

extension StellarSigner: StellarHashSigner {
    public func signHash(_ hash: [UInt8]) async throws -> [UInt8] { try sign(hash) }
}

/// A signature that doesn't verify for the signer's address: it is never attached nor sent.
public enum StellarSigningError: Error, Equatable {
    case badSignature
}

public extension StellarHashSigner {
    /// `signHash(hash)`, once it verifies for `address`; `.badSignature` otherwise.
    func verifiedSignature(_ hash: [UInt8]) async throws -> [UInt8] {
        let signature = try await signHash(hash)
        guard StellarSigner.verify(address: address, message: hash, signature: signature) else {
            throw StellarSigningError.badSignature
        }
        return signature
    }

    /// The SEP-53 signature (base64) of `message`, checked as `verifiedSignature` checks.
    func sep53Signature(for message: String) async throws -> String {
        Data(try await verifiedSignature(StellarSigner.sep53Digest(message))).base64EncodedString()
    }
}

public extension TransactionEnvelope {
    /// The hash a signature commits to: sha256(networkID ‖ ENVELOPE_TYPE_TX ‖ transaction XDR).
    func hash(network: StellarNetwork) -> [UInt8] {
        var w = XDRWriter()
        w.raw(network.networkID)
        w.uint32(2)
        w.raw(transactionXDR)
        return Array(SHA256.hash(data: Data(w.bytes)))
    }

    /// Adds `signer`'s signature for `network`.
    mutating func sign(with signer: StellarSigner, network: StellarNetwork) throws {
        let sig = try signer.sign(hash(network: network))
        signatures.append(DecoratedSignature(hint: signer.hint, signature: sig))
    }

    /// Adds `signer`'s signature for `network`, once it verifies for the signer's address (a key held elsewhere may
    /// answer with anything).
    mutating func sign(using signer: any StellarHashSigner, network: StellarNetwork) async throws {
        let pub = try StrKey.decode(.accountID, signer.address)
        let signature = try await signer.verifiedSignature(hash(network: network))
        signatures.append(DecoratedSignature(hint: Array(pub.suffix(4)), signature: signature))
    }

    /// Whether a valid signature by `address` is present.
    func isSigned(by address: String, network: StellarNetwork) -> Bool {
        guard let pub = try? StrKey.decode(.accountID, address) else { return false }
        let h = hash(network: network)
        return signatures.contains { $0.hint == Array(pub.suffix(4)) && StellarSigner.verify(address: address, message: h, signature: $0.signature) }
    }
}
