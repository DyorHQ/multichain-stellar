import Foundation
import StellarKit
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// A key provider for accounts whose Stellar key comes from a recovery phrase (SEP-5). The host passes a closure that
/// returns the phrase only after its own unlock (the Mera passkey session, or App Lock). Used by the main app for
/// passkey and phrase accounts, and by LiteHarness with a phrase it keeps in the Keychain.
public struct PhraseKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel: String
    public let canSign = true
    public let canExportSecret = false
    private let phrase: @Sendable (String) async throws -> String

    public init(address: String, methodLabel: String, phrase: @escaping @Sendable (String) async throws -> String) {
        self.address = address
        self.methodLabel = methodLabel
        self.phrase = phrase
    }

    public func signer(reason: String) async throws -> StellarSigner {
        let signer = try StellarDerivation.sep5(mnemonic: try await phrase(reason))
        guard signer.address == address else { throw KeyError.badMnemonic }
        return signer
    }
}

/// A key provider for accounts whose Stellar seed is kept in the Keychain (email & password, imported key), gated by
/// Face ID / passcode at every signature.
public struct StoredSeedKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel: String
    public let network: String
    public let canSign = true
    public let canExportSecret = true

    public init(address: String, methodLabel: String, network: String) {
        self.address = address
        self.methodLabel = methodLabel
        self.network = network
    }

    public func signer(reason: String) async throws -> StellarSigner {
        #if canImport(LocalAuthentication) && canImport(Security)
        let ctx = LAContext()
        _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard let seed = StellarKeychain.seed(account: address, network: network) else { throw KeyError.badSeed }
        return try StellarSigner(seed: seed)
        #else
        throw KeyError.badSeed
        #endif
    }
}

/// Watch-only: Lite shows balances and refuses every action.
public struct WatchOnlyKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel = "Watch only"
    public let canSign = false
    public let canExportSecret = false

    public init(address: String) { self.address = address }

    public func signer(reason: String) async throws -> StellarSigner { throw KeyError.badSeed }
}
