import BigInt
import XCTest
@testable import DyorKit

/// The app's one dollar style (`PriceFormat`): the price bands and their rounding, values, compact values, signs, chart
/// axis labels and the VoiceOver text, the same in every region; and `NumberStyle`'s grouped numbers in that style.
final class PriceFormatTests: XCTestCase {
    func testPriceBandsAndRounding() {
        XCTAssertEqual(PriceFormat.usdPrice(nil), "—")
        XCTAssertEqual(PriceFormat.usdPrice(0), "$0.00")
        // $1,000 or more: grouped, 2 decimals.
        XCTAssertEqual(PriceFormat.usdPrice(85_000), "$85,000.00")
        XCTAssertEqual(PriceFormat.usdPrice(1_000), "$1,000.00")
        XCTAssertEqual(PriceFormat.usdPrice(1_234_567.891), "$1,234,567.89")
        XCTAssertEqual(PriceFormat.usdPrice(999.999), "$1,000.00", "rounds up into the grouped band")
        // $1 to $1,000: 2 decimals.
        XCTAssertEqual(PriceFormat.usdPrice(1), "$1.00")
        XCTAssertEqual(PriceFormat.usdPrice(3.514), "$3.51")
        XCTAssertEqual(PriceFormat.usdPrice(3.516), "$3.52")
        XCTAssertEqual(PriceFormat.usdPrice(0.99996), "$1.00", "rounds up into the 2-decimal band")
        // $0.0001 to $1: 4 significant digits.
        XCTAssertEqual(PriceFormat.usdPrice(0.9999), "$0.9999")
        XCTAssertEqual(PriceFormat.usdPrice(0.123456), "$0.1235")
        XCTAssertEqual(PriceFormat.usdPrice(0.5), "$0.5000")
        XCTAssertEqual(PriceFormat.usdPrice(0.0351249), "$0.03512")
        XCTAssertEqual(PriceFormat.usdPrice(0.0001), "$0.0001000")
        XCTAssertEqual(PriceFormat.usdPrice(0.000099996), "$0.0001000", "rounds up out of the subscript band")
        // Below $0.0001: the zeros after the point counted in subscript, then 4 significant digits.
        XCTAssertEqual(PriceFormat.usdPrice(0.00009), "$0.0₄9000")
        XCTAssertEqual(PriceFormat.usdPrice(6.1297e-8), "$0.0₇6130")
        XCTAssertEqual(PriceFormat.usdPrice(6.12949e-8), "$0.0₇6129")
        XCTAssertEqual(PriceFormat.usdPrice(4.2e-8), "$0.0₇4200")
        XCTAssertEqual(PriceFormat.usdPrice(1.23456e-15), "$0.0₁₄1235")
    }

    func testNegativesSignsAndNonFinite() {
        XCTAssertEqual(PriceFormat.usdPrice(-3.5), "−$3.50")
        XCTAssertEqual(PriceFormat.usdPrice(-6.1297e-8), "−$0.0₇6130")
        XCTAssertEqual(PriceFormat.usdPrice(-1_234.5), "−$1,234.50")
        XCTAssertEqual(PriceFormat.usdPrice(12.5, signed: true), "+$12.50")
        XCTAssertEqual(PriceFormat.usdPrice(0, signed: true), "$0.00")
        XCTAssertEqual(PriceFormat.usdPrice(-0.0), "$0.00")
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(PriceFormat.usdPrice(bad), "—")
            XCTAssertEqual(PriceFormat.usdValue(bad), "—")
            XCTAssertEqual(PriceFormat.usdValue(bad, compact: true, signed: true), "—")
            XCTAssertEqual(PriceFormat.spoken(bad), "—")
            XCTAssertEqual(PriceFormat.axis(bad, span: 1), "—")
        }
        XCTAssertTrue(PriceFormat.usdPrice(-1).hasPrefix("\u{2212}"), "the minus sign, not a hyphen")
        XCTAssertFalse(PriceFormat.usdValue(-1).contains("-"))
    }

    func testValues() {
        XCTAssertEqual(PriceFormat.usdValue(nil), "—")
        XCTAssertEqual(PriceFormat.usdValue(0), "$0.00")
        XCTAssertEqual(PriceFormat.usdValue(1_234.5), "$1,234.50")
        XCTAssertEqual(PriceFormat.usdValue(1_234.567), "$1,234.57")
        XCTAssertEqual(PriceFormat.usdValue(25.9), "$25.90")
        // Below half a cent, not zero.
        XCTAssertEqual(PriceFormat.usdValue(0.004), "<$0.01")
        XCTAssertEqual(PriceFormat.usdValue(0.0049), "<$0.01")
        XCTAssertEqual(PriceFormat.usdValue(1e-12), "<$0.01")
        XCTAssertEqual(PriceFormat.usdValue(0.005), "$0.01")
        XCTAssertEqual(PriceFormat.usdValue(0.012), "$0.01")
        XCTAssertEqual(PriceFormat.usdValue(-0.004), "−<$0.01")
        // Signs.
        XCTAssertEqual(PriceFormat.usdValue(-5), "−$5.00")
        XCTAssertEqual(PriceFormat.usdValue(5, signed: true), "+$5.00")
        XCTAssertEqual(PriceFormat.usdValue(0, signed: true), "$0.00")
        XCTAssertEqual(PriceFormat.usdValue(-5, signed: true), "−$5.00")
        // Compact where the call site was compact.
        XCTAssertEqual(PriceFormat.usdValue(999.99, compact: true), "$999.99")
        XCTAssertEqual(PriceFormat.usdValue(1_000, compact: true), "$1K")
        XCTAssertEqual(PriceFormat.usdValue(1_234, compact: true), "$1.23K")
        XCTAssertEqual(PriceFormat.usdValue(25_900, compact: true), "$25.9K")
        XCTAssertEqual(PriceFormat.usdValue(999_999, compact: true), "$1M", "never 1000K")
        XCTAssertEqual(PriceFormat.usdValue(3_450_000, compact: true), "$3.45M")
        XCTAssertEqual(PriceFormat.usdValue(2.5e9, compact: true), "$2.5B")
        XCTAssertEqual(PriceFormat.usdValue(1.2e12, compact: true), "$1.2T")
        XCTAssertEqual(PriceFormat.usdValue(1.5e15, compact: true), "$1,500T")
        XCTAssertEqual(PriceFormat.usdValue(-1_234, compact: true, signed: true), "−$1.23K")
        XCTAssertEqual(PriceFormat.usdValue(1_234, compact: true, signed: true), "+$1.23K")
        // Exact amounts (USDC to the sixth decimal) and whole dollars.
        XCTAssertEqual(PriceFormat.usdValue(0.123456, fractionDigits: 2...6), "$0.123456")
        XCTAssertEqual(PriceFormat.usdValue(771.428571, fractionDigits: 2...6), "$771.428571")
        XCTAssertEqual(PriceFormat.usdValue(1, fractionDigits: 2...6), "$1.00")
        XCTAssertEqual(PriceFormat.usdValue(0.000001, fractionDigits: 2...6), "$0.000001")
        XCTAssertEqual(PriceFormat.usdValue(0.0000004, fractionDigits: 2...6), "<$0.000001")
        XCTAssertEqual(PriceFormat.usdValue(0, fractionDigits: 2...6), "$0.00")
        XCTAssertEqual(PriceFormat.usdValue(2_000.4, fractionDigits: 0...0), "$2,000")
        XCTAssertEqual(PriceFormat.usdValue(0.3, fractionDigits: 0...0), "<$1")
        XCTAssertEqual(PriceFormat.usdValue(771.428571), "$771.43")
    }

    /// A dust coin's chart: ticks 0.4e-8 apart must not collapse into one label.
    func testAxisLabelsStayDistinct() {
        let low = 6.0e-8, high = 6.4e-8
        let span = (high - low) * 1.16 // PriceChart's headroom
        XCTAssertEqual(PriceFormat.axis(low, span: span), "$0.0₇600")
        XCTAssertEqual(PriceFormat.axis(high, span: span), "$0.0₇640")
        let ticks = stride(from: low, through: high + 1e-12, by: 0.1e-8).map { PriceFormat.axis($0, span: span) }
        XCTAssertEqual(ticks.count, 5)
        XCTAssertEqual(Set(ticks).count, ticks.count, "\(ticks)")
        XCTAssertNotEqual(PriceFormat.axis(6.0e-8, span: 1e-8), PriceFormat.axis(6.4e-8, span: 1e-8))
        // Ordinary prices resolve one digit finer than the range.
        XCTAssertEqual(PriceFormat.axis(3.512, span: 0.05), "$3.512")
        XCTAssertEqual(PriceFormat.axis(3.514, span: 0.05), "$3.514")
        XCTAssertEqual(PriceFormat.axis(85_000, span: 2_000), "$85,000")
        XCTAssertEqual(PriceFormat.axis(0.03512, span: 0.002), "$0.0351")
        XCTAssertEqual(PriceFormat.axis(0, span: 1), "$0")
        XCTAssertEqual(PriceFormat.axis(3.5, span: 0), PriceFormat.usdPrice(3.5), "no range: the price itself")
    }

    func testSpokenHasNoSubscripts() {
        let subscripts = Set("₀₁₂₃₄₅₆₇₈₉")
        XCTAssertEqual(PriceFormat.spoken(6.1297e-8), "$0.00000006130")
        XCTAssertEqual(PriceFormat.spoken(0.00009), "$0.00009000")
        XCTAssertEqual(PriceFormat.spoken(85_000), "$85,000.00")
        XCTAssertEqual(PriceFormat.spoken(0.123456), "$0.1235")
        XCTAssertEqual(PriceFormat.spoken(-6.1297e-8), "−$0.00000006130")
        XCTAssertEqual(PriceFormat.spoken(nil), "—")
        var value = 9.87e-19
        while value < 1e6 {
            let spoken = PriceFormat.spoken(value)
            XCTAssertFalse(spoken.contains { subscripts.contains($0) }, spoken)
            // The same rounding as shown: the digits after the zeros match.
            let shown = PriceFormat.usdPrice(value)
            XCTAssertEqual(String(spoken.suffix(4)), String(shown.suffix(4)), "\(value): \(spoken) vs \(shown)")
            value *= 7.3
        }
    }

    /// `NumberStyle`'s numbers of 1,000 or more use the same grouping in every region; truncation and the smaller
    /// bands are unchanged (`CoreTests.testNumberStyle` pins those).
    func testNumberStyleGroupingIsFixed() {
        XCTAssertEqual(NumberStyle.number(85_000, maximumFractionDigits: 1), "85,000")
        XCTAssertEqual(NumberStyle.number(85_000.5, maximumFractionDigits: 1), "85,000.5")
        XCTAssertEqual(NumberStyle.number(1_234_567.891), "1,234,567.89")
        XCTAssertEqual(NumberStyle.number(-1_234.5), "−1,234.5")
    }

    // MARK: - The same text in every region

    static let regions = ["en_GH", "en_US", "fr_FR", "es_ES", "es_MX", "zh_CN", "ko_KR", "de_DE"]
    private static let probeEnvironment = "DYORKIT_PRICE_FORMAT_PROBE"

    /// Every formatted string the probe checks, in a fixed order.
    static func probeOutputs() -> [String] {
        var out: [String] = []
        for price in [0, 6.1297e-8, 0.00009, 0.0001, 0.123456, 0.99996, 3.514, 999.999, 1_234.5, 85_000, -1_234.5, .nan] {
            out.append(PriceFormat.usdPrice(price))
            out.append(PriceFormat.spoken(price))
        }
        for value in [0, 0.004, 0.005, 1_234.5, -1_234.5, 999_999] {
            out.append(PriceFormat.usdValue(value))
            out.append(PriceFormat.usdValue(value, compact: true, signed: true))
        }
        out.append(PriceFormat.usdValue(0.123456, fractionDigits: 2...6))
        out.append(PriceFormat.usdValue(2_000.4, fractionDigits: 0...0))
        out.append(PriceFormat.axis(6.0e-8, span: 4.64e-9))
        out.append(PriceFormat.axis(6.4e-8, span: 4.64e-9))
        out.append(PriceFormat.axis(3.512, span: 0.05))
        out.append(PriceFormat.axis(85_000, span: 2_000))
        out.append(NumberStyle.number(85_000.5, maximumFractionDigits: 1))
        out.append(NumberStyle.number(1_234_567.891))
        out.append(NumberStyle.number(1_234.5, compact: true))
        out.append(PriceAlertTarget.parse("0,03").map { "\($0)" } ?? "nil")
        out.append(PriceAlertTarget.parse("0.03").map { "\($0)" } ?? "nil")
        return out
    }

    /// Runs only inside the child process `testIdenticalOutputInEveryRegion` starts (it does nothing in a normal run):
    /// writes the outputs, and what the region itself would write, to the file the parent names.
    func testRegionProbe() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.probeEnvironment] else { return }
        let report: [String: Any] = [
            "locale": Locale.current.identifier,
            "decimalSeparator": Locale.current.decimalSeparator ?? "",
            "regionCurrency": 1_234.5.formatted(.currency(code: "USD")),
            "outputs": Self.probeOutputs(),
        ]
        try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: path))
    }

    /// The same strings under en_GH, en_US, fr_FR, es_ES, es_MX, zh_CN, ko_KR and de_DE. `Locale.current` is fixed for
    /// a process's lifetime, so each region runs this bundle's `testRegionProbe` in a child test process started with
    /// `-AppleLocale <region>`, and the child also reports what the region's own currency style writes, which proves the
    /// region took effect.
    func testIdenticalOutputInEveryRegion() throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let runner = arguments.first, FileManager.default.isExecutableFile(atPath: runner) else {
            return XCTFail("the test runner isn't known: \(arguments)")
        }
        let bundle = Bundle(for: Self.self).bundlePath
        let expected = Self.probeOutputs()
        XCTAssertEqual(expected, Self.pinned, "the outputs this process writes")
        var regionCurrencies: Set<String> = []
        for region in Self.regions {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("price-format-\(region)-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: out) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runner)
            // The runner takes `-XCTest <scope> <bundle>` last; the region goes first, into the arguments' defaults domain.
            process.arguments = ["-AppleLocale", region, "-XCTest", "DyorKitTests.PriceFormatTests/testRegionProbe", bundle]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.probeEnvironment] = out.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let data = try Data(contentsOf: out)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let locale = try XCTUnwrap(report["locale"] as? String)
            XCTAssertTrue(locale.hasPrefix(region), "\(region): the child ran as \(locale)")
            XCTAssertEqual(report["outputs"] as? [String], expected, region)
            regionCurrencies.insert(try XCTUnwrap(report["regionCurrency"] as? String))
            if region == "fr_FR" || region == "de_DE" || region == "es_ES" { XCTAssertEqual(report["decimalSeparator"] as? String, ",", region) }
        }
        XCTAssertGreaterThan(regionCurrencies.count, 4, "the regions' own styles differ (\(regionCurrencies)), ours doesn't")
    }

    /// `probeOutputs()` as it must read everywhere.
    static let pinned: [String] = [
        "$0.00", "$0.00",
        "$0.0₇6130", "$0.00000006130",
        "$0.0₄9000", "$0.00009000",
        "$0.0001000", "$0.0001000",
        "$0.1235", "$0.1235",
        "$1.00", "$1.00",
        "$3.51", "$3.51",
        "$1,000.00", "$1,000.00",
        "$1,234.50", "$1,234.50",
        "$85,000.00", "$85,000.00",
        "−$1,234.50", "−$1,234.50",
        "—", "—",
        "$0.00", "$0.00",
        "<$0.01", "+<$0.01",
        "$0.01", "+$0.01",
        "$1,234.50", "+$1.23K",
        "−$1,234.50", "−$1.23K",
        "$999,999.00", "+$1M",
        "$0.123456",
        "$2,000",
        "$0.0₇600",
        "$0.0₇640",
        "$3.512",
        "$85,000",
        "85,000.5",
        "1,234,567.89",
        "1.23K",
        "0.03",
        "0.03",
    ]
}

/// The price-alert target field reads like an amount field (`Amount.parse`), whatever the keypad's decimal separator.
final class PriceAlertTargetTests: XCTestCase {
    func testCommaAndPointDecimals() {
        // fr_FR's decimal pad types ",", en_US's types ".".
        XCTAssertEqual(PriceAlertTarget.parse("0,03"), 0.03)
        XCTAssertEqual(PriceAlertTarget.parse("0.03"), 0.03)
        XCTAssertEqual(PriceAlertTarget.parse(" 85000 "), 85_000)
        XCTAssertEqual(PriceAlertTarget.parse("85000,5"), 85_000.5)
        XCTAssertEqual(PriceAlertTarget.parse("1,234.5"), 1_234.5)
        XCTAssertEqual(PriceAlertTarget.parse("1.234,5"), 1_234.5)
        // A dust target keeps every digit.
        XCTAssertEqual(PriceAlertTarget.parse("0.00000006"), 6e-8)
        XCTAssertEqual(PriceAlertTarget.parse("0,000000061297"), 6.1297e-8)
        XCTAssertEqual(PriceFormat.usdPrice(PriceAlertTarget.parse("0,000000061297")), "$0.0₇6130")
    }

    func testRefusals() {
        for bad in ["", " ", "0", "0,00", ".", ",", "abc", "-1", "1e-8", "1,2,3.4.5", "inf", "nan", "$5"] {
            XCTAssertNil(PriceAlertTarget.parse(bad), bad)
        }
    }
}

/// The money paths with the device region set to Ghana, France and Spain: what each region's decimal pad types, and
/// what the app writes into a field (Max, %, a carried quote), reads back as intended in every amount field.
final class RegionMoneyPathTests: XCTestCase {
    private static let regions = ["en_GH", "fr_FR", "es_ES"].map { Locale(identifier: $0) }

    /// Swap, Send, Launch buy and sell, Bridge, the Perps deposit, Moments publish price: `Amount.parse` reads the
    /// region's decimal separator as the decimal point, so "12,5" and "12.5" are both twelve and a half.
    func testTypedAmountsParse() throws {
        for locale in Self.regions {
            let separator = try XCTUnwrap(locale.decimalSeparator)
            for decimals in [6, 18] {
                let unit = BigUInt(10).power(decimals)
                XCTAssertEqual(Amount.parse("12\(separator)5", decimals: decimals), unit * 25 / 2, locale.identifier)
                XCTAssertEqual(Amount.parse("0\(separator)000001", decimals: decimals), unit / 1_000_000, locale.identifier)
                XCTAssertEqual(Amount.parse("1000", decimals: decimals), unit * 1_000, locale.identifier)
            }
            // The price-alert target: the same parser.
            XCTAssertEqual(PriceAlertTarget.parse("0\(separator)03"), 0.03, locale.identifier)
            XCTAssertEqual(PriceAlertTarget.parse("0\(separator)00000006"), 6e-8, locale.identifier)
        }
    }

    /// Max and % write `Amount.exact` of the (rounded-down) balance; it reads back to exactly that amount.
    func testMaxAndPercentRoundTrip() {
        let balances: [(BigUInt, Int)] = [(BigUInt("1234567890123456789012"), 18), (559_465_123, 9), (1, 18), (123_456_789, 6), (BigUInt(10).power(24) + 7, 18)]
        for (balance, decimals) in balances {
            XCTAssertEqual(Amount.parse(Amount.exact(balance, decimals: decimals), decimals: decimals), balance, "Max")
            for pct in [25, 50, 75] {
                let share = Amount.roundedDown(balance * BigUInt(pct) / 100, decimals: decimals)
                XCTAssertEqual(Amount.parse(Amount.exact(share, decimals: decimals), decimals: decimals), share, "\(pct)%")
                XCTAssertLessThanOrEqual(share, balance * BigUInt(pct) / 100)
            }
        }
    }

    /// The Perps price, size, trigger and margin fields (`Amount.fieldNumber` with the region's grouping separator):
    /// what each region types, and the tickets' own POSIX writers, read as intended, so the >5% through-the-mark limit
    /// guard compares the number the user meant.
    func testPerpsFieldsParse() throws {
        for locale in Self.regions {
            let grouping = locale.groupingSeparator
            let decimal = try XCTUnwrap(locale.decimalSeparator)
            XCTAssertEqual(Amount.fieldNumber("85000\(decimal)5", groupingSeparator: grouping), 85_000.5, locale.identifier)
            XCTAssertEqual(Amount.fieldNumber("0\(decimal)5", groupingSeparator: grouping), 0.5, locale.identifier)
            // The tickets' writers: plainSize (POSIX, no grouping) and plainAmount ("%.2f").
            XCTAssertEqual(Amount.fieldNumber("65432.125", groupingSeparator: grouping), 65_432.125, locale.identifier)
            XCTAssertEqual(Amount.fieldNumber(String(format: "%.2f", 1_234.5), groupingSeparator: grouping), 1_234.5, locale.identifier)
        }
        // Ghana groups with ",": a price pasted from a chart is not read 1000x too low. France and Spain read "," as the
        // decimal point, as their keypads type it.
        XCTAssertEqual(Amount.fieldNumber("66,000", groupingSeparator: Locale(identifier: "en_GH").groupingSeparator), 66_000)
        XCTAssertEqual(Amount.fieldNumber("66,000", groupingSeparator: Locale(identifier: "fr_FR").groupingSeparator), 66)
        XCTAssertEqual(Amount.fieldNumber("66,000", groupingSeparator: Locale(identifier: "es_ES").groupingSeparator), 66)
    }

    /// The through-the-mark guard still reads the typed limit through `perpDouble` (`Amount.fieldNumber`) and still
    /// fires beyond 5% of the mark; nothing formatted for display feeds it.
    func testThroughTheMarkGuardIsWired() throws {
        let perps = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        XCTAssertTrue(perps.contains("var perpDouble: Double? { Amount.fieldNumber(self) }"))
        XCTAssertTrue(perps.contains("if kind == .limit, let limit = priceText.perpDouble, let reason = Self.throughMarkProblem(price: limit, side: side, mark: mark, market: market) { return reason }"))
        XCTAssertTrue(perps.contains("let above = side == .long && price > mark * 1.05"))
        XCTAssertTrue(perps.contains("let below = side == .short && price < mark * 0.95"))
    }
}
