import BigInt
import Foundation

/// The rules behind Home's "Add funds to start trading" card for a new passkey account (MERA-PLAN §4). DyorHQ sponsors
/// no network fees, so a new account's first transaction waits for a deposit. The card shows the address and a QR code
/// and watches the balance. When a deposit lands it says "Funds arrived", then offers the first trade. Only an empty
/// account sees it: one with activity, or real funds from the start, never does, and the card goes once the account acts.
public enum FirstFunding {
    /// How often the card reads the balance while it is on screen and the app is active.
    public static let pollInterval: Duration = .seconds(4)
    /// How long "Funds arrived" shows before the trade is offered. Monad lets an account spend a deposit only once it
    /// is 3 blocks old (~1.2 s at 0.4 s blocks).
    public static let arrivalPause: TimeInterval = 1.5
    /// MON under this is dust: 0.001 MON.
    public static let monDust = BigUInt(10).power(15)
    /// A token worth less than this, in dollars, is dust.
    public static let usdDust = 0.01
    /// Below this much MON the first trade can't pay its network fees (Monad charges a transaction's whole fee limit up
    /// front), so the card asks for a little MON before it offers the trade: 0.1 MON, the "about 0.1 MON" its copy asks
    /// for. At Monad's usual fees it covers what Swap's Max keeps back for the swap (300k gas × 202 gwei × 5/4 ≈ 0.076
    /// MON) plus a token-in trade's approvals, and leaves something to trade.
    public static let feeFloor = BigUInt(10).power(17)

    /// The first trade the card offers: what arrived, swapped for MON (or MON for USDC).
    public struct Trade: Equatable, Sendable {
        public let pay: Token
        public let receive: Token
        /// The account's balance of `pay`.
        public let amount: BigUInt
        /// Too little MON for the network fee: the trade can't send until more arrives.
        public let needsMON: Bool

        public init(pay: Token, receive: Token, amount: BigUInt, needsMON: Bool) {
            self.pay = pay
            self.receive = receive
            self.amount = amount
            self.needsMON = needsMON
        }
    }

    public enum Phase: Equatable, Sendable {
        /// Not read yet. Nothing shows.
        case checking
        /// Empty and unused: "Add funds to start trading", watching the balance.
        case addFunds
        /// A deposit just landed: "Funds arrived" until `since + arrivalPause`.
        case arrived(Trade, since: Date)
        /// "Make your first trade".
        case firstTrade(Trade)
        /// The account has activity, had funds from the start, or the card was closed. Nothing shows or polls.
        case done

        public var isVisible: Bool {
            switch self {
            case .addFunds, .arrived, .firstTrade: return true
            case .checking, .done: return false
            }
        }

        /// Whether the balance watch keeps running.
        public var isWatching: Bool { self != .done }
    }

    /// One read of the account.
    public struct Snapshot: Sendable {
        /// Balances by token address (`Monad.native` for MON). A missing entry reads as zero.
        public var balances: [Address: BigUInt]
        /// The tokens `balances` covers: the account's known universe.
        public var tokens: [Token]
        /// Dollar price per whole token, where known.
        public var prices: [Address: Double]
        /// Transactions the account has sent on Monad (pending included), when it was read.
        public var nonce: UInt64?
        /// Other signs the account is in use: the app's own activity for it, launch coins, Moments, Perpl equity.
        public var hasHistory: Bool

        public init(balances: [Address: BigUInt], tokens: [Token], prices: [Address: Double] = [:], nonce: UInt64? = nil, hasHistory: Bool = false) {
            self.balances = balances
            self.tokens = tokens
            self.prices = prices
            self.nonce = nonce
            self.hasHistory = hasHistory
        }

        var mon: BigUInt { balances[Monad.native] ?? 0 }
    }

    /// Whether `amount` of `token` counts as funds rather than dust. MON counts from 0.001. A priced token counts from
    /// $0.01. An unpriced one counts only if it is a curated token, so an airdropped token can't pass for a deposit.
    public static func isFunds(_ amount: BigUInt, of token: Token, usd: Double?) -> Bool {
        guard amount > 0 else { return false }
        if token.isNative { return amount >= monDust }
        if let usd { return Amount.units(amount, decimals: token.decimals) * usd >= usdDust }
        return Token.core.contains { $0.address == token.address }
    }

    /// The funded tokens in `snapshot`, MON first, then in the order the snapshot lists them.
    static func funded(_ snapshot: Snapshot) -> [Token] {
        ([Token.mon] + snapshot.tokens.filter { !$0.isNative })
            .filter { isFunds(snapshot.balances[$0.address] ?? 0, of: $0, usd: snapshot.prices[$0.address]) }
    }

    public static func hasFunds(_ snapshot: Snapshot) -> Bool { !funded(snapshot).isEmpty }

    /// The first trade for these balances. MON pays for USDC when the account holds MON. Otherwise USDC pays for MON,
    /// and failing that the first funded curated token, then any funded token. WMON pays for USDC, not MON, since
    /// WMON to MON would be an unwrap rather than a trade.
    public static func trade(for snapshot: Snapshot) -> Trade {
        let funded = funded(snapshot).filter(SwapEngine.isTradable)
        let curated = Token.core.filter { token in funded.contains { $0.address == token.address } }
        let pay = funded.first(where: \.isNative)
            ?? funded.first { $0.address == Monad.usdc }
            ?? curated.first
            ?? funded.first
            ?? .mon
        return trade(paying: pay, receiving: pay.isNative || pay.address == Monad.wmon ? .usdc : .mon, in: snapshot)
    }

    static func trade(paying pay: Token, receiving receive: Token, in snapshot: Snapshot) -> Trade {
        Trade(pay: pay, receive: receive, amount: snapshot.balances[pay.address] ?? 0, needsMON: snapshot.mon < feeFloor)
    }

    /// The card's next phase after a read (`reading` is nil when the read failed) at `now`.
    /// - Activity (a sent transaction or other history) ends it from any phase.
    /// - The first read decides: an empty account gets "Add funds", a funded one never sees the card.
    /// - A deposit turns "Add funds" into "Funds arrived", which becomes "Make your first trade" after `arrivalPause`,
    ///   even when that read failed.
    /// - The first trade keeps the pair it was offered with and updates its amount and the MON check.
    /// - The card never goes back. A read that shows funds gone without any transaction is a lagging node, not a
    ///   withdrawal.
    public static func next(after phase: Phase, reading: Snapshot?, now: Date) -> Phase {
        if phase == .done { return .done }
        if let reading, reading.hasHistory || (reading.nonce ?? 0) > 0 { return .done }
        let isFunded = reading.map(hasFunds) ?? false
        switch phase {
        case .checking:
            guard reading != nil else { return .checking }
            return isFunded ? .done : .addFunds
        case .addFunds:
            guard let reading, isFunded else { return .addFunds }
            return .arrived(trade(for: reading), since: now)
        case .arrived(let offered, let since):
            var current = offered
            if let reading, isFunded { current = trade(paying: offered.pay, receiving: offered.receive, in: reading) }
            return now.timeIntervalSince(since) >= arrivalPause ? .firstTrade(current) : .arrived(current, since: since)
        case .firstTrade(let offered):
            guard let reading, isFunded else { return .firstTrade(offered) }
            return .firstTrade(trade(paying: offered.pay, receiving: offered.receive, in: reading))
        case .done:
            return .done
        }
    }
}
