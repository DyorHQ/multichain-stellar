// Stellar copy of ios/DyorHQ/Home/HomeView.swift PriceChart (42cd8c7 sha256:8fa76a8065f3)
// Stellar copy of ios/DyorHQ/Perps/PerpTradeView.swift timeframePicker (42cd8c7 sha256:813819fbd886)
// Earn's chart view: a market's supply APY over the past week or month (docs/DESIGN-stellar-parity.md §8.6.3). Internal
// builds only (STELLAR_LITE).
#if STELLAR_LITE
import Charts
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// A market's supply APY over the past week or month, laid out as Monad's `PriceChart` with a percent axis, and the
/// pool's utilization as a thin line under it, from DyorHQ's snapshots of the market (`/v1/earn/history`, every 10
/// minutes from when the market was listed). The chips 7D and 30D under it pick the range, as Perps' timeframes do. A
/// market with fewer than two snapshots says it has no history yet; one whose history couldn't be read says so.
struct StellarRateChart: View {
    let points: [StellarEarnHistory.Point]
    @Binding var range: StellarRateRange
    let isLoading: Bool
    let failed: Bool
    /// The app's language: the axis labels are drawn once, so they are formatted in it explicitly.
    @Environment(\.locale) private var locale

    /// One snapshot, in percent (4.21 for 4.21%).
    struct Sample: Identifiable, Equatable {
        let time: Date
        let apy: Double
        let utilization: Double
        var id: Date { time }
    }

    /// The snapshots in time order, each in percent; one whose time can't be read is left out.
    static func samples(_ points: [StellarEarnHistory.Point]) -> [Sample] {
        points.compactMap { point in
            guard let time = StellarFormat.date(point.t), point.supplyApy.isFinite, point.utilization.isFinite else { return nil }
            return Sample(time: time, apy: point.supplyApyPercent, utilization: point.utilizationPercent)
        }
        .sorted { $0.time < $1.time }
    }

    /// The plotted range with a little headroom, as `PriceChart`'s: an area mark anchors at zero by default, which would
    /// flatten a rate moving between 4.1% and 4.3% into a ruler, so the fill starts at this floor instead. Never below 0.
    static func domain(_ samples: [Sample]) -> ClosedRange<Double> {
        let values = samples.map(\.apy)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.08, abs(high) * 0.02, 0.01)
        return max(0, low - padding)...(high + padding)
    }

    private var samples: [Sample] { Self.samples(points) }

    /// The time axis's labels: hours for a short span, days for a week or a month.
    private var timeFormat: Date.FormatStyle {
        guard let first = samples.first?.time, let last = samples.last?.time, last.timeIntervalSince(first) > 36 * 3600 else {
            return Date.FormatStyle.dateTime.hour().locale(locale)
        }
        return Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            chart
                .frame(height: 240)
            rangePicker
        }
    }

    private var title: Text {
        switch range {
        case .week: Text("Supply APY over the past week", tableName: "StellarEarn", comment: "Stellar Earn's chart view: the title over the chart of the market's supply rate for the last 7 days. APY: annual percentage yield")
        case .month: Text("Supply APY over the past month", tableName: "StellarEarn", comment: "Stellar Earn's chart view: the title over the chart of the market's supply rate for the last 30 days. APY: annual percentage yield")
        }
    }

    @ViewBuilder private var chart: some View {
        let samples = self.samples
        if samples.count >= 2 {
            let domain = Self.domain(samples)
            VStack(spacing: 6) {
                Chart(samples) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value(StellarEarnWords.supplyAPY, sample.apy))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.brand)
                    AreaMark(x: .value("Time", sample.time), yStart: .value("Floor", domain.lowerBound), yEnd: .value(StellarEarnWords.supplyAPY, sample.apy))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Color.brand.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                }
                .chartYScale(domain: domain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeFormat, centered: true) } }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine()
                        AxisValueLabel { if let rate = value.as(Double.self) { Text(verbatim: Self.axis(rate, span: domain.upperBound - domain.lowerBound)) } }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(Self.spokenRange(samples.map(\.apy)))
                // The pool's utilization, a thin line under the rate on the same time axis: what moves the rate.
                Chart(samples) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value(StellarEarnWords.utilization, sample.utilization))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 34)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StellarEarnWords.utilization)
                .accessibilityValue(Self.spokenRange(samples.map(\.utilization)))
            }
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            ContentUnavailableView {
                Label("Chart Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Paragraph(LocalizedStringResource("Blend's rate history couldn't be loaded. Retrying every 30 seconds.", table: "StellarEarn", comment: "Stellar Earn's chart view, in place of the chart: the market's rate history couldn't be read; DyorHQ tries again by itself. Blend is a protocol's name, never translated"))
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text("No Rate History Yet", tableName: "StellarEarn", comment: "Stellar Earn's chart view, in place of the chart: DyorHQ hasn't recorded enough of this market's rates to draw one (title case)")
                } icon: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                }
            } description: {
                Paragraph(LocalizedStringResource("DyorHQ records this market's rate every 10 minutes from when it's listed.", table: "StellarEarn", comment: "Stellar Earn's chart view, under No Rate History Yet: where the chart's points come from. DyorHQ is never translated"))
            }
        }
    }

    /// 7D and 30D, as Perps' timeframes: the chosen one bold on a filled capsule.
    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(StellarRateRange.allCases) { option in
                let active = range == option
                Button {
                    if range != option { Haptics.selection(); range = option }
                } label: {
                    Self.chip(option)
                        .font(.caption.weight(active ? .bold : .regular))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? Color(.tertiarySystemFill) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    /// A range's chip: Monad's own reporting periods, 7D and 30D.
    static func chip(_ range: StellarRateRange) -> Text {
        switch range {
        case .week: Text("7D")
        case .month: Text("30D")
        }
    }

    /// A rate on the axis, with as many decimals as the plotted span needs to tell neighbouring ticks apart.
    static func axis(_ percent: Double, span: Double) -> String {
        let digits = span >= 5 ? 0 : span >= 0.5 ? 1 : 2
        return NumberStyle.percent(percent, fractionDigits: digits, signed: false)
    }

    /// A line in words, for VoiceOver: from its first value to its last.
    static func spokenRange(_ values: [Double]) -> Text {
        let first = NumberStyle.percent(values.first ?? 0, signed: false)
        let last = NumberStyle.percent(values.last ?? 0, signed: false)
        return Text("From \(first) to \(last)", tableName: "StellarEarn", comment: "VoiceOver: the value of a chart on Stellar Earn, a rate's first and last points over the range shown. The values are percentages (3.10%, 4.21%)")
    }
}
#endif
