import Foundation

/// Stellar's minimum balance, and what an account can spend and send (docs/DESIGN-stellar-parity.md §4.5). The server
/// works out the same figures (`_shared/fees.ts`); the phone recomputes them from the parts it is sent, so it never
/// trusts a total or hard-codes a reserve. Every amount is in stroops.
///
///     minBalance = max(0, 2 + subentries + sponsoring − sponsored) × baseReserve
///     spendable  = max(0, balance − minBalance − sellingLiabilities)
///     maxSend    = max(0, spendable − feeEstimate × 5/4 − newReserves × baseReserve)
public struct XLMReserve: Equatable, Sendable {
    public let balance: Int64
    /// The ledger's base reserve (0.5 XLM today), from the ledger header: never assumed.
    public let baseReserve: Int64
    /// Trustlines, offers, data entries and signers.
    public let subentries: Int
    /// Reserves this account pays for others.
    public let sponsoring: Int
    /// Reserves others pay for this account (DyorHQ's sponsored setup on mainnet).
    public let sponsored: Int
    /// XLM held by the account's open offers.
    public let sellingLiabilities: Int64

    public init(balance: Int64, baseReserve: Int64, subentries: Int = 0, sponsoring: Int = 0, sponsored: Int = 0, sellingLiabilities: Int64 = 0) {
        self.balance = balance
        self.baseReserve = baseReserve
        self.subentries = subentries
        self.sponsoring = sponsoring
        self.sponsored = sponsored
        self.sellingLiabilities = sellingLiabilities
    }

    /// What Stellar keeps in the account for it to stay open.
    public var minBalance: Int64 {
        let count = Int64(2).addingSaturated(Int64(subentries)).addingSaturated(Int64(sponsoring)).subtractingSaturated(Int64(sponsored))
        return Self.reserves(count, of: baseReserve)
    }

    /// What can leave the account.
    public var spendable: Int64 {
        max(0, balance.subtractingSaturated(minBalance).subtractingSaturated(sellingLiabilities))
    }

    /// The most XLM an action can send and still pay its own fee and hold the reserves it adds: Max on an XLM amount.
    /// `feeEstimate` is the step's estimate (or, with the review open, the built step's real fee), kept with a quarter
    /// more; `newReserves` is what the plan's new trustlines hold back.
    public func maxSend(feeEstimate: Int64, newReserves: Int = 0) -> Int64 {
        let fee = max(0, feeEstimate).multipliedSaturated(by: 5) / 4
        return max(0, spendable.subtractingSaturated(fee).subtractingSaturated(reserves(newReserves)))
    }

    /// What `count` base reserves hold back.
    public func reserves(_ count: Int) -> Int64 {
        Self.reserves(Int64(count), of: baseReserve)
    }

    private static func reserves(_ count: Int64, of baseReserve: Int64) -> Int64 {
        max(0, count).multipliedSaturated(by: max(0, baseReserve))
    }
}

private extension Int64 {
    func addingSaturated(_ other: Int64) -> Int64 {
        let (v, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : v
    }

    func subtractingSaturated(_ other: Int64) -> Int64 {
        let (v, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : v
    }

    func multipliedSaturated(by other: Int64) -> Int64 {
        let (v, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : v
    }
}
