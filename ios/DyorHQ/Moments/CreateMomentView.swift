import AVFoundation
import BigInt
import DyorKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Publish a Moment: the photo (uploaded to DyorHQ's media bucket and fingerprinted with keccak-256 on-chain, or a
/// link you already host), the name and coin ticker, where and when it happened, the collect price, your coin
/// allocation and how long collecting stays open. Everything is fixed at publish; the preview shows the economics
/// exactly as the contract will apply them. The review is bound to what it shows: the publish carries the terms hash read
/// with the terms on screen, so if they change before it confirms the factory refuses it and nothing is published.
struct CreateMomentView: View {
    /// The live policy, as the Moments board last read it: under a minute and a half old while the board polls (every
    /// 20 s, terms shared for a minute, `ChainCache.TTL.terms`). A publish is bound to the terms its review shows
    /// (`reviewedPolicy`), never to this.
    let policy: MomentPolicy?
    /// Called after the publish transaction settles; the new Moment is passed when it could be resolved.
    let onPublished: (MomentInfo?) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var place = ""
    @State private var date = Date()
    @State private var mediaURI = ""
    @State private var mediaHash: Data?
    @State private var animationURI = ""
    @State private var priceText = "1"
    @State private var allocPercentText = "10"
    @State private var windowDays = 30
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var imageError: String?
    @State private var isVideo = false
    /// A fast https mirror of the picked media for the create-screen preview; the on-chain URI is the ipfs:// CID.
    @State private var mediaMirror = ""
    /// The locally picked photo (or a video's poster frame), shown as the preview immediately — an IPFS gateway can
    /// take a while to serve a freshly pinned CID, so we never wait on the network to show the user their own media.
    @State private var previewImage: UIImage?
    /// The preview's side, in points: a picked photo's preview is decoded for it (off the main thread), not at full size.
    private static let previewSide: CGFloat = 84
    /// The `mediaURI` value the picker upload itself set. The "invalidate on edit" onChange compares against it so the
    /// picker's own write (mediaURI → the pinned ipfs:// CID) is never mistaken for a manual edit and doesn't wipe the
    /// upload's fingerprint / mirror / preview.
    @State private var lastUploadedURI = ""
    /// Uploaded media whose pin to IPFS failed: publishing waits for a retry, or (a photo) the user's choice of the https
    /// copy (RI-9).
    @State private var unpinned: MediaPins?
    /// The photo goes on-chain as DyorHQ's https copy, by the user's choice, because it could not be pinned.
    @State private var usesMirror = false
    @State private var showConfirm = false
    /// The terms and the form as they were when Review was tapped. The sheet shows these and publishes exactly these (the
    /// hash in the transaction is `reviewedPolicy.termsHash`), never the live `policy`, which can refresh under it.
    @State private var reviewedPolicy: MomentPolicy?
    @State private var reviewedInput: MomentPublishInput?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    private var price: BigUInt? { Amount.parse(priceText, decimals: MomentsConstants.usdcDecimals) }
    private var allocBps: Int? {
        guard let percent = Double(allocPercentText.replacingOccurrences(of: ",", with: ".")), percent >= 0 else { return nil }
        return Int((percent * 100).rounded())
    }
    private var maxAllocBps: Int { min(policy?.maxCreatorAllocBps ?? MomentsConstants.maxCreatorAllocBps, MomentsConstants.maxCreatorAllocBps) }
    private var mediaValid: Bool {
        let uri = mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uri.hasPrefix("ipfs://") || uri.hasPrefix("https://")
    }
    private var animationValid: Bool {
        let uri = animationURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return uri.isEmpty || uri.hasPrefix("ipfs://") || uri.hasPrefix("https://")
    }
    private var priceProblem: String? {
        guard let price, price > 0 else { return tr("Enter a collect price in USDC.") }
        if let policy, price < policy.minPrice { return tr("The minimum price is \(MomentsFormat.usdc(policy.minPrice)).") }
        // Above the gross that completes the reserve the first collect is charged only that gross.
        if let policy, let ceiling = MomentsMath.maxCollectPrice(threshold: policy.threshold, reserveBps: policy.reserveBps), price > ceiling {
            return tr("The maximum price is \(MomentsFormat.usdc(ceiling)): the first collect at that price completes the reserve, so a higher price would never be charged.")
        }
        return nil
    }
    private var allocProblem: String? {
        guard let allocBps else { return tr("Enter your allocation as a percentage.") }
        if allocBps > maxAllocBps { return tr("At most \(NumberStyle.basisPoints(maxAllocBps)) of the supply.") }
        return nil
    }
    /// Why this name or ticker can't be published (`SymbolSafety.createRefusal`), as the launch form says it: said under its
    /// field, and Review stays off.
    private var refusal: SymbolSafety.CreateRefusal? {
        SymbolSafety.createRefusal(name: trimmedName, symbol: symbol, maxName: SymbolSafety.maxMomentNameLength)
    }
    private var valid: Bool {
        trimmedName.count >= 2 && trimmedName.count <= 48 && symbolValid && refusal == nil && !place.trimmingCharacters(in: .whitespaces).isEmpty && place.count <= 64
            && mediaValid && animationValid && priceProblem == nil && allocProblem == nil && !uploading && policy?.canPublish == true
    }

    /// The provenance hash: the uploaded bytes' keccak-256 when a photo was chosen, else the hash of the link itself.
    private var effectiveMediaHash: Data {
        mediaHash ?? Keccak.hash256(Data(mediaURI.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    private var input: MomentPublishInput? {
        guard valid, let price, let allocBps else { return nil }
        return MomentPublishInput(
            name: trimmedName, symbol: symbol, mediaURI: mediaURI.trimmingCharacters(in: .whitespacesAndNewlines), mediaHash: effectiveMediaHash,
            animationURI: animationURI.trimmingCharacters(in: .whitespacesAndNewlines), place: place.trimmingCharacters(in: .whitespaces), date: Int(date.timeIntervalSince1970),
            price: price, creatorAllocBps: allocBps, collectWindow: windowDays * 86_400
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                pendingPolicySection
                mediaSection
                Section("Moment") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > 48 { name = String(v.prefix(48)) } }
                    if let refusal, !refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    TextField("Coin ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    if let refusal, refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    TextField("Place", text: $place)
                        .onChange(of: place) { _, v in if v.count > 64 { place = String(v.prefix(64)) } }
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
                        // Snapshot what the sheet shows and publishes; the live policy may refresh while it is open.
                        reviewedPolicy = policy
                        reviewedInput = input
                        showConfirm = true
                    }
                    .fontWeight(.semibold).disabled(!valid || !session.canSign)
                }
            }
            .sheet(isPresented: $showConfirm) {
                if let input = reviewedInput, let policy = reviewedPolicy {
                    ConfirmationSheet(
                        title: "Publish \(input.symbol)", confirmTitle: "Publish",
                        // The reviewed terms' hash, never a fresh read: if the terms changed since, the factory refuses the
                        // publish (TermsChanged) before anything is signed, and the creator reviews again.
                        build: { try await env.moments.publishPlan(input, termsHash: policy.termsHash) },
                        onDone: { dismiss(); onPublished(nil) },
                        onCompleted: { hash in
                            // Recorded in the language in use; `section` is an identifier, never translated.
                            Activity.record(ActivityRecord(kind: .moment, title: tr("Published \(input.name)"), subtitle: tr("$\(input.symbol) · \(MomentsFormat.usdc(input.price)) per edition"), hash: hash, section: "moments"), owner: session.address)
                            // The new coin's picture and DyorHQ label, without waiting for the next 5-minute read.
                            Task { [coins = env.dyorCoins] in await coins.refresh() }
                            Task {
                                // Resolve the new Moment from the receipt and open it.
                                guard let result = (try? await env.moments.publishResult(transaction: hash)) ?? nil,
                                      let info = (try? await env.moments.info(id: result.momentId)) ?? nil else { return }
                                onPublished(info)
                            }
                        },
                        intent: .alwaysAsks(.launch)
                    ) {
                        let days = input.collectWindow / 86_400
                        DetailRow("Moment", verbatim: "\(input.name) ($\(input.symbol))")
                        DetailRow("Collect price", MomentsFormat.usdc(input.price))
                        DetailRow("Graduates at", "\(MomentsFormat.usdcCents(policy.threshold)) reserve · \(MomentsFormat.fdv(MomentsMath.graduationFDV(threshold: policy.threshold, reserveBps: policy.reserveBps, creatorAllocBps: input.creatorAllocBps))) FDV")
                        DetailRow("Your coins", verbatim: "\(NumberStyle.basisPoints(input.creatorAllocBps)) · \(MomentsFormat.coins(MomentsConstants.supply * BigUInt(input.creatorAllocBps) / BigUInt(MomentsConstants.bps)))")
                        DetailRow(Text("Window", comment: "Review row: how long collecting stays open (a time window, not a screen)"), Text("\(days) days"))
                        // Every term the publish's terms hash binds, as read with it.
                        DetailRow("Each collect", "\(NumberStyle.basisPoints(policy.creatorBps)) you · \(NumberStyle.basisPoints(policy.platformBps)) DyorHQ · \(NumberStyle.basisPoints(policy.reserveBps)) reserve")
                        DetailRow("Minimum price", MomentsFormat.usdc(policy.minPrice))
                        DetailRow("Most you can keep", NumberStyle.basisPoints(policy.maxCreatorAllocBps))
                        DetailRow("NFT royalty", NumberStyle.basisPoints(policy.royaltyBps))
                        DetailRow("If it expires", "\(NumberStyle.basisPoints(policy.expiryCreatorBps)) of the reserve to you, the rest to the treasury")
                        DetailRow("Platform wallet", policy.platform.short)
                        DetailRow("Treasury wallet", policy.treasury.short)
                        DetailRow("Link", policy.externalBaseURI.replacingOccurrences(of: "https://", with: "") + "<id>") // not localized: a link pattern
                        if let pending = policy.pending, !pending.hasLapsed(at: Date()) {
                            DetailRow("Policy change", pending.isApplicable(at: Date()) ? "if applied first, nothing is published" : "queued", tint: Color.attention)
                        }
                        DetailRow("Media", mediaHash == nil ? "link, hashed" : usesMirror ? "photo, fingerprinted · DyorHQ link, not IPFS" : (isVideo ? "video, fingerprinted · IPFS" : "photo, fingerprinted · IPFS"))
                    }
                }
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await upload(item) } } }
        }
    }

    // MARK: Sections

    /// A policy change queued on the contract (security audit 2026-09-26, MO-4). Once it can be applied, anyone may
    /// apply it at any moment. The publish carries the hash of the terms reviewed here, so if the new terms take effect
    /// before it confirms, the factory refuses it: nothing is published, and the creator reviews the new terms. They
    /// never change silently. A proposal nobody applied in time has lapsed and is not shown.
    @ViewBuilder private var pendingPolicySection: some View {
        if let policy, let pending = policy.pending, !pending.hasLapsed(at: Date()) {
            let applicable = pending.isApplicable(at: Date())
            Section {
                Label(applicable ? "New terms can take effect at any moment" : "New terms are queued", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                Self.pendingNote(applicable: applicable, from: MomentsFormat.date(pending.applicableAt), until: pending.lapsesAt.map(MomentsFormat.date))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(pending.changes(from: policy), id: \.self) { field in
                    LabeledContent(Self.title(field), value: Self.change(field, from: policy, to: pending)).font(.footnote)
                }
            }
        }
    }

    /// When the queued policy can be applied, and until when (a proposal that can lapse), each as one sentence.
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

    private static func title(_ field: PendingMomentPolicy.Field) -> LocalizedStringKey {
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

    private static func change(_ field: PendingMomentPolicy.Field, from now: MomentPolicy, to next: PendingMomentPolicy) -> String {
        func bps(_ value: Int) -> String { NumberStyle.basisPoints(value) }
        switch field {
        // Exact, unlike the other threshold rows: a change under a cent still reads as a change.
        case .threshold: return "\(MomentsFormat.usdc(now.threshold)) → \(MomentsFormat.usdc(next.threshold))"
        case .minPrice: return "\(MomentsFormat.usdc(now.minPrice)) → \(MomentsFormat.usdc(next.minPrice))"
        case .split: return "\(bps(now.creatorBps)) · \(bps(now.platformBps)) · \(bps(now.reserveBps)) → \(bps(next.creatorBps)) · \(bps(next.platformBps)) · \(bps(next.reserveBps))"
        case .maxCreatorAlloc: return "\(bps(now.maxCreatorAllocBps)) → \(bps(next.maxCreatorAllocBps))"
        case .royalty: return "\(bps(now.royaltyBps)) → \(bps(next.royaltyBps))"
        case .expiryShare: return "\(bps(now.expiryCreatorBps)) → \(bps(next.expiryCreatorBps))"
        case .platform: return "\(now.platform.short) → \(next.platform.short)"
        case .treasury: return "\(now.treasury.short) → \(next.treasury.short)"
        }
    }

    private var mediaSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    if let previewImage {
                        Image(uiImage: previewImage).resizable().scaledToFill()
                    } else {
                        MomentArtwork(provenance: MomentProvenance(mediaURI: mediaMirror.isEmpty ? mediaURI : mediaMirror, mediaHash: Data(), place: "", date: 0, animationURI: ""), symbol: symbol.isEmpty ? "?" : symbol)
                    }
                    if uploading {
                        ZStack { Color.black.opacity(0.35); ProgressView().controlSize(.small).tint(.white) }
                    } else if isVideo, previewImage != nil {
                        Image(systemName: "play.circle.fill")
                            .font(.title2).foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                }
                .frame(width: Self.previewSide, height: Self.previewSide)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                        Label(mediaHash == nil ? "Choose Photo or Video" : (isVideo ? "Change Video" : "Change Photo"), systemImage: isVideo ? "video" : "photo").font(.subheadline.weight(.medium))
                    }
                    .disabled(uploading)
                    if uploading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(unpinned == nil && mediaHash == nil ? "Uploading…" : "Pinning to IPFS…").font(.caption).foregroundStyle(.secondary) }
                    } else if unpinned != nil {
                        Text("Not pinned to IPFS yet.").font(.caption).foregroundStyle(Color.attention)
                    } else if let imageError {
                        Paragraph(imageError).font(.caption).foregroundStyle(Color.attention)
                    } else if let mediaHash {
                        Paragraph("Fingerprint \(String(mediaHash.hexString.prefix(12)))… goes on-chain.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This becomes the NFT.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            if let unpinned, !uploading { unpinnedRow(unpinned) }
            TextField("Or paste an image link (ipfs:// or https://)", text: $mediaURI)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: mediaURI) { old, new in
                    if new == lastUploadedURI { return } // the picker set this URI — keep its upload, don't treat as an edit
                    if old != new, mediaHash != nil { mediaHash = nil; isVideo = false; mediaMirror = ""; previewImage = nil; unpinned = nil; usesMirror = false }
                }
            TextField("Video link (optional)", text: $animationURI)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
            Text("Media")
        } footer: {
            if !mediaURI.isEmpty, !mediaValid { Paragraph("Use an ipfs:// or https:// link.") }
            else if !animationValid { Paragraph("The video link must be ipfs:// or https://.") }
            else if isVideo { Paragraph("The video plays on OpenSea; its cover frame is the NFT image.") }
            else { Paragraph("Shown on OpenSea and in DyorHQ as the NFT.") }
        }
    }

    /// A pin that failed, said before anything is published: a Moment's media link is permanent once on-chain.
    private func unpinnedRow(_ pins: MediaPins) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't pin to IPFS", systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
            if let failure = pins.failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            Text(pins.video == nil
                 ? "Your photo is uploaded, but not on IPFS, where a Moment's media stays available without DyorHQ. Try again, or publish with DyorHQ's link to it instead: that link is permanent on-chain, and DyorHQ only shows it while it still matches your photo's fingerprint."
                 : "Your video is uploaded, but a video Moment needs both the video and its cover frame on IPFS before it can be published. Try again in a minute.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Try Again") { Task { await retryPin() } }.buttonStyle(.borderless).fontWeight(.semibold)
                if pins.video == nil { Button("Use DyorHQ's Link") { useMirror() }.buttonStyle(.borderless) }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private var economicsSection: some View {
        Section {
            HStack {
                Text("Collect price")
                Spacer()
                TextField("1" as String, text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text(verbatim: "USDC").foregroundStyle(.secondary) // not localized: a token symbol
            }
            HStack {
                Text("Your allocation")
                Spacer()
                TextField("10" as String, text: $allocPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 110)
                Text(verbatim: "%").foregroundStyle(.secondary)
            }
            Stepper(value: $windowDays, in: 1...30) {
                HStack { Text("Collect window"); Spacer(); Text("\(windowDays) days").monospacedDigit().foregroundStyle(.secondary) }
            }
        } header: {
            Text("Economics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let priceProblem { Paragraph(priceProblem).foregroundStyle(Color.attention) }
                if let allocProblem { Paragraph(allocProblem).foregroundStyle(Color.attention) }
                if let policy, let price, price > 0 {
                    let reservePerCollect = price * BigUInt(policy.reserveBps) / BigUInt(MomentsConstants.bps)
                    let collects = Int(clamping: reservePerCollect > 0 ? (policy.threshold + reservePerCollect - 1) / reservePerCollect : 0)
                    let fdv = MomentsMath.graduationFDV(threshold: policy.threshold, reserveBps: policy.reserveBps, creatorAllocBps: allocBps ?? maxAllocBps)
                    Paragraph("Minimum \(MomentsFormat.usdc(policy.minPrice)). About \(collects) collects at this price reach the \(MomentsFormat.usdcCents(policy.threshold)) reserve, and the coin graduates at a \(MomentsFormat.fdv(fdv)) FDV. Up to \(NumberStyle.basisPoints(maxAllocBps)) of the \(MomentsFormat.coins(MomentsConstants.supply)) coins is yours, vesting 20% at graduation then 16% a month; anything you leave deepens the pool. Collecting ends at graduation or when the window closes (1 to 30 days).")
                } else if policy == nil {
                    Text("Loading the current policy…")
                }
                if let block = policy?.publishBlock { Paragraph(block.message).foregroundStyle(Color.attention) }
                LearnMoreLink(.publishAMoment)
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            if let policy, let price, let allocBps {
                let creatorCoins = MomentsConstants.supply * BigUInt(allocBps) / BigUInt(MomentsConstants.bps)
                DetailRows {
                    DetailRow("Collect price", MomentsFormat.usdc(price))
                    DetailRow("Graduates at", "\(MomentsFormat.usdcCents(policy.threshold)) reserve · \(MomentsFormat.fdv(MomentsMath.graduationFDV(threshold: policy.threshold, reserveBps: policy.reserveBps, creatorAllocBps: allocBps))) FDV")
                    DetailRow("Each collect", "\(NumberStyle.basisPoints(policy.reserveBps)) reserve · \(NumberStyle.basisPoints(policy.creatorBps)) you · \(NumberStyle.basisPoints(policy.platformBps)) DyorHQ")
                    DetailRow("Your coins", verbatim: "\(MomentsFormat.coins(creatorCoins)) (\(NumberStyle.basisPoints(allocBps)))")
                    DetailRow("Collectors + pool", "\(MomentsFormat.coins(MomentsConstants.supply - creatorCoins)) at one price")
                    DetailRow("NFT royalty", NumberStyle.basisPoints(policy.royaltyBps))
                    DetailRow("Trading fee after graduation", "1.5% (0.2% to you)")
                    DetailRow("Window closes", MomentsFormat.date(Date().addingTimeInterval(TimeInterval(windowDays * 86_400))))
                    DetailRow("Liquidity", "Locked forever", tint: .positive)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Upload

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true; imageError = nil
        defer { uploading = false; photoItem = nil }
        // A new pick replaces the last one, pinned or not — its preview too, so a pick that then fails to read never
        // leaves the old photo (or a video's play badge) standing in for media the form no longer has. `lastUploadedURI`
        // goes first, so clearing the link below is not read as a manual edit.
        lastUploadedURI = ""; mediaURI = ""; animationURI = ""; mediaHash = nil; mediaMirror = ""; unpinned = nil; usesMirror = false
        previewImage = nil; isVideo = false
        do {
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { imageError = tr("Connect DyorHQ Social to upload a photo, or paste a link instead."); return }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                // A video: the file itself is the NFT's animation and is fingerprinted; a frame from it is the image.
                guard let movie = try await item.loadTransferable(type: MovieFile.self) else { imageError = tr("That video could not be read."); return }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                // The size comes from the file system, before anything is read: a long 4K clip is gigabytes, and
                // reading it just to refuse it would exhaust memory (security audit 2026-09-26, RI-5). The file is then
                // hashed a chunk at a time and uploaded straight from disk.
                guard let size = try movie.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 50 * 1024 * 1024 else { imageError = tr("Videos up to 50 MB."); return }
                guard let posterImage = try await MovieFile.coverFrame(url: movie.url) else { imageError = tr("Could not read a frame from that video."); return }
                previewImage = posterImage; isVideo = true // show the video's poster frame immediately, before the pin
                guard let poster = posterImage.avatarJPEG(maxDimension: 2048, quality: 0.9) else { imageError = tr("Could not read a frame from that video."); return }
                let type = UTType(filenameExtension: movie.url.pathExtension) ?? .quickTimeMovie
                let isMP4 = type.conforms(to: .mpeg4Movie)
                // The video's hash is the provenance hash; its poster is filed under that same hash so the app can
                // find the poster mirror again from on-chain data (MomentsMath.mirrorURL).
                let movieURL = movie.url
                let videoHash = try await Task.detached(priority: .userInitiated) { try Keccak.hash256(file: movieURL) }.value
                let posterUpload = try await social.uploadMomentMedia(poster, contentType: "image/jpeg", fileExtension: "jpg", name: MomentsMath.mediaName(hash: videoHash))
                let videoUpload = try await social.uploadMomentMedia(file: movie.url, hash: videoHash, contentType: isMP4 ? "video/mp4" : "video/quicktime", fileExtension: isMP4 ? "mp4" : "mov")
                mediaMirror = posterUpload.mirror.absoluteString
                mediaHash = videoHash
                await pin(MediaPins(image: posterUpload, video: videoUpload))
            } else {
                // The photo is encoded once, here, at `MomentsMath.photoMaxPixels` and `photoJPEGQuality`, and these bytes
                // are the Moment's provenance file: their keccak-256 goes on chain, names the mirror and is what gets
                // pinned. Decoding the pick, drawing it at that size, encoding and hashing it — and the form's small preview
                // of the very bytes that will be published — all run off the main thread, so the form never stalls.
                let previewBucket = ImageSizeBucket.bucket(points: Self.previewSide)
                guard let data = try await item.loadTransferable(type: Data.self),
                      let photo = await Task.detached(priority: .userInitiated, operation: { () -> (jpeg: Data, hash: Data, preview: CGImage?)? in
                          guard let jpeg = UIImage(data: data)?.avatarJPEG(maxDimension: CGFloat(MomentsMath.photoMaxPixels), quality: CGFloat(MomentsMath.photoJPEGQuality)),
                                let size = try? RemoteMedia.inspect(jpeg) else { return nil }
                          let preview = try? RemoteMedia.thumbnail(jpeg, maxPixelSize: ImageSizeBucket.coverPixelSize(bucket: previewBucket, width: size.width, height: size.height))
                          return (jpeg, Keccak.hash256(jpeg), preview)
                      }).value else {
                    imageError = tr("That photo could not be read.")
                    return
                }
                previewImage = photo.preview.map { UIImage(cgImage: $0) }; isVideo = false // show the photo as it will be published, before the pin returns
                let photoUpload = try await social.uploadMomentMedia(photo.jpeg, contentType: "image/jpeg", fileExtension: "jpg", name: MomentsMath.mediaName(hash: photo.hash))
                mediaMirror = photoUpload.mirror.absoluteString
                mediaHash = photo.hash
                await pin(MediaPins(image: photoUpload, video: nil))
            }
            if unpinned == nil { Haptics.success() }
        } catch {
            previewImage = nil; isVideo = false; mediaHash = nil; mediaMirror = ""
            imageError = describe(error)
        }
    }

    /// Pins whatever of `pins` isn't pinned yet. The form takes the media only once all of it is on IPFS; a failure
    /// is kept in `unpinned`, with the reason, for the user to retry — nothing falls back to the https mirror on its
    /// own (security audit 2026-09-26, RI-9).
    private func pin(_ pins: MediaPins) async {
        var pins = pins
        do {
            if pins.imageURI == nil { pins.imageURI = try await social.pinMomentMedia(pins.image) }
            if let video = pins.video, pins.videoURI == nil { pins.videoURI = try await social.pinMomentMedia(video) }
        } catch {
            pins.failure = describe(error)
            unpinned = pins
            Haptics.warning()
            return
        }
        guard let imageURI = pins.imageURI else { return }
        unpinned = nil
        lastUploadedURI = imageURI
        mediaURI = imageURI
        animationURI = pins.videoURI ?? ""
    }

    private func retryPin() async {
        guard let pins = unpinned else { return }
        uploading = true
        defer { uploading = false }
        await pin(pins)
        if unpinned == nil { Haptics.success() }
    }

    /// A photo whose pin failed, published with DyorHQ's https copy instead — only when the user chooses it. The app
    /// shows that copy only while its bytes still match the on-chain fingerprint (`MomentArtwork.imageSources`).
    /// Not offered for a video: its cover frame can't be checked against the video's fingerprint.
    private func useMirror() {
        guard let pins = unpinned, pins.video == nil else { return }
        unpinned = nil
        usesMirror = true
        lastUploadedURI = pins.image.mirror.absoluteString
        mediaURI = pins.image.mirror.absoluteString
        animationURI = ""
    }
}

/// Uploaded Moment media and how far pinning it to IPFS got: the image (a photo, or a video's cover frame) and, for a
/// video, the video itself.
private struct MediaPins {
    let image: SocialSession.MomentUpload
    let video: SocialSession.MomentUpload?
    var imageURI: String?
    var videoURI: String?
    /// Why the last attempt failed.
    var failure: String?
}

/// A video picked from the library, copied to a temporary file so it can be read, hashed, uploaded and sampled.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = URL.temporaryDirectory.appending(path: "moment-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }

    /// The frame one second in (or the first frame of a shorter clip), as the NFT's cover image.
    static func coverFrame(url: URL) async throws -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        let duration = try await asset.load(.duration)
        let at = CMTime(seconds: min(1, max(0, duration.seconds / 2)), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: at)
        return UIImage(cgImage: image)
    }
}
