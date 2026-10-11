import Crypto
import Foundation

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

    /// Whether a valid signature by `address` is present.
    func isSigned(by address: String, network: StellarNetwork) -> Bool {
        guard let pub = try? StrKey.decode(.accountID, address) else { return false }
        let h = hash(network: network)
        return signatures.contains { $0.hint == Array(pub.suffix(4)) && StellarSigner.verify(address: address, message: h, signature: $0.signature) }
    }
}
