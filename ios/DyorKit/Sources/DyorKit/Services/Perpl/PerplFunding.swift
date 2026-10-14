import Foundation

/// Perpl funding, as the exchange defines it (docs.perpl.xyz/exchange/funding): the rate is the sum over the interval
/// of the impact-price premium vs the oracle, clamped, and it settles every `blocksPerInterval` blocks. A positive rate
/// means long positions pay short positions; a negative one, the reverse. Positions carry it as `premium` (the
/// contract's `premiumPnlCNS`) until they settle. How long an interval lasts is Perpl's own figure from its market
/// context (`MarketContext.fundingIntervalSeconds` over `fundingIntervalBlocks`: 2,580 s per 8,571 blocks on
/// 2026-09-08), never an assumed block time.
public enum PerplFunding {
    /// Funding settles every 8 571 blocks, the schedule a market's context doesn't name its own.
    public static let blocksPerInterval: UInt64 = 8_571
    public static let hoursPerYear = 24.0 * 365.0

    /// `fundingRatePct100k` (contract, parts per 100 000) → fraction of notional per interval.
    public static func hourlyRate(pct100k: Int) -> Double { Double(pct100k) / 100_000 }
    /// Gateway `funding.rate` (parts per million) → fraction of notional per interval.
    public static func hourlyRate(ppm: Double) -> Double { ppm / 1_000_000 }

    /// Simple (non-compounded) annualization of an hourly rate.
    public static func annualized(hourly: Double) -> Double { hourly * hoursPerYear }
    public static func daily(hourly: Double) -> Double { hourly * 24 }

    /// Who pays whom at this rate. Zero is a wash.
    public enum Direction: Sendable, Hashable {
        case longsPayShorts, shortsPayLongs, flat
        public var summary: String {
            switch self {
            case .longsPayShorts: return L10n.string(LocalizedStringResource("Longs pay shorts", bundle: L10n.kit, comment: "Perps funding: holders of long positions pay holders of short ones."))
            case .shortsPayLongs: return L10n.string(LocalizedStringResource("Shorts pay longs", bundle: L10n.kit, comment: "Perps funding: holders of short positions pay holders of long ones."))
            case .flat: return L10n.string(LocalizedStringResource("No funding", bundle: L10n.kit, comment: "Perps funding: the rate is zero, so nobody pays."))
            }
        }
    }

    public static func direction(hourly: Double) -> Direction {
        if hourly > 0 { return .longsPayShorts }
        if hourly < 0 { return .shortsPayLongs }
        return .flat
    }

    /// Funding earned (positive) or paid (negative) by a SHORT of `notional` over `hours` at a constant hourly rate.
    public static func shortIncome(notional: Double, hourly: Double, hours: Double) -> Double { notional * hourly * hours }

    /// The next settlement block on the market's schedule of an interval every `intervalBlocks` blocks (the first
    /// boundary strictly after `head`).
    public static func nextSettlementBlock(startBlock: UInt64, head: UInt64, intervalBlocks: UInt64 = blocksPerInterval) -> UInt64 {
        let interval = max(1, intervalBlocks)
        guard head >= startBlock, startBlock > 0 else { return head + interval }
        let elapsed = head - startBlock
        let periods = elapsed / interval + 1
        return startBlock + periods * interval
    }

    /// Seconds until the next settlement, from the head block and the market's own interval in Perpl's context: the
    /// blocks left on its schedule, at `intervalSeconds` per `intervalBlocks`. Nil when the context reported no interval,
    /// so the countdown is left out rather than guessed.
    public static func secondsToNextSettlement(startBlock: UInt64, head: UInt64, intervalSeconds: Int, intervalBlocks: Int) -> Double? {
        guard intervalSeconds > 0, intervalBlocks > 0 else { return nil }
        let blocks = UInt64(intervalBlocks)
        let left = nextSettlementBlock(startBlock: startBlock, head: head, intervalBlocks: blocks) - head
        return Double(left) * Double(intervalSeconds) / Double(blocks)
    }

    /// `secondsToNextSettlement` with the interval of `context`, the market's entry in Perpl's context.
    public static func secondsToNextSettlement(startBlock: UInt64, head: UInt64, context: MarketContext) -> Double? {
        secondsToNextSettlement(startBlock: startBlock, head: head, intervalSeconds: context.fundingIntervalSeconds, intervalBlocks: context.fundingIntervalBlocks)
    }

    /// Hours a short must be held for funding to pay back `totalCost` at a constant hourly rate; nil when the rate
    /// is not positive (funding is being paid, not earned).
    public static func breakevenHours(totalCost: Double, notional: Double, hourly: Double) -> Double? {
        let perHour = notional * hourly
        guard perHour > 0, totalCost >= 0 else { return nil }
        return totalCost / perHour
    }
}
