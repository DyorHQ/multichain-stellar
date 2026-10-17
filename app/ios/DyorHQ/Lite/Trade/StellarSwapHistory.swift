// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapHistoryItem (42cd8c7 sha256:3e963320742b)
// Stellar copy of ios/DyorHQ/Swap/SwapView.swift SwapHistoryRow (42cd8c7 sha256:47e838c8160c)
// Swap History on Stellar (docs/DESIGN-stellar-parity.md §8.6.1). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// One row of Swap History: a "sold → bought" line and when, linking to the transaction on StellarExpert.
struct StellarSwapHistoryItem: Identifiable, Hashable {
    let id: String
    let hash: String?
    let time: Date
    let text: String

    /// The account's settled swaps among `activity` (DyorHQ's `/v1/activity`), newest first: a swap that failed or isn't
    /// confirmed yet isn't one. `code` names an asset the item gives by its contract.
    static func items(_ activity: [StellarActivityItem], code: (String) -> String) -> [StellarSwapHistoryItem] {
        activity.compactMap { item in
            guard item.kind == "swap", item.status == "success", let time = StellarFormat.date(item.at),
                  let text = describe(item, code: code) else { return nil }
            return StellarSwapHistoryItem(id: item.id, hash: item.hash, time: time, text: text)
        }
        .sorted { $0.time > $1.time }
    }

    /// "10 XLM → 1.89 USDC": what the swap spent, and what it really brought (the transaction's result, never its
    /// minimum). When the result wasn't read, the bought asset is named without an amount, never "0 USDC". Nil for an
    /// item that doesn't say what it sold or bought.
    static func describe(_ item: StellarActivityItem, code: (String) -> String) -> String? {
        let display = item.display ?? [:]
        guard let sell = name(display["sell"], code: code), let buy = name(display["buy"], code: code) else { return nil }
        let spent = units(display["amountIn"]).map { StellarFormat.amount($0, code: sell, compact: true) } ?? sell
        let got = (item.result?.amountOut).flatMap { Int64($0) }.map { StellarFormat.amount($0, code: buy, compact: true) } ?? buy
        return "\(spent) → \(got)" // not localized: two amounts with their codes
    }

    /// An asset a swap names (a registry id, a contract, CODE:ISSUER or "native"), by the code the phone knows it by.
    private static func name(_ value: StellarJSON?, code: (String) -> String) -> String? {
        guard case .string(let id)? = value, !id.isEmpty else { return nil }
        return id == "native" ? "XLM" : code(id)
    }

    /// An amount in base units, as the server writes them.
    private static func units(_ value: StellarJSON?) -> Int64? {
        switch value {
        case .string(let text)?: Int64(text).flatMap { $0 >= 0 ? $0 : nil }
        case .number(let number)? where number.isFinite && number >= 0 && number < 9e18: Int64(number)
        default: nil
        }
    }
}

struct StellarSwapHistoryRow: View {
    let item: StellarSwapHistoryItem

    private var page: URL? {
        item.hash.flatMap { StellarExplorer.transaction($0, network: LiteGate.pinned.network) }
    }

    var body: some View {
        Group {
            if let page {
                Link(destination: page) { content }.foregroundStyle(.primary)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text).font(.subheadline.weight(.medium)).monospacedDigit()
                Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if page != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}
#endif
