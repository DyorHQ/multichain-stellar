import BigInt
import DyorKit
import SwiftUI

/// My Moments: every Moment the wallet has a stake in — editions collected, coins promised, claimable now, still
/// vesting, claimed — with one Claim All for everything vested. Moments of the retired cohorts follow as Past Cohorts:
/// outside the totals and Claim All, each opens its own claim-only page.
///
/// Every Moment is checked, from the list the screens share (`MomentsService.moments(limit:)`, its newest
/// `MomentsService.listingLimit`, as Home and the Portfolio check them): until build 23 it checked the board's newest 60,
/// and the board's saved copy while the board showed one. Each cohort's list is read once for the screen: the positions,
/// the past cohorts and the proceeds all take theirs from it.
struct MomentsPortfolioView: View {
    let onOpen: (MomentInfo) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var portfolio: MomentPortfolio?
    @State private var error: String?
    @State private var showClaimAll = false
    @State private var past = PastMomentsModel()
    /// The USDC the wallet earned from the Moments it published, in every cohort (`MomentsService.creatorEarnings`).
    @State private var earnings: MomentsCreatorEarnings?
    @State private var earningsError: String?

    var body: some View {
        NavigationStack {
            List {
                if let portfolio {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            tile(Text("Pending", comment: "[tight] My Moments tile: coins promised, not graduated yet"), portfolio.pending,
                                 Text("promised, not graduated yet", comment: "[tight] My Moments tile, under the amount"))
                            tile(Text("Claimable now", comment: "[tight] My Moments tile: vested coins to claim"), portfolio.claimable,
                                 Text("vested and unclaimed", comment: "[tight] My Moments tile, under the amount"), tint: portfolio.claimable > 0 ? .brand : .primary)
                            tile(Text("Still vesting", comment: "[tight] My Moments tile: coins not vested yet"), portfolio.vesting,
                                 Text("unlocks at the monthly cliffs", comment: "[tight] My Moments tile, under the amount"))
                            tile(Text("Claimed", comment: "[tight] Already claimed: coins on My Moments and a Moment's page, fees and rewards on Portfolio"), portfolio.claimed,
                                 Text("already in your wallet", comment: "[tight] My Moments tile, under the amount"))
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        if portfolio.claimable > 0 {
                            Button("Claim All", systemImage: "arrow.down.circle.fill") { Haptics.tap(); showClaimAll = true }
                                .fontWeight(.semibold)
                                .disabled(!session.canSign)
                        }
                    } footer: {
                        Paragraph("Coins across every Moment. Vesting unlocks at the monthly cliffs.")
                    }
                    proceedsSection
                    if portfolio.rows.isEmpty {
                        if past.positions.isEmpty {
                            ContentUnavailableView {
                                Label("No Moments Yet", systemImage: "camera.aperture")
                            } description: {
                                Paragraph("Collect a Moment and it shows up here with its editions and coins.")
                            } actions: {
                                Button("Browse Moments") { Haptics.tap(); dismiss() }
                            }
                        }
                    } else {
                        Section("Your Moments") {
                            ForEach(portfolio.rows) { row in
                                Button { Haptics.tap(); onOpen(row.moment) } label: { PortfolioRowView(row: row) }.buttonStyle(.plain)
                            }
                        }
                    }
                } else if let error {
                    InlineError(message: error)
                    proceedsSection
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your Moments…").foregroundStyle(.secondary) }
                    proceedsSection
                }
                if !past.positions.isEmpty || past.error != nil || past.incomplete != nil {
                    Section {
                        if let error = past.error { InlineError(message: "Couldn't read every past cohort (pull to refresh): \(error)") }
                        if let incomplete = past.incomplete { InlineError(message: incomplete) }
                        ForEach(past.positions) { position in
                            Button { Haptics.tap(); onOpen(position.info) } label: { PastMomentRow(position: position) }.buttonStyle(.plain)
                        }
                    } header: {
                        Text("Past Cohorts")
                    } footer: {
                        Paragraph("Earlier DyorHQ Moments contracts. Collecting is closed; claim your vested coins and, as a creator, withdraw your own proceeds.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("My Moments"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // A pull awaits the screen's own reads only: the history reads on behind it (`HistoryModel.kick`), and the
            // proceeds follow it. The reads the screens share are read again first (`invalidateChainReads`).
            .refreshable {
                env.invalidateChainReads()
                env.history.kick(env: env)
                await load()
            }
            .task { await loadPositions() }
            // The proceeds, read on opening and again whenever the wallet's Moments history moves (`HistoryModel`): its own
            // scan, not every scan's rounds, and once on opening rather than twice (until build 23 the opening read ran
            // beside this one).
            .task(id: env.history.snapshot.status(WalletHistoryScans.momentsId)) { await loadEarnings() }
            .sheet(isPresented: $showClaimAll) {
                ConfirmationSheet(title: "Claim All", confirmTitle: "Claim All", build: { await env.moments.claimAllPlan(momentIds: portfolio?.claimableIds ?? []) }, onDone: { Task { await load() } },
                                  // Recorded in the language in use; `section` is an identifier, never translated.
                                  onCompleted: { hash in Activity.record(ActivityRecord(kind: .claim, title: tr("Claimed vested coins"), subtitle: tr("across \(portfolio?.claimableIds.count ?? 0) Moments"), hash: hash, section: "moments"), owner: session.address) },
                                  intent: .momentsClaim) {
                    ForEach(portfolio?.rows.filter { $0.moment.graduated && $0.claimable > 0 } ?? []) { row in
                        DetailRow(Text(verbatim: "$\(row.moment.symbol)"), Text(verbatim: MomentsFormat.coins(row.claimable)))
                    }
                }
            }
        }
    }

    /// `title` and `subtitle` are `Text`s so their keys carry a translator's note: both are tight.
    private func tile(_ title: Text, _ coins: BigUInt, _ subtitle: Text, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(MomentsFormat.coins(coins)).font(.headline).monospacedDigit().foregroundStyle(tint)
            subtitle.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Proceeds, for a wallet that published a Moment in any cohort: its share of every collect (From collectors) and of
    /// trading fees after graduation, split into what it withdrew (Claimed) and what the contracts still hold for it
    /// (Unclaimed, withdrawn on each Moment's page). Both pairs add up to the same USDC.
    @ViewBuilder private var proceedsSection: some View {
        if let earnings, !earnings.complete, !earnings.moments.isEmpty || !proceedsReading {
            // The Moments history hasn't been read to the head: a total is never shown in part. While the history is
            // still filling in it says how far it has got; stalled or unreachable, it says so, with a pull to retry.
            Section {
                if proceedsReading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading your history… \(NumberStyle.percent(proceedsProgress * 100, fractionDigits: 0, signed: false))").foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    InlineError(message: "Part of your proceeds couldn't be read just now. Pull to refresh.")
                }
            } header: {
                Text("Proceeds")
            }
        } else if let earnings, earnings.complete {
            // Shown once the history is read, zeros included, so a creator always finds it.
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    usdcTile(Text("From collectors", comment: "[tight] My Moments tile: the creator's share of the collects of the Moments it published, in USDC"), earnings.fromCollectors,
                             Text("your share of collects", comment: "[tight] My Moments tile, under the amount of From collectors"))
                    usdcTile(Text("Trading fees", comment: "[tight] My Moments tile: the creator's share of a graduated Moment's pool trading fees, in USDC"), earnings.tradingFees,
                             Text("after graduation", comment: "[tight] My Moments tile, under the amount of Trading fees"))
                    usdcTile(Text("Claimed", comment: "[tight] Already claimed: coins on My Moments and a Moment's page, fees and rewards on Portfolio"), earnings.claimed,
                             Text("already in your wallet", comment: "[tight] My Moments tile, under the amount"))
                    usdcTile(Text("Unclaimed", comment: "[tight] My Moments tile: USDC the Moments' contracts still hold for their creator, to withdraw"), earnings.unclaimed,
                             Text("on each Moment's page", comment: "[tight] My Moments tile, under the amount of Unclaimed: where it is withdrawn"),
                             tint: earnings.unclaimed > 0 ? .brand : .primary)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Proceeds")
            } footer: {
                Paragraph("Your USDC from the Moments you published, in every cohort: your share of each collect, and of trading fees once a Moment graduates. Withdraw what is unclaimed on each Moment's page.")
            }
        } else if let earningsError {
            Section {
                InlineError(message: earningsError)
            } header: {
                Text("Proceeds")
            }
        } else {
            // The history is still filling in (nothing published found yet), or the balances are being read.
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if proceedsReading {
                        Text("Reading your history… \(NumberStyle.percent(proceedsProgress * 100, fractionDigits: 0, signed: false))").foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Reading your Moments…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Proceeds")
            }
        }
    }

    /// The Moments scan of the wallet's history, the proceeds' only source (`WalletHistoryScans.proceeds`), is still
    /// reading its window with the chain reachable: no other scan holds the proceeds up.
    private var proceedsReading: Bool { env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.proceeds) }
    /// How far the Moments scan has read its window, 0 to 1.
    private var proceedsProgress: Double { env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.proceeds) }

    /// A USDC amount's tile, rounded to the cent, in the coin tiles' style.
    private func usdcTile(_ title: Text, _ units: BigUInt, _ subtitle: Text, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title.font(.caption).foregroundStyle(.secondary)
            Text(verbatim: MomentsFormat.usdcCents(units)).font(.headline).monospacedDigit().foregroundStyle(tint)
            subtitle.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Everything on the screen, read again (a pull, a Claim All done): the positions and the proceeds side by side.
    private func load() async {
        async let positions: () = loadPositions()
        async let earningsLoad: () = loadEarnings()
        _ = await (positions, earningsLoad)
    }

    /// The live cohort's positions and the past cohorts', side by side.
    private func loadPositions() async {
        async let live: () = loadLive()
        async let pastLoad: () = past.load(env: env, address: session.address, force: true)
        _ = await (live, pastLoad)
    }

    /// The proceeds of every cohort, read together: the live cohort's and each retired one's, each from the wallet's
    /// Moments history as the history model has it (no scan of its own) and what the contracts still hold for it, taken
    /// from the cohort's list the screen reads anyway (the list the screens share, a past cohort's `list`), which the
    /// positions read at the same time share. Only a Moment it published that isn't in the list is read on its own; a list
    /// that can't be read leaves every one to be read so. A cohort whose history isn't read to the head leaves nothing
    /// shown in part: the section says how far the history has got.
    private func loadEarnings() async {
        guard let address = session.address else { earnings = nil; earningsError = nil; return }
        let cohorts = env.retiredMoments
        do {
            async let liveLogsRead = env.walletHistory.momentsLogs(wallet: address, cohort: env.config.moments)
            async let liveListRead = env.moments.moments(limit: MomentsService.listingLimit)
            let liveLogs = await liveLogsRead
            let liveList = (try? await liveListRead) ?? []
            async let live = env.moments.creatorEarnings(account: address, published: liveLogs.published, withdrawn: liveLogs.withdrawn, feesWithdrawn: liveLogs.feesWithdrawn,
                                                         complete: liveLogs.complete, known: liveList)
            let retired = try await withThrowingTaskGroup(of: MomentsCreatorEarnings.self) { group in
                for cohort in cohorts {
                    group.addTask {
                        async let logsRead = env.walletHistory.momentsLogs(wallet: address, cohort: cohort.cohort)
                        async let listRead = cohort.moments()
                        let logs = await logsRead
                        let list = (try? await listRead) ?? []
                        return try await cohort.creatorEarnings(account: address, published: logs.published, withdrawn: logs.withdrawn, feesWithdrawn: logs.feesWithdrawn, complete: logs.complete,
                                                                known: list)
                    }
                }
                var all = MomentsCreatorEarnings.none
                for try await read in group { all = all + read }
                return all
            }
            let all = try await live + retired
            guard session.address == address else { return }
            earnings = all
            earningsError = nil
        } catch is CancellationError {
            return
        } catch {
            guard session.address == address else { return }
            earnings = nil
            earningsError = tr("Your proceeds couldn't be read just now: \(describe(error))")
        }
    }

    /// The live cohort's positions, over the list the screens share (`MomentsService.listingLimit` Moments, newest first).
    private func loadLive() async {
        guard let address = session.address else { portfolio = .empty; return }
        do {
            portfolio = try await env.moments.portfolio(account: address, moments: try await env.moments.moments(limit: MomentsService.listingLimit))
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

private struct PortfolioRowView: View {
    let row: MomentPortfolioRow

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: row.moment.provenance, symbol: row.moment.symbol, creator: row.moment.moment.creator)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.moment.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(row.moment.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                summary.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.moment.graduated ? MomentsFormat.coins(row.claimable) : MomentsFormat.coins(row.entitlement)).font(.subheadline.weight(.semibold)).monospacedDigit()
                status.font(.caption2).foregroundStyle(row.moment.graduated && row.claimable > 0 ? Color.brand : .secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The row's editions and coins, one sentence (with "· creator" for its creator).
    private var summary: Text {
        let promised = MomentsFormat.coins(row.entitlement), claimed = MomentsFormat.coins(row.claimed), held = MomentsFormat.coins(row.coinBalance)
        return row.isCreator
            ? Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held) · creator")
            : Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held)")
    }

    /// What the amount on the right is.
    private var status: Text {
        if row.moment.graduated { return Text("claimable", comment: "[tight] My Moments row, under an amount of coins: they can be claimed now") }
        if row.moment.state == .expired { return Text("expired", comment: "[tight] My Moments row, under an amount of coins: the Moment expired") }
        return Text("pending", comment: "[tight] My Moments row, under an amount of coins: promised, the Moment has not graduated")
    }
}
