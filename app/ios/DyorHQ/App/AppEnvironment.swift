import DyorKit
import Foundation
import Observation

/// Long-lived services shared by every screen. Built once at launch from the app configuration.
@Observable
@MainActor
final class AppEnvironment {
    let config: AppConfig
    let rpc: RPCClient
    let multicall: Multicall
    let sender: TransactionSender
    /// Monad's pace, measured once a session (`BlockClock`): the one clock every service that shows or claims a time
    /// reads — prices (the 24h change and charts), the launchpad, Moments (live and retired), swap history and token
    /// activity — so the session measures it once.
    let clock: BlockClock
    /// The chain reads several screens make at about the same time, made once and shared (`ChainCache`): the launch list,
    /// the Moments lists (live and retired) and prices, each kept a few seconds. A transaction of the user's that settled
    /// and a pull to refresh forget them (`invalidateChainReads`), so the next read goes to the chain.
    let chainCache = ChainCache()
    /// What never changes once read — each settled launch's token and text, each settled Moment's record and text — and
    /// where tokens are priced, kept between launches (`ChainStore`), so a refresh reads only what moves. Public chain
    /// data only; erased with this device's data (`Session.eraseLocalData`). A fork keeps it in memory only.
    let chainStore: ChainStore
    /// What Home, the Portfolio, the Launch and Moments boards and My Launchpad last showed for each wallet, kept on the
    /// device (`SavedScreens`): a screen opened paints it at once, says when it was read, and reads everything again
    /// behind it. Never another wallet's, never one over a day old; erased with this device's data
    /// (`Session.eraseLocalData`). A fork saves none.
    let savedScreens: SavedScreens
    /// Prices. DyorHQ coins are priced on their own curve or pool (`DyorListing`), never another pool, unless the owner's
    /// remote switch turns that off (`apply(_:)`); Home counts each coin once (`HomeTotals`).
    let prices: PriceService
    let swap: SwapEngine
    let perpl: PerplService
    let launchpad: LaunchpadService
    /// The live Moments cohort (v2). Not deployed while its addresses are pending: then the board says "not live yet"
    /// and the retired cohorts below still serve their holders.
    let moments: MomentsService
    /// The retired Moments cohorts (3, 2, then 1), one service each, CLAIM-ONLY: holders claim vested coins and creators
    /// withdraw their own proceeds and pool fees; nothing else is reachable. Cohorts 1 and 2 paid the retired wallets;
    /// cohort 3 pays the current ones and is retired because v2 replaced it. They never feed the Moments board, the
    /// feeds, publishing or swap routing — those stay on `moments`.
    let retiredMoments: [RetiredMoments]
    /// Moment names → share-link slugs, across every cohort (`MomentLink`, `MomentSlug`).
    let momentDirectory: MomentDirectory
    let news: NewsService
    let activity: TokenActivityService
    let swapHistory: SwapHistoryService
    let walletDiscovery: WalletTokenDiscovery
    /// Where every `eth_getLogs` goes on mainnet: across the public endpoints, in ranges each answers, through one gate
    /// (`LogsRouter`) — a screen's scan first, then the wallet's history, then the venue list (`LogsGate.Lane`) — and the
    /// client every history reader scans through.
    let logsRouter: LogsRouter
    let logsClient: RPCClient
    /// The wallet's history scans, kept on the device and refreshed incrementally (`HistoryStore`), and the records built
    /// from them (`WalletHistoryService`); `history` is what the screens read.
    let historyStore: HistoryStore
    let walletHistory: WalletHistoryService
    let history = HistoryModel()
    /// The server's cache of the wallet's history (supabase migration 32's `history_read`), taken in at the history
    /// model's times (`ServerHistorySync`): nil on a local fork, whose chain isn't the one the server read, and in a build
    /// without the backend. The owner's switches for it are applied with the others (`apply(_:)`).
    let serverHistory: ServerHistorySync?
    /// What the server's history keeps in UserDefaults: the owner's last switches for it, and per wallet the spot check's
    /// day and the distrust (`ServerHistoryDefaults`).
    let serverHistoryDefaults = ServerHistoryDefaults()
    /// Every DyorHQ launchpad and Moments coin, read from the factories (`DyorCoinRegistry`, created here once): what a
    /// token's picture and label are drawn from (`TokenLogo`, `TokenBadgeView`) and which coins are the wallet's own on
    /// Home. Kept in Application Support, a fork's apart from mainnet's.
    let dyorCoins: DyorCoinsModel
    /// Every NFT the wallet holds on Monad, from its own transfer history (Moments and any other collection).
    let nftDiscovery: WalletNFTDiscovery
    let kuruTokens: KuruTokenListClient
    let venueTokens: VenueTokensService
    /// The swap picker's venue token list, in memory for search, brought up to the chain head in the background
    /// (`VenueTokenList`).
    let venueList: VenueTokenList
    let session: Session
    /// Aurora Intents cross-chain bridge (Home "Bridge") + the multi-chain balance reader behind it.
    let aurora: AuroraIntents
    let chainBalances = MultiChainBalances()
    /// Every bridge deposit sent, tracked until it settles — across relaunches, for the account that sent it.
    let bridgeTracker: BridgeTracker
    let settings = AppSettings()
    /// The app's language, decided before any screen: English on an install's first launch, then what the user chose
    /// (`LanguageStore`).
    let language = LanguageStore()
    /// The minimum supported build: below it, "Update required" replaces the app (GP-2).
    let updateGate = UpdateGate()
    /// Authenticated Perpl trading. A passkey account's trading key lives and dies with its session (`session.mera`).
    let perplTrading: PerplTrading
    /// The wallet's cross-section volume / fees / P&L model, shared by Home's Total Volume and the Portfolio page.
    let portfolio = PortfolioModel()
    /// My Launchpad's state for the wallet signed in, kept between openings of the sheet so it shows the last good state
    /// at once and reads it again behind it; RootView clears it when the wallet changes or signs out
    /// (`LaunchpadProfileModel.follow`).
    let launchpadProfile = LaunchpadProfileModel()
    /// The one alert watcher while the app is open: price alerts, Perps margin warnings, fills and closes, on any screen
    /// (`AlertCenter`). RootView binds it to the account signed in.
    let alerts = AlertCenter()
    let social: SocialSession
    /// Mirrors activity, notifications, alerts and settings to Supabase, and restores them on a new device.
    let sync: BackendSync

    init(config: AppConfig) {
        self.config = config
        social = SocialSession(config: config)
        // Keyless public endpoints with failover. Batches stay under rpc.monad.xyz's 50-items-per-second budget; rpc1
        // limits requests rather than items and refuses every batch (HTTP 403, measured 2026-10-10), so it takes single
        // calls and the batches stay on rpc.monad.xyz (`RPCClient.isRefusal`). A read's answer must start within 8 s on an
        // endpoint, then is read whole, and the other is asked too when the first's hasn't started in 1.3 s; a read too big
        // for one request goes out at once, over the endpoints that take batches, never more than 50 calls of it a second
        // to one (`RPCClient`).
        rpc = RPCClient(urls: config.rpcURLs, maxBatch: 40, itemsPerSecond: 50)
        multicall = Multicall(rpc: rpc)
        sender = TransactionSender(rpc: rpc)
        // The Aurora API key never ships in the app: bridge calls go through the aurora-proxy Edge Function, which
        // holds the key and only serves a signed-in wallet.
        let backend = social.client
        aurora = AuroraIntents(proxy: backend.functionURL("aurora-proxy"), feeRecipient: config.auroraFeeRecipient,
                               authorize: { try await backend.sessionHeaders() })
        bridgeTracker = BridgeTracker(aurora: aurora, balances: MultiChainBalances(), monad: EVMChain.monad(rpc: config.rpcURL))
        clock = BlockClock(rpc: rpc)
        // A local fork (a Debug build pointed at 127.0.0.1) keeps its own logs and its own registry file.
        let host = config.rpcURL.host() ?? ""
        let isFork = host == "127.0.0.1" || host == "localhost"
        chainStore = isFork ? ChainStore(directory: nil) : ChainStore.applicationSupport()
        // A saved screen is shown only by the build that saved it (its version and build number).
        let info = Bundle.main.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "")-\(info?["CFBundleVersion"] as? String ?? "")"
        savedScreens = isFork ? SavedScreens(directory: nil, build: build) : SavedScreens.applicationSupport(build: build)
        // History reads go across the public endpoints, in ranges each answers, through one gate (`LogsRouter`): one
        // client for every reader. A local fork keeps its own logs, so a development build pointed at 127.0.0.1 scans the
        // fork instead: one node, whose head is the head the router reads, so it clamps nothing (`LogsEndpoint.clamps`).
        logsRouter = LogsRouter(endpoints: isFork ? [LogsEndpoint(url: config.rpcURL, span: 50_000, clamps: false)] : LogsEndpoints.monadMainnet,
                                store: isFork ? nil : UserDefaultsLogsCapabilityStore())
        logsClient = isFork ? RPCClient(url: config.rpcURL) : RPCClient(logsRouter: logsRouter)
        // State at past blocks (a wallet's nonce at a block, for its first transaction): only the endpoints that answer
        // it, failing over among them; rpc.monad.xyz (the primary client) and rpc3 refuse old blocks.
        let archiveClient = isFork ? RPCClient(url: config.rpcURL) : RPCClient(urls: LogsEndpoints.archive)
        activity = TokenActivityService(rpc: logsClient, clock: clock)
        // A swap's transaction facts (its record, its receipt, the wallet's balance and nonce at its block) are state at
        // past blocks too: read on the archive endpoints only.
        swapHistory = SwapHistoryService(rpc: logsClient, clock: clock, archive: archiveClient)
        // Wallet discovery reads balances/metadata on the primary multicall.
        walletDiscovery = WalletTokenDiscovery(logsRPC: logsClient, multicall: multicall)
        // The wallet's NFTs from the transfers into it its history store holds (`WalletHistorySnapshot.transfersIn`), with
        // no scan of their own: ownership and metadata on the primary multicall.
        nftDiscovery = WalletNFTDiscovery(multicall: multicall)
        kuruTokens = KuruTokenListClient()
        // The venue-wide pool scan (from genesis, no wallet filter), one venue after the other, one request at a time, a
        // throttle waited out rather than split (`VenueTokensService`), through the same router and gate, in its background
        // lane: behind every screen's scan and the wallet's history rounds (`LogsGate.Lane`), and paused while the history
        // fills in (`VenueTokenList.follow`).
        venueTokens = VenueTokensService(logsRPC: logsClient, multicall: multicall)
        // The wallet's history, kept in Application Support (a fork's apart from mainnet's), under the owner's history
        // epoch the last read of the flags said: what the server's history adds before they are read again this launch is
        // marked with it, never with a lower one the next read would drop.
        let historyDirectory = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent(isFork ? "history-fork" : "history")
        let keptSwitches = serverHistoryDefaults.kept
        historyStore = HistoryStore(router: logsRouter, directory: historyDirectory, epoch: keptSwitches.historyEpoch)
        // The registry reads every factory on the failover RPC; a Debug build on a local fork keeps its own file. The
        // price service asks it which tokens are DyorHQ coins, and which factory made each.
        let registry = DyorCoinRegistry(rpc: rpc, live: config.launchpad, liveMoments: config.moments, store: .applicationSupport(fork: isFork))
        prices = PriceService(rpc: rpc, registry: registry, clock: clock, dyorVenues: true, cache: chainCache, store: chainStore)
        // Graduated launchpad and Moment pools become swap routes on Uniswap v4: the live factory's pools (once v2 is
        // deployed) and those of the retired factories with the current record (the legacy 0xad3d… launches all
        // graduate on Monday Trade). A pending live stack adds nothing, so nothing is read from address 0. What the route
        // search finds (each pair's pools, each coin's graduated pool) is kept a minute in the shared reads, so an amount
        // typed or a re-quote costs each venue one quote read; a settled transaction forgets it (`invalidateChainReads`).
        swap = SwapEngine(rpc: rpc, launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: config.launchpad), moments: config.moments, cache: chainCache)
        perpl = PerplService(rpc: rpc)
        // The launch list and the Moments lists are read once for every screen that asks within a few seconds, and what
        // never changes of a settled launch or Moment is read once and kept (`chainCache`, `chainStore`).
        launchpad = LaunchpadService(rpc: rpc, addresses: config.launchpad, logsRPC: logsClient, clock: clock, cache: chainCache, store: chainStore)
        moments = MomentsService(rpc: rpc, addresses: config.moments, logsRPC: logsClient, clock: clock, cache: chainCache, store: chainStore)
        retiredMoments = MomentsAddresses.retiredMainnet.filter { $0.factory != config.moments.factory }.map { [rpc, logsClient, clock, chainCache, chainStore] in
            RetiredMoments(rpc: rpc, addresses: $0, logsRPC: logsClient, clock: clock, cache: chainCache, store: chainStore)
        }
        // The block of a wallet's first transaction, kept on the device once found.
        let keptFirstBlock: @Sendable (Address) -> UInt64? = { wallet in
            UserDefaults.standard.string(forKey: "history.v1.firstBlock.\(wallet.hex.lowercased())").flatMap { UInt64($0) }
        }
        walletHistory = WalletHistoryService(store: historyStore, swapHistory: swapHistory, clock: clock, stacks: { [launchpad] in await launchpad.stacks },
                                             cohorts: [config.moments] + MomentsAddresses.retiredMainnet.filter { $0.factory != config.moments.factory },
                                             firstActivity: { [archiveClient] wallet in
                                                 // The block of the wallet's first transaction, found once (about 27 nonce reads at past blocks)
                                                 // and kept: the transfer scans read back to it, so every swap the wallet ever made counts. A
                                                 // wallet that has sent none is asked again next time, not kept as such. The device's own
                                                 // only: the one the server's history found is kept apart, in the history store, and dropped
                                                 // with the rest of what the server added (`HistoryStore.serverFirstTransaction`).
                                                 if let kept = keptFirstBlock(wallet) { return kept }
                                                 let first = try await archiveClient.firstTransactionBlock(of: wallet, head: try await archiveClient.blockNumber())
                                                 if let first { UserDefaults.standard.set(String(first), forKey: "history.v1.firstBlock.\(wallet.hex.lowercased())") }
                                                 return first
                                             },
                                             // What was found before, from the device with no read: a round never starts above a floor
                                             // already known (it would trim what lies below it), while a lookup runs beside the first.
                                             knownFirstActivity: keptFirstBlock)
        // The server's history: read with the publishable key, the spot check reading the chain through the same router.
        // Never on a fork, whose blocks past its start aren't mainnet's; the switch as the last read of the flags left it.
        serverHistory = isFork || !config.hasSupabase ? nil
            : ServerHistorySync(client: HistoryServerClient(supabase: social.client), history: walletHistory, router: logsRouter, defaults: serverHistoryDefaults)
        history.setServerHistory(keptSwitches.serverHistory)
        #if DEBUG
        // A fork rehearsal (Secrets.xcconfig MOMENTS_*, Debug only): v2 links (c4) and names follow the Moments this build
        // shows. Without the override this is nil, and c4 stays MomentsAddresses.monadMainnet.
        MomentLink.Cohort.rehearse(liveFactory: config.moments.factory == MomentsAddresses.monadMainnet.factory ? nil : config.moments.factory)
        #endif
        // Every Moment's name in publish order, for share links by name (dyorhq.fun/moments/<name>): cohorts 1–3 up to
        // their pinned counts, then v2 once it is wired.
        momentDirectory = MomentDirectory(rpc: rpc)
        news = NewsService()
        venueList = VenueTokenList(service: venueTokens, logos: { [kuruTokens] in await kuruTokens.logos() },
                                   read: { VenueTokenStore.read() }, write: { VenueTokenStore.write($0, lastBlock: $1, dropped: $2) })
        dyorCoins = DyorCoinsModel(registry: registry, policy: ImageSourcePolicy(supabaseURL: config.supabaseURL))
        session = Session(config: config, backend: social)
        // An erase of this device's data deletes the registry's file and the image caches too.
        session.dyorCoins = dyorCoins
        // An erase of this device's data deletes the chain facts kept between launches and forgets the shared reads.
        session.chainStore = chainStore
        session.chainCache = chainCache
        // An erase of this device's data deletes every screen saved for every wallet.
        session.savedScreens = savedScreens
        // An erase of this device's data saves App Lock as a new install has it, and sets it here too (R4).
        session.settings = settings
        // An erase of this device's data sets the language back to English, as on a new install.
        session.language = language
        // A passkey session's scope check trusts only the configured Moments cohorts — v2 (collects, once deployed), then
        // cohorts 3, 2 and 1 (claims and creator withdrawals) — and signs a launchpad trade only against the curve a
        // known factory recorded on-chain (MERA-PLAN §3).
        session.mera.contracts = Mera.SigningPolicy.Contracts(moments: config.moments)
        session.mera.curveVerifier = { [launchpad] token in await launchpad.knownCurve(token: token) }
        // Retired launchpads are sell-only (owner decision 2026-09-28): the wallet refuses a buy into a curve a retired
        // factory recorded, whatever the sheet declared or a Face ID approved.
        session.mera.retiredCurveLookup = { [launchpad] curves in await launchpad.retiredCurves(among: curves) }
        perplTrading = PerplTrading(mera: session.mera)
        // The chain's word on which positions are open, which the automatic TP/SL clean-up needs besides the stream's.
        // A position the account's bitmap holds but the read left out (a failed sub-read, a market not listed) throws:
        // it is never read as closed.
        perplTrading.readPositions = { [perpl] address, markets in
            guard let account = try await perpl.account(address) else { return [] }
            let positions = try await perpl.positions(account, markets: markets)
            guard Set(positions.map(\.perpId)).isSuperset(of: account.positionPerpIds) else {
                throw PerplTradeError.unavailable(tr("Perpl positions couldn't be read in full."))
            }
            return positions
        }
        // An order's outcome and the app-wide watcher: one notice per fill, the order's own or the watcher's, never two
        // (`PerpExpectedFills`); a close that executed nothing makes the position's ending news again.
        perplTrading.notifyFills = { [settings] in settings.notificationsEnabled && settings.notifyFills }
        perplTrading.expectFill = { [alerts] id, perpId, side, growth, until in alerts.expectFill(id, perpId: perpId, side: side, growth: growth, until: until) }
        perplTrading.fillAnnounced = { [alerts] id, size in alerts.fillAnnounced(id, size: size) }
        perplTrading.releaseFill = { [alerts] id in alerts.releaseFill(id) }
        perplTrading.watcherAnnounced = { [alerts] perpId, side, since in alerts.watcherAnnounced(perpId: perpId, side: side, since: since) }
        perplTrading.wakeWatcher = { [alerts] in alerts.reconsiderFills() }
        perplTrading.userCloseVoided = { [alerts] perpId in alerts.forgetUserClose(perpId) }
        // What a wallet-signed order's transaction did, from its receipt (up to three reads while it reads back null).
        perplTrading.receiptRequests = { [perpl] hash in try await perpl.receiptRequests(hash) }
        // The signed order history, two pages at most: what an order whose stream report was missed is read from.
        perplTrading.orderHistory = { [perpl] key in
            let first = try await perpl.orderEvents(key: key)
            guard let next = first.next else { return first.items }
            let second = try await perpl.orderEvents(key: key, cursor: next)
            return first.items + second.items
        }
        sync = BackendSync(social: social)
        sync.install(settings: settings, address: { [weak session] in session?.address })
        // The owner's remote switches, read with the minimum build: each on until the row turns it off.
        updateGate.onFlags = { [weak self] flags in self?.apply(flags) }
        // The connections the first screens read over, opened before they ask.
        warmConnections()
    }

    /// When `warmConnections` last opened the connections.
    @ObservationIgnored private var warmedAt = Date.distantPast

    /// Opens the connections the first reads go over before they ask (speed work, 2026-10-10): the app's two RPC endpoints
    /// (Home's reads, the hedge of a slow one), the logs endpoint the wallet's history reads first (rpc2), and Supabase. A
    /// new connection costs 0.4–1.1 s of handshakes per host (measured 2026-10-08), paid by the first screen otherwise. At
    /// launch and on every return to the app (iOS closes idle connections while it is away), at most every 30 s. Each is
    /// a request that reads nothing and changes nothing (`RPCClient.warm`, `SupabaseClient.warm`).
    func warmConnections() {
        let now = Date()
        guard now.timeIntervalSince(warmedAt) > 30 else { return }
        warmedAt = now
        Task.detached(priority: .userInitiated) { [rpc, logsClient, backend = social.client] in
            async let app: Void = rpc.warm()
            async let logs: Void = logsClient.warm(first: 1)
            async let social: Void = backend.warm()
            _ = await (app, logs, social)
        }
    }

    /// The last venue switch handed to the price service, so switches apply in the order they were read.
    @ObservationIgnored private var venueSwitch: Task<Void, Never>?
    /// The last history epoch handed to the store, so epochs apply in the order they were read.
    @ObservationIgnored private var epochSwitch: Task<Void, Never>?

    /// Applies the owner's remote switches (`RemoteFlags`, from `UpdateGate`'s read of `app_config` 'ios'): DyorHQ venue
    /// prices on the price service (off: priced like any token, as build 16 did), the DyorHQ labels on the coins model
    /// (off: build 16's labels), on Perps the live order outcome (off: today's acknowledgement sheet, and Close / Add
    /// Margin / Cancel Order go on-chain) and the API actions (off: Close / Add Margin / Cancel Order go on-chain), and the
    /// server's history on the history model (off: the chain alone, as build 22 read it), each on unless the row says
    /// false. A Perps request already sent keeps the mode of its tap. The history epoch is applied to the store whatever
    /// the switch says: entries that took the server's history in under a lower one are read again from nothing, and the
    /// rounds start over on the wallet when any was. The last values read of the two Perps switches (`PerpsSwitchStore`)
    /// and of the server's two (`ServerHistoryDefaults`) are kept on the device for the next launch; nothing is written to
    /// the backend, and the next check applies the row again.
    func apply(_ flags: RemoteFlags) {
        dyorCoins.showsDyorBadges = flags.dyorBadges
        perplTrading.liveOutcomes = flags.perpsLiveOutcome
        perplTrading.apiActions = flags.perpsApiActions
        PerpsSwitchStore.save(flags)
        let previous = venueSwitch
        venueSwitch = Task { [prices] in
            await previous?.value
            await prices.setUsesDyorVenues(flags.dyorVenuePrices)
        }
        serverHistoryDefaults.keep(flags)
        history.setServerHistory(flags.serverHistory)
        let previousEpoch = epochSwitch
        epochSwitch = Task { [weak self, historyStore] in
            await previousEpoch?.value
            let reset = await historyStore.apply(epoch: flags.historyEpoch)
            guard reset > 0, let self else { return }
            history.epochReset(env: self)
        }
    }

    /// Forgets every chain read the screens share (`chainCache`), and the shared head (`clock.head`, `HeadClock.forget`): a
    /// transaction of the user's settled (`ConfirmationSheet`), or a pull to refresh asked for what is on chain now. The
    /// next read of the launch list, the Moments lists, every price, the head they are measured from and Swap's route
    /// search goes to the chain, and no read begun before this is joined or kept. What never changes (`chainStore`)
    /// stays.
    func invalidateChainReads() {
        chainCache.invalidate()
        clock.head.forget()
    }

    /// A transaction sender for `chain`: Monad reuses the app's configured endpoint (and multicall); every other
    /// source chain gets a sender bound to that chain's public RPC + id, so the same wallet key signs a valid
    /// transfer there.
    func sender(for chain: EVMChain) -> TransactionSender {
        chain.isMonad ? sender : TransactionSender(rpc: RPCClient(url: chain.rpcURL), chainId: chain.chainId)
    }

    /// The retired Moments cohort whose factory is `factory`, or nil (the live cohort, or anything else).
    func retiredMoments(for factory: Address) -> RetiredMoments? {
        retiredMoments.first { $0.factory == factory }
    }

    /// The Bridge's Monad chain descriptor, pointed at the app's configured RPC rather than the public default.
    var bridgeMonad: EVMChain { EVMChain.monad(rpc: config.rpcURL) }

    /// Builds/refreshes the global venue token list (Uniswap + Monday Trade). The first run scans the FULL history
    /// from genesis in checkpointed segments, so progress survives the app backgrounding; later runs resume from the
    /// checkpoint and only read the new tail. The checkpoint moves past a segment only once it was read in full; a
    /// segment read in part is read again next time (`VenueTokensService.refresh`). Each new token is enriched with its
    /// accurate Kuru logo and added to the list the swap picker searches (`venueList`). A run waits while the signed-in
    /// wallet's history fills in for the first time, one under way paused at once, and with no wallet signed in a list
    /// with nothing read waits for a sign-in (`VenueTokenList.follow`). Runs after `AppSettings` has decided App Lock
    /// (`settings` is built with this environment), so what the store writes can't turn it off.
    func followVenueTokens(wallet: Address?, historyFilling: Bool) {
        venueList.follow(wallet: wallet, historyFilling: historyFilling)
    }
}
