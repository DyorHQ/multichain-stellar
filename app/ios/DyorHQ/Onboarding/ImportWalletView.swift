import DyorKit
import SwiftUI

/// Imports an existing wallet by its recovery phrase or private key. Everything happens on-device: the address is
/// derived locally and previewed before anything is saved, and on import the key is written only to this iPhone's
/// Keychain. Nothing is transmitted. This is how someone who already has a MetaMask / Rabby / OKX wallet uses it in
/// DyorHQ without creating a new one.
struct ImportWalletView: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var kind: Kind = .phrase
    @State private var phrase = ""
    @State private var privateKey = ""
    @State private var derived: Secp256k1Account?
    @State private var importing = false
    @State private var reveal = false
    @State private var error: String?

    enum Kind: String, CaseIterable, Identifiable {
        case phrase, key
        var id: String { rawValue }
        /// The kind's name on the segmented switch, in the app's language (never its raw value).
        var title: Text {
            switch self {
            case .phrase: Text("Recovery Phrase", comment: "Import Wallet: the switch's side for a 12 or 24 word phrase [tight]")
            case .key: Text("Private Key", comment: "Import Wallet: the switch's side for a hex private key [tight]")
            }
        }
    }

    private var currentInput: String { kind == .phrase ? phrase : privateKey }

    var body: some View {
        List {
            Section {
                Picker(selection: $kind) {
                    ForEach(Kind.allCases) { $0.title.tag($0) }
                } label: {
                    Text("Type", comment: "Which kind it is: on Import Wallet a recovery phrase or a private key, in Perps an order's type (market or limit)")
                }
                .pickerStyle(.segmented)
            }

            switch kind {
            case .phrase: phraseSection
            case .key: keySection
            }

            if let derived {
                Section {
                    HStack(spacing: 12) {
                        Avatar(url: nil, initials: "", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wallet found").font(.subheadline.weight(.semibold))
                            Text(derived.address.short).speechSpellsOutCharacters().font(.footnote.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.positive)
                    }
                } footer: {
                    Paragraph("Check this is the address you expect before importing.")
                }
            } else if !currentInput.isEmpty {
                Section {
                    Label(kind == .phrase ? "Not a valid 12–24 word recovery phrase yet." : "Not a valid private key.", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Section {
                Label("Your key is stored only on this iPhone, in the Keychain, and is never sent anywhere. DyorHQ cannot recover it — keep your original backup safe.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(tr("Import Wallet"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let error { InlineError(message: error).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                PrimaryButton(title: "Import Wallet", isBusy: importing, isDisabled: derived == nil) { runImport() }
                    .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .background(.bar)
        }
        .keyboardDoneButton()
        // Re-hide a revealed secret whenever the app leaves the foreground, so it isn't shown again on return.
        .onChange(of: scenePhase) { _, phase in if phase != .active { reveal = false } }
        .task(id: currentInput + kind.rawValue) {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            derived = await deriveAccount()
        }
    }

    /// Toggles between secure (dots) and revealed entry so the user can verify what they pasted.
    private var revealToggle: some View {
        Button { reveal.toggle(); Haptics.selection() } label: {
            Label(reveal ? "Hide" : "Reveal", systemImage: reveal ? "eye.slash" : "eye").font(.subheadline)
        }
    }

    private var phraseSection: some View {
        Section {
            Group {
                if reveal {
                    TextField("Enter your 12 or 24 word phrase", text: $phrase, axis: .vertical).lineLimit(3...6)
                } else {
                    // Secure entry keeps the phrase off-screen and out of the keyboard's predictive/learning cache.
                    SecureField("Enter your 12 or 24 word phrase", text: $phrase)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .font(.body)
            HStack {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let pasted = UIPasteboard.general.string { phrase = pasted.trimmingCharacters(in: .whitespacesAndNewlines); Haptics.selection() }
                }
                Spacer()
                revealToggle
            }
            .font(.subheadline)
        } header: {
            Text("Recovery Phrase")
        } footer: {
            let count = WalletImport.wordCount(phrase)
            if count > 0 { Paragraph("\(count) words. Words are separated by spaces.") }
            else { Paragraph("The 12 or 24 words from your existing wallet, in order.") }
        }
    }

    private var keySection: some View {
        Section {
            Group {
                if reveal {
                    TextField("0x…" as String, text: $privateKey)
                } else {
                    SecureField("0x…" as String, text: $privateKey)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .font(.body.monospaced())
            HStack {
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let pasted = UIPasteboard.general.string { privateKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines); Haptics.selection() }
                }
                Spacer()
                revealToggle
            }
            .font(.subheadline)
        } header: {
            Text("Private Key")
        } footer: {
            Paragraph("A 64-character hex private key, with or without a 0x prefix.")
        }
    }

    /// Derives the account off the main actor — PBKDF2 over a 24-word phrase is cheap but not free, and this runs
    /// on every edit. `Secp256k1Account` is Sendable, so it crosses back safely.
    private func deriveAccount() async -> Secp256k1Account? {
        let kind = kind, phrase = phrase, privateKey = privateKey
        return await Task.detached(priority: .userInitiated) {
            switch kind {
            case .phrase: return WalletImport.isValidMnemonic(phrase) ? WalletImport.account(fromMnemonic: phrase) : nil
            case .key: return WalletImport.account(fromPrivateKey: privateKey)
            }
        }.value
    }

    private func runImport() {
        guard let derived else { return }
        let importedSecret = currentInput
        importing = true
        error = nil
        Task {
            guard await session.importWallet(derived) else {
                // The key did not reach the Keychain: keep what the user entered so they can try again.
                error = session.lastError ?? tr("Couldn't save the key on this iPhone. Try again.")
                importing = false
                return
            }
            Haptics.success()
            // Scrub the secret from memory and the system clipboard now that the key is safely in the Keychain. The
            // field holds a trimmed copy of what was pasted, so compare trimmed: a phrase copied with a trailing space or
            // newline must not stay on the clipboard.
            let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let clip = UIPasteboard.general.string, !trim(importedSecret).isEmpty, trim(clip) == trim(importedSecret) {
                UIPasteboard.general.string = ""
            }
            phrase = ""; privateKey = ""; self.derived = nil; reveal = false
            importing = false
            // The session flips to signed-in and the root view swaps to the app; nothing else to dismiss.
        }
    }
}
