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
/// frame, the NFT's image), or Monad's image and video links, which the phone fetches and uploads the same way (Stellar
/// shows only DyorHQ's own uploads, `LiteMediaPolicy`); the name and coin ticker, where it happened and when (a day and a
/// time, as on Monad), the collect price in USDC, the creator's coin allocation and how long collecting stays open.
/// Everything is fixed at publish. The review is bound to what it shows: the publish carries the Moments terms by value,
/// and the review refuses Confirm when the plan binds terms other than the ones it read (`termsCheck`).
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
    /// Monad's link fields: an image (ipfs:// or https://) and, optionally, a video. Fetched and uploaded as a pick is
    /// (`useLinks`), replacing it; a pick clears them.
    @State private var imageLink = ""
    @State private var videoLink = ""
    /// Why the links couldn't be used: said under the field it is about.
    @State private var linkProblem: LinkProblem?
    /// The media on the form came from the links, not a pick: emptying both links takes it away.
    @State private var fromLinks = false
    /// The form and the terms as they were when Review was tapped, the terms read again then: the sheet shows these and
    /// publishes the form, and Confirm stays off if the plan binds other terms.
    @State private var reviewed: Reviewed?
    /// A review waiting on the account's USDC: enabled first, in its own review, then this one opens (`review()`).
    @State private var enabling: Reviewed?
    /// That review, once USDC is enabled: it opens as the enabling's sheet closes.
    @State private var afterUSDC: Reviewed?
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
        return StellarMomentFormV2(name: trimmedName, symbol: ticker, place: trimmedPlace.isEmpty ? nil : trimmedPlace,
                                   takenOn: StellarMomentFormV2.takenAt(date), price: price, allocationBps: allocationBps,
                                   windowSecs: windowDays * 86_400)
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
                    DatePicker("When", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
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
            // A link typed or pasted is used once the typing pauses; another edit starts over.
            .task(id: LinkPair(image: imageLink, video: videoLink)) { await useLinks(LinkPair(image: imageLink, video: videoLink)) }
            .sheet(item: $reviewed) { reviewed in reviewSheet(reviewed) }
            .sheet(item: $enabling, onDismiss: {
                // USDC is enabled: the publish's own review, whose plan is now the publish alone.
                if let next = afterUSDC { reviewed = next }
                afterUSDC = nil
            }) { next in enableSheet(next) }
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
            TextField("Or paste an image link (ipfs:// or https://)", text: $imageLink)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(uploading && !fromLinks)
            if let problem = linkProblem, problem.field == .image { InlineError(message: problem.message) }
            TextField("Video link (optional)", text: $videoLink)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(uploading && !fromLinks)
            if let problem = linkProblem, problem.field == .video { InlineError(message: problem.message) }
        } header: {
            Text("Media")
        } footer: {
            if !imageLink.isEmpty, StellarMediaLink.sources(imageLink) == nil {
                Paragraph("Use an ipfs:// or https:// link.")
            } else if !videoLink.isEmpty, StellarMediaLink.sources(videoLink) == nil {
                Paragraph("The video link must be ipfs:// or https://.")
            } else if isVideo {
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
                    // The vesting period and the window as the terms bind them (a test deployment's are minutes).
                    let period = StellarMomentText.duration(economics.terms.durations.vestPeriod)
                    let days = windowDaysRange
                    Paragraph(LocalizedStringResource("Minimum \(StellarMomentText.usdc(policy.minPrice)). About \(Self.collectsToComplete(policy, price: price)) collects at this price reach the \(StellarMomentText.usdc(policy.threshold)) reserve, and the coin graduates at a \(Self.fdv(economics, allocationBps: allocationBps)) FDV. Up to \(NumberStyle.basisPoints(policy.maxCreatorAllocBps)) of the \(StellarMomentText.units(economics.supply)) coins is yours, vesting 20% at graduation then 16% every \(period); anything you leave deepens the pool. Collecting ends at graduation or when the window closes (\(String(days.lowerBound)) to \(String(days.upperBound)) days).", table: "StellarMoments", comment: "Under Publish a Moment's economics: %1$@ the minimum price, %2$lld how many collects reach the reserve %3$@, %4$@ the FDV the coin opens at, %5$@ the most the creator keeps of the %6$@ coins, %7$@ the vesting period (“30 days”), %8$@ to %9$@ the collect window's range in days. FDV is never translated"))
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
    /// .termsChanges`). A mismatch keeps Confirm off and says so; nil when the plan may go. A publish the server builds
    /// only after an earlier step can't be compared before it is signed (`MomentsV2Store.publishWaits`): behind the
    /// account's USDC trustline, Confirm stays off and the next Review enables USDC first (`review()`); behind a restore of
    /// archived data, which changes no terms, it goes unless a policy change is queued that could apply first.
    static func termsCheck(_ plan: PlanView, reviewed: Reviewed, now: Date = Date()) -> LocalizedStringResource? {
        if MomentsV2Store.publishWaits(plan) {
            if plan.steps.contains(where: StellarConfirmationSheet<EmptyView>.enables) {
                return LocalizedStringResource("Enable USDC first, then review your Moment again.", table: "StellarMoments", comment: "In a Stellar Moment's publish review, when the account can't hold USDC yet: Confirm is off; closing and tapping Review again enables USDC first. USDC is never translated")
            }
            // The publish is built seconds after the review: a proposal that can be applied now, or within minutes, could
            // come first.
            guard let pending = reviewed.economics.pendingPolicy,
                  [now, now.addingTimeInterval(Self.policyMargin)].contains(where: { pending.state(at: $0) == "ready" }) else { return nil }
            return LocalizedStringResource("A Moments policy change is queued. Publish once it takes effect or lapses.", table: "StellarMoments", comment: "In a Stellar Moment's publish review, when the publish can only be built after another step and a change of the Moments terms is queued: Confirm is off")
        }
        guard !MomentsV2Store.termsChanges(plan, terms: reviewed.economics.terms, form: reviewed.form).isEmpty else { return nil }
        return LocalizedStringResource("The Moments terms changed since you started. Review them again.", table: "StellarMoments", comment: "In a Stellar Moment's publish review: the contract's terms differ from the ones the review shows, so Confirm is off")
    }

    /// USDC enabled first, in its own review, when the account can't hold it yet: a creator's proceeds are paid in USDC,
    /// and the publish is then built at once, so its review can check it against the terms it shows.
    private func enableSheet(_ next: Reviewed) -> some View {
        StellarConfirmationSheet(
            title: LocalizedStringResource("Enable USDC", table: "StellarMoments", comment: "Title of the review that enables USDC on the account before a Moment is published. USDC is never translated"),
            confirmTitle: LocalizedStringResource("Enable", table: "StellarMoments", comment: "The confirm button of the review that enables USDC before a Moment is published"),
            build: {
                guard let moments else { throw LiteAPIError.notSignedIn }
                return try await moments.enableUSDCPlan()
            },
            onDone: {},
            onCompleted: { _ in afterUSDC = next }
        ) {
            DetailRow("Moment", verbatim: "\(next.form.name) ($\(next.form.symbol))")
            Paragraph(LocalizedStringResource("Your Moment's proceeds are paid in USDC, so your account enables it first. Then you review the publish.", table: "StellarMoments", comment: "In the review that enables USDC before a Moment is published: why, and what comes next. USDC is never translated"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The new Moment as Publish knows it: its NFT address from the publish's result, with the form's name, ticker,
    /// place and day and its media.
    static func listing(results: [TxStatus], form: StellarMomentFormV2, upload: StellarMomentUploadV2) -> StellarMomentListingV2? {
        guard let nft = MomentsV2Store.publishedNFT(results) else { return nil }
        return StellarMomentListingV2(nft: nft, name: form.name, symbol: form.symbol, image: upload.imageUrl, video: upload.isVideo ? upload.mediaUrl : nil,
                                      place: form.place, takenOn: form.takenOn)
    }

    /// Review: the terms read again, live, so the sheet shows (and binds) the ones that stand now; an account that can't
    /// hold USDC yet enables it first (`enableSheet`).
    private func review() async {
        guard let form, let upload, let moments else { return }
        reviewing = true
        defer { reviewing = false }
        await readEconomics(with: moments)
        guard let economics, publishBlock == nil, priceProblem == nil else { return }
        let next = Reviewed(form: form, economics: economics, upload: upload)
        if await moments.needsUSDC() { enabling = next } else { reviewed = next }
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

    /// How soon a queued policy change counts as able to apply before a publish built after an earlier step (`termsCheck`).
    static let policyMargin: TimeInterval = 10 * 60

    /// The contract stores a name of at most 32 bytes and a place of at most 64.
    static let maxNameBytes = 32
    static let maxPlaceBytes = 64

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
        // A pick replaces the links' media: they go, and emptying them takes nothing away.
        fromLinks = false
        linkProblem = nil
        imageLink = ""
        videoLink = ""
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

    // MARK: Links

    /// The two link fields, as one value: a change of either uses them again.
    struct LinkPair: Equatable {
        let image: String
        let video: String
    }

    /// A link that couldn't be used, and the field it is under.
    struct LinkProblem: Equatable {
        enum Field { case image, video }
        let field: Field
        let message: String
    }

    /// The links as the media: fetched by the phone (`StellarMediaLink`, under the caps a picked photo or video has), then
    /// uploaded to DyorHQ's storage like a pick. An image alone is a photo; a video takes the image as its cover frame,
    /// else its own first frames. A link that isn't ipfs:// or https:// waits (the footer says so); emptying both takes
    /// the links' media away. Runs once the typing has paused, and stops with the next edit.
    private func useLinks(_ links: LinkPair) async {
        let image = links.image.trimmingCharacters(in: .whitespacesAndNewlines)
        let video = links.video.trimmingCharacters(in: .whitespacesAndNewlines)
        linkProblem = nil
        // Edited links no longer name the media they brought (whose fetch this edit may have cut short): it goes.
        if fromLinks {
            upload = nil
            previewImage = nil
            isVideo = false
            uploading = false
            mediaError = nil
            fromLinks = false
        }
        guard !image.isEmpty || !video.isEmpty else { return }
        let imageSources = image.isEmpty ? [] : StellarMediaLink.sources(image)
        let videoSources = video.isEmpty ? [] : StellarMediaLink.sources(video)
        guard let imageSources, let videoSources else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, let moments, !uploading else { return }
        uploading = true
        fromLinks = true
        mediaError = nil
        upload = nil
        previewImage = nil
        isVideo = false
        defer { if !Task.isCancelled { uploading = false } }
        do {
            var photo: (jpeg: Data, preview: UIImage?)?
            if !imageSources.isEmpty {
                do {
                    photo = try await StellarMediaLink.photo(from: imageSources)
                } catch {
                    if !Task.isCancelled { linkProblem = LinkProblem(field: .image, message: StellarMediaLink.problem(error, video: false)) }
                    return
                }
            }
            var media: StellarMedia
            if !videoSources.isEmpty {
                let clip: StellarMediaLink.Clip
                do {
                    clip = try await StellarMediaLink.video(from: videoSources)
                } catch {
                    if !Task.isCancelled { linkProblem = LinkProblem(field: .video, message: StellarMediaLink.problem(error, video: true)) }
                    return
                }
                guard let poster = photo?.jpeg ?? clip.cover else {
                    linkProblem = LinkProblem(field: .video, message: tr("Could not read a frame from that video."))
                    return
                }
                previewImage = photo?.preview ?? clip.preview
                isVideo = true
                media = .video(clip.data, contentType: clip.contentType, poster: poster)
            } else {
                guard let photo else { return }
                previewImage = photo.preview
                media = .photo(photo.jpeg)
            }
            guard !Task.isCancelled else { return }
            let uploaded = try await moments.upload(media)
            guard !Task.isCancelled else { return }
            upload = uploaded
            Haptics.success()
        } catch {
            guard !Task.isCancelled else { return }
            previewImage = nil
            isVideo = false
            upload = nil
            mediaError = LiteErrorText.describe(error)
        }
    }
}

/// Monad's media links on Stellar, where a Moment shows only DyorHQ's own uploads (`LiteMediaPolicy`): the phone fetches
/// what a link names (an ipfs:// CID through the app's IPFS gateways, an https link as it is) with DyorKit's capped
/// fetch (`RemoteMedia`: no cookies, no redirect to another host, the body cut off at the cap), checks that it is an image
/// or a video, and Publish uploads it like a picked file. The caps are a picked file's: a photo is read up to
/// `RemoteMedia.maxImageBytes` and within its pixel caps and drawn at the Moments' size and quality; a video is at most
/// `MomentsV2Store.maxVideoBytes`.
enum StellarMediaLink {
    /// A fetched video, its type read from its bytes, with its cover frame (a JPEG) and a preview of it.
    struct Clip {
        let data: Data
        let contentType: String
        let cover: Data?
        let preview: UIImage?
    }

    /// What a fetched link turned out not to be.
    enum Failure: Error, Equatable {
        case notAVideo
    }

    /// Where a pasted link is fetched from, best first: an `ipfs://` link with a real CID through each of the app's
    /// gateways (`MomentsMath.ipfsGateways`), an https link with a host and no user name as it is; nil for anything else
    /// (http, another scheme, a link longer than any picture's address).
    static func sources(_ text: String) -> [URL]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= ImageSourcePolicy.maxURLBytes else { return nil }
        if trimmed.lowercased().hasPrefix("ipfs://") {
            guard let path = IPFS.path(trimmed), IPFS.isCID(IPFS.cid(of: path)) else { return nil }
            let urls = MomentsMath.ipfsGateways.compactMap { URL(string: $0 + path) }
            return urls.isEmpty ? nil : urls
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return [url]
    }

    /// The image a link names, as Publish uploads a picked photo: decoded within `RemoteMedia`'s caps (an HTML page or an
    /// SVG is no image), at most `MomentsMath.photoMaxPixels` across, as a JPEG at the Moments' quality; with a small
    /// preview.
    static func photo(from sources: [URL]) async throws -> (jpeg: Data, preview: UIImage?) {
        let data = try await fetch(sources, maxBytes: RemoteMedia.maxImageBytes)
        return try await Task.detached(priority: .userInitiated) {
            let image = try UIImage(cgImage: RemoteMedia.thumbnail(data, maxPixelSize: MomentsMath.photoMaxPixels))
            guard let jpeg = image.avatarJPEG(maxDimension: CGFloat(MomentsMath.photoMaxPixels), quality: 0.85) else { throw RemoteMedia.Failure.notAnImage }
            return (jpeg, UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 252, height: 252)))
        }.value
    }

    /// The video a link names, at most `MomentsV2Store.maxVideoBytes`: an MP4 or QuickTime movie by its bytes
    /// (`videoType`), with the frame Publish takes for a picked video's cover.
    static func video(from sources: [URL]) async throws -> Clip {
        let data = try await fetch(sources, maxBytes: MomentsV2Store.maxVideoBytes)
        guard let type = videoType(data) else { throw Failure.notAVideo }
        let file = URL.temporaryDirectory.appending(path: "moment-link-\(UUID().uuidString).\(type == "video/quicktime" ? "mov" : "mp4")")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let frame = try? await MovieFile.coverFrame(url: file) else { throw Failure.notAVideo }
        return Clip(data: data, contentType: type, cover: frame.avatarJPEG(maxDimension: 2048, quality: 0.9), preview: frame)
    }

    /// The video type of `data` from its first bytes: an ISO media file (its `ftyp` box), QuickTime's brand "qt  " as
    /// video/quicktime and any other as video/mp4; nil for anything else.
    static func videoType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12, head[4...7].elementsEqual("ftyp".utf8) else { return nil }
        return head[8...11].elementsEqual("qt  ".utf8) ? "video/quicktime" : "video/mp4"
    }

    /// The link's body from the first source that answers, read at most `maxBytes` (a larger one is refused at once).
    private static func fetch(_ sources: [URL], maxBytes: Int) async throws -> Data {
        let session = RemoteMedia.makeSession(requestTimeout: 15, resourceTimeout: RemoteMedia.trustedResourceTimeout, storesResponses: false)
        defer { session.finishTasksAndInvalidate() }
        var failure: Error = RemoteMedia.Failure.status(404)
        for url in sources {
            do {
                return try await RemoteMedia.fetch(url, session: session, maxBytes: maxBytes)
            } catch RemoteMedia.Failure.tooLarge {
                throw RemoteMedia.Failure.tooLarge
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    /// What Publish says under a link that couldn't be used.
    static func problem(_ error: Error, video: Bool) -> String {
        switch error {
        case RemoteMedia.Failure.tooLarge:
            return video ? liteTr(LocalizedStringResource("Videos up to 25 MB.", table: "StellarMoments"))
                : liteTr(LocalizedStringResource("Images up to 10 MB.", table: "StellarMoments", comment: "Under the image link field of Publish a Moment on Stellar: the image the link names is larger than the limit"))
        case RemoteMedia.Failure.notAnImage, RemoteMedia.Failure.tooManyPixels:
            return liteTr(LocalizedStringResource("That link isn't an image DyorHQ can use.", table: "StellarMoments", comment: "Under the image link field of Publish a Moment on Stellar: what the link names isn't a photo (a web page, an SVG) or is too large to draw. DyorHQ is never translated"))
        case Failure.notAVideo:
            return liteTr(LocalizedStringResource("That link isn't an MP4 or MOV video.", table: "StellarMoments", comment: "Under the video link field of Publish a Moment on Stellar: what the link names isn't a video the app can play. MP4 and MOV are file types, never translated"))
        default:
            return liteTr(LocalizedStringResource("That link couldn't be fetched. Check it, or choose the file instead.", table: "StellarMoments", comment: "Under a link field of Publish a Moment on Stellar: the phone couldn't download what the link names"))
        }
    }
}
#endif
