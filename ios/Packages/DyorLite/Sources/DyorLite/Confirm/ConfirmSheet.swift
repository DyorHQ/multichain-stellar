import StellarKit
import SwiftUI

/// Every Lite transaction goes through here: what will happen, in words built on the phone from the plan (not from
/// server text), "Network fee: paid by DyorHQ", then one confirmation that runs every step with live progress.
struct ConfirmSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let action: PreparedAction
    var onDone: ([TxStatus]) -> Void = { _ in }

    @State private var progress: [String: String] = [:]
    @State private var running = false
    @State private var finished = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(action.plan.steps) { step in
                        HStack(alignment: .top, spacing: 12) {
                            stepIcon(step.id)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.label).font(.headline)
                                if let intent = step.intent { IntentLines(intent: intent) }
                                if let p = progress[step.id] { Text(p).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack { Text(action.title); Spacer(); if store.network.name == "testnet" { TestnetBadge() } }
                }
                Section {
                    LabeledContent("Network fee", value: "Paid by DyorHQ")
                    if !action.limits.isEmpty {
                        ForEach(action.limits.sorted(by: { $0.key < $1.key }), id: \.key) { asset, units in
                            LabeledContent("At most", value: "\(Amount.format(units, maxFraction: 7)) \(store.asset(asset)?.code ?? "tokens")")
                        }
                    }
                } footer: {
                    Text("Your phone checks every transaction against what you see here before it signs. Anything else is refused.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LiteTheme.negative) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: finished ? "Done" : (error == nil ? "Confirm" : "Close"), busy: running) {
                    if finished || error != nil { dismiss() } else { Task { await confirm() } }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(running) } }
        }
        .interactiveDismissDisabled(running)
    }

    @ViewBuilder
    private func stepIcon(_ id: String) -> some View {
        let p = progress[id]
        if p == "Confirmed" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LiteTheme.positive)
        } else if p != nil && running {
            ProgressView()
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func confirm() async {
        running = true
        error = nil
        do {
            let results = try await store.run(action.plan, limits: action.limits, reason: action.title) { event in
                Task { @MainActor in
                    switch event {
                    case let .building(id, _): progress[id] = "Preparing…"
                    case let .signing(id, _): progress[id] = "Signing…"
                    case let .submitted(id, _): progress[id] = "Sent, waiting for the network…"
                    case let .confirmed(id, _): progress[id] = "Confirmed"
                    }
                }
            }
            finished = true
            onDone(results)
        } catch {
            self.error = describe(error)
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
            ForEach(lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private var lines: [String] {
        var out: [String] = []
        for (asset, units) in intent.spend.sorted(by: { $0.key < $1.key }) {
            out.append("You pay up to \(Amount.format(units)) \(store.asset(asset)?.code ?? symbol(asset))")
        }
        for (asset, units) in (intent.receive ?? [:]).sorted(by: { $0.key < $1.key }) where units != "0" {
            out.append("You receive at least \(Amount.format(units)) \(store.asset(asset)?.code ?? symbol(asset))")
        }
        if let venue = intent.display?["venue"]?.text { out.append("Route: \(venue)") }
        if let to = intent.display?["to"]?.text { out.append("To \(shortAddress(to))") }
        if let memo = intent.display?["memo"]?.text, !memo.isEmpty { out.append("Memo \(memo)") }
        if intent.spend.isEmpty && (intent.receive ?? [:]).isEmpty { out.append(neutralLine) }
        return out
    }

    private var neutralLine: String {
        switch intent.kind {
        case "trust": return "Enables an asset on your account. The reserve is paid by DyorHQ."
        case "activate": return "Creates your Stellar account. Paid by DyorHQ."
        case "launch_graduate": return "Moves this launch to Soroswap. Spends nothing."
        case "launch_claim": return "Sends your creator fees to you."
        case "moment_publish": return "Publishes your Moment. Spends nothing."
        default: return "Spends nothing."
        }
    }

    private func symbol(_ contract: String) -> String {
        store.launches.first { $0.token == contract }?.symbol ?? "tokens"
    }
}
