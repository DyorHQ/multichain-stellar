import Foundation
import Observation
import StellarKit

/// Everything the Stellar screens read, and every action they take. Made by `LiteSession` once signed in, and kept
/// with it across network switches, so a return to Stellar shows the last figures at once.
@MainActor
@Observable
public final class LiteStore {
    public let env: LiteEnvironment
    /// The account's Stellar address (G…).
    public let address: String
    public let monad: LiteMonadBridge?
    let api: LiteAPI
    /// The session that made it: the signer for transactions, and where a lost session or a paused service is said.
    @ObservationIgnored weak var session: LiteSession?

    public internal(set) var config: LiteConfig?
    public private(set) var account: AccountView?
    public private(set) var prices: StellarPrices?
    public private(set) var activity: [StellarActivityItem] = []
    public private(set) var markets: [EarnMarket] = []
    public private(set) var positions: [EarnPosition] = []
    public private(set) var launches: [StellarLaunch] = []
    public private(set) var moments: [StellarMoment] = []
    public private(set) var owned: [StellarEdition] = []
    /// The last read's failure, in the current language; nil once a refresh goes through.
    public internal(set) var lastError: String?
    /// When the balances were last read.
    public private(set) var updatedAt: Date?

    /// The parts read at least once, and the parts whose last read failed: a part never says "nothing" for want of
    /// an answer.
    enum Part: Hashable { case account, activity, earn, launches, moments }
    private(set) var loaded: Set<Part> = []
    private(set) var failed: Set<Part> = []

    init(env: LiteEnvironment, api: LiteAPI, address: String, monad: LiteMonadBridge?, config: LiteConfig?) {
        self.env = env
        self.api = api
        self.address = address
        self.monad = monad
        self.config = config
    }

    var network: StellarNetwork { env.pinned.network }
    var isTestnet: Bool { network.name == "testnet" }

    // ---------------------------------------------------------------------------------------------- reads

    /// Reads everything again. A call while a refresh is under way waits for that one rather than starting another (a
    /// run that ends as Stellar Home appears asks twice).
    public func refreshAll() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readAll() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    @ObservationIgnored private var refreshing: Task<Void, Never>?

    /// Reads everything again, in place: what was read stays on screen until a new read replaces it, and the header's
    /// warning goes only once a whole round has gone through (a poll never makes it blink).
    private func readAll() async {
        async let c: Void = refreshConfig()
        async let a: Void = refreshAccount()
        async let t: Void = refreshActivity()
        async let b: Void = refreshEarn()
        async let l: Void = refreshLaunches(sort: "new")
        async let d: Void = refreshMoments()
        _ = await (c, a, t, b, l, d)
        if failed.isEmpty { lastError = nil }
    }

    func refreshConfig() async {
        guard let config = try? await api.config() else { return }
        self.config = config
        session?.read(config: config)
    }

    public func refreshAccount() async {
        do {
            async let account = api.account()
            async let prices = api.prices()
            let (a, p) = try await (account, prices)
            adopt(account: a)
            self.prices = p
            updatedAt = Date()
        } catch {
            failed.insert(.account)
            report(error)
        }
    }

    func refreshActivity() async {
        do {
            activity = try await api.activity()
            loaded.insert(.activity)
            failed.remove(.activity)
        } catch {
            failed.insert(.activity)
            report(error)
        }
    }

    public func refreshEarn() async {
        do {
            markets = try await api.earnMarkets()
            positions = try await api.earnPositions()
            loaded.insert(.earn)
            failed.remove(.earn)
        } catch {
            failed.insert(.earn)
            report(error)
        }
    }

    public func refreshLaunches(sort: String) async {
        do {
            launches = try await api.launches(sort: sort)
            loaded.insert(.launches)
            failed.remove(.launches)
        } catch {
            failed.insert(.launches)
            report(error)
        }
    }

    public func launchDetail(_ token: String) async throws -> StellarLaunchDetail { try await api.launch(token) }

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

    public func momentDetail(_ id: Int) async throws -> StellarMomentDetail { try await api.moment(id) }

    func adopt(account: AccountView) {
        self.account = account
        loaded.insert(.account)
        failed.remove(.account)
    }

    /// A read that failed: said in the header, and a lost session or access told to the session.
    func report(_ error: Error) {
        lastError = describe(error)
        guard let api = error as? LiteAPIError else { return }
        switch api {
        case .notSignedIn: session?.lostSession()
        case let .server(status, code, _):
            if code == "access_revoked" { session?.lostAccess() } else if status == 401 { session?.lostSession() }
        default: break
        }
    }

    /// The total in USD at reference prices (testnet assets have no value: the screen says so). Nil until the balances
    /// and the prices are read.
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

    /// A signer for a transaction: one prompt (the session's provider). `reason` is in the current language.
    func signer(reason: String) async throws -> StellarSigner {
        guard let session else { throw LiteAPIError.notSignedIn }
        return try await session.signer(reason: reason)
    }

    // ---------------------------------------------------------------------------------------------- actions → plans

    public func quoteSwap(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        try await api.quoteSwap(sell: sell, buy: buy, amount: amount, slippageBps: slippageBps)
    }

    public func swapPlan(_ quote: SwapQuote) async throws -> PreparedAction {
        let plan = try await api.buildSwap(quoteId: quote.quoteId)
        let buy = code(quote.buy)
        let swap = LiteTitles.intent(kind: "swap", display: ["amountIn": .string(quote.amountIn), "sell": .string(code(quote.sell)), "buy": .string(buy)])
        return PreparedAction(plan: plan, limits: limit(quote.sell, quote.amountIn), title: tr("Swap"),
                              titles: Self.unbuilt(plan, main: swap, before: LiteTitles.intent(kind: "trust", display: ["asset": .string(buy)])))
    }

    public func sendPlan(asset: String, to: String, amount: Int64, memo: String?, memoType: String?) async throws -> PreparedAction {
        let plan = try await api.send(asset: asset, to: to, amount: amount, memo: memo, memoType: memoType)
        return PreparedAction(plan: plan, limits: limit(asset, String(amount)), title: tr("Send"))
    }

    public func earnPlan(deposit: Bool, market: EarnMarket, amount: Int64) async throws -> PreparedAction {
        let plan = try await api.buildEarn(deposit: deposit, pool: market.pool, asset: market.asset, amount: amount)
        let main = LiteTitles.intent(kind: deposit ? "earn_deposit" : "earn_withdraw", display: ["amount": .string(String(amount)), "asset": .string(market.code)])
        return PreparedAction(plan: plan, limits: deposit ? [market.asset: amount] : [:], title: deposit ? tr("Deposit") : tr("Withdraw"),
                              titles: Self.unbuilt(plan, main: main, before: LiteTitles.intent(kind: "trust", display: ["asset": .string(market.code)])))
    }

    public func launchPlan(_ req: LiteAPI.LaunchRequest, spend: (asset: String, amount: Int64)?) async throws -> PreparedAction {
        let plan = try await api.buildLaunch(req)
        var limits: [String: Int64] = [:]
        if let spend { limits[asset(spend.asset)?.contract ?? spend.asset] = spend.amount }
        return PreparedAction(plan: plan, limits: limits, title: Self.launchTitle(req.action))
    }

    static func launchTitle(_ action: String) -> String {
        switch action {
        case "create": tr("Launch a coin")
        case "buy": tr("Buy")
        case "sell": tr("Sell")
        case "graduate": tr("Graduate")
        case "claim": tr("Claim")
        default: action.capitalized
        }
    }

    public func quoteTrade(token: String, buy: Bool, amount: Int64) async throws -> TradeQuote {
        try await api.quoteTrade(token: token, buy: buy, amount: amount)
    }

    public func publishPlan(media: Data, contentType: String, title: String, description: String, price: Int64, quote: String, editions: Int, windowSecs: Int) async throws -> PreparedAction {
        let ticket = try await api.uploadTicket(contentType: contentType, bytes: media.count)
        try await api.upload(media, contentType: contentType, to: ticket)
        let uri = try await api.momentMetadata(title: title, description: description, mediaUrl: ticket.publicUrl, video: contentType.hasPrefix("video"))
        let plan = try await api.buildPublishMoment(uri: uri, price: price, quote: quote, maxEditions: editions, windowSecs: windowSecs)
        return PreparedAction(plan: plan, limits: [:], title: tr("Publish"))
    }

    public func uploadImage(_ data: Data, contentType: String) async throws -> String {
        let ticket = try await api.uploadTicket(contentType: contentType, bytes: data.count)
        try await api.upload(data, contentType: contentType, to: ticket)
        return ticket.publicUrl
    }

    public func collectPlan(_ moment: StellarMoment, quantity: Int) async throws -> PreparedAction {
        let plan = try await api.buildCollect(momentId: moment.id, quantity: quantity)
        let total = (Int64(moment.price) ?? 0) * Int64(quantity)
        return PreparedAction(plan: plan, limits: [moment.quote: total], title: tr("Collect"))
    }

    public func bridgeOut(amount: Int64, monadAddress: String) async throws -> (PreparedAction, BridgeTransfer) {
        let start = try await api.bridgeStart(toStellar: false, amount: String(amount), monadAddress: monadAddress)
        guard let plan = start.plan else { throw LiteAPIError.decoding("the bridge plan") }
        let send = LiteTitles.intent(kind: "bridge_out", display: ["amount": .string(String(amount))])
        return (PreparedAction(plan: plan, limits: limit("USDC", String(amount)), title: tr("Send to Monad"), titles: Self.unbuilt(plan, main: send, before: nil)),
                start.transfer)
    }

    public func bridgeIn(amount6: Int64) async throws -> BridgeTransfer {
        guard let monad else { throw LiteAPIError.server(status: 400, code: "no_monad", message: tr("Move funds from Monad inside DyorHQ.")) }
        let start = try await api.bridgeStart(toStellar: true, amount: String(amount6), monadAddress: monad.monadAddress)
        let hash = try await monad.send(start.evmSteps ?? [])
        _ = try await api.bridgeSource(id: start.transfer.id, txHash: hash)
        return start.transfer
    }

    public func bridgeSourceReported(id: String, hash: String) async throws { _ = try await api.bridgeSource(id: id, txHash: hash) }
    public func bridgeStatus(id: String) async throws -> BridgeStatus { try await api.bridgeStatus(id: id) }

    public func claimOnMonad(_ status: BridgeStatus) async throws {
        guard let monad, let claim = status.claim else { return }
        let hash = try await monad.send([claim])
        _ = try await api.bridgeClaimed(id: status.id, txHash: hash)
    }

    public func faucet() async throws {
        _ = try await api.faucet()
        await refreshAccount()
    }

    public func anchors() async throws -> [AnchorInfo] { try await api.anchors(country: Locale.current.region?.identifier ?? "*") }

    public func trackCash(anchor: String, deposit: Bool, asset: String, id: String, status: String, amount: String?) async {
        try? await api.trackCash(anchor: anchor, deposit: deposit, asset: asset, anchorTxId: id, status: status, amount: amount)
    }

    // ---------------------------------------------------------------------------------------------- running

    /// Verifies, signs and sends every step of a plan; `limits` are the amounts the user confirmed on screen. Each step
    /// unlocks for itself (`reason` is shown in the prompt, in the current language).
    @discardableResult
    public func run(_ plan: PlanView, limits: [String: Int64], reason: String, onEvent: @escaping @Sendable (PlanRunner.Event) -> Void = { _ in }) async throws -> [TxStatus] {
        guard let config, let rpc = URL(string: config.rpcUrl) else { throw LiteAPIError.notSignedIn }
        let runner = PlanRunner(api: api, user: address, pinned: env.pinned, inspector: ContractInspector(rpcURL: rpc))
        let results = try await runner.run(plan, limits: limits, signer: { try await self.signer(reason: reason) }, onEvent: onEvent)
        Task { await self.refreshAccount() }
        Task { await self.refreshActivity() }
        return results
    }

    func limit(_ asset: String, _ amount: String) -> [String: Int64] {
        let contract = config?.asset(asset)?.contract ?? asset
        return [contract: Int64(amount) ?? 0]
    }

    /// An asset's code (XLM, USDC, a launch's symbol) by its id or contract.
    func code(_ id: String) -> String {
        account?.balances.first { $0.asset == id }?.code ?? asset(id)?.code ?? launches.first { $0.token == id }?.symbol ?? shortAddress(id)
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

/// A plan plus the limits the user is confirming, ready for the confirmation sheet.
public struct PreparedAction: Identifiable, Equatable {
    public let plan: PlanView
    public let limits: [String: Int64]
    public let title: String
    /// Titles for steps that arrive without their intent (`LiteStore.unbuilt`), by step id.
    var titles: [String: String] = [:]
    public var id: String { plan.planId }
}

/// An error as a person reads it, in the current language where the package words it: no connection, a cancelled or
/// wrong unlock, the session's failures. The server's and the plan checks' own messages are shown as they are.
func describe(_ error: Error) -> String {
    switch error {
    case LiteAPIError.transport:
        return tr("No connection. Check your network and try again.")
    case LiteAPIError.notSignedIn:
        return tr("Sign in on Stellar to continue.")
    case is LiteAPIError, is PlanRunner.Failure, is AnchorClient.Failure:
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    default:
        return LiteSession.failure(for: error).errorDescription ?? error.localizedDescription
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
