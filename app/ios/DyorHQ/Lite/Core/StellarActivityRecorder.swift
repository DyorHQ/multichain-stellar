// Stellar's notifications (docs/DESIGN-stellar-parity.md §3.7, §8.15). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation

/// Posts a Stellar action to the app's notification center once it has settled, as Monad's settled actions post theirs:
/// once per plan, in the account's own center (its Monad address), with a banner when the user allows them. A tap opens
/// the action's Stellar screen, switching to Stellar first (`Router.openStellar(reference:)`).
///
/// - **When.** The store fires `LiteSession.onSettled` once per settled plan, from its own task, so the post outlives the
///   review sheet. `NetworkRoot.makeSession` installs the recorder on each account's session.
/// - **Kind.** A swap and the bridge are `.swap`, a Moment `.moments`, everything else `.transaction`. Enabling an asset,
///   a restore and the faucet post nothing: Activity lists them.
/// - **Route** `.home` with a `stellar:` reference: a build without Stellar that restores the row opens Monad Home.
/// - **Body.** The action's own words, then the network: " · Stellar testnet" on testnet, " · Stellar" on mainnet.
/// - **Once.** By plan id, and for a background tracker (`notify(id:…)`) by its transfer id, remembered per Stellar
///   address under `lite.notified.<G>`, which signing out of the app erases (`DyorHQLiteKeys.forget`).
///
/// Stellar actions are never written to the Monad wallet's activity log: its rows are Monad transactions, mirrored into
/// DyorHQ's volume. Stellar's activity is the server's (`/v1/activity`).
@MainActor
final class StellarActivityRecorder {
    /// One notification, as the recorder hands it to the center.
    struct Post: Equatable {
        let kind: AppNotification.Kind
        let title: String
        let body: String
        let route: AppNotification.Route
        let reference: String
        /// The account's Monad address: the center the notification is filed in.
        let owner: Address
    }

    /// How many ids it remembers per Stellar address, the newest kept.
    static let remembered = 200

    /// The account whose center the notifications go to.
    let owner: Address
    private let isTestnet: Bool
    private let defaults: UserDefaults
    private let deliver: @MainActor (Post) -> Void
    /// Ids posted while no Stellar address was known (a passkey account before its setup): this launch only.
    private var unfiled: Set<String> = []

    /// - Parameters:
    ///   - owner: the account's Monad address.
    ///   - deliver: hands a notification to the center: `NotificationHub.shared` in the app.
    init(owner: Address, isTestnet: Bool = AppNetwork.stellar.isTestnet, defaults: UserDefaults = .standard,
         deliver: @escaping @MainActor (Post) -> Void = StellarActivityRecorder.post) {
        self.owner = owner
        self.isTestnet = isTestnet
        self.defaults = defaults
        self.deliver = deliver
    }

    /// The recorder for `owner`'s account, as `session`'s settled actions' poster.
    @discardableResult
    static func install(on session: LiteSession, owner: Address) -> StellarActivityRecorder {
        let recorder = StellarActivityRecorder(owner: owner)
        session.onSettled = { [weak session] action in recorder.record(action, account: session?.address) }
        return recorder
    }

    /// The app's notification center: filed in the account's own, with a banner when the user allows them.
    static func post(_ post: Post) {
        NotificationHub.shared.post(kind: post.kind, title: post.title, body: post.body, route: post.route, reference: post.reference,
                                    owner: post.owner)
    }

    /// A settled plan of the Stellar account `account` (G…): posted once, unless its kind posts nothing.
    func record(_ action: LiteSettledAction, account: String?) {
        guard let kind = Self.kind(of: action) else { return }
        notify(id: "plan.\(action.planId)", kind: kind, title: action.title, body: action.body, reference: action.reference, account: account)
    }

    /// Posts once per `id` for the Stellar account `account`: a plan's, or a background tracker's transfer under its own
    /// prefix ("bridge.<id>"). False when that id was posted already. `body` is without the network, which this adds;
    /// `reference` is the screen it opens, Stellar Home when nil.
    @discardableResult
    func notify(id: String, kind: AppNotification.Kind, title: String, body: String, reference: String?, account: String?) -> Bool {
        guard remember(id, account: account) else { return false }
        deliver(Post(kind: kind, title: title, body: withNetwork(body), route: .home,
                     reference: reference ?? StellarDestination.home.reference, owner: owner))
        return true
    }

    /// A settled action's kind of notification; nil for the ones that post nothing (§8.15).
    static func kind(of action: LiteSettledAction) -> AppNotification.Kind? {
        switch action.kind {
        case "swap": return .swap
        case "trust", "restore", "faucet", "activate": return nil
        default: break
        }
        switch action.section {
        case .bridge: return .swap
        case .moments: return .moments
        case .spot, .earn, .launch, .account: return .transaction
        }
    }

    /// `body`, then the network it happened on.
    func withNetwork(_ body: String) -> String {
        let network = isTestnet
            ? liteTr(LocalizedStringResource("Stellar testnet", table: "StellarShell", comment: "After a Stellar notification's text (“Swapped 10 XLM → 1.2 USDC · Stellar testnet”): Stellar's test network, where it happened. Stellar is a network's name, never translated"))
            : AppNetwork.stellar.name
        return body.isEmpty ? network : "\(body) · \(network)"
    }

    /// Notes `id` as posted for `account`; false when it was already.
    private func remember(_ id: String, account: String?) -> Bool {
        guard let account else { return unfiled.insert(id).inserted }
        let key = Self.key(account)
        var ids = defaults.stringArray(forKey: key) ?? []
        guard !ids.contains(id), !unfiled.contains(id) else { return false }
        ids.append(id)
        defaults.set(Array(ids.suffix(Self.remembered)), forKey: key)
        return true
    }

    /// Where the ids posted for a Stellar address are kept: erased with the account (`DyorHQLiteKeys.forget`).
    static func key(_ account: String) -> String { "lite.notified.\(account)" }
}
#endif
