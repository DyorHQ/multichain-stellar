import BigInt
import Foundation

/// Conversions between raw token units and human numbers, plus the trading-style number formatting the app uses
/// wherever SwiftUI's own formatters are not the right tool (dust prices, compact balances).
public enum Amount {
    /// `BigUInt` raw units to a floating value; precise enough for display, never for math that goes on-chain.
    public static func units(_ value: BigUInt, decimals: Int) -> Double {
        guard decimals > 0 else { return Double(value) }
        return Double(value) / pow(10, Double(decimals))
    }

    public static func units(_ value: BigInt, decimals: Int) -> Double {
        let magnitude = units(value.magnitude, decimals: decimals)
        return value.sign == .minus ? -magnitude : magnitude
    }

    /// Exact conversion of a floating amount to raw units (rounds half away from zero at the last digit).
    public static func raw(_ value: Double, decimals: Int) -> BigUInt {
        guard value.isFinite, value > 0 else { return 0 }
        let text = String(format: "%.\(decimals)f", value)
        return parse(text, decimals: decimals) ?? 0
    }

    /// Parses user input into raw units. Returns nil for anything that is not a plain positive decimal. The decimal pad
    /// types the region's separator ("," across much of Europe and Latin America) while the app's own writers emit ".",
    /// so a decimal comma is read as a decimal point — "0,5" is one half, never 5 (see `decimalPoint`). Digits beyond
    /// `decimals` are truncated, not rounded. Same rules as the web app's parseAmount.
    public static func parse(_ input: String, decimals: Int) -> BigUInt? {
        guard decimals >= 0 else { return nil } // a token's decimals can come from an API; negative ones would trap below
        let cleaned = input.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0 == "." || $0 == "," || ($0.isASCII && $0.isNumber) }),
              let normalized = decimalPoint(cleaned) else { return nil }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? ""
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        if fraction.count > decimals { fraction = String(fraction.prefix(decimals)) }
        fraction += String(repeating: "0", count: decimals - fraction.count)
        let digits = (whole.isEmpty ? "0" : whole) + fraction
        return BigUInt(digits, radix: 10)
    }

    /// `s` (ASCII digits, "." and "," only) with one "." as its decimal point and no grouping, or nil when ambiguous:
    /// - one separator of either kind is the decimal point ("0,5" and "0.5");
    /// - both kinds ("1,234.5", "1.234,5"): the last is the decimal point and the other must group thousands exactly;
    /// - one kind more than once ("1,234,567"): thousands grouping only, else nil.
    public static func decimalPoint(_ s: String) -> String? {
        let dots = s.filter { $0 == "." }.count
        let commas = s.filter { $0 == "," }.count
        func grouped(_ part: Substring, by separator: Character) -> String? {
            let groups = part.split(separator: separator, omittingEmptySubsequences: false)
            // More than one group: the first can't start with 0 ("0.001,5" is not 1.5, "0,500" alone is one half).
            guard let first = groups.first, (1...3).contains(first.count), groups.count == 1 || first.first != "0",
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            return groups.joined()
        }
        if dots + commas == 0 { return s }
        if dots + commas == 1 { return s.replacingOccurrences(of: ",", with: ".") }
        if dots > 0, commas > 0 {
            guard let lastDot = s.lastIndex(of: "."), let lastComma = s.lastIndex(of: ",") else { return nil }
            let decimalSeparator: Character = lastDot > lastComma ? "." : ","
            let at = max(lastDot, lastComma)
            guard s.firstIndex(of: decimalSeparator) == at,
                  let whole = grouped(s[..<at], by: decimalSeparator == "." ? "," : ".") else { return nil }
            let fraction = String(s[s.index(after: at)...])
            guard !fraction.contains("."), !fraction.contains(",") else { return nil }
            return whole + "." + fraction
        }
        return grouped(Substring(s), by: dots > 0 ? "." : ",")
    }

    /// A typed or pasted perps price, size or trigger as a finite number, or nil. The token-amount rules (`decimalPoint`)
    /// with one change, because for a price a smaller reading is not the safe side: a lone "," followed by exactly three
    /// digits after a 1-3 digit whole part that doesn't start with 0 ("66,000") is thousands grouping when the locale
    /// groups with "," (en_US), so a price pasted from a chart isn't read 1000x too low. Where "," is the decimal separator
    /// (de_DE, fr_FR) it stays the decimal point ("1,234" is 1.234), and "0,5" is one half everywhere. A lone "." is
    /// always the decimal point, since the app's own writers emit POSIX "." ("65432.125"). ASCII digits and separators
    /// only: no signs, "inf", "nan" or exponents.
    public static func fieldNumber(_ input: String, groupingSeparator: String? = Locale.current.groupingSeparator) -> Double? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.allSatisfy({ $0 == "." || $0 == "," || ($0.isASCII && $0.isNumber) }) else { return nil }
        var normalized: String
        if groupingSeparator == ",", !s.contains("."), s.filter({ $0 == "," }).count == 1, let comma = s.firstIndex(of: ","),
           (1...3).contains(s.distance(from: s.startIndex, to: comma)), s.first != "0",
           s.distance(from: comma, to: s.endIndex) == 4 {
            normalized = s.replacingOccurrences(of: ",", with: "")
        } else {
            guard let point = decimalPoint(s) else { return nil }
            normalized = point
        }
        guard normalized != "." else { return nil }
        return Double(normalized).flatMap { $0.isFinite ? $0 : nil }
    }

    /// A share of a balance for an amount field (25 / 50 / 75 %, a native Max after its fee): rounded DOWN to
    /// `significantDigits` significant digits, keeping every whole digit, so it never exceeds the exact share and reads
    /// "0.559465" rather than eighteen decimals. Only fraction digits are dropped. A full ERC-20 balance should stay exact
    /// (so it can all be spent), so callers don't round that.
    public static func roundedDown(_ value: BigUInt, decimals: Int, significantDigits: Int = 6) -> BigUInt {
        let digits = String(value).count
        let whole = max(0, digits - decimals)
        let drop = min(decimals, max(0, digits - max(significantDigits, whole)))
        guard drop > 0 else { return value }
        let unit = BigUInt(10).power(drop)
        return value / unit * unit
    }

    /// Exact decimal string of raw units, trimmed of trailing zeros ("1.5", "0.000001", "1200").
    public static func exact(_ value: BigUInt, decimals: Int) -> String {
        let digits = String(value)
        if decimals == 0 { return digits }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[split...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = String(padded[..<split])
        return fraction.isEmpty ? whole : "\(whole).\(fraction)"
    }
}

public enum NumberStyle {
    private static let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")

    /// Balances and prices: compact suffixes for large values (1.2M), trailing zeros trimmed, and
    /// leading-zero notation (0.0₆42) for dust prices so tiny tokens stay readable. A `maximumFractionDigits` above the
    /// defaults (6 below 1, 4 significant for dust) is honored there too, so a value on a market's price/lot grid shows
    /// in full.
    public static func number(_ value: Double, compact: Bool = false, maximumFractionDigits: Int? = nil) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        let sign = value < 0 ? "−" : ""
        if magnitude == 0 { return "0" }
        if compact, magnitude >= 1_000 {
            let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
            for (divisor, suffix) in units where magnitude >= divisor {
                return sign + trim(String(format: "%.2f", magnitude / divisor)) + suffix
            }
        }
        if magnitude >= 1_000 {
            // The app's one number style (`PriceFormat`): "," between thousands and "." as the decimal point in every
            // region, so 85,000.5 never reads "85 000,5" or "85.000,5" next to a "$85,000.50" price.
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = ","
            formatter.groupingSize = 3
            formatter.decimalSeparator = "."
            formatter.maximumFractionDigits = maximumFractionDigits ?? 2
            return sign + (formatter.string(from: NSNumber(value: magnitude)) ?? String(magnitude))
        }
        if magnitude >= 1 { return sign + trim(String(format: "%.\(maximumFractionDigits ?? 4)f", magnitude)) }
        if magnitude >= 1e-4 { return sign + trim(String(format: "%.\(max(6, maximumFractionDigits ?? 6))f", magnitude)) }
        // 0.000000042 → 0.0₇42
        let text = String(format: "%.20f", magnitude)
        guard let dot = text.firstIndex(of: ".") else { return sign + String(magnitude) }
        let fraction = text[text.index(after: dot)...]
        let zeros = fraction.prefix { $0 == "0" }.count
        var significant = String(fraction.dropFirst(zeros).prefix(max(4, (maximumFractionDigits ?? 0) - zeros)))
        while significant.count > 1, significant.hasSuffix("0") { significant.removeLast() }
        return "\(sign)0.0\(String(zeros).map { subscripts[Int(String($0))!] }.map(String.init).joined())\(significant)"
    }

    public static func units(_ value: BigUInt, decimals: Int, compact: Bool = false, maximumFractionDigits: Int? = nil) -> String {
        number(Amount.units(value, decimals: decimals), compact: compact, maximumFractionDigits: maximumFractionDigits)
    }

    public static func percent(_ value: Double, fractionDigits: Int = 2, signed: Bool = true) -> String {
        guard value.isFinite else { return "—" }
        let body = String(format: "%.\(fractionDigits)f%%", abs(value))
        if !signed { return body }
        return (value < 0 ? "−" : value > 0 ? "+" : "") + body
    }

    public static func basisPoints(_ bps: Int) -> String {
        trim(String(format: "%.2f", Double(bps) / 100)) + "%"
    }

    private static func trim(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
