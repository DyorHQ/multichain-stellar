import Foundation
import StellarKit

/// What a step of each kind may cost, in stroops, when `/v1/fees` has no history for it (docs/DESIGN-stellar-parity.md
/// §6.3): the server's defaults, shipped here too, so Max and the setup's price work before the fees are read.
public enum StellarFeeDefaults {
    public static let estimates: [String: Int64] = [
        "payment": 10_000, "payment_token": 300_000, "trust": 10_000, "restore": 500_000,
        "swap_sdex": 10_000, "swap_soroswap": 500_000, "swap_aquarius": 500_000,
        "blend_submit_deposit": 5_000_000, "blend_submit_withdraw": 500_000,
        "launch_create": 10_000_000, "launch_buy": 500_000, "launch_sell": 500_000, "launch_graduate": 15_000_000,
        "launch_claim": 500_000, "moment_publish": 3_000_000, "moment_collect": 10_000_000,
        "token_approve": 300_000, "cctp_burn": 500_000,
    ]

    public static func estimate(_ stepKind: String) -> Int64? { estimates[stepKind] }
}

/// What the review's "Max network fee" row says (§4.6), mirroring Monad's `FeePreview.summary`: up to the fees of the
/// steps built so far, plus how many of the user's steps can only be priced as they are signed; or that DyorHQ pays,
/// when the phone checked it (§4.3) and the user pays no step.
public struct StellarFeeSummary: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        /// "Up to %@": every one of the user's steps is built; their fees together, in stroops.
        case upTo(stroops: Int64)
        /// "Up to %@ + %lld more steps": some are built (`stroops`), `steps` more are priced as they are signed.
        case upToAndMore(stroops: Int64, steps: Int)
        /// "Priced as each step is signed": none of the user's steps is built yet.
        case pricedAsSigned
        /// DyorHQ pays every step, as checked on the phone: the review's sponsored row (§4.6).
        case paidByDyorHQ
    }

    public let value: Value
    /// Why DyorHQ pays a step, for the row's footer ("DyorHQ pays this one: your account's setup."); nil when the user
    /// pays every step.
    public let sponsorReason: StellarSponsorReason?

    public init(_ fees: PlanFees) {
        let mine = fees.steps.filter { $0.payer == .user }
        let built = mine.filter(\.built)
        let unbuilt = mine.count - built.count
        let stroops = built.reduce(Int64(0)) { $0 + $1.maxFee }
        sponsorReason = fees.steps.lazy.compactMap { step -> StellarSponsorReason? in
            if case .dyorHQ(let reason) = step.payer { return reason }
            return nil
        }.first
        if mine.isEmpty, sponsorReason != nil {
            value = .paidByDyorHQ
        } else if unbuilt == 0 {
            value = .upTo(stroops: stroops)
        } else if built.isEmpty {
            value = .pricedAsSigned
        } else {
            value = .upToAndMore(stroops: stroops, steps: unbuilt)
        }
    }

    /// Stroops as XLM, for the app's number style ("0.0154 XLM": `NumberStyle.number(xlm, maximumFractionDigits: 7)`).
    public static func xlm(_ stroops: Int64) -> Double { Double(stroops) / 10_000_000 }
}

/// A change or a rate as the API sends it, a fraction (0.0123), as the percent the app's figures take (1.23 for
/// `ChangeBadge(value:)`, R24). Only these make percents, so no screen multiplies by 100 itself, or twice.
public struct StellarPercent: Hashable, Comparable, Sendable {
    /// The percent: 1.23 for +1.23%.
    public let value: Double

    public init(_ fraction: Double) {
        // A fraction × 100 can land a hair off the decimal it stands for; 9 decimals of a percent are plenty.
        value = (fraction * 100 * 1e9).rounded() / 1e9
    }

    /// Nil for an unknown (or not finite) fraction.
    public init?(_ fraction: Double?) {
        guard let fraction, fraction.isFinite else { return nil }
        self.init(fraction)
    }

    public static func < (lhs: StellarPercent, rhs: StellarPercent) -> Bool { lhs.value < rhs.value }
    public static func == (lhs: StellarPercent, rhs: Double) -> Bool { lhs.value == rhs }
}

public extension StellarMarketRow {
    /// The 24h change in percent (1.23 for +1.23%); nil while unknown (a coin under a day old).
    var change24hPercent: Double? { StellarPercent(change24h)?.value }
}

public extension StellarHoldings {
    /// The account's 24h change across its priced holdings, in percent.
    var change24hPercent: Double? { StellarPercent(change24h.pct)?.value }
}

public extension StellarHoldings.SpotHolding {
    var change24hPercent: Double? { StellarPercent(change24h)?.value }
}

public extension StellarHoldings.LaunchHolding {
    var change24hPercent: Double? { StellarPercent(change24h)?.value }
}

public extension StellarLaunch {
    var change24hPercent: Double? { StellarPercent(change24h)?.value }
}

public extension StellarLaunchDetail.Stats {
    var change24hPercent: Double? { StellarPercent(change24h)?.value }
}

public extension EarnMarket {
    var supplyApyPercent: Double { StellarPercent(supplyApy).value }
    var borrowApyPercent: Double { StellarPercent(borrowApy).value }
    var utilizationPercent: Double { StellarPercent(utilization).value }
}

public extension EarnPosition {
    var supplyApyPercent: Double? { StellarPercent(supplyApy)?.value }
}

public extension StellarEarnHistory.Point {
    var supplyApyPercent: Double { StellarPercent(supplyApy).value }
    var utilizationPercent: Double { StellarPercent(utilization).value }
}
