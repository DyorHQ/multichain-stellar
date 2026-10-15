// Stellar copy of ios/DyorHQ/Moments/MomentDetailView.swift MomentDetailView (42cd8c7 sha256:b47ea52891d1)
// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentStateBadge (42cd8c7 sha256:e656eda0dbb7)
// Stellar copy of ios/DyorHQ/Moments/MomentsUI.swift MomentStateLabel (42cd8c7 sha256:a4ec2c6cd7d5)
// A Stellar Moment's page (docs/DESIGN-stellar-parity.md §8.11.2, §8.11.3; docs/DESIGN-stellar-contracts-v2.md §21).
// Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import AVFoundation
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// A Stellar Moment's page, pushed over the Moments board. A Moment of contracts v2 is its NFT contract, keyed by that
/// address: its progress to the threshold, the collect ticket while it collects, its graduation (or expiry), the
/// account's editions and coins as they vest, the creator's proceeds and the pool once it exists. A retired v1 Moment
/// (`init(id:)`) is shown as it stands: its editions and their way into Freighter, never a collect.
struct StellarMomentDetailView: View {
    private enum Key: Hashable {
        case moment(StellarMomentListingV2)
        case retired(Int)
    }

    private let key: Key

    /// The v2 Moment `nft`, with what its opener knows of it (`listing`: its name and media); only the address otherwise.
    init(nft: String, listing: StellarMomentListingV2? = nil) {
        key = .moment(listing?.nft == nft ? listing! : StellarMomentListingV2(nft: nft))
    }

    /// A v2 Moment as its opener knows it (Publish, a board's card).
    init(listing: StellarMomentListingV2) {
        key = .moment(listing)
    }

    /// The retired v1 Moment `id`, by its number in the v1 Moments contract.
    init(id: Int) {
        key = .retired(id)
    }

    var body: some View {
        switch key {
        case .moment(let listing): StellarMomentPage(listing: listing)
        case .retired(let id): StellarRetiredMomentPage(id: id)
        }
    }
}

// MARK: - A v2 Moment

/// One v2 Moment's page (MomentDetailView's sections, for Stellar): every figure read live from its contract through the
/// API (`MomentsV2Store`), every write a review (`StellarConfirmationSheet`). No share button and no OpenSea row: Stellar
/// editions are seen in Freighter (`StellarFreighterSheet`).
private struct StellarMomentPage: View {
    let listing: StellarMomentListingV2
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    /// The time the page is drawn at: it moves on only when what the page shows of the time changes (the window closing,
    /// graduation turning slow, the Moment becoming expirable); the badge's countdown keeps its own.
    @State private var clock = Clock()
    @State private var status: StellarMomentStatusV2?
    @State private var vesting: StellarMomentVestingV2?
    @State private var economics: StellarMomentsEconomicsV2?
    /// The editions this account collected from this page, from each settled collect's result: the API has no read of an
    /// account's v2 editions, so these are the ones the page can offer in Freighter.
    @State private var collected: [Int] = []
    @State private var quantity = 1
    @State private var reloads = 0
    /// Each part whose latest read failed, and why: the header says the first, with Retry, and the part keeps what it
    /// last read.
    @State private var failures: [Part: String] = [:]
    @State private var action: Action?
    @State private var freighter: StellarFreighterEdition?

    private enum Part: CaseIterable { case status, economics, vesting }

    private enum Action: String, Identifiable {
        case collect, claim, withdraw, graduate, expire
        var id: String { rawValue }
    }

    private var moments: MomentsV2Store? { session?.store.map { MomentsV2Store(store: $0) } }
    private var canSign: Bool { session?.canSign == true }
    private var loadError: String? { Part.allCases.lazy.compactMap { failures[$0] }.first }
    private var nft: String { listing.nft }
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(clock.now)) }
    private var phase: StellarMomentPhaseV2? { status.map { StellarMomentPhaseV2($0, now: now) } }
    private var isCreator: Bool { status.map { $0.creator == session?.address } == true }
    private var name: String { listing.name ?? StellarAccountID(nft)?.short ?? nft }

    var body: some View {
        List {
            headerSection
            if let status, let phase {
                if phase != .graduated, phase != .expired { progressSection(status, phase: phase) }
                statsSection(status)
                if phase == .collecting { collectSection(status) }
                switch phase {
                case .graduating, .graduationFailed: graduationSection(status, phase: phase)
                case .windowClosed: windowClosedSection(status)
                case .expired: expiredSection(status)
                case .collecting, .graduated: EmptyView()
                }
                positionSection(status, phase: phase)
                if isCreator { creatorSection(status, phase: phase) }
                if phase == .graduated { poolSection(status) }
                aboutSection(status)
            } else if loadError == nil {
                Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: listing.symbol.map { "$\($0)" } ?? name))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await clock.run(showing: { face(at: $0) }) }
        .task(id: reloads) { await load() }
        // While it waits to graduate, the page follows it: the keeper usually finishes within a minute.
        .task(id: "\(phase?.rawValue ?? "")-\(reloads)") { await follow() }
        .sheet(item: $action) { sheet(for: $0) }
        .sheet(item: $freighter) { StellarFreighterSheet(edition: $0) }
    }

    /// What the page shows of the time at `time`: its phase, whether graduation is slow, whether it can expire.
    private func face(at time: Int) -> [String] {
        guard let status else { return [] }
        let at = Date(timeIntervalSince1970: TimeInterval(time))
        return [StellarMomentPhaseV2(status, now: at).rawValue, String(StellarMomentText.isSlow(status, at: at)), String(StellarMomentText.isExpirable(status, at: at))]
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // The art fills a box the row's width decides; a video loops muted over its poster.
                Color(.tertiarySystemFill)
                    .frame(height: 240)
                    .overlay { StellarMomentArtwork(image: listing.image, name: name) }
                    .overlay {
                        if let video = StellarImages.video(listing.video) { StellarLoopingVideo(url: video).allowsHitTesting(false) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: name).font(.title2.weight(.semibold)).lineLimit(2)
                        if let symbol = listing.symbol {
                            Text(verbatim: "$\(symbol)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    if let status { StellarMomentPhaseBadge(status: status) }
                    HStack(spacing: 6) {
                        if let place = listing.place, !place.isEmpty { Label { Text(verbatim: place) } icon: { Image(systemName: "mappin.and.ellipse") }.lineLimit(1) }
                        if let day = listing.takenOn.flatMap(StellarMomentText.day) { Label { Text(verbatim: day) } icon: { Image(systemName: "calendar") } }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let loadError {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: loadError)
                        Spacer(minLength: 8)
                        Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func progressSection(_ status: StellarMomentStatusV2, phase: StellarMomentPhaseV2) -> some View {
        Section {
            Gauge(value: min(1, max(0, status.progress))) {
                Text("Graduation")
            } currentValueLabel: {
                Text(verbatim: NumberStyle.basisPoints(Int((min(1, max(0, status.progress)) * 10_000).rounded(.down))))
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.brand)
            LabeledContent("Reserve", value: tr("\(StellarMomentText.usdc(status.reserve)) of \(StellarMomentText.usdc(status.threshold))"))
            if phase == .collecting, let left = StellarMomentText.remaining(status) {
                LabeledContent("Still needed", value: StellarMomentText.usdc(left))
                if let deadline = StellarFormat.date(status.deadline) { LabeledContent("Window closes", value: MomentsFormat.date(deadline)) }
            }
        } footer: {
            Paragraph(LocalizedStringResource("\(NumberStyle.basisPoints(status.reserveBps)) of every collect builds the reserve. At the threshold the coin graduates into a Soroswap pool whose liquidity is locked forever.", table: "StellarMoments", comment: "Under a Stellar Moment's progress bar. The value is a share of each collect (75%). Soroswap is never translated"))
        }
    }

    private func statsSection(_ status: StellarMomentStatusV2) -> some View {
        Section {
            HStack(spacing: 0) {
                stat(Text("Per edition"), StellarMomentText.usdc(status.price))
                Divider().frame(height: 34)
                stat(Text("Graduation FDV"), StellarMomentText.fdvAtOpen(status).map(StellarMomentText.usdc) ?? "—")
                Divider().frame(height: 34)
                stat(Text("Editions"), "\(status.editions)")
                Divider().frame(height: 34)
                stat(Text("Collects"), "\(status.collects)")
            }
        }
    }

    private func stat(_ label: Text, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            label.font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Collect

    private func collectSection(_ status: StellarMomentStatusV2) -> some View {
        let limit = StellarMomentText.collectLimit(maxPerCollect: economics?.maxPerCollect)
        let price = Int64(status.price) ?? 0
        let pay = price.multipliedReportingOverflow(by: Int64(min(quantity, limit))).partialValue
        let balance = moments?.usdcBalance ?? 0
        let short = balance < pay
        return Section {
            Stepper(value: $quantity, in: 1...limit) {
                HStack {
                    Text("Editions")
                    Spacer()
                    Text(verbatim: "\(quantity)").monospacedDigit().fontWeight(.semibold)
                }
            }
            LabeledContent("You pay") { Text(verbatim: StellarMomentText.usdc(pay)).monospacedDigit().fontWeight(.semibold) }
            if StellarMomentText.completes(status, quantity: quantity) {
                Label {
                    Text("This collect completes the Moment: it takes only what the reserve still needs, and the coin graduates right after.", tableName: "StellarMoments", comment: "On a Stellar Moment's collect ticket: this many editions reach the threshold")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.footnote).foregroundStyle(Color.brand)
            }
            LabeledContent("Your USDC") {
                Text(verbatim: StellarMomentText.usdc(balance)).monospacedDigit().foregroundStyle(short ? Color.attention : .secondary)
            }
            if canSign {
                if short {
                    Button {
                        Haptics.tap()
                        router.openStellarSwap(buy: "USDC")
                    } label: {
                        Label { Text("Get USDC", tableName: "StellarMoments", comment: "Button on a Stellar Moment's collect ticket when the account's USDC is short: opens Swap to buy USDC. USDC is never translated") } icon: { Image(systemName: "arrow.left.arrow.right") }
                    }
                }
                Button {
                    Haptics.tap()
                    action = .collect
                } label: {
                    Label("Collect \(quantity) Editions", systemImage: "camera.aperture").fontWeight(.semibold)
                }
                .disabled(short || price <= 0)
            } else {
                Text("Sign in to collect.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Collect")
        } footer: {
            Paragraph(LocalizedStringResource("Paid in USDC: \(NumberStyle.basisPoints(status.reserveBps)) reserve, \(NumberStyle.basisPoints(status.creatorBps)) creator, \(NumberStyle.basisPoints(status.platformBps)) DyorHQ. Your editions show in My Moments as soon as it settles.", table: "StellarMoments", comment: "Under a Stellar Moment's collect ticket: how each collect is split. The values are shares (75%, 20%, 5%). USDC and DyorHQ are never translated"))
        }
    }

    // MARK: Graduation and expiry

    @ViewBuilder
    private func graduationSection(_ status: StellarMomentStatusV2, phase: StellarMomentPhaseV2) -> some View {
        Section {
            if phase == .graduationFailed {
                Paragraph(LocalizedStringResource("A graduation attempt failed. Anyone can try again; it graduates as soon as an attempt succeeds.", table: "StellarMoments", comment: "A Stellar Moment whose graduation failed and was recorded"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure = status.failure {
                    LabeledContent {
                        Text(verbatim: failure.name ?? "\(failure.origin) · \(failure.code)").font(.footnote.monospaced())
                    } label: {
                        Text("Reason", tableName: "StellarMoments", comment: "A row on a Stellar Moment whose graduation failed: the contract error it failed with (shown in English, as the contract names it)")
                    }
                }
                if let since = status.stuckSince.flatMap(StellarFormat.date) { LabeledContent("First failure", value: MomentsFormat.date(since)) }
            } else {
                Paragraph(LocalizedStringResource("This Moment reached its goal. DyorHQ graduates it within about a minute, and anyone can.", table: "StellarMoments", comment: "A Stellar Moment waiting to graduate into its coin and pool. DyorHQ is never translated"))
                    .font(.footnote).foregroundStyle(.secondary)
                if StellarMomentText.isSlow(status, at: now) {
                    Label {
                        Text("Graduation is taking longer than usual.", tableName: "StellarMoments", comment: "A Stellar Moment that has waited over an hour to graduate")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
                }
            }
            if let expires = status.expiresAt.flatMap(StellarFormat.date) {
                LabeledContent {
                    Text(verbatim: MomentsFormat.date(expires))
                } label: {
                    Text("Can expire from", tableName: "StellarMoments", comment: "A row on a Stellar Moment that hasn't graduated: from when anyone can end it without graduating (a date follows)")
                }
            }
            if StellarMomentText.isExpirable(status, at: now) {
                expireButton
            } else if status.graduatable {
                Button(phase == .graduationFailed ? "Retry Graduation" : "Graduate", systemImage: "arrow.up.forward.circle") { Haptics.tap(); action = .graduate }
                    .disabled(!canSign)
            }
        } header: {
            if phase == .graduationFailed {
                Text("Graduation Failed", tableName: "StellarMoments", comment: "Section header on a Stellar Moment whose graduation attempt failed")
            } else {
                Text("Graduation Pending")
            }
        } footer: {
            Paragraph(LocalizedStringResource("If it never graduates, it can expire: \(NumberStyle.basisPoints(status.expiryCreatorBps)) of its reserve goes to the creator and the rest to the DyorHQ treasury. Collectors keep their editions.", table: "StellarMoments", comment: "Under a Stellar Moment's graduation: what happens if it expires instead. The value is the creator's share (70%). DyorHQ is never translated"))
        }
    }

    private func windowClosedSection(_ status: StellarMomentStatusV2) -> some View {
        Section {
            Paragraph("The collect window closed with the reserve short of the threshold. Anyone can wind it down: \(NumberStyle.basisPoints(status.expiryCreatorBps)) of the reserve to the creator, the rest to the treasury.")
                .font(.footnote).foregroundStyle(.secondary)
            expireButton
        } header: {
            Text("Window Closed")
        }
    }

    private var expireButton: some View {
        Button("Expire Moment", systemImage: "xmark.circle") { Haptics.tap(); action = .expire }.disabled(!canSign)
    }

    private func expiredSection(_ status: StellarMomentStatusV2) -> some View {
        Section {
            if let ended = status.endedAt.flatMap(StellarFormat.date) { LabeledContent("Ended", value: MomentsFormat.date(ended)) }
            Paragraph(LocalizedStringResource("It ended before graduating: \(NumberStyle.basisPoints(status.expiryCreatorBps)) of its reserve went to the creator and the rest to the DyorHQ treasury. Collectors keep their editions; its coin was never made.", table: "StellarMoments", comment: "An expired Stellar Moment. The value is the creator's share of the reserve (70%). DyorHQ is never translated"))
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Expired")
        }
    }

    // MARK: Position, creator, pool

    @ViewBuilder
    private func positionSection(_ status: StellarMomentStatusV2, phase: StellarMomentPhaseV2) -> some View {
        let side = vesting?.collector
        if !collected.isEmpty || side != nil {
            Section {
                if !collected.isEmpty {
                    LabeledContent("Editions", value: StellarMomentText.editions(collected))
                    ForEach(collected.prefix(3), id: \.self) { edition in
                        Button {
                            freighter = freighterEdition(edition)
                        } label: {
                            Label { Text("View #\(String(edition)) in Freighter", tableName: "StellarMoments", comment: "A button on a Stellar Moment: how to see this edition in Freighter, the Stellar wallet. The value is the edition's number. Freighter is never translated") } icon: { Image(systemName: "wallet.bifold") }
                        }
                        .disabled(freighterEdition(edition) == nil)
                    }
                }
                if let side {
                    LabeledContent("Coins owed", value: StellarMomentText.coins(side.total, symbol: listing.symbol))
                    if phase == .graduated { vestingRows(side, claimable: vesting?.claimable.collector ?? "0") }
                }
                claimButton(status, phase: phase)
            } header: {
                Text("Your Position")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if phase != .graduated, phase != .expired { Paragraph("Coins are minted to you as they vest once the Moment graduates.") }
                    if !collected.isEmpty {
                        Paragraph(LocalizedStringResource("Each edition is an NFT in your Stellar account. Freighter can show it once you add it.", table: "StellarMoments", comment: "Under a Stellar Moment's position. Stellar and Freighter are never translated"))
                    }
                }
            }
        }
    }

    /// Claimable, claimed and vested, and the schedule: when each tranche vests.
    @ViewBuilder
    private func vestingRows(_ side: StellarMomentVestingV2.Side, claimable: String) -> some View {
        let due = (Int64(claimable) ?? 0) > 0
        LabeledContent("Claimable now") {
            Text(verbatim: StellarMomentText.coins(claimable, symbol: listing.symbol)).monospacedDigit()
                .fontWeight(due ? .semibold : .regular).foregroundStyle(due ? Color.brand : .primary)
        }
        LabeledContent("Claimed", value: StellarMomentText.coins(side.claimed, symbol: listing.symbol))
        ForEach(side.tranches) { tranche in
            LabeledContent {
                Text(verbatim: NumberStyle.basisPoints(tranche.vestedBps))
                    .monospacedDigit()
                    .foregroundStyle(tranche.at.flatMap(StellarFormat.date).map { $0 <= now } == true ? Color.positive : .secondary)
            } label: {
                Text(verbatim: tranche.at.flatMap(StellarFormat.date).map(MomentsFormat.date) ?? "—")
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func claimButton(_ status: StellarMomentStatusV2, phase: StellarMomentPhaseV2) -> some View {
        if phase == .graduated, let total = vesting?.claimable.total, (Int64(total) ?? 0) > 0 {
            Button {
                Haptics.tap()
                action = .claim
            } label: {
                Label(listing.symbol.map { tr("Claim \(StellarMomentText.units(total)) $\($0)") } ?? tr("Claim"), systemImage: "arrow.down.circle")
                    .fontWeight(.semibold)
            }
            .disabled(!canSign)
        }
    }

    private func creatorSection(_ status: StellarMomentStatusV2, phase: StellarMomentPhaseV2) -> some View {
        let proceeds = Int64(status.proceeds.creator) ?? 0
        return Section {
            LabeledContent("Proceeds to withdraw") {
                Text(verbatim: StellarMomentText.usdc(proceeds)).monospacedDigit().fontWeight(proceeds > 0 ? .semibold : .regular)
            }
            if proceeds > 0 {
                Button("Withdraw Proceeds", systemImage: "banknote") { Haptics.tap(); action = .withdraw }.disabled(!canSign)
            }
            if phase == .graduated, let mine = vesting?.creator {
                LabeledContent("Allocation claimable") { Text(verbatim: StellarMomentText.coins(vesting?.claimable.creator ?? "0", symbol: listing.symbol)).monospacedDigit() }
                LabeledContent("Allocation vested", value: StellarMomentText.coins(mine.vested, symbol: listing.symbol))
                if vesting?.collector == nil { claimButton(status, phase: phase) }
            }
        } header: {
            Text("You Created This")
        } footer: {
            Paragraph(LocalizedStringResource("\(NumberStyle.basisPoints(status.creatorBps)) of every collect waits here for you to withdraw. Your coins vest from graduation: 20% then, and 16% more each period.", table: "StellarMoments", comment: "Under a Stellar Moment's creator section. The value is the creator's share of each collect (20%)"))
        }
    }

    private func poolSection(_ status: StellarMomentStatusV2) -> some View {
        Section {
            if let coin = StellarAccountID(status.coin) { StellarAddressRow(title: "Coin", address: coin) }
            if let pool = status.pool.flatMap(StellarAccountID.init) { StellarAddressRow(title: "Pool", address: pool) }
            if let graduated = status.graduatedAt.flatMap(StellarFormat.date) { LabeledContent("Graduated", value: MomentsFormat.date(graduated)) }
            LabeledContent("Liquidity", value: tr("Locked forever"))
            Button {
                Haptics.tap()
                router.openStellarSwap(sell: "USDC", buy: status.coin)
            } label: {
                Label("Trade $\(listing.symbol ?? StellarAccountID(status.coin)?.short ?? "")", systemImage: "arrow.left.arrow.right").fontWeight(.semibold)
            }
        } header: {
            Text("Pool")
        } footer: {
            if let harvest = economics?.terms.harvest {
                Paragraph(LocalizedStringResource("Graduated on Soroswap. Of its pool's fees on the locked liquidity, \(NumberStyle.basisPoints(harvest.compoundedBps)) stay in the pool; of the rest, the USDC goes \(NumberStyle.basisPoints(harvest.quoteSide.creatorBps)) to the creator and \(NumberStyle.basisPoints(harvest.quoteSide.platformBps)) to DyorHQ, and the coins are burned.", table: "StellarMoments", comment: "Under a graduated Stellar Moment's pool. The values are shares (33.33%, 40%, 60%). Soroswap, USDC and DyorHQ are never translated"))
            }
        }
    }

    private func aboutSection(_ status: StellarMomentStatusV2) -> some View {
        Section {
            if let creator = StellarAccountID(status.creator) { StellarAddressRow(title: "Creator", address: creator) }
            if let published = StellarFormat.date(status.publishedAt) { LabeledContent("Published", value: MomentsFormat.date(published)) }
            if let deadline = StellarFormat.date(status.deadline) { LabeledContent("Collect window", value: tr("until \(MomentsFormat.date(deadline))")) }
            LabeledContent("Split", value: tr("\(NumberStyle.basisPoints(status.reserveBps)) reserve · \(NumberStyle.basisPoints(status.creatorBps)) creator · \(NumberStyle.basisPoints(status.platformBps)) DyorHQ"))
            LabeledContent("Creator allocation", value: NumberStyle.basisPoints(status.creatorAllocBps))
            LabeledContent("NFT royalty", value: NumberStyle.basisPoints(status.royaltyBps))
            if let supply = economics?.supply { LabeledContent("Supply", value: StellarMomentText.coins(supply, symbol: listing.symbol)) }
            if let video = StellarImages.video(listing.video) {
                Link(destination: video) { Label("Open video", systemImage: "play.rectangle") }
            } else if let image = StellarMomentText.original(listing.image) {
                Link(destination: image) { Label("Open media", systemImage: "photo") }
            }
            if let collection = StellarAccountID(nft) {
                StellarAddressRow(resource: LocalizedStringResource("Collection", table: "StellarMoments", comment: "A row on a Stellar Moment: the address of its NFT contract, which holds its editions"), address: collection)
                if let page = collection.explorerURL() {
                    Link(destination: page) {
                        Label { Text("View on StellarExpert", tableName: "StellarCommon") } icon: { Image(systemName: "safari") }
                    }
                }
            }
        } header: {
            Text("About this Moment")
        } footer: {
            Paragraph("Fixed at publish; nothing about a live Moment can be changed.")
        }
    }

    // MARK: Reviews

    @ViewBuilder
    private func sheet(for which: Action) -> some View {
        let symbol = listing.symbol ?? name
        switch which {
        case .collect:
            let count = min(quantity, StellarMomentText.collectLimit(maxPerCollect: economics?.maxPerCollect))
            StellarConfirmationSheet(
                title: "Collect \(symbol)", confirmTitle: "Collect",
                build: {
                    guard let moments, let status else { throw LiteAPIError.notSignedIn }
                    return try await moments.collectPlan(nft: nft, quantity: count, price: Int64(status.price) ?? 0, name: name, title: tr("Collect"))
                },
                onDone: { reloads += 1 },
                onCompleted: { results in
                    if let editions = MomentsV2Store.collectedEditions(results) { collected = Array(Set(collected).union(editions)).sorted() }
                    reloads += 1
                }
            ) {
                DetailRow("Moment", verbatim: listing.symbol.map { "\(name) ($\($0))" } ?? name)
                DetailRow("Editions", verbatim: "\(count)")
                DetailRow(Text("Your NFTs", tableName: "StellarMoments", comment: "A row of a Stellar Moment's collect review: where the editions collected appear"),
                          Text("In My Moments once it settles", tableName: "StellarMoments", comment: "The value of the collect review's 'Your NFTs' row"))
                if let status, StellarMomentText.completes(status, quantity: count) {
                    DetailRow(Text("Graduates"), Text("Yes, right after", tableName: "StellarMoments", comment: "The value of a Stellar Moment's collect review row 'Graduates': this collect completes it, and it graduates in the following ledgers"), tint: .brand)
                }
            }
        case .claim:
            StellarConfirmationSheet(
                title: "Claim \(symbol)", confirmTitle: "Claim",
                build: {
                    guard let moments else { throw LiteAPIError.notSignedIn }
                    return try await moments.claimPlan(nft: nft, title: tr("Claim"))
                },
                onDone: { reloads += 1 }, onCompleted: { _ in reloads += 1 }
            ) {
                DetailRow("Claimable", verbatim: StellarMomentText.coins(vesting?.claimable.total ?? "0", symbol: listing.symbol))
            }
        case .withdraw:
            StellarConfirmationSheet(
                title: "Withdraw Proceeds", confirmTitle: "Withdraw",
                build: {
                    guard let moments else { throw LiteAPIError.notSignedIn }
                    return try await moments.withdrawPlan(nft: nft, symbol: symbol, title: tr("Withdraw"))
                },
                onDone: { reloads += 1 }, onCompleted: { _ in reloads += 1 }
            ) {
                DetailRow("Proceeds", StellarMomentText.usdc(status?.proceeds.creator ?? "0"))
            }
        case .graduate:
            StellarConfirmationSheet(
                title: status?.stuckSince == nil ? "Graduate" : "Retry Graduation", confirmTitle: "Graduate",
                build: {
                    guard let moments else { throw LiteAPIError.notSignedIn }
                    return try await moments.graduatePlan(nft: nft, symbol: symbol, title: tr("Graduate"))
                },
                onDone: { reloads += 1 }, onCompleted: { _ in reloads += 1 }
            ) {
                DetailRow("Reserve", StellarMomentText.usdc(status?.reserve ?? "0"))
                DetailRow(Text("Pool"), Text("Soroswap · locked forever", tableName: "StellarMoments", comment: "A row of a Stellar Moment's graduation review: where its coin's liquidity goes. Soroswap is never translated"))
            }
        case .expire:
            StellarConfirmationSheet(
                title: "Expire Moment", confirmTitle: "Expire",
                build: {
                    guard let moments else { throw LiteAPIError.notSignedIn }
                    return try await moments.expirePlan(nft: nft, title: tr("Expire"))
                },
                onDone: { reloads += 1 }, onCompleted: { _ in reloads += 1 }
            ) {
                DetailRow("Reserve", StellarMomentText.usdc(status?.reserve ?? "0"))
                DetailRow("To creator", NumberStyle.basisPoints(status?.expiryCreatorBps ?? 0))
                DetailRow("To treasury", NumberStyle.basisPoints(10_000 - (status?.expiryCreatorBps ?? 0)))
            }
        }
    }

    /// Edition `number` of this Moment, as Freighter adds it: the Moment's own NFT contract and the edition's number.
    private func freighterEdition(_ number: Int) -> StellarFreighterEdition? {
        StellarAccountID(nft).map { StellarFreighterEdition(contract: $0, tokenId: number, name: listing.name, image: listing.image, isVideo: listing.video != nil) }
    }

    // MARK: Loading

    /// The page's reads, side by side, each part shown as its read lands; a part whose read fails keeps what it showed
    /// and says so (`failures`).
    private func load() async {
        guard let moments else { return }
        async let s: Void = read(.status) { status = try await moments.status(nft) }
        async let e: Void = read(.economics) { economics = try await moments.economics() }
        async let v: Void = read(.vesting) { vesting = try await moments.vesting(nft) }
        _ = await (s, e, v)
    }

    private func read(_ part: Part, _ body: () async throws -> Void) async {
        do {
            try await body()
            failures[part] = nil
        } catch LiteAPIError.notSignedIn where part == .vesting {
            // No account to read about: nothing to show, nothing failed.
            failures[part] = nil
        } catch {
            if !Task.isCancelled { failures[part] = LiteErrorText.describe(error) }
        }
    }

    /// While the Moment waits to graduate, its state again every 15 seconds, until it moves on or the page closes.
    private func follow() async {
        guard let moments, phase == .graduating || phase == .graduationFailed else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let read = try? await moments.status(nft) else { continue }
            if read != status { status = read }
            if read.state != "graduation_pending" {
                reloads += 1
                return
            }
        }
    }
}

// MARK: - The state badge

/// Where a v2 Moment is: collecting (with the time left), window closed, graduation pending or failed, graduated,
/// expired. Colour never stands alone: the word is always there. A collecting Moment's badge keeps its own time, drawn
/// again alone at each instant its countdown reads differently and at the deadline.
struct StellarMomentPhaseBadge: View {
    let status: StellarMomentStatusV2
    /// On top of a photo the badge sits on a material so it stays legible whatever the image.
    var onMedia = false

    var body: some View {
        if StellarMomentPhaseV2(status, now: Date()) == .collecting, let deadline = StellarFormat.date(status.deadline) {
            TimelineView(CountdownSchedule(deadline: Int(deadline.timeIntervalSince1970))) { context in
                StellarMomentPhaseLabel(status: status, now: context.date, onMedia: onMedia)
            }
        } else {
            StellarMomentPhaseLabel(status: status, now: Date(), onMedia: onMedia)
        }
    }
}

/// `StellarMomentPhaseBadge` at one time.
private struct StellarMomentPhaseLabel: View {
    let status: StellarMomentStatusV2
    let now: Date
    var onMedia: Bool

    private var phase: StellarMomentPhaseV2 { StellarMomentPhaseV2(status, now: now) }

    private var words: String {
        switch phase {
        case .collecting:
            let seconds = StellarFormat.date(status.deadline).map { Int($0.timeIntervalSince(now)) } ?? 0
            let left = MomentsFormat.countdown(seconds, short: onMedia)
            return onMedia ? left : tr("Collecting · \(left)")
        case .windowClosed: return tr("Window closed")
        case .graduating: return tr("Graduation pending")
        case .graduationFailed:
            return liteTr(LocalizedStringResource("Graduation failed", table: "StellarMoments", comment: "[tight] A Stellar Moment's badge: its graduation attempt failed"))
        case .graduated: return tr("Graduated")
        case .expired: return tr("Expired")
        }
    }

    private var tint: Color {
        switch phase {
        case .collecting: .brand
        case .windowClosed, .expired: .secondary
        case .graduating, .graduationFailed: .attention
        case .graduated: .positive
        }
    }

    private var symbol: String {
        switch phase {
        case .collecting: "clock"
        case .windowClosed: "clock.badge.xmark"
        case .graduating: "hourglass"
        case .graduationFailed: "exclamationmark.triangle.fill"
        case .graduated: "checkmark.seal.fill"
        case .expired: "xmark.circle"
        }
    }

    var body: some View {
        Label(words, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if onMedia { Capsule().fill(.regularMaterial) } else { Capsule().fill(tint.opacity(0.14)) }
            }
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

// MARK: - A retired v1 Moment

/// A Moment of the retired v1 contract (SEP-50 editions, no coin): its media, figures, the account's editions with their
/// way into Freighter, its collectors and what was fixed at publish. Nothing is collected or published there any more.
private struct StellarRetiredMomentPage: View {
    let id: Int
    @Environment(\.stellarSession) private var session
    @State private var detail: StellarMomentDetail?
    @State private var failure: String?
    @State private var reloads = 0
    @State private var freighter: StellarFreighterEdition?

    private var store: LiteStore? { session?.store }

    var body: some View {
        List {
            if let detail {
                let m = detail.moment
                header(m)
                Section {
                    LabeledContent("Per edition", value: StellarMomentText.amount(m.price, code: m.quoteCode ?? store?.asset(m.quote)?.code ?? StellarAccountID(m.quote)?.short ?? m.quote))
                    LabeledContent("Editions", value: m.maxEditions > 0 ? "\(m.minted)/\(m.maxEditions)" : "\(m.minted)")
                    if let collects = m.collects { LabeledContent("Collects", value: "\(collects)") }
                    if let count = detail.collectorsSummary?.count {
                        LabeledContent { Text(verbatim: "\(count)") } label: { Text("Collectors", tableName: "StellarMoments", comment: "[tight] A Stellar Moment's stat: how many accounts collected it") }
                    }
                }
                positionSection(detail)
                collectorsSection(detail)
                aboutSection(m)
            } else if let failure {
                Section {
                    InlineError(message: failure)
                    Button("Try Again", systemImage: "arrow.clockwise") { reloads += 1 }
                }
            } else {
                Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: detail?.moment.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: reloads) { await load() }
        .sheet(item: $freighter) { StellarFreighterSheet(edition: $0) }
    }

    private func title(_ m: StellarMoment) -> String { m.title ?? tr("Moment #\(String(m.id))") }

    private func header(_ m: StellarMoment) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Color(.tertiarySystemFill)
                    .frame(height: 240)
                    .overlay { StellarMomentArtwork(image: m.posterUrl ?? m.mediaUrl, name: title(m)) }
                    .overlay {
                        if m.mediaType == "video", let video = StellarImages.video(m.mediaUrl) { StellarLoopingVideo(url: video).allowsHitTesting(false) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title(m)).font(.title2.weight(.semibold)).lineLimit(2)
                    Label {
                        Text("Retired", tableName: "StellarMoments", comment: "[tight] A badge on a Moment of DyorHQ's first, retired Stellar Moments contract: it can't be collected any more")
                    } icon: {
                        Image(systemName: "archivebox")
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let place = m.place, !place.isEmpty { Label { Text(verbatim: place) } icon: { Image(systemName: "mappin.and.ellipse") }.lineLimit(1) }
                        if let day = m.takenOn.flatMap(StellarMomentText.day) { Label { Text(verbatim: day) } icon: { Image(systemName: "calendar") } }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Paragraph(LocalizedStringResource("From DyorHQ's first Stellar Moments contract, now retired: it can't be collected any more. Editions stay with their collectors.", table: "StellarMoments", comment: "Under a retired Stellar Moment's header. DyorHQ and Stellar are never translated"))
        }
    }

    @ViewBuilder
    private func positionSection(_ detail: StellarMomentDetail) -> some View {
        let editions = detail.you?.editions ?? []
        if !editions.isEmpty {
            Section {
                LabeledContent("Editions", value: StellarMomentText.editions(editions))
                ForEach(editions.prefix(3), id: \.self) { edition in
                    Button {
                        freighter = freighterEdition(edition, of: detail.moment)
                    } label: {
                        Label { Text("View #\(String(edition)) in Freighter", tableName: "StellarMoments") } icon: { Image(systemName: "wallet.bifold") }
                    }
                    .disabled(freighterEdition(edition, of: detail.moment) == nil)
                }
            } header: {
                Text("Your Position")
            } footer: {
                Paragraph(LocalizedStringResource("Each edition is an NFT in your Stellar account. Freighter can show it once you add it.", table: "StellarMoments"))
            }
        }
    }

    private func collectorsSection(_ detail: StellarMomentDetail) -> some View {
        Section {
            if let summary = detail.collectorsSummary, summary.count > 0 {
                LabeledContent { Text(verbatim: "\(summary.count)") } label: { Text("Collectors", tableName: "StellarMoments") }
                if let largest = summary.largest, let address = StellarAccountID(largest.address) {
                    LabeledContent("Largest", value: tr("\(address.short) · \(largest.editions) editions"))
                }
            } else {
                Text("No collects yet.", tableName: "StellarMoments", comment: "A Stellar Moment nobody has collected yet")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Collectors", tableName: "StellarMoments")
        }
    }

    private func aboutSection(_ m: StellarMoment) -> some View {
        Section {
            if let creator = StellarAccountID(m.creator) { StellarAddressRow(title: "Creator", address: creator) }
            if let published = StellarFormat.date(m.publishedAt ?? m.createdAt) { LabeledContent("Published", value: MomentsFormat.date(published)) }
            if let deadline = StellarFormat.date(m.deadline) { LabeledContent("Collect window", value: tr("until \(MomentsFormat.date(deadline))")) }
            if let platform = m.platformBps {
                LabeledContent {
                    Text(verbatim: liteTr(LocalizedStringResource("\(NumberStyle.basisPoints(10_000 - platform)) creator · \(NumberStyle.basisPoints(platform)) DyorHQ", table: "StellarMoments", comment: "A retired Stellar Moment's split of each collect: the creator's share, then DyorHQ's (95%, 5%). DyorHQ is never translated")))
                } label: {
                    Text("Split")
                }
            }
            if let royalty = m.royaltyBps { LabeledContent("NFT royalty", value: NumberStyle.basisPoints(royalty)) }
            LabeledContent {
                if m.maxEditions > 0 {
                    Text(verbatim: "\(m.maxEditions)")
                } else {
                    Text("Open edition", tableName: "StellarMoments", comment: "The edition size of a Stellar Moment with no cap")
                }
            } label: {
                Text("Edition size", tableName: "StellarMoments", comment: "A row on a Stellar Moment: how many editions it can have")
            }
            if m.mediaType == "video", let video = StellarImages.video(m.mediaUrl) {
                Link(destination: video) { Label("Open video", systemImage: "play.rectangle") }
            } else if let image = StellarMomentText.original(m.mediaUrl) {
                Link(destination: image) { Label("Open media", systemImage: "photo") }
            }
            if let collection = contract(of: m) {
                StellarAddressRow(resource: LocalizedStringResource("Collection", table: "StellarMoments"), address: collection)
                if let page = collection.explorerURL() {
                    Link(destination: page) {
                        Label { Text("View on StellarExpert", tableName: "StellarCommon") } icon: { Image(systemName: "safari") }
                    }
                }
            }
        } header: {
            Text("About this Moment")
        } footer: {
            Paragraph("Fixed at publish; nothing about a live Moment can be changed.")
        }
    }

    /// The v1 Moments contract that minted `m`: the account's editions name it (as the store last read them); else the
    /// API's v1 Moments contract.
    private func contract(of m: StellarMoment) -> StellarAccountID? {
        let named = store?.owned.first { $0.momentId == m.id }?.contract ?? store?.config?.contracts.moments
        return named.flatMap(StellarAccountID.init)
    }

    private func freighterEdition(_ tokenId: Int, of m: StellarMoment) -> StellarFreighterEdition? {
        contract(of: m).map { StellarFreighterEdition(contract: $0, tokenId: tokenId, name: m.title, image: m.posterUrl ?? m.mediaUrl, isVideo: m.mediaType == "video") }
    }

    private func load() async {
        guard let store else { return }
        do {
            detail = try await store.momentDetail(id)
            failure = nil
        } catch {
            if !Task.isCancelled, detail == nil { failure = LiteErrorText.describe(error) }
        }
    }
}

// MARK: - Shared pieces

/// A video looping muted, filling its frame: a Moment's media over its poster. Only DyorHQ's own uploads reach it
/// (`StellarImages.video`).
struct StellarLoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var looper: AVPlayerLooper?
        private var player: AVQueuePlayer?

        func play(_ url: URL) {
            let player = AVQueuePlayer()
            player.isMuted = true
            // A looping header keeps no screen awake.
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let layer = self.layer as? AVPlayerLayer
            layer?.videoGravity = .resizeAspectFill
            layer?.player = player
            self.player = player
            player.play()
        }

        func stop() {
            player?.pause()
            looper = nil
            player = nil
        }
    }
}

/// How the Moment screens write a v2 Moment's figures: USDC and coins in base units (7 decimals), a day the creator
/// picked, an edition list.
enum StellarMomentText {
    static func usdc(_ units: Int64) -> String { StellarFormat.amount(units, code: "USDC") }

    static func usdc(_ units: String) -> String { "\(StellarFormat.units(units)) USDC" }

    static func amount(_ units: String, code: String) -> String { "\(StellarFormat.units(units)) \(code)" }

    /// Coins, compact ("1.2M $DUSK"), or the number alone while the ticker isn't known.
    static func coins(_ units: String, symbol: String?) -> String {
        let amount = StellarFormat.units(units, compact: true)
        return symbol.map { "\(amount) $\($0)" } ?? amount
    }

    static func units(_ units: String) -> String { StellarFormat.units(units, compact: true) }

    /// "#12, #13 +4": the first editions, then how many more.
    static func editions(_ numbers: [Int]) -> String {
        let shown = numbers.prefix(2).map { "#\($0)" }.joined(separator: ", ")
        return numbers.count > 2 ? "\(shown) +\(numbers.count - 2)" : shown
    }

    /// A day the creator picked ("2026-10-14"), in the app's language ("October 14, 2026").
    static func day(_ text: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: text) else { return nil }
        var style = Date.FormatStyle(date: .long, time: .omitted).locale(L10n.locale)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    /// The most editions one collect may take: the contract's limit, and at least 1 (a stepper over 1...0 would trap).
    static func collectLimit(maxPerCollect: Int?) -> Int { max(1, maxPerCollect ?? 1) }

    /// Past this long after completion, graduation is slower than the keeper usually is.
    static func isSlow(_ status: StellarMomentStatusV2, at time: Date) -> Bool {
        guard status.state == "graduation_pending", let completed = status.completedAt.flatMap(StellarFormat.date) else { return false }
        return time.timeIntervalSince(completed) >= MomentsV2Store.usualGraduation
    }

    /// Whether `expire` takes it at `time`: from `expiresAt` on (the server's own reckoning, §9.2).
    static func isExpirable(_ status: StellarMomentStatusV2, at time: Date) -> Bool {
        guard let at = status.expiresAt.flatMap(StellarFormat.date) else { return false }
        return time >= at
    }

    /// The reserve still short of the threshold, in USDC base units; nil once it's reached.
    static func remaining(_ status: StellarMomentStatusV2) -> Int64? {
        guard let threshold = Int64(status.threshold), let reserve = Int64(status.reserve), threshold > reserve else { return nil }
        return threshold - reserve
    }

    /// Whether collecting `quantity` editions completes the Moment (the contract's terminal collect: what it would put in
    /// the reserve reaches the threshold).
    static func completes(_ status: StellarMomentStatusV2, quantity: Int) -> Bool {
        guard let left = remaining(status), let price = Int64(status.price) else { return false }
        let gross = Double(price) * Double(quantity)
        return gross * Double(status.reserveBps) / 10_000 >= Double(left)
    }

    /// The FDV the coin opens at, in USDC base units: BPS·T·(BPS + r) / ((BPS − allocation)·r) (moments-v2's bundle
    /// rate, as the API's `fdvAtOpen`).
    static func fdvAtOpen(_ status: StellarMomentStatusV2) -> Int64? {
        guard let threshold = Double(status.threshold), status.reserveBps > 0, status.creatorAllocBps < 10_000 else { return nil }
        let fdv = 10_000 * threshold * Double(10_000 + status.reserveBps) / (Double(10_000 - status.creatorAllocBps) * Double(status.reserveBps))
        return fdv.isFinite && fdv < 9e18 ? Int64(fdv.rounded(.down)) : nil
    }

    /// The photo itself, when it is DyorHQ's own upload.
    static func original(_ image: String?) -> URL? {
        guard let image else { return nil }
        return LiteMediaPolicy.imageSources(image, base: LiteGate.mediaBase, renderBase: nil, pixels: nil).last
    }
}
#endif
