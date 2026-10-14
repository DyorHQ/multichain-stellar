import DyorKit
import SwiftUI
import WebKit

/// A real TradingView chart — TradingView's own Lightweight Charts™ engine (bundled, no network) rendered in a
/// `WKWebView` — fed entirely by Perpl's candle data. Candlesticks, a volume histogram, a crosshair with an OHLC
/// legend, pan and zoom. The palette is resolved from the app's own Positive/Negative/label colors and re-sent when
/// the theme flips, so the chart matches the surrounding screen exactly in light and dark. Its dates and its legend
/// follow the app's language (the environment's locale), re-sent when the language changes; prices keep the app's one
/// number style.
struct TradingViewChart: View {
    let candles: [PerpCandle]
    /// Horizontal reference lines (entry, liquidation, take-profit/stop-loss, resting orders) drawn over the candles.
    var levels: [ChartLevel] = []
    /// Buy/sell fill markers to pin under/over the bar they filled in.
    var markers: [ChartMarker] = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        ChartWebView(candles: candles, levels: levels, markers: markers, colorScheme: colorScheme, language: ChartLanguage(locale))
            .background(Color(.secondarySystemGroupedBackground))
    }
}

/// The app's language as the chart needs it: the locale its dates are written in, and its legend's labels.
struct ChartLanguage: Equatable {
    /// The locale as a BCP 47 tag ("en-US"), for the chart's time scale and crosshair dates.
    let locale: String
    /// The legend's open, high, low and close labels.
    let open: String
    let high: String
    let low: String
    let close: String

    init(_ locale: Locale) {
        self.locale = locale.identifier(.bcp47)
        open = tr(LocalizedStringResource("O", comment: "The chart legend's label for a candle's opening price. [tight]"))
        high = tr(LocalizedStringResource("H", comment: "The chart legend's label for a candle's highest price. [tight]"))
        low = tr(LocalizedStringResource("L", comment: "The chart legend's label for a candle's lowest price. [tight]"))
        close = tr(LocalizedStringResource("C", comment: "The chart legend's label for a candle's closing price. [tight]"))
    }
}

/// One horizontal line on the chart, coloured for its role (side/liq/tp/sl) with an axis label.
struct ChartLevel: Equatable {
    let price: Double
    let colorHex: String
    let title: String
    var dashed: Bool = false
    var width: Int = 1
}

/// One fill marker: the bar time it belongs to, its side, and a short label.
struct ChartMarker: Equatable {
    let time: Int
    let side: OrderSide
    var text: String = ""
}

private struct ChartWebView: UIViewRepresentable {
    let candles: [PerpCandle]
    let levels: [ChartLevel]
    let markers: [ChartMarker]
    let colorScheme: ColorScheme
    let language: ChartLanguage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "chart", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.apply(candles: candles, levels: levels, markers: markers, colorScheme: colorScheme, language: language)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ready")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var ready = false
        private var lastSignature = ""
        private var lastLevels = ""
        private var lastMarkers = ""
        private var lastScheme: ColorScheme?
        private var lastLanguage: ChartLanguage?
        private var pendingCandles: [PerpCandle] = []
        private var pendingLevels: [ChartLevel] = []
        private var pendingMarkers: [ChartMarker] = []
        private var pendingScheme: ColorScheme = .light
        private var pendingLanguage: ChartLanguage?

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor in
                self.ready = true
                self.flush()
            }
        }

        func apply(candles: [PerpCandle], levels: [ChartLevel], markers: [ChartMarker], colorScheme: ColorScheme, language: ChartLanguage) {
            pendingCandles = candles
            pendingLevels = levels
            pendingMarkers = markers
            pendingScheme = colorScheme
            pendingLanguage = language
            if ready { flush() }
        }

        private func flush() {
            guard let web = webView else { return }
            if pendingScheme != lastScheme || pendingLanguage != lastLanguage {
                lastScheme = pendingScheme
                lastLanguage = pendingLanguage
                web.evaluateJavaScript("window.__configure(\(Self.configureJSON(scheme: pendingScheme, language: pendingLanguage)))")
            }
            let signature = "\(pendingCandles.count)|\(pendingCandles.first?.id ?? 0)|\(pendingCandles.last?.id ?? 0)|\(pendingCandles.last?.close ?? 0)|\(pendingCandles.last?.high ?? 0)|\(pendingCandles.last?.low ?? 0)"
            if signature != lastSignature, !pendingCandles.isEmpty {
                lastSignature = signature
                web.evaluateJavaScript("window.__setData(\(Self.candlesJSON(pendingCandles)))")
            }
            let levelsJSON = Self.levelsJSON(pendingLevels)
            if levelsJSON != lastLevels {
                lastLevels = levelsJSON
                web.evaluateJavaScript("window.__setLevels(\(levelsJSON))")
            }
            let markersJSON = Self.markersJSON(pendingMarkers)
            if markersJSON != lastMarkers {
                lastMarkers = markersJSON
                web.evaluateJavaScript("window.__setMarkers(\(markersJSON))")
            }
        }

        private static func levelsJSON(_ levels: [ChartLevel]) -> String {
            let rows = levels.map { lv in
                "{\"price\":\(lv.price),\"color\":\"\(lv.colorHex)\",\"title\":\"\(escape(lv.title))\",\"dashed\":\(lv.dashed),\"width\":\(lv.width)}"
            }
            return "[\(rows.joined(separator: ","))]"
        }

        private static func markersJSON(_ markers: [ChartMarker]) -> String {
            let rows = markers.map { m in
                // not localized: the page's JSON values ("buy", "sell")
                "{\"time\":\(m.time),\"side\":\"\(m.side == .buy ? "buy" : "sell")\",\"text\":\"\(escape(m.text))\"}"
            }
            return "[\(rows.joined(separator: ","))]"
        }

        /// Minimal JSON-string escaping for the short titles we send (no control characters expected).
        private static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }

        private static func candlesJSON(_ candles: [PerpCandle]) -> String {
            let rows = candles.map { c in
                "{\"time\":\(Int(c.time.timeIntervalSince1970)),\"open\":\(c.open),\"high\":\(c.high),\"low\":\(c.low),\"close\":\(c.close),\"volume\":\(c.volume)}"
            }
            return "[\(rows.joined(separator: ","))]"
        }

        /// The chart's settings: the palette for `scheme`, and the app's language (`ChartLanguage`) for its dates and legend.
        private static func configureJSON(scheme: ColorScheme, language: ChartLanguage?) -> String {
            var config: [String: Any] = ["palette": palette(for: scheme)]
            if let language {
                config["locale"] = language.locale
                config["legend"] = ["o": language.open, "h": language.high, "l": language.low, "c": language.close]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }

        private static func palette(for scheme: ColorScheme) -> [String: String] {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            let up = UIColor(named: "Positive")?.resolvedColor(with: traits) ?? .systemGreen
            let down = UIColor(named: "Negative")?.resolvedColor(with: traits) ?? .systemRed
            let text = UIColor.secondaryLabel.resolvedColor(with: traits)
            let grid = UIColor.separator.resolvedColor(with: traits)
            return ["up": up.hex, "down": down.hex, "text": text.hex, "grid": grid.rgba(0.6), "border": grid.rgba(0.9), "crosshair": text.hex,
                    "up2": up.rgba(0.45), "down2": down.rgba(0.45)]
        }
    }
}

private extension UIColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func rgba(_ alpha: CGFloat) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%d,%d,%d,%.2f)", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), alpha)
    }
}
