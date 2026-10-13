import Foundation
import Observation
import StellarKit

/// Everything the Lite screens read, and every action they take. One per signed-in account.
@MainActor
@Observable
public final class LiteStore {
    public enum Phase: Equatable {
        case starting
        case needsInvite
        case needsActivation
        case ready
        case unavailable(String)
    }

    public let env: LiteEnvironment
    public let keys: LiteKeyProvider
    public let monad: LiteMonadBridge?
    let api: LiteAPI

    public private(set) var phase: Phase = .starting
    public private(set) var config: LiteConfig?
    public private(set) var account: AccountView?
    public private(set) var prices: Prices?
    public private(set) var activity: [ActivityItem] = []
    public private(set) var markets: [EarnMarket] = []
    public private(set) var positions: [EarnPosition] = []
    public private(set) var launches: [Launch] = []
    public private(set) var moments: [Moment] = []
    public private(set) var owned: [OwnedEdition] = []
    public var lastError: String?

    public init(env: LiteEnvironment, keys: LiteKeyProvider, monad: LiteMonadBridge? = nil) {
        self.env = env
        self.keys = keys
        self.monad = monad
        api = LiteAPI(baseURL: env.apiURL)
    }

    var network: StellarNetwork { env.pinned.network }

    // ---------------------------------------------------------------------------------------------- session

    /// Restores the Lite session, or asks for an invite (first time), then makes sure the account is active.
    public func start() async {
        do {
            config = try await api.config()
            guard let config, config.flags.enabled else {
                phase = .unavailable("DyorHQ Lite is paused for maintenance. Pro is unaffected.")
                return
            }
            guard config.minBuild <= env.buildNumber else {
                phase = .unavailable("Update DyorHQ to use Lite.")
                return
            }
            guard config.sponsor == env.pinned.sponsor else {
                phase = .unavailable("This build doesn't match the Lite network. Update DyorHQ.")
                return
            }
            #if canImport(Security)
            if let saved = StellarKeychain.session(account: keys.address, network: network.name), saved.expiresAt > Date() {
                await api.restore(token: saved.token, expiresAt: saved.expiresAt)
            }
            #endif
            if await !api.isSignedIn {
                try await signIn(invite: nil)
            }
            try await afterSignIn()
        } catch let e as LiteAPIError where e.code == "not_invited" {
            phase = .needsInvite
        } catch {
            phase = .unavailable(describe(error))
        }
    }

    public func signIn(invite: String?) async throws {
        let signer = try await keys.signer(reason: "Sign in to DyorHQ Lite")
        let result = try await api.signIn(signer: signer, inviteCode: invite)
        #if canImport(Security)
        if let exp = ISO8601DateFormatter.liteUI.date(from: result.expiresAt) {
            try? StellarKeychain.saveSession(token: result.token, expiresAt: exp, account: keys.address, network: network.name)
        }
        #endif
        if invite != nil { try await afterSignIn() }
    }

    private func afterSignIn() async throws {
        account = try await api.account()
        let usdcReady = account?.balances.first { $0.asset == "USDC" }?.enabled ?? false
        phase = (account?.exists ?? false) && usdcReady ? .ready : .needsActivation
        if phase == .ready { await refreshAll() }
    }

    /// Creates the account (Friendbot on testnet, sponsored on mainnet) and enables USDC. Spends nothing.
    public func activate() async throws {
        let result = try await api.activate()
        if let plan = result.plan { try await run(plan, limits: [:], reason: "Activate your Stellar account") }
        try await afterSignIn()
    }

    // ---------------------------------------------------------------------------------------------- reads

    public func refreshAll() async {
        async let a: Void = refreshAccount()
        async let b: Void = refreshEarn()
        async let c: Void = refreshLaunches(sort: "new")
        async let d: Void = refreshMoments()
        _ = await (a, b, c, d)
    }

    public func refreshAccount() async {
        do {
            account = try await api.account()
            prices = try await api.prices()
            activity = try await api.activity()
        } catch { lastError = describe(error) }
    }

    public func refreshEarn() async {
        do {
            markets = try await api.earnMarkets()
            positions = try await api.earnPositions()
        } catch { lastError = describe(error) }
    }

    public func refreshLaunches(sort: String) async {
        do { launches = try await api.launches(sort: sort) } catch { lastError = describe(error) }
    }

    public func launchDetail(_ token: String) async throws -> LaunchDetail { try await api.launch(token) }

    public func refreshMoments() async {
        do {
            moments = try await api.moments()
            owned = try await api.ownedEditions()
        } catch { lastError = describe(error) }
    }

    public func momentDetail(_ id: Int) async throws -> MomentDetail { try await api.moment(id) }

    /// Total balance in USD at reference prices (testnet assets have no value: the label says so).
    public var totalUSD: Double {
        guard let account, let prices else { return 0 }
        return account.balances.reduce(0) { sum, row in
            sum + Double(row.units) / 1e7 * (prices.usd[row.asset] ?? prices.usd[row.contract] ?? 0)
        } + positions.reduce(0) { sum, p in
            sum + (Double(p.supplied) ?? 0) / 1e7 * (prices.usd[p.code == "XLM" ? "XLM" : "USDC"] ?? 0)
        }
    }

    public func asset(_ id: String) -> AssetInfo? { config?.asset(id) }

    // ---------------------------------------------------------------------------------------------- actions → plans

    public func quoteSwap(sell: String, buy: String, amount: Int64, slippageBps: Int) async throws -> SwapQuote {
        try await api.quoteSwap(sell: sell, buy: buy, amount: amount, slippageBps: slippageBps)
    }

    public func swapPlan(_ quote: SwapQuote) async throws -> PreparedAction {
        let plan = try await api.buildSwap(quoteId: quote.quoteId)
        return PreparedAction(plan: plan, limits: limit(quote.sell, quote.amountIn), title: "Swap")
    }

    public func sendPlan(asset: String, to: String, amount: Int64, memo: String?, memoType: String?) async throws -> PreparedAction {
        let plan = try await api.send(asset: asset, to: to, amount: amount, memo: memo, memoType: memoType)
        return PreparedAction(plan: plan, limits: limit(asset, String(amount)), title: "Send")
    }

    public func earnPlan(deposit: Bool, market: EarnMarket, amount: Int64) async throws -> PreparedAction {
        let plan = try await api.buildEarn(deposit: deposit, pool: market.pool, asset: market.asset, amount: amount)
        return PreparedAction(plan: plan, limits: deposit ? [market.asset: amount] : [:], title: deposit ? "Deposit" : "Withdraw")
    }

    public func launchPlan(_ req: LiteAPI.LaunchRequest, spend: (asset: String, amount: Int64)?) async throws -> PreparedAction {
        let plan = try await api.buildLaunch(req)
        var limits: [String: Int64] = [:]
        if let spend { limits[asset(spend.asset)?.contract ?? spend.asset] = spend.amount }
        return PreparedAction(plan: plan, limits: limits, title: req.action == "create" ? "Launch" : req.action.capitalized)
    }

    public func quoteTrade(token: String, buy: Bool, amount: Int64) async throws -> TradeQuote {
        try await api.quoteTrade(token: token, buy: buy, amount: amount)
    }

    public func publishPlan(media: Data, contentType: String, title: String, description: String, price: Int64, quote: String, editions: Int, windowSecs: Int) async throws -> PreparedAction {
        let ticket = try await api.uploadTicket(contentType: contentType, bytes: media.count)
        try await api.upload(media, contentType: contentType, to: ticket)
        let uri = try await api.momentMetadata(title: title, description: description, mediaUrl: ticket.publicUrl, video: contentType.hasPrefix("video"))
        let plan = try await api.buildPublishMoment(uri: uri, price: price, quote: quote, maxEditions: editions, windowSecs: windowSecs)
        return PreparedAction(plan: plan, limits: [:], title: "Publish")
    }

    public func uploadImage(_ data: Data, contentType: String) async throws -> String {
        let ticket = try await api.uploadTicket(contentType: contentType, bytes: data.count)
        try await api.upload(data, contentType: contentType, to: ticket)
        return ticket.publicUrl
    }

    public func collectPlan(_ moment: Moment, quantity: Int) async throws -> PreparedAction {
        let plan = try await api.buildCollect(momentId: moment.id, quantity: quantity)
        let total = (Int64(moment.price) ?? 0) * Int64(quantity)
        return PreparedAction(plan: plan, limits: [moment.quote: total], title: "Collect")
    }

    public func bridgeOut(amount: Int64, monadAddress: String) async throws -> (PreparedAction, BridgeTransfer) {
        let start = try await api.bridgeStart(toStellar: false, amount: String(amount), monadAddress: monadAddress)
        guard let plan = start.plan else { throw LiteAPIError.decoding("the bridge plan") }
        return (PreparedAction(plan: plan, limits: limit("USDC", String(amount)), title: "Send to Monad"), start.transfer)
    }

    public func bridgeIn(amount6: Int64) async throws -> BridgeTransfer {
        guard let monad else { throw LiteAPIError.server(status: 400, code: "no_monad", message: "Open Lite from DyorHQ to move funds from Monad.") }
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

    public func signOutOfLite() async {
        await api.signOut()
        #if canImport(Security)
        StellarKeychain.erase(account: keys.address)
        #endif
        phase = .starting
    }

    // ---------------------------------------------------------------------------------------------- running

    /// Verifies, signs and sends every step of a plan; `limits` are the amounts the user confirmed on screen.
    @discardableResult
    public func run(_ plan: PlanView, limits: [String: Int64], reason: String, onEvent: @escaping @Sendable (PlanRunner.Event) -> Void = { _ in }) async throws -> [TxStatus] {
        guard let config, let rpc = URL(string: config.rpcUrl) else { throw LiteAPIError.notSignedIn }
        let runner = PlanRunner(api: api, user: keys.address, pinned: env.pinned, inspector: ContractInspector(rpcURL: rpc))
        let keys = self.keys
        let results = try await runner.run(plan, limits: limits, signer: { try await keys.signer(reason: reason) }, onEvent: onEvent)
        Task { await self.refreshAccount() }
        return results
    }

    func limit(_ asset: String, _ amount: String) -> [String: Int64] {
        let contract = config?.asset(asset)?.contract ?? asset
        return [contract: Int64(amount) ?? 0]
    }
}

/// A plan plus the limits the user is confirming, ready for the confirmation sheet.
public struct PreparedAction: Identifiable, Equatable {
    public let plan: PlanView
    public let limits: [String: Int64]
    public let title: String
    public var id: String { plan.planId }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

extension ISO8601DateFormatter {
    static let liteUI: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
