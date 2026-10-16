// Stellar for the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey (DyorHQ/internal
// ios-app/stellar-v2/privy-stellar-wallets.md). Privy holds their keys, so their Stellar key is a Privy wallet the user
// owns, which this iPhone makes and signs with itself, talking to Privy's client API with the user's own session (as
// Privy's SDKs do): DyorHQ's servers are never in that path. This iPhone still builds and checks everything it signs;
// each signature is authorized here by the user's own Privy key (the Privy SDK) and checked against the account's
// address before it is used. Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation
import Observation
import StellarKit

/// Whether the owner lets Privy sign-ins use Stellar (`LiteConfig.privyWallets`, the Lite API's LITE_PRIVY_WALLETS):
/// until a server says so, a Privy account sees "Not available for … sign-in yet" (`LiteGate.availability`). Read as
/// `StellarRemoteFlag` is: when the signed-in app appears and on every return to the foreground, at most once every ten
/// minutes; a failed read keeps the last value, which is kept between launches.
@Observable
@MainActor
final class PrivyWalletsFlag {
    static let shared = PrivyWalletsFlag()

    /// The Lite API's config said `privyWallets: true` the last time it was read.
    private(set) var isOn: Bool
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let interval: TimeInterval = 10 * 60
    private static let key = "lite.privyWallets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.key)
    }

    func check() async {
        guard !checking, let api = LiteGate.apiURL else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        guard let config = try? await LiteAPI(baseURL: api, network: LiteGate.pinned.network.name).config(timeout: 10) else { return }
        isOn = config.privyWallets == true
        defaults.set(isOn, forKey: Self.key)
    }
}

extension DyorHQLiteKeys {
    /// The sign-in methods whose keys Privy holds.
    static func isPrivy(_ method: Session.Method) -> Bool {
        switch method {
        case .apple, .google, .email, .passkey: true
        case .emailPassword, .meraPasskey, .imported, .watchOnly: false
        }
    }

    /// `evm`'s Stellar wallet at Privy, as this iPhone kept it once it checked it: its id and address, stored together under
    /// one key; nil before.
    static func keptPrivyWallet(for evm: Address, defaults: UserDefaults = .standard) -> PrivyStellarWallet? {
        if let pair = defaults.dictionary(forKey: privyKey(evm)) as? [String: String] {
            guard let walletId = pair["walletId"], let address = pair["address"] else { return nil }
            return PrivyStellarWallet(walletId: walletId, address: address)
        }
        // Internal builds before 2026-10-17 kept the id alone, beside the account's Stellar address.
        guard let walletId = defaults.string(forKey: privyKey(evm)), let address = stellarAddress(for: evm, defaults: defaults) else { return nil }
        return PrivyStellarWallet(walletId: walletId, address: address)
    }

    /// Keeps `wallet` as `evm`'s, in one write, then its address as the account's Stellar address: only if nothing of the
    /// account was forgotten since `epoch` (a sign-out or erase while the lookup ran), and only if it may be kept
    /// (`PrivyWalletCheck.mayKeep`). Checked and written under the epochs' lock, so a `forget` is either before (nothing
    /// is written) or after (it removes what was). False when nothing was kept.
    static func keep(_ wallet: PrivyStellarWallet, for evm: Address, epoch: Int, defaults: UserDefaults = .standard) -> Bool {
        PrivyLookupEpochs.shared.ifUnchanged(evm, since: epoch) {
            guard PrivyWalletCheck.mayKeep(wallet, kept: keptPrivyWallet(for: evm, defaults: defaults),
                                           stellarAddress: stellarAddress(for: evm, defaults: defaults)) else { return false }
            defaults.set(["walletId": wallet.walletId, "address": wallet.address], forKey: privyKey(evm))
            store(wallet.address, for: evm, defaults: defaults)
            return true
        } ?? false
    }

    static func privyKey(_ evm: Address) -> String { "lite.privyWallet.\(evm)" }

    /// "Not available for Google sign-in yet.": what a Privy account reads when its sign-in can't have a Stellar wallet
    /// (no Monad wallet id at Privy to compare with, or no identity token from the Privy app), as the sheet says it.
    private static func notForThisSignIn(_ method: Session.Method) -> LiteSession.Failure {
        .server(NetworkAvailability.Reason.signInMethod(method).message)
    }

    /// Privy's client API for the signed-in user (their access token, DyorHQ's app and iOS client, this app's bundle
    /// id): the phone talks to Privy itself, never through DyorHQ's servers.
    @MainActor
    static func privyAPI(session: Session) -> PrivyWalletAPI {
        PrivyWalletAPI(appId: session.config.privyAppID, clientId: session.config.privyClientID,
                       nativeAppIdentifier: Bundle.main.bundleIdentifier ?? "") { [session] in
            guard let token = try await session.privyAccessToken() else { throw SessionError.authenticationRequired }
            return token
        }
    }

    /// The provider of a Privy account whose wallet this iPhone knows: signs in silently, and asks App Lock once per
    /// action where it applies, as a seed account does; each signature is the user's Privy key's to authorize. With
    /// `recheck`, the wallet, read from this iPhone's storage, is confirmed at Privy before the first signature
    /// (`PrivyWalletCheck.confirm`), once for the provider's life: a wallet given another signer since is never used.
    @MainActor
    static func privyProvider(session: Session, settings: AppSettings, method: Session.Method, evm: Address, wallet: PrivyStellarWallet,
                              recheck: Bool) -> LiteKeyProvider {
        let api = privyAPI(session: session)
        let unavailable = notForThisSignIn(method)
        let confirm: PrivyWalletRecheck? = recheck ? PrivyWalletRecheck({ [session] in
            guard let monadWalletId = await session.privyWalletId(for: evm) else { throw unavailable }
            try await PrivyWalletCheck.confirm(wallet, backend: api, ownerWalletId: monadWalletId, ownerAddress: evm.hex)
        }) : nil
        let signer = PrivyStellarSigner(wallet: wallet, appId: session.config.privyAppID, backend: api, authorize: { [session] request in
            try await session.privyAuthorizationSignature(url: request.url, method: request.method, headers: request.headers, body: request.body)
        }, recheck: confirm)
        let appLockApplies: @MainActor @Sendable () -> Bool = { [session, settings] in settings.appLockApplies(to: session.account) }
        return RemoteKeyProvider(signer: signer, methodLabel: method.title) { reason in
            guard await appLockApplies() else { return }
            guard BiometricGate.canAuthenticateOwner else { throw StellarSigningFailure.noDevicePasscode }
            guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
        }
    }

    /// The lookups under way, one per account: two switches at once share one, and one whose switch was cancelled still
    /// finishes and keeps what it found, so a wallet Privy made is never lost and made again.
    @MainActor private static var resolving: [Address: Task<PrivyStellarWallet, Error>] = [:]

    /// A Privy account's first switch (`LiteSession`'s `resolveKeys`), no prompt: its Stellar wallet, found or made at
    /// Privy by this iPhone itself, and used only once Privy says only the user controls it (`PrivyWalletCheck`): owned
    /// by the same key quorum as the account's Privy Monad wallet, with no other signer, not imported. The one kept on
    /// this iPhone stays the account's; it is never swapped for another.
    @MainActor
    static func resolvePrivy(session: Session, settings: AppSettings, evm: Address) async throws -> LiteKeyProvider {
        guard let account = session.account, account.address == evm, isPrivy(account.method) else { throw LiteSession.Failure.keyNotOnDevice }
        let method = account.method
        let lookup: Task<PrivyStellarWallet, Error>
        if let running = resolving[evm] {
            lookup = running
        } else {
            lookup = Task { @MainActor in
                defer { resolving[evm] = nil }
                return try await findPrivyWallet(session: session, method: method, evm: evm)
            }
            resolving[evm] = lookup
        }
        let wallet = try await lookup.value
        // Just checked: the session's first signature needs no second look.
        return privyProvider(session: session, settings: settings, method: method, evm: evm, wallet: wallet, recheck: false)
    }

    @MainActor
    private static func findPrivyWallet(session: Session, method: Session.Method, evm: Address) async throws -> PrivyStellarWallet {
        // The account's Monad wallet at Privy: its owner is the user's own key quorum. A wallet Privy gives no id (an
        // on-device wallet from before Privy's server wallets) can't be compared with.
        let epoch = PrivyLookupEpochs.shared.epoch(evm)
        guard let monadWalletId = await session.privyWalletId(for: evm) else { throw notForThisSignIn(method) }
        let kept = keptPrivyWallet(for: evm)
        // The user's Stellar wallets as Privy's identity token lists them, refreshed: Privy limits how often a user is read,
        // so a refusal is tried once more a moment later. A token Privy didn't reissue isn't current (unless the sign-in
        // that issued it was a moment ago): it makes no new wallet.
        let before = await session.privyIdentityToken(refresh: false)
        let began = Date()
        var identity = await session.privyIdentityTokenRefreshed()
        if !identity.fresh {
            try? await Task.sleep(for: .seconds(2))
            identity = await session.privyIdentityTokenRefreshed()
        }
        let current = PrivyWalletCheck.isCurrent(identity.token, before: before, refreshWentThrough: identity.fresh, began: began)
        let wallet: PrivyStellarWallet
        do {
            wallet = try await PrivyWalletCheck.resolve(backend: privyAPI(session: session), ownerWalletId: monadWalletId,
                                                        ownerAddress: evm.hex, kept: kept, identityToken: identity.token,
                                                        identityTokenIsFresh: current)
        } catch PrivyWalletCheck.Failure.noIdentityToken {
            throw notForThisSignIn(method)
        }
        // Still this account's sign-in, and nothing of it forgotten meanwhile: a sign-out or erase while the lookup ran
        // gets nothing written back. Kept once, never swapped: what this iPhone kept meanwhile, and the Stellar address it
        // already has for the account, must be this wallet's, or nothing is kept and nothing signed.
        guard session.account?.address == evm, session.account?.method == method else { throw LiteSession.Failure.cancelled }
        guard PrivyLookupEpochs.shared.epoch(evm) == epoch else { throw LiteSession.Failure.cancelled }
        guard keep(wallet, for: evm, epoch: epoch) else { throw PrivyWalletCheck.Failure.notOnlyTheUsers }
        return wallet
    }
}

/// How many times each account's Stellar keys were forgotten (`DyorHQLiteKeys.forget`): a Privy wallet lookup notes it
/// as it begins and keeps what it found only if it is unchanged, so a sign-out or erase while it ran is never undone.
final class PrivyLookupEpochs: @unchecked Sendable {
    static let shared = PrivyLookupEpochs()

    private let lock = NSLock()
    private var forgets: [Address: Int] = [:]

    func epoch(_ evm: Address) -> Int { lock.withLock { forgets[evm, default: 0] } }

    /// A sign-out or erase of `evm`: before what was kept for it goes.
    func forgot(_ evm: Address) { lock.withLock { forgets[evm, default: 0] += 1 } }

    /// `write`'s answer, run under the lock while `evm` wasn't forgotten since `epoch`; nil, not run, once it was.
    func ifUnchanged<T>(_ evm: Address, since epoch: Int, _ write: () -> T) -> T? {
        lock.withLock { forgets[evm, default: 0] == epoch ? write() : nil }
    }
}

#endif
