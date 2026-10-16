import StellarKit
import SwiftUI

/// USDC between Monad and Stellar. Testnet: Circle CCTP. Monad → Stellar is signed by the account's Monad wallet (the
/// host provides it); Stellar → Monad burns here and is claimed on Monad by the Monad wallet once Circle attests.
struct BridgeSheet: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var toStellar: Bool
    @State private var amount = ""
    @State private var monadAddress = ""
    @State private var transfer: BridgeTransfer?
    @State private var status: BridgeStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var prepared: PreparedAction?

    /// `toStellar`: Monad → Stellar at first, else Stellar → Monad.
    init(toStellar: Bool = true) {
        _toStellar = State(initialValue: toStellar)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(), selection: $toStellar) {
                        // Network names, never translated.
                        Text(verbatim: "Monad → Stellar").tag(true)
                        Text(verbatim: "Stellar → Monad").tag(false)
                    }
                    .pickerStyle(.segmented)
                    AmountInput(label: "USDC", text: $amount, code: "USDC", maxUnits: toStellar ? nil : store.account?.balance("USDC"))
                    if !toStellar && store.monad == nil {
                        TextField(tr("Monad address (0x…)"), text: $monadAddress).font(.body.monospaced()).autocorrectionDisabled()
                    }
                } footer: {
                    LiteParagraph(toStellar
                        ? tr("Your Monad wallet sends the USDC. It arrives on Stellar in about a minute.")
                        : tr("The USDC leaves Stellar now. You claim it on Monad with your Monad wallet once Circle confirms, in a few minutes."))
                }
                if let status {
                    Section(tr("Transfer")) {
                        LabeledContent(tr("Status"), value: status.status.replacingOccurrences(of: "_", with: " "))
                        if status.claim != nil, store.monad != nil {
                            LitePrimaryButton(title: tr("Claim on Monad"), busy: busy) { Task { await claim(status) } }
                        }
                        Button(tr("Refresh")) { Task { await refresh() } }
                    }
                }
                if let error { Section { LiteInlineError(message: error) } }
            }
            .safeAreaInset(edge: .bottom) {
                LitePrimaryButton(title: toStellar ? tr("Move to Stellar") : tr("Review"), busy: busy, enabled: StellarAmount.parse(amount) != nil) { Task { await go() } }.padding()
            }
            .navigationTitle(tr("Bridge"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
            .sheet(item: $prepared) { action in
                ConfirmSheet(action: action) { results in
                    Task {
                        if let t = transfer, let hash = results.last?.hash { try? await store.bridgeSourceReported(id: t.id, hash: hash) }
                        await refresh()
                    }
                }
            }
        }
        .liteFormSheet()
    }

    private func go() async {
        guard let units7 = StellarAmount.parse(amount) else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            if toStellar {
                transfer = try await store.bridgeIn(amount6: units7 / 10) // Monad USDC has 6 decimals
                await refresh()
            } else {
                let dest = store.monad?.monadAddress ?? monadAddress
                let (action, t) = try await store.bridgeOutPlan(amount: units7 - units7 % 10, monadAddress: dest)
                transfer = t
                prepared = action
            }
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }

    private func refresh() async {
        guard let t = transfer else { return }
        status = try? await store.bridgeStatus(id: t.id)
    }

    private func claim(_ s: BridgeStatus) async {
        busy = true
        defer { busy = false }
        do {
            try await store.claimOnMonad(s)
            await refresh()
        } catch {
            self.error = LiteErrorText.describe(error)
        }
    }
}
