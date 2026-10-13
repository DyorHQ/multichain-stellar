import Foundation
import StellarKit

/// How the host app lends Lite the account's Stellar key. The key is derived from the account's existing secret
/// (docs/ARCHITECTURE.md §3.2) and handed over only for the duration of one signature.
public protocol LiteKeyProvider: Sendable {
    /// The account's Stellar address (G…), known without unlocking anything.
    var address: String { get }
    /// False for watch-only accounts.
    var canSign: Bool { get }
    /// "Passkey", "Email", "Recovery phrase", … for Settings.
    var methodLabel: String { get }
    /// Email & imported-key accounts can export their Stellar secret (S…); phrase accounts restore from the phrase.
    var canExportSecret: Bool { get }
    /// Unlocks and returns the signer (Face ID, passkey, or App Lock). `reason` is shown in the system prompt.
    func signer(reason: String) async throws -> StellarSigner
}

/// Optional: the Pro (Monad) wallet, for the bridge. The host signs and sends EVM steps and returns the last hash.
public protocol LiteMonadBridge: Sendable {
    var monadAddress: String { get }
    func send(_ steps: [EvmStep]) async throws -> String
}

public struct LiteEnvironment: Sendable {
    public let apiURL: URL
    public let pinned: PinnedContracts
    public let buildNumber: Int

    public init(apiURL: URL, pinned: PinnedContracts = .testnet, buildNumber: Int) {
        self.apiURL = apiURL
        self.pinned = pinned
        self.buildNumber = buildNumber
    }
}
