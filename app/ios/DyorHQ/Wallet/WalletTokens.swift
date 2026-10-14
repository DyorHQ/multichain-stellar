import BigInt
import DyorKit

/// Every token the wallet holds on Monad, read one way for every list of them — the Portfolio's Assets and the Send
/// sheet — so the two can't drift: native MON, the curated list, every token acquired in the app, and every ERC-20
/// the wallet's whole transfer history shows it received (Launchpad and Moment coins, airdrops, wrapped tokens), kept
/// while its balance is above zero, valued, and ranked (`WalletHoldings.ranked`): the Send list by value with unpriced
/// tokens after priced ones, the Portfolio in the order it has always used.
@MainActor
enum WalletTokens {
    struct Read {
        /// The wallet read.
        let owner: Address
        /// The tokens held (balance above zero), in universe order. Never an NFT collection.
        let tokens: [Token]
        let balances: [Address: BigUInt]
        /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12),
        /// except the DyorHQ coins that turn out to be its own (`ranked`).
        let unverified: Set<Address>
        /// False when part of the wallet's history (`WalletTokenDiscovery.Scan`) or of its balances couldn't be read: a
        /// token it holds may be missing, which a list says rather than passing `tokens` off as everything.
        let complete: Bool
    }

    /// The tokens `address` holds, with their balances (`ERC20.balanceReport`: MON on its own, the curated tokens in a read
    /// of their own, every other token in bounded reads, so no third-party contract can keep MON or a curated token from
    /// being read, nor break the whole list). Throws when no balance could be read at all, so a failed read is never
    /// taken for an empty wallet; a part that couldn't be read leaves the list incomplete (`Read.complete`), with a token
    /// whose balance read failed left out as it always was when it is one only stored here, and said when it is MON, a
    /// curated token or one the history just found.
    static func read(env: AppEnvironment, address: Address) async throws -> Read {
        let scan = await history(env: env, address: address)
        return try await read(env: env, address: address, history: scan)
    }

    /// The ERC-20s the wallet's transfer history shows it received (`WalletTokenDiscovery.held`, from the history model's
    /// transfers): the slow part of a read while that history is still filling in, so the Send sheet lists the rest
    /// meanwhile. Tokens stored for the wallet are skipped: every read has them. The Send sheet and the Portfolio say part
    /// of the wallet couldn't be read, with Retry, when the history couldn't be read in full.
    static func history(env: AppEnvironment, address: Address) async -> WalletTokenDiscovery.Scan {
        let known = Set(KnownTokenStore.universe(owner: address).map(\.address))
        // The history model's transfers (`HistoryModel`), no scan of its own. While the transfer scan is still filling in
        // (a first read of the wallet), the list waits for it, as it waited for its own scan, up to `historyWait`; the
        // list is complete once the scan has read its window, and says so otherwise. Only that scan holds it up
        // (`WalletHistoryScans.holdings`): not one the list isn't read from, nor one that can't reach the chain, nor a
        // round reading the blocks since a head read from the device at launch (`readingWindow`): the next read adds them.
        let started = ContinuousClock.now
        while env.history.wallet == address, env.history.snapshot.readingWindow(scans: WalletHistoryScans.holdings),
              ContinuousClock.now - started < historyWait, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        let snapshot = env.history.wallet == address ? env.history.snapshot : .empty
        return await env.walletDiscovery.held(wallet: address, incoming: snapshot.transfersIn, complete: snapshot.status(WalletHistoryScans.transfersInId).complete, known: known)
    }

    /// The longest a list waits for the wallet's transfer history to fill in.
    static let historyWait: Duration = .seconds(45)

    /// `read`, with the history already scanned (`history`), or not yet (nil): then the tokens are MON, the curated ones
    /// and every one stored for the wallet, what the Send sheet lists while the history is read, and `Read.complete`
    /// speaks for their balances only.
    static func read(env: AppEnvironment, address: Address, history scan: WalletTokenDiscovery.Scan?) async throws -> Read {
        var universe = KnownTokenStore.universe(owner: address)
        let known = Set(universe.map(\.address))
        // A token stored while the history was read (bought in the meantime) is in the universe already, as chosen.
        let found = (scan?.tokens ?? []).filter { !known.contains($0.address) }
        universe += found
        let unverified = KnownTokenStore.unverified(owner: address).union(found.map(\.address))
        let report = await ERC20.balanceReport(of: universe, owner: address, rpc: env.rpc, multicall: env.multicall)
        if report.balances.isEmpty, !report.unread.isEmpty || !report.failed.isEmpty { throw BalancesUnread() }
        let mustRead = Set([Monad.native] + Token.core.map(\.address) + found.map(\.address))
        let balancesComplete = report.unread.isEmpty && report.failed.isDisjoint(with: mustRead)
        let held = WalletHoldings.held(universe, balances: report.balances)
        // Earlier builds' discovery stored NFT collections as tokens (their `balanceOf` counts editions): left out, as
        // discovery now leaves them out. An edition can't be sent as a token, and it shows under NFTs.
        let collections = await env.walletDiscovery.collections(among: held)
        return Read(owner: address, tokens: held.filter { !collections.contains($0.address) }, balances: report.balances, unverified: unverified,
                    complete: (scan?.complete ?? true) && balancesComplete)
    }

    /// No balance could be read.
    struct BalancesUnread: Error {}

    /// `read`'s tokens, valued and ranked.
    struct Ranked {
        let tokens: [HeldToken]
        /// Prices couldn't all be read: the pool finder's read failed (the curated dollar stables keep their $1, most
        /// tokens are unpriced and ranked by amount rather than value), a curated token's own price read failed (MON's
        /// included: `WalletHoldings.unpricedCurated`'s `unread`), or a DyorHQ coin's own value couldn't be read (its
        /// launch or Moment, or its live price: `AppCoins.complete`), so it is unpriced. The ranking is then not wholly by
        /// value: a list says so and shows no total, and a send preselects nothing.
        let pricesFailed: Bool
        /// The curated tokens held that no pool the price finder looks for prices (cbBTC, LBTC, ezETH, rETH, aprMON:
        /// `WalletHoldings.unpricedCurated`'s `noPool`). They simply have no price, which is no failure, whatever amount is
        /// held: the Portfolio totals the rest and names them, and a send still preselects the top priced token, their rows
        /// reading "No price".
        let unpriced: [Token]
        /// The held coins still on a launchpad's curve, from the same read that valued them (`HeldLaunches.curve`); nil when
        /// the launchpads couldn't be asked.
        let curve: CurveHoldings?
    }

    /// `read`'s tokens valued and ranked by `order` (the Send list's unless another is given): at their pools' prices,
    /// a curated dollar stable no pool prices at $1 (`WalletHoldings.stablesAtPar`), and DyorHQ's own coins as the app
    /// values them (`WalletHoldings.pricing`) — a launch coin at its curve's or pool's live price in its pair asset, a
    /// Moment coin at its pool's live USDC price — which no pool the price finder looks for gives them. Prices that can't
    /// be read leave tokens unpriced, never hidden, and say so (`Ranked.pricesFailed`); a curated token no pool prices is
    /// named (`Ranked.unpriced`), and is no failure. A DyorHQ coin the wallet launched, or whose Moment it collected or
    /// created, is its own, not Unverified (`WalletHoldings.unverified`), and is recorded as chosen, so Home, which marks
    /// what the token store marks, agrees.
    static func ranked(_ read: Read, env: AppEnvironment, by order: (HeldToken, HeldToken) -> Bool = WalletHoldings.precedes) async -> Ranked {
        async let coins = appCoins(read, env: env)
        // Which tokens are DyorHQ coins, from their factories, for their pictures and labels: known before the list shows.
        async let proven: Void = env.dyorCoins.prove(read.tokens)
        // The launchpad's pair assets too (MON, USDC, AUSD, aBIL), whether held or not: a launch coin's price is in one.
        var seen = Set<Address>()
        let priced = (read.tokens + [Token.mon] + Token.core.filter { Token.launchpadPairAssets.contains($0.address) }).filter { seen.insert($0.address).inserted }
        let prices: [Address: PriceInfo]
        var failed = false
        var noPool: Set<Address> = []
        do {
            prices = try await env.prices.prices(for: priced)
            noPool = await env.prices.withoutPool(read.tokens)
        } catch {
            prices = PriceService.definedPrices(for: priced)
            failed = true
        }
        let own = await coins
        let pooled = WalletHoldings.stablesAtPar(prices.mapValues(\.usd), tokens: read.tokens)
        let valued = WalletHoldings.pricing(pooled, launches: own.launches, moments: own.momentPrices)
        let unverified = WalletHoldings.unverified(read.unverified, owner: read.owner, launches: own.launches, staked: own.staked)
        let ownCoins = WalletHoldings.ownCoins(owner: read.owner, launches: own.launches, staked: own.staked)
        markOwnCoins(ownCoins, among: read.tokens, owner: read.owner)
        let unpriced = WalletHoldings.unpricedCurated(read.tokens, prices: valued, noPool: noPool)
        await proven
        return Ranked(tokens: WalletHoldings.ranked(read.tokens, balances: read.balances, prices: valued, unverified: unverified, by: order),
                      pricesFailed: failed || !own.complete || !unpriced.unread.isEmpty, unpriced: unpriced.noPool, curve: own.curve)
    }

    /// Records the coins of `own` among `tokens` — DyorHQ coins that are `owner`'s own (`WalletHoldings.ownCoins`: a launch
    /// it deployed, a Moment it collected or created) — as chosen, so no list marks them Unverified. The one way every
    /// screen does it: the Portfolio and the Send sheet from the launchpads' and cohorts' records (`ranked`), Home from the
    /// coins the registry says the wallet made (`DyorCoinsModel.created`). A coin the wallet was only sent is never in
    /// `own`, and stays Unverified (IOST-12).
    static func markOwnCoins(_ own: Set<Address>, among tokens: [Token], owner: Address) {
        for token in tokens where own.contains(token.address) {
            KnownTokenStore.add(token, owner: owner)
            KnownTokenStore.markChosen(token.address, owner: owner)
        }
    }

    /// DyorHQ's own coins among a read's tokens, as their factories record them.
    struct AppCoins {
        /// Launch coins: any launchpad, live or retired, in any phase, with their launches and live prices.
        var launches: HeldLaunches = .none
        /// Moment coins' dollar prices (`WalletHoldings.momentPrice`), the live cohort's or a retired one's: nil for one
        /// whose Moment or live price couldn't be read, or that has no pool.
        var momentPrices: [Address: Double?] = [:]
        /// The Moment coins whose Moment this wallet collected or created.
        var staked: Set<Address> = []
        /// Every DyorHQ coin among the tokens could be told apart and valued: false when the launchpads' records, a
        /// factory's launches, a launch's live price, the live cohort's coin lookup, a Moment or a Moment's live price
        /// couldn't be read.
        var complete = true
        /// The held coins still on a launchpad's curve; nil when the launchpads couldn't be asked.
        var curve: CurveHoldings? = CurveHoldings.none
    }

    /// Which of `read`'s tokens DyorHQ's contracts made, and their values. MON and the curated tokens are never asked. A
    /// coin whose launch, Moment or live price couldn't be read is unpriced, never valued by another pool, and the read
    /// says it is incomplete.
    private static func appCoins(_ read: Read, env: AppEnvironment) async -> AppCoins {
        let candidates = read.tokens.filter { !$0.isNative && Token.core($0.address) == nil }
        guard !candidates.isEmpty else { return AppCoins() }
        let launchpad = env.launchpad
        async let launches = try? await launchpad.heldLaunches(candidates)
        async let moments = momentCoins(candidates.map(\.address), owner: read.owner, env: env)
        let found = await launches
        let coins = await moments
        return AppCoins(launches: found ?? .none, momentPrices: coins.prices, staked: coins.staked,
                        complete: (found?.complete ?? false) && coins.complete, curve: found?.curve)
    }

    /// The Moments whose coins are among `coins`: the live cohort's, by its factory's `momentIdByCoin`, and the retired
    /// cohorts', from their fixed list (`MomentsAddresses.retiredMainnetCoins`), each cohort's in one read
    /// (`MomentsService.infos`). A Moment counts only when it names the coin it was found for and belongs to the cohort
    /// asked. `prices`: each such coin's (`WalletHoldings.momentPrice`), nil when its Moment or live price couldn't be
    /// read. `staked`: those whose Moment `owner` collected or created, from each cohort's vesting; a cohort whose stakes
    /// can't be read stakes nothing, and its coins stay as marked. `complete` is false when a lookup, a Moment or a live
    /// price couldn't be read.
    private static func momentCoins(_ coins: [Address], owner: Address, env: AppEnvironment) async -> (prices: [Address: Double?], staked: Set<Address>, complete: Bool) {
        let live = env.moments
        var complete = true
        var liveIds: [Address: BigUInt] = [:]
        do { liveIds = try await live.momentIds(coins: coins) } catch { complete = false }
        // Each cohort's coins, by id: the live one's, then each retired one's.
        var retired: [Address: [(coin: Address, id: BigUInt)]] = [:]
        for coin in coins where liveIds[coin] == nil {
            if let key = MomentsAddresses.retiredMainnetCoins[coin], env.retiredMoments(for: key.factory) != nil { retired[key.factory, default: []].append((coin, key.id)) }
        }
        let liveFactory = env.config.moments.factory
        let liveRead: [MomentInfo]? = liveIds.isEmpty ? [] : try? await live.infos(ids: Array(liveIds.values))
        var infos: [MomentInfo] = liveRead ?? []
        if liveRead == nil { complete = false }
        for (factory, keys) in retired {
            guard let cohort = env.retiredMoments(for: factory) else { continue }
            if let read = try? await cohort.infos(ids: keys.map(\.id)) { infos += read } else { complete = false }
        }
        var moments: [Address: MomentInfo] = [:]
        for info in infos {
            let expected = liveIds[info.moment.coin] != nil ? liveFactory : MomentsAddresses.retiredMainnetCoins[info.moment.coin]?.factory
            if info.moment.factory == expected { moments[info.moment.coin] = info }
        }
        var prices: [Address: Double?] = [:]
        for coin in Array(liveIds.keys) + retired.values.flatMap({ $0.map(\.coin) }) {
            guard let info = moments[coin] else { prices[coin] = .some(nil); complete = false; continue }
            let price = WalletHoldings.momentPrice(info)
            // A pool whose live price wasn't read: unpriced, and said.
            if price == nil, info.pool != nil { complete = false }
            prices[coin] = .some(price)
        }
        guard !moments.isEmpty else { return (prices, [], complete) }
        // Each cohort's portfolio rows, in one read per cohort: the account's collects, plus a creator's allocation.
        var rows: [MomentPortfolioRow] = []
        let found = Array(moments.values)
        let liveInfos = found.filter { $0.moment.factory == liveFactory }
        if !liveInfos.isEmpty, let portfolio = try? await live.portfolio(account: owner, moments: liveInfos) { rows += portfolio.rows }
        for cohort in env.retiredMoments {
            let own = found.filter { $0.moment.factory == cohort.factory }
            if !own.isEmpty, let read = try? await cohort.positions(account: owner, moments: own) { rows += read.positions.map(\.row) }
        }
        let staked = Set(rows.filter { $0.isCreator || $0.entitlement > 0 }.map(\.moment.moment.coin)).intersection(moments.keys)
        return (prices, staked, complete)
    }
}
