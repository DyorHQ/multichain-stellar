import BigInt
import DyorKit
import SwiftUI

/// One Moment: its media and provenance, where it is on the way to graduation, the collect ticket, the wallet's
/// own editions / coins / claims, the creator's proceeds and fees, the pool once it exists, and every fixed fact
/// about it. Everything reads straight from the contracts; every write is a confirmation sheet.
struct MomentDetailView: View {
    @State var info: MomentInfo
    var onChanged: () -> Void = {}
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    /// The time the page is drawn at: it moves on only when what the page shows of the time changes (`MomentPageTimes`:
    /// the window closing, a vesting cliff, a buyback coming due); the badge's countdown keeps its own
    /// (`MomentStateBadge`). Until build 23 the whole page was drawn again every second.
    @State private var clock = Clock()
    @State private var detail: MomentDetail?
    @State private var account: MomentAccountView?
    @State private var quote: CollectQuote?
    @State private var quoteReason: String?
    @State private var quantity = 1
    @State private var editionHolders: MomentEditionHolders?
    @State private var holderStats: MomentHolderStats?
    /// When the newest block the shown coin holder statistics count was made, while they are what the device kept from
    /// the last opening (`MomentsService.savedHolderStats`): the section says so ("Updated 3 min ago") until this opening's
    /// read lands.
    @State private var holderStatsSavedAt: Date?
    /// The latest read of `holderStats` failed: the last good statistics stay, and the holders section says so.
    @State private var holderStatsUnread = false
    /// The page's reads asked for after the first — Retry, an action done — which key its read (`.task(id:)`): a new one
    /// cancels the one under way, and closing the page cancels it, rather than a `Task` of its own reading on after the
    /// page closed (the coin's holders are a scan of up to 80 requests).
    @State private var reloads = 0
    /// Each part of the page whose latest read failed, and why (`load`): the header says the first, with Retry, and the
    /// part keeps what it last read.
    @State private var failures: [Part: String] = [:]
    /// The page's reads have answered once: the Share button looks the Moment's name up only then (`MomentShareButton`),
    /// so the link directory's reads never hold the page's up.
    @State private var loaded = false
    @State private var action: MomentAction?
    @Environment(\.openURL) private var openURL

    private enum MomentAction: Identifiable {
        case collect, claim, creatorProceeds, creatorFees, platformProceeds, platformFees, treasuryProceeds, retry, expire, buyback
        var id: Int { hashValue }
    }

    /// The parts of the page read on their own (`load`), in the order the header names a failure.
    private enum Part: CaseIterable {
        case moment, supply, account, editionHolders
    }

    /// The first part whose latest read failed, said in the header with Retry.
    private var loadError: String? { Part.allCases.lazy.compactMap { failures[$0] }.first }

    private var m: Moment { info.moment }
    private var now: Int { clock.now }
    private var isCreator: Bool { session.address != nil && session.address == m.creator }
    private var canCollect: Bool { info.isCollecting(at: now) }

    var body: some View {
        // A Moment of a retired cohort never reaches the collect / expire / retry / buyback / beneficiary / trade
        // controls below, nor the live service (its id names a different Moment there): it gets the claim-only page.
        if let cohort = env.retiredMoments(for: m.factory) {
            RetiredMomentDetailView(cohort: cohort, info: info, onChanged: onChanged)
        } else {
            page
        }
    }

    private var page: some View {
        List {
            headerSection
            if !info.graduated, info.state != .expired { progressSection }
            statsSection
            if canCollect { collectSection }
            if info.isRetriable { pendingSection }
            if info.state == .expired { expiredSection } else if info.isExpirable(at: now) { expirableSection }
            if let account, account.nftBalance > 0 || account.entitlement > 0 || account.coinBalance > 0 || account.claimable > 0 { positionSection(account) }
            if isCreator { creatorSection }
            if let account, account.platformProceeds > 0 || account.platformFees > 0 || account.treasuryProceeds > 0 { beneficiarySection(account) }
            if info.graduated, let pool = info.pool { poolSection(pool) }
            holdersSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(info.symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The Moment's own link (m.dyorhq.fun), which opens this page in the app; OpenSea stays a row in About.
            ToolbarItem(placement: .topBarTrailing) { MomentShareButton(info: info, ready: loaded) }
        }
        .refreshable { await load() }
        .task { await clock.run(showing: { MomentPageTimes(info, at: $0) }) }
        .task(id: reloads) { await load() }
        .task(id: "\(quantity)-\(info.ledger.reserve)-\(info.state.rawValue)") { await refreshQuote() }
        .sheet(item: $action) { which in sheet(for: which) }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // The art fills a box the row's width decides: drawn straight in a flexible frame, a filled image wider than
                // 240 pt tall allows widened the whole header past the row, cutting off the name and the badge at the left.
                Color(.tertiarySystemFill)
                    .frame(height: 240)
                    .overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.name).font(.title2.weight(.semibold)).lineLimit(2)
                        Text(verbatim: "$\(info.symbol)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    MomentStateBadge(info: info)
                    HStack(spacing: 6) {
                        if !info.provenance.place.isEmpty { Label(info.provenance.place, systemImage: "mappin.and.ellipse").lineLimit(1) }
                        if info.provenance.date > 0 { Label(MomentsFormat.day(info.provenance.date), systemImage: "calendar") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                // A part whose read failed keeps what it last showed; the first such failure is said here, with Retry.
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

    private var progressSection: some View {
        Section {
            Gauge(value: min(1, Double(info.progressBps) / 10_000)) {
                Text("Graduation")
            } currentValueLabel: {
                Text(verbatim: "\(info.progressBps / 100)%")
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(.brand)
            LabeledContent("Reserve", value: tr("\(MomentsFormat.usdcCents(info.ledger.reserve)) of \(MomentsFormat.usdcCents(m.threshold))"))
            if info.state == .collecting, now < m.deadline {
                LabeledContent("Still needed", value: tr("\(MomentsFormat.usdcCents(info.reserveRemaining)) · about \(info.collectsToGraduate) collects"))
                LabeledContent("Window closes", value: MomentsFormat.date(m.deadline))
            }
        } footer: {
            Paragraph("\(NumberStyle.basisPoints(m.reserveBps)) of every collect builds the reserve; at the threshold the coin graduates into a locked Uniswap pool.")
        }
    }

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                if info.graduated, let pool = info.pool {
                    stat(Text("Coin price", comment: "[tight] Moment stat: the coin's price"), MomentsFormat.coinPrice(pool.usdcPerCoin), spoken: MomentsFormat.coinPriceSpoken(pool.usdcPerCoin))
                    Divider().frame(height: 34)
                    stat(Text("FDV", comment: "[tight] Fully diluted valuation: a stat on a Moment's page and on its card"), MomentsFormat.fdv(pool.fdvUSD))
                    Divider().frame(height: 34)
                    stat(Text("Since open", comment: "[tight] Moment stat: the price change since the pool opened"), pool.changeSinceOpen.map { NumberStyle.percent($0) } ?? "—")
                } else {
                    stat(Text("Per edition", comment: "[tight] The price of one edition: a stat on a Moment's page and on its card"), MomentsFormat.usdc(m.price))
                    Divider().frame(height: 34)
                    // The pool opens at the collect price, so this is fixed at publish — the coin's valuation on day one.
                    stat(Text("Graduation FDV", comment: "[tight] Moment stat: the fully diluted valuation the coin graduates at"), MomentsFormat.fdv(MomentsMath.graduationFDV(threshold: m.threshold, reserveBps: m.reserveBps, creatorAllocBps: m.creatorAllocBps)))
                    Divider().frame(height: 34)
                    stat(Text("Editions", comment: "[tight] How many editions of a Moment were collected: a stat on the Moment's page and on its card"), "\(info.editions)")
                    Divider().frame(height: 34)
                    stat(Text("Collects", comment: "[tight] Moment stat: how many collects there were (a noun)"), "\(info.ledger.collects)")
                }
            }
        }
    }

    /// `label` is a `Text` so its key carries a translator's note; `spoken` is what VoiceOver reads for `value` when the
    /// two differ (a subscripted price, `PriceFormat.spoken`).
    private func stat(_ label: Text, _ value: String, spoken: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel(spoken ?? value)
            label.font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var collectSection: some View {
        Section {
            Stepper(value: $quantity, in: 1...MomentsConstants.maxBatch) {
                HStack {
                    Text("Editions")
                    Spacer()
                    Text(verbatim: "\(quantity)").monospacedDigit().fontWeight(.semibold)
                }
            }
            if let quote {
                let editions = Int(clamping: quote.editions)
                LabeledContent("You pay") { Text(MomentsFormat.usdc(quote.gross)).monospacedDigit().fontWeight(.semibold) }
                LabeledContent("You get") { Paragraph("\(editions) editions · \(MomentsFormat.coins(quote.entitlement)) $\(info.symbol)").monospacedDigit().multilineTextAlignment(.trailing) }
                if quote.terminal {
                    Label("This collect completes the Moment: it takes only what the reserve still needs (\(MomentsFormat.usdc(quote.gross)) for \(editions) editions) and graduates the coin in the same transaction.", systemImage: "sparkles")
                        .font(.footnote).foregroundStyle(Color.brand)
                }
            } else if let quoteReason {
                Paragraph(quoteReason).font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quoting…").font(.footnote).foregroundStyle(.secondary) }
            }
            if let account {
                LabeledContent("Your USDC") { Text(MomentsFormat.usdc(account.usdcBalance)).monospacedDigit().foregroundStyle(insufficient ? Color.attention : .secondary) }
            }
            if session.canSign {
                Button {
                    Haptics.tap()
                    action = .collect
                } label: {
                    Label(quote?.terminal == true ? "Collect and Graduate" : "Collect \(quantity) Editions", systemImage: "camera.aperture")
                        .fontWeight(.semibold)
                }
                .disabled(quote == nil || insufficient)
            } else {
                Text(session.address == nil ? "Sign in to collect." : "You are watching this address. Sign in to collect.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Collect", comment: "Collect (buy) editions of this Moment, a verb: the section header on the Moment's page and its button")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Paragraph("Paid in USDC: \(NumberStyle.basisPoints(m.reserveBps)) reserve, \(NumberStyle.basisPoints(m.creatorBps)) creator, \(NumberStyle.basisPoints(m.platformBps)) DyorHQ. Your NFT appears on OpenSea as soon as it settles.")
                LearnMoreLink(.collectAMoment)
            }
        }
    }

    private var insufficient: Bool {
        guard let quote, let account else { return false }
        return account.usdcBalance < quote.gross
    }

    private var pendingSection: some View {
        Section {
            Paragraph("Graduation has not completed yet; anyone can retry it.")
                .font(.footnote).foregroundStyle(.secondary)
            if info.ledger.stuckSince > 0 { LabeledContent("First failure", value: MomentsFormat.date(info.ledger.stuckSince)) }
            Button("Retry Graduation", systemImage: "arrow.clockwise") { Haptics.tap(); action = .retry }.disabled(!session.canSign)
        } header: {
            Text("Graduation Pending")
        }
    }

    private var expiredSection: some View {
        Section {
            LabeledContent("Ended", value: MomentsFormat.date(info.ledger.endedAt))
            Paragraph("The window closed before the threshold; the reserve was wound down. Editions stay with their collectors.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Expired", comment: "[tight] The Moment expired before graduating: a badge, a status and a section header")
        }
    }

    private var expirableSection: some View {
        Section {
            Text(info.state == .collecting
                 ? "The collect window closed with the reserve short of the threshold. Anyone can wind it down: \(NumberStyle.basisPoints(m.expiryCreatorBps)) of the reserve to the creator, the rest to the treasury."
                 : "Graduation has been failing for more than a week past the deadline. Anyone can wind the Moment down now.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Expire Moment", systemImage: "xmark.circle") { Haptics.tap(); action = .expire }.disabled(!session.canSign)
        } header: {
            Text("Window Closed", comment: "Section header: the collect window has closed (not a screen window)")
        }
    }

    private func positionSection(_ account: MomentAccountView) -> some View {
        Section {
            if account.nftBalance > 0 {
                LabeledContent("Editions", value: account.nftIds.isEmpty ? "\(account.nftBalance)" : account.nftIds.prefix(6).map { "#\($0)" }.joined(separator: ", ") + (account.nftIds.count > 6 ? " +\(account.nftIds.count - 6)" : ""))
                ForEach(account.nftIds.prefix(3), id: \.self) { id in
                    Link(destination: OpenSea.item(contract: m.nft, tokenId: id)) { Label("View #\(String(id)) on OpenSea", systemImage: "sailboat") }
                }
            }
            if account.entitlement > 0 { LabeledContent("Coins owed", value: "\(MomentsFormat.coins(account.entitlement)) $\(info.symbol)") }
            if info.graduated {
                LabeledContent("Claimable now") { Text(verbatim: "\(MomentsFormat.coins(account.claimable)) $\(info.symbol)").monospacedDigit().fontWeight(account.claimable > 0 ? .semibold : .regular).foregroundStyle(account.claimable > 0 ? Color.brand : .primary) }
                LabeledContent("Claimed", value: "\(MomentsFormat.coins(account.claimed)) $\(info.symbol)")
                LabeledContent("Vested", value: "\(MomentsMath.collectorVestedBps(graduatedAt: info.pool?.graduatedAt ?? 0, now: now) / 100)%")
                if account.claimable > 0 {
                    Button("Claim \(MomentsFormat.coins(account.claimable)) $\(info.symbol)", systemImage: "arrow.down.circle") { Haptics.tap(); action = .claim }.disabled(!session.canSign)
                }
            }
            if account.coinBalance > 0 {
                LabeledContent("In wallet", value: "\(MomentsFormat.coins(account.coinBalance)) $\(info.symbol)")
                if let pool = info.pool { LabeledContent("Value") { USDText(value: MomentsMath.coins(account.coinBalance) * pool.usdcPerCoin) } }
            }
        } header: {
            Text("Your Position", comment: "Section header: the wallet's editions and coins of this Moment")
        } footer: {
            // Where a collector's coins vest and are claimed.
            VStack(alignment: .leading, spacing: 4) {
                if !info.graduated, info.state != .expired { Paragraph("Coins are minted to you as they vest once the Moment graduates.") }
                LearnMoreLink(.momentsGraduationAndVesting)
            }
        }
    }

    private var creatorSection: some View {
        Section {
            LabeledContent("Proceeds to withdraw") { Text(MomentsFormat.usdc(account?.creatorProceeds ?? 0)).monospacedDigit().fontWeight((account?.creatorProceeds ?? 0) > 0 ? .semibold : .regular) }
            if (account?.creatorProceeds ?? 0) > 0 {
                Button("Withdraw Proceeds", systemImage: "banknote") { Haptics.tap(); action = .creatorProceeds }.disabled(!session.canSign)
            }
            if info.graduated {
                LabeledContent("Pool fees to withdraw") { Text(MomentsFormat.usdc(account?.creatorFees ?? 0)).monospacedDigit().fontWeight((account?.creatorFees ?? 0) > 0 ? .semibold : .regular) }
                if (account?.creatorFees ?? 0) > 0 {
                    Button("Withdraw Pool Fees", systemImage: "banknote") { Haptics.tap(); action = .creatorFees }.disabled(!session.canSign)
                }
                if let account {
                    LabeledContent("Allocation claimable") { Text(verbatim: "\(MomentsFormat.coins(account.claimableCreator)) $\(info.symbol)").monospacedDigit() }
                    LabeledContent("Allocation vested", value: "\(MomentsMath.creatorVestedBps(graduatedAt: info.pool?.graduatedAt ?? 0, now: now) / 100)%")
                }
            }
        } header: {
            Text("You Created This")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Paragraph("\(NumberStyle.basisPoints(m.creatorBps)) of every collect, plus \(NumberStyle.basisPoints(MomentsConstants.hookCreatorShareBps)) of the pool's 1% fee after graduation, accrue here for you.")
                LearnMoreLink(.momentsEarningsAndFees)
            }
        }
    }

    private func beneficiarySection(_ account: MomentAccountView) -> some View {
        Section("Protocol Beneficiary") {
            if account.platformProceeds > 0 {
                LabeledContent("Platform proceeds", value: MomentsFormat.usdc(account.platformProceeds))
                Button("Withdraw Platform Proceeds") { Haptics.tap(); action = .platformProceeds }.disabled(!session.canSign)
            }
            if account.platformFees > 0 {
                LabeledContent("Platform pool fees", value: MomentsFormat.usdc(account.platformFees))
                Button("Withdraw Platform Fees") { Haptics.tap(); action = .platformFees }.disabled(!session.canSign)
            }
            if account.treasuryProceeds > 0 {
                LabeledContent("Treasury share", value: MomentsFormat.usdc(account.treasuryProceeds))
                Button("Withdraw Treasury Share") { Haptics.tap(); action = .treasuryProceeds }.disabled(!session.canSign)
            }
        }
    }

    private func poolSection(_ pool: MomentPool) -> some View {
        Section {
            LabeledContent("Coin price") { Text(MomentsFormat.coinPrice(pool.usdcPerCoin)).accessibilityLabel(MomentsFormat.coinPriceSpoken(pool.usdcPerCoin)) }
            let opened = MomentsMath.usdcPerCoin(sqrtPriceX96: pool.openingSqrtPriceX96, usdcIs0: pool.usdcIs0)
            LabeledContent("Opened at") { Text(MomentsFormat.coinPrice(opened)).accessibilityLabel(MomentsFormat.coinPriceSpoken(opened)) }
            LabeledContent("Graduated", value: MomentsFormat.date(pool.graduatedAt))
            LabeledContent("Seeded with", value: "\(MomentsFormat.usdc(pool.reserveSeed)) + \(MomentsFormat.coins(pool.poolCoins)) $\(info.symbol)")
            LabeledContent("Position", value: tr("Full range · locked forever"))
            LabeledContent("Fees accrued", value: tr("creator \(MomentsFormat.usdc(pool.creatorFees)) · DyorHQ \(MomentsFormat.usdc(pool.platformFees)) · buyback \(MomentsFormat.usdc(pool.buybackFees))"))
            LabeledContent("Buyback budget", value: MomentsFormat.usdc(pool.buybackBudget))
            // v2: each round adds at most 0.5% of the position as liquidity; the rest waits in the locker for later rounds.
            if let held = pool.heldForLaterRounds, held > 0 {
                LabeledContent("Held for later buyback rounds", value: MomentsFormat.usdc(held))
            }
            if pool.buybackReady(at: now) {
                Button("Run Buyback", systemImage: "arrow.triangle.2.circlepath") { Haptics.tap(); action = .buyback }.disabled(!session.canSign)
            } else if pool.lastBuyback > 0 {
                LabeledContent("Last buyback", value: MomentsFormat.date(pool.lastBuyback))
            }
            if SwapEngine.isTradable(info.coinToken) {
                Button {
                    Haptics.tap()
                    router.openSwap(tokenIn: .usdc, tokenOut: info.coinToken)
                } label: {
                    Label("Trade $\(info.symbol)", systemImage: "arrow.left.arrow.right").fontWeight(.semibold)
                }
            } else {
                // A retired cohort's coin (never expected on this live-cohort page): no trade is offered.
                Label("Past cohort · trading closed", systemImage: "lock").foregroundStyle(.secondary)
            }
        } header: {
            Text("Pool", comment: "Section header: the coin's liquidity pool")
        } footer: {
            Paragraph("Liquidity locked forever in Uniswap v4. Every trade pays 1.5%: pool, creator, DyorHQ and buybacks.")
        }
    }

    private var holdersSection: some View {
        Section("Holders") {
            // "—" until read (a read that failed says so in the header, with Retry), a minimum ("+") for a Moment with more
            // editions than one read counts, whose largest holder isn't shown (`MomentEditionHolders.complete`).
            LabeledContent("Edition holders", value: editionHoldersText)
            if let editions = editionHolders, editions.complete, let top = editions.topHolder, editions.topCount > 0 {
                let count = editions.topCount
                LabeledContent("Largest", value: tr("\(top.short) · \(count) editions"))
            } else if let editions = editionHolders, !editions.complete {
                Paragraph("Counted from this Moment's earliest editions only, so there may be more holders.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if info.graduated {
                // What the device kept from the last opening shows at once, said to be, until this opening's read lands.
                if let savedAt = holderStatsSavedAt { SavedLine(date: savedAt, reading: !holderStatsUnread) }
                // A read that stopped short of the publish gives the holders as a minimum ("+", and "—" for a minimum of
                // none), and the figures only the whole history gives — the top wallet and its share, the pool's share —
                // not at all (`MomentHolderStats.complete`).
                LabeledContent("Coin holders", value: coinHoldersText)
                if let stats = holderStats, stats.complete, stats.holders > 0 {
                    LabeledContent("Top wallet", value: tr("\(stats.topHolder?.short ?? "—") · \(NumberStyle.basisPoints(stats.topHolderBps)) of circulating"))
                    LabeledContent("In the pool", value: NumberStyle.basisPoints(stats.poolBps))
                }
                if holderStatsUnread {
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: "This coin's holders couldn't be read just now.")
                        Spacer(minLength: 8)
                        Button("Retry") { reloads += 1 }.font(.footnote.weight(.semibold))
                    }
                } else if let stats = holderStats, !stats.complete {
                    // A coin older than one read reaches back (80 requests: about two weeks of a Moment's age on the widest
                    // endpoint) always gets a minimum: no failure, and no Retry that could ever do better.
                    Paragraph("Counted from this coin's most recent transfers only, so there may be more holders.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            AddressRow(title: "Creator", address: m.creator)
            LabeledContent("Published", value: MomentsFormat.date(m.publishedAt))
            LabeledContent("Collect window", value: tr("until \(MomentsFormat.date(m.deadline))"))
            LabeledContent("Split", value: tr("\(NumberStyle.basisPoints(m.reserveBps)) reserve · \(NumberStyle.basisPoints(m.creatorBps)) creator · \(NumberStyle.basisPoints(m.platformBps)) DyorHQ"))
            LabeledContent("Creator allocation", value: NumberStyle.basisPoints(m.creatorAllocBps))
            LabeledContent("NFT royalty", value: NumberStyle.basisPoints(m.royaltyBps))
            LabeledContent("Supply", value: "\(MomentsFormat.coins(MomentsConstants.supply)) $\(info.symbol)")
            if let detail {
                LabeledContent("Owed to collectors", value: tr("\(MomentsFormat.coins(detail.supply.entitlements)) · \(detail.supply.collects) collects"))
                LabeledContent("Minted so far", value: MomentsFormat.coins(detail.coinTotalSupply))
            }
            if !info.provenance.mediaHash.isEmpty, info.provenance.mediaHash.contains(where: { $0 != 0 }) {
                LabeledContent("Media hash") { Text(info.provenance.mediaHash.hexString.prefix(18) + "…").font(.footnote.monospaced()).foregroundStyle(.secondary) }
            }
            Link(destination: OpenSea.collection(contract: m.nft)) { Label("View on OpenSea", systemImage: "sailboat") }
            if let url = info.provenance.animationURL { Link(destination: url) { Label("Open video", systemImage: "play.rectangle") } }
            else if let url = info.provenance.mediaURL { Link(destination: url) { Label("Open media", systemImage: "photo") } }
            AddressRow(title: "Coin", address: m.coin)
            AddressRow(title: "NFT", address: m.nft)
        } header: {
            Text("About this Moment")
        } footer: {
            Paragraph("Fixed at publish; nothing about a live Moment can be changed.")
        }
    }

    // MARK: Sheets

    /// What collecting `quantity` editions pulls: the quoted gross, or the listed price when there's no quote yet.
    private var collectGross: BigUInt { quote?.gross ?? m.price * BigUInt(quantity) }

    @ViewBuilder private func sheet(for which: MomentAction) -> some View {
        switch which {
        case .collect:
            ConfirmationSheet(
                title: "Collect \(info.symbol)",
                confirmTitle: quote?.terminal == true ? "Collect and Graduate" : LocalizedStringResource("Collect", comment: "Collect (buy) editions of this Moment, a verb: the section header on the Moment's page and its button"),
                build: {
                    // Every account: an exact USDC approval of the collect contract, then collect. Nothing is signed when
                    // the sheet opens — the Permit2 path signed its transfer here, before Confirm and App Lock (IOST-6) —
                    // and Permit2 is never approved for unlimited USDC (IOST-14). The contract pulls at most the quoted
                    // gross, which the approval covers.
                    await env.moments.collectWithApprovalPlan(momentId: m.id, quantity: quantity, gross: collectGross, symbol: info.symbol)
                },
                onDone: { finished() },
                onCompleted: { hash in
                    // Recorded in the language in use; `section` is an identifier, never translated.
                    Activity.record(ActivityRecord(kind: .moment, title: tr("Collected \(info.name)"), subtitle: tr("\(quantity) editions · \(MomentsFormat.usdc(quote?.gross ?? m.price * BigUInt(quantity)))"), hash: hash, section: "moments", usd: MomentsMath.usdc(quote?.gross ?? m.price * BigUInt(quantity)), reference: m.id.description), owner: session.address)
                },
                // The settled sheet's View control opens the newest edition on OpenSea, where the NFT now lives.
                onView: { _ in openURL(OpenSea.item(contract: m.nft, tokenId: BigUInt((detail?.supply.collects ?? 0) + quantity))) },
                intent: .momentsCollect(pay: .init(token: env.config.moments.usdc, amount: collectGross), usd: MomentsMath.usdc(collectGross))
            ) {
                DetailRow("Moment", verbatim: "\(info.name) ($\(info.symbol))")
                DetailRow("Editions", verbatim: "\(quantity)")
                DetailRow("You pay", MomentsFormat.usdc(quote?.gross ?? m.price * BigUInt(quantity)))
                DetailRow("Coins owed", verbatim: "\(MomentsFormat.coins(quote?.entitlement ?? 0)) $\(info.symbol)")
                DetailRow("Your NFT", "On OpenSea once it settles")
                if quote?.terminal == true { DetailRow("Graduates", "Yes, in this transaction", tint: .brand) }
            }
        case .claim:
            ConfirmationSheet(title: "Claim \(info.symbol)", confirmTitle: "Claim", build: { await env.moments.claimPlan(momentId: m.id, symbol: info.symbol) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed $\(info.symbol)"), subtitle: tr("\(MomentsFormat.coins(account?.claimable ?? 0)) vested coins"), hash: hash, section: "moments", reference: m.id.description), owner: session.address) },
                              intent: .momentsClaim) {
                DetailRow("Claimable", verbatim: "\(MomentsFormat.coins(account?.claimable ?? 0)) $\(info.symbol)")
            }
        case .creatorProceeds:
            ConfirmationSheet(title: "Withdraw Proceeds", confirmTitle: "Withdraw", build: { await env.moments.withdrawCreatorProceedsPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected $\(info.symbol) proceeds"), subtitle: tr("\(MomentsFormat.usdc(account?.creatorProceeds ?? 0)) creator proceeds"), hash: hash, section: "moments", usd: MomentsMath.usdc(account?.creatorProceeds ?? 0), reference: m.id.description), owner: session.address) },
                              intent: .momentsWithdraw) {
                DetailRow("Proceeds", MomentsFormat.usdc(account?.creatorProceeds ?? 0))
            }
        case .creatorFees:
            ConfirmationSheet(title: "Withdraw Pool Fees", confirmTitle: "Withdraw", build: { await env.moments.withdrawCreatorFeesPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected $\(info.symbol) pool fees"), subtitle: tr("\(MomentsFormat.usdc(account?.creatorFees ?? 0)) trading fees"), hash: hash, section: "moments", usd: MomentsMath.usdc(account?.creatorFees ?? 0), reference: m.id.description), owner: session.address) },
                              intent: .momentsWithdraw) {
                DetailRow("Pool fees", MomentsFormat.usdc(account?.creatorFees ?? 0))
            }
        case .platformProceeds:
            ConfirmationSheet(title: "Withdraw Platform Proceeds", confirmTitle: "Withdraw", build: { await env.moments.withdrawPlatformProceedsPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected platform proceeds"), subtitle: "\(MomentsFormat.usdc(account?.platformProceeds ?? 0)) · $\(info.symbol)", hash: hash, section: "moments", usd: MomentsMath.usdc(account?.platformProceeds ?? 0), reference: m.id.description), owner: session.address) },
                              intent: .alwaysAsks(.withdrawElsewhere)) {
                DetailRow("Proceeds", MomentsFormat.usdc(account?.platformProceeds ?? 0))
            }
        case .platformFees:
            ConfirmationSheet(title: "Withdraw Platform Fees", confirmTitle: "Withdraw", build: { await env.moments.withdrawPlatformFeesPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected platform pool fees"), subtitle: "\(MomentsFormat.usdc(account?.platformFees ?? 0)) · $\(info.symbol)", hash: hash, section: "moments", usd: MomentsMath.usdc(account?.platformFees ?? 0), reference: m.id.description), owner: session.address) },
                              intent: .alwaysAsks(.withdrawElsewhere)) {
                DetailRow("Pool fees", MomentsFormat.usdc(account?.platformFees ?? 0))
            }
        case .treasuryProceeds:
            ConfirmationSheet(title: "Withdraw Treasury Share", confirmTitle: "Withdraw", build: { await env.moments.withdrawTreasuryProceedsPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected treasury share"), subtitle: "\(MomentsFormat.usdc(account?.treasuryProceeds ?? 0)) · $\(info.symbol)", hash: hash, section: "moments", usd: MomentsMath.usdc(account?.treasuryProceeds ?? 0), reference: m.id.description), owner: session.address) },
                              intent: .alwaysAsks(.withdrawElsewhere)) {
                DetailRow("Treasury share", MomentsFormat.usdc(account?.treasuryProceeds ?? 0))
            }
        case .retry:
            ConfirmationSheet(title: "Retry Graduation", confirmTitle: "Retry", build: { await env.moments.retryGraduationPlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .graduate, title: tr("Graduated $\(info.symbol)"), subtitle: tr("\(MomentsFormat.usdcCents(info.ledger.reserve)) reserve into a locked pool"), hash: hash, section: "moments", reference: m.id.description), owner: session.address) }) {
                DetailRow("Reserve", MomentsFormat.usdcCents(info.ledger.reserve))
                DetailRow("Pool", "\(MomentsFormat.usdcCents(info.ledger.reserve)) + coins, locked")
            }
        case .expire:
            ConfirmationSheet(title: "Expire Moment", confirmTitle: LocalizedStringResource("Expire", comment: "Button: wind the Moment down (a verb)"), build: { await env.moments.expirePlan(momentId: m.id) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .graduate, title: tr("Expired \(info.name)"), subtitle: tr("\(MomentsFormat.usdcCents(info.ledger.reserve)) reserve wound down"), hash: hash, section: "moments", reference: m.id.description), owner: session.address) }) {
                DetailRow("Reserve", MomentsFormat.usdcCents(info.ledger.reserve))
                DetailRow("To creator", NumberStyle.basisPoints(m.expiryCreatorBps))
                DetailRow("To treasury", NumberStyle.basisPoints(MomentsConstants.bps - m.expiryCreatorBps))
            }
        case .buyback:
            ConfirmationSheet(title: "Run Buyback", confirmTitle: LocalizedStringResource("Run", comment: "Button: run the buyback (a verb)"), build: { await env.moments.buybackPlan(momentId: m.id, minCoinOut: 0) }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .graduate, title: tr("Ran $\(info.symbol) buyback"), subtitle: tr("\(MomentsFormat.usdc(info.pool?.buybackBudget ?? 0)) into the pool"), hash: hash, section: "moments", reference: m.id.description), owner: session.address) }) {
                DetailRow("Budget", MomentsFormat.usdc(info.pool?.buybackBudget ?? 0))
                DetailRow(Text("Spends", comment: "Review row: what the buyback spends its budget on"), Text("half on coins, half paired as liquidity"))
                DetailRow("Impact cap", verbatim: "1%")
                if info.pool?.heldForLaterRounds != nil {
                    // v2's guards: a round runs at most hourly, and not when the price moved over 2% within the block.
                    DetailRow("Price check", "refused if the price moved over 2% this block")
                }
            }
        }
    }

    private func finished() {
        reloads += 1
        onChanged()
    }

    // MARK: Loading

    /// The page's reads, side by side, each part shown as its own read lands: the Moment itself, then its edition holders
    /// (as many editions as it now counts) and, once graduated, its coin's holders; its supply (`MomentsService.detail`);
    /// and the account's stake. The supply and the stake take only what is fixed at publish from the Moment the page was
    /// given, so neither waits for the Moment to be read. A part whose read fails keeps what it showed and says so
    /// (`failures`), the others still land. Until build 23 one await held every part until the slowest answered, after the
    /// Moment was read twice over, and one failure hid them all.
    private func load() async {
        async let moment: Void = loadMoment()
        async let supply: Void = loadSupply()
        async let stake: Void = loadAccount()
        _ = await (moment, supply, stake)
        if !Task.isCancelled { loaded = true }
    }

    private func loadMoment() async {
        do {
            // Only ever the same Moment (factory, id) back: the live service's id could name a different cohort's Moment.
            if let fresh = try await env.moments.info(id: m.id), fresh.key == info.key, fresh != info { info = fresh }
            failures[.moment] = nil
        } catch {
            if !Task.isCancelled { failures[.moment] = describe(error) }
        }
        async let editions: Void = loadEditionHolders()
        if info.graduated { await loadHolderStats() }
        await editions
    }

    private func loadSupply() async {
        do {
            let read = try await env.moments.detail(for: info)
            guard !Task.isCancelled else { return }
            detail = read
            failures[.supply] = nil
        } catch {
            if !Task.isCancelled { failures[.supply] = describe(error) }
        }
    }

    private func loadEditionHolders() async {
        do {
            let read = try await env.moments.editionHolders(nft: m.nft, editions: info.editions)
            guard !Task.isCancelled else { return }
            if editionHolders != read { editionHolders = read }
            failures[.editionHolders] = nil
        } catch {
            if !Task.isCancelled { failures[.editionHolders] = describe(error) }
        }
    }

    /// The edition holders as the section shows them: "—" until read, a minimum ("+") when the Moment has more editions
    /// than one read counts (`MomentEditionHolders.complete`).
    private var editionHoldersText: String {
        guard let editions = editionHolders else { return "—" }
        return editions.complete ? "\(editions.holders)" : "\(editions.holders)+"
    }

    /// The coin's holders as the section shows them: "—" until read, a minimum ("+") when not every transfer since the
    /// publish was (`MomentHolderStats.complete`), and "—" for a minimum of none, which says nothing ("0+" read as no
    /// holders).
    private var coinHoldersText: String {
        guard let stats = holderStats else { return "—" }
        if stats.complete { return "\(stats.holders)" }
        return stats.holders > 0 ? "\(stats.holders)+" : "—"
    }

    /// The coin's holder statistics (`MomentsService.holderStats`, its transfers read newest first, what was counted
    /// kept on the device so the next opening reads only what is new): what the device kept from the last opening shows at
    /// once, said to be (`holderStatsSavedAt`), until this read lands. A read that failed keeps the last good statistics,
    /// and the holders section says so, with Retry.
    private func loadHolderStats() async {
        if holderStats == nil, let saved = await env.moments.savedHolderStats(coin: m.coin) {
            holderStats = saved.stats
            holderStatsSavedAt = saved.asOf
        }
        let stats = await env.moments.holderStats(coin: m.coin, publishedAt: m.publishedAt)
        guard !Task.isCancelled else { return }
        if let stats { holderStats = stats; holderStatsSavedAt = nil }
        holderStatsUnread = stats == nil
    }

    private func loadAccount() async {
        guard let address = session.address else { account = nil; failures[.account] = nil; return }
        do {
            let read = try await env.moments.accountView(info, account: address)
            guard !Task.isCancelled, session.address == address else { return }
            account = read
            failures[.account] = nil
        } catch {
            if !Task.isCancelled { failures[.account] = describe(error) }
        }
    }

    private func refreshQuote() async {
        guard canCollect else { quote = nil; quoteReason = nil; return }
        do {
            quote = try await env.moments.quote(id: m.id, quantity: quantity)
            quoteReason = nil
        } catch {
            quote = nil
            quoteReason = describe(error)
        }
    }
}
