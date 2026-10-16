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

    /// Privy's id of `evm`'s Stellar wallet, kept with its address once this iPhone checked it; nil before.
    static func privyStellarWalletId(for evm: Address) -> String? { UserDefaults.standard.string(forKey: privyKey(evm)) }
    static func privyKey(_ evm: Address) -> String { "lite.privyWallet.\(evm)" }

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
    /// action where it applies, as a seed account does; each signature is the user's Privy key's to authorize.
    @MainActor
    static func privyProvider(session: Session, settings: AppSettings, method: Session.Method, wallet: PrivyStellarWallet) -> LiteKeyProvider {
        let signer = PrivyStellarSigner(wallet: wallet, appId: session.config.privyAppID, backend: privyAPI(session: session)) { [session] request in
            try await session.privyAuthorizationSignature(url: request.url, method: request.method, headers: request.headers, body: request.body)
        }
        let appLockApplies: @MainActor @Sendable () -> Bool = { [session, settings] in settings.appLockApplies(to: session.account) }
        return RemoteKeyProvider(signer: signer, methodLabel: method.title) { reason in
            guard await appLockApplies() else { return }
            guard BiometricGate.canAuthenticateOwner else { throw StellarSigningFailure.noDevicePasscode }
            guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
        }
    }

    /// A Privy account's first switch (`LiteSession`'s `resolveKeys`), no prompt: its Stellar wallet, found or made at
    /// Privy by this iPhone itself, and used only once Privy says only the user controls it (`PrivyWalletCheck`): owned
    /// by the same key quorum as the account's Privy Monad wallet, with no other signer, not imported. The one kept on
    /// this iPhone stays the account's; it is never swapped for another.
    @MainActor
    static func resolvePrivy(session: Session, settings: AppSettings, evm: Address) async throws -> LiteKeyProvider {
        guard let account = session.account, account.address == evm, isPrivy(account.method) else { throw LiteSession.Failure.keyNotOnDevice }
        // The account's Monad wallet at Privy: its owner is the user's own key quorum. A wallet Privy gives no id (an
        // on-device wallet from before Privy's server wallets) can't be compared with.
        guard let monadWalletId = await session.privyWalletId(for: evm) else { throw LiteSession.privyWalletsUnavailable }
        let kept: PrivyStellarWallet? = {
            guard let address = stellarAddress(for: evm), let id = privyStellarWalletId(for: evm) else { return nil }
            return PrivyStellarWallet(walletId: id, address: address)
        }()
        // The user's Stellar wallets as Privy's identity token lists them, refreshed: Privy limits how often a user is read,
        // so a refusal is tried once more a moment later; a token it couldn't refresh makes no new wallet.
        var identity = await session.privyIdentityTokenRefreshed()
        if !identity.fresh {
            try? await Task.sleep(for: .seconds(2))
            identity = await session.privyIdentityTokenRefreshed()
        }
        let wallet = try await PrivyWalletCheck.resolve(backend: privyAPI(session: session), ownerWalletId: monadWalletId, kept: kept,
                                                        identityToken: identity.token, identityTokenIsFresh: identity.fresh)
        store(wallet.address, for: evm)
        UserDefaults.standard.set(wallet.walletId, forKey: privyKey(evm))
        return privyProvider(session: session, settings: settings, method: account.method, wallet: wallet)
    }
}

#endif
