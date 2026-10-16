import Foundation
import StellarKit

/// A key provider for accounts whose Stellar key is held elsewhere and signs over the network: a Privy wallet, for the
/// accounts that sign in with Apple, Google, an email code or a Privy passkey (DyorHQ/internal
/// ios-app/stellar-v2/privy-stellar-wallets.md §5.2; the signer is StellarKit's `PrivyStellarSigner`). It works as a seed
/// account's does: the sign-in is signed with no prompt (the only thing signed without the user, and `LiteAPI.signIn`
/// checks it is exactly the expected challenge first), and each confirmed action asks the device owner once, as Monad's
/// Confirm does, only while App Lock applies (`ownerCheck`). Every signature is checked against `address` before it is
/// used. Nothing can be exported: the key stays with Privy.
public struct RemoteKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel: String
    public let canSign = true
    public let canExportSecret = false
    public let signsInSilently = true
    private let signer: any StellarHashSigner
    private let ownerCheck: @Sendable (String) async throws -> Void

    /// - Parameters:
    ///   - signer: the account's signer; its address is the account's.
    ///   - ownerCheck: run as each action starts, with its reason in the current language: Face ID or the passcode while
    ///     App Lock applies, nothing otherwise. It throws `LiteSession.Failure.cancelled` for a cancelled prompt, and
    ///     nothing is signed.
    public init(signer: any StellarHashSigner, methodLabel: String, ownerCheck: @escaping @Sendable (String) async throws -> Void) {
        address = signer.address
        self.methodLabel = methodLabel
        self.signer = signer
        self.ownerCheck = ownerCheck
    }

    public func signInSignature(for message: String) async throws -> String {
        try await signer.sep53Signature(for: message)
    }

    public func beginSigning(reason: String) async throws -> LiteSigningRun {
        try await ownerCheck(reason)
        return RemoteSigningRun(signer: signer)
    }

    /// The key stays with Privy: there is no secret key to show (`canExportSecret` is false).
    public func revealSecret(reason: String) async throws -> String { throw KeyError.badSeed }
}

/// One confirmed action's run for a remote key: its signer signs nothing once the run has ended.
final class RemoteSigningRun: LiteSigningRun {
    private let signer: any StellarHashSigner
    private let ended = SigningRunEnd()

    init(signer: any StellarHashSigner) { self.signer = signer }

    func signer(reason: String) async throws -> any StellarHashSigner {
        try ended.check()
        return RunBoundSigner(inner: signer, ended: ended)
    }

    func end() { ended.end() }
}

/// A run's signer: each signature first checks that its run is still on.
private struct RunBoundSigner: StellarHashSigner {
    let inner: any StellarHashSigner
    let ended: SigningRunEnd

    var address: String { inner.address }

    func signHash(_ hash: [UInt8]) async throws -> [UInt8] {
        try ended.check()
        return try await inner.signHash(hash)
    }
}
