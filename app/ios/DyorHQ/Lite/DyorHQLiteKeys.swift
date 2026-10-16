// The account's Stellar key, from the secret it already has (docs/ARCHITECTURE.md §3.2), and how it signs: the sign-in
// silently, each action as Monad's Confirm does (docs/DESIGN-stellar-parity.md §1.1 decision 6, §5.8, §7.2, §8.7).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation
import StellarKit

enum DyorHQLiteKeys {
    /// The Stellar address of `evm`'s account on this iPhone (public), stored once its key was derived here; nil before.
    /// An email & password or imported account has it only with its seed in the Keychain (`LiteKeyBootstrap.save`), so
    /// for them it also says the Stellar key is on this iPhone (`LiteGate.availability`).
    static func stellarAddress(for evm: Address) -> String? { UserDefaults.standard.string(forKey: key(evm)) }
    fileprivate static func store(_ stellar: String, for evm: Address) { UserDefaults.standard.set(stellar, forKey: key(evm)) }
    fileprivate static func key(_ evm: Address) -> String { "lite.stellar.\(evm)" }

    /// The network the Keychain files the seeds and sessions under: the build's pinned one.
    static var network: String { LiteGate.pinned.network.name }

    /// The provider for the signed-in account, made without a prompt; nil while its Stellar address isn't known (a passkey
    /// account before its setup ceremony). A seed account signs its sign-in with no prompt and asks for Face ID or the
    /// passcode once per confirmed action while App Lock applies, as `settings` say at that moment; a passkey account asks
    /// for its passkey once per signature, never App Lock.
    @MainActor
    static func provider(session: Session, settings: AppSettings) -> LiteKeyProvider? {
        guard let account = session.account, let stellar = stellarAddress(for: account.address) else { return nil }
        let evm = account.address
        let mera = session.mera
        return make(method: account.method, stellar: stellar,
                    appLockApplies: { [session, settings] in settings.appLockApplies(to: session.account) },
                    phrase: { _ in try await passkeyPhrase(mera, evm: evm) })
    }

    /// The provider as hosts asked for it before decision 6. App Lock is read from the saved setting at each Confirm, as
    /// `provider(session:settings:)` reads it from the app's settings.
    @available(*, deprecated, message: "Pass the app's settings: App Lock is read from them at each Confirm.")
    @MainActor
    static func provider(session: Session) -> LiteKeyProvider? {
        guard let account = session.account, let stellar = stellarAddress(for: account.address) else { return nil }
        let evm = account.address
        let mera = session.mera
        return make(method: account.method, stellar: stellar,
                    appLockApplies: { [session] in AppSettings().appLockApplies(to: session.account) },
                    phrase: { _ in try await passkeyPhrase(mera, evm: evm) })
    }

    /// The provider for an account signed in with `method` whose Stellar address is `stellar`: the Keychain's seed for an
    /// email & password or imported account, which consults `appLockApplies` when an action starts; the passkey for a
    /// passkey account (`phrase` runs one ceremony and returns the words), which never consults App Lock. Nil for the
    /// methods whose keys DyorHQ doesn't hold.
    static func make(method: Session.Method, stellar: String, appLockApplies: @escaping @MainActor @Sendable () -> Bool,
                     phrase: @escaping @Sendable (String) async throws -> String) -> LiteKeyProvider? {
        switch method {
        case .meraPasskey:
            return PhraseKeyProvider(address: stellar, methodLabel: method.title, phrase: phrase)
        case .emailPassword, .imported:
            return GatedSeedKeyProvider(address: stellar, methodLabel: method.title, network: network, appLockApplies: appLockApplies)
        case .apple, .google, .email, .passkey, .watchOnly:
            return nil
        }
    }

    /// A passkey account's setup ceremony (`LiteSession`'s `setupKey`), for `evm`'s account only: one passkey prompt,
    /// whose words give the account's Stellar address, stored here, and the signer of that one run. Passkey accounts only:
    /// a seed account's key is in the Keychain, and its sign-in and setup never need a ceremony.
    @MainActor
    static func setupKey(session: Session, evm: Address, reason: String) async throws -> LiteSession.UnlockResult {
        guard let account = session.account, account.address == evm, account.method == .meraPasskey else {
            throw LiteSession.Failure.keyNotOnDevice
        }
        let mera = session.mera
        let signer = try StellarDerivation.sep5(mnemonic: try await passkeyPhrase(mera, evm: evm))
        store(signer.address, for: evm)
        let keys = PhraseKeyProvider(address: signer.address, methodLabel: account.method.title) { _ in try await passkeyPhrase(mera, evm: evm) }
        return LiteSession.UnlockResult(keys: keys, signer: signer)
    }

    /// The setup ceremony as hosts named it before decision 6.
    @available(*, deprecated, renamed: "setupKey(session:evm:reason:)")
    @MainActor
    static func unlock(session: Session, evm: Address, reason: String) async throws -> LiteSession.UnlockResult {
        try await setupKey(session: session, evm: evm, reason: reason)
    }

    /// The passkey account's recovery phrase, from one ceremony pinned to `evm`'s passkey. A cancelled ceremony and another
    /// account's passkey are said as the setup run says them.
    @MainActor
    private static func passkeyPhrase(_ mera: MeraSession, evm: Address) async throws -> String {
        do {
            return try await mera.revealPhrase(expecting: evm).joined(separator: " ")
        } catch PasskeyCeremony.Failure.cancelled {
            throw LiteSession.Failure.cancelled
        } catch PasskeyCeremony.Failure.wrongCredential, MeraSession.Failure.differentPasskey {
            throw LiteSession.Failure.otherAccountsKey
        }
    }

    /// Sign-out and erase (`LiteKeyBootstrap.forget`): the session's refresh token family is revoked (in the background,
    /// best effort), then the Stellar seed and session stored for `evm` go, with DyorHQLite's notes about the account (set up,
    /// signed out of Stellar, the transfers it was told about), the Stellar figures saved for it (`StellarSaved`), the
    /// remembered address, and the network and Stellar intro remembered for it (`AppNetwork.forget`). Call before
    /// UserDefaults is wiped: it holds the Stellar address the Keychain items are filed under.
    static func forget(evm: Address) {
        let defaults = UserDefaults.standard
        if let stellar = stellarAddress(for: evm) {
            revokeSession(of: stellar)
            StellarKeychain.erase(account: stellar)
            for note in [LiteSession.activatedKey(stellar), LiteSession.signedOutKey(stellar), "lite.notified.\(stellar)"] {
                defaults.removeObject(forKey: note)
            }
        }
        StellarSaved.shared.forget(evm)
        defaults.removeObject(forKey: key(evm))
        AppNetwork.forget(evm)
    }

    /// Asks the Lite API to revoke the refresh token kept for `stellar` and the tokens it rotated into (§5.9): read now,
    /// before the Keychain item goes, and sent from a task of its own, so the sign-out never waits on the network.
    private static func revokeSession(of stellar: String) {
        guard let refresh = StellarKeychain.refreshToken(account: stellar, network: network)?.token, let api = LiteGate.apiURL else { return }
        Task.detached(priority: .utility) {
            await LiteAPI(baseURL: api).revoke(refreshToken: refresh)
        }
    }
}

/// The Stellar seed of an email & password or imported account, kept in this iPhone's Keychain (`StellarKeychain`).
/// Signing follows Monad's Confirm (decision 6): the sign-in challenge is signed with no prompt, as a SEP-53 message
/// signature that can't stand for a transaction's (§5.8); an action asks for Face ID or the passcode once, as it starts,
/// and only while App Lock applies, through `BiometricGate` so the privacy cover stays off behind the prompt (RootView);
/// showing the secret key always asks, as Monad's key export does. The seed is read for each signature and dropped with
/// its signer, so nothing secret outlives one signature.
struct GatedSeedKeyProvider: LiteKeyProvider {
    let address: String
    let methodLabel: String
    let network: String
    let canSign = true
    let canExportSecret = true
    let signsInSilently = true
    /// Whether App Lock applies to the account (`AppSettings.appLockApplies(to:)`), read as each action starts, so a
    /// change in Profile › Security applies to the next Confirm.
    let appLockApplies: @MainActor @Sendable () -> Bool
    /// The account's seed, read from the Keychain for each signature.
    let seed: @Sendable () -> [UInt8]?
    /// Tests only: the device owner's check, counted. Nil in the app, which asks `BiometricGate`.
    let ownerCheck: StellarOwnerCheck?

    init(address: String, methodLabel: String, network: String, appLockApplies: @escaping @MainActor @Sendable () -> Bool,
         seed: (@Sendable () -> [UInt8]?)? = nil, ownerCheck: StellarOwnerCheck? = nil) {
        self.address = address
        self.methodLabel = methodLabel
        self.network = network
        self.appLockApplies = appLockApplies
        self.seed = seed ?? { StellarKeychain.seed(account: address, network: network) }
        self.ownerCheck = ownerCheck
    }

    /// The sign-in challenge's SEP-53 signature, with no prompt: `LiteAPI.signIn` asks for nothing but a challenge of the
    /// exact expected shape, and checks the signature before it is sent.
    func signInSignature(for message: String) async throws -> String {
        try StellarSeedSigningRun.signer(seed: seed, address: address).signMessage(message)
    }

    /// One confirmed action: Face ID or the passcode once, only while App Lock applies; with App Lock on and no device
    /// passcode, nothing can confirm the owner and nothing is signed (App Lock fails closed). A cancelled prompt throws
    /// `.cancelled`: nothing was signed.
    func beginSigning(reason: String) async throws -> LiteSigningRun {
        if await appLockApplies() {
            if let ownerCheck {
                guard await ownerCheck.canAuthenticate() else { throw StellarSigningFailure.noDevicePasscode }
                guard await ownerCheck.authenticate(reason) else { throw LiteSession.Failure.cancelled }
            } else {
                guard BiometricGate.canAuthenticateOwner else { throw StellarSigningFailure.noDevicePasscode }
                guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
            }
        }
        return StellarSeedSigningRun(address: address, seed: seed)
    }

    /// The Stellar secret key (S…): always the device owner's check first, whatever App Lock says.
    func revealSecret(reason: String) async throws -> String {
        if let ownerCheck {
            guard await ownerCheck.authenticate(reason) else { throw LiteSession.Failure.cancelled }
        } else {
            guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
        }
        return try StellarSeedSigningRun.signer(seed: seed, address: address).secret
    }
}

/// One confirmed action's signing for a seed account: each signer reads the Keychain, with no prompt (the action's one
/// check, when App Lock applies, came before it), for one signature. After `end()` it gives none.
final class StellarSeedSigningRun: LiteSigningRun, @unchecked Sendable {
    private let address: String
    private let seed: @Sendable () -> [UInt8]?
    private let lock = NSLock()
    private var ended = false

    init(address: String, seed: @escaping @Sendable () -> [UInt8]?) {
        self.address = address
        self.seed = seed
    }

    func signer(reason: String) async throws -> StellarSigner {
        guard !lock.withLock({ ended }) else { throw LiteSession.Failure.cancelled }
        return try Self.signer(seed: seed, address: address)
    }

    func end() { lock.withLock { ended = true } }

    /// The account's signer from its seed: no seed is no key on this iPhone, another account's seed is refused.
    static func signer(seed: () -> [UInt8]?, address: String) throws -> StellarSigner {
        guard let bytes = seed() else { throw LiteSession.Failure.keyNotOnDevice }
        let signer = try StellarSigner(seed: bytes)
        guard signer.address == address else { throw KeyError.badSeed }
        return signer
    }
}

/// The device owner's check as `GatedSeedKeyProvider` asks it, for tests to count. The app leaves it out, and the provider
/// asks `BiometricGate`.
struct StellarOwnerCheck: Sendable {
    /// Whether the device can verify its owner at all (a passcode is set).
    let canAuthenticate: @MainActor @Sendable () -> Bool
    /// The prompt, with its reason; false when it was cancelled or failed.
    let authenticate: @MainActor @Sendable (String) async -> Bool
}

/// What the app's key provider adds to the session's own failures.
enum StellarSigningFailure: Error, Equatable, LocalizedError {
    /// App Lock is on and the device has no passcode: nothing can confirm its owner, so nothing is signed.
    case noDevicePasscode

    var errorDescription: String? {
        switch self {
        case .noDevicePasscode: tr("App Lock needs a device passcode. Set one in iOS Settings, then try again.")
        }
    }
}

/// Hooks for the two sign-in paths that hold their secret only briefly (docs/INTEGRATION-ios.md §4): the email v2 log-in
/// and bind (`Session.logInWithPassword` / `bindEmailPassword`, where seed and pepper are in hand) and the import flow
/// (`ImportWalletView.runImport`, which still has the phrase or key) call these while they still have the secret.
enum LiteKeyBootstrap {
    static func didDeriveEmailWallet(seed: Data, pepper: Data, evm: Address) {
        guard let signer = try? StellarDerivation.emailV2(seed: [UInt8](seed), pepper: [UInt8](pepper)) else { return }
        save(signer, evm: evm)
    }

    static func didImport(privateKey: Data, evm: Address) {
        guard let signer = try? StellarDerivation.fromSecp256k1(privateKey: [UInt8](privateKey)) else { return }
        save(signer, evm: evm)
    }

    static func didImport(phrase: String, evm: Address) {
        // The words exactly as DyorKit's WalletImport reads them (lowercased, any whitespace), so the Stellar key comes
        // from the same BIP-39 seed as the imported Monad key.
        let words = phrase.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        guard let signer = try? StellarDerivation.sep5(mnemonic: words.joined(separator: " ")) else { return }
        save(signer, evm: evm)
    }

    /// Sign-out and erase: everything Stellar kept for `evm` (`DyorHQLiteKeys.forget`). Call before UserDefaults is wiped.
    static func forget(evm: Address) {
        DyorHQLiteKeys.forget(evm: evm)
    }

    private static func save(_ signer: StellarSigner, evm: Address) {
        guard let seed = try? StrKey.decode(.seed, signer.secret) else { return }
        // Remember the address only once the seed is in the Keychain: an address without its seed can't sign.
        guard (try? StellarKeychain.saveSeed(seed, account: signer.address, network: DyorHQLiteKeys.network)) != nil else { return }
        DyorHQLiteKeys.store(signer.address, for: evm)
    }
}
#endif
