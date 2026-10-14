import Foundation

/// The app's one style for dollar amounts, the same in every language and region: "$" in front, "." as the decimal
/// point, "," between thousands, K/M/B/T when a call site is short of room, and "−" (U+2212) for a negative. It is built
/// from POSIX `String(format:)` only, never from the user's locale, so "$1,234.50" reads the same in Accra, Paris, Madrid
/// and Seoul and is never mistaken for 1.2345 or 1,234,500.
///
/// It always rounds to the nearest shown digit. It is for reading only: an amount field is written with
/// `Amount.exact` / `Amount.roundedDown` and read with `Amount.parse` / `Amount.fieldNumber`, and none of these strings
/// is ever written into a field or copied to the pasteboard.
public enum PriceFormat {
    private static let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")

    /// A unit price:
    /// - none or not a finite number: "—";
    /// - $1,000 or more: grouped, 2 decimals ("$85,000.00");
    /// - $1 to $1,000: 2 decimals ("$3.51");
    /// - $0.0001 to $1: 4 significant digits ("$0.1235", "$0.0001000");
    /// - below $0.0001: 4 significant digits after the zeros, which are counted in subscript ("$0.0₇6130" is
    ///   $0.00000006130).
    /// A price that rounds up into the next band is shown in that band (0.99996 is "$1.00"). `signed` adds "+" to a
    /// positive change; a negative always has "−".
    public static func usdPrice(_ value: Double?, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return sign(value, signed: signed) + "$" + price(abs(value), subscripted: true)
    }

    /// `usdPrice` as VoiceOver should read it: the same rounding, with every zero written out instead of the subscript
    /// count ("$0.00000006130"), since a subscript digit is read as a plain digit. "—" for none, as shown.
    public static func spoken(_ value: Double?, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return sign(value, signed: signed) + "$" + price(abs(value), subscripted: false)
    }

    /// An amount of money (a balance, a total, a fee, a P&L): 2 decimals, grouped ("$1,234.50"), or up to
    /// `fractionDigits.upperBound` decimals with trailing zeros trimmed down to `fractionDigits.lowerBound` ("$0.123456"
    /// for an exact USDC amount). Not zero but below half of the last shown digit reads "<$0.01" ("<$1" for whole
    /// dollars). `compact` writes $1,000 and more as "$1.2K", "$3.45M", "$2B", "$1T", for a call site short of room.
    /// `signed` adds "+" to a positive; zero has no sign; a negative always has "−" ("−$5.00", "−<$0.01").
    public static func usdValue(_ value: Double?, compact: Bool = false, signed: Bool = false,
                                fractionDigits: ClosedRange<Int> = 2...2) -> String {
        guard let value, value.isFinite else { return "—" }
        let digits = max(0, fractionDigits.lowerBound)...min(12, max(0, fractionDigits.upperBound))
        let magnitude = abs(value)
        if magnitude == 0 { return "$" + fixed(0, fractionDigits: digits) }
        let smallest = pow(10, -Double(digits.upperBound))
        if magnitude < smallest / 2 { return sign(value, signed: signed) + "<$" + fixed(smallest, fractionDigits: digits.upperBound...digits.upperBound) }
        if compact, let short = compacted(magnitude, fractionDigits: digits) { return sign(value, signed: signed) + "$" + short }
        return sign(value, signed: signed) + "$" + fixed(magnitude, fractionDigits: digits)
    }

    /// A price chart's axis label, with as many digits as the plotted range needs to tell neighbouring ticks apart: one
    /// digit finer than the range's leading digit, so $0.0₇60 and $0.0₇64 stay distinct on a dust coin's chart and a
    /// $3.51 coin moving a few cents reads "$3.512". Dust is subscripted as in `usdPrice`. `span` is the plotted range
    /// (top minus bottom); a span that is not a positive finite number falls back to `usdPrice`.
    public static func axis(_ value: Double, span: Double) -> String {
        guard value.isFinite else { return "—" }
        guard span.isFinite, span > 0 else { return usdPrice(value) }
        let magnitude = abs(value)
        if magnitude == 0 { return "$0" }
        // The digit place one below the span's leading digit (a span of 4e-9 is resolved to 1e-10).
        let place = Int(floor(log10(span))) - 1
        if magnitude >= 1e-4 {
            let decimals = min(12, max(0, -place))
            return sign(value, signed: false) + "$" + fixed(magnitude, fractionDigits: decimals...decimals)
        }
        let leading = scientific(magnitude, significantDigits: 6).exponent
        let significant = min(6, max(1, leading - place + 1))
        let (digits, exponent) = scientific(magnitude, significantDigits: significant)
        guard exponent < -4 else { return sign(value, signed: false) + "$" + plain(digits, exponent: exponent) }
        return sign(value, signed: false) + "$" + subscripted(digits, exponent: exponent)
    }

    // MARK: - Building blocks

    private static func sign(_ value: Double, signed: Bool) -> String {
        value < 0 ? "−" : (signed && value > 0 ? "+" : "")
    }

    /// The price bands of `usdPrice` for a non-negative finite magnitude, without "$".
    private static func price(_ magnitude: Double, subscripted useSubscript: Bool) -> String {
        if magnitude == 0 { return "0.00" }
        let (digits, exponent) = scientific(magnitude, significantDigits: 4)
        if exponent >= 0 { return fixed(magnitude, fractionDigits: 2...2) }
        if exponent >= -4 || !useSubscript { return plain(digits, exponent: exponent) }
        return subscripted(digits, exponent: exponent)
    }

    /// The significant digits and the power of ten of `magnitude` rounded to `significantDigits` digits, from POSIX
    /// "%e" (6.1297e-8 at 4 digits is ("6130", -8); 9.99996e-5 rounds up to ("1000", -4)).
    private static func scientific(_ magnitude: Double, significantDigits: Int) -> (digits: String, exponent: Int) {
        let text = String(format: "%.\(max(0, significantDigits - 1))e", magnitude)
        let parts = text.split(separator: "e")
        let digits = parts[0].filter { $0 != "." }
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (String(digits), exponent)
    }

    /// "0." + the zeros + `digits`, for a negative `exponent` ("6130", -5 is "0.00006130").
    private static func plain(_ digits: String, exponent: Int) -> String {
        "0." + String(repeating: "0", count: max(0, -exponent - 1)) + digits
    }

    /// "0.0" + the count of zeros after the point in subscript + `digits` ("6130", -8 is "0.0₇6130").
    private static func subscripted(_ digits: String, exponent: Int) -> String {
        let zeros = String(-exponent - 1).compactMap { $0.wholeNumberValue }.map { String(subscripts[$0]) }.joined()
        return "0.0" + zeros + digits
    }

    /// `magnitude` with `fractionDigits.upperBound` decimals, trailing zeros trimmed down to `fractionDigits.lowerBound`,
    /// thousands grouped with ",".
    private static func fixed(_ magnitude: Double, fractionDigits: ClosedRange<Int>) -> String {
        let text = String(format: "%.\(fractionDigits.upperBound)f", magnitude)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        while fraction.count > fractionDigits.lowerBound, fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = grouped(String(parts[0]))
        return fraction.isEmpty ? whole : whole + "." + fraction
    }

    /// ASCII digits with "," between each group of three from the right ("85000" is "85,000").
    private static func grouped(_ whole: String) -> String {
        var out = ""
        for (index, character) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }

    /// $1,000 and more as K/M/B/T with up to 2 decimals, trailing zeros trimmed ("1.2K", "3.45M"), choosing the smallest
    /// unit whose rounded figure stays under 1,000 (999,999 is "1M", not "1000K"). Nil when the amount, as it would be
    /// shown in full, is under $1,000.
    private static func compacted(_ magnitude: Double, fractionDigits: ClosedRange<Int>) -> String? {
        let shown = Double(String(format: "%.\(fractionDigits.upperBound)f", magnitude)) ?? magnitude
        guard shown >= 1_000 else { return nil }
        let units: [(Double, String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]
        for (index, (divisor, suffix)) in units.enumerated() {
            let figure = fixed(magnitude / divisor, fractionDigits: 0...2)
            if index == units.count - 1 || (Double(String(format: "%.2f", magnitude / divisor)) ?? 0) < 1_000 { return figure + suffix }
        }
        return nil
    }
}

/// The price-alert target field. It is read with the amount fields' parser, `Amount.parse`, so the decimal separator
/// the region's keypad types works ("0,03" from a comma-decimal keypad is three cents, as "0.03" is), at 18 decimals so a
/// dust target such as 0.00000006 keeps every digit. Nil for an empty, malformed or zero target.
public enum PriceAlertTarget {
    public static let decimals = 18

    public static func parse(_ text: String) -> Double? {
        guard let raw = Amount.parse(text, decimals: decimals), raw > 0 else { return nil }
        return Double(Amount.exact(raw, decimals: decimals))
    }
}
