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
/// name, ticker and description, links, the asset it is priced in and where it graduates, a developer buy, and the
/// advanced terms (the creator fee until graduation, fee sharing with holders, a fee recipient and wallets exempt from
/// the early-buy tax). The launchpad's terms and the 10 XLM launch fee are read live (`/v1/economics`, the launch
/// preview); the review shows every term the launch binds, its durations included, and its network fee.
///
/// A ticker must be 2–10 ASCII letters or digits and is refused here with a clear message, before any review; a name
/// is at most 32 bytes and passes `SymbolSafety`. Too little XLM for the launch fee, the network fee and the account's
/// minimum balance is said with what is missing, before the review.
struct StellarCreateLaunchView: View {
    /// Once the launch settled: the new coin's contract, when its transaction returned it.
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
    @State private var preview: StellarLaunchPreviewV2?
    @State private var previewError: String?
    /// The new coin, from what the launch returned.
    @State private var launchedToken: String?

    /// Name: at most this many bytes (the launchpad's limit).
    static let maxNameBytes = 32
    static let maxDescription = 500
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

    /// The terms the launch binds: the preview's for this quote and venue, else the economics' for its default venue.
    private var terms: StellarLaunchTermsV2? {
        if let preview, preview.terms.quote == quote?.contract, preview.venue.id == chosenVenue { return preview.terms }
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
        switch preview.flatMap({ Self.shortage($0, initialBuy: initialBuy, quoteIsXLM: quoteIsXLM) }) {
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

    private var valid: Bool {
        trimmedName.count >= 2 && ticker != nil && refusal == nil && terms != nil && blocker == nil && !recipientInvalid
            && shortfall == nil && (initialBuy == 0 || firstBuy != nil) && (session?.canSign ?? false)
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
                        .onChange(of: description) { _, typed in if typed.count > Self.maxDescription { description = String(typed.prefix(Self.maxDescription)) } }
                }
                Section("Links") {
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("X profile", text: $twitter).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Telegram", text: $telegram).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                pairingSection
                developerBuySection
                advancedSection
                if showAdvanced { exemptSection }
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
            .task { await loadEconomics() }
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

    // MARK: Developer buy

    private var developerBuySection: some View {
        Section {
            StellarAmountField(title: "0" as String, text: $initialBuyText, code: quoteCode.isEmpty ? nil : quoteCode) {
                if let max = preview.flatMap({ Int64($0.maxInitialBuy) }) { initialBuyText = StellarFormat.plain(units: max) }
            }
            if let firstBuy {
                DetailRow("You receive", verbatim: "\(StellarFormat.units(firstBuy.tokensOut, compact: true)) \(ticker ?? symbol)")
            }
        } header: {
            Text("Developer Buy (Optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let shortfall {
                    Paragraph(verbatim: shortfall).foregroundStyle(Color.attention)
                } else if let previewError {
                    InlineError(message: previewError)
                }
                Paragraph("Buy your own coin in the same transaction — snipe-tax exempt.")
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper(value: $creatorFeeBps, in: 0...(terms?.maxCreatorFeeBps ?? economics?.maxCreatorFeeBps ?? 0), step: 25) {
                    Text("Creator fee (until graduation) \(NumberStyle.basisPoints(creatorFeeBps))", tableName: "StellarLaunch", comment: "A stepper on Stellar's Launch a Coin screen: the creator's fee on every curve trade, charged until the coin graduates. The value is a percent (0.25%)")
                }
                Toggle("Share fees with holders", isOn: $holderSharing).tint(.brand)
                TextField(text: $recipientText, prompt: Text(verbatim: "G… / C…")) {
                    Text("Fee recipient (optional)", tableName: "StellarLaunch", comment: "A field on Stellar's Launch a Coin screen: another account to receive the coin's creator fees; empty for the creator")
                }
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                if recipientInvalid {
                    InlineError(message: LocalizedStringResource("That isn't a Stellar address.", table: "StellarLaunch", comment: "Under an address field on Stellar: what was typed isn't a valid G… or C… address. Stellar is a network's name, never translated"))
                }
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Paragraph(LocalizedStringResource("The creator fee is charged on curve trades only. After graduation the pool's fees are shared instead: half to DyorHQ, half to holders or the fee recipient.", table: "StellarLaunch", comment: "Footer of the advanced terms on Stellar's Launch a Coin screen: the creator fee stops at graduation, when the pool's fees are split. DyorHQ is never translated"))
                if holderSharing {
                    Paragraph(LocalizedStringResource("Holders also earn part of the pool fees after graduation, in this coin and in \(quoteCode).", table: "StellarLaunch", comment: "Under a Stellar coin's holder rewards, and the Share fees with holders setting: after graduation holders also get part of the pool's fees, in the coin and in its quote asset. The value is the quote asset (XLM)"))
                }
            }
        }
    }

    /// Wallets that pay no early-buy tax on this coin, besides the creator and the fee recipient.
    private var exemptSection: some View {
        Section {
            ForEach(exempt, id: \.self) { address in
                if let id = StellarAccountID(address) { StellarAddressText(id) }
            }
            .onDelete { exempt.remove(atOffsets: $0) }
            if exempt.count < Self.maxExempt {
                HStack {
                    TextField(text: $exemptText, prompt: Text(verbatim: "G… / C…")) {
                        Text("Wallet", tableName: "StellarLaunch", comment: "[tight] A field on Stellar's Launch a Coin screen: a wallet address to exempt from the early-buy tax")
                    }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button("Add") {
                        guard let id = StellarAccountID(exemptText.trimmingCharacters(in: .whitespacesAndNewlines)), !exempt.contains(id.checksummed) else { return }
                        exempt.append(id.checksummed)
                        exemptText = ""
                    }
                    .disabled(StellarAccountID(exemptText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }
            }
        } header: {
            Text("Early-buy tax exemptions", tableName: "StellarLaunch", comment: "A section on Stellar's Launch a Coin screen: wallets that pay no early-buy (snipe) tax on the new coin")
        } footer: {
            Paragraph(LocalizedStringResource("These wallets pay no early-buy tax on this coin, besides you and the fee recipient. Up to \(Self.maxExempt).", table: "StellarLaunch", comment: "Footer of the early-buy tax exemptions on Stellar's Launch a Coin screen. The value is the most wallets (32)"))
        }
    }

    // MARK: Review (§8.10.5 L)

    @ViewBuilder private var confirmation: some View {
        if let launches, let terms, let ticker {
            StellarConfirmationSheet(
                title: "Launch \(ticker)", confirmTitle: "Launch \(ticker)",
                build: { try await launches.createPlan(form(ticker: ticker, terms: terms), terms: terms, image: imageData) },
                onDone: {
                    dismiss()
                    onLaunched(launchedToken)
                },
                onCompleted: { results in
                    if case .string(let token)? = results.last?.returnValue, StellarAccountID(token) != nil { launchedToken = token }
                },
                onView: { hash in
                    // The new coin's own page, from what its launch returned; StellarExpert only when it returned nothing.
                    if let launchedToken {
                        router.openStellar(.launch(token: launchedToken))
                        dismiss()
                        onLaunched(launchedToken)
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
                DetailRow(Text("Creator fee (until graduation)", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: the creator's fee on every curve trade, charged until the coin graduates"),
                          Text(verbatim: NumberStyle.basisPoints(creatorFeeBps)))
                DetailRow(Text("Fee sharing"), Text(holderSharing ? "On" : "Off"))
                if let recipient { DetailRow("Fee recipient", verbatim: recipient.short) }
                if !exempt.isEmpty {
                    DetailRow(Text("Early-buy tax exemptions", tableName: "StellarLaunch", comment: "A section on Stellar's Launch a Coin screen: wallets that pay no early-buy (snipe) tax on the new coin"),
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
                durationRow(Text("Fallback after", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long after a delay its fallback venue opens"), terms.durations.fallbackDelay)
                durationRow(Text("Refunds after", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long after a delay anyone can switch it to refunds"), terms.durations.rescuePublic)
                durationRow(Text("Recipient takeover notice", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how long the fee recipient has to veto a change DyorHQ's admin proposes. DyorHQ is never translated"), terms.durations.takeoverDelay)
                durationRow(Text("Pool fees collected every", tableName: "StellarLaunch", comment: "In the review of a Stellar launch: how often its pool's fees are collected after graduation"), terms.durations.harvestInterval)
            }
        }
    }

    private func durationRow(_ label: Text, _ seconds: Int) -> some View {
        DetailRow(label, Text(verbatim: Self.duration(seconds)))
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
    static func fitted(_ text: String, bytes: Int) -> String {
        var kept = ""
        for character in text {
            guard kept.utf8.count + String(character).utf8.count <= bytes else { break }
            kept.append(character)
        }
        return kept
    }

    // MARK: Reading

    private func loadEconomics() async {
        guard let store else { return }
        let launches = self.launches ?? LaunchV2Store(store: store)
        self.launches = launches
        await launches.refreshEconomics()
        if quoteAsset.isEmpty, let first = launches.economics?.quotes.first(where: \.enabled) { quoteAsset = first.asset }
    }

    /// What changes the launch's fee, Max and the XLM it needs.
    private var previewKey: String {
        "\(quote?.asset ?? "")-\(chosenVenue ?? -1)-\(creatorFeeBps)-\(holderSharing)-\(recipient?.checksummed ?? "")-\(exempt.count)-\(launches?.economics != nil)"
    }

    /// The launch preview (§20.3): the terms for this quote and venue, Max for the first buy and any XLM shortfall.
    private func readPreview() async {
        guard let launches, let quote, blocker == nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let draft = LaunchV2Form(name: trimmedName, symbol: ticker ?? "", quote: quote.asset, venue: chosenVenue, creatorFeeBps: creatorFeeBps,
                                 holderSharing: holderSharing, recipient: recipient?.checksummed, exempt: exempt)
        do {
            let fresh = try await launches.preview(draft)
            guard !Task.isCancelled else { return }
            preview = fresh
            previewError = nil
        } catch {
            if !Task.isCancelled { previewError = LiteErrorText.describe(error) }
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
