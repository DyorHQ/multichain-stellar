import Foundation
import Observation

/* Perpl's public market-data WebSocket (wss://app.perpl.xyz/ws/v1/market-data): the live order book, trade tape
   and per-market state for one focused market. No authentication — the native app connects with no Origin, which
   Perpl accepts (verified against the live feed). Scaled integers arrive per the market's price/size decimals and
   are divided out here so the UI only ever sees real numbers. See docs.perpl.xyz market-data websocket. */

public struct BookLevel: Identifiable, Sendable, Hashable {
    public let price: Double
    public let size: Double
    public let orders: Int
    public var id: Double { price }
    public init(price: Double, size: Double, orders: Int) { self.price = price; self.size = size; self.orders = orders }
}

public struct OrderBook: Sendable {
    /// Bids high→low, asks low→high, each already scaled and capped.
    public var bids: [BookLevel] = []
    public var asks: [BookLevel] = []

    public var bestBid: Double? { bids.first?.price }
    public var bestAsk: Double? { asks.first?.price }
    public var spread: Double? { guard let b = bestBid, let a = bestAsk else { return nil }; return a - b }
    /// Share of visible depth resting on the bid, 0…1, for the buy/sell ratio bar.
    public var bidShare: Double {
        let b = bids.reduce(0) { $0 + $1.size }, a = asks.reduce(0) { $0 + $1.size }
        return b + a > 0 ? b / (b + a) : 0.5
    }
    public var isEmpty: Bool { bids.isEmpty && asks.isEmpty }
}

public struct PerpTrade: Identifiable, Sendable, Hashable {
    public let id: Int
    public let time: Date
    public let price: Double
    public let size: Double
    public let side: OrderSide
    public init(id: Int, time: Date, price: Double, size: Double, side: OrderSide) {
        self.id = id; self.time = time; self.price = price; self.size = size; self.side = side
    }
}

/// The `market-state@<chain>` snapshot for one market, scaled.
public struct PerplLiveState: Sendable {
    public let oracle: Double
    public let mark: Double
    public let last: Double
    public let mid: Double
    public let bid: Double
    public let ask: Double
    public let prev24h: Double
    public let volume24h: Double
    public let openInterest: Double
    public var change24h: Double? { prev24h > 0 ? (last - prev24h) / prev24h * 100 : nil }
}

/// One OHLCV candle from Perpl, scaled to real prices.
public struct PerpCandle: Identifiable, Sendable, Hashable {
    public let time: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Double
    public let trades: Int
    public var id: TimeInterval { time.timeIntervalSince1970 }
    public init(time: Date, open: Double, high: Double, low: Double, close: Double, volume: Double, trades: Int) {
        self.time = time; self.open = open; self.high = high; self.low = low; self.close = close; self.volume = volume; self.trades = trades
    }
}

/// Live market data for the focused perp market. `@Observable` so a SwiftUI trade screen reads it directly; the
/// socket runs on the main actor (URLSessionWebSocketTask.receive() suspends without blocking the thread).
@Observable
@MainActor
public final class PerplFeed {
    public private(set) var book = OrderBook()
    public private(set) var trades: [PerpTrade] = []
    public private(set) var state: PerplLiveState?
    public private(set) var connected = false
    public private(set) var error: String?

    private let chainId: Int
    private let wsURL: URL
    private var market: PerpMarket?
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var generation = 0
    private var tradeSeq = 0
    /// The last heartbeat sequence number seen on the CURRENT socket (internal for tests). Each socket numbers its
    /// own heartbeats, so a reconnect starts over.
    private(set) var lastHeartbeat: Int?
    private var retry = 0
    /// When the last frame of any kind arrived. `connected` is derived from this, not from socket errors: a healthy
    /// feed streams book, tape and a heartbeat every second, so *silence* is the true "not live" signal — it stays
    /// live through a brief reconnect and it also catches a half-open socket that never delivers an error.
    private var lastMessageAt: Date = .distantPast
    private var lastRestartAt: Date = .distantPast
    private var supervisor: Task<Void, Never>?
    private static let backoff: [UInt64] = [1, 2, 4, 8, 16, 32, 60]
    /// Silence beyond this reads as "Connecting…"; beyond the second, a fresh socket is forced (a silent half-open
    /// stall never fires `.failure`, so nothing else would reconnect it).
    private static let showConnectingAfter: TimeInterval = 3
    private static let forceReconnectAfter: TimeInterval = 8

    public init(chainId: Int = 143, wsURL: URL = URL(string: "wss://app.perpl.xyz/ws/v1/market-data")!, session: URLSession = .shared) {
        self.chainId = chainId
        self.wsURL = wsURL
        self.session = session
    }

    /// Point the feed at a market. Tears down any previous socket and its book/tape.
    ///
    /// Re-focusing the same market is a no-op ONLY while the socket is still alive (`task != nil`). After `stop()`
    /// (the trade screen disappeared) the task is nil, so the same market must reconnect on the next appear —
    /// otherwise the feed stays dead and the UI is stuck on "Connecting…".
    public func focus(_ market: PerpMarket) {
        if market.id == self.market?.id, task != nil { return }
        self.market = market
        book = OrderBook()
        trades = []
        state = nil
        // Read honestly as "Connecting…" for the new market instead of carrying the previous market's live state
        // over its empty book until the supervisor's first tick.
        connected = false
        lastMessageAt = .distantPast
        restart()
        startSupervisor()
    }

    public func stop() {
        generation += 1
        supervisor?.cancel()
        supervisor = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func restart() {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        guard let market else { return }
        lastRestartAt = Date()
        // The new socket's first heartbeat must not be compared with the old socket's last one: that reads as a gap
        // and forces a second subscribe right after this one.
        lastHeartbeat = nil
        let task = session.webSocketTask(with: wsURL)
        self.task = task
        task.resume()
        subscribe(market: market)
        receive(gen: gen)
    }

    /// A once-per-second watchdog that owns `connected` from data recency and rescues a socket that went silent
    /// without erroring. It runs from `focus()` to `stop()`, spanning reconnects, so it is the single authority on
    /// whether the UI reads "Live". `restart()` supersedes any pending failure-driven reconnect by bumping generation.
    private func startSupervisor() {
        supervisor?.cancel()
        supervisor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.market != nil else { return }
                let silence = Date().timeIntervalSince(self.lastMessageAt)
                if self.connected, silence > Self.showConnectingAfter { self.connected = false }
                // Silent past the hard window with no reconnect since — a half-open socket, or every retry is stalling.
                // Force a fresh one. `lastRestartAt` (set by every restart, including failure-driven) rate-limits this.
                if silence > Self.forceReconnectAfter, Date().timeIntervalSince(self.lastRestartAt) > Self.forceReconnectAfter {
                    self.restart()
                }
            }
        }
    }

    private func subscribe(market: PerpMarket) {
        let subs: [[String: Any]] = [
            ["stream": "heartbeat@\(chainId)", "subscribe": true],
            ["stream": "market-state@\(chainId)", "subscribe": true],
            ["stream": "order-book@\(market.id)", "subscribe": true],
            ["stream": "trades@\(market.id)", "subscribe": true],
        ]
        send(["mt": 5, "subs": subs])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive(gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.connected = true
                    self.lastMessageAt = Date()
                    self.error = nil
                    self.retry = 0
                    if case .string(let text) = message, let data = text.data(using: .utf8) { self.handle(data) }
                    else if case .data(let data) = message { self.handle(data) }
                    self.receive(gen: gen)
                case .failure(let failure):
                    self.error = failure.localizedDescription
                    // Don't drop `connected` here — the supervisor decides liveness from data recency, so a brief drop
                    // followed by a fast reconnect never flickers to "Connecting…". Just bring a fresh socket up.
                    self.scheduleReconnect(gen: gen)
                }
            }
        }
    }

    private func scheduleReconnect(gen: Int) {
        guard gen == generation, market != nil else { return }
        let delay = Self.backoff[min(retry, Self.backoff.count - 1)]
        retry += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard gen == self.generation else { return }
            self.restart()
        }
    }

    // MARK: Decoding

    /// Internal (not private) so tests can replay recorded frames.
    func handle(_ data: Data) {
        guard let market, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let mt = obj["mt"] as? Int else { return }
        let priceScale = pow(10.0, Double(market.priceDecimals))
        let sizeScale = pow(10.0, Double(market.lotDecimals))
        switch mt {
        case 15: // L2 snapshot
            book.bids = levels(obj["bid"], priceScale, sizeScale, descending: true)
            book.asks = levels(obj["ask"], priceScale, sizeScale, descending: false)
        case 16: // L2 delta
            book.bids = apply(delta: obj["bid"], to: book.bids, priceScale, sizeScale, descending: true)
            book.asks = apply(delta: obj["ask"], to: book.asks, priceScale, sizeScale, descending: false)
        case 17: // trades snapshot — replaces the tape. Every (re)subscribe sends one, and prepending it to the tape
                 // already shown doubled every recent trade after each reconnect.
            trades = Array(tradeList(obj["d"], priceScale, sizeScale).prefix(60))
        case 18: // trades update — newest first, ahead of what is already shown
            let incoming = tradeList(obj["d"], priceScale, sizeScale)
            trades = Array((incoming + trades).prefix(60))
        case 9: // market-state (all markets)
            if let d = obj["d"] as? [String: Any], let raw = d[String(market.id)] as? [String: Any] {
                state = liveState(raw, priceScale, sizeScale)
            }
        case 100: // heartbeat
            if let sn = obj["sn"] as? Int {
                if let last = lastHeartbeat, sn != last + 1 { subscribe(market: market) } // gap → resubscribe
                lastHeartbeat = sn
            }
        default: break
        }
    }

    private func levels(_ any: Any?, _ priceScale: Double, _ sizeScale: Double, descending: Bool) -> [BookLevel] {
        let raw = (any as? [[String: Any]]) ?? []
        let mapped = raw.compactMap { level -> BookLevel? in
            guard let p = num(level["p"]), let s = num(level["s"]), (level["o"] as? Int ?? 1) > 0 else { return nil }
            return BookLevel(price: p / priceScale, size: s / sizeScale, orders: level["o"] as? Int ?? 1)
        }
        return Array(mapped.sorted { descending ? $0.price > $1.price : $0.price < $1.price }.prefix(40))
    }

    /// Merge a delta into the current side: upsert changed prices, drop levels whose order count went to zero.
    private func apply(delta any: Any?, to current: [BookLevel], _ priceScale: Double, _ sizeScale: Double, descending: Bool) -> [BookLevel] {
        // Not `uniqueKeysWithValues`: a snapshot that repeats a price level would trap; the later level wins.
        var byPrice = Dictionary(current.map { ($0.price, $0) }, uniquingKeysWith: { _, last in last })
        for level in (any as? [[String: Any]]) ?? [] {
            guard let p = num(level["p"]) else { continue }
            let price = p / priceScale
            let orders = level["o"] as? Int ?? 0
            if orders <= 0 || num(level["s"]) == 0 { byPrice[price] = nil }
            else if let s = num(level["s"]) { byPrice[price] = BookLevel(price: price, size: s / sizeScale, orders: orders) }
        }
        return Array(byPrice.values.sorted { descending ? $0.price > $1.price : $0.price < $1.price }.prefix(40))
    }

    private func tradeList(_ any: Any?, _ priceScale: Double, _ sizeScale: Double) -> [PerpTrade] {
        ((any as? [[String: Any]]) ?? []).compactMap { trade in
            guard let p = num(trade["p"]), let s = num(trade["s"]) else { return nil }
            let ms = ((trade["at"] as? [String: Any])?["t"] as? Double) ?? ((trade["at"] as? [String: Any])?["t"] as? Int).map(Double.init) ?? 0
            tradeSeq += 1
            return PerpTrade(id: tradeSeq, time: Date(timeIntervalSince1970: ms / 1000), price: p / priceScale, size: s / sizeScale, side: (trade["sd"] as? Int) == 1 ? .buy : .sell)
        }
    }

    private func liveState(_ raw: [String: Any], _ priceScale: Double, _ sizeScale: Double) -> PerplLiveState {
        func p(_ k: String) -> Double { (num(raw[k]) ?? 0) / priceScale }
        return PerplLiveState(
            oracle: p("orl"), mark: p("mrk"), last: p("lst"), mid: p("mid"), bid: p("bid"), ask: p("ask"),
            prev24h: p("prv"), volume24h: (num(raw["dv"]) ?? 0) / sizeScale, openInterest: (num(raw["oi"]) ?? 0) / sizeScale
        )
    }

    private func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
