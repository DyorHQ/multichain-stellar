// Stellar copy of ios/DyorHQ/Moments/CreateMomentView.swift CreateMomentView (42cd8c7 sha256:74d5fc0d1e7f)
// Publishing a Stellar Moment (docs/DESIGN-stellar-parity.md §8.11.4; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import PhotosUI
import StellarKit
import SwiftUI
import UniformTypeIdentifiers

/// Publish a Moment on Stellar: the photo or video (uploaded to DyorHQ's storage as it is picked; a video with its cover
/// frame, the NFT's image), the name and coin ticker, where and when it happened, the collect price in USDC, the
/// creator's coin allocation and how long collecting stays open. Everything is fixed at publish. The review is bound to
/// what it shows: the publish carries the Moments terms by value, and the review refuses Confirm when the plan binds
/// terms other than the ones it read (`termsCheck`).
struct StellarCreateMomentView: View {
    /// Called once the publish settled and the review closed, with the new Moment as Publish knows it: its opener
    /// pushes its page.
    let onPublished: (StellarMomentListingV2) -> Void
    @Environment(\.stellarSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var economics: StellarMomentsEconomicsV2?
    @State private var economicsRead = false
    @State private var economicsError: String?
    @State private var name = ""
    @State private var symbol = ""
    @State private var place = ""
    @State private var date = Date()
    @State private var priceText = "1"
    @State private var allocationPercent = 10
    @State private var windowDays = 30
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var mediaError: String?
    @State private var upload: StellarMomentUploadV2?
    /// The picked photo (or a video's cover frame), shown at once, before the upload returns.
    @State private var previewImage: UIImage?
    @State private var isVideo = false
    /// The form and the terms as they were when Review was tapped, the terms read again then: the sheet shows these and
    /// publishes the form, and Confirm stays off if the plan binds other terms.
    @State private var reviewed: Reviewed?
    @State private var reviewing = false
    /// The new Moment, once its publish settled: opened when the review closes.
    @State private var published: StellarMomentListingV2?

    /// The preview's side, in points.
    private static let previewSide: CGFloat = 84

    struct Reviewed: Identifiable {
        let form: StellarMomentFormV2
        let economics: StellarMomentsEconomicsV2
        let upload: StellarMomentUploadV2
        var id: String { "\(form.symbol)-\(form.price)-\(upload.mediaUrl)" }
    }

    private var moments: MomentsV2Store? { session?.store.map { MomentsV2Store(store: $0) } }
    private var policy: StellarMomentsPolicyV2? { economics?.policy }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedPlace: String { place.trimmingCharacters(in: .whitespaces) }
    private var ticker: String? { StellarTickerV2.normalized(symbol) }
    private var price: Int64? { Amount.parse(priceText, decimals: StellarFormat.decimals).flatMap { Int64(exactly: $0) } }
    private var allocationBps: Int { allocationPercent * 100 }
    private var maxAllocationPercent: Int { (policy?.maxCreatorAllocBps ?? 0) / 100 }
    private var windowDaysRange: ClosedRange<Int> {
        guard let d = economics?.terms.durations else { return 1...30 }
        let low = max(1, (d.minWindow + 86_399) / 86_400)
        return low...max(low, d.maxWindow / 86_400)
    }

    /// Why the name can't be published: a look-alike or hidden character (`SymbolSafety`), or more bytes than the
    /// contract stores.
    private var nameProblem: String? {
        if let refusal = SymbolSafety.createRefusal(name: trimmedName, symbol: "", maxName: Self.maxNameBytes), !refusal.isAboutSymbol { return refusal.message }
        if trimmedName.utf8.count > Self.maxNameBytes {
            return liteTr(LocalizedStringResource("Name: at most 32 bytes. Accented letters and emoji count as more than one.", table: "StellarMoments", comment: "Under the name field of Publish a Moment on Stellar: the name is too long for the contract"))
        }
        return nil
    }

    /// Why the ticker can't be published, said before any review (the contracts take 2–10 ASCII letters or digits).
    private var symbolProblem: String? {
        guard !symbol.isEmpty else { return nil }
        guard ticker != nil else {
            return liteTr(LocalizedStringResource("Ticker: 2–10 letters (A–Z) or digits, without accents, spaces or symbols.", table: "StellarMoments", comment: "Under the coin ticker field of Publish a Moment on Stellar: what a ticker may be"))
        }
        if let refusal = SymbolSafety.createRefusal(name: "", symbol: symbol), refusal.isAboutSymbol { return refusal.message }
        return nil
    }

    private var placeProblem: String? {
        guard trimmedPlace.utf8.count > Self.maxPlaceBytes else { return nil }
        return liteTr(LocalizedStringResource("Place: at most 64 bytes.", table: "StellarMoments", comment: "Under the place field of Publish a Moment on Stellar: the place is too long for the contract"))
    }

    private var priceProblem: String? {
        guard let price, price > 0 else { return tr("Enter a collect price in USDC.") }
        if let policy, let min = Int64(policy.minPrice), price < min { return tr("The minimum price is \(StellarMomentText.usdc(min)).") }
        if let ceiling = economics.flatMap({ Int64($0.maxPrice) }), price > ceiling {
            return tr("The maximum price is \(StellarMomentText.usdc(ceiling)): the first collect at that price completes the reserve, so a higher price would never be charged.")
        }
        return nil
    }

    /// Why nothing can be published now: v2 Moments aren't on this network, or publishing is paused.
    private var publishBlock: String? {
        guard economicsRead else { return nil }
        guard let economics else {
            return liteTr(LocalizedStringResource("Publishing opens once DyorHQ Moments are live on Stellar.", table: "StellarMoments", comment: "Publish a Moment on Stellar, when the network has no Moments contract yet. DyorHQ and Stellar are never translated"))
        }
        if economics.publishingPaused || economics.guardianPaused {
            return liteTr(LocalizedStringResource("Publishing new Moments is paused.", table: "StellarMoments", comment: "Publish a Moment on Stellar, while DyorHQ has paused publishing"))
        }
        return nil
    }

    private var form: StellarMomentFormV2? {
        guard let ticker, let price else { return nil }
        let day = Self.dayFormatter.string(from: date)
        return StellarMomentFormV2(name: trimmedName, symbol: ticker, place: trimmedPlace.isEmpty ? nil : trimmedPlace, takenOn: day, price: price,
                                   allocationBps: allocationBps, windowSecs: windowDays * 86_400)
    }

    private var valid: Bool {
        !trimmedName.isEmpty && nameProblem == nil && ticker != nil && symbolProblem == nil && !trimmedPlace.isEmpty && placeProblem == nil
            && priceProblem == nil && upload != nil && !uploading && economics != nil && publishBlock == nil && allocationPercent <= maxAllocationPercent
    }

    var body: some View {
        NavigationStack {
            Form {
                pendingPolicySection
                mediaSection
                Section("Moment") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > Self.maxNameBytes { name = String(v.prefix(Self.maxNameBytes)) } }
                    if let nameProblem { InlineError(message: nameProblem) }
                    TextField("Coin ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in
                            let kept = String(v.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
                            if kept != v { symbol = kept }
                        }
                    if let symbolProblem { InlineError(message: symbolProblem) }
                    TextField("Place", text: $place)
                        .onChange(of: place) { _, v in if v.count > Self.maxPlaceBytes { place = String(v.prefix(Self.maxPlaceBytes)) } }
                    if let placeProblem { InlineError(message: placeProblem) }
                    DatePicker("When", selection: $date, in: ...Date(), displayedComponents: [.date])
                }
                economicsSection
                if valid { previewSection }
            }
            .navigationTitle(tr("Publish a Moment"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        Haptics.tap()
                        Task { await review() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!valid || reviewing || session?.canSign != true)
                }
            }
            .task { await readEconomics() }
            .onChange(of: photoItem) { _, item in if let item { Task { await pick(item) } } }
            .sheet(item: $reviewed) { reviewed in reviewSheet(reviewed) }
        }
    }

    // MARK: Sections

    /// A policy change queued on the contract: once it applies, a publish that bound the old terms is refused, nothing
    /// is published, and the creator reviews the new terms. A proposal that lapsed isn't shown.
    @ViewBuilder private var pendingPolicySection: some View {
        if let policy, let pending = economics?.pendingPolicy {
            let state = pending.state(at: Date())
            if state != "lapsed" {
                let applicable = state == "ready"
                Section {
                    Label(applicable ? "New terms can take effect at any moment" : "New terms are queued", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                    Self.pendingNote(applicable: applicable, from: StellarFormat.date(pending.eta).map(MomentsFormat.date) ?? "—",
                                     until: StellarFormat.date(pending.expires).map(MomentsFormat.date))
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.changes(from: policy, to: pending.policy), id: \.self) { field in
                        LabeledContent(Self.title(field), value: Self.change(field, from: policy, to: pending.policy)).font(.footnote)
                    }
                }
            }
        }
    }

    @ViewBuilder private static func pendingNote(applicable: Bool, from: String, until: String?) -> some View {
        switch (applicable, until) {
        case (true, let until?):
            Paragraph("Anyone can apply the queued policy now until \(until). If it's applied before your publish confirms, nothing is published: you review the new terms below and publish again. Your terms never change without you seeing them.")
        case (true, nil):
            Paragraph("Anyone can apply the queued policy now. If it's applied before your publish confirms, nothing is published: you review the new terms below and publish again. Your terms never change without you seeing them.")
        case (false, let until?):
            Paragraph("The queued policy can be applied from \(from) until \(until). If it's applied before your publish confirms, nothing is published and you review the new terms below.")
        case (false, nil):
            Paragraph("The queued policy can be applied from \(from). If it's applied before your publish confirms, nothing is published and you review the new terms below.")
        }
    }

    /// A field of the policy a queued proposal changes.
    enum PolicyField: Hashable, CaseIterable {
        case threshold, minPrice, split, maxCreatorAlloc, royalty, expiryShare, platform, treasury
    }

    /// The fields `next` changes from `now`.
    static func changes(from now: StellarMomentsPolicyV2, to next: StellarMomentsPolicyV2) -> [PolicyField] {
        PolicyField.allCases.filter { field in
            switch field {
            case .threshold: now.threshold != next.threshold
            case .minPrice: now.minPrice != next.minPrice
            case .split: [now.creatorBps, now.platformBps, now.reserveBps] != [next.creatorBps, next.platformBps, next.reserveBps]
            case .maxCreatorAlloc: now.maxCreatorAllocBps != next.maxCreatorAllocBps
            case .royalty: now.royaltyBps != next.royaltyBps
            case .expiryShare: now.expiryCreatorBps != next.expiryCreatorBps
            case .platform: now.platform != next.platform
            case .treasury: now.treasury != next.treasury
            }
        }
    }

    private static func title(_ field: PolicyField) -> LocalizedStringKey {
        switch field {
        case .threshold: return "Graduation reserve"
        case .minPrice: return "Minimum price"
        case .split: return "Split (you · DyorHQ · reserve)"
        case .maxCreatorAlloc: return "Most you can keep"
        case .royalty: return "NFT royalty"
        case .expiryShare: return "Your share on expiry"
        case .platform: return "Platform wallet"
        case .treasury: return "Treasury wallet"
        }
    }

    private static func change(_ field: PolicyField, from now: StellarMomentsPolicyV2, to next: StellarMomentsPolicyV2) -> String {
        func bps(_ value: Int) -> String { NumberStyle.basisPoints(value) }
        func short(_ address: String) -> String { StellarAccountID(address)?.short ?? address }
        switch field {
        case .threshold: return "\(StellarMomentText.usdc(now.threshold)) → \(StellarMomentText.usdc(next.threshold))"
        case .minPrice: return "\(StellarMomentText.usdc(now.minPrice)) → \(StellarMomentText.usdc(next.minPrice))"
        case .split: return "\(bps(now.creatorBps)) · \(bps(now.platformBps)) · \(bps(now.reserveBps)) → \(bps(next.creatorBps)) · \(bps(next.platformBps)) · \(bps(next.reserveBps))"
        case .maxCreatorAlloc: return "\(bps(now.maxCreatorAllocBps)) → \(bps(next.maxCreatorAllocBps))"
        case .royalty: return "\(bps(now.royaltyBps)) → \(bps(next.royaltyBps))"
        case .expiryShare: return "\(bps(now.expiryCreatorBps)) → \(bps(next.expiryCreatorBps))"
        case .platform: return "\(short(now.platform)) → \(short(next.platform))"
        case .treasury: return "\(short(now.treasury)) → \(short(next.treasury))"
        }
    }

    private var mediaSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    if let previewImage {
                        Image(uiImage: previewImage).resizable().scaledToFill()
                    } else {
                        StellarMomentArtwork(image: upload?.imageUrl, name: ticker ?? "?")
                    }
                    if uploading {
                        ZStack { Color.black.opacity(0.35); ProgressView().controlSize(.small).tint(.white) }
                    } else if isVideo, previewImage != nil {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 3)
                    }
                }
                .frame(width: Self.previewSide, height: Self.previewSide)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                        Label(upload == nil ? "Choose Photo or Video" : (isVideo ? "Change Video" : "Change Photo"), systemImage: isVideo ? "video" : "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(uploading)
                    if uploading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }
                    } else if let mediaError {
                        Paragraph(mediaError).font(.caption).foregroundStyle(Color.attention)
                    } else {
                        Text("This becomes the NFT.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Media")
        } footer: {
            if isVideo {
                Paragraph(LocalizedStringResource("The video plays in DyorHQ; its cover frame is the NFT image.", table: "StellarMoments", comment: "Under Publish a Moment's media, for a video. DyorHQ is never translated"))
            } else {
                Paragraph(LocalizedStringResource("Shown in DyorHQ and in Freighter as the NFT.", table: "StellarMoments", comment: "Under Publish a Moment's media, for a photo. DyorHQ and Freighter are never translated"))
            }
        }
    }

    private var economicsSection: some View {
        Section {
            HStack {
                Text("Collect price")
                Spacer()
                TextField("1" as String, text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text(verbatim: "USDC").foregroundStyle(.secondary)
            }
            Stepper(value: $allocationPercent, in: 0...max(0, maxAllocationPercent)) {
                HStack {
                    Text("Your allocation")
                    Spacer()
                    Text(verbatim: NumberStyle.basisPoints(allocationBps)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .disabled(economics == nil)
            Stepper(value: $windowDays, in: windowDaysRange) {
                HStack { Text("Collect window"); Spacer(); Text("\(windowDays) days").monospacedDigit().foregroundStyle(.secondary) }
            }
            LabeledContent {
                Text(verbatim: "Soroswap")
            } label: {
                Text("Graduates on", tableName: "StellarMoments", comment: "A row of Publish a Moment on Stellar: the exchange its coin's pool opens on (Soroswap follows, never translated)")
            }
        } header: {
            Text("Economics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let priceProblem { Paragraph(priceProblem).foregroundStyle(Color.attention) }
                if let economics, let policy, let price, price > 0 {
                    Paragraph("Minimum \(StellarMomentText.usdc(policy.minPrice)). About \(Self.collectsToComplete(policy, price: price)) collects at this price reach the \(StellarMomentText.usdc(policy.threshold)) reserve, and the coin graduates at a \(Self.fdv(economics, allocationBps: allocationBps)) FDV. Up to \(NumberStyle.basisPoints(policy.maxCreatorAllocBps)) of the \(StellarMomentText.units(economics.supply)) coins is yours, vesting 20% at graduation then 16% a month; anything you leave deepens the pool. Collecting ends at graduation or when the window closes (1 to 30 days).")
                } else if let economicsError {
                    Paragraph(economicsError).foregroundStyle(Color.attention)
                } else if !economicsRead {
                    Text("Loading the current policy…")
                }
                if let publishBlock { Paragraph(publishBlock).foregroundStyle(Color.attention) }
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if let economics, let policy, let price {
                let creatorCoins = Self.coins(economics.supply, bps: allocationBps)
                DetailRows {
                    DetailRow("Collect price", StellarMomentText.usdc(price))
                    DetailRow("Graduates at", "\(StellarMomentText.usdc(policy.threshold)) reserve · \(Self.fdv(economics, allocationBps: allocationBps)) FDV")
                    DetailRow("Each collect", "\(NumberStyle.basisPoints(policy.reserveBps)) reserve · \(NumberStyle.basisPoints(policy.creatorBps)) you · \(NumberStyle.basisPoints(policy.platformBps)) DyorHQ")
                    DetailRow("Your coins", verbatim: "\(StellarMomentText.units(creatorCoins)) (\(NumberStyle.basisPoints(allocationBps)))")
                    DetailRow("Collectors + pool", "\(StellarMomentText.units(Self.coins(economics.supply, bps: 10_000 - allocationBps))) at one price")
                    DetailRow("NFT royalty", NumberStyle.basisPoints(policy.royaltyBps))
                    DetailRow("Window closes", MomentsFormat.date(Date().addingTimeInterval(TimeInterval(windowDays * 86_400))))
                    DetailRow("Liquidity", "Locked forever", tint: .positive)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Review

    private func reviewSheet(_ reviewed: Reviewed) -> some View {
        let policy = reviewed.economics.policy
        let form = reviewed.form
        return StellarConfirmationSheet(
            title: "Publish \(form.symbol)", confirmTitle: "Publish",
            build: {
                guard let moments else { throw LiteAPIError.notSignedIn }
                return try await moments.publishPlan(form, media: reviewed.upload, title: tr("Publish"))
            },
            onDone: {
                dismiss()
                if let published { onPublished(published) }
            },
            onCompleted: { results in
                published = Self.listing(results: results, form: form, upload: reviewed.upload)
            },
            check: { action in Self.termsCheck(action.plan, reviewed: reviewed) }
        ) {
            DetailRow("Moment", verbatim: "\(form.name) ($\(form.symbol))")
            DetailRow("Collect price", StellarMomentText.usdc(form.price))
            DetailRow("Graduates at", "\(StellarMomentText.usdc(policy.threshold)) reserve · \(Self.fdv(reviewed.economics, allocationBps: form.allocationBps)) FDV")
            DetailRow("Your coins", verbatim: "\(NumberStyle.basisPoints(form.allocationBps)) · \(StellarMomentText.units(Self.coins(reviewed.economics.supply, bps: form.allocationBps)))")
            DetailRow(Text("Window"), Text("\(form.windowSecs / 86_400) days"))
            DetailRow("Each collect", "\(NumberStyle.basisPoints(policy.creatorBps)) you · \(NumberStyle.basisPoints(policy.platformBps)) DyorHQ · \(NumberStyle.basisPoints(policy.reserveBps)) reserve")
            DetailRow("Minimum price", StellarMomentText.usdc(policy.minPrice))
            DetailRow("Most you can keep", NumberStyle.basisPoints(policy.maxCreatorAllocBps))
            DetailRow("NFT royalty", NumberStyle.basisPoints(policy.royaltyBps))
            DetailRow("If it expires", "\(NumberStyle.basisPoints(policy.expiryCreatorBps)) of the reserve to you, the rest to the treasury")
            DetailRow(Text("Graduates on", tableName: "StellarMoments"), Text(verbatim: "Soroswap"))
            DetailRow("Platform wallet", StellarAccountID(policy.platform)?.short ?? policy.platform)
            DetailRow("Treasury wallet", StellarAccountID(policy.treasury)?.short ?? policy.treasury)
            if let pending = reviewed.economics.pendingPolicy, pending.state(at: Date()) != "lapsed" {
                DetailRow("Policy change", pending.state(at: Date()) == "ready" ? "if applied first, nothing is published" : "queued", tint: Color.attention)
            }
            DetailRow(Text("Media"), reviewed.upload.isVideo
                      ? Text("video + cover frame, stored by DyorHQ", tableName: "StellarMoments", comment: "The Media row of a Stellar Moment's publish review, for a video. DyorHQ is never translated")
                      : Text("photo, stored by DyorHQ", tableName: "StellarMoments", comment: "The Media row of a Stellar Moment's publish review, for a photo. DyorHQ is never translated"))
        }
    }

    /// The review's guard: the terms the built publish binds, against the ones its review read (`MomentsV2Store
    /// .termsChanges`). A mismatch keeps Confirm off and says so; nil when the plan may go. While the publish waits behind
    /// the account's USDC trustline it isn't built yet, and the server builds it with the terms as they stand then.
    static func termsCheck(_ plan: PlanView, reviewed: Reviewed) -> LocalizedStringResource? {
        let changed = MomentsV2Store.termsChanges(plan, terms: reviewed.economics.terms, form: reviewed.form)
        guard let changed, !changed.isEmpty else { return nil }
        return LocalizedStringResource("The Moments terms changed since you started. Review them again.", table: "StellarMoments", comment: "In a Stellar Moment's publish review: the contract's terms differ from the ones the review shows, so Confirm is off")
    }

    /// The new Moment as Publish knows it: its NFT address from the publish's result, with the form's name, ticker,
    /// place and day and its media.
    static func listing(results: [TxStatus], form: StellarMomentFormV2, upload: StellarMomentUploadV2) -> StellarMomentListingV2? {
        guard let nft = MomentsV2Store.publishedNFT(results) else { return nil }
        return StellarMomentListingV2(nft: nft, name: form.name, symbol: form.symbol, image: upload.imageUrl, video: upload.isVideo ? upload.mediaUrl : nil,
                                      place: form.place, takenOn: form.takenOn)
    }

    /// Review: the terms read again, live, so the sheet shows (and binds) the ones that stand now.
    private func review() async {
        guard let form, let upload, let moments else { return }
        reviewing = true
        defer { reviewing = false }
        await readEconomics(with: moments)
        guard let economics, publishBlock == nil, priceProblem == nil else { return }
        reviewed = Reviewed(form: form, economics: economics, upload: upload)
    }

    // MARK: Figures

    /// The collects at `price` that reach the threshold: ceil(T / (price · reserve)).
    static func collectsToComplete(_ policy: StellarMomentsPolicyV2, price: Int64) -> Int {
        guard let threshold = Double(policy.threshold), price > 0, policy.reserveBps > 0 else { return 0 }
        return Int((threshold / (Double(price) * Double(policy.reserveBps) / 10_000)).rounded(.up))
    }

    /// The FDV the coin opens at with `allocationBps`, from the economics' table of allocations (in USDC).
    static func fdv(_ economics: StellarMomentsEconomicsV2, allocationBps: Int) -> String {
        let row = economics.fdvByAllocation.first { $0.allocationBps == allocationBps }?.fdv
            ?? (allocationBps == economics.policy.maxCreatorAllocBps ? economics.fdvAtOpen : nil)
        return row.map(StellarMomentText.usdc) ?? "—"
    }

    /// `bps` of `supply` (coin base units).
    static func coins(_ supply: String, bps: Int) -> String {
        guard let total = Decimal(string: supply) else { return "0" }
        let share = (total * Decimal(bps) / 10_000) as NSDecimalNumber
        return share.rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .down, scale: 0, raiseOnExactness: false,
                                                                          raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).stringValue
    }

    /// The contract stores a name of at most 32 bytes and a place of at most 64.
    static let maxNameBytes = 32
    static let maxPlaceBytes = 64

    /// The day the Moment happened, as the metadata keeps it ("2026-10-14"), in the phone's own calendar day.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Reading and uploading

    private func readEconomics() async {
        guard let moments else { return }
        await readEconomics(with: moments)
    }

    private func readEconomics(with moments: MomentsV2Store) async {
        do {
            economics = try await moments.economics()
            economicsError = nil
            if allocationPercent > maxAllocationPercent { allocationPercent = maxAllocationPercent }
            windowDays = min(max(windowDays, windowDaysRange.lowerBound), windowDaysRange.upperBound)
        } catch {
            if economics == nil { economicsError = LiteErrorText.describe(error) }
        }
        economicsRead = true
    }

    /// A pick replaces the last one: read here (a photo drawn at the Moments' size and quality, off the main thread; a
    /// video checked for size before it is read, with its cover frame), then uploaded to DyorHQ's storage.
    private func pick(_ item: PhotosPickerItem) async {
        uploading = true
        mediaError = nil
        upload = nil
        previewImage = nil
        isVideo = false
        defer {
            uploading = false
            photoItem = nil
        }
        do {
            guard let moments else { throw LiteAPIError.notSignedIn }
            let media: StellarMedia
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: MovieFile.self) else { mediaError = tr("That video could not be read."); return }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                // The size from the file system, before anything is read.
                guard let size = try movie.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= MomentsV2Store.maxVideoBytes else {
                    mediaError = liteTr(LocalizedStringResource("Videos up to 25 MB.", table: "StellarMoments", comment: "Publish a Moment on Stellar: the video picked is larger than the limit"))
                    return
                }
                guard let cover = try await MovieFile.coverFrame(url: movie.url) else { mediaError = tr("Could not read a frame from that video."); return }
                previewImage = cover
                isVideo = true
                guard let poster = cover.avatarJPEG(maxDimension: 2048, quality: 0.9) else { mediaError = tr("Could not read a frame from that video."); return }
                let type = UTType(filenameExtension: movie.url.pathExtension) ?? .quickTimeMovie
                let data = try Data(contentsOf: movie.url)
                media = .video(data, contentType: type.conforms(to: .mpeg4Movie) ? "video/mp4" : "video/quicktime", poster: poster)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let photo = await Task.detached(priority: .userInitiated, operation: { () -> (jpeg: Data, preview: UIImage?)? in
                          guard let jpeg = UIImage(data: data)?.avatarJPEG(maxDimension: CGFloat(MomentsMath.photoMaxPixels), quality: 0.85) else { return nil }
                          return (jpeg, UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 252, height: 252)))
                      }).value else {
                    mediaError = tr("That photo could not be read.")
                    return
                }
                previewImage = photo.preview
                media = .photo(photo.jpeg)
            }
            upload = try await moments.upload(media)
            Haptics.success()
        } catch {
            previewImage = nil
            isVideo = false
            upload = nil
            mediaError = LiteErrorText.describe(error)
        }
    }
}
#endif
