import BigInt
import CoreImage.CIFilterBuiltins
import DyorKit
import SwiftUI

/// The account hub: who is signed in, the wallet actions, and every setting — wallets, security (passkeys and
/// two-factor), notifications, appearance, language, support — then sign out. Modeled on a settings screen: a
/// grouped list with a symbol per row, in DyorHQ's system.
struct ProfileView: View {
    /// True when opened as a full-screen page from the home header or the menu (adds a Close control).
    var presented = false
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(LanguageStore.self) private var language
    @Environment(PerplTrading.self) private var perplTrading
    @Environment(SocialSession.self) private var social
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showAppearance = false
    @State private var confirmSignOut = false
    @State private var confirmForget = false
    @State private var signingOut = false
    @State private var showDeleteAccount = false

    /// Sign-out removes the signing key from this device, so say what that means for each kind of wallet: an imported
    /// key exists nowhere else unless the user saved it, so it must never read as "your wallet stays with your account".
    private var signOutMessage: String {
        switch session.account?.method {
        case .watchOnly?, nil:
            return tr("Balances and positions for this address will no longer be shown.")
        case .imported?:
            return tr("This removes the imported key from this iPhone. You'll need its recovery phrase or private key to use this wallet again — export it first (Manage Wallets → Export Wallet) if you haven't saved it.")
        case .emailPassword?:
            return tr("Sign in again with your email and password to use this wallet.")
        default:
            return tr("Your wallet stays with your account. Sign in again to use it.")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let account = session.account { header(account) }

                Section {
                    Button { showReceive = true } label: { SettingsRow("Receive", symbol: "qrcode", tint: .accent) }
                    Button { showSend = true } label: { SettingsRow("Send", symbol: "paperplane", tint: .accent) }
                        .disabled(!session.canSign)
                    NavigationLink { RecentActivityView() } label: { SettingsRow("Recent Activity", symbol: "clock.arrow.circlepath", tint: .accent) }
                } header: {
                    Text("Wallet")
                } footer: {
                    if !session.canSign { Text("Sign in to send from this address.") }
                }

                Section("Settings") {
                    NavigationLink { SocialProfileView() } label: {
                        HStack {
                            SettingsRow("DyorHQ Social", symbol: "person.2.circle", tint: .accent)
                            Spacer()
                            if social.isSignedIn { Text(social.profile?.handle.map { "@\($0)" } ?? tr("Connected")).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink { ManageWalletsView() } label: { SettingsRow("Manage Wallets", symbol: "wallet.bifold", tint: .accent) }
                    NavigationLink { SecurityView() } label: { SettingsRow("Security", symbol: "lock.shield", tint: .accent) }
                    NavigationLink { NotificationsView() } label: { SettingsRow("Notifications", symbol: "bell.badge", tint: .accent) }
                    Button { showAppearance = true } label: {
                        HStack {
                            SettingsRow("Appearance", symbol: "paintbrush", tint: .accent)
                            Spacer()
                            Text(settings.appearance.label).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink { TradingPreferencesView() } label: { SettingsRow("Trading Preferences", symbol: "slider.horizontal.3", tint: .accent) }
                    NavigationLink { PerplTradingView() } label: {
                        HStack {
                            SettingsRow("Perpl Trading", symbol: "bolt.horizontal", tint: .accent)
                            Spacer()
                            if perplTrading.isReady { Text("Connected").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink { LanguageView() } label: {
                        HStack { SettingsRow("Language", symbol: "globe", tint: .accent); Spacer(); Text(language.resolved.endonym).foregroundStyle(.secondary) }
                    }
                    NavigationLink {
                        ScrollView { GetHelpContent().padding(16) }
                            .background(Color(.systemGroupedBackground))
                            .navigationTitle(tr("Support"))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: { SettingsRow("Support", symbol: "questionmark.circle", tint: .accent) }
                    Link(destination: SupportLinks.helpCenter) { SettingsRow("Help Center", symbol: "book", tint: .accent) }
                    Link(destination: SupportLinks.terms) { SettingsRow("Terms of Use", symbol: "doc.text", tint: .accent) }
                    Link(destination: SupportLinks.privacy) { SettingsRow("Privacy Policy", symbol: "hand.raised", tint: .accent) }
                }

                Section("Network") {
                    LabeledContent("Chain", value: tr("Monad mainnet"))
                    LabeledContent("RPC", value: env.config.rpcURL.host() ?? env.config.rpcURL.absoluteString)
                }

                // A passkey account keeps nothing on the device that the passkey can't bring back, so signing out of one
                // is forgetting this device: the whole local copy is erased (`AccountDeletion.eraseThisDevice`), and the
                // passkey provider is never told anything — the passkey is the account (MERA-PLAN §6).
                if session.isPasskeyAccount {
                    Section {
                        Button(role: .destructive) { confirmForget = true } label: {
                            Label("Forget This Device", systemImage: "iphone.slash")
                        }
                        .disabled(signingOut)
                    } footer: {
                        Paragraph("Removes this account from this iPhone. Your passkey keeps it — sign in again anytime.")
                    }
                }

                Section {
                    if !session.isPasskeyAccount {
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Label(session.canSign ? "Sign Out" : "Stop Watching", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(signingOut)
                    }
                    Button(role: .destructive) { showDeleteAccount = true } label: {
                        Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(signingOut)
                } footer: {
                    Paragraph("DyorHQ \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · \(SupportLinks.tagline) · Self-custodial.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("Profile"))
            .navigationBarTitleDisplayMode(presented ? .inline : .large)
            .foregroundStyle(.primary)
            .toolbar {
                if presented {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Haptics.tap(); dismiss() } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                            .accessibilityLabel(Text("Close", comment: "Closes this screen or sheet (a verb)"))
                    }
                }
            }
            .sheet(isPresented: $showReceive) { if let address = session.address { ReceiveSheet(address: address) } }
            .sheet(isPresented: $showSend) { SendSheet() }
            .sheet(isPresented: $showAppearance) { AppearanceSheet() }
            .sheet(isPresented: $showDeleteAccount) { DeleteAccountView() }
            .confirmationDialog(session.canSign ? "Sign out of DyorHQ?" : "Stop watching this address?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(session.canSign ? "Sign Out" : "Stop Watching", role: .destructive) {
                    let address = session.address
                    Task { @MainActor in
                        // Signing out can delete the only copy of an imported key, so with App Lock on it asks for the
                        // device owner first, like key export (audit F5).
                        if session.canSign, settings.appLockApplies(to: session.account),
                           !(await BiometricGate.authenticate(reason: "Sign out of DyorHQ")) { return }
                        signingOut = true
                        // The Perpl trading key on this device is a delegate for this wallet: it goes with the session.
                        if let address { perplTrading.forget(address: address) }
                        await session.signOut()
                        signingOut = false
                    }
                }
            } message: {
                Text(signOutMessage)
            }
            .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget This Device", role: .destructive) {
                    guard let address = session.address else { return }
                    signingOut = true
                    Task {
                        await AccountDeletion.eraseThisDevice(address: address, session: session, social: social, env: env)
                        signingOut = false
                    }
                }
            } message: {
                Text("This iPhone's copy of the account is erased. Your passkey keeps the account and its funds; sign in with it again anytime.")
            }
        }
    }

    private var avatarURL: URL? {
        guard let raw = social.profile?.avatar_url, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func initials(_ account: Session.Account) -> String {
        let source = social.profile?.display_name ?? social.profile?.handle ?? account.label ?? ""
        let letters = source.split(whereSeparator: { $0 == " " || $0 == "@" }).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private func header(_ account: Session.Account) -> some View {
        Section {
            HStack(spacing: 14) {
                if account.method == .watchOnly {
                    ZStack {
                        Circle().fill(Color(.tertiarySystemFill)).frame(width: 56, height: 56)
                        Image(systemName: "eye").font(.title2).foregroundStyle(.secondary)
                    }
                } else {
                    Avatar(url: avatarURL, initials: initials(account), size: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(social.profile?.display_name ?? account.label ?? account.address.short).font(.title3.weight(.semibold))
                    Text(account.method == .watchOnly ? "Watching this address" : "Signed in with \(account.method.title)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            AddressRow(title: "Address", address: account.address)
        }
    }
}

/// A settings row: a symbol in the accent tint, then the title. Matches Apple's own settings rows. The title is a catalog
/// key when written in the code, or a `String` shown as it is.
struct SettingsRow: View {
    private let title: Text
    let symbol: String
    var tint: Color = .accent

    init(_ title: LocalizedStringKey, symbol: String, tint: Color = .accent) {
        self.title = Text(title)
        self.symbol = symbol
        self.tint = tint
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, symbol: String, tint: Color = .accent) {
        self.title = Text(verbatim: String(title))
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            title.foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

struct ReceiveSheet: View {
    let address: Address
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = QRCode.image(for: address.checksummed) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("QR code of your address")
                }
                VStack(spacing: 8) {
                    Text(address.checksummed)
                        .speechSpellsOutCharacters()
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Paragraph("Send MON or any Monad token to this address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                HStack(spacing: 12) {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = address.checksummed
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: address.checksummed) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle(tr("Receive"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sensoryFeedback(.success, trigger: copied)
        }
        .presentationDetents([.large])
    }
}

/// Send MON or any token the wallet holds to another address.
struct SendSheet: View {
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// The asset to send, as the list showed it when it was chosen, Unverified mark included: the highest-value one the
    /// wallet holds once the list is read (`WalletHoldings.selection`), then the user's pick. Nil before that, when every
    /// held token is Unverified, and when a new read no longer holds it: the user picks.
    @State private var choice: HeldToken?
    /// Every token the wallet holds, ranked: the Portfolio's list (`WalletTokens`).
    @State private var assets: AssetList = .loading
    /// Retry bumps it, to read the list again.
    @State private var attempt = 0
    /// The list the form shows: the wallet and attempt it was read for, marked while the wallet's history is still read.
    /// Available and Max are read again for each (`balanceReadKey`).
    @State private var assetsKey: String?
    /// The read of the list for a wallet and attempt (`readAssets`), on a task of its own: coming back from the token
    /// list shows the form again, which restarts its tasks, and the read goes on, or stands, rather than starting over.
    /// Cancelled when the sheet closes.
    @State private var assetsRead: (id: String, task: Task<Void, Never>)?
    /// The symbol of a pick a new read no longer held: it was cleared, with the amount, and the user picks again.
    @State private var droppedChoice: String?
    @State private var recipient = ""
    @State private var amount = ""
    @State private var balance: BigUInt?
    /// The token `balance` is for.
    @State private var balanceToken: Address?
    /// What the review shows and signs, frozen when Review is tapped (RT-7): a Max that lands late or an edit behind
    /// the sheet can't change the amount signed after it was shown.
    @State private var review: SendReview?
    /// The pasted text hidden characters were removed from (GR-4), while it is still what the field holds.
    @State private var cleanedPaste: String?
    /// Whether the recipient has contract code (GR-3): nil until read, or when it couldn't be read.
    @State private var recipientIsContract: Bool?
    @State private var recipientCheckFailed = false
    /// The recipient whose check finished (`checkRecipient`): coming back from the token list neither checks it again
    /// nor clears the acknowledgement given for it.
    @State private var checkedRecipient: Address?
    /// Sending to a contract (or to an address that couldn't be checked) takes this acknowledgement.
    @State private var sendToContract = false

    private var token: Token? { choice?.token }
    /// Which read of the list the form wants: this wallet's, the `attempt`th.
    private var assetsReadKey: String { "\(session.address?.hex ?? "")#\(attempt)" }
    /// Which balance Available and Max want: the chosen token's, after the list's latest read.
    private var balanceReadKey: String { "\(token?.address.hex ?? "")#\(assetsKey ?? "")" }
    /// What was typed or pasted, without surrounding whitespace or invisible characters (GR-4).
    private var recipientText: String { Address.cleanedInput(recipient).text }
    /// Nil for a mixed-case address whose EIP-55 checksum is wrong: a mistyped character must never become the recipient.
    private var recipientAddress: Address? { Address.inputProblem(recipientText) == nil ? Address(recipientText) : nil }
    private var rawAmount: BigUInt? { token.flatMap { Amount.parse(amount, decimals: $0.decimals) } }

    /// Why this can't be sent, in words: nil when it can. Nothing is said about a field still empty.
    private var problem: String? {
        if let issue = Address.inputProblem(recipientText) { return issue }
        if let to = recipientAddress {
            if to.isZero { return tr("That's the zero address: anything sent there is lost for good.") }
            // Tokens sent to their own contract are stuck there: almost no token can send them back (GR-3).
            if let token, !token.isNative, to == token.address { return tr("That's the \(token.symbol) token contract itself. Tokens sent to it are almost always lost for good.") }
        }
        if let rawAmount, let balance, let token, rawAmount > balance {
            return tr("More than your \(NumberStyle.units(balance, decimals: token.decimals)) \(token.symbol).")
        }
        return nil
    }

    /// A contract recipient, or one whose code couldn't be read, needs the acknowledgement.
    private var needsContractAcknowledgement: Bool { recipientIsContract == true || recipientCheckFailed }

    private var valid: Bool {
        // Only a pick from the list as read: while it is read again, or when that read failed, there is nothing to send.
        guard case .loaded = assets, choice != nil else { return false }
        guard problem == nil, let recipientAddress, !recipientAddress.isZero, let rawAmount, rawAmount > 0 else { return false }
        guard recipientIsContract != nil || recipientCheckFailed else { return false } // still checking
        return !needsContractAcknowledgement || sendToContract
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $recipient)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        guard let pasted = UIPasteboard.general.string else { return }
                        let cleaned = Address.cleanedInput(pasted)
                        recipient = cleaned.text
                        cleanedPaste = cleaned.removedInvisible ? cleaned.text : nil
                    }
                    if needsContractAcknowledgement {
                        Toggle(recipientIsContract == true ? "Send to this contract anyway" : "Send without that check", isOn: $sendToContract)
                            .tint(Color.attention)
                    }
                } header: {
                    Text("To", comment: "The address the tokens are sent to, a section header [tight]")
                } footer: {
                    if let cleanedPaste, cleanedPaste == recipient { Paragraph("Hidden characters were removed from the pasted address. Check it matches the source.") }
                    if let to = recipientAddress, to == session.address { Text("That's your own address.") }
                    if recipientIsContract == true {
                        if let token {
                            Paragraph("This address is a contract, not a wallet. Most contracts can't send tokens back, so funds sent to the wrong one are lost. Send only if you know this contract accepts \(token.symbol).")
                        } else {
                            Paragraph("This address is a contract, not a wallet. Most contracts can't send tokens back, so funds sent to the wrong one are lost. Send only if you know this contract accepts this token.")
                        }
                    } else if recipientCheckFailed {
                        Paragraph("Couldn't check whether this address is a contract. Check it before sending.")
                    }
                }
                Section {
                    assetRow
                    AmountField(title: "Amount", text: $amount, token: token) { useMax() }
                        .disabled(token == nil)
                } header: {
                    Text("Amount")
                } footer: {
                    if let problem { Paragraph(problem).foregroundStyle(Color.attention) }
                    else if let balance, let token { Text("Available: \(NumberStyle.units(balance, decimals: token.decimals)) \(token.symbol)") }
                }
            }
            .navigationTitle(tr("Send"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        guard valid, let choice, let to = recipientAddress, let raw = rawAmount else { return }
                        review = SendReview(asset: choice, to: to, amount: raw, toContract: recipientIsContract == true,
                                            badge: env.dyorCoins.badge(choice.token, receivedUnasked: choice.unverified))
                    }
                    .disabled(!valid)
                }
            }
            .task(id: assetsReadKey) { loadAssets(assetsReadKey) }
            // A list read while the wallet's transfer history was still filling in is read again once it is complete.
            .task(id: env.history.snapshot.status(WalletHistoryScans.transfersInId).complete) {
                if env.history.snapshot.status(WalletHistoryScans.transfersInId).complete, case .loaded(_, false, _, false) = assets { attempt += 1 }
            }
            .task(id: balanceReadKey) {
                // Available and Max are always the chosen token's, read fresh: never another token's balance. Read again
                // for each new read of the list (Retry), which also sets the balance it read; coming back from the token
                // list runs this again. The balance already read for the same token stays until the new one lands.
                if balanceToken != token?.address { balance = nil; balanceToken = nil }
                guard let token, let address = session.address else { return }
                let fresh = try? await ERC20.balances(of: [token], owner: address, rpc: env.rpc, multicall: env.multicall)[token.address]
                guard !Task.isCancelled, token == self.token, let fresh else { return }
                balance = fresh
                balanceToken = token.address
            }
            .task(id: recipientAddress) { await checkRecipient() }
            .sheet(item: $review) { review in
                let owner = session.address
                let rpc = env.rpc
                ConfirmationSheet(title: "Send \(review.token.symbol)", confirmTitle: "Send", build: {
                    // A send the chain would refuse (a token that blocks it, a contract that won't take MON) is named
                    // here and Send stays off: nothing that must fail is signed.
                    if let owner, let refusal = await TokenTransfer.refusal(review.token, to: review.to, amount: review.amount, from: owner, rpc: rpc) {
                        throw TransactionError.rejected(refusal)
                    }
                    let request = try review.request()
                    return [.call(request, label: tr("Send \(review.token.symbol)"))]
                }, onDone: { dismiss() }, onCompleted: { hash in
                    // A send out of the wallet is a withdrawal in the journey. USD is exact for the curated dollar
                    // stables, matched by contract address — a token that only calls itself "USDC" is not dollars —
                    // and left unknown otherwise rather than guessed.
                    Activity.record(ActivityRecord(kind: .withdraw, title: tr("Sent \(review.token.symbol)"),
                        subtitle: "\(NumberStyle.units(review.amount, decimals: review.token.decimals)) \(review.token.symbol) → \(review.to.short)",
                        hash: hash, section: "wallet", usd: WalletHoldings.stableUSD(review.token, amount: review.amount)), owner: session.address)
                }, intent: .alwaysAsks(.send)) {
                    DetailRow("To", review.to.checksummed, spellsOut: true) // in full: this review is the last check before funds leave
                    if review.toContract { DetailRow("Recipient", "A contract, not a wallet", tint: .attention) }
                    DetailRow("Amount", verbatim: "\(NumberStyle.units(review.amount, decimals: review.token.decimals)) \(review.token.symbol)")
                    // In full, like the recipient: a look-alike's contract can be made to match a short form.
                    if !review.token.isNative { DetailRow("Token contract", review.token.address.checksummed, spellsOut: true) }
                    if review.badge.isImitation, let title = review.badge.title { DetailRow("Token", title, tint: .attention) }
                    if review.unverified { DetailRow("Token", review.receivedNote, tint: .attention) }
                    DetailRow("Network", verbatim: "Monad") // not localized: the chain's name
                }
            }
        }
        .onDisappear { assetsRead?.task.cancel() }
    }

    /// The token to send, as a row that opens the list of everything the wallet holds; while the list is read, a
    /// progress row; a read that failed says so with Retry, never as an empty wallet.
    @ViewBuilder private var assetRow: some View {
        switch assets {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your wallet…").foregroundStyle(.secondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                InlineError(message: "Your balances couldn't be read. Check your connection and try again.")
                Button("Retry", systemImage: "arrow.clockwise") { attempt += 1 }
            }
        case .loaded(let held, let complete, _, let readingHistory) where held.isEmpty:
            if readingHistory {
                // Nothing among MON, the curated tokens and the stored ones: the history may hold more.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your wallet…").foregroundStyle(.secondary)
                }
            } else if complete {
                Paragraph("This wallet holds no tokens on Monad, so there's nothing to send.").foregroundStyle(.secondary)
            } else {
                readNotice("No tokens found, but part of your wallet couldn't be read, so some may be missing.")
            }
        case .loaded(let held, let complete, let pricesFailed, let readingHistory):
            NavigationLink {
                SendAssetPicker(assets: held, selected: choice?.id, readingHistory: readingHistory) { choice = $0; droppedChoice = nil }
            } label: {
                if let choice { SendAssetRow(asset: choice) } else { Text("Choose a token") }
            }
            if let droppedChoice, choice == nil {
                Paragraph("Your wallet no longer holds the \(droppedChoice) you picked. Choose a token.").font(.footnote).foregroundStyle(Color.attention)
            }
            if readingHistory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Paragraph("Reading your wallet's history. Tokens found there will be added.").font(.footnote).foregroundStyle(.secondary)
                }
            } else if !complete, env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.holdings) {
                // The wallet's transfer history, the only scan the list is read from, is still filling in behind the app
                // (`HistoryModel`): the list is read again once it is complete.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your history… \(NumberStyle.percent(env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.holdings) * 100, fractionDigits: 0, signed: false))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let gap = Self.readGap(complete: complete, pricesFailed: pricesFailed) { readNotice(gap) }
        }
    }

    /// What part of the read failed, in words: nil when all of it was read. A curated token no pool prices is no
    /// failure: its row reads "No price", and the top priced token is picked as usual.
    private static func readGap(complete: Bool, pricesFailed: Bool) -> String? {
        switch (complete, pricesFailed) {
        case (true, false): return nil
        case (true, true): return tr("Some prices couldn't be read, so values are missing and no token was picked for you.")
        case (false, false): return tr("Part of your wallet couldn't be read, so a token may be missing from the list.")
        case (false, true): return tr("Some prices and part of your wallet couldn't be read, so values and tokens may be missing, and no token was picked for you.")
        }
    }

    /// What a read that came back partly empty-handed left out, with Retry: never passed off as all the wallet holds.
    private func readNotice(_ text: LocalizedStringKey) -> some View {
        readNotice(Text(text))
    }

    /// A notice worded at run time (`readGap`), shown as it is.
    @_disfavoredOverload
    private func readNotice<S: StringProtocol>(_ text: S) -> some View {
        readNotice(Text(verbatim: String(text)))
    }

    private func readNotice(_ text: Text) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            text.font(.footnote).foregroundStyle(.secondary)
            Button("Retry", systemImage: "arrow.clockwise") { attempt += 1 }
        }
    }

    /// Starts reading the list for `key` (`readAssets`), unless that read is done or still going: coming back from the
    /// token list runs this again, and the list read for this key stands, with the pick made from it.
    private func loadAssets(_ key: String) {
        if assetsKey == key { return }
        if let running = assetsRead, running.id == key, !running.task.isCancelled { return }
        assetsRead?.task.cancel()
        let env = env
        let session = session
        assetsRead = (key, Task { await readAssets(key, env: env, session: session) })
    }

    /// Reads every token the wallet holds, as the Portfolio does (`WalletTokens`), in two steps, so Send never waits on
    /// the wallet's whole history to offer MON: first MON, the curated tokens and every token stored for the wallet,
    /// listed at once with nothing preselected, while the history is read alongside; then the tokens the history shows
    /// join the list, ranked again, and a token is preselected (`show`).
    private func readAssets(_ key: String, env: AppEnvironment, session: Session) async {
        guard let address = session.address else {
            assets = .loaded([], complete: true, pricesFailed: false)
            choice = nil
            assetsKey = key
            return
        }
        assets = .loading
        async let history = WalletTokens.history(env: env, address: address)
        let first: WalletTokens.Read
        do {
            first = try await WalletTokens.read(env: env, address: address, history: nil)
        } catch {
            guard !Task.isCancelled else { return }
            assets = .failed
            assetsKey = key
            return
        }
        let firstRanked = await WalletTokens.ranked(first, env: env)
        guard !Task.isCancelled, address == session.address else { return }
        show(firstRanked, complete: first.complete, readingHistory: true)
        assetsKey = key + "#first"
        let scan = await history
        let read = try? await WalletTokens.read(env: env, address: address, history: scan)
        var ranked: WalletTokens.Ranked?
        if let read { ranked = await WalletTokens.ranked(read, env: env) }
        guard !Task.isCancelled, address == session.address else { return }
        if let read, let ranked {
            show(ranked, complete: read.complete, readingHistory: false)
        } else {
            // No balance could be read this time: the first list stands, said to be incomplete.
            show(firstRanked, complete: false, readingHistory: false)
        }
        assetsKey = key
    }

    /// Shows a list as read. While the wallet's history is still read (`readingHistory`) the list may yet grow, so
    /// nothing is preselected from it: a pick it holds stays, with this read's balance, and a pick it doesn't hold yet
    /// (one the history found, before Retry) waits for the history. Once the history is in, a pick is kept while the
    /// wallet still holds it, and cleared with the amount once it doesn't, never swapped for another asset; with none,
    /// the default is picked (`WalletHoldings.selection`).
    private func show(_ ranked: WalletTokens.Ranked, complete: Bool, readingHistory: Bool) {
        assets = .loaded(ranked.tokens, complete: complete, pricesFailed: ranked.pricesFailed, readingHistory: readingHistory)
        if readingHistory {
            guard let current = choice else { return }
            let fresh = ranked.tokens.first { $0.id == current.id }
            choice = fresh ?? current
            // Available and Max start from the balance this read found; for a pick only the history holds, the balance
            // task reads it for this read.
            balance = fresh?.balance
            balanceToken = fresh?.id
            return
        }
        // Without every price that exists the list isn't wholly ranked by value: nothing is preselected from it. A curated
        // token no pool prices is no gap: it ranks after the priced ones, and the top priced token is picked.
        let kept = WalletHoldings.selection(keeping: choice?.id, in: ranked.tokens, pricesRead: !ranked.pricesFailed)
        if let previous = choice, kept == nil {
            droppedChoice = previous.token.symbol
            amount = ""
        }
        choice = kept
        // Available and Max start from the balance this read found, never one an earlier read found; the balance
        // task reads it again for this read.
        balance = kept?.balance
        balanceToken = kept?.id
    }

    /// Reads whether the recipient has code. An EIP-7702-delegated account (Monad accounts can carry a `0xef0100`
    /// delegation) is still a wallet its key controls, so only other code counts as a contract. A check that finished
    /// for this address stands: coming back from the token list runs this again, and must not clear the acknowledgement.
    private func checkRecipient() async {
        let to = recipientAddress
        if let to, to == checkedRecipient { return }
        recipientIsContract = nil
        recipientCheckFailed = false
        sendToContract = false
        checkedRecipient = nil
        guard let to, !to.isZero else { return }
        do {
            let code = try await env.rpc.code(at: to)
            guard !Task.isCancelled, to == recipientAddress else { return }
            recipientIsContract = !code.isEmpty && !(code.count == 23 && code.prefix(3) == Data([0xef, 0x01, 0x00]))
            checkedRecipient = to
        } catch {
            guard !Task.isCancelled, to == recipientAddress else { return }
            recipientCheckFailed = true
            checkedRecipient = to
        }
    }

    /// The whole balance; for MON, less the send's network fee (MERA-PLAN §5), estimated for the recipient once one is
    /// entered.
    private func useMax() {
        guard let token, let balance else { return }
        guard token.isNative else { amount = Amount.exact(balance, decimals: token.decimals); return }
        let native = token
        let like = recipientAddress.map { TransactionRequest(to: $0, value: 1) }
        Task {
            let max = await env.sender.maxValue(balance: balance, like: like, from: session.address, budget: NetworkFeeReserve.transferGasLimit)
            // The token or balance changed, or the review opened, while the fee was read: that Max no longer applies.
            guard self.token == native, self.balance == balance, review == nil else { return }
            amount = Amount.exact(max, decimals: native.decimals)
        }
    }
}

/// A send as the review sheet shows and signs it, frozen when Review is tapped.
private struct SendReview: Identifiable {
    let id = UUID()
    let token: Token
    let to: Address
    let amount: BigUInt
    var toContract = false
    /// The token reached the wallet without being chosen here (`HeldToken.unverified`), as the list marked it when it
    /// was picked.
    var unverified = false
    /// Its label when Review was tapped (`TokenBadge`): a look-alike's warning in the label's own words ("Not the real
    /// ETH"), a DyorHQ coin's DyorHQ label.
    var badge: TokenBadge

    init(asset: HeldToken, to: Address, amount: BigUInt, toContract: Bool = false, badge: TokenBadge) {
        token = asset.token
        self.to = to
        self.amount = amount
        self.toContract = toContract
        unverified = asset.unverified
        self.badge = badge
    }

    /// What the review says of a token sent to the wallet unasked: a DyorHQ coin by its DyorHQ label, never as Unverified.
    var receivedNote: String {
        if badge.isDyorHQ, let title = badge.title {
            return tr(LocalizedStringResource("\(title): sent to you, not chosen here",
                                              comment: "Send review: a token someone sent to this wallet, not one chosen in the app. %@ is its DyorHQ label, DyorHQ Launch or DyorHQ Moment"))
        }
        return tr(LocalizedStringResource("Unverified: sent to you, not chosen here",
                                          comment: "Send review: a token someone sent to this wallet, not one chosen in the app, so its name proves nothing"))
    }

    func request() throws -> TransactionRequest { try TokenTransfer.request(token, to: to, amount: amount) }
}

/// The Send sheet's token list as last read.
private enum AssetList: Equatable {
    case loading
    /// The read failed: shown as a failure with Retry, never as an empty wallet.
    case failed
    /// `complete`: false when part of the wallet's history couldn't be read, so a token may be missing (`WalletTokens.Read`).
    /// `pricesFailed`: values are missing and the order is by amount (`WalletTokens.Ranked`). `readingHistory`: MON, the
    /// curated tokens and the stored ones, while the wallet's history is still read; the tokens it shows are added when it
    /// is.
    case loaded([HeldToken], complete: Bool, pricesFailed: Bool, readingHistory: Bool = false)
}

/// Every token the wallet holds, highest dollar value first (`WalletHoldings.ranked`), searchable by symbol, name or
/// pasted address. Unverified tokens are listed where their value puts them, marked.
private struct SendAssetPicker: View {
    let assets: [HeldToken]
    let selected: Address?
    /// The wallet's history is still read: more tokens may be added.
    let readingHistory: Bool
    let onPick: (HeldToken) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""

    var body: some View {
        let shown = WalletHoldings.matching(assets, query: query)
        let badges = shown.map { env.dyorCoins.badge($0.token, receivedUnasked: $0.unverified) }
        List {
            Section {
                ForEach(shown) { asset in
                    Button {
                        Haptics.selection()
                        onPick(asset)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            SendAssetRow(asset: asset)
                            if asset.id == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Selected") }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if readingHistory { Paragraph("Still reading your wallet's history, so more tokens may be added.") }
                    if shown.isEmpty {
                        Text("No token in this wallet matches.")
                    } else if zip(shown, badges).contains(where: { $0.unverified && !$1.isDyorHQ }) {
                        Paragraph("Unverified tokens arrived in your wallet without you choosing them here. Anyone can send any token, with any name — including a real token's. Check the contract before you send.")
                    } else if shown.contains(where: \.unverified) {
                        Paragraph("Some DyorHQ coins here were sent to your wallet without you choosing them here. Anyone can launch a coin on DyorHQ: check the contract before you send.")
                    } else if badges.contains(where: \.isImitation) {
                        Paragraph("Some tokens here carry the name of another token but are other contracts. Check the contract before you send.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: tr("Symbol, name or address"))
        .navigationTitle(tr("Choose a Token"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One held token: logo, symbol with its label (`TokenBadge`: DyorHQ Launch or Moment, Unverified, or a look-alike's
/// "Not the real ETH"), name, balance and dollar value — or "No price". A token that could pass for another — sent to
/// the wallet, carrying another token's name, or with a symbol that isn't plain text (an invisible character, a letter
/// from another script) — also shows its contract.
private struct SendAssetRow: View {
    let asset: HeldToken
    @Environment(AppEnvironment.self) private var env

    private var badge: TokenBadge { env.dyorCoins.badge(asset.token, receivedUnasked: asset.unverified) }

    var body: some View {
        HStack(spacing: 12) {
            // By address (`CoinIcon`): a shipped logo only for the curated token itself, and letters for one carrying another
            // token's name (its own could be the real one's artwork).
            TokenLogo(token: asset.token, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(asset.token.symbol).font(.headline).lineLimit(1)
                    TokenBadgeView(badge)
                }
                // So a look-alike's name is never all there is to go on.
                Text(subtitle).font(.footnote).foregroundStyle(badge.isImitation ? AnyShapeStyle(Color.attention) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(NumberStyle.units(asset.balance, decimals: asset.token.decimals, compact: true)).monospacedDigit()
                Text(valueText).font(.footnote).foregroundStyle(asset.value == nil ? HierarchicalShapeStyle.tertiary : .secondary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        return asset.unverified || !asset.plainSymbol || badge.isWarning ? "\(asset.token.displayName) · \(asset.token.address.short)" : asset.token.displayName
    }

    private var valueText: String {
        guard let value = asset.value else { return tr("No price") }
        return PriceFormat.usdValue(value)
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
