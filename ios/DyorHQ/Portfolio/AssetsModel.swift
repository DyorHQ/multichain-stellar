import BigInt
import DyorKit
import SwiftUI

/// Everything the wallet holds on Monad — every ERC-20 with a balance and every NFT — discovered from the wallet's
/// own transfer history rather than a curated list, so assets received anywhere on the chain show up here.
@Observable
@MainActor
final class AssetsModel {
    /// A held token, valued (`HeldToken`): the Send sheet lists the same ones (`WalletTokens`), in its own order.
    typealias TokenAsset = HeldToken

    private(set) var tokens: [TokenAsset] = []
    /// Tokens the wallet was sent rather than chose in the app — found in its history — shown as Unverified (IOST-12).
    private(set) var unverified: Set<Address> = []
    /// The NFTs the wallet holds, newest received first (`WalletNFTDiscovery.held`), from the transfers into it that its
    /// history store holds — the scan its tokens are found in, no scan of their own.
    private(set) var nfts: [NFTAsset] = []
    /// False when an NFT the wallet holds may be missing from `nfts`: the transfers into it weren't all read yet (the
    /// history still filling in: `nftsFilling`), or an ownership read failed. The NFTs tab says so, with Retry, never "No
    /// NFTs" on a read that was a part.
    private(set) var nftsComplete = true
    /// More NFTs may be held than the list resolves at once (`WalletNFTDiscovery.Held.cut`): its count reads as a minimum.
    private(set) var nftsCut = false
    /// The transfers into the wallet were still reading their window when the NFTs were read
    /// (`WalletHistorySnapshot.readingWindow`, what the token list waits on, `WalletTokens.history`): the tab says how far
    /// the history has got (`nftsProgress`), and the NFTs are read again once it has read them all. Not for a history that
    /// is complete but last read a while ago (read from the device at launch, the app away), which `filling` counts as
    /// still reading — a failed ownership read then showed "Reading your history… 99%" with no Retry — nor for another
    /// wallet's history.
    private(set) var nftsFilling = false
    /// How much of the transfers' window the history had read when the NFTs were read, of this wallet's history only.
    private(set) var nftsProgress = 0.0
    /// The block the transfers into the wallet were read back to when the NFTs were read (`HistoryStatus.floor`), and the
    /// day it was, when above the chain's first block: the scan reads back to the wallet's first transaction or 30 days,
    /// whichever is earlier, and never below the logs it keeps (`HistoryEntry.capFloor`), so an NFT received before then,
    /// and not since, isn't among the candidates — an airdrop to a wallet that has sent nothing yet, say. The tab says how
    /// far back it reached, and counts what it lists as a minimum ("N+"), never "No NFTs in this wallet".
    private(set) var nftsFloor: UInt64?
    private(set) var nftsSince: Date?
    /// The NFTs are being read: after the tokens, which the card shows meanwhile.
    private(set) var nftsLoading = false
    /// The wallet the NFTs shown are of: an earlier read's are kept, for an NFT whose ownership couldn't be read again,
    /// only for the same wallet.
    private var nftsFor: Address?
    /// The NFTs have been read once for the wallet shown: until then an empty list is unread, never "No NFTs".
    var nftsRead: Bool { nftsFor != nil }
    /// Moments by their NFT contract, so a Moment edition opens its own page instead of a generic link.
    private(set) var momentsByNFT: [Address: MomentInfo] = [:]
    /// Retired-cohort Moments by their coin: such a coin opens its claim-only page, never a swap (a trade on a retired
    /// pool pays the retired fee wallet). Entries are only ever added — a failed read keeps the ones already known —
    /// and a coin in `MomentsAddresses.retiredMainnetCoins` gets no swap even before its Moment has been read.
    private(set) var retiredByCoin: [Address: MomentInfo] = [:]
    /// Retired-cohort Moments by their NFT contract, so a past-cohort edition opens its claim-only page.
    private(set) var retiredByNFT: [Address: MomentInfo] = [:]
    /// Held coins still on a launchpad's bonding curve, the live launchpad's or a retired one's, with their launches
    /// (`LaunchpadService.curveHoldings`): no Swap venue routes a curve, so such a coin's row opens its Launch page, where
    /// its curve trades (Buy and Sell on the live launchpad, Sell only on a retired one), as Home's token page does. A
    /// coin whose launch couldn't be read opens its page by reference, which reads it. Known before the token list
    /// shows, so such a coin never gets a Swap row; a failed check keeps the coins already known, and the rest open Swap,
    /// whose "no venue" state checks again and points to the Launch page.
    private(set) var curve: CurveHoldings = .none
    /// Prices couldn't all be read (`WalletTokens.Ranked.pricesFailed`): some tokens are unpriced, so the holdings total
    /// would be a part passed off as the whole. It isn't shown, and the card says why.
    private(set) var pricesFailed = false
    /// The curated tokens held that no pool prices (`WalletTokens.Ranked.unpriced`): they simply have no price, so the
    /// total is of the priced assets, and the card names what it leaves out.
    private(set) var unpriced: [Token] = []
    /// False when part of the wallet couldn't be read (`WalletTokens.Read.complete`: its history, read fail-fast, or a
    /// balance): a token it holds may be missing, which the card says, with Retry, rather than pass the list off as
    /// everything the wallet holds.
    private(set) var complete = true
    /// The wallet's transfer history — the transfers into it, the only scan the list is read from
    /// (`WalletHistoryScans.holdings`) — was still filling in when the list was read (`HistoryModel`): tokens found there
    /// join the list once it has, and the card says so rather than "couldn't be read".
    private(set) var historyFilling = false
    private(set) var historyProgress = 0.0
    /// No balance could be read at all (`WalletTokens.read` threw): the list is empty for that, not because the wallet
    /// holds nothing.
    private(set) var balancesUnread = false
    private(set) var loading = false
    private(set) var loadedFor: Address?

    /// The priced assets' dollar value: a token with no price adds nothing.
    var totalValue: Double { tokens.compactMap(\.value).reduce(0, +) }
    /// The holdings total is shown: every price that exists was read, and something is priced.
    var showsTotal: Bool { !pricesFailed && totalValue > 0 }

    /// What part of the read failed, in words, as the Send sheet says it: nil when all of it was read. Nothing about
    /// prices when there is nothing to value.
    var readGap: String? {
        if balancesUnread { return tr("Your balances couldn't be read. Check your connection and try again.") }
        switch (complete, pricesFailed) {
        case (true, false): return nil
        case (false, _) where historyFilling: return tr("Reading your history… \(NumberStyle.percent(historyProgress * 100, fractionDigits: 0, signed: false))")
        case (true, true): return tokens.isEmpty ? nil : tr("Some prices couldn't be read, so values are missing and no total is shown.")
        case (false, _) where tokens.isEmpty: return tr("No tokens found, but part of your wallet couldn't be read, so some may be missing.")
        case (false, false): return tr("Part of your wallet couldn't be read, so a token may be missing from the list and the total.")
        case (false, true): return tr("Some prices and part of your wallet couldn't be read, so values and tokens may be missing, and no total is shown.")
        }
    }

    /// What part of the NFTs couldn't be read, in words: nil when they all were, or while they are being read.
    var nftGap: String? {
        guard !nftsComplete, !nftsLoading else { return nil }
        if nftsFilling { return tr("Reading your history… \(NumberStyle.percent(nftsProgress * 100, fractionDigits: 0, signed: false))") }
        return nfts.isEmpty ? tr("No NFTs found, but part of your wallet couldn't be read, so some may be missing.")
            : tr("Part of your wallet couldn't be read, so an NFT may be missing from the list.")
    }

    /// The NFTs' count as the card shows it: a minimum ("+") when one may be missing — a read that was a part, more held
    /// than are listed, or transfers read back to a day only (`nftsSince`).
    var nftCount: String {
        nftsComplete && !nftsCut && nftsSince == nil ? "\(nfts.count)" : "\(nfts.count)+"
    }

    /// The day the transfers the NFTs come from were read back to (`nftsSince`), in the app's language; nil when they reach
    /// the chain's first block.
    var nftsSinceDay: String? {
        nftsSince.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)) }
    }

    /// Reads the wallet's tokens and, unless `nfts` is false (the Update screen lists balances only), its NFTs, after the
    /// tokens: the card shows the tokens as soon as they are valued (`loading`), and the NFTs once read (`nftsLoading`).
    func load(env: AppEnvironment, address: Address?, force: Bool, nfts includeNFTs: Bool = true) async {
        guard let address else {
            tokens = []; nfts = []; nftsComplete = true; nftsCut = false; nftsFilling = false; nftsProgress = 0; nftsFloor = nil; nftsSince = nil; nftsFor = nil
            complete = true; balancesUnread = false; loadedFor = nil; return
        }
        if !force, loadedFor == address { return }
        // Another wallet's NFTs are never shown while this one's are read.
        if nftsFor != address { nfts = []; nftsComplete = true; nftsCut = false; nftsFilling = false; nftsProgress = 0; nftsFloor = nil; nftsSince = nil; nftsFor = nil }
        loading = true
        nftsLoading = includeNFTs
        defer { loading = false; nftsLoading = false }

        async let momentsTask = env.moments.moments(limit: 200)
        async let retiredTask = PastMomentsModel.allMoments(env: env)

        // The token part is the Send sheet's too (`WalletTokens`). Balances that couldn't be read list nothing, as before,
        // and the card says so, as it says when only part of the wallet couldn't be read.
        let read = try? await WalletTokens.read(env: env, address: address)
        // The NFTs, from the transfers into the wallet its history store holds — those the token list was just read from,
        // once `WalletTokens.history` had waited for them — beside the tokens' valuing. In build 22 and earlier they had a
        // scan of their own, from block 0 and oldest first, which never reached a Moment edition (`WalletNFTDiscovery`).
        let ownHistory = env.history.wallet == address
        let history = ownHistory ? env.history.snapshot : .empty
        let previousNFTs = nftsFor == address ? nfts : []
        async let nftTask: WalletNFTDiscovery.Held? = includeNFTs
            ? await env.nftDiscovery.held(wallet: address, incoming: history.transfersIn, complete: history.status(WalletHistoryScans.transfersInId).complete,
                                          keeping: previousNFTs)
            : nil
        var ranked: [TokenAsset] = []
        var found: CurveHoldings?
        var failed = false
        var unpricedHeld: [Token] = []
        // The Portfolio keeps the order it has always had; the Send sheet ranks the same tokens its own way. The coins on a
        // curve come from the same read that valued them: the launchpads are asked once.
        if let read {
            let result = await WalletTokens.ranked(read, env: env, by: WalletHoldings.portfolioPrecedes)
            ranked = result.tokens
            found = result.curve
            failed = result.pricesFailed
            unpricedHeld = result.unpriced
        }
        // As the list marks them: the DyorHQ coins the wallet launched or collected are its own, not Unverified.
        unverified = read == nil ? KnownTokenStore.unverified(owner: address) : Set(ranked.filter(\.unverified).map(\.id))
        // Known before the token list shows, so a retired Moment coin or a coin on a curve is never offered a swap in between.
        // A retired cohort that couldn't be read keeps the Moments already known, and the card says part of the wallet
        // couldn't be read.
        let retired = await retiredTask
        for info in retired.moments {
            retiredByCoin[info.moment.coin] = info
            retiredByNFT[info.moment.nft] = info
        }
        if let found { curve = found }
        pricesFailed = failed
        unpriced = unpricedHeld
        complete = (read?.complete ?? false) && retired.complete
        historyFilling = !(read?.complete ?? false) && env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.holdings)
        historyProgress = env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.holdings)
        balancesUnread = read == nil
        tokens = ranked
        loading = false

        let moments = (try? await momentsTask) ?? []
        // Their coins, proven by their cohorts, for the coins' pictures and labels.
        await env.dyorCoins.ingest(moments + retired.moments)
        // Known before the NFTs show, so a Moment edition never reads as an unverified collection in between.
        momentsByNFT = Dictionary(moments.map { ($0.moment.nft, $0) }, uniquingKeysWith: { first, _ in first })
        if let held = await nftTask {
            nfts = held.nfts
            nftsComplete = held.complete
            nftsCut = held.cut
            // Only this wallet's history reading its window is "reading": the stand-in for another's reads as reading too.
            nftsFilling = ownHistory && !held.complete && history.readingWindow(scans: WalletHistoryScans.holdings)
            nftsProgress = history.progress(since: nil, scans: WalletHistoryScans.holdings)
            let transfers = history.status(WalletHistoryScans.transfersInId)
            nftsFloor = transfers.floor
            nftsSince = transfers.floor.flatMap { floor in
                floor > 0 ? history.anchor.map { BlockClock.time(of: floor, anchor: $0, secondsPerBlock: history.secondsPerBlock) } : nil
            }
            nftsFor = address
        }
        loadedFor = address
    }
}

/// My Holdings on the Portfolio: everything the wallet owns on Monad, as one toggle — Assets (every ERC-20 with a
/// balance, valued) or NFTs (every ERC-721, from its metadata). A Moment edition opens its Moment; any other NFT
/// opens on OpenSea.
struct AssetsCard: View {
    let model: AssetsModel
    /// Reads the holdings again, after a read that failed in part.
    let retry: () -> Void
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showAllTokens = false
    @State private var kind: Kind = .assets

    private enum Kind: String, CaseIterable, Identifiable {
        case assets, nfts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .assets: return tr(LocalizedStringResource("Assets", comment: "A tab: in My Holdings the tokens held, on Perps the trading account's balance [tight]"))
            case .nfts: return tr(LocalizedStringResource("NFTs", comment: "My Holdings tab: the NFTs held [tight]"))
            }
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("My Holdings").font(.headline)
                Spacer()
                if model.loading || (kind == .nfts && model.nftsLoading) { ProgressView().controlSize(.mini) }
                else if kind == .assets, model.showsTotal { Text(PriceFormat.usdValue(model.totalValue)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                else if kind == .nfts, !model.nfts.isEmpty {
                    // A list that may be missing one counts at least what it shows, never passed off as all of them.
                    Text(verbatim: model.nftCount).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Picker("Holdings", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind == .assets, !model.loading, let gap = model.readGap {
                // A read that failed in part is said, with Retry, never passed off as all the wallet holds.
                VStack(alignment: .leading, spacing: 8) {
                    Text(gap).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote.weight(.medium))
                }
            }
            if kind == .assets, model.showsTotal, !model.unpriced.isEmpty, !model.loading {
                // A token no pool prices is no failure: the total is of the rest, and says what it leaves out.
                Paragraph("Doesn't include \(WalletHoldings.symbolList(model.unpriced)): no price found.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if kind == .assets, model.tokens.isEmpty, model.loading || model.readGap == nil {
                Text(model.loading ? "Reading the wallet…" : "No tokens in this wallet yet.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }
            if kind == .nfts, let gap = model.nftGap {
                // A read that was a part — the history still filling in, or an ownership read that failed — is said, never
                // "No NFTs".
                VStack(alignment: .leading, spacing: 8) {
                    Paragraph(verbatim: gap).font(.footnote).foregroundStyle(.secondary)
                    if !model.nftsFilling { Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote.weight(.medium)) }
                }
            }
            if kind == .nfts, model.nfts.isEmpty, model.nftsLoading || model.nftGap == nil {
                Group {
                    if model.nftsLoading || !model.nftsRead {
                        Text("Reading the wallet…")
                    } else if let day = model.nftsSinceDay {
                        // Read back to a day, not the chain's start: says how far, never "No NFTs in this wallet".
                        Paragraph(verbatim: tr("No NFTs received since \(day).")).multilineTextAlignment(.center)
                    } else {
                        Text("No NFTs in this wallet yet.")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }
            if kind == .nfts, !model.nfts.isEmpty, !model.nftsLoading, model.nftGap == nil, let day = model.nftsSinceDay {
                // The list is every NFT the transfers read name, and they reach back to a day: one received before it, and
                // not since, isn't in it.
                Paragraph(verbatim: tr("Only NFTs received since \(day) are listed.")).font(.footnote).foregroundStyle(.secondary)
            }

            if kind == .assets, !model.tokens.isEmpty {
                let shown = showAllTokens ? model.tokens : Array(model.tokens.prefix(6))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, asset in
                        let route = model.curve.route(asset.token.address)
                        if let retired = model.retiredByCoin[asset.token.address] {
                            // A retired cohort's coin is never offered a swap: it opens its claim-only page.
                            NavigationLink(value: PastMomentRoute(info: retired)) { tokenRow(asset) }
                                .buttonStyle(.plain)
                        } else if MomentsAddresses.isRetiredCoin(asset.token.address) {
                            // Its cohort could not be read yet: still no swap, just the row.
                            tokenRow(asset, note: "Past cohort · trading closed")
                        } else if route.isOnCurve {
                            // Never Swap: no venue routes a coin still on a launchpad's curve, live or retired. It trades
                            // on its curve, from its Launch page, where Home sends it too; by reference when unread.
                            Button {
                                router.openLaunchPage(for: route)
                                dismiss()
                            } label: {
                                tokenRow(asset, note: route.rowNote, unverified: model.unverified.contains(asset.token.address))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { router.openSwap(tokenIn: asset.token, tokenOut: asset.token.symbol == "USDC" ? .mon : .usdc); dismiss() } label: { tokenRow(asset, unverified: model.unverified.contains(asset.token.address)) }
                                .buttonStyle(.plain)
                        }
                        if index < shown.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
                if model.tokens.count > shown.count {
                    Button("Show all \(model.tokens.count)") { showAllTokens = true }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }
            }

            if kind == .nfts, !model.nfts.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.nfts) { nft in
                        if let retired = model.retiredByNFT[nft.contract] {
                            // A past-cohort edition opens its claim-only page, here in the Portfolio.
                            NavigationLink(value: PastMomentRoute(info: retired)) { nftTile(nft, caption: "Past cohort Moment") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "\(nft.name), \(nft.collection)"))
                        } else if model.momentsByNFT[nft.contract] != nil {
                            Button { open(nft) } label: { nftTile(nft, caption: "Moment · OpenSea") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: "\(nft.name), \(nft.collection)"))
                        } else {
                            // Any other collection was sent to the wallet, not chosen here: its name and art prove nothing.
                            Button { open(nft) } label: { nftTile(nft, caption: "OpenSea", unverified: true) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(nft.name), \(nft.collection), unverified")
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func nftTile(_ nft: NFTAsset, caption: LocalizedStringKey, unverified: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.tertiarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let moment = model.momentsByNFT[nft.contract] ?? model.retiredByNFT[nft.contract] {
                        // A Moment's art comes through the Moment's own checked sources, not the NFT's metadata.
                        MomentArtwork(provenance: moment.provenance, symbol: moment.symbol, creator: moment.moment.creator)
                    } else if let url = nft.imageURL {
                        RemoteImage(url: url, pointSize: 120) { loading in
                            if loading { ImageLoadingSpinner() } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }
                        .accessibilityIgnoresInvertColors() // art, left as it is under Smart Invert
                    } else {
                        Image(systemName: "seal").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(nft.name).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 4) {
                if unverified { UnverifiedBadge() }
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: LocalizedStringKey, unverified: Bool = false) -> some View {
        tokenRow(asset, note: Text(note), unverified: unverified)
    }

    /// A row whose note is worded at run time (a curve route's `rowNote`), shown as it is: the token's name when there is
    /// none.
    @_disfavoredOverload
    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: String? = nil, unverified: Bool = false) -> some View {
        tokenRow(asset, note: note.map { Text(verbatim: $0) }, unverified: unverified)
    }

    private func tokenRow(_ asset: AssetsModel.TokenAsset, note: Text?, unverified: Bool) -> some View {
        HStack(spacing: 12) {
            TokenLogo(token: asset.token, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(asset.token.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    TokenBadgeView(token: asset.token, receivedUnasked: unverified)
                }
                (note ?? Text(verbatim: asset.token.displayName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberStyle.units(asset.balance, decimals: asset.token.decimals, compact: true)).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary)
                if let value = asset.value { Text(PriceFormat.usdValue(value)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func open(_ nft: NFTAsset) {
        Haptics.tap()
        if let moment = model.momentsByNFT[nft.contract] {
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                router.openMoment(moment)
            }
        } else {
            openURL(nft.openSeaURL)
        }
    }
}
