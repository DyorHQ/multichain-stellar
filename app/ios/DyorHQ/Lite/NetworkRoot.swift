// The signed-in app of an internal build (docs/DESIGN-network-switch.md §8.1): Monad's screens or Stellar's, with the
// covers and the network sheet above both. RootView's `.signedIn` shows it. Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The network on screen (`Router.network`), remembered per account (`network.<address>`), and the account's Stellar
/// session (`LiteSession`), kept across switches and dropped with the account (§2.6). Monad's tabs (`MainTabView`, build
/// 23's) and Stellar's (`StellarRootView`) push in from their side, Monad leading and Stellar trailing. The side menu,
/// Profile and the other covers, and the sheet from either Home's chip, sit above the swap, so a switch made from Profile
/// happens under it.
///
/// Nothing on Stellar is gated (docs/DESIGN-stellar-parity.md §1.1 decision 6): opening, relaunching on and coming back
/// to Stellar never prompt and never lock. Prompts come only with a signature (App Lock when it applies, or the passkey).
struct NetworkRoot: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The signed-in account's Stellar session, while the account can use Stellar.
    @State private var stellar: StellarAccount?
    /// Receive, asked for by a Stellar screen's add-funds action (`StellarActions.addFunds`).
    @State private var addingFunds = false

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
                StellarRootView(session: stellarSession)
                    // In from the trailing edge, and back out to it.
                    .transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .leading)))
            } else {
                MainTabView(hostsCovers: false)
                    .transition(.asymmetric(insertion: .push(from: .leading), removal: .push(from: .trailing)))
            }
        }
        .modifier(AppCovers())
        .networkSheet($router.networkSheet) { swap(to: $0) }
        .sheet(isPresented: $addingFunds) { StellarReceiveSheet() }
        .environment(\.stellarSession, stellarSession)
        .environment(\.networkSetupSession, stellarSession)
        .environment(\.stellarActions, actions(stellarSession))
        .task(id: Followed(address: session.address, availability: availability)) { await follow() }
        .onChange(of: router.network) { _, network in AppNetwork.store(network, for: session.address) }
        // The app's language reaches the Stellar screens at once, as it reaches the app's (`LanguageStore`).
        .onChange(of: env.language.locale, initial: true) { _, locale in LiteL10n.locale = locale }
        .task { await StellarRemoteFlag.shared.check(client: env.social.client) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            // Away: the session's renewal timer stops, and a passkey account's setup run ends with its signer ("Not
            // finished. Try again."). Nothing else is held, so nothing else goes.
            case .background: stellarSession?.appDidEnterBackground()
            // Back: the session renews if it is gone or ends soon, without a prompt; and the owner's switch, at most every
            // ten minutes, as `UpdateGate` reads its row.
            case .active:
                stellarSession?.appDidBecomeActive()
                Task { await StellarRemoteFlag.shared.check(client: env.social.client) }
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
            keep(nil)
            return
        }
        guard availability == .offered else {
            // The sheet says why this account can't use Stellar; there is no session to keep.
            keep(nil)
            if router.network == .stellar { router.network = .monad }
            return
        }
        if stellar?.owner != address { keep(StellarAccount(owner: address, session: makeSession(for: address))) }
        // As the account left it, with no push; Monad for a new account (rule 1).
        let remembered = AppNetwork.stored(for: address)
        if router.network != remembered {
            withTransaction(\.disablesAnimations, true) { router.network = remembered }
        }
        // A cold launch on Stellar opens it at once, from what this iPhone saved, and renews the session in the background:
        // never a prompt, never the network sheet (decision 6).
        if remembered == .stellar, let stellarSession { await stellarSession.resumeAtLaunch() }
    }

    /// Keeps `account`'s Stellar session (nil: none), and says whether a Stellar destination can open
    /// (`Router.stellarAvailable`).
    private func keep(_ account: StellarAccount?) {
        stellar = account
        router.stellarAvailable = account != nil
        StellarLiveSession.hold(account?.session, owner: account?.owner)
    }

    /// The account's Stellar session. Its provider signs the sign-in with no prompt (a seed account) and each confirmed
    /// action as Monad's Confirm does; a passkey account's setup ceremony (`setupKey`) derives its Stellar key with one
    /// prompt, the first time. Its settled actions post to the notification center, and Sign out of Stellar erases what
    /// this iPhone saved for it.
    private func makeSession(for owner: Address) -> LiteSession {
        // Passkey accounts only: a seed account's key is in the Keychain, and its setup never needs a ceremony.
        var setupKey: (@Sendable (String) async throws -> LiteSession.UnlockResult)?
        if session.account?.method == .meraPasskey {
            setupKey = { [session] reason in try await DyorHQLiteKeys.setupKey(session: session, evm: owner, reason: reason) }
        }
        let lite = LiteSession(env: LiteGate.environment,
                               stellarAddress: DyorHQLiteKeys.stellarAddress(for: owner),
                               monad: MonadBridgeAdapter(session: session),
                               keys: DyorHQLiteKeys.provider(session: session, settings: settings),
                               setupKey: setupKey)
        StellarActivityRecorder.install(on: lite, owner: owner)
        lite.onSignOut = { _ in StellarSaved.shared.forget(owner) }
        return lite
    }

    /// What the shared Stellar pieces can ask of the screens around them (`StellarActions`). Receive opens over the
    /// Stellar screens, so a sheet that asks for it closes first.
    private func actions(_ lite: LiteSession?) -> StellarActions {
        StellarActions(addFunds: { addingFunds = true },
                       swap: { [router] sell, buy, starter in router.openStellarSwap(sell: sell, buy: buy, starter: starter) },
                       signIn: { try await lite?.signIn() },
                       switchToMonad: { swap(to: .monad) })
    }

    /// A switch from either Home's chip once the sheet has slid down, or from a paused Stellar tab (§2.5): `network`'s
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

/// The signed-in account's Stellar session, as `NetworkRoot` keeps it, for the app's sign-out and erase of this device
/// (Session.swift): they sign it out before `LiteKeyBootstrap.forget` erases what Stellar kept.
@MainActor
enum StellarLiveSession {
    private static var held: (owner: Address, session: LiteSession)?

    /// `NetworkRoot` keeps `session` for `owner`; nil when it keeps none.
    static func hold(_ session: LiteSession?, owner: Address?) {
        guard let session, let owner else { held = nil; return }
        held = (owner, session)
    }

    /// Signs `owner`'s Stellar session out: its refresh token family revoked, its saved session and figures erased
    /// (`LiteSession.signOut()`). Waits at most `limit` for the server; the rest goes on behind.
    static func signOut(owner: Address, limit: Duration = .seconds(3)) async {
        guard let held, held.owner == owner else { return }
        self.held = nil
        let (ended, end) = AsyncStream<Void>.makeStream()
        Task { await held.session.signOut(); end.finish() }
        let timer = Task { try? await Task.sleep(for: limit); end.finish() }
        for await _ in ended {}
        timer.cancel()
    }
}

extension EnvironmentValues {
    /// The signed-in account's Stellar session, for the Stellar screens and the ones over the swap that show Stellar's own
    /// (Profile's Stellar account and Wallet): `NetworkRoot` sets it. Nil where the account can't use Stellar.
    @Entry var stellarSession: LiteSession? = nil
}
#endif
