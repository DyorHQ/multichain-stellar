import StellarKit
import SwiftUI

struct LiteSettingsView: View {
    @Environment(LiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSwitchToPro: () -> Void
    @State private var secret: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Stellar address") { Text(shortAddress(store.keys.address)).font(.body.monospaced()) }
                    LabeledContent("Secured by", value: store.keys.methodLabel)
                    LabeledContent("Network", value: store.network.name.capitalized)
                    if let r = store.account?.reserves { LabeledContent("Reserves paid by DyorHQ", value: "\(r.sponsoredByDyorHQ)") }
                }
                if store.keys.canExportSecret {
                    Section {
                        if let secret {
                            Text(secret).font(.footnote.monospaced()).textSelection(.enabled)
                            Text("Anyone with this key controls your Stellar account. Never share it.").font(.footnote).foregroundStyle(LiteTheme.negative)
                        } else {
                            Button("Show Stellar secret key") {
                                Task {
                                    do { secret = try await store.keys.signer(reason: "Show your Stellar secret key").secret } catch { self.error = describe(error) }
                                }
                            }
                        }
                    } footer: {
                        Text("Import it into any Stellar wallet (Freighter, LOBSTR, xBull) to reach the same account.")
                    }
                } else {
                    Section { Text("Your Stellar account restores from the same recovery phrase as your DyorHQ account (SEP-5).").font(.footnote) }
                }
                if store.network.name == "testnet" {
                    Section("Testnet") {
                        Button("Get 10,000 test XLM") { Task { do { try await store.faucet() } catch { self.error = describe(error) } } }
                        Text("Internal testing build. Balances on testnet have no value.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Switch to Pro (Monad)") { dismiss(); onSwitchToPro() }
                    Button("Sign out of Lite", role: .destructive) { Task { await store.signOutOfLite(); dismiss() } }
                }
                if let error { Section { Text(error).foregroundStyle(LiteTheme.negative) } }
            }
            .navigationTitle("Lite settings")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onDisappear { secret = nil }
        }
    }
}
