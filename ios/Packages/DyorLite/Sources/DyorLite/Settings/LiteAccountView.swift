import StellarKit
import SwiftUI

/// Profile › Network › Stellar account (design spec §3.5): the Stellar address, how it is secured, the network, the
/// secret key for accounts that can export it, test XLM, and signing out of Stellar. Pushed inside Profile's own
/// navigation stack: it has no stack or Close of its own.
@MainActor
public struct LiteAccountView: View {
    private let session: LiteSession
    @State private var secret: String?
    @State private var error: String?
    @State private var copied = false
    @State private var confirmSignOut = false
    @State private var busy = false
    @Environment(\.liteStyle) private var style

    public init(session: LiteSession) { self.session = session }

    private var store: LiteStore? { session.home == .ready ? session.store : nil }

    public var body: some View {
        Form {
            Section {
                if let address = session.address {
                    // A row, not a button: its label stays in the text colour, and only the copy icon takes the tint.
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(verbatim: shortAddress(address))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(verbatim: address).speechSpellsOutCharacters())
                            Button {
                                copyToPasteboard(address)
                                copied = true
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(copied ? tr("Copied") : tr("Copy address"))
                        }
                    } label: {
                        Text(tr("Stellar address"))
                    }
                }
                if let method = session.methodLabel, !method.isEmpty {
                    LabeledContent(tr("Secured by"), value: method)
                }
                LabeledContent(tr("Network")) {
                    HStack(spacing: 6) {
                        Text(verbatim: "Stellar")
                        if session.isTestnet { TestnetBadge() }
                    }
                }
            }
            if session.canExportSecret {
                Section {
                    if let secret {
                        Text(verbatim: secret).font(.footnote.monospaced()).textSelection(.enabled)
                        LiteParagraph(tr("Anyone with this key controls your Stellar account. Never share it."))
                            .font(.footnote)
                            .foregroundStyle(style.negative)
                    } else {
                        Button(tr("Show Stellar secret key")) {
                            Task {
                                do { secret = try await session.revealSecret(reason: tr("Show your Stellar secret key")) } catch { self.error = LiteErrorText.describe(error) }
                            }
                        }
                    }
                } footer: {
                    LiteParagraph(tr("Import it into any Stellar wallet (Freighter, LOBSTR, xBull) to reach the same account."))
                }
            }
            if session.isTestnet, let store, let amount = ReceiveSheet.faucetAmount(store.config) {
                Section {
                    Button(tr("Get \(amount) test XLM")) {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await store.faucet() } catch { self.error = LiteErrorText.describe(error) }
                        }
                    }
                    .disabled(busy)
                } footer: {
                    LiteParagraph(tr("Testnet balances have no value. You pay Stellar's network fees in XLM, as you pay MON on Monad."))
                }
            }
            if let error { Section { LiteInlineError(message: error) } }
            if session.store != nil {
                Section {
                    Button(tr("Sign out of Stellar"), role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .navigationTitle(tr("Stellar account"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(tr("Sign out of Stellar on this iPhone?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(tr("Sign out of Stellar"), role: .destructive) { Task { await session.signOut() } }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("You'll sign in again to use Stellar. Your Stellar funds stay in your account."))
        }
        .onDisappear { secret = nil }
    }
}

/// Profile › Wallet › Receive while on Stellar: the Stellar address and its QR code (receiving needs nothing but the
/// address). Presented as a sheet; it has its own Close.
@MainActor
public struct LiteDepositSheet: View {
    private let session: LiteSession

    public init(session: LiteSession) { self.session = session }

    public var body: some View {
        if let address = session.address {
            ReceiveSheet(address: address, store: session.store)
        } else {
            LiteRestingSheet(session: session)
        }
    }
}

/// Profile › Wallet › Send while on Stellar: Withdraw, once the session is ready. Presented as a sheet; it has its own
/// Close.
@MainActor
public struct LiteWithdrawSheet: View {
    private let session: LiteSession

    public init(session: LiteSession) { self.session = session }

    public var body: some View {
        if session.home == .ready, let store = session.store {
            SendSheet().environment(store)
        } else {
            LiteRestingSheet(session: session)
        }
    }
}

/// A Stellar sheet whose session is paused or still opening: what Home's card says.
struct LiteRestingSheet: View {
    let session: LiteSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if case .paused(let failure) = session.home {
                    ContentUnavailableView(failure.errorDescription ?? "", systemImage: "pause.circle")
                } else {
                    ProgressView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Close")) { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
