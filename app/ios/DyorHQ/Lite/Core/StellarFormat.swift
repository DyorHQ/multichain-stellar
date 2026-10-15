// How the Stellar screens write amounts, fees and the server's dates (docs/DESIGN-stellar-parity.md §7.3). Internal
// builds only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation

/// The Stellar screens' figures in the app's own number style (`NumberStyle`), so a Stellar balance reads as a Monad one.
/// Amounts come in base units (7 decimals for XLM, USDC and the launches' coins); USD always goes through `PriceFormat`
/// or `USDText`, never here.
enum StellarFormat {
    /// Every Stellar asset's decimals unless it says otherwise: XLM, the classic assets and the launches' coins.
    static let decimals = 7

    /// An amount for display, from base units: "1,250.5", "0.0₆42", or compact "1.2M".
    static func units(_ units: Int64, decimals: Int = decimals, compact: Bool = false) -> String {
        NumberStyle.units(BigUInt(max(0, units)), decimals: decimals, compact: compact)
    }

    /// The same, for base units as the API writes them (a decimal string); "—" for one that isn't a whole number.
    static func units(_ text: String, decimals: Int = decimals, compact: Bool = false) -> String {
        guard let value = BigUInt(text) else { return "—" }
        return NumberStyle.units(value, decimals: decimals, compact: compact)
    }

    /// An amount with its asset's code, as one piece of text with nothing to translate: "12.5 XLM".
    static func amount(_ units: Int64, code: String, decimals: Int = decimals, compact: Bool = false) -> String {
        "\(self.units(units, decimals: decimals, compact: compact)) \(code)"
    }

    /// What an amount field holds after Max, a percent button or a quote: the exact amount, POSIX, with no grouping and
    /// no trailing zeros ("1250.5"), so it reads back as it was written (`Amount.parse`).
    static func plain(units: Int64, decimals: Int = decimals) -> String {
        Amount.exact(BigUInt(max(0, units)), decimals: decimals)
    }

    /// A network fee in stroops as XLM: "0.0154 XLM" (§4.6).
    static func xlm(stroops: Int64) -> String {
        "\(NumberStyle.number(StellarFeeSummary.xlm(stroops), maximumFractionDigits: 7)) XLM"
    }

    /// The review's "Max network fee" value (§4.6), in the app's language: Monad's own words for the user's fees, and
    /// the sponsored value (`sponsoredFee`) only for what the phone checked DyorHQ pays (§4.3).
    static func feeSummary(_ summary: StellarFeeSummary) -> String {
        switch summary.value {
        case .upTo(let stroops):
            let fee = xlm(stroops: stroops)
            return tr("Up to \(fee)")
        case .upToAndMore(let stroops, let steps):
            let fee = xlm(stroops: stroops)
            return tr("Up to \(fee) + \(steps) more steps")
        case .pricedAsSigned:
            return tr("Priced as each step is signed")
        case .paidByDyorHQ:
            return sponsoredFee
        }
    }

    /// A server time (ISO 8601, with or without fractions of a second) as a date.
    static func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()
}
#endif
