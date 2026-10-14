#if DEBUG
import Foundation

/* DEBUG builds only (never in a Release binary): the scripted Perps demo's scenarios, as data. The app's demo
   (`ios/DyorHQ/Debug/PerpsDemo.swift`, DEBUG + Simulator) feeds these frames, in process, to a real `PerplTradeClient`
   (`debugScripted()`: no socket, no key, no network) adopted by an isolated `PerplTrading`, and presents the real Perps
   sheets over it, so a simulator can show every outcome state for QA screenshots. Nothing here does I/O: a scenario is a
   prelude (what Perpl sends at sign-in), the replies Perpl gives to what the sheet writes, a few scripted events (a
   dropped socket, a dismissed sheet, Try Again), and what the chain reads back for Add Margin. Not localized: nothing
   here is ever shown to a user of a shipped build. */

public enum PerplDemoScript {
    // MARK: Fixtures

    public static let accountId = 4242
    public static let marketId = 9001
    public static let positionId = 7321764036614
    /// The trading heartbeat's first head block; one block per beat.
    public static let firstHead = 111_721_253
    /// The WalletSnapshot's `sn`: the heartbeats continue it from 1001.
    public static let snapshotSn = 1000
    public static let beatMilliseconds = 400
    /// The Perpl account's balance and locked balance in the prelude (AUSD, 6-dp units): 2,468 AUSD free.
    public static let balanceCNS = 2_500_000_000, lockedCNS = 32_000_000

    /// BTC on a market id no real screen shows.
    public static let market = PerpMarket(id: marketId, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                                          mark: 81_650, last: 81_650, oracle: 81_650, markTimestamp: 0, longOI: 0, shortOI: 0,
                                          fundingRatePct100k: 0, status: 0, initMarginFraction: 0.05, maintMarginFraction: 0.025, numOrders: 0)

    /// The account's position as the chain reads it: long 0.002 BTC at 80,000, `margin` AUSD (32 before any margin is added).
    public static func position(margin: Double = 32) -> PerpPosition {
        let size = 0.002, entry = 80_000.0, mark = market.mark
        let notional = size * mark
        return PerpPosition(perpId: marketId, symbol: "BTC", side: .long, size: size, entry: entry, mark: mark, margin: margin,
                            unrealized: (mark - entry) * size, premium: 0, leverage: 5,
                            liquidation: PerplService.liquidationPrice(side: .long, entry: entry, size: size, margin: margin, premium: 0, maintenanceFraction: market.maintMarginFraction),
                            notional: notional)
    }

    /// The account's resting order as the chain lists it: buy 0.001 BTC at 78,000 (order id 31).
    public static let chainOrder = PerpOrder(perpId: marketId, orderId: 31, symbol: "BTC", type: .openLong, side: .buy, price: 78_000, size: 0.001,
                                             leverage: 5, expiryBlock: 0, reduceOnly: false)

    // MARK: Shape

    /// What the scenario opens.
    public enum Screen: Sendable, Equatable {
        /// The order sheet (`AuthedOrderSheet`, the live outcome on) for this ticket.
        case order(Ticket)
        /// The position's Close sheet on the trading connection: the size chip, and a limit price (nil: market).
        case close(percent: Int, limitPrice: Double?, postOnly: Bool)
        /// The position's Add Margin sheet on the trading connection, with this amount typed.
        case margin(amount: String)
        /// Cancel Order for the chain order (31), which Perpl's list names by its smart contract order id.
        case cancelOrder
        /// The "Leftover TP/SL" cancel sheet over every trigger the prelude lists.
        case cancelTriggers
        /// The trade screen's cards (position, order, TP/SL) on the demo session.
        case cards
    }

    /// An order ticket: a long of 0.001 BTC at 5×.
    public struct Ticket: Sendable, Equatable {
        public let kind: OrderKind
        public let limitPrice: Double?
        public let postOnly: Bool
        public let takeProfit: Double?
        public let stopLoss: Double?

        public static let size = 0.001

        public init(kind: OrderKind, limitPrice: Double? = nil, postOnly: Bool = false, takeProfit: Double? = nil, stopLoss: Double? = nil) {
            self.kind = kind; self.limitPrice = limitPrice; self.postOnly = postOnly; self.takeProfit = takeProfit; self.stopLoss = stopLoss
        }

        public var input: OrderInput {
            OrderInput(market: PerplDemoScript.market, side: .long, kind: kind, size: Self.size, price: limitPrice, leverage: 5, postOnly: postOnly)
        }
    }

    /// Which written frame a reply answers, from its `t` / `tp` / `tpc` / `oid`.
    public enum Match: Sendable, Equatable {
        case entry, takeProfit, stopLoss, close, margin
        case cancel(oid: Int)
    }

    /// The gateway's ack (mt:3) for the frame: accepted, refused with Perpl's code and words, or never sent (unanswered).
    public enum Ack: Sendable, Equatable {
        case ok
        case refused(code: Int, error: String)
        case none
    }

    /// A frame Perpl sends `afterMs` after the write it answers.
    public struct Timed: Sendable, Equatable {
        public let afterMs: Int
        public let template: String
    }

    /// Perpl's answer to one written frame: its ack, then its reports. Each reply answers one write, in catalog order:
    /// a second write that matches takes the next reply that matches, and a write with none left is never answered.
    public struct Reply: Sendable, Equatable {
        public let match: Match
        public let ack: Ack
        public let ackAfterMs: Int
        public let frames: [Timed]
    }

    /// A scripted event. Steps run one after another, each `afterMs` after its anchor: the moment the previous step ran
    /// (or the sheet appeared), or the first write after that moment.
    public struct Step: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            /// The socket drops (`PerplTradeClient.debugDrop`).
            case drop
            /// The sheet on screen is dismissed, as a swipe would.
            case dismissSheet
            /// The order leaves Perpl's list: cancelled elsewhere.
            case removeOrder(oid: Int)
            /// The Close sheet's Try Again (its own action).
            case tryAgain
            /// A tap on the card's Cancel (the Cards screen): its real sheet opens.
            case cancelFromCard(oid: Int)
        }
        public enum Anchor: Sendable, Equatable { case start, write }
        public let action: Action
        public let anchor: Anchor
        public let afterMs: Int

        /// A second after the sheet appears: before Run's confirm (2 s), so nothing is ever written.
        public static let dropSocketBeforeWrite = Step(action: .drop, anchor: .start, afterMs: 1000)
        public static func drop(afterMs: Int) -> Step { Step(action: .drop, anchor: .write, afterMs: afterMs) }
        public static func dismissSheet(afterMs: Int) -> Step { Step(action: .dismissSheet, anchor: .write, afterMs: afterMs) }
        public static func removeOrder(oid: Int, afterMs: Int) -> Step { Step(action: .removeOrder(oid: oid), anchor: .start, afterMs: afterMs) }
        public static func tryAgain(afterMs: Int) -> Step { Step(action: .tryAgain, anchor: .write, afterMs: afterMs) }
        public static func cancelFromCard(oid: Int, afterMs: Int) -> Step { Step(action: .cancelFromCard(oid: oid), anchor: .start, afterMs: afterMs) }
    }

    /// What a chain read of the position returns from `afterMs` after the first margin write on: its margin in AUSD.
    public struct ChainRead: Sendable, Equatable {
        public let afterMs: Int
        public let margin: Double
    }

    public struct Scenario: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let screen: Screen
        /// Sent in order at the start: the WalletSnapshot (mt:19), the open orders (mt:23), the positions (mt:26). The
        /// heartbeats follow every 400 ms.
        public let prelude: [String]
        public let replies: [Reply]
        public let steps: [Step]
        public let chain: [ChainRead]
        /// What the screen shows, for QA.
        public let expected: String
        /// The account's free balance in the prelude (AUSD): Add Margin's "Available".
        public let available: Double
        /// The prelude lists the position (and the chain reads return it).
        public let hasPosition: Bool

        /// The position's margin (AUSD) a chain read returns `ms` after the first margin write (nil: before it): the last
        /// scripted read due by then, else the margin it had.
        public func chainMargin(afterWriteMs ms: Int?) -> Double {
            guard let ms else { return PerplDemoScript.marginBefore }
            return chain.last { $0.afterMs <= ms }?.margin ?? PerplDemoScript.marginBefore
        }
    }

    /// The position's margin before any is added (AUSD).
    public static let marginBefore: Double = 32

    // MARK: Matching and rendering

    /// The reply kind a written mt:22 frame takes, or nil for anything else.
    public static func match(_ frame: [String: Any]) -> Match? {
        guard frame["mt"] as? Int == 22, let t = frame["t"] as? Int else { return nil }
        switch t {
        case 6: return .margin
        case 5: return (frame["oid"] as? Int).map { .cancel(oid: $0) }
        case 3, 4:
            guard frame["tp"] != nil else { return .close }
            // Last-based (1, 2): this app's take-profit; mark-based (3, 4): its stop-loss.
            return [1, 2].contains(frame["tpc"] as? Int ?? 0) ? .takeProfit : .stopLoss
        case 1, 2: return .entry
        default: return nil
        }
    }

    /// `template` with its variables: `{rq}` / `{sn}` the answered frame's request id and sequence, `{n}` the next server
    /// sequence, `{h}` the current head block, `{now}` the time in ms. Placeholders never clash with JSON: an object key
    /// always opens `{"`.
    public static func render(_ template: String, rq: Int, sn: Int, head: Int, serverSn: Int, nowMs: Int) -> String {
        template
            .replacingOccurrences(of: "{rq}", with: String(rq))
            .replacingOccurrences(of: "{sn}", with: String(sn))
            .replacingOccurrences(of: "{n}", with: String(serverSn))
            .replacingOccurrences(of: "{h}", with: String(head))
            .replacingOccurrences(of: "{now}", with: String(nowMs))
    }

    /// The gateway's ack (mt:3) for the frame written with `sn`; nil when Perpl never answers it.
    public static func ackFrame(_ ack: Ack, sn: Int, serverSn: Int) -> String? {
        let status: [String: Any]
        switch ack {
        case .ok: status = ["code": 0, "error": ""]
        case .refused(let code, let error): status = ["code": code, "error": error]
        case .none: return nil
        }
        let frame: [String: Any] = ["mt": 3, "sid": 100, "sn": serverSn, "cid": sn, "status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func scenario(_ id: String) -> Scenario? { scenarios.first { $0.id == id } }

    /// The trading heartbeat (mt:100): sequence `sn`, head block `head`.
    public static func heartbeat(sn: Int, head: Int) -> String { #"{"mt":100,"sn":\#(sn),"h":\#(head)}"# }

    /// An order of the account leaving Perpl's list, cancelled elsewhere (the `removeOrder` step): render it like a reply.
    public static func removal(oid: Int) -> String { ord(#""oid":\#(oid),"st":5,"sr":28,"r":true"#) }

    // MARK: Frame shorthands

    /// An OrdersUpdate (mt:24) of one order of the account on the demo market, at the current head.
    static func ord(_ fields: String) -> String { #"{"mt":24,"d":["# + item(fields) + "]}" }
    /// An OrdersUpdate of several orders in one frame.
    static func ords(_ fields: [String]) -> String { #"{"mt":24,"d":["# + fields.map(item).joined(separator: ",") + "]}" }
    private static func item(_ fields: String) -> String { #"{"acc":4242,"mkt":9001,"at":{"b":{h}},"# + fields + "}" }
    /// A FillsUpdate (mt:25), as a taker.
    static func fill(_ fields: String) -> String { #"{"mt":25,"d":[{"acc":4242,"mkt":9001,"l":2,"# + fields + "}]}" }
    /// A PositionsUpdate (mt:27) of the demo position.
    static func pos(_ fields: String) -> String { #"{"mt":27,"d":[{"acc":4242,"mkt":9001,"pid":7321764036614,"sd":1,"lv":500,"# + fields + "}]}" }

    static func at(_ ms: Int, _ template: String) -> Timed { Timed(afterMs: ms, template: template) }
    /// Acknowledged 150 ms after the write, then `frames`.
    static func reply(_ match: Match, _ frames: [Timed] = []) -> Reply {
        Reply(match: match, ack: .ok, ackAfterMs: 150, frames: frames)
    }
    static func reply(_ match: Match, _ ack: Ack, _ frames: [Timed] = []) -> Reply {
        Reply(match: match, ack: ack, ackAfterMs: 150, frames: frames)
    }

    /// The chain order's live entry (rq 480, `scid` 31).
    static let restingOrder = #"{"acc":4242,"mkt":9001,"oid":31,"scid":31,"rq":480,"t":1,"st":2,"p":780000,"os":100,"fs":0,"lv":500}"#
    static func trigger(oid: Int, price: Int, tpc: Int, size: Int, linked: Bool) -> String {
        #"{"acc":4242,"mkt":9001,"oid":\#(oid),"t":3,"st":8,"p":0,"os":\#(size),"fs":0,"tp":\#(price),"tpc":\#(tpc),"lv":0"#
            + (linked ? #","lp":7321764036614"# : "") + "}"
    }

    static func prelude(orders: [String] = [restingOrder], position: Bool = true, balance: Int = balanceCNS, locked: Int = lockedCNS) -> [String] {
        let account = #"{"mt":19,"sn":1000,"as":[{"id":4242,"in":1,"fw":true,"fr":false,"ft":0,"lfr":500,"b":"\#(balance)","lb":"\#(locked)"}]}"#
        let open = #"{"mt":23,"d":["# + orders.joined(separator: ",") + "]}"
        let held = position ? #"{"acc":4242,"mkt":9001,"pid":7321764036614,"sd":1,"lv":500,"st":1,"s":200,"ep":800000,"c":"32000000"}"# : ""
        return [account, open, #"{"mt":26,"d":["# + held + "]}"]
    }

    // MARK: Order replies

    static let bracket = Ticket(kind: .market, takeProfit: 90_000, stopLoss: 75_000)
    static let marketOnly = Ticket(kind: .market)

    /// The entry filled in full (`shift` ms later than usual).
    static func filledEntry(shift: Int = 0, fee: String = "28159") -> [Timed] {
        [at(700 + shift, ord(#""rq":{rq},"oid":77,"t":1,"st":4,"sr":43,"os":100,"fs":100,"fp":816155,"f":"\#(fee)","fl":4,"lv":500,"r":true"#)),
         at(750 + shift, fill(#""oid":77,"t":1,"p":816155,"s":100,"f":"\#(fee)""#)),
         at(800 + shift, pos(#""rq":{rq},"oid":77,"st":1,"sr":17,"s":300,"ep":805385,"c":"48330000""#))]
    }
    static func armed(_ kind: Match, extra: [Timed] = []) -> Reply {
        let (oid, price, tpc) = kind == .takeProfit ? (78, 900_000, 1) : (79, 750_000, 4)
        return reply(kind, [at(500, ord(#""rq":{rq},"oid":\#(oid),"t":3,"st":8,"sr":60,"tp":\#(price),"tpc":\#(tpc),"os":100,"fl":4,"lv":0"#))] + extra)
    }
    /// Armed, then cancelled with the entry that executed nothing.
    static func armedThenCancelled(_ kind: Match) -> Reply {
        let oid = kind == .takeProfit ? 78 : 79
        return armed(kind, extra: [at(1500, ord(#""rq":{rq},"oid":\#(oid),"st":5,"sr":28,"r":true"#))])
    }
    static let notFilledEntry = reply(.entry, [at(700, ord(#""rq":{rq},"oid":77,"t":1,"st":5,"sr":16,"os":100,"fs":0,"r":true"#))])
    static let restingEntry = reply(.entry, [at(700, ord(#""rq":{rq},"oid":80,"t":1,"st":2,"sr":35,"p":800000,"os":100,"fs":0,"fl":1"#))])

    // MARK: Close replies

    /// The 100% close filled in full and Perpl reported the position closed under its request.
    static func closedInFull(shift: Int = 0) -> Reply {
        reply(.close, [at(600 + shift, ord(#""rq":{rq},"oid":90,"t":3,"st":4,"os":200,"fs":200,"fp":816100,"f":"56310","fl":4,"r":true"#)),
                       at(650 + shift, fill(#""oid":90,"t":3,"p":816100,"s":200,"f":"56310""#)),
                       at(700 + shift, pos(#""rq":{rq},"oid":90,"st":2,"sr":13,"s":0"#))])
    }
    static let closeNotFilled = reply(.close, [at(600, ord(#""rq":{rq},"oid":90,"t":3,"st":5,"sr":16,"os":200,"fs":0,"r":true"#))])

    // MARK: Margin replies

    static let marginGrown = #""rq":{rq},"st":1,"s":200,"c":"42000000""#
    static let marginRefused = reply(.margin, [at(600, ord(#""rq":{rq},"t":6,"st":7,"sr":36,"fr":2"#))])

    // MARK: Cancel replies

    static func cancelled(_ oid: Int, after ms: Int) -> Reply { reply(.cancel(oid: oid), [at(ms, removal(oid: oid))]) }

    // MARK: Catalog

    static func order(_ id: String, _ title: String, _ ticket: Ticket, _ replies: [Reply], steps: [Step] = [], expected: String) -> Scenario {
        Scenario(id: id, title: title, screen: .order(ticket), prelude: prelude(), replies: replies, steps: steps, chain: [], expected: expected,
                 available: Double(balanceCNS - lockedCNS) / 1_000_000, hasPosition: true)
    }
    static func close(_ id: String, _ title: String, percent: Int = 100, limit: Double? = nil, postOnly: Bool = false, _ replies: [Reply], steps: [Step] = [],
                      expected: String) -> Scenario {
        Scenario(id: id, title: title, screen: .close(percent: percent, limitPrice: limit, postOnly: postOnly), prelude: prelude(), replies: replies, steps: steps,
                 chain: [], expected: expected, available: Double(balanceCNS - lockedCNS) / 1_000_000, hasPosition: true)
    }
    static func margin(_ id: String, _ title: String, amount: String = "10", balance: Int = balanceCNS, _ replies: [Reply], steps: [Step] = [], chain: [ChainRead] = [],
                       expected: String) -> Scenario {
        Scenario(id: id, title: title, screen: .margin(amount: amount), prelude: prelude(balance: balance), replies: replies, steps: steps, chain: chain,
                 expected: expected, available: Double(balance - lockedCNS) / 1_000_000, hasPosition: true)
    }
    static func cancelOrder(_ id: String, _ title: String, _ replies: [Reply], steps: [Step] = [], expected: String) -> Scenario {
        Scenario(id: id, title: title, screen: .cancelOrder, prelude: prelude(), replies: replies, steps: steps, chain: [], expected: expected,
                 available: Double(balanceCNS - lockedCNS) / 1_000_000, hasPosition: true)
    }
    static func cards(_ id: String, _ title: String, _ replies: [Reply], steps: [Step] = [], expected: String) -> Scenario {
        let orders = [restingOrder, trigger(oid: 50, price: 900_000, tpc: 1, size: 200, linked: true), trigger(oid: 51, price: 750_000, tpc: 4, size: 200, linked: true)]
        return Scenario(id: id, title: title, screen: .cards, prelude: prelude(orders: orders), replies: replies, steps: steps, chain: [], expected: expected,
                        available: Double(balanceCNS - lockedCNS) / 1_000_000, hasPosition: true)
    }

    // swiftlint:disable line_length
    public static let scenarios: [Scenario] = [
        // Orders
        order("order-filled", "Market long + TP/SL: filled", bracket, [reply(.entry, filledEntry()), armed(.takeProfit), armed(.stopLoss)],
              expected: "Filled 0.001 BTC at 81,615.5 · fee; take-profit set at 90,000 and stop-loss set at 75,000, closing 0.001 BTC"),
        order("order-rebate", "Market long + TP/SL: filled, maker rebate", bracket, [reply(.entry, filledEntry(fee: "-1200")), armed(.takeProfit), armed(.stopLoss)],
              expected: "Filled … · rebate $0.0012"),
        order("order-partly-filled", "Market long + TP/SL: partly filled", bracket,
              [reply(.entry, [at(700, ord(#""rq":{rq},"oid":77,"t":1,"st":5,"sr":16,"os":100,"fs":40,"fp":816200,"f":"11263","r":true"#)),
                              at(750, fill(#""oid":77,"t":1,"p":816200,"s":40,"f":"11263""#))]),
               armed(.takeProfit), armed(.stopLoss)],
              expected: "Partly filled 0.0004 of 0.001; the rest was cancelled within your 1% slippage"),
        order("order-partly-resting", "Limit long at 81,700: partly filled, rest resting", Ticket(kind: .limit, limitPrice: 81_700),
              [reply(.entry, [at(700, ord(#""rq":{rq},"oid":81,"t":1,"st":3,"p":817000,"os":100,"fs":40,"fp":817000"#)),
                              at(750, fill(#""oid":81,"t":1,"p":817000,"s":40,"f":"11268""#))])],
              expected: "Partly filled 0.0004 of 0.001 at 81,700.0; the rest is resting on the book at 81,700.0"),
        order("order-resting", "Post-only limit at 80,000 + TP/SL: resting", Ticket(kind: .limit, limitPrice: 80_000, postOnly: true, takeProfit: 90_000, stopLoss: 75_000),
              [restingEntry, armed(.takeProfit), armed(.stopLoss)],
              expected: "Resting on the book at 80,000.0; take-profit and stop-loss accepted, active when the order fills"),
        order("order-cancelled-elsewhere", "Limit at 80,000: resting, then cancelled elsewhere", Ticket(kind: .limit, limitPrice: 80_000),
              [reply(.entry, [at(700, ord(#""rq":{rq},"oid":80,"t":1,"st":2,"sr":35,"p":800000,"os":100,"fs":0,"fl":1"#)),
                              at(4000, ord(#""oid":80,"st":5,"sr":28,"r":true"#))])],
              expected: "Resting…, then Order cancelled: it was cancelled before it filled"),
        order("order-expired", "Limit at 80,000: expired", Ticket(kind: .limit, limitPrice: 80_000),
              [reply(.entry, [at(900, ord(#""rq":{rq},"oid":80,"t":1,"st":6,"os":100,"fs":0,"r":true"#))])],
              expected: "Order expired: it expired before it filled, so nothing was opened"),
        order("order-not-filled", "Market long + TP/SL: not filled", bracket, [notFilledEntry, armedThenCancelled(.takeProfit), armedThenCancelled(.stopLoss)],
              expected: "Not filled (1% slippage); still in the ticket; after the 3 s check its TP/SL were cancelled with it"),
        order("order-not-filled-leftovers", "Not filled, TP/SL left armed", bracket,
              [notFilledEntry, armed(.takeProfit), armed(.stopLoss), cancelled(78, after: 1200), cancelled(79, after: 1200)],
              expected: "Not filled; its TP/SL are still armed with Cancel Them (the Leftover TP/SL sheet cancels them)"),
        order("order-may-be-armed", "Not filled, socket drops before the TP/SL check", bracket, [notFilledEntry, armed(.takeProfit), armed(.stopLoss)],
              steps: [.drop(afterMs: 1200)],
              expected: "Not filled; its TP/SL may still be armed (no live list could rule them out)"),
        order("order-failed", "Market long + TP/SL: failed", bracket,
              [reply(.entry, [at(600, ord(#""rq":{rq},"t":1,"st":7,"sr":44,"fr":1"#))]), armedThenCancelled(.takeProfit), armedThenCancelled(.stopLoss)],
              expected: "Order failed: there isn't enough available margin on your Perpl account for this order"),
        order("order-refused", "Market long: refused at the gateway", marketOnly,
              [reply(.entry, .refused(code: 400, error: "last exec block already expired"))],
              expected: "Back to review with Perpl's error; nothing followed"),
        order("order-provisional-then-filled", "Market long: provisional failure, then filled", marketOnly,
              [reply(.entry, [at(500, ord(#""rq":{rq},"t":1,"st":7,"sr":15"#))] + filledEntry(shift: 2800))],
              expected: "Perpl reported a problem, waiting for its final answer; then Filled"),
        order("order-unconfirmed", "Market long: acknowledged, never reported", marketOnly, [reply(.entry)],
              expected: "Waiting…, then after ~10 s Result not confirmed yet"),
        order("order-unanswered", "Market long + TP/SL: never acknowledged", bracket, [reply(.entry, .none)],
              expected: "Still listening for Perpl… (after the 8 s ack timeout), then unconfirmed: TP/SL not sent"),
        order("order-foreign", "Market long: another order reported under its request", marketOnly,
              [reply(.entry, [at(700, ord(#""rq":{rq},"oid":77,"t":2,"st":4,"os":100,"fs":100"#))])],
              expected: "Result not confirmed yet: Perpl reported a different order under this request"),
        order("order-tpsl-at-once", "Filled; the stop-loss triggers at once", bracket,
              [reply(.entry, filledEntry()), armed(.takeProfit),
               // Admitted and triggered in one update, inside the stop-loss's own wait.
               reply(.stopLoss, [at(400, ords([#""rq":{rq},"oid":79,"t":3,"st":8,"sr":60,"tp":750000,"tpc":4,"os":100,"fl":4,"lv":0"#,
                                                #""rq":{rq},"oid":79,"st":9,"sr":54"#]))])],
              expected: "Filled; the stop-loss at 75,000 triggered at once"),
        order("order-tp-cap", "Filled; the take-profit is refused (open-order cap)", bracket,
              [reply(.entry, filledEntry()), reply(.takeProfit, [at(500, ord(#""rq":{rq},"oid":78,"t":3,"st":7,"sr":24"#))]), armed(.stopLoss)],
              expected: "Take-profit not placed: your account has the most open orders Perpl allows (at the deadline)"),
        order("order-tp-not-listed", "Filled; the take-profit is acknowledged, never listed", bracket,
              [reply(.entry, filledEntry()), reply(.takeProfit), armed(.stopLoss)],
              expected: "The take-profit line says Perpl hasn't listed it yet"),
        order("order-tp-refused-ack", "Filled; the take-profit is refused at the gateway", bracket,
              [reply(.entry, filledEntry()), reply(.takeProfit, .refused(code: 400, error: "trigger price invalid")), armed(.stopLoss)],
              expected: "The refused-trigger warning"),
        order("order-triggered-later", "Filled; the stop-loss triggers 6 s later", bracket,
              [reply(.entry, filledEntry()), armed(.takeProfit), armed(.stopLoss, extra: [at(6000, ord(#""oid":79,"st":9,"sr":54"#))])],
              expected: "The stop-loss line flips to triggered"),
        order("order-cancelled-later", "Filled; the take-profit is cancelled 6 s later", bracket,
              [reply(.entry, filledEntry()), armed(.takeProfit, extra: [at(6000, ord(#""oid":78,"st":5,"sr":28,"r":true"#))]), armed(.stopLoss)],
              expected: "The take-profit line flips to cancelled later"),
        order("status-row", "Filled after the sheet is closed: the status row", bracket,
              [reply(.entry, filledEntry(shift: 3000)), armed(.takeProfit), armed(.stopLoss)], steps: [.dismissSheet(afterMs: 1000)],
              expected: "Status row: Waiting for Perpl…, then filled (leaves after 8 s); Would notify: Order filled · Long BTC-PERP"),

        // TP/SL cancels
        Scenario(id: "cancel-tpsl-mixed", title: "Leftover TP/SL: six cancels, six endings", screen: .cancelTriggers,
                 prelude: prelude(orders: [trigger(oid: 40, price: 900_000, tpc: 1, size: 100, linked: false), trigger(oid: 41, price: 750_000, tpc: 4, size: 100, linked: false),
                                           trigger(oid: 42, price: 910_000, tpc: 1, size: 100, linked: false), trigger(oid: 43, price: 740_000, tpc: 4, size: 100, linked: false),
                                           trigger(oid: 44, price: 920_000, tpc: 1, size: 100, linked: false), trigger(oid: 45, price: 730_000, tpc: 4, size: 100, linked: false)],
                                  position: false),
                 replies: [cancelled(40, after: 1200),
                           reply(.cancel(oid: 41), [at(800, ord(#""rq":{rq},"oid":41,"t":5,"st":7,"sr":45"#))]),
                           reply(.cancel(oid: 42), [at(600, ord(#""oid":42,"st":9,"sr":54"#)), at(1500, ord(#""oid":42,"st":10,"sr":65,"r":true"#))]),
                           reply(.cancel(oid: 43)),
                           reply(.cancel(oid: 44), [at(50, ord(#""oid":44,"st":7,"sr":33,"r":true"#))]),
                           reply(.cancel(oid: 45), [at(900, ord(#""oid":45,"st":6,"r":true"#))])],
                 steps: [], chain: [],
                 expected: "Cancelling…, then Cancelled / Still live (Try Again) / Triggered first / Not confirmed after 10 s (Try Again) / Already gone / Expired first; Cancelled 1 TP/SL",
                 available: 0, hasPosition: false),

        // Closes
        close("close-market-filled", "Close 100% at market: closed", [closedInFull()],
              expected: "Closed 0.002 BTC at 81,610.0 · fee; Would notify: Closed BTC · BTC-PERP long"),
        close("close-partial-25", "Close 25% at market", percent: 25,
              [reply(.close, [at(600, ord(#""rq":{rq},"oid":90,"t":3,"st":4,"os":50,"fs":50,"fp":816100,"f":"14078","fl":4,"r":true"#)),
                              at(650, fill(#""oid":90,"t":3,"p":816100,"s":50,"f":"14078""#)),
                              at(700, pos(#""rq":{rq},"oid":90,"st":1,"s":150"#))])],
              expected: "Closed 0.0005 BTC at 81,610.0; Would notify: Partly closed BTC"),
        close("close-market-partly", "Close 100% at market: partly closed", [reply(.close, [at(600, ord(#""rq":{rq},"oid":90,"t":3,"st":5,"sr":16,"os":200,"fs":120,"fp":816050,"r":true"#))])],
              expected: "Partly closed 0.0012 of 0.002; the rest wasn't filled within 1%"),
        close("close-market-not-filled", "Close 100% at market: not closed", [closeNotFilled],
              expected: "Not closed: nothing on the order book within 1%; Try Again"),
        close("close-not-filled-try-again", "Not closed, Try Again, closed", [closeNotFilled, closedInFull()], steps: [.tryAgain(afterMs: 1500)],
              expected: "Not closed, Try Again, then Closed 0.002 BTC"),
        close("close-failed", "Close 100%: failed (negative value)", [reply(.close, [at(600, ord(#""rq":{rq},"t":3,"st":7,"sr":44,"fr":6"#))])],
              expected: "Not closed: closing at this price would leave the position with a negative value; Try Again"),
        close("close-refused-gateway", "Close 100%: refused at the gateway", [reply(.close, .refused(code: 400, error: "bad request"))],
              expected: "The error, and: Nothing was sent. Close this and try again: it will be sent from your wallet."),
        close("close-socket-drop", "Close 100%: the socket drops before the confirm", [], steps: [.dropSocketBeforeWrite],
              expected: "Not connected to Perpl trading. Nothing was sent. Close this and try again."),
        close("close-limit-resting", "Post-only limit close at 82,000: resting", limit: 82_000, postOnly: true,
              [reply(.close, [at(600, ord(#""rq":{rq},"oid":91,"t":3,"st":2,"sr":35,"p":820000,"os":200,"fs":0,"fl":1"#))])],
              expected: "Close order resting on the book at 82,000.0"),
        close("close-unconfirmed", "Close 100%: acknowledged, never reported", [reply(.close)],
              expected: "Result not confirmed yet, with the close's own detail"),
        close("close-unanswered", "Close 100%: never acknowledged", [reply(.close, .none)],
              expected: "Still listening for Perpl…, then unconfirmed: close status unknown, check Positions"),
        close("close-status-row", "Closed after the sheet is closed: the status row", [closedInFull(shift: 3000)], steps: [.dismissSheet(afterMs: 1000)],
              expected: "Status row titled Close BTC: waiting, then Closed; Would notify: Closed BTC · BTC-PERP long"),

        // Margin
        margin("margin-added", "Add 10 AUSD: added", [reply(.margin, [at(600, ord(#""rq":{rq},"t":6,"st":10"#)), at(700, pos(marginGrown))])],
               expected: "Added 10 AUSD margin."),
        margin("margin-added-position-only", "Add 10 AUSD: the position's collateral grows", [reply(.margin, [at(700, pos(marginGrown))])],
               expected: "Added 10 AUSD margin."),
        margin("margin-st5-then-position", "Add 10 AUSD: st 5, then the collateral grows", [reply(.margin, [at(500, ord(#""rq":{rq},"t":6,"st":5"#)), at(900, pos(marginGrown))])],
               expected: "Waiting…, then Added 10 AUSD margin."),
        margin("margin-st5-only", "Add 10 AUSD: st 5 only, the chain unchanged", [reply(.margin, [at(500, ord(#""rq":{rq},"t":6,"st":5"#))])],
               expected: "Margin not confirmed yet (after 10 s)"),
        margin("margin-chain-only", "Add 10 AUSD: only the chain shows it", [reply(.margin)], chain: [ChainRead(afterMs: 1500, margin: 42)],
               expected: "Added 10 AUSD margin. (at the 2 s chain read)"),
        margin("margin-growth-without-rq", "Add 10 AUSD: growth reported without its request", [reply(.margin, [at(800, pos(#""st":1,"s":200,"c":"42000000""#))])],
               expected: "Added 10 AUSD margin."),
        margin("margin-refused", "Add 10 AUSD: refused", [marginRefused],
               expected: "Margin not added: there isn't enough available margin to add to this position"),
        margin("margin-provisional-then-added", "Add 10 AUSD: provisional failure, then added",
               [reply(.margin, [at(500, ord(#""rq":{rq},"t":6,"st":7,"sr":15"#)), at(3000, pos(marginGrown))])],
               expected: "Waiting…, then Added 10 AUSD margin."),
        margin("margin-refused-gateway", "Add 10 AUSD: refused at the gateway", [reply(.margin, .refused(code: 400, error: "bad request"))],
               expected: "Margin not added (Perpl's words), and the wallet fallback line"),
        margin("margin-unanswered", "Add 10 AUSD: never acknowledged", [reply(.margin, .none)],
               expected: "Still listening, then Margin not confirmed yet"),
        margin("margin-unconfirmed", "Add 10 AUSD: acknowledged, never reported", [reply(.margin)],
               expected: "Margin not confirmed yet (after 10 s)"),
        margin("margin-zero", "Add 0.0000001 AUSD: rounds to zero", amount: "0.0000001", [],
               expected: "The margin amount rounds to zero; nothing written"),
        margin("margin-over-available", "Add 30 AUSD with 18 AUSD free", amount: "30", balance: 50_000_000, [],
               expected: "The over-available refusal; nothing written"),
        margin("margin-dismissed", "Add 10 AUSD: refused after the sheet is closed",
               [reply(.margin, [at(2000, ord(#""rq":{rq},"t":6,"st":7,"sr":36,"fr":2"#))])], steps: [.dismissSheet(afterMs: 300)],
               expected: "Would notify: Margin not added · There isn't enough available margin to add to this position."),
        margin("margin-dismissed-unconfirmed", "Add 10 AUSD: not confirmed after the sheet is closed", [reply(.margin)], steps: [.dismissSheet(afterMs: 300)],
               expected: "Would notify (at 10 s): Margin not confirmed yet · Check the position's margin before adding more"),

        // Cancel order
        cancelOrder("cancel-order-cancelled", "Cancel the resting order: cancelled", [cancelled(31, after: 900)],
                    expected: "Cancelling…, then Cancelled: the order was cancelled"),
        cancelOrder("cancel-order-filled-first", "Cancel: the order filled first", [reply(.cancel(oid: 31), [at(700, ord(#""oid":31,"st":4,"fs":100,"r":true"#))])],
                    expected: "Filled first"),
        cancelOrder("cancel-order-expired-first", "Cancel: the order expired first", [reply(.cancel(oid: 31), [at(700, ord(#""oid":31,"st":6,"r":true"#))])],
                    expected: "Expired first: the order had already expired"),
        cancelOrder("cancel-order-still-live", "Cancel refused: still live", [reply(.cancel(oid: 31), [at(600, ord(#""rq":{rq},"oid":31,"t":5,"st":7,"sr":36"#))])],
                    expected: "Still live, with the reason and Try Again"),
        cancelOrder("cancel-order-generic-refusal", "Cancel refused without a reason", [reply(.cancel(oid: 31), [at(600, ord(#""rq":{rq},"oid":31,"t":5,"st":7,"sr":45"#))])],
                    expected: "Perpl couldn't cancel the order. It is still live. Try Again"),
        cancelOrder("cancel-order-refused-ack", "Cancel refused at the gateway", [reply(.cancel(oid: 31), .refused(code: 403, error: "read-scoped key"))],
                    expected: "Still live, Perpl's words, and the wallet fallback line"),
        cancelOrder("cancel-order-already-gone", "Cancel: the order left the list first", [], steps: [.removeOrder(oid: 31, afterMs: 0)],
                    expected: "Already gone: the order was already gone (nothing sent)"),
        cancelOrder("cancel-order-not-confirmed", "Cancel: acknowledged, never confirmed", [reply(.cancel(oid: 31))],
                    expected: "Not confirmed (after 10 s), with Try Again"),

        // Cards
        cards("cards", "The trade screen's cards", [], expected: "Position (with its TP/SL), the resting order and the TP/SL cards"),
        cards("cards-cancelling", "Cards: an order and a TP/SL cancelling", [reply(.cancel(oid: 31)), reply(.cancel(oid: 51))],
              steps: [.cancelFromCard(oid: 31, afterMs: 300), .dismissSheet(afterMs: 1500), .cancelFromCard(oid: 51, afterMs: 800), .dismissSheet(afterMs: 1500)],
              expected: "The order card and the stop-loss card both Cancelling…"),
        cards("cards-order-gone", "Cards: the order cancelled from its card", [cancelled(31, after: 900)],
              steps: [.cancelFromCard(oid: 31, afterMs: 300), .dismissSheet(afterMs: 2500)],
              expected: "The order card says Cancelled, with no Cancel"),
    ]
    // swiftlint:enable line_length
}
#endif
