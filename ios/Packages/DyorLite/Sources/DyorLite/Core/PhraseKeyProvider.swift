import Foundation
import StellarKit
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// A key provider for accounts whose Stellar key comes from a recovery phrase (SEP-5) that only the host's own ceremony
/// gives out: the Mera passkey for passkey accounts. Nothing about it is silent: the sign-in and every signature ask for
/// that ceremony, and the words never outlive the signature they make.
public struct PhraseKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel: String
    public let canSign = true
    public let canExportSecret = false
    public let signsInSilently = false
    private let phrase: @Sendable (String) async throws -> String

    /// `phrase` runs the ceremony and returns the words; `reason` is in the current language.
    public init(address: String, methodLabel: String, phrase: @escaping @Sendable (String) async throws -> String) {
        self.address = address
        self.methodLabel = methodLabel
        self.phrase = phrase
    }

    /// Only the ceremony gives the key: a sign-in with no session needs the passkey (`LiteSession.signIn()`).
    public func signInSignature(for message: String) async throws -> String { throw LiteSession.Failure.needsPasskey }

    /// Asks nothing: each signature of the run is one ceremony.
    public func beginSigning(reason: String) async throws -> LiteSigningRun {
        PhraseSigningRun(address: address, phrase: phrase)
    }

    /// A phrase account restores from its phrase: there is no secret key to show (`canExportSecret` is false).
    public func revealSecret(reason: String) async throws -> String { throw KeyError.badSeed }
}

/// A phrase account's run: one ceremony per signer, its words dropped once the key is derived.
final class PhraseSigningRun: LiteSigningRun {
    private let address: String
    private let phrase: @Sendable (String) async throws -> String
    private let ended = SigningRunEnd()

    init(address: String, phrase: @escaping @Sendable (String) async throws -> String) {
        self.address = address
        self.phrase = phrase
    }

    func signer(reason: String) async throws -> any StellarHashSigner {
        try ended.check()
        let signer = try StellarDerivation.sep5(mnemonic: try await phrase(reason))
        // A run that ended during the ceremony signs nothing more.
        try ended.check()
        guard signer.address == address else { throw KeyError.badMnemonic }
        return signer
    }

    func end() { ended.end() }
}

/// A key provider for accounts whose Stellar seed is kept in this iPhone's Keychain (email & password, an imported phrase
/// or key). It signs the sign-in with no prompt (the seed is read for that one signature), and asks for Face ID or the
/// passcode once per confirmed action, only when `appLock` says App Lock applies, as Monad's Confirm does. LiteHarness
/// uses it with App Lock always on; the app has its own, which asks through its privacy cover.
public struct StoredSeedKeyProvider: LiteKeyProvider {
    public let address: String
    public let methodLabel: String
    public let network: String
    public let canSign = true
    public let canExportSecret = true
    public let signsInSilently = true
    private let appLock: @Sendable () -> Bool
    private let seed: @Sendable () -> [UInt8]?
    private let authenticate: @Sendable (String) async throws -> Void

    /// `appLock` is read when an action starts, so a change of the setting applies to the next one.
    public init(address: String, methodLabel: String, network: String, appLock: @escaping @Sendable () -> Bool = { true }) {
        self.init(address: address, methodLabel: methodLabel, network: network, appLock: appLock,
                  seed: { StellarKeychain.seed(account: address, network: network) },
                  authenticate: { reason in try await DeviceOwner.authenticate(reason: reason) })
    }

    /// The Keychain and the owner's check as given (tests).
    init(address: String, methodLabel: String, network: String, appLock: @escaping @Sendable () -> Bool,
         seed: @escaping @Sendable () -> [UInt8]?, authenticate: @escaping @Sendable (String) async throws -> Void) {
        self.address = address
        self.methodLabel = methodLabel
        self.network = network
        self.appLock = appLock
        self.seed = seed
        self.authenticate = authenticate
    }

    public func signInSignature(for message: String) async throws -> String {
        try SeedSigningRun.signer(seed: seed, address: address).signMessage(message)
    }

    public func beginSigning(reason: String) async throws -> LiteSigningRun {
        if appLock() { try await authenticate(reason) }
        return SeedSigningRun(address: address, seed: seed)
    }

    public func revealSecret(reason: String) async throws -> String {
        try await authenticate(reason)
        return try SeedSigningRun.signer(seed: seed, address: address).secret
    }
}

/// A seed account's run: each signer reads the Keychain, with no prompt (the action's one check came before).
final class SeedSigningRun: LiteSigningRun {
    private let address: String
    private let seed: @Sendable () -> [UInt8]?
    private let ended = SigningRunEnd()

    init(address: String, seed: @escaping @Sendable () -> [UInt8]?) {
        self.address = address
        self.seed = seed
    }

    func signer(reason: String) async throws -> any StellarHashSigner {
        try ended.check()
        return try Self.signer(seed: seed, address: address)
    }

    func end() { ended.end() }

    /// The account's signer from its seed; another account's seed, or none, is no key on this iPhone.
    static func signer(seed: () -> [UInt8]?, address: String) throws -> StellarSigner {
        guard let bytes = seed() else { throw KeyError.badSeed }
        let signer = try StellarSigner(seed: bytes)
        guard signer.address == address else { throw KeyError.badSeed }
        return signer
    }
}

/// Watch-only: the Stellar screens show balances and refuse every signature.
public struct WatchOnlyKeyProvider: LiteKeyProvider {
    public let address: String
    public var methodLabel: String { tr("Watch only") }
    public let canSign = false
    public let canExportSecret = false
    public let signsInSilently = false

    public init(address: String) { self.address = address }

    public func signInSignature(for message: String) async throws -> String { throw LiteSession.Failure.needsPasskey }
    public func beginSigning(reason: String) async throws -> LiteSigningRun { throw KeyError.badSeed }
    public func revealSecret(reason: String) async throws -> String { throw KeyError.badSeed }
}

/// Whether a signing run has ended; a signer asked for after it is refused as cancelled.
final class SigningRunEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnded = false

    func end() { lock.withLock { isEnded = true } }

    func check() throws {
        if lock.withLock({ isEnded }) { throw LiteSession.Failure.cancelled }
    }
}

/// The device owner's check (Face ID, Touch ID or the passcode), with `reason` in the system prompt.
enum DeviceOwner {
    static func authenticate(reason: String) async throws {
        #if canImport(LocalAuthentication)
        _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        #else
        throw KeyError.badSeed
        #endif
    }
}
