import Foundation
import Observation
import StellarKit

/// Everything the Stellar screens read, and every action they take (docs/DESIGN-stellar-parity.md §7.2). Made by
/// `LiteSession` once the account's address is known, and kept with it across network switches, so a return to Stellar
/// shows the last figures at once.
///
/// Reads never prompt and never need a session: the account, its holdings, Earn and the boards are viewer reads, with
/// the session's token when one is held and the account's public view otherwise. DyorHQ's own history (Portfolio,
/// Activity, My Launchpad, My Moments) needs a session: a seed account gets one silently first; a passkey account with
/// none reports `.needsSignIn` for that part and asks nothing. An action is built once a session is held (a passkey
/// account in the public view signs in once, since the user started it), priced and verified on the phone, and run with
/// one signing run (`run(_:reason:onEvent:)`).
@MainActor
@Observable
public final class LiteStore {
    public let env: LiteEnvironment
    /// The account's Stellar address (G…).
    public let address: String
    public let monad: LiteMonadBridge?
    let backend: LiteBackend
    /// The session that made it: the signing runs, the sign-in an action may need, and where a paused service is said.
    @ObservationIgnored weak var session: LiteSession?

    // MARK: - Reads (nil or empty until read; `parts` says how each part's last read went)

    public internal(set) var config: LiteConfig?
    public private(set) var account: AccountView?
    public private(set) var fees: StellarFees?
    public private(set) var holdings: StellarHoldings?
    /// Blend's markets, for Earn (public).
    public private(set) var earnMarkets: [EarnMarket] = []
    /// The last Activity read (`refreshActivity(section:kind:period:)`).
    public private(set) var activity: [StellarActivityItem] = []
    /// Portfolio, by the periods read.
    public private(set) var portfolio: [VolumePeriodKey: StellarPortfolio] = [:]
    public private(set) var parts: [LitePart: LiteReadStatus] = [:]
    /// The last read's failure, in the current language; nil once a whole round goes through.
    public internal(set) var lastError: String?
    /// When the balances were last read.
    public private(set) var updatedAt: Date?

    // MARK: - Today's screens' reads (LiteLegacyScreens; they go with those screens, WP-50)

    public private(set) var prices: StellarPrices?
    public private(set) var positions: [EarnPosition] = []
    public private(set) var launches: [StellarLaunch] = []
    public private(set) var moments: [StellarMoment] = []
    public private(set) var owned: [StellarEdition] = []

    /// Today's screens' parts: read at least once, and failed at the last read.
    enum Part: Hashable { case account, activity, earn, launches, moments }
    private(set) var loaded: Set<Part> = []
    private(set) var failed: Set<Part> = []

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Each launch's quote asset (its contract), from every launch read: what a curve trade spends.
    @ObservationIgnored private var launchQuotes: [String: String] = [:]
    @ObservationIgnored private var launchSymbols: [String: String] = [:]
    /// The plans run now, and the plans settled: a plan settles once.
    @ObservationIgnored private var runs: [String: Task<[TxStatus], Error>] = [:]
    @ObservationIgnored private var settled: Set<String> = []
    /// A Monad → Stellar transfer the review priced, which `bridgeIn` sends while it is fresh.
    @ObservationIgnored private var pendingBridgeIn: (amount6: Int64, start: BridgeStart, at: Date)?

    init(env: LiteEnvironment, backend: LiteBackend, address: String, monad: LiteMonadBridge?, config: LiteConfig?) {
        self.env = env
        self.backend = backend
        self.address = address
        self.monad = monad
        self.config = config
    }

    var api: LiteAPI { backend.api }
    var network: StellarNetwork { env.pinned.network }
    var isTestnet: Bool { network != .mainnet }

    /// How `part`'s last read went.
    public func status(_ part: LitePart) -> LiteReadStatus { parts[part] ?? .unread }

    // MARK: - Reads

    /// Reads everything again. A call while a refresh is under way waits for that one rather than starting another (a
    /// run that ends as Stellar Home appears asks twice).
    public func refreshAll() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// Reads everything again, in place: what was read stays on screen until a new read replaces it, and the header's
    /// warning goes only once a whole round has gone through (a poll never makes it blink).
    private func readAll() async {
        async let c: Void = refreshConfig()
        async let f: Void = refreshFees()
        async let a: Void = refreshAccount()
        async let h: Void = refreshHoldings()
        async let e: Void = refreshEarn()
        async let t: Void = refreshActivity()
        async let p: Void = refreshPortfolios()
        async let l: Void = refreshLaunches(sort: "new")
        async let m: Void = refreshMoments()
        _ = await (c, f, a, h, e, t, p, l, m)
        if failed.isEmpty, !parts.values.contains(.failed) { lastError = nil }
    }

    func refreshConfig() async {
        guard let config = try? await api.config() else { return }
        self.config = config
        session?.read(config: config)
    }

    /// The network fees (public): every step kind's estimate and the base reserve.
    public func refreshFees() async {
        guard let fees = try? await api.fees() else { return }
        adopt(fees: fees)
    }

    /// The account and its XLM position (a viewer read).
    public func refreshAccount() async {
        do {
            adopt(account: try await api.account())
            updatedAt = Date()
        } catch {
            failed.insert(.account)
            report(error)
        }
        // Today's screens value the balances at these.
        if let prices = try? await api.prices() { self.prices = prices }
    }

    /// Home's balance card, My Holdings and the allocation (a viewer read): each of its four parts says whether the
    /// server could read it.
    public func refreshHoldings() async {
        let holdingParts: [LitePart] = [.spot, .earn, .launch, .moments]
        do {
            let holdings = try await api.holdings()
            self.holdings = holdings
            for part in holdingParts { parts[part] = holdings.parts[part.rawValue] == "failed" ? .failed : .read }
            for launch in holdings.launch { launchSymbols[launch.token] = launch.symbol }
            updatedAt = Date()
        } catch {
            for part in holdingParts { parts[part] = .failed }
            report(error)
        }
    }

    /// Blend's markets (public) and the account's positions (a viewer read).
    public func refreshEarn() async {
        do {
            earnMarkets = try await api.earnMarkets()
            positions = try await api.earnPositions()
            loaded.insert(.earn)
            failed.remove(.earn)
        } catch {
            failed.insert(.earn)
            report(error)
        }
    }

    /// The account's activity (DyorHQ's history), every filter optional.
    public func refreshActivity(section: String? = nil, kind: String? = nil, period: VolumePeriodKey? = nil) async {
        do {
            activity = try await history(.activity) { try await self.api.activity(section: section, kind: kind, period: period) }
            loaded.insert(.activity)
            failed.remove(.activity)
        } catch {
            if status(.activity) == .failed { failed.insert(.activity) }
        }
    }

    /// The account's activity for one screen's own list (Swap History's swaps over a range), read as `refreshActivity`
    /// reads it but kept out of `activity` and its status, so what another screen lists stays that screen's read.
    /// `.needsSignIn`: a passkey account with no session, and nothing asks; `.failed`: `lastError` says why.
    public func readActivity(section: String? = nil, kind: String? = nil, period: VolumePeriodKey? = nil) async
        -> (items: [StellarActivityItem], status: LiteReadStatus) {
        do {
            return (try await history(nil) { try await self.api.activity(section: section, kind: kind, period: period) }, .read)
        } catch LiteAPIError.notSignedIn where session?.needsSignIn == true {
            return ([], .needsSignIn)
        } catch {
            return ([], .failed)
        }
    }

    /// Portfolio over `period` (DyorHQ's history).
    public func refreshPortfolio(_ period: VolumePeriodKey) async {
        guard let portfolio = try? await history(.portfolio, { try await self.api.portfolio(period: period) }) else { return }
        self.portfolio[period] = portfolio
    }

    /// The periods already read, again (after an action settles, and with every refresh).
    private func refreshPortfolios() async {
        for period in VolumePeriodKey.allCases where portfolio[period] != nil { await refreshPortfolio(period) }
    }

    /// Today's launch list (a viewer read).
    public func refreshLaunches(sort: String) async {
        do {
            launches = try await api.launches(sort: sort)
            learn(launches)
            loaded.insert(.launches)
            failed.remove(.launches)
        } catch {
            failed.insert(.launches)
            report(error)
        }
    }

    /// Today's Moments board and the account's editions (viewer reads).
    public func refreshMoments() async {
        do {
            moments = try await api.moments()
            owned = try await api.ownedEditions()
            loaded.insert(.moments)
            failed.remove(.moments)
        } catch {
            failed.insert(.moments)
            report(error)
        }
    }

    /// A page of the launch board (a viewer read): `section` "explore" or "graduated", `sort` "newest", "market_cap"
    /// or "near_graduation".
    public func launchBoard(section: String, sort: String, query: String? = nil, cursor: String? = nil) async throws -> StellarLaunchBoard {
        let board = try await api.launchBoard(section: section, sort: sort, query: query, cursor: cursor)
        learn(board.launches)
        return board
    }

    /// A launch page (a viewer read).
    public func launchDetail(_ token: String) async throws -> StellarLaunchDetail {
        let detail = try await api.launch(token)
        learn([detail.launch])
        return detail
    }

    /// The launchpad's and the Moments contract's terms, read live from the contracts (public).
    public func economics() async throws -> StellarEconomics { try await api.economics() }

    /// My Launchpad (DyorHQ's history).
    public func myLaunchpad() async throws -> StellarMyLaunchpad {
        let mine = try await history(.myLaunchpad) { try await self.api.myLaunchpad() }
        learn(mine.held.map(\.launch) + mine.created.map(\.launch))
        return mine
    }

    /// The Moments board: `filter` "all", "collecting" or "closed" (a viewer read).
    public func moments(filter: String) async throws -> [StellarMoment] { try await api.moments(filter: filter) }

    /// A Moment page (a viewer read).
    public func momentDetail(_ id: Int) async throws -> StellarMomentDetail { try await api.moment(id) }

    /// My Moments (DyorHQ's history).
    public func myMoments() async throws -> StellarMomentsMine {
        try await history(.myMoments) { try await self.api.myMoments() }
    }

    /// My Moments of contracts v2 (DyorHQ's history), the same part as v1's.
    public func myMomentsV2() async throws -> StellarMyMomentsV2 {
        try await history(.myMoments) { try await self.api.myMomentsV2() }
    }

    /// An Earn market's supply rate and utilization over `range` (`.week` or `.month`; public).
    public func earnHistory(pool: String, asset: String, range: VolumePeriodKey) async throws -> StellarEarnHistory {
        try await api.earnHistory(pool: pool, asset: asset, range: range)
    }

    /// Search by code or name, or exactly by a C… id or `CODE:G…` (a viewer read).
    public func searchAssets(_ query: String) async throws -> [StellarAssetResult] { try await api.searchAssets(query) }

    /// Whether `address` can receive `asset`, before a send is reviewed.
    public func recipient(_ address: String, asset: String) async throws -> StellarRecipient {
        try await ensureSession()
        return try await api.recipient(address, asset: asset)
    }

    func adopt(account: AccountView) {
        self.account = account
        for row in account.balances where row.kind == "launch" { launchSymbols[row.contract] = row.code }
        loaded.insert(.account)
        failed.remove(.account)
    }

    func adopt(fees: StellarFees) {
        self.fees = fees
    }

    /// A read of DyorHQ's history (a session route). With no session a seed account signs in silently first; a passkey
    /// account that can't renew by itself reports `.needsSignIn` for `part`, and nothing asks. A read for one screen's own
    /// list names no part: `parts` stays as the shared reads left it.
    private func history<T>(_ part: LitePart?, _ read: () async throws -> T) async throws -> T {
        func mark(_ status: LiteReadStatus) {
            if let part { parts[part] = status }
        }
        if let session, session.access == .publicView {
            if session.needsSignIn {
                mark(.needsSignIn)
                throw LiteAPIError.notSignedIn
            }
            try? await session.renew()
        }
        do {
            let value = try await read()
            mark(.read)
            return value
        } catch LiteAPIError.notSignedIn where session?.needsSignIn == true {
            mark(.needsSignIn)
            throw LiteAPIError.notSignedIn
        } catch {
            mark(.failed)
            report(error)
            throw error
        }
    }

    /// A read that failed: said in the header, and access turned off told to the session (the paused card).
    func report(_ error: Error) {
        lastError = LiteErrorText.describe(error)
        if let api = error as? LiteAPIError, api.code == "access_revoked" { session?.lostAccess() }
    }

    private func learn(_ launches: [StellarLaunch]) {
        for launch in launches {
            launchQuotes[launch.token] = launch.quote
            launchSymbols[launch.token] = launch.symbol
        }
    }

    /// The total in USD at reference prices (testnet assets have no value: the screen says so). Nil until the balances
    /// and the prices are read. Today's Home only: the new one reads `holdings`.
    public var totalValue: Double? {
        guard let account, let prices else { return nil }
        return account.balances.reduce(0) { sum, row in
            sum + Double(row.units) / 1e7 * (prices.usd[row.asset] ?? prices.usd[row.contract] ?? 0)
        } + positions.reduce(0) { sum, p in
            sum + (Double(p.supplied) ?? 0) / 1e7 * (prices.usd[p.code == "XLM" ? "XLM" : "USDC"] ?? 0)
        }
    }

    /// A balance's value in USD at reference prices, when there is a price.
    func value(of row: BalanceRow) -> Double? {
        guard let px = prices?.usd[row.asset] ?? prices?.usd[row.contract], px > 0 else { return nil }
        return Double(row.units) / 1e7 * px
    }

    public func asset(_ id: String) -> AssetInfo? { config?.asset(id) }

    // MARK: - Max

    /// The most of `asset` an action of `stepKind` can spend (base units): for XLM what it can send and still pay the
    /// step's fee (its estimate, kept with a quarter more) and hold the `newReserves` it adds, from the account's own
    /// figures (`XLMReserve.maxSend`, §4.5); for any other asset, the whole balance (its fee is checked at review).
    public func maxAmount(asset: String, stepKind: String, newReserves: Int = 0) -> Int64 {
        guard isXLM(asset) else { return balance(asset) }
        guard let position = account?.xlm ?? holdings?.xlm, let reserve = XLMReserve(position) else { return 0 }
        let fee = fees?.estimate(stepKind) ?? StellarFeeDefaults.estimate(stepKind) ?? env.pinned.feePolicy.maxFee
        return reserve.maxSend(feeEstimate: fee, newReserves: newReserves)
    }

    /// Whether `id` (a registry id or a contract) is XLM.
    func isXLM(_ id: String) -> Bool {
        id == "XLM" || id == "native" || (config?.asset("XLM")?.contract).map { $0 == id } == true
    }

    /// The account's balance of `id` (a registry id or a contract), in base units.
    func balance(_ id: String) -> Int64 {
        if let row = account?.balances.first(where: { $0.asset == id || $0.contract == id }) { return row.units }
        if let row = holdings?.spot.first(where: { $0.id == id || $0.contract == id }) { return row.units }
        if let row = holdings?.launch.first(where: { $0.token == id }) { return Int64(row.balance) ?? 0 }
        return 0
    }

    // MARK: - Actions → prepared plans

    /// A swap's price across Stellar's venues. A quote needs a session (a passkey account in the public view signs in
    /// once: the user typed an amount to swap).
    public func swapQuote(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        try await ensureSession()
        return try await api.quoteSwap(sell: sell, buy: buy, amount: amount, slippageBps: slippageBps)
    }

    /// The swap `quote` prices, through `venue` (one of its routes; nil for the best).
    public func swapPlan(_ quote: SwapQuote, venue: String? = nil) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.buildSwap(quoteId: quote.quoteId, venue: venue)
        let sell = code(quote.sell)
        let buy = code(quote.buy)
        let route = venue.flatMap { v in quote.routes?.first { $0.venue == v } }
        let out = route?.amountOut ?? quote.best.amountOut
        let least = try Self.swapMinimum(quoted: out, minOut: route?.minOut ?? quote.best.minOut, slippageBps: quote.slippageBps)
        // The asset the user chose to buy, pinned on the phone: the verifiers let the bought token off the route
        // allowlist because the intent names it, so the run must hold the intent to this one.
        let bought = contract(quote.buy)
        guard bought != PlanBindings.anyAsset else { throw PlanRunner.Failure.refused(step: tr("Swap"), reason: "the asset you buy can't be checked") }
        let main = LiteTitles.intent(kind: "swap", display: ["amountIn": .string(quote.amountIn), "sell": .string(sell), "buy": .string(buy)])
        return try prepare(plan, limits: limit(quote.sell, quote.amountIn), bindings: PlanBindings(minimums: [bought: least]), title: tr("Swap"),
                           titles: Self.unbuilt(plan, main: main, before: LiteTitles.intent(kind: "trust", display: ["asset": .string(buy)])),
                           section: isLaunchToken(quote.sell) || isLaunchToken(quote.buy) ? .launch : .spot, reference: "stellar:swap",
                           summary: .swap(amountIn: Int64(quote.amountIn) ?? 0, sell: sell, buy: buy, quotedOut: Int64(out) ?? 0))
    }

    /// A send to `to` (G… or C…), with the memo the recipient gave (`memoType` "text", "id" or "hash").
    public func sendPlan(asset: String, to: String, amount: Int64, memo: String?, memoType: String? = nil) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.send(asset: asset, to: to, amount: amount, memo: memo, memoType: memoType)
        let typed = PlanBindings(destination: .confirmed(to: to, memo: Self.boundMemo(memo, type: memoType)))
        return try prepare(plan, limits: limit(asset, String(amount)), bindings: typed, title: tr("Send"), section: .spot, reference: "stellar:home",
                           summary: .send(amount: amount, code: code(asset), to: to))
    }

    /// Enables `asset` (a trustline): it holds one base reserve of the user's own XLM while enabled.
    public func enablePlan(asset: String) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.enable(asset: asset)
        let code = code(asset)
        return try prepare(plan, limits: [:], title: tr("Enable \(code)"), section: .account, reference: "stellar:home", summary: .enable(code: code))
    }

    /// A deposit to an Earn market, or a withdrawal from it.
    public func earnPlan(deposit: Bool, market: EarnMarket, amount: Int64) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.buildEarn(deposit: deposit, pool: market.pool, asset: market.asset, amount: amount)
        let main = LiteTitles.intent(kind: deposit ? "earn_deposit" : "earn_withdraw", display: ["amount": .string(String(amount)), "asset": .string(market.code)])
        // A withdrawal receives what the user asked for, at least.
        return try prepare(plan, limits: deposit ? [market.asset: amount] : [:],
                           bindings: deposit ? .none : PlanBindings(minimums: [market.asset: amount]), title: deposit ? tr("Deposit") : tr("Withdraw"),
                           titles: Self.unbuilt(plan, main: main, before: LiteTitles.intent(kind: "trust", display: ["asset": .string(market.code)])),
                           section: .earn, reference: "stellar:earn/\(market.id)", summary: .earn(deposit: deposit, amount: amount, code: market.code))
    }

    /// A curve trade's price: `amount` of the quote asset to buy with, or of coins to sell.
    public func launchQuote(token: String, buy: Bool, amount: Int64) async throws -> StellarLaunchQuote {
        try await ensureSession()
        return StellarLaunchQuote(buy: buy, amount: amount, quote: try await api.quoteTrade(token: token, buy: buy, amount: amount))
    }

    /// A curve buy (spending `amount` of the coin's quote asset) or sell (`amount` coins), bringing at least `minOut`.
    public func launchTradePlan(token: String, buy: Bool, amount: Int64, minOut: Int64) async throws -> PreparedAction {
        try await ensureSession()
        var request = LiteAPI.LaunchRequest(action: buy ? "buy" : "sell", token: token)
        request.amount = String(amount)
        request.minOut = String(minOut)
        let quote = try await quoteAsset(of: token)
        let plan = try await api.buildLaunch(request)
        return try prepare(plan, limits: [buy ? quote : token: amount], bindings: PlanBindings(minimums: [buy ? token : quote: minOut]),
                           title: buy ? tr("Buy") : tr("Sell"), section: .launch,
                           reference: "stellar:launch/\(token)",
                           summary: .launchTrade(buy: buy, symbol: code(token), amount: amount, quoteCode: code(quote)))
    }

    /// A new coin: its image uploaded and its metadata written first, then the launch (with the developer buy). The
    /// ticker is checked as typed: one that isn't 2 to 10 ASCII letters or digits is refused before anything is sent,
    /// as the server refuses it (422 `bad_symbol`); the rest go out upper-cased.
    public func launchCreatePlan(_ form: StellarLaunchForm, image: Data?) async throws -> PreparedAction {
        guard let symbol = Self.launchSymbol(form.symbol) else {
            throw LiteAPIError.server(status: 422, code: "bad_symbol", message: tr("Use 2 to 10 letters or digits for the symbol."), detail: nil)
        }
        try await ensureSession()
        let imageUrl = try await image.asyncMap { try await upload($0, contentType: "image/jpeg") }
        let uri = try await api.launchMetadata(name: form.name, symbol: symbol, description: form.description, imageUrl: imageUrl,
                                               website: form.website, x: form.x, telegram: form.telegram)
        var request = LiteAPI.LaunchRequest(action: "create", quote: form.quote, name: form.name, symbol: symbol, uri: uri,
                                            creatorFeeBps: form.creatorFeeBps)
        request.amount = String(form.developerBuy)
        request.minOut = String(form.minOut)
        let plan = try await api.buildLaunch(request)
        let quote = asset(form.quote)?.contract ?? form.quote
        return try prepare(plan, limits: form.developerBuy > 0 ? [quote: form.developerBuy] : [:],
                           bindings: form.developerBuy > 0 ? PlanBindings(minimums: [PlanBindings.anyAsset: form.minOut]) : .none, title: tr("Launch a coin"),
                           section: .launch, reference: nil, summary: .launchCreate(symbol: symbol, name: form.name))
    }

    /// Whether `symbol` can be a coin's ticker: 2 to 10 ASCII letters or digits as typed, spaces around it aside, the
    /// server's rule (Soroswap reads a token's symbol as UTF-8, so a coin with any other could never graduate). Create
    /// checks it before it sends anything.
    public nonisolated static func isLaunchSymbol(_ symbol: String) -> Bool {
        let scalars = symbol.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        return (2...10).contains(scalars.count) && scalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The ticker Create sends for what the user typed: trimmed and upper-cased once it passes `isLaunchSymbol`, nil
    /// otherwise. Checked before upper-casing, which turns letters outside ASCII into ASCII ones ("ß" into "SS").
    public nonisolated static func launchSymbol(_ typed: String) -> String? {
        isLaunchSymbol(typed) ? typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : nil
    }

    /// Moves a coin whose curve is full to its Soroswap pool (anyone may; the user pays only the network fee).
    public func graduatePlan(token: String) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.buildLaunch(LiteAPI.LaunchRequest(action: "graduate", token: token))
        return try prepare(plan, limits: [:], title: tr("Graduate"), section: .launch, reference: "stellar:launch/\(token)",
                           summary: .launchGraduate(symbol: code(token)))
    }

    /// The creator's fees of each coin, one plan per coin, in order.
    public func claimPlan(tokens: [String]) async throws -> [PreparedAction] {
        try await ensureSession()
        var actions: [PreparedAction] = []
        for token in tokens {
            let plan = try await api.buildLaunch(LiteAPI.LaunchRequest(action: "claim", token: token))
            actions.append(try prepare(plan, limits: [:], title: tr("Claim"), section: .launch, reference: "stellar:launch/\(token)",
                                       summary: .launchClaim(symbol: code(token))))
        }
        return actions
    }

    /// A new Moment: its media (and a video's cover frame) uploaded and its metadata written first, then the publish.
    public func publishPlan(_ form: StellarMomentForm, media: StellarMedia) async throws -> PreparedAction {
        try await ensureSession()
        let mediaUrl = try await upload(media.data, contentType: media.contentType)
        var posterUrl: String?
        if media.isVideo {
            // The cover frame is the NFT's image (§6.9): a video doesn't go out without one.
            guard let poster = media.poster else { throw LiteAPIError.server(status: 400, code: "bad_media", message: tr("A video needs its cover frame.")) }
            posterUrl = try await upload(poster, contentType: "image/jpeg")
        }
        let metadata = try await api.momentMetadata(title: form.title, description: form.description, mediaUrl: mediaUrl,
                                                    mediaType: media.isVideo ? "video" : "image", posterUrl: posterUrl, place: form.place,
                                                    takenOn: form.takenOn)
        let plan = try await api.buildPublishMoment(uri: metadata.uri, price: form.price, quote: form.quote, maxEditions: form.maxEditions,
                                                    windowSecs: form.windowSecs)
        return try prepare(plan, limits: [:], title: tr("Publish"), section: .moments, reference: nil, summary: .publish(title: form.title))
    }

    /// `quantity` editions of `moment`, at its price.
    public func collectPlan(moment: StellarMoment, quantity: Int) async throws -> PreparedAction {
        try await ensureSession()
        let plan = try await api.buildCollect(momentId: moment.id, quantity: quantity)
        let total = (Int64(moment.price) ?? 0) * Int64(quantity)
        return try prepare(plan, limits: [moment.quote: total], title: tr("Collect"), section: .moments, reference: "stellar:moment/\(moment.id)",
                           summary: .collect(title: moment.title ?? tr("Moment #\(moment.id)"), quantity: quantity, total: total,
                                             quoteCode: moment.quoteCode ?? code(moment.quote)))
    }

    /// Stellar → Monad: the transfer the server opens and the plan that burns `amount` USDC (7 decimals) on Stellar.
    public func bridgeOutPlan(amount: Int64, monadAddress: String) async throws -> (PreparedAction, BridgeTransfer) {
        try await ensureSession()
        let start = try await api.bridgeStart(toStellar: false, amount: String(amount), monadAddress: monadAddress)
        guard let plan = start.plan else { throw LiteAPIError.decoding("the bridge plan") }
        let send = LiteTitles.intent(kind: "bridge_out", display: ["amount": .string(String(amount))])
        let action = try prepare(plan, limits: limit("USDC", String(amount)), bindings: PlanBindings(destination: .confirmed(to: monadAddress, memo: nil)),
                                 title: tr("Send to Monad"), titles: Self.unbuilt(plan, main: send, before: nil),
                                 section: .bridge, reference: "stellar:bridge/\(start.transfer.id)", summary: .bridgeOut(amount: amount))
        return (action, start.transfer)
    }

    /// Monad → Stellar, before the review: the transfer the server opens and the Monad steps that send it (approve,
    /// burn). `bridgeIn` sends these same steps while they are fresh.
    public func bridgeInStart(amount6: Int64) async throws -> BridgeStart {
        if let pending = pendingBridgeIn, pending.amount6 == amount6, Date().timeIntervalSince(pending.at) < 5 * 60 { return pending.start }
        guard let monad else { throw LiteAPIError.server(status: 400, code: "no_monad", message: tr("Move funds from Monad inside DyorHQ.")) }
        try await ensureSession()
        let start = try await api.bridgeStart(toStellar: true, amount: String(amount6), monadAddress: monad.monadAddress)
        pendingBridgeIn = (amount6, start, Date())
        return start
    }

    /// The Monad network fee of a Monad → Stellar transfer of `amount6` (6 decimals), for the review; nil when the
    /// host can't price it.
    public func bridgePreview(amount6: Int64) async throws -> LiteMonadFeePreview? {
        let start = try await bridgeInStart(amount6: amount6)
        return try await monad?.preview(start.evmSteps ?? [])
    }

    /// Monad → Stellar: the host's Monad wallet signs and sends the steps, then the server follows the transfer.
    public func bridgeIn(amount6: Int64) async throws -> BridgeTransfer {
        guard let monad else { throw LiteAPIError.server(status: 400, code: "no_monad", message: tr("Move funds from Monad inside DyorHQ.")) }
        let start = try await bridgeInStart(amount6: amount6)
        pendingBridgeIn = nil
        let hash = try await monad.send(start.evmSteps ?? [])
        _ = try await api.bridgeSource(id: start.transfer.id, txHash: hash)
        return start.transfer
    }

    public func bridgeSourceReported(id: String, hash: String) async throws { _ = try await api.bridgeSource(id: id, txHash: hash) }
    public func bridgeStatus(id: String) async throws -> BridgeStatus { try await api.bridgeStatus(id: id) }

    /// Claims a Stellar → Monad transfer on Monad, with the host's Monad wallet, once Circle has attested it.
    public func claimOnMonad(_ status: BridgeStatus) async throws {
        guard let monad, let claim = status.claim else { return }
        let hash = try await monad.send([claim])
        _ = try await api.bridgeClaimed(id: status.id, txHash: hash)
    }

    /// Testnet's Friendbot: its test XLM for an account that already existed, once per address, ever (the server
    /// refuses a second claim with 429 `faucet_used`). The account is read again whatever the answer, so
    /// `firstFunding.faucet.claimed` says what the server now holds: done after the claim, and after a refusal for a
    /// claim made before or one the server is still settling.
    public func faucet() async throws {
        try await ensureSession()
        do {
            _ = try await api.faucet()
        } catch {
            await refreshAccount()
            throw error
        }
        await refreshAccount()
    }

    /// Whether the account may still claim Friendbot's test XLM: testnet, the account read, and its claim not made.
    /// False while unknown: the offer shows only once the server says it is open.
    public var canClaimFriendbot: Bool {
        isTestnet && account?.firstFunding?.faucet?.claimed == false
    }

    /// Uploads a photo, a video or a cover frame to DyorHQ's media storage; its URL.
    func upload(_ data: Data, contentType: String) async throws -> String {
        let ticket = try await api.uploadTicket(contentType: contentType, bytes: data.count)
        try await api.upload(data, contentType: contentType, to: ticket)
        return ticket.publicUrl
    }

    /// Before an action is built: a session (`LiteSession.ensureSession`).
    func ensureSession() async throws {
        guard let session else { throw LiteAPIError.notSignedIn }
        try await session.ensureSession()
    }

    /// The plan, priced on the phone: a step above the pinned caps throws here, so the review never shows a fee the
    /// run would refuse. `bindings`: what the user's form computed and typed besides the spends (the minimums, the
    /// destination and memo); a step already built that names other ones throws here too, and the run holds every step
    /// to them (`PlanRunner.run`).
    func prepare(_ plan: PlanView, limits: [String: Int64], bindings: PlanBindings = .none, title: String, titles: [String: String] = [:],
                 section: LiteSection, reference: String?, summary: LiteActionSummary) throws -> PreparedAction {
        try Self.checkBuilt(plan, bindings: bindings, user: address, pinned: env.pinned)
        let fees = try PlanFees(plan: plan, pinned: env.pinned, estimates: fees)
        let spends = limits.keys.sorted().map { isXLM($0) ? "XLM" : code($0) }
        return PreparedAction(plan: plan, limits: limits, bindings: bindings, title: title, titles: titles, section: section, reference: reference,
                              fees: fees, summary: summary, spends: spends)
    }

    /// The steps the server built already, against `bindings`, in plan order: the review never shows a minimum, a
    /// destination or a memo the run would refuse. A step not built yet is checked when the run builds it.
    nonisolated static func checkBuilt(_ plan: PlanView, bindings: PlanBindings, user: String, pinned: PinnedContracts) throws {
        var check = PlanBindings.Check(bindings, user: user, pinned: pinned)
        for (index, step) in plan.steps.enumerated() {
            guard let intent = step.intent else { continue }
            do {
                try check.step(intent, spends: intent.spend.values.contains { (Int64($0) ?? 1) != 0 }, last: index == plan.steps.count - 1)
            } catch PlanBindings.Refusal.minimum {
                throw PlanRunner.Failure.minimumNotConfirmed(step: step.label)
            } catch PlanBindings.Refusal.destination {
                throw PlanRunner.Failure.destinationNotConfirmed(step: step.label)
            } catch PlanBindings.Refusal.settings {
                throw PlanRunner.Failure.settingsNotConfirmed(step: step.label)
            }
        }
    }

    /// A swap's minimum as the screen showed it: the route's own (`minOut`), never less than the quoted amount less the
    /// quote's slippage, and never nothing.
    nonisolated static func swapMinimum(quoted: String, minOut: String?, slippageBps: Int) throws -> Int64 {
        let out = Int64(quoted) ?? 0
        let bps = Int64(min(max(slippageBps, 0), 10_000))
        let product = out.multipliedFullWidth(by: 10_000 - bps)
        let floor = out > 0 && product.high < 10_000 ? Int64(10_000).dividingFullWidth(product).quotient : 0
        let least = max(minOut.flatMap { Int64($0) } ?? 0, floor)
        guard least > 0 else { throw PlanRunner.Failure.minimumNotConfirmed(step: tr("Swap")) }
        return least
    }

    /// The memo the user typed, as the server binds it in a send's intent (account.ts `memoOf`): an id as its number, a
    /// hash as 64 lowercase hex characters (from hex or base64), text as typed; nil without one.
    nonisolated static func boundMemo(_ value: String?, type: String?) -> Intent.Memo? {
        guard let value, !value.isEmpty else { return nil }
        switch type ?? "text" {
        case "id":
            return Intent.Memo(type: "id", value: UInt64(value).map(String.init) ?? value)
        case "hash":
            let isHex = value.count == 64 && value.allSatisfy(\.isHexDigit)
            if isHex { return Intent.Memo(type: "hash", value: value.lowercased()) }
            guard let bytes = Data(base64Encoded: value), bytes.count == 32 else { return Intent.Memo(type: "hash", value: value) }
            return Intent.Memo(type: "hash", value: bytes.map { String(format: "%02x", $0) }.joined())
        default:
            return Intent.Memo(type: type ?? "text", value: value)
        }
    }

    /// The key a step's `intent.receive` names an asset by, worked out on the phone rather than taken from the server's
    /// config: a registry asset ("XLM", "USDC") by its contract when the build pins it (the `token` role), else by the
    /// asset contract of its classic asset (native, or CODE:ISSUER); a C… as given; a CODE:ISSUER by its asset contract.
    /// `PlanBindings.anyAsset` when none of these applies, which a swap refuses (`swapPlan`).
    func contract(_ asset: String) -> String {
        if let info = config?.asset(asset) {
            if env.pinned.contracts("token").contains(info.contract) { return info.contract }
            if let classic = info.classic { return Self.assetContract(classic, network: env.pinned.network) ?? PlanBindings.anyAsset }
            return PlanBindings.anyAsset
        }
        if StrKey.isValid(.contract, asset) { return asset }
        return Self.assetContract(asset, network: env.pinned.network) ?? PlanBindings.anyAsset
    }

    /// A classic asset's contract ("native", or CODE:ISSUER), as Stellar derives it; nil for anything else.
    public nonisolated static func assetContract(_ classic: String, network: StellarNetwork) -> String? {
        if classic == "native" { return AssetContract.id(.native, network: network) }
        let parts = classic.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, (1...12).contains(parts[0].count), StrKey.isValid(.accountID, parts[1]) else { return nil }
        return AssetContract.id(.credit(code: parts[0], issuer: parts[1]), network: network)
    }

    // MARK: - Running

    /// Verifies, signs and sends every step of `action`, within the limits and fees the user confirmed. One signing run
    /// for the whole action (`reason` is its prompt, in the current language): App Lock once when it applies, or the
    /// passkey once per step, named by the step's title. It runs in the store's own task, so it goes on, and the plan
    /// settles once (`LiteSession.onSettled`), even if the sheet that started it closes; a second call for the same
    /// plan waits for the first.
    @discardableResult
    public func run(_ action: PreparedAction, reason: String, onEvent: @escaping @Sendable (PlanRunner.Event) -> Void = { _ in }) async throws -> [TxStatus] {
        if let running = runs[action.id] { return try await running.value }
        let task = Task { try await self.execute(action, reason: reason, onEvent: onEvent) }
        runs[action.id] = task
        defer { runs[action.id] = nil }
        return try await task.value
    }

    private func execute(_ action: PreparedAction, reason: String, onEvent: @escaping @Sendable (PlanRunner.Event) -> Void) async throws -> [TxStatus] {
        guard let session else { throw LiteAPIError.notSignedIn }
        // A step not built yet is built during the run, which needs a session.
        try await ensureSession()
        let signing = try await session.beginSigning(reason: reason)
        defer { signing.end() }
        let step = StepTitle()
        let results = try await backend.run(action.plan, user: address, limits: action.limits, bindings: action.bindings, fees: action.fees,
                                            signer: { try await signing.signer(reason: step.title ?? action.title) },
                                            onEvent: { event in
                                                if case let .signing(id, label) = event {
                                                    step.title = action.plan.steps.first { $0.id == id }.map(action.title(of:)) ?? label
                                                }
                                                onEvent(event)
                                            })
        settle(action, results: results)
        return results
    }

    /// A plan went through: said once (`LiteSession.onSettled`), then the figures it changed are read again.
    private func settle(_ action: PreparedAction, results: [TxStatus]) {
        guard settled.insert(action.id).inserted else { return }
        let words = LiteTitles.settled(action.summary, results: results)
        let settledAction = LiteSettledAction(planId: action.id, kind: action.summary.kind, title: words.title, body: words.body,
                                              section: action.section, reference: action.reference ?? Self.reference(action.summary, results: results),
                                              hashes: results.map(\.hash), at: Date())
        session?.onSettled?(settledAction)
        Task { await refreshAfterSettle() }
    }

    /// After any settled action: the account, the holdings, Earn and Portfolio (§8.2.7).
    private func refreshAfterSettle() async {
        async let a: Void = refreshAccount()
        async let h: Void = refreshHoldings()
        async let e: Void = refreshEarn()
        async let p: Void = refreshPortfolios()
        _ = await (a, h, e, p)
    }

    /// A new coin's or Moment's reference, from what its transaction returned (the coin's contract, the Moment's id).
    nonisolated static func reference(_ summary: LiteActionSummary, results: [TxStatus]) -> String? {
        let value = results.last?.returnValue
        switch (summary, value) {
        case (.launchCreate, .string(let token)?) where StrKey.isValid(.contract, token): return "stellar:launch/\(token)"
        case (.launchCreate, _): return "stellar:launch"
        case (.publish, .number(let id)?) where id >= 0 && id == id.rounded() && id < 1e15: return "stellar:moment/\(Int64(id))"
        case (.publish, .string(let id)?) where Int64(id) != nil: return "stellar:moment/\(id)"
        case (.publish, _): return "stellar:moment"
        default: return nil
        }
    }

    func limit(_ asset: String, _ amount: String) -> [String: Int64] {
        // A classic asset outside the registry (CODE:ISSUER, or native) is capped by its asset contract: the verifier
        // counts a step's outflow by that contract, so a cap keyed by CODE:ISSUER would match nothing and refuse the run.
        let contract = config?.asset(asset)?.contract ?? Self.assetContract(asset, network: env.pinned.network) ?? asset
        return [contract: Int64(amount) ?? 0]
    }

    /// An asset's code (XLM, USDC, a coin's symbol) by its id or contract; never an old server's stand-in.
    func code(_ id: String) -> String {
        let known = [account?.balances.first { $0.asset == id || $0.contract == id }?.code, asset(id)?.code, launchSymbols[id],
                     launches.first { $0.token == id }?.symbol]
        return known.lazy.compactMap(LiteFormat.name).first ?? LiteFormat.short(id)
    }

    /// Whether `id` is a coin of the launchpad (a contract that isn't one of the registry's assets).
    func isLaunchToken(_ id: String) -> Bool {
        asset(id) == nil && StrKey.isValid(.contract, id)
    }

    /// A coin's quote asset (its contract), from the launches read, else its page.
    private func quoteAsset(of token: String) async throws -> String {
        if let quote = launchQuotes[token] { return quote }
        return try await launchDetail(token).launch.quote
    }

    /// The phone's titles for the steps the server hasn't built yet: they come with an English label only (the server
    /// builds a plan's first step at once and the others as they come up). The plan's main step is its last; the steps
    /// before it enable the asset it needs.
    nonisolated static func unbuilt(_ plan: PlanView, main: String?, before: String?) -> [String: String] {
        var titles: [String: String] = [:]
        for (index, step) in plan.steps.enumerated() where step.intent == nil {
            titles[step.id] = index == plan.steps.count - 1 ? main : before
        }
        return titles
    }
}

/// The title of the step being signed now: what the passkey prompt names.
/// A step's display fields as a store compares them with its own form (`LaunchV2Store.formChanges`,
/// `MomentsV2Store.formChanges`). A list reads the same whether the server sends it as an array or as a comma-separated
/// string; a field that is absent or of another kind reads as nil, which never matches a form's value.
struct BoundDisplay {
    private let display: [String: StellarJSON]

    init(_ display: [String: StellarJSON]?) {
        self.display = display ?? [:]
    }

    /// A whole number, sent as a number or as its digits.
    func whole(_ key: String) -> Int? {
        switch display[key] {
        case .number(let n)? where n == n.rounded() && abs(n) < 1e15: Int(n)
        case .string(let s)?: Int(s)
        default: nil
        }
    }

    /// A base-units amount or another figure, as its digits.
    func text(_ key: String) -> String? {
        switch display[key] {
        case .string(let s)?: s
        case .number(let n)? where n == n.rounded() && abs(n) < 1e15: String(Int64(n))
        default: nil
        }
    }

    func flag(_ key: String) -> Bool? {
        switch display[key] {
        case .bool(let b)?: b
        case .string("true")?: true
        case .string("false")?: false
        default: nil
        }
    }

    /// A list of strings: the field read back through its JSON, so an array reads as one.
    func strings(_ key: String) -> [String]? {
        guard display[key] != nil, let data = try? JSONEncoder().encode(display),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch object[key] {
        case let list as [Any]:
            let strings = list.compactMap { $0 as? String }
            return strings.count == list.count ? strings : nil
        case let text as String:
            return text.isEmpty ? [] : text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default:
            return nil
        }
    }
}

private final class StepTitle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var title: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

extension ISO8601DateFormatter {
    static let liteUI: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension String {
    /// A server timestamp (ISO 8601, with or without fractions of a second) as a date.
    var liteDate: Date? { ISO8601DateFormatter.liteUI.date(from: self) ?? ISO8601DateFormatter().date(from: self) }
}
