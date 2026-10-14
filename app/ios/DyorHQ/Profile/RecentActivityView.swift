import BigInt
import DyorKit
import SwiftUI

/// A unified, in-app feed of everything the wallet does across DyorHQ — launches, curve buys/sells, swaps and perp
/// orders — newest first, each linking to its transaction on Monadscan. It merges the local action log (the only
/// source for perps, and the freshest rows) with on-chain scans that backfill launchpad and swap history.
struct RecentActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var model = RecentActivityModel()

    var body: some View {
        List {
            if model.items.isEmpty {
                if model.loading || model.historyFilling {
                    // Nothing recorded here yet, and the chain history still being read: how far it has got, never
                    // "No Activity Yet" ahead of it.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if model.loading {
                            Text("Loading activity…").foregroundStyle(.secondary)
                        } else {
                            Text("Reading your history… \(NumberStyle.percent(model.historyProgress * 100, fractionDigits: 0, signed: false))").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } else if let incomplete = model.incomplete ?? model.historyUnread {
                    // Nothing to show because part of it couldn't be read: the error, with Retry, never "No Activity Yet".
                    HStack(alignment: .firstTextBaseline) {
                        InlineError(message: incomplete)
                        Spacer(minLength: 8)
                        Button("Retry") { env.history.kick(env: env); Task { await model.load(env: env, address: session.address) } }.font(.footnote.weight(.semibold))
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Activity Yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Paragraph("Your launches, swaps, buys, sells and perp orders show up here.")
                    } actions: {
                        Button("Start Trading") { Haptics.tap(); router.presented = nil; router.tradeMode = .swap; router.tab = .trade }
                    }
                }
            } else {
                if let incomplete = model.incomplete ?? model.historyUnread { InlineError(message: incomplete) }
                Section {
                    if model.historyFilling {
                        // Older rows from the chain join the list as the history fills in.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading your history… \(NumberStyle.percent(model.historyProgress * 100, fractionDigits: 0, signed: false))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    ForEach(model.items) { RecentActivityRow(item: $0) }
                } footer: {
                    if let address = session.address {
                        Link(destination: Monad.explorerAddress(address)) { Label("Open full history on Monadscan", systemImage: "safari") }.font(.footnote)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(tr("Recent Activity"))
        .navigationBarTitleDisplayMode(.inline)
        // A pull awaits the screen's own reads only: the history reads on behind it (`HistoryModel.kick`), and the
        // backfill follows it. The reads the screens share are read again first (`invalidateChainReads`).
        .refreshable {
            env.invalidateChainReads()
            env.history.kick(env: env)
            await model.load(env: env, address: session.address)
        }
        .task(id: session.address) { await model.load(env: env, address: session.address) }
        // The history fills in behind the screen (`HistoryModel`): the backfill follows it.
        .task(id: env.history.version) { model.applyHistory(env.history.snapshot, address: session.address) }
    }
}

/// One row in the feed.
struct FeedItem: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let time: Date
    let hash: Data?
}

private struct RecentActivityRow: View {
    let item: FeedItem

    var body: some View {
        Group {
            if let hash = item.hash {
                Link(destination: Monad.explorerTransaction(hash)) { content }.foregroundStyle(.primary)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.footnote.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Color.brand.opacity(0.14), in: Circle())
                .foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.medium))
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(RelativeTime.short(Int(item.time.timeIntervalSince1970))) ago").font(.caption2).foregroundStyle(.tertiary)
                if item.hash != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .contentShape(Rectangle())
    }
}

@Observable
@MainActor
final class RecentActivityModel {
    private(set) var items: [FeedItem] = []
    private(set) var loading = false
    /// Said when part of the launchpad activity couldn't be read (a launchpad's launches, or the activity scan): the
    /// rows last read stay, and the feed says it may be missing some.
    private(set) var incomplete: String?
    /// Said when the chain history couldn't be read to the head (unreachable, or rounds of reading stopped short):
    /// the rows it gave stay, and the feed says it may be missing some.
    private(set) var historyUnread: String?
    /// The last week of the chain history, in the scans the feed shows (`WalletHistoryScans.activity`), is still being
    /// read, and how far it has got (0 to 1): older blocks the feed never shows don't hold it up.
    private(set) var historyFilling = false
    private(set) var historyProgress = 0.0
    /// The wallet the kept launches and launchpad activity were read for: another wallet starts from nothing.
    private var keptFor: Address?
    /// The last launches read, which a launchpad that can't be read now keeps (`LaunchListing.keeping`).
    private var lastLaunches: [Launch] = []
    /// The wallet's launchpad activity last read, which a failed activity read keeps.
    private var lastActivity: [ActivityItem] = []
    /// Counts loads: only the newest one publishes what it read, so a slower load (for a wallet no longer shown, or a
    /// pull to refresh overtaken by another) never overwrites a newer one.
    private var loads = 0

    func load(env: AppEnvironment, address: Address?) async {
        loads += 1
        let load = loads
        // Whether this load may still publish: it is the newest, and not cancelled (the screen closed mid-load; reads cut
        // short that way aren't failures to show).
        func current() -> Bool { load == loads && !Task.isCancelled }
        guard let address else {
            items = []; incomplete = nil; historyUnread = nil; historyFilling = false; historyProgress = 0; keptFor = nil; lastLaunches = []; lastActivity = []; loading = false
            return
        }
        if keptFor != address { items = []; incomplete = nil; historyUnread = nil; historyFilling = false; historyProgress = 0; lastLaunches = []; lastActivity = []; keptFor = address }
        loading = true
        defer { if load == loads { loading = false } }
        let tokenMap = Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        // The actions recorded on this device show at once; the on-chain backfill joins them below.
        let byToken = Dictionary(lastLaunches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        items = Self.merge(ActivityLog.all(owner: address), lpActivity: lastActivity, byToken: byToken, swaps: [], tokens: tokenMap)
        // Pending rows are re-checked beside the launch read, not ahead of it (each can wait on the RPC); the feed is
        // built once the launches answer, and again once they are settled.
        async let rechecked: Void = PendingActivity.recheck(owner: address, rpc: env.rpc)
        // A launchpad whose launches couldn't be read keeps its last good ones: the feed says it is incomplete rather than
        // show less as if that were all.
        let listing = await env.launchpad.launchListing(limit: 60)
        guard current() else { await rechecked; return }
        let launches = listing.keeping(lastLaunches)
        lastLaunches = launches
        incomplete = listing.complete ? nil : tr("Some launchpad activity couldn't be read just now. Pull to refresh.")
        applyHistory(env.history.snapshot, address: address, tokens: tokenMap)
        await rechecked
        guard current() else { return }
        applyHistory(env.history.snapshot, address: address, tokens: tokenMap)
    }

    /// The on-chain backfill from the wallet's history as the history model has it (`HistoryModel`, no scan of its own):
    /// the launchpad fills, and the swaps, over the last week, and how far the history has read that week. Called
    /// whenever `HistoryModel.version` moves, and by `load`.
    func applyHistory(_ snapshot: WalletHistorySnapshot, address: Address?, tokens: [Address: Token]? = nil) {
        guard let address, keptFor == address else { return }
        let since = Date().addingTimeInterval(-SwapHistoryService.Window.week.seconds)
        historyFilling = snapshot.filling(since: since, scans: WalletHistoryScans.activity)
        historyProgress = snapshot.progress(since: since, scans: WalletHistoryScans.activity)
        historyUnread = snapshot.unreachable ? tr("Part of your history couldn't be read just now, so some activity may be missing. Pull to refresh.") : nil
        let tokenMap = tokens ?? Dictionary(KnownTokenStore.universe(owner: address).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let byToken = Dictionary(lastLaunches.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        let byCurve = Dictionary(lastLaunches.map { ($0.curve, $0) }, uniquingKeysWith: { first, _ in first })
        let fills = snapshot.launch.fills.filter { $0.time >= since }.compactMap { fill -> ActivityItem? in
            guard let launch = byCurve[fill.curve] else { return nil }
            return ActivityItem(id: fill.id, block: fill.block, logIndex: fill.logIndex, time: Int(fill.time.timeIntervalSince1970), transactionHash: fill.hash,
                                kind: .trade(token: launch.token, curve: fill.curve, trader: address, isBuy: fill.isBuy, quoteAmount: fill.quoteAmount, tokenAmount: fill.tokenAmount))
        }
        lastActivity = fills
        items = Self.merge(ActivityLog.all(owner: address), lpActivity: fills, byToken: byToken, swaps: snapshot.swaps.filter { $0.time >= since }, tokens: tokenMap)
    }

    /// The feed, newest first: the actions recorded here — typed, exact, and the only source for perps — then the
    /// on-chain backfill, then the rows `PendingActivity` wrote for sent transactions, each only where nothing else has
    /// its hash: a typed backfill row ("Swapped 10 USDC → 3 MON") says more than "Swap on Uniswap v4 · Confirmed".
    private static func merge(_ records: [ActivityRecord], lpActivity: [ActivityItem], byToken: [Address: Launch], swaps: [SwapRecord],
                              tokens: [Address: Token]) -> [FeedItem] {
        var out: [FeedItem] = []
        var seen = Set<String>()
        func add(_ record: ActivityRecord, icon: String) {
            let key = record.txHashHex ?? record.id.uuidString
            guard seen.insert(key).inserted else { return }
            out.append(FeedItem(id: key, icon: icon, title: record.title, subtitle: record.subtitle, time: record.time, hash: record.txHash))
        }
        for record in records where record.status == nil { add(record, icon: record.kind.symbol) }
        // Launchpad on-chain backfill (launches, buys, sells by this wallet).
        for activity in lpActivity where seen.insert(activity.transactionHash.hexString).inserted {
            out.append(feedItem(from: activity, launch: byToken[activity.token]))
        }
        // Swap backfill for swaps made before recording or on another device.
        for swap in swaps where seen.insert(swap.hash.hexString).inserted {
            out.append(FeedItem(id: swap.hash.hexString, icon: "arrow.left.arrow.right", title: tr("Swapped"), subtitle: SwapHistoryItem.describe(swap, tokens: tokens), time: swap.time, hash: swap.hash))
        }
        for record in records { if let status = record.status { add(record, icon: PendingActivity.symbol(for: status)) } }
        return out.sorted { $0.time > $1.time }
    }

    private static func feedItem(from activity: ActivityItem, launch: Launch?) -> FeedItem {
        let symbol = launch?.symbol ?? activity.token.short
        let time = Date(timeIntervalSince1970: TimeInterval(activity.time))
        let hash = activity.transactionHash
        switch activity.kind {
        case .launch:
            return FeedItem(id: hash.hexString, icon: "flame.fill", title: tr("Launched $\(symbol)"), subtitle: launch?.name ?? "", time: time, hash: hash)
        case .trade(_, _, _, let isBuy, let quoteAmount, let tokenAmount):
            let pairDecimals = launch?.pair.decimals ?? 18
            let pairSymbol = launch?.pair.symbol ?? ""
            let subtitle = "\(NumberStyle.units(tokenAmount, decimals: 18, compact: true)) \(symbol) · \(NumberStyle.units(quoteAmount, decimals: pairDecimals, compact: true)) \(pairSymbol)"
            return FeedItem(id: hash.hexString, icon: isBuy ? "arrow.down" : "arrow.up", title: isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)"), subtitle: subtitle, time: time, hash: hash)
        case .graduated:
            return FeedItem(id: hash.hexString, icon: "checkmark.seal.fill", title: tr("\(symbol) graduated"), subtitle: "", time: time, hash: hash)
        }
    }
}
