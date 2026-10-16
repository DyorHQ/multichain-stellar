// Stellar for the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey (DyorHQ/internal
// ios-app/stellar-v2/privy-stellar-wallets.md). Privy holds their keys, so their Stellar key is a Privy wallet the user
// owns, made through the Lite API the first time. This iPhone still builds and checks everything it signs; each
// signature is authorized here by the user's own Privy key (the Privy SDK), relayed by the Lite API, and checked against
// the account's address before it is used. Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation
import Observation
import StellarKit

/// Whether the Lite API serves Stellar wallets for Privy sign-ins (`LiteConfig.privyWallets`): until it does, a Privy
/// account sees "Not available for … sign-in yet" (`LiteGate.availability`). Read as `StellarRemoteFlag` is: when the
/// signed-in app appears and on every return to the foreground, at most once every ten minutes; a failed read keeps the
/// last value, which is kept between launches.
@Observable
@MainActor
final class PrivyWalletsFlag {
    static let shared = PrivyWalletsFlag()

    /// The Lite API said `privyWallets: true` the last time it was read.
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
    static func privyWalletId(for evm: Address) -> String? { UserDefaults.standard.string(forKey: privyKey(evm)) }
    static func privyKey(_ evm: Address) -> String { "lite.privyWallet.\(evm)" }

    /// The provider of a Privy account whose wallet this iPhone knows: signs in silently, and asks App Lock once per
    /// action where it applies, as a seed account does; each signature is the user's Privy key's to authorize.
    @MainActor
    static func privyProvider(session: Session, settings: AppSettings, method: Session.Method, wallet: PrivyWallet) -> LiteKeyProvider {
        let appId = session.config.privyAppID
        let api = LiteAPI(baseURL: LiteGate.environment.apiURL, network: network)
        let signer = PrivyStellarSigner(address: wallet.address, walletId: wallet.walletId, appId: appId, backend: api) { [session] request in
            try await session.privyAuthorizationSignature(url: request.url, method: request.method, headers: request.headers, body: request.body)
        }
        let appLockApplies: @MainActor @Sendable () -> Bool = { [session, settings] in settings.appLockApplies(to: session.account) }
        return RemoteKeyProvider(signer: signer, methodLabel: method.title) { reason in
            guard await appLockApplies() else { return }
            guard BiometricGate.canAuthenticateOwner else { throw StellarSigningFailure.noDevicePasscode }
            guard await BiometricGate.authenticate(reason: reason) else { throw LiteSession.Failure.cancelled }
        }
    }

    /// A Privy account's first switch (`LiteSession`'s `resolveKeys`), no prompt: the account's Stellar wallet from the
    /// Lite API, made the first time, then checked before anything is kept. It must be the wallet this iPhone kept for
    /// the account, if it kept one, and one Privy itself lists for the user, where Privy's identity token lists any
    /// Stellar wallet: so a Lite API that answered with an address of its own is refused.
    @MainActor
    static func resolvePrivy(session: Session, settings: AppSettings, evm: Address) async throws -> LiteKeyProvider {
        guard let account = session.account, account.address == evm, isPrivy(account.method) else { throw LiteSession.Failure.keyNotOnDevice }
        // Proof of the user for the Lite API: Privy's identity token (fresh from Privy), which can't be traded for the
        // user's key.
        guard let proof = try await session.privyIdentityToken(refresh: true) else { throw LiteSession.privyWalletsUnavailable }
        let wallet = try await LiteAPI(baseURL: LiteGate.environment.apiURL, network: network).privyWallet(privyToken: proof)
        // What this iPhone kept for the account: its address, with its wallet id where that was kept too.
        let kept = stellarAddress(for: evm).map { PrivyWallet(walletId: privyWalletId(for: evm) ?? wallet.walletId, address: $0) }
        // Privy's own list, read again after the lookup: a wallet made a moment ago is in it.
        let fresh = try await session.privyIdentityToken(refresh: true) ?? proof
        guard PrivyWalletCheck.accepts(wallet, kept: kept, identityToken: fresh) else { throw unconfirmed }
        store(wallet.address, for: evm)
        UserDefaults.standard.set(wallet.walletId, forKey: privyKey(evm))
        return privyProvider(session: session, settings: settings, method: account.method, wallet: wallet)
    }

    /// The wallet the Lite API named isn't one Privy confirms as the user's, or isn't the one this iPhone kept.
    private static var unconfirmed: LiteSession.Failure {
        .server(liteTr(LocalizedStringResource("Privy didn't confirm this Stellar wallet as yours, so DyorHQ won't use it. Nothing was signed.", table: "Lite", comment: "An error on the network sheet: the Stellar wallet DyorHQ's server named for an Apple, Google, email-code or Privy-passkey account isn't one Privy (the company holding the key) lists for the user")))
    }
}

#endif
