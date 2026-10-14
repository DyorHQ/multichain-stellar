import DyorKit
import SwiftUI
import UIKit

// The settings screens reached from Profile: wallets, security (passkeys + app lock), notifications, trading
// defaults, language, and the appearance sheet. Plain grouped lists in DyorHQ's system, each doing one real thing.

/// Perpl web links. New users open a Perpl account on the web app first (the on-chain Exchange needs an account
/// before it will report positions or accept the authenticated trading enrollment); this carries the DyorHQ referral.
enum PerplLinks {
    static let signup = URL(string: "https://app.perpl.xyz/trade?ref=H3ehW3FCqoj")!
}

/// Manage the signed-in wallet: its address, how it is secured, and the network it is on.
struct ManageWalletsView: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            if let account = session.account {
                Section {
                    AddressRow(title: "Address", address: account.address)
                    LabeledContent {
                        Text(verbatim: account.method.title)
                    } label: {
                        Text("Sign-in", comment: "How this wallet signs in (Apple, Google, Email…), a noun [tight]")
                    }
                    if let label = account.label { LabeledContent("Account", value: label) }
                } header: {
                    Text("This Wallet")
                } footer: {
                    Paragraph(account.method == .watchOnly
                         ? "You are watching this address. Sign in to create a wallet you can sign with."
                         : account.method == .meraPasskey
                         ? "This wallet is derived from your passkey every time you unlock it; its key is never stored, on this device or on a server. The same passkey gives the same wallet on any device."
                         : [.apple, .google, .email, .passkey].contains(account.method)
                         ? "This is a Privy embedded wallet, secured by your \(account.method.title) sign-in. The same sign-in opens it on any device. DyorHQ never holds your keys."
                         : "This wallet was created on this device and is secured by your \(account.method.title) account. DyorHQ never holds your keys.")
                }

                if account.method == .meraPasskey {
                    MeraSessionSection()
                }

                Section {
                    Link(destination: Monad.explorerAddress(account.address)) { Label("View on Monadscan", systemImage: "safari") }
                    Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = account.address.checksummed }
                }

                if account.canSign {
                    Section {
                        NavigationLink { WalletExportView() } label: {
                            Label(account.method == .meraPasskey ? "Export Recovery Phrase" : "Export Wallet", systemImage: "key.horizontal")
                        }
                    } footer: {
                        Paragraph(account.method == .imported || account.method == .emailPassword
                             ? "Reveal this wallet's private key to back it up or move it to another wallet. The key never leaves your device."
                             : account.method == .meraPasskey
                             ? "Show the 24-word recovery phrase your passkey derives, to back this wallet up or restore it in another wallet without the passkey. It asks for your passkey every time and is never stored."
                             : "Export this wallet's private key through Privy's secure export page.")
                    }
                }

                if account.method == .watchOnly {
                    Section {
                        NavigationLink { ImportWalletView() } label: { Label("Import an Existing Wallet", systemImage: "square.and.arrow.down") }
                    } footer: {
                        Paragraph("Import your own wallet with its recovery phrase or private key. It stays on this device.")
                    }
                }
            }
            Section("Network") {
                LabeledContent("Chain", value: tr("Monad mainnet"))
                LabeledContent("Chain ID", value: "143")
                LabeledContent("RPC", value: env.config.rpcURL.host() ?? "—")
            }
        }
        .navigationTitle(tr("Manage Wallets"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Passkeys and the biometric app lock — the second factors a self-custodial wallet can offer.
struct SecurityView: View {
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                if session.hasPasskeys {
                    Button {
                        busy = true; message = nil
                        Task {
                            // not localized: the passkey's name, the app's
                            do { try await session.createPasskey(displayName: "DyorHQ"); message = tr("Passkey added."); isError = false }
                            catch { message = describe(error); isError = true }
                            busy = false
                        }
                    } label: {
                        HStack {
                            Label("Add a Passkey", systemImage: "person.badge.key")
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(busy || !session.canSign)
                } else if session.hasMera {
                    // Privy passkeys are off whenever Mera is on (they'd share the rpId): a passkey is an account of its own.
                    Label("Passkey accounts are created from the sign-in screen, not added here.", systemImage: "person.badge.key")
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
                    Label("Passkeys are not enabled in this build.", systemImage: "key.slash").foregroundStyle(.secondary).font(.subheadline)
                }
            } header: {
                Text("Passkeys")
            } footer: {
                if let message { Paragraph(message).foregroundStyle(isError ? Color.attention : Color.positive) }
                else if session.hasMera { Paragraph("A passkey account unlocks with Face ID or Touch ID, and iCloud Keychain keeps its passkey on your other Apple devices.") }
                else { Paragraph("Sign in with Face ID or Touch ID. Add one per device.") }
            }

            Section {
                // Stays visible while the lock is on, even if biometrics were since removed, so it can always be managed.
                if BiometricGate.isAvailable || settings.requireBiometrics {
                    Toggle("Require \(BiometricGate.typeName)", isOn: Binding(
                        get: { settings.requireBiometrics },
                        set: { on in
                            if on { settings.requireBiometrics = true; return }
                            // Turning App Lock OFF needs the owner too — otherwise anyone holding the unlocked phone
                            // could simply switch it off.
                            Task { if await BiometricGate.authenticate(reason: "Turn off App Lock") { settings.requireBiometrics = false } }
                        }))
                } else {
                    Label("No biometrics enrolled on this device.", systemImage: "faceid").foregroundStyle(.secondary).font(.subheadline)
                }
            } header: {
                Text("App Lock")
            } footer: {
                if session.account?.method == .meraPasskey {
                    // `AppSettings.appLockApplies`: a passkey account's lock is its passkey, never a second prompt.
                    Paragraph("Your passkey is this account's lock: signing asks for it whenever the session is locked, so App Lock doesn't add a second \(BiometricGate.promptName) prompt.")
                } else if settings.requireBiometrics, !BiometricGate.canAuthenticateOwner {
                    Paragraph("Set a device passcode in iOS Settings — App Lock can't confirm transactions without one.").foregroundStyle(Color.attention)
                } else {
                    Paragraph("Asks for \(BiometricGate.typeName) (or your passcode) before every transaction is signed, and before App Lock can be turned off.")
                }
            }
        }
        .navigationTitle(tr("Security"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Notification preferences. Turning them on requests the system permission. Every notification is made on the
/// device while DyorHQ runs — there is no push server — and the copy says so (security audit 2026-09-26, GL-4): alerts
/// arrive while DyorHQ is open, on any screen (`AlertCenter`), and never while it is closed.
struct NotificationsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Session.self) private var session
    @State private var denied = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle("Enable Notifications", isOn: $settings.notificationsEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if denied { Paragraph("Notifications are turned off for DyorHQ in iOS Settings. Enable them there to receive alerts.").foregroundStyle(Color.attention) }
                    else { Paragraph("Alerts arrive while DyorHQ is open. iOS pauses the app in the background, so nothing reaches your lock screen while DyorHQ is closed.") }
                    LearnMoreLink(.notificationsAndPriceAlerts)
                }
            }
            Section {
                Toggle("Swaps & Fills", isOn: $settings.notifyFills)
                Toggle("Perps Margin Warnings", isOn: $settings.notifyMargin)
                Toggle("Price Alerts", isOn: $settings.notifyPriceAlerts)
                NavigationLink { PriceAlertsView() } label: {
                    HStack {
                        Label("Manage Price Alerts", systemImage: "bell.badge")
                        Spacer()
                        Text(verbatim: "\(PriceAlertStore.all(owner: session.address).count)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Paragraph("Alerts arrive while DyorHQ is open, on any screen: order fills, a Perps position at 80% and 90% of its margin in use, and price alerts. Nothing arrives while DyorHQ is closed, so don't rely on them to protect a position: set a stop-loss on it. Everything is also kept in the in-app center.")
            }
            .disabled(!settings.notificationsEnabled)
        }
        .navigationTitle(tr("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task { denied = await Notifications.authorizationStatus() == .denied }
        .onChange(of: settings.notificationsEnabled) { _, on in
            guard on else { return }
            Task {
                let granted = await Notifications.requestAuthorization()
                denied = !granted
                if !granted { settings.notificationsEnabled = false }
            }
        }
    }
}

/// Defaults the trade tickets open with.
struct TradingPreferencesView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Stepper(value: $settings.defaultLeverage, in: TradingDefaults.leverageRange, step: 1) {
                    LabeledContent("Default Leverage", value: "\(Int(settings.defaultLeverage))×")
                }
            } footer: {
                Paragraph("The leverage a new perps order opens on. Each market still caps it to its own maximum.")
            }
            Section {
                Picker("Max Slippage", selection: $settings.slippageBps) {
                    // The same choices a restored backend copy is checked against (`BackendRestore.slippageBps`).
                    ForEach(TradingDefaults.slippageChoicesBps, id: \.self) { Text(NumberStyle.basisPoints($0)).tag($0) }
                }
            } footer: {
                Paragraph("The furthest a market order or swap may move from its quote before it is cancelled.")
            }
        }
        .navigationTitle(tr("Trading Preferences"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Connect to Perpl's authenticated trading API (the route to real TP/SL). One-time enrollment signs a payload
/// with the wallet; the Ed25519 key lives in the Keychain (a passkey account's: its token only, once per device).
struct PerplTradingView: View {
    @Environment(PerplTrading.self) private var trading
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemoveKey = false

    /// The TP/SL live on Perpl right now, which removing the key leaves armed and out of this device's sight.
    private var liveTriggerCount: Int { trading.ordersAreLive ? trading.openOrders.filter(\.isTrigger).count : 0 }

    var body: some View {
        List {
            Section {
                LabeledContent("Status") { statusLabel }
                if trading.key != nil {
                    LabeledContent("Signed in") { checkmark(trading.isSignedIn) }
                    LabeledContent("One-click trading") { checkmark(trading.isForwarding) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if session.account?.method == .meraPasskey {
                        Paragraph("Your trading key comes from your passkey and exists only while your session is unlocked; this device stores just its token. On another iPhone, connect once more.")
                    } else {
                        Paragraph("Your trading key is generated on this device and authorized once by your wallet.")
                    }
                    LearnMoreLink(.oneClickTrading)
                }
            }

            Section {
                Link(destination: PerplLinks.signup) {
                    HStack {
                        Label("Create a Perpl Account", systemImage: "arrow.up.forward.square")
                        Spacer()
                        Image(systemName: "safari").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("New to Perpl?")
            } footer: {
                Paragraph("Your wallet needs a Perpl account before it can trade. Opens app.perpl.xyz.")
            }

            Section {
                switch trading.status {
                case .notEnrolled:
                    Button("Connect Perpl Trading") { run { try await enroll() } }
                        .disabled(busy || !session.canSign)
                case .enrolled:
                    Button("Reconnect") { run { try await trading.connect() } }.disabled(busy)
                case .connecting:
                    HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                case .needsForwarding:
                    Button("Enable One-Click Trading") { run { try await enableForwarding() } }.disabled(busy)
                case .connected:
                    Label("Ready to trade", systemImage: "checkmark.seal.fill").foregroundStyle(Color.positive)
                    Button("Disconnect") { trading.disconnect() }.disabled(busy)
                case .failed:
                    // A failed enrolment left no key to reconnect with: trying again enrols again (a new key each time).
                    Button("Try Again") {
                        run { if trading.isEnrolled { try await trading.connect() } else { try await enroll() } }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("Connection")
            } footer: {
                if let error { InlineError(message: error) }
                // A drop that happened outside a tap (idle timeout, rejected key, connection cap) is only on `status`.
                else if case .failed(let why) = trading.status { InlineError(message: why) }
                else if trading.status == .needsForwarding { Paragraph("Lets Perpl's keeper forward your signed orders. One on-chain transaction.") }
            }

            if trading.isEnrolled {
                Section {
                    Button("Remove API Key", role: .destructive) { confirmRemoveKey = true }.disabled(busy)
                } footer: {
                    Paragraph("Deletes the key from this device. Take-profit and stop-loss orders already on Perpl stay live.")
                }
                .confirmationDialog("Remove the API key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
                    Button("Remove API Key", role: .destructive) { if let address = session.address { trading.forget(address: address) } }
                } message: {
                    // Removing the key cancels nothing (security audit GT-3): say what stays armed where the app can't see it.
                    if liveTriggerCount > 0 {
                        Text("You have \(liveTriggerCount) take-profit/stop-loss orders live on Perpl. Removing the key doesn't cancel them: they stay armed, and this device can't show or cancel them until you connect again.")
                    } else {
                        Text("Any take-profit or stop-loss you have on Perpl stays live. This device can't show or cancel them until you connect again.")
                    }
                }
            }
        }
        .navigationTitle(tr("Perpl Trading"))
        .navigationBarTitleDisplayMode(.inline)
        .task { trading.refresh(account: session.account) }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? Color.positive : Color.secondary)
    }

    @ViewBuilder private var statusLabel: some View {
        switch trading.status {
        case .notEnrolled: Text("Not connected").foregroundStyle(.secondary)
        case .enrolled: Text("Enrolled", comment: "Perpl trading's status: a trading key is set up, not connected yet [tight]").foregroundStyle(.secondary)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .needsForwarding: Text("Enable one-click", comment: "Perpl trading's status: one-click trading still needs enabling [tight]").foregroundStyle(Color.attention)
        case .connected: Text("Ready", comment: "Perpl trading's status: connected and ready to trade [tight]").foregroundStyle(Color.positive)
        case .failed: Text("Error", comment: "Perpl trading's status: the connection failed, a noun [tight]").foregroundStyle(Color.attention)
        }
    }

    private func enroll() async throws {
        guard let wallet = session.wallet, let address = session.address else { throw SessionError.readOnly }
        // Enrollment signs with the wallet and creates a trading key — App Lock applies.
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Connect Perpl trading")) { throw SessionError.authenticationRequired }
        try await trading.enroll(wallet: wallet, address: address)
    }

    private func enableForwarding() async throws {
        guard let wallet = session.wallet else { throw SessionError.readOnly }
        // An on-chain transaction sent without a confirmation sheet — App Lock applies.
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Enable one-click trading")) { throw SessionError.authenticationRequired }
        try await trading.enableForwarding(env: env, wallet: wallet)
    }

    /// Connecting signs, and enabling one-click trading is an on-chain send without a review sheet: a Moment link waits
    /// until it ends, so it never closes Profile under it (RootView's link gate).
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await router.holdingLinks(work) } catch { self.error = describe(error) }; busy = false }
    }
}

/// The Language screen: System (the device's language, among those this build ships), then each language this build
/// ships, in its own name. A choice applies at once and is saved as iOS's per-app language (`LanguageStore`), which
/// Settings › Apps › DyorHQ › Language shows too. While English is the only language, the footer says more are coming.
struct LanguageView: View {
    @Environment(LanguageStore.self) private var language

    var body: some View {
        List {
            Section {
                row(.system) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System", comment: "Follows the device's own setting: on Appearance its light or dark look, on the Language screen and menu its language [tight]")
                        Text("Uses your device language (\(language.deviceLanguageName))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(language.available) { option in
                    row(.language(option)) { Text(verbatim: option.endonym) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Paragraph("Screens iOS draws itself, such as Face ID and permission prompts, change the next time you open DyorHQ.")
                    if language.available.count < 2 { Text("More languages are coming in the next update.") }
                }
            }
        }
        .navigationTitle(tr("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A choice, checked while it is the one in use.
    private func row(_ choice: LanguageChoice, @ViewBuilder label: () -> some View) -> some View {
        Button { language.select(choice) } label: {
            HStack {
                label()
                Spacer()
                if language.choice == choice {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(language.choice == choice ? .isSelected : [])
    }
}

/// The onboarding hub's globe menu (owner decision 21): the Language screen's choices, before sign-in, through the same
/// store. Offered once a second language ships; until then there is nothing to choose.
struct LanguageMenu: View {
    @Environment(LanguageStore.self) private var language

    var body: some View {
        Menu {
            Picker("Language", selection: Binding(get: { language.choice }, set: { language.select($0) })) {
                Text("System", comment: "Follows the device's own setting: on Appearance its light or dark look, on the Language screen and menu its language [tight]")
                    .tag(LanguageChoice.system)
                ForEach(language.available) { option in
                    Text(verbatim: option.endonym).tag(LanguageChoice.language(option))
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .accessibilityLabel("Language")
    }
}

/// The appearance sheet: System / Light / Dark, applied live, plus what the trading colors mean.
struct AppearanceSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button { settings.appearance = mode } label: {
                            VStack(spacing: 10) {
                                Image(systemName: mode.symbol).font(.title2)
                                Text(mode.label).font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(settings.appearance == mode ? Color.accentColor : Color.clear, lineWidth: 2)
                            }
                        }
                        .foregroundStyle(settings.appearance == mode ? Color.primary : Color.secondary)
                    }
                }

                HStack(spacing: 12) {
                    swatch(.positive, "Long / Up")
                    swatch(.negative, "Short / Down")
                }
                .padding(.top, 4)

                Spacer()
            }
            .padding(20)
            .navigationTitle(tr("Appearance"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.height(300)])
        // A sheet keeps the scheme it was presented with, so switching from inside this one left a pale panel over a
        // dark app (and the other way round). Styling the sheet from the chosen mode, and drawing its backdrop in
        // SwiftUI instead of the default UIKit material, makes the whole sheet follow every tap immediately.
        .environment(\.colorScheme, settings.appearance.resolved)
        .presentationBackground(Color(uiColor: .systemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: settings.appearance.resolved == .dark ? .dark : .light))))
    }

    private func swatch(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The passkey signing session: how long signatures stay prompt-free after a Face ID, and a way to end it now.
private struct MeraSessionSection: View {
    @Environment(Session.self) private var session
    @State private var changing = false
    @State private var error: String?

    var body: some View {
        let mera = session.mera
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                LabeledContent {
                    if let expiresAt = mera.expiresAt, expiresAt > ctx.date {
                        let left = Int(expiresAt.timeIntervalSince(ctx.date))
                        let clock = String(format: "%02d:%02d", left / 60, left % 60) // not localized: minutes and seconds
                        Text("Unlocked · \(clock) left").monospacedDigit().foregroundStyle(Color.positive)
                    } else {
                        Text("Locked", comment: "The passkey session is locked or has ended: the next signature asks for the passkey [tight]").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Session", comment: "The passkey's signing session, a label [tight]")
                }
            }
            Picker("Prompt-free for", selection: Binding(get: { Int(mera.sessionLength) }, set: { change(to: TimeInterval($0)) })) {
                ForEach(Mera.SessionLength.choices, id: \.self) { length in
                    Text(verbatim: Self.lengthText(length)).tag(Int(length))
                }
            }
            .disabled(changing)
            Button("Lock now", systemImage: "lock") { Haptics.tap(); mera.end() }.disabled(!mera.isUnlocked)
        } header: {
            Text("Passkey")
        } footer: {
            if let error { InlineError(message: error) }
            else { Paragraph("Signs without another prompt until the session ends; then \(BiometricGate.promptName) again. A new length applies from the next session, and a longer one needs \(BiometricGate.promptName).") }
        }
    }

    /// A session length in the app's language's own units ("15 minutes", "1 hour").
    private static func lengthText(_ length: TimeInterval) -> String {
        Duration.seconds(Int(length)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))
    }

    /// Shorter is immediate; longer asks for the passkey (Face ID) and leaves the live session's end time as it is.
    private func change(to length: TimeInterval) {
        guard length != session.mera.sessionLength else { return }
        changing = true; error = nil
        Task {
            do { try await session.mera.setSessionLength(length) }
            catch where isUserCancellation(error) {}
            catch { self.error = describe(error) }
            changing = false
        }
    }
}

