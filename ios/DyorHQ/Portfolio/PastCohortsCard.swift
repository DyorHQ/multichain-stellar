import BigInt
import DyorKit
import SwiftUI

/// A retired-cohort Moment the Portfolio pushes. Moment ids restart at 1 on every factory, so the navigation identity
/// is the (factory, id) key, never the id — a cohort-1 "#2" can never open cohort 3's #2.
struct PastMomentRoute: Hashable {
    let info: MomentInfo
    var key: MomentKey { info.key }

    static func == (a: PastMomentRoute, b: PastMomentRoute) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// The wallet's Moments on the retired cohorts that still hold something for it (coins to claim or vesting, creator
/// proceeds or pool fees, editions or coins), read from each cohort's own contracts.
@Observable
@MainActor
final class PastMomentsModel {
    private(set) var positions: [RetiredMomentPosition] = []
    private(set) var loading = false
    private(set) var error: String?
    /// Said when a past cohort has more Moments than the app reads at once (`RetiredMoments.list` was cut): its
    /// positions then come from the Moments read and the wallet's own history, which a Moment it only received by
    /// transfer is not in.
    private(set) var incomplete: String?
    private(set) var loadedFor: Address?
    /// The wallet the latest load is for: a slower load for a wallet signed out since never lands.
    private var requested: Address?

    func load(env: AppEnvironment, address: Address?, force: Bool) async {
        requested = address
        guard let address else { positions = []; error = nil; incomplete = nil; loadedFor = nil; loading = false; return }
        if !force, loadedFor == address { return }
        if loadedFor != address { positions = []; incomplete = nil }
        loading = true
        defer { if requested == address { loading = false } }
        var found: [RetiredMomentPosition] = []
        var failure: String?
        var cut = false
        // A cohort's list cut short is completed from the wallet's own Moments history: the history store's, which scans
        // every cohort for it already (`WalletHistoryScans.moments`), once it is read in full; until then each cohort scans
        // its own, newest first (`RetiredMoments.positions`).
        let snapshot = env.history.snapshot
        let history = env.history.wallet == address && snapshot.status(WalletHistoryScans.momentsId).complete ? snapshot.moments : nil
        // The cohorts side by side, kept in their order: each one's list is shared with the Portfolio's and My Holdings'
        // reads, and its Moments' records and text are kept on the device (`RetiredMoments`), so only what moves is read.
        let cohorts = env.retiredMoments
        let reads = await withTaskGroup(of: (Int, [RetiredMomentPosition], Bool, (any Error)?).self) { group in
            for (i, cohort) in cohorts.enumerated() {
                group.addTask {
                    do {
                        let read = try await cohort.positions(account: address, history: history)
                        return (i, read.positions, read.complete, nil)
                    } catch {
                        return (i, [], true, error)
                    }
                }
            }
            var out = [(positions: [RetiredMomentPosition], complete: Bool, error: (any Error)?)](repeating: ([], true, nil), count: cohorts.count)
            for await (i, positions, complete, error) in group { out[i] = (positions, complete, error) }
            return out
        }
        for (cohort, read) in zip(cohorts, reads) {
            if let error = read.error {
                // Keep what this cohort showed before rather than dropping a claim on a transient read failure.
                failure = describe(error)
                found += positions.filter { $0.key.factory == cohort.factory }
            } else {
                found += read.positions
                if !read.complete { cut = true }
            }
        }
        guard requested == address else { return }
        positions = found
        error = failure
        incomplete = cut ? tr("A past cohort has more Moments than the app reads at once, so one of yours may be missing here.") : nil
        loadedFor = address
    }

    /// Every Moment of every retired cohort, and whether every cohort was read (`RetiredMoments.moments(of:keeping:)`):
    /// a cohort that can't be read keeps its Moments from `previous` and makes `complete` false, for the caller to say.
    static func allMoments(env: AppEnvironment, keeping previous: [MomentInfo] = []) async -> (moments: [MomentInfo], complete: Bool) {
        await RetiredMoments.moments(of: env.retiredMoments, keeping: previous)
    }
}

/// Past cohorts on the Portfolio: shown when the wallet has something on a retired cohort, or when a cohort could not
/// be read, or not in full (a claim is never hidden behind a failed or partial read). Each row opens the Moment's
/// claim-only page; collecting and trading are closed there.
struct PastCohortsCard: View {
    let model: PastMomentsModel

    var body: some View {
        if !model.positions.isEmpty || model.error != nil || model.incomplete != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Past Cohorts").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                Paragraph("Moments from earlier DyorHQ contracts. Collecting is closed; claim your vested coins and, as a creator, withdraw your own proceeds.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.error { InlineError(message: "Couldn't read every past cohort (pull to refresh): \(error)") }
                if let incomplete = model.incomplete { InlineError(message: incomplete) }
                VStack(spacing: 0) {
                    ForEach(Array(model.positions.enumerated()), id: \.element.id) { index, position in
                        NavigationLink(value: PastMomentRoute(info: position.info)) { PastMomentRow(position: position) }
                            .buttonStyle(.plain)
                        if index < model.positions.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
            .padding(16)
            .cardBackground()
        }
    }
}

/// One retired-cohort Moment the wallet has something in (the Portfolio's Past Cohorts card and My Moments).
struct PastMomentRow: View {
    let position: RetiredMomentPosition

    private var info: MomentInfo { position.info }

    private var summary: String {
        var parts: [String] = []
        if position.row.nftBalance > 0 { parts.append(tr("\(position.row.nftBalance) editions")) }
        if position.row.isCreator { parts.append(tr(LocalizedStringResource("creator", comment: "Among a Moment's summary parts: you published it"))) }
        if info.graduated, position.row.vesting > 0 { parts.append(tr("\(MomentsFormat.coins(position.row.vesting)) vesting")) }
        if position.row.coinBalance > 0 { parts.append(tr("\(MomentsFormat.coins(position.row.coinBalance)) in wallet")) }
        return parts.isEmpty ? tr("Collecting closed") : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: info.moment.creator)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(verbatim: "$\(info.symbol)").font(.caption).foregroundStyle(.secondary)
                }
                Paragraph(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if position.claimable > 0 {
                    Text(MomentsFormat.coins(position.claimable)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Color.brand)
                    Text("claimable").font(.caption2).foregroundStyle(Color.brand)
                } else if position.creatorWithdrawable > 0 {
                    Text(MomentsFormat.usdc(position.creatorWithdrawable)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("to withdraw").font(.caption2).foregroundStyle(.secondary)
                } else {
                    (info.graduated ? Text("Graduated") : info.state == .expired ? Text("Expired")
                        : Text(verbatim: tr(LocalizedStringResource("pastCohort.closed", defaultValue: "Closed", comment: "[tight] A past cohort Moment's status when it neither graduated nor expired: collecting it is closed in the app"))))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
