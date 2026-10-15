import StellarKit
import SwiftUI

/// Every Stellar transaction goes through here: what will happen, in words built on the phone from the plan (not from
/// server text), the most its network fees can come to (worked out on the phone from each step's own transaction; that
/// DyorHQ pays, only where the phone checked it), then one confirmation that runs every step with live progress. A step's headline is the same title Activity gives the transaction once it is sent (`LiteTitles`).
struct ConfirmSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liteStyle) private var style
    let action: PreparedAction
    var onDone: ([TxStatus]) -> Void = { _ in }

    @State private var progress: [String: Progress] = [:]
    @State private var running = false
    @State private var finished = false
    @State private var error: String?

    enum Progress: Equatable { case preparing, signing, sent, confirmed }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(action.plan.steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            stepIcon(step.id)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: action.title(of: step)).font(.headline)
                                if let intent = step.intent { IntentLines(intent: intent) }
                                if let p = progress[step.id] { Text(label(p)).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text(verbatim: action.title)
                        Spacer()
                        if store.isTestnet {
                            HStack(spacing: 6) {
                                Text(verbatim: "Stellar")
                                TestnetBadge()
                            }
                            .textCase(nil)
                        }
                    }
                }
                Section {
                    feeRow
                    if !action.limits.isEmpty {
                        ForEach(action.limits.sorted(by: { $0.key < $1.key }), id: \.key) { asset, units in
                            LabeledContent(tr("At most"), value: "\(StellarAmount.format(units, maxFraction: 7)) \(store.asset(asset)?.code ?? tr("tokens"))")
                        }
                    }
                } footer: {
                    LiteParagraph(tr("Your phone checks every transaction against what you see here before it signs. Anything else is refused."))
                }
                if let error {
                    Section { LiteInlineError(message: error) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: finished ? tr("Done") : (error == nil ? tr("Confirm") : tr("Close")), busy: running) {
                    if finished || error != nil { dismiss() } else { Task { await confirm() } }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(tr("Review"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() }.disabled(running) } }
        }
        .interactiveDismissDisabled(running)
        .liteFormSheet()
    }

    /// "Max network fee: Up to 0.0154 XLM" (Monad's wording, §4.6); DyorHQ's payment only when the phone checked it.
    @ViewBuilder
    private var feeRow: some View {
        let summary = StellarFeeSummary(action.fees)
        switch summary.value {
        case .paidByDyorHQ where action.sponsorVerified:
            LabeledContent(tr("Network fee"), value: tr("Paid by DyorHQ"))
        case .upTo(let stroops):
            LabeledContent(tr("Max network fee"), value: tr("Up to \(Self.xlm(stroops))"))
        case let .upToAndMore(stroops, steps):
            LabeledContent(tr("Max network fee"), value: tr("Up to \(Self.xlm(stroops)) + \(steps) more steps"))
        case .pricedAsSigned, .paidByDyorHQ:
            LabeledContent(tr("Max network fee"), value: tr("Priced as each step is signed"))
        }
    }

    /// "0.0154 XLM": XLM is never translated.
    private static func xlm(_ stroops: Int64) -> String { "\(LiteFormat.units(stroops)) XLM" }

    private func label(_ p: Progress) -> String {
        switch p {
        case .preparing: tr("Preparing…")
        case .signing: tr("Signing…")
        case .sent: tr("Sent, waiting for the network…")
        case .confirmed: tr("Confirmed")
        }
    }

    @ViewBuilder
    private func stepIcon(_ id: String) -> some View {
        let p = progress[id]
        if p == .confirmed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(style.positive)
        } else if p != nil && running {
            ProgressView()
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    /// One signing run for the whole action (App Lock once when it applies, or the passkey per step), in the store's
    /// task: the plan settles there even if this sheet closes.
    private func confirm() async {
        running = true
        error = nil
        do {
            let results = try await store.run(action, reason: tr("Confirm \(action.title)")) { event in
                Task { @MainActor in
                    switch event {
                    case let .building(id, _): progress[id] = .preparing
                    case let .signing(id, _): progress[id] = .signing
                    case let .submitted(id, _): progress[id] = .sent
                    case let .confirmed(id, _): progress[id] = .confirmed
                    }
                }
            }
            finished = true
            onDone(results)
        } catch {
            self.error = LiteErrorText.describe(error)
        }
        running = false
    }
}

/// The phone's own description of an intent, from its structured fields.
@MainActor
struct IntentLines: View {
    @Environment(LiteStore.self) private var store
    let intent: Intent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { Text(verbatim: $0).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private var lines: [String] {
        var out: [String] = []
        for (asset, units) in intent.spend.sorted(by: { $0.key < $1.key }) {
            out.append(tr("You pay up to \(StellarAmount.format(units)) \(store.asset(asset)?.code ?? symbol(asset))"))
        }
        for (asset, units) in (intent.receive ?? [:]).sorted(by: { $0.key < $1.key }) where units != "0" {
            out.append(tr("You receive at least \(StellarAmount.format(units)) \(store.asset(asset)?.code ?? symbol(asset))"))
        }
        if let venue = intent.display?["venue"]?.text { out.append(tr("Route: \(LiteTitles.venue(venue))")) }
        // The bound recipient (§5.2), else what the server displays.
        if let to = intent.to ?? intent.display?["to"]?.text { out.append(tr("To \(LiteFormat.short(to))")) }
        if let memo = intent.memo?.value ?? intent.display?["memo"]?.text, !memo.isEmpty { out.append(tr("Memo \(memo)")) }
        if intent.spend.isEmpty && (intent.receive ?? [:]).isEmpty { out.append(neutralLine) }
        return out
    }

    private var neutralLine: String {
        switch intent.kind {
        case "trust": tr("Enables an asset on your account. Stellar holds some of your XLM while it is enabled.")
        case "activate": tr("Creates your Stellar account.")
        case "launch_graduate": tr("Moves this launch to Soroswap. Spends nothing.")
        case "launch_claim": tr("Sends your creator fees to you.")
        case "moment_publish": tr("Publishes your Moment. Spends nothing.")
        default: tr("Spends nothing.")
        }
    }

    private func symbol(_ contract: String) -> String {
        store.launches.first { $0.token == contract }?.symbol ?? tr("tokens")
    }
}
