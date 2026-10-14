import BigInt
import Foundation

/// Reads markets, accounts, positions and orders from Perpl's Exchange contract and builds the transaction
/// plans the app runs with `TransactionSender`. Mirrors app/lib/perps/perpl.ts in the web repository.
public actor PerplService {
    /// The markets the app lists, in display order: every live market on the Exchange (id 30, the old SOL, is
    /// retired). Symbols are the app's; the contract's own symbol (for example `SOL_v2`) is what `PerpMarket.symbol`
    /// carries, and price / lot decimals are read from `getPerpetualInfo` (LIT 5/1, VVV 4/2, TAO 3/3, PUMP 6/0 on
    /// 2026-09-27). A position in a market missing here is still read (`positions`).
    // not localized: the markets' names
    public static let markets: [(id: Int, symbol: String, name: String)] = [
        (1, "BTC", "Bitcoin"),
        (10, "MON", "Monad"),
        (20, "ETH", "Ether"),
        (31, "SOL", "Solana"),
        (40, "HYPE", "Hyperliquid"),
        (50, "ZEC", "Zcash"),
        (60, "LIT", "Lighter"),
        (70, "VVV", "Venice"),
        (80, "TAO", "Bittensor"),
        (90, "PUMP", "Pump.fun"),
    ]

    /// Perpl's public REST API. `Perpl.api` (api.perpl.xyz) has no DNS record; the web app proxies
    /// app.perpl.xyz/api, which is what this defaults to.
    public static let restBase = URL(string: "https://app.perpl.xyz/api")!

    public let rpc: RPCClient
    private let multicall: Multicall
    private let session: URLSession
    private let apiBase: URL
    private let contextURL: URL

    public init(rpc: RPCClient, session: URLSession = .shared, restBase: URL = PerplService.restBase) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
        self.session = session
        apiBase = restBase
        contextURL = restBase.appending(path: "v1/pub/context")
    }

    // MARK: Reads

    /// Markets in the order of `ids`; markets the contract fails to report are left out, and a market whose
    /// margin read fails has unknown (nil) margin fractions, never a guessed 10% / 5%.
    public func markets(ids: [Int]? = nil) async throws -> [PerpMarket] {
        let ids = ids ?? Self.markets.map(\.id)
        async let infoReads = multicall.read(ids.map { PerplExchange.read(PerplExchange.Signature.getPerpetualInfo, [.uint($0)], returns: PerplExchange.Returns.perpetualInfo) })
        async let marginReads = multicall.read(ids.map { PerplExchange.read(PerplExchange.Signature.getMarginFractions, [.uint($0), .uint(0)], returns: PerplExchange.Returns.marginFractions) })
        let (infos, margins) = try await (infoReads, marginReads)
        var out: [PerpMarket] = []
        for (i, id) in ids.enumerated() {
            guard case .success(let info) = infos[i] else { continue }
            var margin: [ABIValue]?
            if case .success(let values) = margins[i] { margin = values }
            out.append(PerplExchange.market(id: id, info: info[0], margins: margin))
        }
        return out
    }

    /// Nil when the address has no Exchange account: the contract reverts with `AccountNotFound(address)`
    /// rather than returning an empty record.
    public func account(_ address: Address) async throws -> PerpAccount? {
        let data = PerplExchange.calldata(PerplExchange.Signature.getAccountByAddr, [.address(address)])
        let raw: Data
        do {
            raw = try await rpc.ethCall(CallRequest(to: PerplExchange.address, data: data))
        } catch let error as RPCError where PerplExchange.isAccountNotFound(error) {
            return nil
        }
        let values = try ABI.decode(raw, PerplExchange.Returns.account)
        return PerplExchange.account(values[0])
    }

    /// Every open position of the account. A position in a market `markets` doesn't hold (one Perpl added after this
    /// build) is read with that market's own on-chain info, never dropped; if that market can't be read, this throws
    /// rather than return a list that looks complete.
    public func positions(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpPosition] {
        if account.positionPerpIds.isEmpty { return [] }
        let listed = Set(markets.map(\.id))
        let unlisted = account.positionPerpIds.filter { !listed.contains($0) }
        var markets = markets
        if !unlisted.isEmpty {
            let extra = try await self.markets(ids: unlisted)
            guard Set(extra.map(\.id)).isSuperset(of: unlisted) else {
                throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("a position in a market", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”")))
            }
            markets += extra
        }
        let calls = account.positionPerpIds.map { PerplExchange.read(PerplExchange.Signature.getPosition, [.uint($0), .uint(account.accountId)], returns: PerplExchange.Returns.position) }
        let results = try await multicall.read(calls)
        var out: [PerpPosition] = []
        for (perpId, result) in zip(account.positionPerpIds, results) {
            // A slot that can't be read is an error, never a list that silently leaves the position out; only a
            // successful read of an empty slot (zero lot) is skipped.
            guard case .success(let values) = result, let perp = markets.first(where: { $0.id == perpId }) else {
                throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("position \(String(perpId))", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.” The value is the market's number.")))
            }
            guard let position = PerplExchange.position(perp: perp, values: values) else { continue }
            out.append(position)
        }
        return out
    }

    /// Open orders of an account: for every market where the account holds an order lock, walk the market's
    /// order-id index, read each order in chunks, and keep the account's own.
    public func openOrders(_ account: PerpAccount, markets: [PerpMarket]) async throws -> [PerpOrder] {
        let lockCalls = markets.map { PerplExchange.read(PerplExchange.Signature.getPerpOrderLocks, [.uint(account.accountId), .uint($0.id)], returns: PerplExchange.Returns.orderLocks) }
        let locks = try await multicall.read(lockCalls)
        let active = zip(markets, locks).compactMap { market, result -> PerpMarket? in
            guard case .success(let values) = result, !values[0].elements.isEmpty else { return nil }
            return market
        }
        var out: [PerpOrder] = []
        for perp in active {
            let indexData = PerplExchange.calldata(PerplExchange.Signature.getOrderIdIndex, [.uint(perp.id)])
            let raw = try await rpc.ethCall(CallRequest(to: PerplExchange.address, data: indexData))
            let index = try ABI.decode(raw, PerplExchange.Returns.orderIdIndex)
            let ids = PerplExchange.orderIds(leaves: index[1].elements.map(\.uint))
            for start in stride(from: 0, to: ids.count, by: PerplExchange.orderChunkSize) {
                let chunk = Array(ids[start..<min(start + PerplExchange.orderChunkSize, ids.count)])
                let orderCalls = chunk.map { PerplExchange.read(PerplExchange.Signature.getOrder, [.uint(perp.id), .uint($0)], returns: PerplExchange.Returns.order) }
                let orders = try await multicall.read(orderCalls)
                for (orderId, result) in zip(chunk, orders) {
                    guard case .success(let values) = result else { continue }
                    let parsed = PerplExchange.order(perp: perp, orderId: orderId, values: values[0])
                    guard parsed.accountId == account.accountId, let order = parsed.order else { continue }
                    out.append(order)
                }
            }
        }
        return out
    }

    /// AUSD in the wallet and the allowance already granted to the Exchange, both in collateral units.
    public func collateral(of address: Address) async throws -> (wallet: BigUInt, allowance: BigUInt) {
        let results = try await multicall.readAll([
            try ERC20.balanceOf(Perpl.collateral, address),
            try ERC20.allowance(Perpl.collateral, owner: address, spender: Perpl.exchange),
        ])
        return (results[0][0].uint, results[1][0].uint)
    }

    /// Perpl's public market context: 24h reference price, volume, open interest and funding per market.
    public func context() async throws -> [MarketContext] {
        var request = URLRequest(url: contextURL)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NetworkError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PerplError.contextUnavailable(status: http.statusCode)
        }
        let body: ContextResponse
        do {
            body = try JSONDecoder().decode(ContextResponse.self, from: data)
        } catch {
            throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("market context", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”")))
        }
        return (body.markets ?? []).compactMap { market in
            guard let config = market.config, let state = market.state else { return nil }
            let priceScale = pow(10, Double(config.priceDecimals))
            let sizeScale = pow(10, Double(config.sizeDecimals))
            // `funding.rate` is the interval rate in parts per million (BTC 40 ↔ contract fundingRatePct100k 4 ↔
            // 0.004%/h, verified live 2026-09-16 on BTC, ETH and MON); `div` scales the funding index, not the rate.
            let fundingRate = (market.funding?.rate ?? 0) / 1_000_000
            return MarketContext(
                id: market.id,
                name: market.name ?? "",
                priceDecimals: config.priceDecimals,
                sizeDecimals: config.sizeDecimals,
                mark: state.mrk / priceScale,
                last: state.lst / priceScale,
                prev24h: state.prv / priceScale,
                volume24h: state.dv / sizeScale,
                openInterest: state.oi / sizeScale,
                fundingRate: fundingRate,
                isOpen: config.isOpen,
                fundingIntervalSeconds: market.fundingIntervalSec ?? 0,
                fundingIntervalBlocks: market.fundingIntervalBlocks ?? 0,
                orderTTLBlocks: market.orderTTLBlocks
            )
        }
    }

    /// OHLCV candles for a market's chart, straight from Perpl's public REST feed (no auth). `from`/`to` are
    /// milliseconds; `resolution` is one of Perpl's supported second-intervals; at most 1024 candles per call.
    /// Prices are scaled by the market's `priceDecimals`; volume arrives as a decimal string.
    public func candles(marketId: Int, resolution: Int, from: Date, to: Date, priceDecimals: Int) async throws -> [PerpCandle] {
        let fromMs = Int(from.timeIntervalSince1970 * 1000)
        let toMs = Int(to.timeIntervalSince1970 * 1000)
        let url = apiBase.appending(path: "v1/market-data/\(marketId)/candles/\(resolution)/\(fromMs)-\(toMs)")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("DyorHQ/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw NetworkError.transport(error) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PerplError.contextUnavailable(status: http.statusCode) }
        let series: CandleSeriesResponse
        do { series = try JSONDecoder().decode(CandleSeriesResponse.self, from: data) } catch { throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("candles", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”"))) }
        let scale = pow(10.0, Double(priceDecimals))
        return (series.d ?? []).map { candle in
            PerpCandle(
                time: Date(timeIntervalSince1970: Double(candle.t) / 1000),
                open: Double(candle.o) / scale, high: Double(candle.h) / scale, low: Double(candle.l) / scale, close: Double(candle.c) / scale,
                volume: Double(candle.v ?? "0") ?? 0, trades: candle.n ?? 0
            )
        }
    }

    // MARK: Authenticated history

    /// One page of fills (newest first). `count` ≤ 100; pass the previous page's `next` cursor to continue.
    public func fills(key: PerplApiKey, markets: [PerpMarket], count: Int = 100, cursor: String? = nil) async throws -> PerplHistoryPage<PerplFill> {
        let byId = Dictionary(markets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let (rows, next) = try await signedHistory("/v1/trading/fills", count: count, cursor: cursor, key: key)
        return PerplHistoryPage(items: rows.compactMap { PerplFill(fill: $0, markets: byId) }, next: next)
    }

    /// One page of position-history rows that realized P&L (closes, decreases, liquidations), newest first.
    public func positionHistory(key: PerplApiKey, markets: [PerpMarket], count: Int = 100, cursor: String? = nil) async throws -> PerplHistoryPage<PerplPositionRecord> {
        let byId = Dictionary(markets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let (rows, next) = try await signedHistory("/v1/trading/position-history", count: count, cursor: cursor, key: key)
        return PerplHistoryPage(items: rows.compactMap { PerplPositionRecord(position: $0, markets: byId) }, next: next)
    }

    /// One page of the account's history (deposits, withdrawals, settlements, funding payments, liquidations), newest
    /// first. Funding rows (`kind == .funding`) are the realized funding payments on the account.
    public func accountHistory(key: PerplApiKey, count: Int = 100, cursor: String? = nil) async throws -> PerplHistoryPage<PerplAccountEvent> {
        let (rows, next) = try await signedHistory("/v1/trading/account-history", count: count, cursor: cursor, key: key)
        return PerplHistoryPage(items: rows.compactMap { PerplAccountEvent(event: $0) }, next: next)
    }

    /// One page of the account's order history (signed), newest first, as order events: what a reconnect or a relaunch
    /// reads by request id when the stream's own report was missed.
    public func orderEvents(key: PerplApiKey, count: Int = 100, cursor: String? = nil) async throws -> PerplHistoryPage<PerplOrderEvent> {
        let (rows, next) = try await signedHistory("/v1/trading/order-history", count: count, cursor: cursor, key: key)
        return PerplHistoryPage(items: rows.compactMap { PerplOrderEvent(json: $0, snapshot: false) }, next: next)
    }

    /// What a mined Perpl transaction did, decoded from its receipt (`PerplReceipt`); nil when the receipt never read back.
    public func receiptRequests(_ hash: Data) async throws -> [PerplReceipt.Request]? {
        try await PerplReceipt.requests(ofTransaction: hash, rpc: rpc)
    }

    /// Signs and fetches one `{d:[…], np:cursor}` history page. `path` is the gateway path with no `/api` prefix.
    private func signedHistory(_ path: String, count: Int, cursor: String?, key: PerplApiKey) async throws -> (rows: [[String: Any]], next: String?) {
        var target = "\(path)?count=\(max(1, min(count, 100)))"
        if let cursor, !cursor.isEmpty { target += "&page=\(cursor)" }
        let auth = PerplAuthClient(chainId: Monad.chainId, apiBase: apiBase, session: session)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = PerplAuth.base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let data = try await auth.signedGet(target, key: key, timestamp: timestamp, nonce: nonce)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PerplError.malformedResponse(L10n.string(LocalizedStringResource("history page", bundle: L10n.kit, comment: "What Perpl sent that the app could not read, completing “Perpl sent <this> the app could not read.”"))) }
        let rows = json["d"] as? [[String: Any]] ?? []
        let np = json["np"] as? String
        return (rows, (np?.isEmpty == false) ? np : nil)
    }

    // MARK: Transaction plans

    /// Approves AUSD to the Exchange when needed (the sender skips a sufficient allowance), then opens the
    /// account with the first deposit or tops an existing one up.
    public nonisolated func depositPlan(amountCNS: BigUInt, hasAccount: Bool) -> [TransactionStep] {
        let signature = hasAccount ? PerplExchange.Signature.depositCollateral : PerplExchange.Signature.createAccount
        let request = TransactionRequest(to: PerplExchange.address, data: PerplExchange.calldata(signature, [.uint(amountCNS)]))
        return [
            .approve(token: Perpl.collateral, spender: Perpl.exchange, amount: amountCNS, label: L10n.tr("Approve AUSD")),
            .call(request, label: hasAccount ? L10n.string(LocalizedStringResource("Deposit AUSD", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent.")) : L10n.string(LocalizedStringResource("Open Perpl account", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. It opens (creates) a trading account on Perpl with a first deposit."))),
        ]
    }

    public nonisolated func withdrawPlan(amountCNS: BigUInt) -> [TransactionStep] {
        let request = TransactionRequest(to: PerplExchange.address, data: PerplExchange.calldata(PerplExchange.Signature.withdrawCollateral, [.uint(amountCNS)]))
        return [.call(request, label: L10n.tr("Withdraw AUSD"))]
    }

    /// `execOrders([desc], revertOnFail: true)` for one order.
    public nonisolated func orderPlan(_ input: OrderInput) -> [TransactionStep] {
        let data = PerplExchange.execOrdersCalldata([Self.buildOrderDesc(input)], revertOnFail: true)
        let symbol = input.market.symbol
        let label = input.reduceOnly
            ? L10n.string(LocalizedStringResource("Close \(symbol)", bundle: L10n.kit, comment: "A transaction step: close the position on a Perps market (BTC-PERP)."))
            : input.side == .long
            ? L10n.string(LocalizedStringResource("Long \(symbol)", bundle: L10n.kit, comment: "A transaction step: open or add to a long (buy) position on a Perps market (BTC-PERP)."))
            : L10n.string(LocalizedStringResource("Short \(symbol)", bundle: L10n.kit, comment: "A transaction step: open or add to a short (sell) position on a Perps market (BTC-PERP)."))
        return [.call(TransactionRequest(to: PerplExchange.address, data: data), label: label)]
    }

    public nonisolated func cancelPlan(perpId: Int, orderId: Int) -> [TransactionStep] {
        let desc = PerplExchange.cancelDesc(perpId: perpId, orderId: orderId, descId: BigUInt(OrderDescIDs.shared.next()))
        let data = PerplExchange.execOrdersCalldata([desc], revertOnFail: true)
        return [.call(TransactionRequest(to: PerplExchange.address, data: data), label: L10n.string(LocalizedStringResource("Cancel order", bundle: L10n.kit, comment: "A transaction step: cancel a resting order on Perpl.")))]
    }

    /// Closes a position with a reduce-only order on the opposite side. Defaults to a market close; pass
    /// `kind: .limit` with a `limitPrice` to rest a reduce-only maker order (optionally post-only) instead — the
    /// same order desc the venue uses for any close, so a limit close is as accurate as a market one.
    /// `size` closes part of the position (`closeFractionSize`); nil closes all of it as the chain reported it.
    public nonisolated func closePositionPlan(market: PerpMarket, position: PerpPosition, slippageBps: Int,
                                              kind: OrderKind = .market, limitPrice: Double? = nil, postOnly: Bool = false,
                                              size: Double? = nil) -> [TransactionStep] {
        orderPlan(Self.closeInput(market: market, position: position, size: size ?? position.size, slippageBps: slippageBps,
                                  kind: kind, limitPrice: limitPrice, postOnly: postOnly))
    }

    /// The reduce-only order that closes `size` of `position`: on the opposite side, at the leverage the position carries
    /// (rounded as the web app rounds it, at least 1), a market close at `slippageBps` or a resting limit at `limitPrice`
    /// (optionally post-only). The one close both paths send: the wallet's `execOrders` desc and the trading connection's
    /// CloseLong / CloseShort frame (`PerplOrders.entry`).
    public nonisolated static func closeInput(market: PerpMarket, position: PerpPosition, size: Double, slippageBps: Int,
                                              kind: OrderKind = .market, limitPrice: Double? = nil, postOnly: Bool = false) -> OrderInput {
        let rounded = PerplExchange.jsRound(position.leverage)
        let leverage = max(1, rounded == 0 || rounded.isNaN ? 1 : rounded)
        return OrderInput(market: market, side: position.side.opposite, kind: kind, size: size,
                          price: kind == .limit ? limitPrice : nil, leverage: leverage, reduceOnly: true,
                          slippageBps: slippageBps, postOnly: postOnly && kind == .limit)
    }

    /// `percent` (25, 50 or 75) of a position of `positionSize`, in whole lots of the market (`lotDecimals`): the position's
    /// lots × percent / 100, rounded down — so the size reviewed is exactly the size sent, never a fraction of a lot.
    /// Nil when that is less than one lot (the chip can't close anything). 100 is the size as given.
    public nonisolated static func closeFractionSize(positionSize: Double, lotDecimals: Int, percent: Int) -> Double? {
        guard percent < 100 else { return positionSize > 0 ? positionSize : nil }
        let scale = pow(10, Double(lotDecimals))
        guard positionSize.isFinite, positionSize > 0, let lots = Int(exactly: (positionSize * scale).rounded()) else { return nil }
        let part = lots * max(0, percent) / 100
        return part > 0 ? Double(part) / scale : nil
    }

    /// Adds `amount` AUSD of collateral to the open position on `market`, lowering its leverage and pushing the
    /// liquidation price further away. One `execOrders` call, no approval (the collateral is already in the account).
    public nonisolated func addMarginPlan(market: PerpMarket, amount: Double) -> [TransactionStep] {
        let desc = PerplExchange.addMarginDesc(perpId: market.id, amountCNS: PerplExchange.toCNS(amount), descId: BigUInt(OrderDescIDs.shared.next()))
        let data = PerplExchange.execOrdersCalldata([desc], revertOnFail: true)
        return [.call(TransactionRequest(to: PerplExchange.address, data: data), label: L10n.tr("Add \(NumberStyle.number(amount, maximumFractionDigits: 2)) AUSD margin"))]
    }

    // MARK: Pure helpers

    /// Price at which the position's equity would fall to the maintenance requirement; nil for an empty
    /// position or an unknown maintenance fraction (the margin read failed), never below zero.
    public nonisolated static func liquidationPrice(side: PositionSide, entry: Double, size: Double, margin: Double, premium: Double, maintenanceFraction: Double?) -> Double? {
        PerplExchange.liquidationPrice(side: side, entry: entry, size: size, margin: margin, premium: premium, maintenanceFraction: maintenanceFraction)
    }

    /// The 15 `OrderDesc` fields for `execOrders`, with a fresh strictly increasing `orderDescId`.
    public nonisolated static func buildOrderDesc(_ input: OrderInput) -> [ABIValue] {
        PerplExchange.orderDesc(input, descId: BigUInt(OrderDescIDs.shared.next()))
    }

    /// Collateral units (AUSD, 6 decimals) to a display number and back.
    public nonisolated static func fromCNS(_ value: BigUInt) -> Double { PerplExchange.fromCNS(value) }
    public nonisolated static func toCNS(_ value: Double) -> BigUInt { PerplExchange.toCNS(value) }
}

// MARK: - Context payload

private struct ContextResponse: Decodable {
    let markets: [ContextMarket]?
}

private struct CandleSeriesResponse: Decodable {
    let d: [RawCandle]?
    struct RawCandle: Decodable {
        let t: Int
        let o: Int64
        let c: Int64
        let h: Int64
        let l: Int64
        let v: String?
        let n: Int?
    }
}

private struct ContextMarket: Decodable {
    struct Config: Decodable {
        let priceDecimals: Int
        let sizeDecimals: Int
        let isOpen: Bool

        enum CodingKeys: String, CodingKey {
            case priceDecimals = "price_decimals"
            case sizeDecimals = "size_decimals"
            case isOpen = "is_open"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            priceDecimals = try c.decode(Int.self, forKey: .priceDecimals)
            sizeDecimals = try c.decode(Int.self, forKey: .sizeDecimals)
            isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        }
    }

    struct State: Decodable {
        let mrk: Double
        let lst: Double
        let prv: Double
        let dv: Double
        let oi: Double

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mrk = try c.decodeIfPresent(Double.self, forKey: .mrk) ?? 0
            lst = try c.decodeIfPresent(Double.self, forKey: .lst) ?? 0
            prv = try c.decodeIfPresent(Double.self, forKey: .prv) ?? 0
            dv = try c.decodeIfPresent(Double.self, forKey: .dv) ?? 0
            oi = try c.decodeIfPresent(Double.self, forKey: .oi) ?? 0
        }

        enum CodingKeys: String, CodingKey { case mrk, lst, prv, dv, oi }
    }

    struct Funding: Decodable {
        let rate: Double
        let div: Double?
    }

    let id: Int
    let name: String?
    let config: Config?
    let state: State?
    let funding: Funding?
    /// The market's own funding interval, in seconds and in blocks.
    let fundingIntervalSec: Int?
    let fundingIntervalBlocks: Int?
    /// How many blocks an order sent with `lb: 0` has to execute.
    let orderTTLBlocks: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, config, state, funding
        case fundingIntervalSec = "funding_interval_sec"
        case fundingIntervalBlocks = "funding_interval_blocks"
        case orderTTLBlocks = "order_ttl_blocks"
    }
}
