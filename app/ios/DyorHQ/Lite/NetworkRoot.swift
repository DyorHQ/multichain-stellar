// The signed-in app of an internal build (docs/DESIGN-network-switch.md §8.1): Monad's screens or Stellar's, with the
// covers and the network sheet above both. RootView's `.signedIn` shows it. Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The network on screen (`Router.network`), remembered per account (`network.<address>`), and the account's Stellar
/// session (`LiteSession`), kept across switches and dropped with the account (§2.6). Monad's tabs (`MainTabView`, build
/// 23's) and DyorLite's (`LiteRootView`) push in from their side, Monad leading and Stellar trailing. The side menu,
/// Profile and the other covers, and the sheet from either Home's chip, sit above the swap, so a switch made from Profile
/// happens under it.
struct NetworkRoot: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The signed-in account's Stellar session, while the account can use Stellar.
    @State private var stellar: StellarAccount?

    /// A Stellar session and the account it belongs to: one per account, never handed to another.
    private struct StellarAccount {
        let owner: Address
        let session: LiteSession
    }

    /// What `follow()` follows.
    private struct Followed: Equatable {
        let address: Address?
        let availability: NetworkAvailability?
    }

    private var availability: NetworkAvailability? { LiteGate.availability(session: session) }

    /// The session of the account signed in now.
    private var stellarSession: LiteSession? {
        guard let stellar, stellar.owner == session.address else { return nil }
        return stellar.session
    }

    private var showsStellar: Bool { router.network == .stellar && stellarSession != nil }

    var body: some View {
        @Bindable var router = router
        ZStack {
            if showsStellar, let stellarSession {
                LiteRootView(session: stellarSession, selection: $router.stellarTab.liteTab, style: .dyorHQ, chrome: chrome(stellarSession))
                    // In from the trailing edge, and back out to it.
                    .transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
            } else {
                MainTabView(hostsCovers: false)
                    .transition(.asymmetric(insertion: .push(from: .leading), removal: .push(from: .trailing)))
            }
        }
        .modifier(AppCovers())
        .networkSheet($router.networkSheet) { swap(to: $0) }
        .environment(\.stellarSession, stellarSession)
        .environment(\.networkSetupSession, stellarSession)
        .task(id: Followed(address: session.address, availability: availability)) { await follow() }
        .onChange(of: router.network) { _, network in AppNetwork.store(network, for: session.address) }
        // The app's language reaches the Stellar screens at once, as it reaches the app's (`LanguageStore`).
        .onChange(of: env.language.locale, initial: true) { _, locale in LiteL10n.locale = locale }
        .task { await StellarRemoteFlag.shared.check(client: env.social.client) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            // The setup run's signer goes when the app leaves (only `.background`: Face ID and passkey sheets make the
            // scene `.inactive`, and the run needs its signer behind them).
            case .background: stellarSession?.appDidEnterBackground()
            // The owner's switch, at most every ten minutes, as `UpdateGate` reads its row.
            case .active: Task { await StellarRemoteFlag.shared.check(client: env.social.client) }
            default: break
            }
        }
    }

    /// The account's network and Stellar session: at a sign-in, and whenever the control appears, goes or changes what it
    /// offers (the owner's switch is read after launch).
    private func follow() async {
        guard let address = session.address, let availability else {
            // The control is gone (the owner's switch turned off, §2.6 rule 4): Monad, saying why if Stellar was on screen.
            router.networkSheet = nil
            if router.network == .stellar {
                if showsStellar {
                    router.linkNotice = liteTr(LocalizedStringResource("Stellar is off for now. You're back on Monad.", table: "Lite", comment: "A notice at the bottom of the screen: DyorHQ turned its Stellar service off, so the app went back to the Monad network"))
                    Haptics.warning()
                }
                router.network = .monad
            }
            stellar = nil
            return
        }
        guard availability == .offered else {
            // The sheet says why this account can't use Stellar; there is no session to keep.
            stellar = nil
            if router.network == .stellar { router.network = .monad }
            return
        }
        if stellar?.owner != address { stellar = StellarAccount(owner: address, session: makeSession(for: address)) }
        // As the account left it, with no push; Monad for a new account (rule 1).
        let remembered = AppNetwork.stored(for: address)
        if router.network != remembered {
            withTransaction(\.disablesAnimations, true) { router.network = remembered }
        }
        // A cold launch on Stellar restores its session silently: never a prompt (rule 2). Locked, Stellar Home says so.
        if remembered == .stellar, let stellarSession { await stellarSession.resumeAtLaunch() }
    }

    /// The account's Stellar session. Its unlock is one prompt per setup run (`DyorHQLiteKeys.unlock`); its provider, when
    /// one can be made without a prompt, signs the transactions after it, each with its own.
    private func makeSession(for owner: Address) -> LiteSession {
        LiteSession(env: LiteGate.environment,
                    stellarAddress: DyorHQLiteKeys.stellarAddress(for: owner),
                    monad: MonadBridgeAdapter(session: session),
                    keys: DyorHQLiteKeys.provider(session: session),
                    unlock: { [session] reason in try await DyorHQLiteKeys.unlock(session: session, evm: owner, reason: reason) })
    }

    /// What the Stellar screens draw of the app's: Monad Home's header and the network chip, and the locked and paused
    /// cards' buttons.
    private func chrome(_ stellar: LiteSession) -> LiteChrome {
        LiteChrome(
            header: { context in
                // `HomeHeader` as Monad Home has it: its search button opens the Stellar search.
                AnyView(HomeHeader(showSearch: Binding(get: { false }, set: { if $0 { context.openSearch() } }),
                                   error: context.error, updatedAt: context.updatedAt))
            },
            // DyorLite puts it in the card's 44 pt chip row (`LiteHomeView.chipRow`), so the chip alone.
            networkChip: { AnyView(NetworkChip(network: .stellar)) },
            unlock: { unlockInline(stellar) },
            switchToMonad: { swap(to: .monad) })
    }

    /// The locked card's unlock (§2.2 C): Setup runs in place, the card's button busy. Where it stops for the user or
    /// fails, the sheet opens at Setup, where the run stands.
    private func unlockInline(_ stellar: LiteSession) {
        Task {
            await stellar.run()
            switch stellar.state {
            case .waiting, .failed: router.networkSheet = NetworkSheetRequest(origin: .home, startAt: .setup)
            default: break
            }
        }
    }

    /// A switch from either Home's chip once the sheet has slid down, or from Stellar's paused card (§2.5): `network`'s
    /// screens push in from their side in 320 ms (a cut with Reduce Motion) on their Home tab, and VoiceOver starts on
    /// their chip (§5, §6).
    private func swap(to network: AppNetwork) {
        guard router.network != network else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
            router.network = network
            if network == .monad { router.tab = .home } else { router.stellarTab = .home }
            router.focusesNetworkChip = true
        }
    }
}

extension LiteStyle {
    /// DyorHQ's own tokens for the Stellar screens (§7): Brand, the status colours and the label on them.
    static let dyorHQ = LiteStyle(accent: .brand, positive: .positive, negative: .negative, attention: .attention, onStatus: .onStatus)
}

extension EnvironmentValues {
    /// The signed-in account's Stellar session, for the screens over the swap that show Stellar's own (Profile's Stellar
    /// account and Wallet): `NetworkRoot` sets it. Nil where the account can't use Stellar.
    @Entry var stellarSession: LiteSession? = nil
}
#endif
