import BigInt
import DyorKit
import SwiftUI

/// A Moment of a retired cohort, CLAIM-ONLY: the wallet's editions and coins, its vested coins to claim, and — for the
/// creator — the creator's own proceeds and pool fees to withdraw. Cohorts 1 and 2 snapshotted the retired fee wallets;
/// cohort 3 pays the current ones and was replaced by the v2 contracts (`RetiredMoments.retirement`). Either way there is
/// no collect, expire, graduation retry, buyback, platform / treasury withdrawal or trade here; every write is a
/// `RetiredMoments.plan` against this cohort's own contracts, and every read goes to this cohort (its Moment ids overlap
/// the live cohort's).
struct RetiredMomentDetailView: View {
    let cohort: RetiredMoments
    @State var info: MomentInfo
    var onChanged: () -> Void = {}
    @Environment(Session.self) private var session
    /// The time the page is drawn at: it moves on only when what the page shows of the time changes (`MomentPageTimes`:
    /// the vested shares at the monthly cliffs, the window closing on a Moment that never graduated).
    @State private var clock = Clock()
    @State private var account: MomentAccountView?
    /// Why the latest read of the Moment, or of the account's stake in it, failed; each keeps what it last showed.
    @State private var infoError: String?
    @State private var accountError: String?
    /// The page's reads have answered once: the Share button looks the Moment's name up only then (`MomentShareButton`).
    @State private var loaded = false
    /// The page's reads asked for again (Retry), which key its read (`.task(id:)`): closing the page cancels it.
    @State private var reloads = 0
    @State private var action: RetiredMomentAction?

    private var m: Moment { info.moment }
    private var now: Int { clock.now }
    private var isCreator: Bool { session.address != nil && session.address == m.creator }

    var body: some View {
        List {
            headerSection
            noticeSection
            if let account, account.nftBalance > 0 || account.entitlement > 0 || account.coinBalance > 0 || account.claimable > 0 { positionSection(account) }
            if isCreator { creatorSection }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(info.symbol)
        .navigationBarTitleDisplayMode(.inline)
        // A retired Moment can still be shown around: its link opens this claim-only page.
        .toolbar { ToolbarItem(placement: .topBarTrailing) { MomentShareButton(info: info, ready: loaded) } }
        .refreshable { await load() }
        .task { await clock.run(showing: { MomentPageTimes(info, at: $0) }) }
        .task(id: reloads) { await load() }
        .sheet(item: $action) { which in sheet(for: which) }
    }

    // MARK: Sections

    /// The badge: its words in the app's language, its symbol and tint.
    private var status: (text: String, symbol: String, tint: Color) {
        if info.graduated || info.state == .graduated {
            return (tr(LocalizedStringResource("Graduated", comment: "[tight] A status: the coin graduated into its pool. A badge on Moments, a section of the Launch board and a date row: use a form that fits each")), "checkmark.seal.fill", .positive)
        }
        switch info.state {
        case .expired: return (tr(LocalizedStringResource("Expired", comment: "[tight] The Moment expired before graduating: a badge, a status and a section header")), "xmark.circle", .secondary)
        case .graduationPending: return (tr(LocalizedStringResource("Graduation pending", comment: "[tight] Moment badge: its graduation has not completed yet")), "hourglass", .attention)
        default: return (tr(LocalizedStringResource("Collecting closed", comment: "[tight] Moment badge: a past cohort's Moment can no longer be collected")), "lock", .secondary)
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // The art fills a box the row's width decides: drawn straight in a flexible frame, a filled image wider than
                // 240 pt tall allows widened the whole header past the row, cutting off the name and the badge at the left.
                Color(.tertiarySystemFill)
                    .frame(height: 240)
                    .overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: m.creator) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.name).font(.title2.weight(.semibold)).lineLimit(2)
                        Text(verbatim: "$\(info.symbol)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Label(status.text, systemImage: status.symbol)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(status.tint.opacity(0.14)))
                        .foregroundStyle(status.tint)
                    HStack(spacing: 6) {
                        if !info.provenance.place.isEmpty { Label(info.provenance.place, systemImage: "mappin.and.ellipse").lineLimit(1) }
                        if info.provenance.date > 0 { Label(MomentsFormat.day(info.provenance.date), systemImage: "calendar") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let loadError = infoError ?? accountError {
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

    private var noticeSection: some View {
        Section {
            Label("Past cohort — collecting closed", systemImage: "archivebox").font(.subheadline.weight(.semibold)).foregroundStyle(Color.attention)
        } footer: {
            switch cohort.retirement {
            case .retiredWallets:
                Paragraph("This Moment was published on an earlier DyorHQ Moments contract whose fee wallets have been retired. You can claim your vested coins and, as its creator, withdraw your own proceeds and pool fees; collecting, trading and every other action are closed in the app.")
            case .replaced:
                Paragraph("This Moment was published on an earlier DyorHQ Moments contract, since replaced by a new release. You can claim your vested coins and, as its creator, withdraw your own proceeds and pool fees; collecting, trading and every other action are closed in the app.")
            }
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
            if account.coinBalance > 0 { LabeledContent("In wallet", value: "\(MomentsFormat.coins(account.coinBalance)) $\(info.symbol)") }
        } header: {
            Text("Your Position", comment: "Section header: the wallet's editions and coins of this Moment")
        } footer: {
            if !info.graduated {
                if info.state == .expired {
                    Paragraph("It expired before graduating, so its coins never vest. Your editions stay yours.")
                } else if info.missedGraduation(at: now) {
                    Paragraph("Its collecting window ended before it graduated, so its coins never vest. Your editions stay yours.")
                } else {
                    Paragraph("Coins vest only once a Moment graduates; collecting is closed in the app.")
                }
            }
        }
    }

    private var creatorSection: some View {
        Section {
            LabeledContent("Proceeds to withdraw") { Text(MomentsFormat.usdc(account?.creatorProceeds ?? 0)).monospacedDigit().fontWeight((account?.creatorProceeds ?? 0) > 0 ? .semibold : .regular) }
            if (account?.creatorProceeds ?? 0) > 0 {
                Button("Withdraw Proceeds", systemImage: "banknote") { Haptics.tap(); action = .withdrawCreatorProceeds }.disabled(!session.canSign)
            }
            if info.graduated {
                LabeledContent("Pool fees to withdraw") { Text(MomentsFormat.usdc(account?.creatorFees ?? 0)).monospacedDigit().fontWeight((account?.creatorFees ?? 0) > 0 ? .semibold : .regular) }
                if (account?.creatorFees ?? 0) > 0 {
                    Button("Withdraw Pool Fees", systemImage: "banknote") { Haptics.tap(); action = .withdrawCreatorFees }.disabled(!session.canSign)
                }
                if let account {
                    LabeledContent("Allocation claimable") { Text(verbatim: "\(MomentsFormat.coins(account.claimableCreator)) $\(info.symbol)").monospacedDigit() }
                    LabeledContent("Allocation vested", value: "\(MomentsMath.creatorVestedBps(graduatedAt: info.pool?.graduatedAt ?? 0, now: now) / 100)%")
                }
            }
        } header: {
            Text("You Created This")
        } footer: {
            Paragraph("Withdrawals pay you, the creator, and no one else.")
        }
    }

    private var aboutSection: some View {
        Section {
            AddressRow(title: "Creator", address: m.creator)
            LabeledContent("Published", value: MomentsFormat.date(m.publishedAt))
            Link(destination: OpenSea.collection(contract: m.nft)) { Label("View on OpenSea", systemImage: "sailboat") }
            AddressRow(title: "Coin", address: m.coin)
            AddressRow(title: "NFT", address: m.nft)
            AddressRow(title: "Cohort", address: cohort.factory)
        } header: {
            Text("About this Moment")
        }
    }

    // MARK: Sheets — the only writes: `RetiredMomentAction`

    /// Each settled write is recorded in the language in use; `section` is an identifier, never translated.
    @ViewBuilder private func sheet(for which: RetiredMomentAction) -> some View {
        let plan = cohort.plan(which, momentId: m.id, symbol: info.symbol)
        switch which {
        case .claim:
            ConfirmationSheet(title: "Claim \(info.symbol)", confirmTitle: "Claim", build: { plan }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed $\(info.symbol)"), subtitle: tr("\(MomentsFormat.coins(account?.claimable ?? 0)) vested coins · past cohort"), hash: hash, section: "moments", reference: info.key.description), owner: session.address) },
                              intent: .momentsClaim) {
                DetailRow("Claimable", verbatim: "\(MomentsFormat.coins(account?.claimable ?? 0)) $\(info.symbol)")
            }
        case .withdrawCreatorProceeds:
            ConfirmationSheet(title: "Withdraw Proceeds", confirmTitle: "Withdraw", build: { plan }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected $\(info.symbol) proceeds"), subtitle: tr("\(MomentsFormat.usdc(account?.creatorProceeds ?? 0)) creator proceeds · past cohort"), hash: hash, section: "moments", usd: MomentsMath.usdc(account?.creatorProceeds ?? 0), reference: info.key.description), owner: session.address) },
                              intent: .momentsWithdraw) {
                DetailRow("Proceeds", MomentsFormat.usdc(account?.creatorProceeds ?? 0))
            }
        case .withdrawCreatorFees:
            ConfirmationSheet(title: "Withdraw Pool Fees", confirmTitle: "Withdraw", build: { plan }, onDone: { finished() },
                              onCompleted: { hash in Activity.record(ActivityRecord(kind: .fees, title: tr("Collected $\(info.symbol) pool fees"), subtitle: tr("\(MomentsFormat.usdc(account?.creatorFees ?? 0)) trading fees · past cohort"), hash: hash, section: "moments", usd: MomentsMath.usdc(account?.creatorFees ?? 0), reference: info.key.description), owner: session.address) },
                              intent: .momentsWithdraw) {
                DetailRow("Pool fees", MomentsFormat.usdc(account?.creatorFees ?? 0))
            }
        }
    }

    private func finished() {
        Task {
            await load()
            onChanged()
        }
    }

    // MARK: Loading (this cohort only)

    /// The Moment and the account's stake in it, side by side, each shown as it lands: the stake takes only what is fixed
    /// at publish from the Moment the page was given (`RetiredMoments.accountView`). Until build 23 the stake was read
    /// after the Moment, and one failure hid both.
    private func load() async {
        async let moment: Void = loadMoment()
        async let stake: Void = loadAccount()
        _ = await (moment, stake)
        if !Task.isCancelled { loaded = true }
    }

    private func loadMoment() async {
        do {
            if let fresh = try await cohort.info(id: m.id), fresh.key == info.key, fresh != info { info = fresh }
            infoError = nil
        } catch {
            if !Task.isCancelled { infoError = describe(error) }
        }
    }

    private func loadAccount() async {
        guard let address = session.address else { account = nil; accountError = nil; return }
        do {
            let read = try await cohort.accountView(info, account: address)
            guard !Task.isCancelled, session.address == address else { return }
            account = read
            accountError = nil
        } catch {
            if !Task.isCancelled { accountError = describe(error) }
        }
    }
}
