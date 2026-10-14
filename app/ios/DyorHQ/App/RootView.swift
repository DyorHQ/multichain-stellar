import DyorKit
import SwiftUI
import UIKit

/// Chooses between onboarding and the app, following the session state.
struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Router.self) private var router
    #if DEBUG && targetEnvironment(simulator)
    /// `-PerpsDemo [scenario]`: the scripted Perps demo, over whatever the session shows (DEBUG + Simulator only).
    @State private var perpsDemo = PerpsDemo.requested
    #endif

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
            case .signedOut:
                // A passkey account just deleted: what's left to do about the passkey, then onboarding.
                if let done = session.passkeyDeletion {
                    AccountDeletedView(done: done) { session.passkeyDeletion = nil }
                } else if let notice = session.deletionNotice {
                    DeletionNoticeView(message: notice) { session.deletionNotice = nil }
                } else if let required = env.updateGate.required {
                    UpdateRequiredView(minimum: required)
                } else {
                    OnboardingView()
                }
            case .signedIn:
                // A build below the minimum shows balances and export only: nothing that signs is reachable (GP-2).
                if let required = env.updateGate.required {
                    UpdateRequiredView(minimum: required)
                } else {
                    MainTabView()
                }
            }
        }
        .animation(.default, value: session.state)
        // Moment links (universal links on m.dyorhq.fun, and dyorhq://moments/…) arrive here, on the one view that is
        // mounted in every session state; the router only parses and stores. The gate below opens the Moment once the
        // app may navigate — signed in, not behind the update gate, no confirmation on screen or action running — and
        // re-decides on every change of what it looks at, so a link that arrived signed out opens after the sign-in. A
        // tapped banner's screen goes through the same gate (`NotificationRouteGate`), but only for the account signed
        // in: signed out, or for another account, it is dropped.
        .onOpenURL { router.handle($0) }
        .onChange(of: linkGateInput, initial: true) { _, _ in applyLinkGate() }
        .overlay(alignment: .bottom) {
            if let notice = router.linkNotice {
                Paragraph(notice)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); router.linkNotice = nil }
            }
        }
        .animation(.default, value: router.linkNotice)
        // The appearance lives on a View, not on the App's scene body: a scene body does not re-evaluate reliably on
        // an observable change, and the stale scheme it left on the root view controller shadowed the window.
        .preferredColorScheme(settings.appearance.colorScheme)
        // The app's language (`LanguageStore`) as SwiftUI's locale: every `Text` under here follows a choice at once, and
        // every screen keeps its place. Never an `.id` on this view to force it: rebuilding RootView would restart its
        // `.task(id:)` jobs (the backend sign-in, the restore, the per-account binding).
        .environment(\.locale, env.language.locale)
        // Privacy cover for the app-switcher snapshot: iOS screenshots the UI whenever the app leaves the foreground,
        // and that image is written to the app container. If a recovery phrase / private key were on screen (Import
        // Wallet), it would land in that snapshot. Covering the whole hierarchy the instant we're not active means the
        // snapshot only ever captures the cover, never a secret. The exceptions are the owner's own prompts: a passkey
        // ceremony's system sheet and App Lock's Face ID or passcode prompt (`BiometricGate`) make the scene .inactive,
        // and the cover must not blank the app — the sheet being confirmed — behind them. The cover is a window of its
        // own above every other, so it also hides a sheet or full-screen cover (Export Wallet, the recovery phrase),
        // which an overlay on this view never reached (IOSK-13).
        .onChange(of: privacyCovered, initial: true) { _, covered in PrivacyShield.update(covered: covered) }
        .task { session.start(); settings.appearance.apply() }
        .task { await env.updateGate.check(client: env.social.client) }
        .onChange(of: scenePhase) { _, phase in
            // A passkey (Mera) signing session must not outlive the user leaving the app: whoever picks the phone up
            // next has to present the passkey again. Ending it also closes a passkey account's Perpl socket and drops
            // its trading key. An approved plan or order still running keeps it until it finishes, within the
            // background time iOS grants (GL-1).
            if phase == .background {
                session.mera.endWhenIdle()
                // iOS may suspend the app now: the next activation is a return to it (`LogScanClock`).
                LogScanClock.suspended()
                // Alerts arrive while the app is open: checks pause until it is back.
                env.alerts.enteredBackground()
                // The wallet's history: the return is a new foreground session, which reads the server's history again
                // when the scans fell behind, and polls it within a new window (`HistoryModel.resume`).
                env.history.enteredBackground()
            }
            if phase == .active {
                session.mera.enteredForeground()
                settings.appearance.apply()
                // The connections the reads below go over, opened again (iOS closes idle ones while the app is away).
                env.warmConnections()
                // Back from the background: price alerts and open positions are checked at once (a Face ID or passkey
                // prompt, which only makes the scene inactive, changes nothing).
                env.alerts.enteredForeground()
                // The minimum supported build, at most every ten minutes (GP-2).
                Task { await env.updateGate.check(client: env.social.client) }
                // Transactions sent before the app left the foreground: settle their pending rows (GL-2), and pick up
                // the bridges iOS suspended (GL-5).
                Task { await PendingActivity.recheck(owner: session.address, rpc: env.rpc) }
                env.bridgeTracker.resume()
                // The wallet's history: rounds of reading that had stopped short start again.
                env.history.resume(env: env)
                // Reconnect the trading socket the instant the app returns (iOS drops it while suspended), so TP/SL is
                // ready without waiting for the keep-alive loop's next tick. Never a prompt: a passkey account's
                // socket reconnects only inside a live session, and there is none right after a return.
                Task {
                    await env.perplTrading.ensureConnected()
                    // Orders sent before the app left the foreground (or before it was closed) whose result never came:
                    // read from the stream, Perpl's history and the chain, with no notice.
                    await env.perplTrading.reconcileLoadedOrders()
                }
                // Wallet-signed Perps orders whose receipt wasn't read before the app left (or was killed): read now, so
                // their row says what they did (no notice, no socket needed).
                Task { await env.perplTrading.redecodeOnChainOrders() }
                // On a return from the background only: a log scan that was running while iOS suspended the app measures
                // an outage from now, not from its last answer before, and the venue list reads on if its last run ended
                // short (`VenueTokenList.resume`). Face ID, a passkey sheet or Control Center only make the scene
                // inactive: after them, a running scan's outage keeps counting (`LogScanClock`).
                if LogScanClock.resumed() { env.venueList.resume() }
            }
        }
        // Keep the per-wallet sessions tied to the active wallet: rebind whenever the signed-in address changes, so a
        // sign-out + import of a different wallet never carries over the previous account's social profile or its
        // authenticated Perpl trading session.
        .task(id: session.address) {
            env.social.bind(address: session.address)
            // The wallet's on-chain history: from the store at once, filled in behind every screen (`HistoryModel`).
            env.history.start(env: env, wallet: session.address)
            // My Launchpad keeps one wallet's state between openings: another wallet, or a sign-out, clears it.
            env.launchpadProfile.follow(session.address)
            // So does the Portfolio, Total Volume's figures and those saved for the wallet among them.
            env.portfolio.follow(session.address)
            // Bridges are tracked for the account that sent them only: a sign-out or switch stops the rest (RS-2).
            env.bridgeTracker.bind(owner: session.address)
            // Perpl trading and the notification center follow the account at once, not after the backend sign-in's
            // round-trip below, so nothing meanwhile trades for or is filed under the previous account (RS-9).
            env.perplTrading.refresh(account: session.account)
            // Its wallet-signed Perps orders an earlier run never read the receipt of (a kill right after it confirmed).
            Task { await env.perplTrading.redecodeOnChainOrders() }
            NotificationHub.shared.bind(owner: session.address)
            // The one alert watcher follows the account with the notification center: started for it, kept while it stays
            // signed in, stopped on a sign-out or a switch (`AlertCenter`). A watched wallet gets its alerts too, worded
            // for someone who can't act on it.
            env.alerts.bind(owner: session.address, env: env, signedIn: { session.address }, canAct: { session.canSign })
            // A wallet that can sign connects to the backend by itself (one signature), so activity and settings are
            // recorded — and restored on a fresh device — without a separate step. Not a passkey account restored
            // locked at launch: that signature would be a passkey prompt nobody asked for. `signInWithMera` starts its
            // sign-in while its session is live (this joins it), and the background signer never prompts. A stored
            // token `bind` is restoring is this launch's sign-in: this joins it too, and signs only if it didn't restore
            // (RS-3).
            if session.canSignWithoutPrompt, !env.social.isSignedIn, let address = session.address, let wallet = session.backgroundWallet {
                await env.social.signIn(address: address, wallet: wallet)
            }
            // Ask for notification permission once the user is signed in and can act (so swaps, fills and price
            // alerts actually reach the lock screen). notificationsEnabled defaults on, but the Settings toggle only
            // requests when flipped — so a user who never opened Settings was never prompted.
            if session.canSign, settings.notificationsEnabled { await Notifications.requestAuthorizationIfUndetermined() }
            // Transactions sent in an earlier run of the app whose confirmation it never saw (GL-2).
            await PendingActivity.recheck(owner: session.address, rpc: env.rpc)
        }
        // Whenever the account's backend session opens — whoever signed in (the rebind above, the reconnect below,
        // Bridge, a screen that uploads) or a stored token was restored — pull what other devices recorded. Idempotent:
        // activity merges without doubling, the other stores fill only while empty.
        .task(id: "\(env.social.isSignedIn)-\(session.address?.hex ?? "")") {
            guard env.social.isSignedIn, let address = session.address, env.social.isBound(to: address) else { return }
            await env.sync.restore(owner: address)
        }
        // An account that isn't connected to the backend (a passkey account restored locked, a sign-in skipped because
        // the app left the foreground, or a token that just expired after 12 h) reconnects as soon as it can sign
        // without a prompt: at once for a key or Privy wallet, when its session opens for a passkey account. Only once
        // the rebind above has bound this account, and never while a sign-in runs. It can't loop: a failed sign-in
        // leaves isSignedIn false throughout, so the id doesn't change; a success changes it once, then the guard stops.
        .task(id: "\(session.mera.isUnlocked)-\(env.social.isSignedIn)") {
            guard !env.social.isSignedIn, env.social.state == .signedOut, session.canSignWithoutPrompt,
                  let address = session.address, env.social.isBound(to: address), let wallet = session.backgroundWallet else { return }
            await env.social.signIn(address: address, wallet: wallet)
        }
        // The venue token list: what the last run stored is read at once, for search. The run that reads on from it goes
        // through the same gate as the wallet's history, behind it (`LogsGate.Lane.background`), and waits while the
        // signed-in wallet's history fills in for the first time — until the history model is on that wallet, and then
        // until its history is read to the head, or stalled: a run under way is paused, and reads on from its last segment
        // read in full. With no wallet signed in, a list with nothing read (a fresh install, from genesis) waits for a
        // sign-in (`VenueTokenList.follow`). Nothing while the session is restored at launch: it is signed in or out a
        // moment later.
        .task { await env.venueList.load() }
        .task(id: "\(session.state == .loading)-\(session.address?.hex ?? "")-\(env.history.wallet?.hex ?? "")-\(env.history.filling)") {
            guard session.state != .loading else { return }
            env.followVenueTokens(wallet: session.address, historyFilling: env.history.wallet != session.address || env.history.filling)
        }
        // The DyorHQ coin registry: read at start, then every 5 minutes while the app is in the foreground.
        .task(id: scenePhase == .active) { if scenePhase == .active { await env.dyorCoins.keepFresh() } }
        #if DEBUG && targetEnvironment(simulator)
        .fullScreenCover(isPresented: $perpsDemo) { PerpsDemoView() }
        #endif
    }
}

extension RootView {
    /// Whether the privacy cover is up: whenever the app isn't foreground-active, except behind a passkey or App Lock
    /// prompt. Leaving the app during one still covers it: the scene is then in the background.
    private var privacyCovered: Bool {
        !(scenePhase == .active || (scenePhase == .inactive && (session.mera.isPrompting || BiometricGate.isPrompting)))
    }

    /// Everything the link gate decides on, as one value to observe.
    private struct LinkGateInput: Hashable {
        var pending: Bool
        /// A tapped banner's screen, waiting.
        var route: NotificationTap?
        var phase: MomentLinkGate.Phase
        /// The account signed in, which a banner's route must name.
        var signedIn: Address?
        var updateRequired: Bool
        var deletionScreen: Bool
        var busy: Bool
    }

    private var linkGateInput: LinkGateInput {
        let phase: MomentLinkGate.Phase
        switch session.state {
        case .loading: phase = .loading
        case .signedOut: phase = .signedOut
        case .signedIn: phase = .signedIn
        }
        // `runningActions` counts every approved plan (TransactionRun) and Perpl bracket still signing or sending, for
        // every account type. `linkHolds` counts every review sheet on screen (ConfirmationSheet, the Perps order /
        // close / margin / TP/SL reviews, Bridge) — a review not yet confirmed, and the moment a run settles before its
        // caller records it — and the sends and the account deletion that run outside a sheet. An App Lock (Face ID or
        // passcode) or passkey prompt on screen holds too, wherever it was asked from (sign-out, Settings, Export).
        let busy = session.mera.runningActions > 0 || router.linkHolds > 0 || BiometricGate.isPrompting || session.mera.isPrompting
        return LinkGateInput(pending: router.pendingLink != nil, route: router.pendingNotificationRoute, phase: phase,
                             signedIn: session.address, updateRequired: env.updateGate.required != nil,
                             deletionScreen: session.passkeyDeletion != nil || session.deletionNotice != nil, busy: busy)
    }

    private func applyLinkGate() {
        let input = linkGateInput
        guard input.pending || input.route != nil else { return }
        let decision = NotificationRouteGate.decide(link: input.pending, route: input.route, routeArrivedLast: router.notificationRouteArrivedLast,
                                                    phase: input.phase, updateRequired: input.updateRequired,
                                                    deletionScreen: input.deletionScreen, busy: input.busy, signedIn: input.signedIn)
        switch decision.link {
        case .deliver?: router.deliverPendingLink()
        case .drop?: router.pendingLink = nil
        case .hold?, .banner?, nil: break // OnboardingView shows the banner while a link waits signed out
        }
        switch decision.route {
        case .deliver?: router.deliverPendingNotificationRoute()
        case .drop?: router.pendingNotificationRoute = nil
        case .hold?, nil: break
        }
    }
}

/// The privacy cover's window: above every other window of the scene, so it hides the tabs and whatever is presented
/// over them — sheets, full-screen covers, alerts — from the snapshot iOS takes when the app leaves the foreground
/// (IOSK-13). Shown while `update(covered: true)`, gone the moment the app is active again. It never becomes the key
/// window, so a keyboard or a focused field underneath is left as it was.
@MainActor
enum PrivacyShield {
    private static var window: UIWindow?

    static func update(covered: Bool) {
        guard covered else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let shield = UIWindow(windowScene: scene)
        shield.windowLevel = .alert + 1
        shield.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        shield.rootViewController = UIHostingController(rootView: PrivacyCover())
        shield.isHidden = false
        window = shield
    }
}

/// An opaque cover shown whenever the app is not foreground-active, so the OS snapshot can't capture on-screen secrets.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.brand)
        }
        .accessibilityHidden(true)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, launch, trade, moments
    var id: String { rawValue }
}

/// The tab bar plus everything layered over it: the side menu (the three-line button on Home) and the sections it
/// opens outside the tabs (Portfolio, News, Get Help, Profile) as full-screen covers.
struct MainTabView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            // Trade sits between Launch and Moments, dividing the two coin sections.
            Tab("Home", systemImage: "house", value: .home) { HomeView() }
            Tab("Launch", systemImage: "flame", value: .launch) { LaunchpadView() }
            Tab("Trade", systemImage: "arrow.left.arrow.right", value: .trade) { TradeView() }
            Tab("Moments", systemImage: "camera.aperture", value: .moments) { MomentsView() }
        }
        .sensoryFeedback(.selection, trigger: router.tab)
        .fullScreenCover(isPresented: $router.menuOpen) { SideMenuView() }
        .fullScreenCover(item: $router.presented) { screen in
            switch screen {
            case .portfolio: PortfolioView()
            case .news: NewsView()
            case .help: GetHelpView()
            case .profile: ProfileView(presented: true)
            case .notifications: NotificationCenterView()
            }
        }
    }
}
