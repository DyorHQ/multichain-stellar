// Stellar copy of ios/DyorHQ/Profile/RecentActivityView.swift RecentActivityRow (42cd8c7 sha256:aaf303437a65)
// One row of Stellar activity (docs/DESIGN-stellar-parity.md §8.12.3). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// One row of the account's Stellar activity (`/v1/activity`): an icon disc, the title and subtitle Monad's Recent Activity
/// words its rows with (`StellarActivityPresenter`, past tense, never the server's English for a kind it knows), the
/// network fee the account paid, and how long ago; it opens the transaction on StellarExpert. A transaction not seen
/// confirmed yet, or one that failed, says so as Monad's pending rows do.
struct StellarActivityRow: View {
    let item: StellarActivityItem

    private var presentation: StellarActivityPresentation { StellarActivityPresenter.present(item) }

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
        let presentation = self.presentation
        return HStack(spacing: 12) {
            Image(systemName: Self.symbol(status: item.status) ?? presentation.symbol)
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Self.title(presentation.title).font(.subheadline.weight(.medium))
                if let status = Self.statusText(item.status) {
                    status.font(.caption).foregroundStyle(.secondary)
                } else if let subtitle = presentation.subtitle {
                    Self.subtitle(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let fee = Self.fee(presentation) {
                    fee.font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let at = StellarFormat.date(item.at) {
                    Text("\(RelativeTime.short(Int(at.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
                }
                if page != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .contentShape(Rectangle())
    }

    /// Monad's pending rows' symbols: sent and not seen confirmed yet, or failed.
    static func symbol(status: String) -> String? {
        switch status {
        case "pending", "submitted": "clock"
        case "failed": "xmark.circle"
        default: nil
        }
    }

    /// Monad's pending rows' words, in place of the subtitle.
    static func statusText(_ status: String) -> Text? {
        switch status {
        case "pending", "submitted": Text("Sent — confirmation not seen yet")
        case "failed": Text("Reverted — only the network fee was spent")
        default: nil
        }
    }

    static func title(_ title: StellarActivityPresentation.Title) -> Text {
        switch title {
        case .launched(let symbol): Text("Launched $\(symbol)")
        case .bought(let symbol): Text("Bought \(symbol)")
        case .sold(let symbol): Text("Sold \(symbol)")
        case .collectedCreatorFees(let symbol): Text("Collected \(symbol) creator fees")
        case .graduated(let symbol): Text("\(symbol) graduated")
        case .published(let name): Text("Published \(name)")
        case .collected(let name): Text("Collected \(name)")
        case .swapped: Text("Swapped")
        case .sent(let code):
            Text("Sent \(code)", tableName: "StellarCommon", comment: "A row of Stellar activity: the account sent this asset to another account. The value is its code (XLM, USDC), never translated")
        case .supplied(let code):
            Text("Supplied \(code)", tableName: "StellarCommon", comment: "A row of Stellar activity: the account lent this asset on Earn (Blend). The value is its code (XLM, USDC)")
        case .withdrew(let code):
            Text("Withdrew \(code)", tableName: "StellarCommon", comment: "A row of Stellar activity: the account took this asset back from Earn (Blend). The value is its code (XLM, USDC)")
        case .bridged(let code):
            Text("Bridged \(code)", tableName: "StellarCommon", comment: "A row of Stellar activity: the account moved this asset between Monad and Stellar. The value is its code (USDC)")
        case .enabled(let code):
            Text("Enabled \(code)", tableName: "StellarCommon", comment: "A row of Stellar activity: the account enabled this asset (a Stellar trustline), so it can hold it. The value is its code (USDC)")
        case .setUpAccount:
            Text("Set up your account", tableName: "StellarCommon", comment: "A row of Stellar activity: the account was created on the Stellar network")
        case .restoredData:
            Text("Restored data", tableName: "StellarCommon", comment: "A row of Stellar activity: the account paid to bring back data the Stellar network had archived")
        case .fundedWithFriendbot:
            Text("Funded with Friendbot", tableName: "StellarCommon", comment: "A row of Stellar activity: the account got its one grant of free test XLM from Friendbot, the Stellar test network's faucet. Friendbot is a name, never translated")
        case .other(let words): Text(verbatim: words)
        }
    }

    static func subtitle(_ subtitle: StellarActivityPresentation.Subtitle) -> Text {
        switch subtitle {
        case .name(let name), .venue(let name): Text(verbatim: name)
        case .trade(let got, let paid):
            Text("\(amount(got)) \(got.code) for \(amount(paid)) \(paid.code)")
        case .amount(let value): Text(verbatim: written(value))
        case .perEdition(let price):
            Text("\(written(price)) per edition", tableName: "StellarCommon", comment: "A row of Stellar activity, under a published Moment: what one edition costs. The value is an amount with its code (1.5 USDC)")
        case .editions(let count, let total?): Text("\(count) editions · \(written(total))")
        case .editions(let count, nil): Text("\(count) editions")
        case .swap(let paid, let got): Text(verbatim: "\(written(paid)) → \(written(got))")
        case .to(let address, let value?):
            Text("\(written(value)) to \(StellarAccountID(address)?.short ?? address)", tableName: "StellarCommon", comment: "A row of Stellar activity, under a send: the amount with its code (12.5 XLM), then the short address it went to (GBQ4…7ZKD)")
        case .to(let address, nil): Text(verbatim: StellarAccountID(address)?.short ?? address)
        case .pool(let pool): Text(verbatim: "Blend · \(pool)") // not localized: Blend is a protocol's name, the pool's is its own
        case .route(let from, let to): Text(verbatim: "\(from) → \(to)") // not localized: two networks' names
        }
    }

    /// "Fee 0.0154 XLM", or "Fee paid by DyorHQ"; nil when the fee isn't known.
    static func fee(_ presentation: StellarActivityPresentation) -> Text? {
        if presentation.paidByDyorHQ {
            return Text("Fee paid by DyorHQ", tableName: "StellarCommon", comment: "A row of Stellar activity: DyorHQ paid this transaction's network fee (a new account's setup, or a first swap into XLM). DyorHQ is never translated")
        }
        guard let stroops = presentation.feeStroops else { return nil }
        return Text("Fee \(StellarFormat.xlm(stroops: stroops))", tableName: "StellarCommon", comment: "A row of Stellar activity: the network fee the account paid for this transaction. The value is an amount in XLM (0.0154 XLM)")
    }

    private static func amount(_ value: StellarActivityAmount) -> String {
        StellarFormat.units(value.units, decimals: value.decimals, compact: true)
    }

    private static func written(_ value: StellarActivityAmount) -> String {
        StellarFormat.amount(value.units, code: value.code, decimals: value.decimals, compact: true)
    }
}
#endif
