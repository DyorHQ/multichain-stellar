import BigInt
import Foundation

/* On-chain history for Moments without an indexer: `eth_getLogs` from the factory's deployment block (nothing
   about Moments exists before it) in chunks the endpoint accepts, newest first. Every event that matters carries the
   wallet as an indexed topic, so each scan is one filtered query. The app's own screens read the wallet's Moments history
   from its history store (`WalletHistoryScans.moments`, every cohort), not from here. */

public extension MomentsService {
    /// Everything the wallet did on Moments — collects, vesting claims, USDC withdrawals, publishes — since
    /// `fromBlock` (default: the factory's deployment block), newest first, and whether every scan read the whole window
    /// (`complete`): false when the head couldn't be read, or a scan stopped short. The scans read newest first, so one
    /// that stops short holds the latest records; in build 22 and earlier they read oldest first and said nothing, and a
    /// cohort deployed more than about 4.8M blocks ago (each scan's budget, 80 requests) came back with its first weeks
    /// only, passed off as the whole.
    func history(account: Address, fromBlock: UInt64? = nil) async -> (history: MomentsAccountHistory, complete: Bool) {
        guard isDeployed else { return (.empty, true) }
        guard let anchor = try? await logsRPC.block(.latest) else { return (.empty, false) }
        let secondsPerBlock = await clock.secondsPerBlock()
        let from = max(fromBlock ?? addresses.deployBlock, addresses.deployBlock)
        guard from <= anchor.number else { return (.empty, true) }
        let word = account.data.leftPadded(to: 32)
        let to = anchor.number
        async let collectedRead = logsRPC.chunkedLogsReport(address: addresses.collect, topics: [MomentsABI.Events.collectedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let claimedRead = logsRPC.chunkedLogsReport(address: addresses.vesting, topics: [MomentsABI.Events.claimedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let withdrawnRead = logsRPC.chunkedLogsReport(address: addresses.collect, topics: [MomentsABI.Events.withdrawnTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let feesRead = logsRPC.chunkedLogsReport(address: addresses.hook, topics: [MomentsABI.Events.feesWithdrawnTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        async let publishedRead = logsRPC.chunkedLogsReport(address: addresses.factory, topics: [MomentsABI.Events.publishedTopic, nil, word], fromBlock: from, toBlock: to, order: .descending)
        let (collected, claimed, withdrawn, fees, published) = await (collectedRead, claimedRead, withdrawnRead, feesRead, publishedRead)
        let history = Self.history(collected: collected.logs, claimed: claimed.logs, withdrawn: withdrawn.logs, feesWithdrawn: fees.logs, published: published.logs,
                                   anchor: anchor, secondsPerBlock: secondsPerBlock, factory: addresses.factory)
        return (history, [collected, claimed, withdrawn, fees, published].allSatisfy { $0.complete })
    }

    /// Pure half of `history`, so the parsers can be tested on canned logs. Each record's time is its block's own when the
    /// log carries it (`Log.blockTimestamp`), else estimated from `anchor` at `secondsPerBlock`; `factory` tags every
    /// record with its cohort (Moment ids restart at 1 on every factory).
    nonisolated static func history(collected: [Log], claimed: [Log], withdrawn: [Log], feesWithdrawn: [Log], published: [Log], anchor: BlockHeader, secondsPerBlock: Double,
                                    factory: Address = .zero) -> MomentsAccountHistory {
        func time(_ log: Log) -> Date { BlockClock.time(of: log, anchor: anchor, secondsPerBlock: secondsPerBlock) }
        var collects: [MomentCollectRecord] = []
        for log in collected {
            guard let e = MomentsABI.collected(log) else { continue }
            collects.append(MomentCollectRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, collector: e.collector,
                                                gross: e.gross, editions: Int(clamping: e.editions), firstRank: Int(clamping: e.firstRank), entitlement: e.entitlement,
                                                reserveIn: e.reserveIn, creatorIn: e.creatorIn, platformIn: e.platformIn, factory: factory))
        }
        var claims: [MomentClaimRecord] = []
        for log in claimed {
            guard let e = MomentsABI.claimed(log) else { continue }
            claims.append(MomentClaimRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, collectorAmount: e.collectorAmount, creatorAmount: e.creatorAmount, factory: factory))
        }
        var withdrawals: [MomentWithdrawalRecord] = []
        for log in withdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, kind: .proceeds, amount: e.amount, factory: factory))
        }
        for log in feesWithdrawn {
            guard let e = MomentsABI.withdrawn(log) else { continue }
            withdrawals.append(MomentWithdrawalRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, kind: .poolFees, amount: e.amount, factory: factory))
        }
        var publishes: [MomentPublishRecord] = []
        for log in published {
            guard let e = MomentsABI.published(log) else { continue }
            publishes.append(MomentPublishRecord(hash: log.transactionHash, block: log.blockNumber, time: time(log), momentId: e.momentId, coin: e.coin, factory: factory))
        }
        return MomentsAccountHistory(
            collects: collects.sorted { $0.block > $1.block },
            claims: claims.sorted { $0.block > $1.block },
            withdrawals: withdrawals.sorted { $0.block > $1.block },
            publishes: publishes.sorted { $0.block > $1.block }
        )
    }

    /// Holder statistics for a Moment coin from its `Transfer` logs since publish. The pool and the other protocol
    /// addresses are reported apart from wallets (spec §12 containment: holder count + top-holder share). Nil when the
    /// head, or the newest of the coin's blocks, couldn't be read: no figure at all, never 0 holders.
    ///
    /// The transfers are read newest first (`RPCClient.newestLogs`) within the patient budget (80 requests, about 4.8M
    /// blocks on rpc2, about 13 days of a Moment's age at this lookback; 80,000 blocks, hours, on the 1,000-block
    /// endpoints): a read that stops short of the publish gives the holders as a minimum and says so
    /// (`MomentHolderStats.complete`). In build 22 and earlier it read oldest first and said nothing: an older Moment's
    /// holders, top wallet and pool share were those of its first days, shown with the head as `scannedTo`.
    ///
    /// Since build 23 what was counted is kept on the device (`MomentHolderTally`, with a store): a page opened again
    /// reads only the blocks since, and, while the count doesn't reach back to the publish, the blocks before it, newest
    /// first, so an older coin's holders become whole over a few openings instead of starting again from the head each
    /// time. The newest `MomentHolderTally.settleBlocks` blocks (`LogsEndpoints.headLag`, 600) are read every time and
    /// never kept: this read is a screen's, given no head, so an endpoint that clamps may answer its newest range short
    /// from a node hundreds of blocks behind, with no error (`LogsEndpoint.clamps`), and what it left out would be kept
    /// as blocks with no transfers for good. A read of the blocks since that stops short starts the count again from the
    /// head (the newest blocks are counted first, as before); one that can't read the head keeps what was kept, and
    /// returns nil.
    func holderStats(coin: Address, publishedAt: Int) async -> MomentHolderStats? {
        guard isDeployed, let anchor = try? await logsRPC.block(.latest) else { return nil }
        let secondsPerBlock = await clock.secondsPerBlock()
        // The publish block from the anchor and the session's pace (with slack), never before deployment.
        let back = Self.holderLookback(ageSeconds: anchor.timestamp - publishedAt, secondsPerBlock: secondsPerBlock)
        let floor = max(addresses.deployBlock, anchor.number > back ? anchor.number - back : 0)
        let epoch = store?.epoch
        let saved = savedHolderTally(coin: coin)
        let topics = [MomentsABI.Events.transferTopic]
        let start = saved.map { $0.to + 1 } ?? floor
        let newer = start <= anchor.number
            ? await logsRPC.newestLogs(address: coin, topics: topics, fromBlock: start, toBlock: anchor.number)
            : NewestLogs(logs: [], readFrom: start, complete: true)
        let settled = MomentHolderTally.settled(head: anchor.number)
        let settledAt = Self.time(anchor: anchor, block: settled, secondsPerBlock: secondsPerBlock)
        guard var round = MomentHolderTally.round(saved: saved, coin: coin, floor: floor, head: anchor.number, start: start, settled: settled, settledAt: settledAt,
                                                  newer: newer) else { return nil }
        // The blocks before the count, newest first, once the blocks since were read in full.
        if round.newerComplete, let kept = round.kept, !kept.complete {
            let older = await logsRPC.newestLogs(address: coin, topics: topics, fromBlock: kept.floor, toBlock: kept.from - 1)
            round.extend(older)
        }
        if let kept = round.kept, let epoch { keepHolderTally(kept, readSince: epoch) }
        return round.stats(addresses: addresses)
    }

    /// The holder statistics of what the device kept of `coin`'s transfers when its holders were last read
    /// (`MomentHolderTally`), and when the newest block they count was made: a page shows them at once, said to be saved,
    /// until its read lands. Nil when nothing is kept (or no store).
    func savedHolderStats(coin: Address) -> (stats: MomentHolderStats, asOf: Date)? {
        guard let tally = savedHolderTally(coin: coin) else { return nil }
        return (Self.holderStats(balances: tally.balances, addresses: addresses, scannedTo: tally.to, complete: tally.complete), tally.asOf)
    }

    /// What the device keeps of `coin`'s transfers; nil without a store, or when nothing usable is kept.
    private func savedHolderTally(coin: Address) -> MomentHolderTally? {
        store?.load(MomentHolderTallyFile.self, from: MomentHolderTally.fileName(coin))?.tally(coin: coin)
    }

    /// Keeps `tally`, unless this device's data was erased since `epoch` (when the read began), or it counts more wallets
    /// than a file keeps (`MomentHolderTally.maxKeptWallets`): then the file is left as it was, and the next read starts
    /// from it.
    private func keepHolderTally(_ tally: MomentHolderTally, readSince epoch: Int) {
        guard let store, tally.balances.count <= MomentHolderTally.maxKeptWallets else { return }
        store.save(MomentHolderTallyFile(tally), to: MomentHolderTally.fileName(tally.coin), epoch: epoch)
    }

    /// Pure half of `holderStats(coin:publishedAt:)` for a read that may have stopped short: nil when nothing was read down
    /// from the head.
    nonisolated static func holderStats(_ read: NewestLogs, addresses: MomentsAddresses, scannedTo: UInt64) -> MomentHolderStats? {
        guard read.readFrom != nil else { return nil }
        return holderStats(transfers: read.logs, addresses: addresses, scannedTo: scannedTo, complete: read.complete)
    }

    /// How far back `holderStats` reads a Moment's transfers: its age (no less than 0) in blocks at `secondsPerBlock`,
    /// with a quarter more and 2,000 blocks of slack, so the publish is inside the scan even if the pace was slower.
    nonisolated static func holderLookback(ageSeconds: Int, secondsPerBlock: Double) -> UInt64 {
        BlockClock.blocks(in: TimeInterval(max(0, ageSeconds)) * 1.25, secondsPerBlock: secondsPerBlock) + 2_000
    }

    /// Pure half of `holderStats`: `complete`, whether `transfers` are every one since the publish
    /// (`MomentHolderStats.complete`).
    nonisolated static func holderStats(transfers: [Log], addresses: MomentsAddresses, scannedTo: UInt64, complete: Bool = true) -> MomentHolderStats {
        holderStats(balances: netTransfers(transfers), addresses: addresses, scannedTo: scannedTo, complete: complete)
    }

    /// Each address's net transfers in `transfers`, in coin units: what it received less what it sent (mints come from
    /// address 0, which is never counted). An address whose transfers cancel out is left out.
    nonisolated static func netTransfers(_ transfers: [Log]) -> [Address: BigInt] {
        var balances: [Address: BigInt] = [:]
        for log in transfers {
            guard let from = log.indexedAddress(0), let to = log.indexedAddress(1) else { continue }
            let value = BigInt(BigUInt(log.data))
            if !from.isZero { balances[from, default: 0] -= value }
            balances[to, default: 0] += value
        }
        return balances.filter { $0.value != 0 }
    }

    /// The statistics of `balances` (`netTransfers`, of the blocks counted up to `scannedTo`).
    nonisolated static func holderStats(balances: [Address: BigInt], addresses: MomentsAddresses, scannedTo: UInt64, complete: Bool) -> MomentHolderStats {
        let protocolSet = addresses.protocolHolders
        var minted = BigInt(0), pool = BigInt(0), circulating = BigInt(0)
        var holders = 0
        var top: (Address?, BigInt) = (nil, 0)
        for (who, balance) in balances where balance > 0 {
            minted += balance
            if who == addresses.poolManager { pool += balance }
            if protocolSet.contains(who) { continue }
            circulating += balance
            holders += 1
            // Of equal balances the lowest address, so two reads of the same transfers name the same wallet.
            if balance > top.1 || (balance == top.1 && top.0.map { who.hex < $0.hex } ?? true) { top = (who, balance) }
        }
        let scale = pow(10.0, Double(MomentsConstants.coinDecimals))
        return MomentHolderStats(
            holders: holders,
            topHolder: top.0,
            topHolderBps: circulating == 0 ? 0 : Int(clamping: (top.1 * 10_000 / circulating).magnitude),
            circulatingCoins: Double(circulating) / scale,
            poolBps: minted == 0 ? 0 : Int(clamping: (pool * 10_000 / minted).magnitude),
            mintedCoins: Double(minted) / scale,
            scannedTo: scannedTo,
            complete: complete
        )
    }
}

/// A Moment coin's transfers counted so far (`MomentsService.holderStats`): each address's net transfers over one run of
/// blocks read in one piece, `from` to `to`, kept on the device (`ChainStore`, one file a coin) so the next read of the
/// coin's holders reads only the blocks since `to` and, while the run doesn't reach back to the publish (`floor`), the
/// blocks before `from`, newest first. Public chain data only, the same for every account on the device; erased with the
/// device's data (`ChainStore.erase`), and a count read before an erase is never kept after it.
struct MomentHolderTally: Equatable, Sendable {
    /// The newest blocks read on every read of a coin's holders and never kept: `LogsEndpoints.headLag`, 600 blocks, about
    /// three minutes. The read is a screen's, given no head (`RPCClient.newestLogs`), so any endpoint may be asked for any
    /// of its blocks — none waits on rpc2, and with rpc2 down the page still shows the holders — and one that clamps
    /// (`LogsEndpoint.clamps`) answers a range past its node's head short, with no error, from a node hundreds of blocks
    /// behind at times: a block it left out, kept, would count as one with no transfers for good. So only blocks at least
    /// that far below the head are kept, as the wallet's history keeps none a clamping endpoint read nearer the head
    /// (`LogsRouter.read`); the newer ones are shown and read again at the next opening. It covers a head read from a node
    /// a little ahead of the one that answered the logs too.
    static let settleBlocks: UInt64 = LogsEndpoints.headLag
    /// The most wallets a kept count holds: a coin held more widely is read from the head on every opening, as before.
    static let maxKeptWallets = 20_000

    let coin: Address
    /// The first block the coin's transfers can be in: before its publish (`MomentsService.holderLookback`, with slack),
    /// never before its cohort's deployment. The lowest of every read's: a later read never narrows the window.
    var floor: UInt64
    /// Every transfer of the coin from block `from` to block `to`, both included, is counted in `balances`, and no other.
    var from: UInt64
    var to: UInt64
    /// Each address's net transfers over `from…to` (`MomentsService.netTransfers`).
    var balances: [Address: BigInt]
    /// When block `to` was made: how old the count is, which a page says while it shows it ("Updated 3 min ago").
    var asOf: Date

    /// The count reaches back to the publish: every transfer of the coin up to `to` is in it.
    var complete: Bool { from <= floor }

    /// The newest block a read of the holders at `head` keeps: `settleBlocks` below it, 0 near the chain's first blocks.
    static func settled(head: UInt64) -> UInt64 { head > settleBlocks ? head - settleBlocks : 0 }

    /// `moment-holders-<coin>.json`.
    static func fileName(_ coin: Address) -> String { "moment-holders-\(coin.hex.lowercased()).json" }

    /// `a` and `b` added up, address by address; an address whose net is zero left out.
    static func merged(_ a: [Address: BigInt], _ b: [Address: BigInt]) -> [Address: BigInt] {
        var out = a
        for (who, value) in b { out[who, default: 0] += value }
        return out.filter { $0.value != 0 }
    }

    /// One read of a coin's holders (`MomentsService.holderStats`): what is kept, the newest blocks it doesn't keep, and
    /// how far down from the head the blocks were read in one piece.
    struct Round: Equatable, Sendable {
        /// What the device keeps after this read; nil when nothing settled was read in one piece with the head.
        var kept: MomentHolderTally?
        /// The net transfers of the blocks after `settled`, read now and not kept.
        let recent: [Address: BigInt]
        /// The oldest block of the run read in one piece down from `head`, the kept count's included.
        var coveredFrom: UInt64
        let floor: UInt64
        let head: UInt64
        /// The blocks since the kept count were read in full: the kept count and this read are one run.
        let newerComplete: Bool

        /// Every block from the window's floor to the head was counted.
        var complete: Bool { coveredFrom <= floor }

        /// Adds the read of the blocks before the kept count (`older`, `[floor, kept.from - 1]`, newest first): the part
        /// read in one piece down from `kept.from - 1` is counted, and the count reaches down to where it stopped.
        mutating func extend(_ older: NewestLogs) {
            guard newerComplete, var tally = kept, let readFrom = older.readFrom, readFrom < tally.from else { return }
            tally.balances = MomentHolderTally.merged(tally.balances, MomentsService.netTransfers(older.logs.filter { $0.blockNumber >= readFrom && $0.blockNumber < tally.from }))
            tally.from = readFrom
            kept = tally
            coveredFrom = readFrom
        }

        /// The statistics shown: the kept count and the newest blocks together, complete when they reach the floor.
        func stats(addresses: MomentsAddresses) -> MomentHolderStats {
            MomentsService.holderStats(balances: MomentHolderTally.merged(kept?.balances ?? [:], recent), addresses: addresses, scannedTo: head, complete: complete)
        }
    }

    /// What a read of the blocks since the kept count (`newer`, of `[start, head]`, newest first; `start` is the block after
    /// `saved.to`, or `floor` with nothing kept) makes of it. Nil when the head itself wasn't read. Read in full, its
    /// settled blocks (up to `settled`, made at `settledAt`) join the kept count; the rest are shown, not kept. Stopped
    /// short, the run it read down from the head is counted and kept on its own: what was kept before is cut off from it by
    /// blocks unread, so it is dropped, and the newest blocks are what a minimum is counted from, as before.
    static func round(saved: MomentHolderTally?, coin: Address, floor: UInt64, head: UInt64, start: UInt64, settled: UInt64, settledAt: Date,
                      newer: NewestLogs) -> Round? {
        guard let readFrom = newer.readFrom else { return nil }
        let floor = min(saved?.floor ?? floor, floor)
        let settledLogs = newer.logs.filter { $0.blockNumber >= readFrom && $0.blockNumber <= settled }
        let recent = MomentsService.netTransfers(newer.logs.filter { $0.blockNumber >= readFrom && $0.blockNumber > settled })
        guard newer.complete else {
            let kept = readFrom <= settled
                ? MomentHolderTally(coin: coin, floor: floor, from: readFrom, to: settled, balances: MomentsService.netTransfers(settledLogs), asOf: settledAt)
                : nil
            return Round(kept: kept, recent: recent, coveredFrom: readFrom, floor: floor, head: head, newerComplete: false)
        }
        var kept = saved
        kept?.floor = floor
        if settled >= start {
            if var tally = kept {
                tally.balances = merged(tally.balances, MomentsService.netTransfers(settledLogs))
                tally.to = settled
                tally.asOf = settledAt
                kept = tally
            } else {
                kept = MomentHolderTally(coin: coin, floor: floor, from: start, to: settled, balances: MomentsService.netTransfers(settledLogs), asOf: settledAt)
            }
        }
        return Round(kept: kept, recent: recent, coveredFrom: kept?.from ?? start, floor: floor, head: max(head, kept?.to ?? head), newerComplete: true)
    }
}

/// A `MomentHolderTally` on disk. Each wallet is kept as its lower-case address and its net transfers in decimal: a file
/// of another version or another coin, blocks out of order, or any entry that can't be read back is not used at all (a
/// count missing one wallet would be wrong), and the coin's holders are read from the head again.
struct MomentHolderTallyFile: Codable {
    static let currentVersion = 1

    let version: Int
    let coin: String
    let floor: UInt64
    let from: UInt64
    let to: UInt64
    let asOf: Date
    let balances: [String: String]

    init(_ tally: MomentHolderTally) {
        version = Self.currentVersion
        coin = tally.coin.hex.lowercased()
        floor = tally.floor
        from = tally.from
        to = tally.to
        asOf = tally.asOf
        var out: [String: String] = [:]
        for (who, value) in tally.balances { out[who.hex.lowercased()] = String(value) }
        balances = out
    }

    /// The count kept for `coin`; nil when it can't be used.
    func tally(coin: Address) -> MomentHolderTally? {
        guard version == Self.currentVersion, self.coin == coin.hex.lowercased(), from <= to else { return nil }
        var out: [Address: BigInt] = [:]
        for (who, text) in balances {
            guard let address = Address(who), let value = BigInt(text, radix: 10) else { return nil }
            out[address] = value
        }
        return MomentHolderTally(coin: coin, floor: floor, from: from, to: to, balances: out, asOf: asOf)
    }
}
