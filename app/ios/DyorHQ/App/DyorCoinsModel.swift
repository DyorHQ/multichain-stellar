import DyorKit
import Foundation
import Observation

/// The screens' view of the DyorHQ coin registry (`DyorCoinRegistry`): every DyorHQ launchpad and Moments coin known so
/// far, kept in step with the registry (`updates()`), so a row that draws a token's picture (`TokenLogo`) or its label
/// (`TokenBadgeView`) draws again as soon as its coin is known. Reading it never reads the chain. The registry reads
/// when the app starts and every 5 minutes while it is in the foreground (`keepFresh`, from RootView), after a launch or
/// a publish settles (`refresh`), and for the tokens, launches and Moments Home, the Portfolio and the Send sheet load
/// (`prove`, `ingest`): never because a view appeared. Built once, by `AppEnvironment`.
@Observable
@MainActor
final class DyorCoinsModel {
    /// The registry itself: read and written only through this model.
    @ObservationIgnored private let registry: DyorCoinRegistry
    /// Where a coin's picture may be loaded from (`ImageSourcePolicy`: this build's Supabase bucket and the fixed IPFS
    /// gateways, never a host a creator chose).
    @ObservationIgnored let policy: ImageSourcePolicy
    /// Every DyorHQ coin known, by address.
    private(set) var coins: [Address: DyorCoin] = [:]
    /// Whether DyorHQ coins carry their DyorHQ labels: the owner's remote switch `RemoteFlags.dyorBadges`, on unless the
    /// backend turns it off (`AppEnvironment.apply(_:)`). Off, `badge` judges every token as build 16 did, with no
    /// registry entry: no DyorHQ label, and a coin sent to the wallet Unverified. Pictures are unchanged.
    var showsDyorBadges = true
    @ObservationIgnored private var following: Task<Void, Never>?

    /// How often the registry is read again while the app is in the foreground: every 5 minutes.
    static let refreshInterval: TimeInterval = 300

    init(registry: DyorCoinRegistry, policy: ImageSourcePolicy) {
        self.registry = registry
        self.policy = policy
        following = Task { [weak self] in
            for await coins in await registry.updates() {
                guard let self else { return }
                self.coins = coins
            }
        }
    }

    /// The DyorHQ coin at `address`, if known.
    func coin(_ address: Address) -> DyorCoin? { coins[address] }

    /// The picture `token` shows (`CoinIcon.resolve`, by address, from what is known of it now).
    func icon(_ token: Token) -> CoinIcon { CoinIcon.resolve(token, coin: coins[token.address], policy: policy) }

    /// The label `token` shows (`TokenBadge.of`), `receivedUnasked` being whether it reached the wallet without being
    /// chosen in the app. Every screen's label comes from here, so the DyorHQ labels' switch (`showsDyorBadges`) is
    /// applied in this one place.
    func badge(_ token: Token, receivedUnasked: Bool) -> TokenBadge {
        TokenBadge.of(token, coin: showsDyorBadges ? coins[token.address] : nil, receivedUnasked: receivedUnasked)
    }

    /// Reads what the factories recorded since the last complete read (`refreshIfStale`), then again every
    /// `refreshInterval`, until the calling task ends (RootView runs it while the app is in the foreground).
    func keepFresh() async {
        while !Task.isCancelled {
            await registry.refreshIfStale(maxAge: Self.refreshInterval)
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
        }
    }

    /// Reads what the factories recorded since the last read, now: a launch or a publish just settled.
    func refresh() async {
        await registry.refresh()
    }

    /// Asks the factories about the tokens among `tokens` not known yet (`DyorCoinRegistry.prove`): MON, the curated tokens
    /// and the coins already known cost nothing.
    func prove(_ tokens: [Token]) async {
        _ = await registry.prove(tokens.map(\.address))
    }

    /// The coins of launches another read listed, proven by their factories (`DyorCoinRegistry.ingest`).
    func ingest(_ launches: [Launch]) async {
        _ = await registry.ingest(launches)
    }

    /// The coins of Moments another read listed, proven by their cohorts.
    func ingest(_ moments: [MomentInfo]) async {
        _ = await registry.ingest(moments)
    }

    /// The coins `owner` made, as their factories record it: the launches it deployed and the Moments it created.
    func created(by owner: Address) async -> Set<Address> {
        Set(await registry.coins(createdBy: owner).map(\.address))
    }

    /// Forgets every coin and deletes the registry's file (`dyor-coins-143.json`): account deletion.
    func erase() async {
        await registry.erase()
        coins = [:]
    }
}

extension ImageSourcePolicy {
    /// This build's policy (`AppConfig.supabaseURL`'s bucket and the fixed IPFS gateways), for a picture drawn where the
    /// environment isn't at hand: `LaunchArtwork` and `MomentArtwork`, as `DyorCoinsModel.policy` is.
    static let app = ImageSourcePolicy(supabaseURL: AppConfig.current.supabaseURL)
}
