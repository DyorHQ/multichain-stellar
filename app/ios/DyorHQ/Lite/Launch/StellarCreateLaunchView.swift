// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift CreateLaunchView (42cd8c7 sha256:8a8c8e605d26)
// Stellar copy of ios/DyorHQ/Launchpad/LaunchpadView.swift LaunchPreviewCard (42cd8c7 sha256:146ddaa7fc9e)
// Launch a coin on Stellar (docs/DESIGN-stellar-parity.md §8.10.3, §8.10.5; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import PhotosUI
import StellarKit
import SwiftUI

/// Launch a coin on Stellar's launchpad v2, laid out as Monad's `CreateLaunchView`: its image, a live preview card, its
/// name, ticker and description, links, the asset it is priced in and where it graduates, a developer buy, and Monad's
/// Advanced (the creator tax and fee sharing with holders, then a fee recipient and wallets exempt from the early-buy
/// tax). The launchpad's terms and the 10 XLM launch fee are read live (`/v1/economics`, the launch preview); the review
/// shows every term the launch binds, its durations included, and its network fee. Done opens the new coin's page.
///
/// A ticker must be 2–10 ASCII letters or digits and is refused here with a clear message, before any review; a name
/// is at most 32 bytes and passes `SymbolSafety`. Too little XLM for the launch fee, the network fee and the account's
/// minimum balance is said with what is missing, before the review.
struct StellarCreateLaunchView: View {
    /// Once the launch settled and Create closed, exactly once (Done, a swipe of the settled review, or View): the new
    /// coin's contract, when its transaction returned it. Create opens the coin's page itself (`openLaunched`).
    var onLaunched: (String?) -> Void = { _ in }
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var launches: LaunchV2Store?
    @State private var name = ""
    @State private var symbol = ""
    @State private var description = ""
    @State private var website = ""
    @State private var twitter = ""
    @State private var telegram = ""
    /// The quote asset's id ("XLM", "USDC").
    @State private var quoteAsset = ""
    /// The venue chosen, where the quote allows more than one; nil for its default.
    @State private var venue: Int?
    @State private var creatorFeeBps = 0
    @State private var holderSharing = true
    @State private var recipientText = ""
    @State private var exemptText = ""
    @State private var exempt: [String] = []
    @State private var initialBuyText = ""
    @State private var showAdvanced = false
    @State private var showConfirm = false
    @State private var photoItem: PhotosPickerItem?
    /// The picture as it is uploaded with the launch (`UIImage.launchJPEG`), and its local preview.
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var imageError: String?
    /// The launch preview of the last read that went through; nil again once a read fails, as it no longer describes the
    /// form.
    @State private var preview: StellarLaunchPreviewV2?
    /// Why the last read of the preview failed (said with Retry); nil once a read is under way again.
    @State private var previewError: String?
    /// Retry and Check Again read the preview again: after a failed read, a cancelled sign-in, or XLM added.
    @State private var previewReads = 0
    /// The new coin, from what the launch returned.
    @State private var launchedToken: String?

    /// Name: at most this many bytes (the launchpad's limit).
    static let maxNameBytes = 32
    /// Description: at most this many Unicode scalars, as the server counts them (launch_metadata.ts).
    static let maxDescription = 500
    /// A link: at most this many UTF-16 units, as the server counts them.
    static let maxLink = 200
    /// The contract's limit on exemptions besides the creator and the recipient.
    static let maxExempt = 32

    private var store: LiteStore? { session?.store }
    private var economics: StellarLaunchpadEconomicsV2? { launches?.economics }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var ticker: String? { StellarTickerV2.normalized(symbol) }

    /// Why this name or ticker can't be launched (`SymbolSafety.createRefusal`): said under its field, and Review stays
    /// off.
    private var refusal: SymbolSafety.CreateRefusal? {
        SymbolSafety.createRefusal(name: trimmedName, symbol: symbol, maxName: Self.maxNameBytes)
    }

    private var quotes: [StellarLaunchpadEconomicsV2.Quote] { economics?.quotes.filter(\.enabled) ?? [] }
    private var quote: StellarLaunchpadEconomicsV2.Quote? { quotes.first { $0.asset == quoteAsset } ?? quotes.first }

    /// The venues this quote may graduate on (O7: Soroswap only today, so the picker shows only when there are more).
    private var venues: [StellarLaunchVenueV2] {
        guard let economics, let quote else { return [] }
        return economics.venues.filter { $0.enabled && (quote.venuesAllowed.isEmpty || quote.venuesAllowed.contains($0.id)) }
    }

    private var chosenVenue: Int? { quote?.venueLocked == true ? quote?.defaultVenue : venue ?? quote?.defaultVenue }

    /// The launch preview of the quote and venue chosen: one read for another pair (just before a change, while the
    /// next one is read) is never used for its terms, Max or shortfall.
    private var currentPreview: StellarLaunchPreviewV2? { Self.preview(preview, quote: quote?.contract, venue: chosenVenue) }

    /// `preview` when it was read for the quote asset `quote` (its contract) and `venue`; nil when it was another pair's.
    static func preview(_ preview: StellarLaunchPreviewV2?, quote: String?, venue: Int?) -> StellarLaunchPreviewV2? {
        guard let preview, preview.terms.quote == quote, preview.venue.id == venue else { return nil }
        return preview
    }

    /// The terms the launch binds: the preview's for this quote and venue, else the economics' for its default venue.
    private var terms: StellarLaunchTermsV2? {
        if let currentPreview { return currentPreview.terms }
        return chosenVenue == quote?.defaultVenue ? quote?.terms : nil
    }

    private var quoteCode: String { quote?.code ?? "" }
    private var quoteIsXLM: Bool { quote.map { $0.contract == economics?.launchFee.contract } ?? false }
    private var launchFee: Int64 { terms.flatMap { Int64($0.launchFee) } ?? economics.flatMap { Int64($0.launchFee.amount) } ?? 0 }
    private var initialBuy: Int64 { StellarAmount.parse(initialBuyText) ?? 0 }
    private var firstBuy: LaunchV2FirstBuy? { terms.flatMap { LaunchV2Store.firstBuy(initialBuy, terms: $0, creatorFeeBps: creatorFeeBps) } }

    private var recipient: StellarAccountID? { StellarAccountID(recipientText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var recipientInvalid: Bool { !recipientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && recipient == nil }

    /// Why nothing can be launched from here now: the terms unread, no v2 launchpad on this network, launches paused, or
    /// a build that can't sign for launchpad v2.
    private var blocker: LocalizedStringResource? {
        guard let launches else { return nil }
        switch launches.economicsStatus {
        case .unread: return nil
        case .failed: return "The launchpad's terms couldn't be read. Close this screen and try again."
        default: break
        }
        guard let economics else {
            return LocalizedStringResource("New launches open soon.", table: "StellarLaunch", comment: "On Stellar's Launch a Coin screen: the network's new launchpad isn't live yet")
        }
        if !economics.launchesEnabled || quotes.isEmpty {
            return LocalizedStringResource("New launches are paused.", table: "StellarLaunch", comment: "On Stellar's launch board and Launch a Coin screen: the launchpad takes no new launches for now")
        }
        if !launches.isPinned {
            return LocalizedStringResource("This version of DyorHQ can't launch on Stellar's new launchpad yet. Update DyorHQ.", table: "StellarLaunch", comment: "On Stellar's Launch a Coin screen: this build of the app can't sign for the new launchpad. DyorHQ and Stellar are never translated")
        }
        return nil
    }

    /// The XLM (or quote) missing before the review (F18, V12): the launch fee, its network fee and the account's minimum
    /// balance come first; for an XLM quote the developer buy too.
    private var shortfall: String? {
        switch currentPreview.flatMap({ Self.shortage($0, initialBuy: initialBuy, quoteIsXLM: quoteIsXLM) }) {
        case nil:
            return nil
        case .quote(let balance)?:
            return tr("Not enough \(quoteCode): you have \(StellarFormat.units(balance)).")
        case .xlm(let missing)?:
            return liteTr(LocalizedStringResource("Not enough XLM: you need \(StellarFormat.units(missing)) XLM more. The \(StellarFormat.units(launchFee)) XLM launch fee, the network fee and your account's minimum balance come first.", table: "StellarLaunch", comment: "On Stellar's Launch a Coin screen, before the review: the account's XLM doesn't cover the launch. The first value is the XLM missing, the second the launch fee in XLM (10). XLM is never translated"))
        }
    }

    /// What a launch with a developer buy of `initialBuy` is short of, from the launch preview: XLM (in stroops) when the
    /// account can't pay the fee, its network fee and its minimum balance (and, for an XLM quote, the buy); the quote's
    /// balance when the buy is more than it holds. Nil when it fits.
    enum Shortage: Equatable {
        case xlm(Int64)
        case quote(balance: Int64)
    }

    static func shortage(_ preview: StellarLaunchPreviewV2, initialBuy: Int64, quoteIsXLM: Bool) -> Shortage? {
        if let short = preview.shortfall.flatMap({ Int64($0) }), short > 0 { return .xlm(short + (quoteIsXLM ? initialBuy : 0)) }
        if quoteIsXLM, let max = Int64(preview.maxInitialBuy), initialBuy > max { return .xlm(initialBuy - max) }
        if !quoteIsXLM, let balance = Int64(preview.quoteBalance), initialBuy > balance { return .quote(balance: balance) }
        return nil
    }

    private var linksValid: Bool {
        Self.linkAccepted(website, .website) && Self.linkAccepted(twitter, .x) && Self.linkAccepted(telegram, .telegram)
    }

    /// The preview Review waits for is being read: nothing went wrong, so the footer says it is checking.
    private var previewPending: Bool {
        currentPreview == nil && previewError == nil && blocker == nil && quote != nil
    }

    /// Review waits for the preview of the quote and venue chosen too: its shortfall is what the launch checks first.
    /// While it is missing the footer always says why: checking, or the read's error with Retry.
    private var valid: Bool {
        trimmedName.count >= 2 && ticker != nil && refusal == nil && terms != nil && blocker == nil && !recipientInvalid && linksValid
            && currentPreview != nil && shortfall == nil && (initialBuy == 0 || firstBuy != nil) && (session?.canSign ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let blocker {
                    Section {
                        Label { Paragraph(blocker) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.subheadline).foregroundStyle(Color.attention)
                    }
                }
                imageSection
                previewSection
                Section("Coin") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, typed in
                            let fitted = Self.fitted(typed, bytes: Self.maxNameBytes)
                            if fitted != typed { name = fitted }
                        }
                    if let refusal, !refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    TextField("Ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, typed in
                            let kept = String(typed.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10))
                            if kept != typed { symbol = kept }
                        }
                    if let refusal, refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    else if !symbol.isEmpty, ticker == nil {
                        InlineError(message: LocalizedStringResource("Ticker: 2–10 letters (A–Z) or digits, without accents, spaces or symbols.", table: "StellarLaunch", comment: "Under the ticker field of Stellar's Launch a Coin screen: what a Stellar coin's ticker may hold. A–Z stays as it is"))
                    }
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: description) { _, typed in
                            let fitted = Self.fitted(typed, scalars: Self.maxDescription)
                            if fitted != typed { description = fitted }
                        }
                }
                linksSection
                pairingSection
                developerBuySection
                advancedSection
            }
            .navigationTitle(tr("Launch a Coin"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { Haptics.tap(); showConfirm = true }.fontWeight(.semibold).disabled(!valid)
                }
            }
            .sheet(isPresented: $showConfirm) { confirmation }
            .onChange(of: photoItem) { _, item in if let item { Task { await readImage(item) } } }
            // The store's identity: Create opened before the session has a store reads once it does.
            .task(id: store.map(ObjectIdentifier.init)) { await loadEconomics() }
            .task(id: previewKey) { await readPreview() }
        }
    }

    // MARK: Image and preview

    private var imageSection: some View {
        Section {
            HStack(spacing: 16) {
                artwork(size: 72)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(imageData == nil ? "Choose Image" : "Change Image", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    if let imageError {
                        Paragraph(verbatim: imageError).font(.caption).foregroundStyle(Color.attention)
                    } else {
                        Text("Square images look best.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    /// The picture chosen (shown at once, before it is uploaded with the launch), or the coin's letters.
    @ViewBuilder private func artwork(size: CGFloat) -> some View {
        if let previewImage {
            Image(uiImage: previewImage).resizable().scaledToFill()
        } else {
            StellarArtwork(symbol: symbol.isEmpty ? "?" : symbol, image: nil, pointSize: size)
        }
    }

    @ViewBuilder private var previewSection: some View {
        if trimmedName.count >= 2, ticker != nil, refusal == nil {
            Section {
                StellarLaunchPreviewCard(name: trimmedName, symbol: symbol, image: previewImage, pairSymbol: quoteCode)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Your Coin")
            }
        }
    }

    // MARK: Pairing

    private var pairingSection: some View {
        Section {
            if quotes.count > 1 {
                Picker("Paired with", selection: $quoteAsset) {
                    ForEach(quotes, id: \.asset) { Text(verbatim: $0.code).tag($0.asset) }
                }
            } else {
                LabeledContent("Paired with", value: quoteCode)
            }
            if venues.count > 1, quote?.venueLocked == false {
                Picker("Graduates on", selection: Binding(get: { chosenVenue ?? -1 }, set: { venue = $0 })) {
                    ForEach(venues) { Text(verbatim: $0.name).tag($0.id) }
                }
            } else {
                LabeledContent("Graduates on", value: venueName)
            }
            LabeledContent("Launch fee", value: launchFee > 0 ? "\(StellarFormat.units(launchFee)) XLM" : "—")
        } header: {
            Text("Pairing")
        } footer: {
            if let terms {
                Paragraph(LocalizedStringResource("Graduates to a \(venueName) pool, liquidity locked forever, once the curve raises \(StellarFormat.units(terms.threshold, compact: true)) \(quoteCode).", table: "StellarLaunch", comment: "Footer of the pairing on Stellar's Launch a Coin screen. Values: the venue's name (Soroswap), the raise that completes the curve, and its asset (XLM)"))
            }
        }
        .onChange(of: quoteAsset) { _, _ in venue = nil }
    }

    private var venueName: String { terms?.venue.name ?? venues.first { $0.id == chosenVenue }?.name ?? "Soroswap" } // not localized: a venue's name

    // MARK: Links

    /// The coin's links, each refused under its field when the server would refuse it.
    private var linksSection: some View {
        Section("Links") {
            TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !Self.linkAccepted(website, .website) {
                InlineError(message: LocalizedStringResource("Website: an https link, at most \(Self.maxLink) characters.", table: "StellarLaunch", comment: "Under the website field of Stellar's Launch a Coin screen: what a coin's website link may be. The value is the most characters (200). https stays as it is"))
            }
            TextField("X profile", text: $twitter).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !Self.linkAccepted(twitter, .x) {
                InlineError(message: LocalizedStringResource("X: an https link to a profile on x.com or twitter.com, at most \(Self.maxLink) characters.", table: "StellarLaunch", comment: "Under the X profile field of Stellar's Launch a Coin screen: what a coin's X link may be. The value is the most characters (200). X, https, x.com and twitter.com stay as they are"))
            }
            TextField("Telegram", text: $telegram).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !Self.linkAccepted(telegram, .telegram) {
                InlineError(message: LocalizedStringResource("Telegram: an https link on t.me, at most \(Self.maxLink) characters.", table: "StellarLaunch", comment: "Under the Telegram field of Stellar's Launch a Coin screen: what a coin's Telegram link may be. The value is the most characters (200). Telegram, https and t.me stay as they are"))
            }
        }
    }

    /// A coin's link fields, and the sites the server holds X and Telegram links to.
    enum LinkKind {
        case website, x, telegram

        var hosts: [String]? {
            switch self {
            case .website: nil
            case .x: ["x.com", "twitter.com"]
            case .telegram: ["t.me"]
            }
        }
    }

    /// Whether the server takes `text` as a `kind` link (launch_metadata.ts `launchLink`): empty, or https with a host, at
    /// most `maxLink` characters and no user name or password; an X or Telegram link a page on that service's own site.
    static func linkAccepted(_ text: String, _ kind: LinkKind) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard trimmed.utf16.count <= maxLink, let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        guard let hosts = kind.hosts else { return true }
        return hosts.contains(host) && url.path(percentEncoded: true).count >= 2
    }

    // MARK: Developer buy

    private var developerBuySection: some View {
        Section {
            StellarAmountField(title: "0" as String, text: $initialBuyText, code: quoteCode.isEmpty ? nil : quoteCode) {
                if let max = currentPreview.flatMap({ Int64($0.maxInitialBuy) }) { initialBuyText = StellarFormat.plain(units: max) }
            }
            if let firstBuy {
                DetailRow("You receive", verbatim: "\(StellarFormat.units(firstBuy.tokensOut, compact: true)) \(ticker ?? symbol)")
            }
        } header: {
            Text("Developer Buy (Optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                // Review waits for the preview, so whenever it is off for the preview's sake this says why, and each of
                // these can read it again: a read that failed or a sign-in that was cancelled, the account's XLM once
                // some is added.
                if let previewError {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: previewError)
                        Spacer(minLength: 8)
                        Button("Retry") { previewReads += 1 }.font(.footnote.weight(.semibold))
                    }
                } else if let shortfall {
                    HStack(alignment: .firstTextBaseline) {
                        Paragraph(verbatim: shortfall).foregroundStyle(Color.attention)
                        Spacer(minLength: 8)
                        Button("Check Again") { previewReads += 1 }.font(.footnote.weight(.semibold))
                    }
                } else if previewPending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…")
                    }
                    .foregroundStyle(.secondary)
                }
                Paragraph("Buy your own coin in the same transaction — snipe-tax exempt.")
            }
        }
    }

    // MARK: Advanced

    /// Monad's Advanced, inline: the creator tax and fee sharing, then the two settings launchpad v2 adds (a fee recipient
    /// and wallets exempt from the early-buy tax), under one footer.
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper("Creator tax \(NumberStyle.basisPoints(creatorFeeBps))", value: $creatorFeeBps,
                        in: 0...(terms?.maxCreatorFeeBps ?? economics?.maxCreatorFeeBps ?? 0), step: 25)
                Toggle("Share fees with holders", isOn: $holderSharing).tint(.brand)
                addressField($recipientText, prompt: Text("Fee recipient (optional)", tableName: "StellarLaunch", comment: "A field on Stellar's Launch a Coin screen: another account to receive the coin's creator fees; empty for the creator"))
                if recipientInvalid {
                    InlineError(message: LocalizedStringResource("That isn't a Stellar address.", table: "StellarLaunch", comment: "Under an address field on Stellar: what was typed isn't a valid G… or C… address. Stellar is a network's name, never translated"))
                }
                ForEach(exempt, id: \.self) { address in
                    if let id = StellarAccountID(address) {
                        LabeledContent {
                            StellarAddressText(id)
                        } label: {
                            Text("Exempt", tableName: "StellarLaunch", comment: "[tight] On Stellar's Launch a Coin screen, before a wallet's address: it pays no early-buy (snipe) tax on the new coin")
                        }
                    }
                }
                .onDelete { exempt.remove(atOffsets: $0) }
                if exempt.count < Self.maxExempt {
                    HStack {
                        addressField($exemptText, prompt: Text("Wallet exempt from the early-buy tax", tableName: "StellarLaunch", comment: "A field on Stellar's Launch a Coin screen: a wallet address that pays no early-buy (snipe) tax on the new coin, added with the Add button beside it"))
                        Button("Add") {
                            guard let id = StellarAccountID(exemptText.trimmingCharacters(in: .whitespacesAndNewlines)), !exempt.contains(id.checksummed) else { return }
                            exempt.append(id.checksummed)
                            exemptText = ""
                        }
                        .disabled(StellarAccountID(exemptText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                }
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } footer: {
            if let terms { Paragraph(Self.feeFooter(terms)) }
        }
    }

    /// An address typed in Advanced: monospaced, in capitals as StrKeys are, never corrected.
    private func addressField(_ text: Binding<String>, prompt: Text) -> some View {
        TextField(text: text, prompt: prompt) { prompt }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
    }

    /// Advanced's one footer, true for launchpad v2: the creator tax is charged on curve trades only; the creator (or the
    /// fee recipient) receives it with its share of the curve fee and, after graduation, its share of what the locked
    /// Soroswap liquidity earns (the launch's own `protocolShareBps` going to DyorHQ); with sharing on, holders receive all
    /// of it.
    static func feeFooter(_ terms: StellarLaunchTermsV2) -> LocalizedStringResource {
        let protocolShare = min(10_000, max(0, terms.protocolShareBps))
        return LocalizedStringResource("Creator tax is charged on curve trades only. You, or the fee recipient you set, receive it with a share of the curve fee and, after graduation, \(NumberStyle.basisPoints(10_000 - protocolShare)) of the fees its locked \(terms.venue.name) liquidity earns (\(NumberStyle.basisPoints(protocolShare)) go to DyorHQ). With fee sharing on, holders receive all of it instead.", table: "StellarLaunch", comment: "The footer of Advanced on Stellar's Launch a Coin screen. The values are shares (50%, 50%) and the graduation venue's name (Soroswap, never translated). DyorHQ is never translated")
    }

    /// With fee sharing on, the creator fee and the creator's share of the curve fee go to holders: said in the review, so
    /// a creator who sets a fee knows there will be none to claim.
    static let sharingTakesCreatorFees = LocalizedStringResource("With fee sharing on, the creator fee and the creator's share of the curve fee go to holders as rewards, so there are no creator fees to claim. Turn sharing off to keep them.", table: "StellarLaunch", comment: "On Stellar's Launch a Coin screen and its review, while Share fees with holders is on: the creator's fees all go to the coin's holders")

    // MARK: Review (§8.10.5 L)

    @ViewBuilder private var confirmation: some View {
        if let launches, let terms, let ticker {
            StellarConfirmationSheet(
                title: "Launch \(ticker)", confirmTitle: "Launch \(ticker)",
                build: { try await launches.createPlan(form(ticker: ticker, terms: terms), terms: terms, image: imageData) },
                // The review runs this once, however its settled sheet closes: Done, a swipe, or View (below). Create closes
                // and the new coin's own page opens over the board (`openLaunched`).
                onDone: {
                    let token = launchedToken
                    dismiss()
                    onLaunched(token)
                    Self.openLaunched(token, router: router)
                },
                onCompleted: { results in
                    launchedToken = Self.launchedToken(results)
                },
                onView: { hash in
                    // The new coin's own page, from what its launch returned: the review closes, and its cleanup (onDone)
                    // closes Create and opens the page. StellarExpert only when the launch returned nothing.
                    if launchedToken != nil {
                        showConfirm = false
                    } else if let page = StellarExplorer.transaction(hash, network: LiteGate.pinned.network) {
                        UIApplication.shared.open(page)
                    }
                }
            ) {
                DetailRow("Coin", verbatim: "\(trimmedName) ($\(ticker))")
                DetailRow("Paired with", verbatim: quoteCode)
                DetailRow("Graduation", verbatim: "\(StellarFormat.units(terms.threshold, compact: true)) \(quoteCode)")
                DetailRow("Graduation venue", verbatim: terms.venue.name)
                if terms.fallback.id != terms.venue.id {
                    DetailRow(Text("Fallback venue", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: where the coin graduates if its own venue keeps failing"), Text(verbatim: terms.fallback.name))
                }
                DetailRow(Text("Creator tax"), Text(verbatim: NumberStyle.basisPoints(creatorFeeBps)))
                DetailRow(Text("Fee sharing"), Text(holderSharing ? "On" : "Off"))
                if holderSharing {
                    Paragraph(Self.sharingTakesCreatorFees).font(.footnote).foregroundStyle(.secondary)
                }
                if let recipient { DetailRow("Fee recipient", verbatim: recipient.short) }
                if !exempt.isEmpty {
                    DetailRow(Text("Early-buy tax exemptions", tableName: "StellarLaunch", comment: "In the review of a Stellar launch, beside a number: how many wallets pay no early-buy (snipe) tax on the new coin"),
                              Text(verbatim: "\(exempt.count)"))
                }
                DetailRow("Launch fee", verbatim: "\(StellarFormat.units(Int64(terms.launchFee) ?? 0)) XLM")
                if let firstBuy {
                    DetailRow("Developer buy", verbatim: StellarFormat.amount(initialBuy, code: quoteCode))
                    DetailRow("You receive", verbatim: "\(StellarFormat.units(firstBuy.tokensOut, compact: true)) \(ticker)")
                }
                DetailRow("Curve fee", verbatim: NumberStyle.basisPoints(terms.feeBps))
                DetailRow("Supply", verbatim: StellarFormat.units(terms.supply, compact: true))
                durationRow(Text("Graduation grace", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long a full curve may take to graduate before anyone can mark it delayed"), terms.durations.grace)
                durationRow(Text("Fallback after", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long after a delay its fallback venue opens"),
                            Self.fallbackDelay(terms))
                durationRow(Text("Refunds by DyorHQ after", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long after a delay DyorHQ's admin can switch it to refunds, before anyone can. DyorHQ is never translated"), terms.durations.rescueAdmin)
                durationRow(Text("Refunds by anyone after", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long after a delay anyone can switch it to refunds"), terms.durations.rescuePublic)
                durationRow(Text("Recipient takeover notice", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long the fee recipient has to veto a change DyorHQ's admin proposes. DyorHQ is never translated"), terms.durations.takeoverDelay)
                durationRow(Text("Recipient takeover window", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: once its notice is over, how long a fee recipient change DyorHQ's admin proposed can be applied before it lapses. DyorHQ is never translated"), terms.durations.takeoverWindow)
                durationRow(Text("Pool fees collected every", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how often its pool's fees are collected after graduation"), terms.durations.harvestInterval)
            }
        }
    }

    /// The new coin's contract, from what its launch returned; nil when it returned none.
    static func launchedToken(_ results: [TxStatus]) -> String? {
        guard case .string(let token)? = results.last?.returnValue, StrKey.isValid(.contract, token) else { return nil }
        return token
    }

    /// After a launch, Create's sheets close and the new coin's page opens over the Launch board: once they have closed
    /// (`Router.coverCloses`; a push asked for while two sheets are still closing could be lost), through the router, so the
    /// board pushes it (`pendingStellar`) whichever screen presented Create, and its page reads the coin first, waiting for
    /// the indexer's row as the page of a coin just launched (`StellarLaunchDetailView.justLaunched`). Nothing when the
    /// launch returned no coin.
    static func openLaunched(_ token: String?, router: Router) {
        guard let token, let destination = destination(afterLaunching: token) else { return }
        StellarLaunchDetailView.justLaunched.insert(token)
        Task { @MainActor in
            try? await Task.sleep(for: Router.coverCloses)
            router.openStellar(destination)
        }
    }

    /// Where Done takes a settled launch: the new coin's page on the Launch tab, when its contract is known.
    static func destination(afterLaunching token: String?) -> StellarDestination? {
        guard let token, StrKey.isValid(.contract, token) else { return nil }
        return .launch(token: token)
    }

    private func durationRow(_ label: Text, _ seconds: Int) -> some View {
        DetailRow(label, Text(verbatim: Self.duration(seconds)))
    }

    /// How long after a delay the fallback venue opens: `fallbackDelay`, and for a venue-locked launch no sooner than
    /// `lockedFallback` (launchpad-v2's `fallback_at`, unless DyorHQ's admin allows it earlier).
    static func fallbackDelay(_ terms: StellarLaunchTermsV2) -> Int {
        terms.venueLocked ? max(terms.durations.fallbackDelay, terms.durations.lockedFallback) : terms.durations.fallbackDelay
    }

    /// A duration in the app's language: "1 hour", "30 days", "1 day, 12 hours".
    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "—"
    }

    /// The form as the launch takes it.
    private func form(ticker: String, terms: StellarLaunchTermsV2) -> LaunchV2Form {
        LaunchV2Form(name: trimmedName, symbol: ticker, description: description.isEmpty ? nil : description, website: Self.link(website),
                     x: Self.link(twitter), telegram: Self.link(telegram), quote: quote?.asset ?? "XLM", venue: terms.venue.id,
                     creatorFeeBps: creatorFeeBps, holderSharing: holderSharing, recipient: recipient?.checksummed, exempt: exempt,
                     developerBuy: firstBuy == nil ? 0 : initialBuy, minOut: firstBuy?.minOut ?? 0)
    }

    private static func link(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `text` cut to at most `bytes` UTF-8 bytes, whole characters only.
    static func fitted(_ text: String, bytes: Int) -> String { fitted(text, limit: bytes) { $0.utf8.count } }

    /// `text` cut to at most `scalars` Unicode scalars (what the server's `[...text].length` counts), whole characters
    /// only.
    static func fitted(_ text: String, scalars: Int) -> String { fitted(text, limit: scalars) { $0.unicodeScalars.count } }

    private static func fitted(_ text: String, limit: Int, size: (String) -> Int) -> String {
        var kept = ""
        var used = 0
        for character in text {
            let next = size(String(character))
            guard used + next <= limit else { break }
            kept.append(character)
            used += next
        }
        return kept
    }

    // MARK: Reading

    private func loadEconomics() async {
        guard let store else { return }
        let launches = self.launches.flatMap { $0.store === store ? $0 : nil } ?? LaunchV2Store(store: store)
        self.launches = launches
        await launches.refreshEconomics()
        if quoteAsset.isEmpty, let first = launches.economics?.quotes.first(where: \.enabled) { quoteAsset = first.asset }
    }

    /// What changes the launch's fee, Max and the XLM it needs: the form's terms, the account (another one, or XLM added
    /// since), and Retry or Check Again. (The name and ticker don't: the preview prices the longest ones while they're
    /// empty.)
    private var previewKey: String {
        "\(quote?.asset ?? "")-\(chosenVenue ?? -1)-\(creatorFeeBps)-\(holderSharing)-\(recipient?.checksummed ?? "")-\(exempt.joined(separator: ","))"
            + "-\(launches?.economics != nil)-\(Self.accountKey(store?.account))-\(previewReads)"
    }

    /// The account and its balances as one string: another account, its activation or a change of any balance reads the
    /// preview again; the same balances read again (in any order) change nothing.
    static func accountKey(_ account: AccountView?) -> String {
        guard let account else { return "" }
        return "\(account.address):\(account.exists):" + account.balances.map { "\($0.asset)=\($0.balance)" }.sorted().joined(separator: ",")
    }

    /// The launch preview (§20.3): the terms for this quote and venue, Max for the first buy and any XLM shortfall. A read
    /// that fails drops the last one, so Review stays off with the error and Retry rather than on terms that may be stale.
    private func readPreview() async {
        guard let launches, let quote, blocker == nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        previewError = nil
        let draft = LaunchV2Form(name: trimmedName, symbol: ticker ?? "", quote: quote.asset, venue: chosenVenue, creatorFeeBps: creatorFeeBps,
                                 holderSharing: holderSharing, recipient: recipient?.checksummed, exempt: exempt)
        do {
            let fresh = try await launches.preview(draft)
            guard !Task.isCancelled else { return }
            preview = fresh
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewError = LiteErrorText.describe(error)
        }
    }

    /// The middle square, 512 pixels a side (`launchJPEG`): what the preview shows is what every screen shows.
    private func readImage(_ item: PhotosPickerItem) async {
        imageError = nil
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.launchJPEG() else {
            imageError = tr("That image could not be read.")
            return
        }
        imageData = jpeg
        previewImage = UIImage(data: jpeg)
        Haptics.success()
    }
}

/// The live preview shown while creating a coin: the same shape as a board card.
private struct StellarLaunchPreviewCard: View {
    let name: String
    let symbol: String
    let image: UIImage?
    let pairSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    StellarArtwork(symbol: symbol.isEmpty ? "?" : symbol, image: nil)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    (name.isEmpty ? Text("Your coin") : Text(verbatim: name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    // not localized: a ticker stands in for the one still to be typed, as tickers are never translated.
                    Text(verbatim: "$\(symbol.isEmpty ? "TICKER" : symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("New").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.brand.opacity(0.14), in: Capsule())
                    Spacer()
                    Text("Pairs with \(pairSymbol)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
