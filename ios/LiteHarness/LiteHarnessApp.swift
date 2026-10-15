// LiteHarness: runs DyorHQ's Stellar screens on their own, for internal testers, without the DyorHQ app.
// Its account is a 24-word phrase generated on first launch and kept in the Keychain (this device only), with the
// Stellar seed it derives; the same SEP-5 account opens in DyorHQ from that phrase. It plays the host the app plays: it
// owns the account's `LiteSession` (a seed account: the sign-in is silent, and Face ID comes once per confirmed action),
// draws a header and a network chip for Stellar Home, and shows the setup run (the invite and account-setup steps, which
// the app shows in its network sheet). Nothing locks (decision 6).
import DyorLite
import Security
import StellarKit
import SwiftUI

@main
struct LiteHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            HarnessRoot()
                .tint(LiteStyle.default.accent) // DyorHQ's app tint
        }
    }
}

struct HarnessRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: LiteSession?
    @State private var tab: LiteTab = .home
    @State private var setup = false
    @State private var monadNote = false

    var body: some View {
        Group {
            if let session {
                LiteRootView(session: session, selection: $tab, style: .default, chrome: chrome(for: session))
                    .sheet(isPresented: $setup) { HarnessSetupView(session: session) }
            } else {
                ProgressView().task {
                    let session = HarnessAccount.session()
                    self.session = session
                    await session.resumeAtLaunch()
                }
            }
        }
        // The session renews while the app is in front; nothing secret is held when it leaves.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session?.appDidBecomeActive()
            case .background: session?.appDidEnterBackground()
            default: break
            }
        }
        .alert("Monad lives in the DyorHQ app", isPresented: $monadNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This internal build only runs Stellar. In DyorHQ, this button takes you back to Monad.")
        }
    }

    private func chrome(for session: LiteSession) -> LiteChrome {
        LiteChrome(
            header: { context in AnyView(HarnessHeader(context: context)) },
            networkChip: { AnyView(HarnessChip { setup = true }) },
            switchToMonad: { monadNote = true }
        )
    }
}

/// Stands in for DyorHQ's Home header: the search capsule with the last read's status.
struct HarnessHeader: View {
    let context: LiteHeaderContext

    var body: some View {
        Button(action: context.openSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search tokens…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let error = context.error {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(LiteStyle.default.attention).accessibilityLabel(error)
                } else if let updatedAt = context.updatedAt {
                    Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }
}

/// Stands in for DyorHQ's network chip: here it opens the setup steps.
struct HarnessChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: "Stellar").font(.subheadline.weight(.medium))
                Text("Testnet")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LiteStyle.default.attention)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(LiteStyle.default.attention.opacity(0.14), in: Capsule())
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The setup run as a checklist, with the step that needs the tester: the invite code, or the account's setup. It
/// closes itself once the session is ready; ✕ cancels between steps.
struct HarnessSetupView: View {
    let session: LiteSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Steps") {
                    ForEach(session.steps) { row in
                        HStack(spacing: 12) {
                            icon(row.status)
                            Text(title(row.step))
                            Spacer()
                        }
                    }
                }
                switch session.state {
                case .waiting(.invite), .failed(.invite, _):
                    InviteView(session: session)
                case .waiting(.setUp), .failed(.setUp, _):
                    ActivationView(session: session)
                case .failed(_, let failure), .unavailable(let failure):
                    Section {
                        Text(failure.errorDescription ?? "").foregroundStyle(LiteStyle.default.attention)
                        if failure.canRetry { Button("Try again") { Task { await session.retry() } } }
                    }
                case .running:
                    Section { ProgressView().frame(maxWidth: .infinity) }
                case .idle:
                    Section { Button("Start") { Task { await session.run() } } }
                case .ready, .waiting:
                    EmptyView()
                }
            }
            .navigationTitle("Switching to Stellar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        session.cancel()
                        dismiss()
                    }
                    .disabled(session.isSending)
                }
            }
            .task(id: session.state) { if session.state == .ready { dismiss() } }
        }
        .interactiveDismissDisabled(session.isSending)
    }

    private func title(_ step: LiteSession.Step) -> String {
        switch step {
        case .signIn: "Sign in"
        case .invite: "Enter your invite code"
        case .setUp: "Set up your Stellar account"
        default: ""
        }
    }

    @ViewBuilder
    private func icon(_ status: LiteSession.StepStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .needsYou: Image(systemName: "circle.inset.filled").foregroundStyle(LiteStyle.default.accent)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(LiteStyle.default.positive)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LiteStyle.default.attention)
        }
    }
}

/// First sign-in for an account: an invite code binds it to the internal-tester allowlist.
struct InviteView: View {
    let session: LiteSession
    @State private var code = ""

    var body: some View {
        Section {
            TextField("Invite code", text: $code)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.join)
                .onSubmit(join)
            if case .failed(.invite, let failure) = session.state {
                Text(failure.errorDescription ?? "").font(.footnote).foregroundStyle(LiteStyle.default.attention)
            }
            Button("Join", action: join)
                .disabled(code.filter { !$0.isWhitespace }.count < 8 || session.state == .running)
        } header: {
            Text("Enter your invite code")
        } footer: {
            Text("DyorHQ on Stellar is invite-only while we test it. You need the code only once.")
        }
    }

    private func join() {
        Task { await session.join(invite: code) }
    }
}

/// Creates the Stellar account (Friendbot on testnet) and enables USDC: one tap, with Face ID once for the Enable USDC
/// transaction, whose fee and reserve are the account's own.
struct ActivationView: View {
    let session: LiteSession

    var body: some View {
        Section {
            if case .failed(.setUp, let failure) = session.state {
                Text(failure.errorDescription ?? "").font(.footnote).foregroundStyle(LiteStyle.default.attention)
            }
            Button(session.isSending ? "Setting up…" : "Set up") { Task { await session.setUp() } }
                .disabled(session.isSending)
        } header: {
            Text("Set up your Stellar account")
        } footer: {
            Text(price)
        }
    }

    /// What Enable USDC costs, as the session priced it: its estimate until the step is built, then its own fee.
    private var price: String {
        let base = "Creates your test account with test XLM from Stellar's testnet faucet, then enables USDC."
        guard let fee = session.setupFee, let reserve = session.baseReserve else { return base }
        let holds = StellarAmount.format(reserve * Int64(max(1, fee.newReserves)))
        return base + " Holds \(holds) XLM · network fee up to \(StellarAmount.format(fee.userMax)) XLM, paid from your test XLM."
    }
}

enum HarnessConfig {
    static var environment: LiteEnvironment {
        let url = Bundle.main.object(forInfoDictionaryKey: "LITE_API_URL") as? String ?? ""
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
        return LiteEnvironment(apiURL: URL(string: url)!, pinned: .testnet, buildNumber: build)
    }
}

enum HarnessAccount {
    private static let slot = "harness-entropy"

    /// The harness account's session: a seed account, whose sign-in is silent and whose actions ask Face ID once each.
    @MainActor
    static func session() -> LiteSession {
        let keys = provider()
        return LiteSession(env: HarnessConfig.environment, stellarAddress: keys.address, monad: nil, keys: keys)
    }

    /// The harness account's key: its phrase's entropy, and the Stellar seed the phrase derives (SEP-5), both in the
    /// Keychain. App Lock always applies here: every confirmed action asks for Face ID once.
    static func provider() -> StoredSeedKeyProvider {
        let entropy = StellarKeychain.seed(account: slot, network: "testnet") ?? {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            try? StellarKeychain.saveSeed(bytes, account: slot, network: "testnet")
            return bytes
        }()
        let signer = Mnemonic.phrase(entropy: entropy).flatMap { try? StellarDerivation.sep5(mnemonic: $0) }
        let address = signer?.address ?? ""
        if let signer, StellarKeychain.seed(account: address, network: "testnet") == nil, let seed = try? StrKey.decode(.seed, signer.secret) {
            try? StellarKeychain.saveSeed(seed, account: address, network: "testnet")
        }
        return StoredSeedKeyProvider(address: address, methodLabel: "Test phrase (this device)", network: "testnet", appLock: { true })
    }
}
