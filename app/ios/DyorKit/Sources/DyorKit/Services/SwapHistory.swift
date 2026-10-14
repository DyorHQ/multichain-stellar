import BigInt
import Foundation

/// One swap the wallet made, reconstructed from its ERC-20 `Transfer` logs: a transaction where the wallet both
/// sent one token and received another. Amounts are raw (wei); the UI resolves symbols/decimals from its token set.
public struct SwapRecord: Identifiable, Sendable, Hashable {
    public let hash: Data
    public let block: UInt64
    public let time: Date
    public let soldToken: Address
    public let soldAmount: BigUInt
    public let boughtToken: Address
    public let boughtAmount: BigUInt
    /// The block's own time (seconds since 1970) when its logs carried it (`Log.blockTimestamp`): then `time` is exact,
    /// and stays as it is when the swap is timed again. Nil: `time` is estimated from a later block.
    public let blockTimestamp: Int?
    public var id: String { hash.hexString }

    /// A sale into native MON whose MON couldn't be read (`SwapHistoryService.nativeReceived`): its amount is unknown, not
    /// zero. Shown without an amount, and left out of P&L.
    public var boughtNativeUnknown: Bool { boughtToken == Monad.native && boughtAmount == 0 }

    public init(hash: Data, block: UInt64, time: Date, soldToken: Address, soldAmount: BigUInt, boughtToken: Address, boughtAmount: BigUInt, blockTimestamp: Int? = nil) {
        self.hash = hash
        self.block = block
        self.time = time
        self.soldToken = soldToken
        self.soldAmount = soldAmount
        self.boughtToken = boughtToken
        self.boughtAmount = boughtAmount
        self.blockTimestamp = blockTimestamp
    }

    /// The same swap, its time estimated again from a newer head — unless it is its block's own (`blockTimestamp`).
    public func timed(anchor: BlockHeader, secondsPerBlock: Double) -> SwapRecord {
        guard blockTimestamp == nil else { return self }
        return SwapRecord(hash: hash, block: block, time: BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock),
                          soldToken: soldToken, soldAmount: soldAmount, boughtToken: boughtToken, boughtAmount: boughtAmount)
    }

    /// The same swap with what the sale into native MON paid the wallet (`SwapHistoryService.nativeReceived`).
    func receiving(_ amount: BigUInt) -> SwapRecord {
        SwapRecord(hash: hash, block: block, time: time, soldToken: soldToken, soldAmount: soldAmount, boughtToken: boughtToken, boughtAmount: amount, blockTimestamp: blockTimestamp)
    }
}

/// Reconstructs a wallet's swap history from on-chain `Transfer` events, with no per-token filter: one pair of
/// `eth_getLogs` scans (out of the wallet, into the wallet) covers every token at once, then transactions that both
/// spent and received a token become swaps. This backfills history the local record store didn't capture (older
/// swaps, or ones made on another device). Uses rpc1's wide `eth_getLogs` ranges.
public struct SwapHistoryService: Sendable {
    private let rpc: RPCClient
    /// Where a transaction's facts are read (`TransactionFacts`): its record, its receipt, and the wallet's balance and
    /// nonce at past blocks — state only the archive endpoints answer (`LogsEndpoints.archive`: rpc2, rpc4, rpc1), never
    /// a client that fails over onto rpc3 or rpc.monad.xyz, which refuse old blocks.
    private let archive: RPCClient
    /// Turns the 24H, 7D and 30D filters into blocks, and block numbers into the times a swap shows.
    public let clock: BlockClock

    /// `archive`: the client for the transactions' facts (`TransactionFacts`); nil reads them on `rpc` (a local fork,
    /// tests).
    public init(rpc: RPCClient, clock: BlockClock? = nil, archive: RPCClient? = nil) {
        self.rpc = rpc
        self.archive = archive ?? rpc
        self.clock = clock ?? BlockClock(rpc: rpc)
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// How far back a history query looks. `all` is capped so a no-address scan stays bounded on a busy chain.
    public enum Window: String, Sendable, CaseIterable, Identifiable {
        case day, week, month, all
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .day: return L10n.string(LocalizedStringResource("24H", bundle: L10n.kit, comment: "[tight] A history window: the last 24 hours."))
            case .week: return L10n.string(LocalizedStringResource("7D", bundle: L10n.kit, comment: "[tight] A history window: the last 7 days."))
            case .month: return L10n.string(LocalizedStringResource("30D", bundle: L10n.kit, comment: "[tight] A history window: the last 30 days."))
            case .all: return L10n.string(LocalizedStringResource("All", bundle: L10n.kit, comment: "[tight] A history window: every swap, as far back as the app reads."))
            }
        }
        /// The blocks a scan of this window reads at `secondsPerBlock`: the day, the week and the month their true length
        /// (`seconds`); "All" the fixed budget `allBlocks`, whatever the pace.
        public func blocks(secondsPerBlock: Double) -> UInt64 {
            self == .all ? Self.allBlocks : BlockClock.blocks(in: seconds, secondsPerBlock: secondsPerBlock)
        }
        /// `blocks(secondsPerBlock:)` at `BlockClock.fallbackSecondsPerBlock`, for a reader with no clock: an estimate.
        /// `swaps(wallet:window:)` uses the session's measured pace.
        public var blocks: UInt64 { blocks(secondsPerBlock: BlockClock.fallbackSecondsPerBlock) }
        /// What an "All" scan reads: a block budget, 19,440,000 blocks (about 68 days at Monad's pace), kept as it was
        /// when it was called 90 days so a scan with no address filter stays bounded on a busy chain.
        public static let allBlocks: UInt64 = 19_440_000
        /// The matching wall-clock cutoff for filtering recorded rows.
        public var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 86_400 * 7
            case .month: return 86_400 * 30
            case .all: return 86_400 * 90
            }
        }
    }

    /// The current chain head, for a poller to checkpoint from (so it only picks up swaps made after a trader is copied).
    public func head() async -> UInt64? { try? await rpc.block(.latest).number }

    public func swaps(wallet: Address, window: Window, decimals: [Address: Int] = [:], limit: Int = 100) async -> [SwapRecord] {
        guard let anchor = try? await rpc.block(.latest) else { return [] }
        let secondsPerBlock = await clock.secondsPerBlock()
        let latest = anchor.number
        let blocks = window.blocks(secondsPerBlock: secondsPerBlock)
        let from = latest > blocks ? latest - blocks : 0
        return await scan(wallet: wallet, from: from, to: latest, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit)
    }

    /// Swaps in an explicit block range — e.g. the Portfolio's full-history scan from block 0.
    public func swaps(wallet: Address, fromBlock: UInt64, toBlock: UInt64, decimals: [Address: Int] = [:], limit: Int = 100) async -> [SwapRecord] {
        guard toBlock >= fromBlock, let anchor = try? await rpc.block(.latest) else { return [] }
        return await scan(wallet: wallet, from: fromBlock, to: toBlock, anchor: anchor, secondsPerBlock: await clock.secondsPerBlock(), decimals: decimals, limit: limit)
    }

    private func scan(wallet: Address, from: UInt64, to latest: UInt64, anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int], limit: Int) async -> [SwapRecord] {
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // No address filter: one scan for everything the wallet sent, one for everything it received, each newest first
        // (`RPCClient.chunkedLogs`), so a window wider than a scan's budget gives its latest swaps. No screen reads swaps
        // from here: the app builds them from its history store (`WalletHistoryService`), which says how far it has read.
        async let outgoing = rpc.chunkedLogs(address: nil, topics: [topic, walletWord, nil], fromBlock: from, toBlock: latest)
        async let incoming = rpc.chunkedLogs(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest)
        let (outLogs, inLogs) = await (outgoing, incoming)
        return await reconstruct(wallet: wallet, outgoing: outLogs, incoming: inLogs, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit)
    }

    /// The wallet's swaps from its `Transfer` logs — those it sent (`outgoing`) and received (`incoming`), as the history
    /// store keeps them — newest first, at most `limit`: a transaction with a spent leg and a received leg is a swap, and a
    /// one-sided one whose other leg is native MON is read from the transaction itself (`archive`).
    public func reconstruct(wallet: Address, outgoing outLogs: [Log], incoming inLogs: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int],
                            limit: Int) async -> [SwapRecord] {
        await reconstruct(wallet: wallet, outgoing: outLogs, incoming: inLogs, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, limit: limit, facts: [:]).records
    }

    /// What a transaction's own record says (`eth_getTransactionByHash`) and what a sale into native MON paid the wallet
    /// (`withNativeReceived`), kept by the caller between reconstructions — in memory and on the device, beside the
    /// wallet's history (`WalletHistoryService`): once mined, neither changes, so a build looks up new transactions only,
    /// and the history read from the device at launch needs no network at all.
    public struct TransactionFacts: Sendable, Hashable, Codable {
        public var from: Address?
        public var to: Address?
        public var value: BigUInt
        public var nativeReceived: NativeReceived

        public init(from: Address?, to: Address?, value: BigUInt, nativeReceived: NativeReceived = .unread) {
            self.from = from
            self.to = to
            self.value = value
            self.nativeReceived = nativeReceived
        }

        /// The facts of the same transaction from two builds, the more known kept: the record from whichever read it, and
        /// what the sale into MON paid from whichever settled it (read, or found unknowable).
        func merged(with other: TransactionFacts) -> TransactionFacts {
            var out = from == nil ? other : self
            if case .unread = out.nativeReceived { out.nativeReceived = nativeReceived == .unread ? other.nativeReceived : nativeReceived }
            return out
        }

        // Kept as hex text, as the history store keeps its logs: `{"from":"0x…","to":"0x…","value":"0x…","native":"0x…"}`.
        private enum CodingKeys: String, CodingKey { case from, to, value, native }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func address(_ key: CodingKeys) throws -> Address? {
                guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
                guard let address = Address(text) else { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not an address") }
                return address
            }
            from = try address(.from)
            to = try address(.to)
            guard let value = BigUInt(hexQuantity: try container.decode(String.self, forKey: .value)) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "not a quantity")
            }
            self.value = value
            nativeReceived = try container.decodeIfPresent(NativeReceived.self, forKey: .native) ?? .unread
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(from?.hex, forKey: .from)
            try container.encodeIfPresent(to?.hex, forKey: .to)
            try container.encode(value.hexQuantity, forKey: .value)
            try container.encode(nativeReceived, forKey: .native)
        }
    }

    /// What a sale into native MON paid the wallet, which no Transfer log carries (`nativeReceived`): not read yet (read
    /// at a build that may read), read, or unknowable — every read answered, and the wallet's balance change across the
    /// block can't say it (it sent another transaction in the same block). Unknowable is kept as such and never read
    /// again: the sale shows without an amount and stays out of P&L, which says it is incomplete.
    public enum NativeReceived: Sendable, Hashable, Codable {
        case unread
        case read(BigUInt)
        case unknowable

        /// The amount, once read.
        public var amount: BigUInt? {
            if case .read(let amount) = self { return amount }
            return nil
        }

        // One string: "unread", "unknowable", or the amount as a quantity ("0x…").
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            switch text {
            case "unread": self = .unread
            case "unknowable": self = .unknowable
            default:
                guard text.hasPrefix("0x"), let amount = BigUInt(hexQuantity: text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a native amount")
                }
                self = .read(amount)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .unread: try container.encode("unread")
            case .unknowable: try container.encode("unknowable")
            case .read(let amount): try container.encode(amount.hexQuantity)
            }
        }
    }

    /// What `reconstruct` built: the swaps, newest first; every transaction's facts, the known and the new; and the blocks
    /// of the one-sided transactions left out because their facts are still unread (`reading` false, a read that didn't
    /// answer, or past the `factsPerBuild` one build reads) — the swaps are a part until those are read.
    public struct Reconstruction: Sendable {
        public var records: [SwapRecord]
        public var facts: [Data: TransactionFacts]
        public var unreadBlocks: [UInt64]
        /// The transactions whose records this build asked for (`factsPerBuild` at most; none when not `reading`, or when
        /// none was left out), and how many of them it read: asked for and none read is an archive that isn't answering,
        /// which the history counts as a round that read nothing (`WalletHistorySnapshot.swapFactsFailed`).
        public var factsAsked = 0
        public var factsRead = 0
    }

    /// How many transactions' records one build reads (`eth_getTransactionByHash`), newest first: the rest at the next.
    static let factsPerBuild = 300

    /// `reconstruct`, with what was looked up per transaction before (`facts`) used again, and returned with the new.
    /// `reading` false: nothing is read — swaps whose other leg is native MON are built from known facts only, the
    /// one-sided transactions with none left out (`Reconstruction.unreadBlocks`), and sales into MON not read yet keep
    /// their amount unknown — for the instant read of the history from the device.
    public func reconstruct(wallet: Address, outgoing outLogs: [Log], incoming inLogs: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int],
                            limit: Int, facts known: [Data: TransactionFacts], reading: Bool = true) async -> Reconstruction {
        var facts = known
        // A swap's time: its block's own when its logs carry it, else estimated from the anchor.
        func time(_ block: UInt64, _ timestamp: Int?) -> Date {
            timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock)
        }

        // Group both directions by transaction; a swap is a tx with a spent leg and a received leg.
        struct Leg { let token: Address; let amount: BigUInt; let block: UInt64; let timestamp: Int? }
        var sent: [Data: [Leg]] = [:]
        var received: [Data: [Leg]] = [:]
        // Only ERC-20 transfers: exactly three topics and a 32-byte amount. ERC-721 `Transfer` shares the topic but
        // indexes the token id (four topics, empty data), and an NFT mint in a payment transaction is not a swap leg.
        func isERC20(_ log: Log) -> Bool { log.topics.count == 3 && log.data.count == 32 }
        func leg(_ log: Log) -> Leg { Leg(token: log.address, amount: BigUInt(log.data), block: log.blockNumber, timestamp: log.blockTimestamp) }
        for log in outLogs where isERC20(log) { sent[log.transactionHash, default: []].append(leg(log)) }
        for log in inLogs where isERC20(log) { received[log.transactionHash, default: []].append(leg(log)) }

        // Compare tokens by human value (decimals-normalized), not raw wei — otherwise an 18-decimal reward/refund
        // credited in the same tx would outrank a 6-decimal output. Unknown tokens assume 18.
        func human(_ token: Address, _ raw: BigUInt) -> Double { Double(raw) / pow(10, Double(decimals[token] ?? 18)) }
        // Sum legs per token (so a split route or same-token change lands as one total), then pick the dominant token.
        // The legs of one transaction share its block, and its time.
        func dominant(_ legs: [Leg], excluding: Address?) -> (token: Address, amount: BigUInt, block: UInt64, timestamp: Int?)? {
            var sums: [Address: BigUInt] = [:]
            var blocks: [Address: UInt64] = [:]
            for leg in legs where leg.token != excluding {
                sums[leg.token, default: 0] += leg.amount
                blocks[leg.token] = max(blocks[leg.token] ?? 0, leg.block)
            }
            guard let best = sums.max(by: { human($0.key, $0.value) < human($1.key, $1.value) }) else { return nil }
            return (best.key, best.value, blocks[best.key] ?? 0, legs.lazy.compactMap(\.timestamp).first)
        }

        var records: [SwapRecord] = []
        for (hash, sentLegs) in sent {
            guard let recvLegs = received[hash] else { continue }
            guard let sold = dominant(sentLegs, excluding: nil) else { continue }
            guard let bought = dominant(recvLegs, excluding: sold.token) else { continue }
            records.append(SwapRecord(hash: hash, block: sold.block, time: time(sold.block, sold.timestamp),
                                      soldToken: sold.token, soldAmount: sold.amount, boughtToken: bought.token, boughtAmount: bought.amount, blockTimestamp: sold.timestamp))
        }

        // One-sided transactions can still be swaps whose other leg is native MON, which leaves no Transfer log:
        // MON paid in (the transaction carries value) or MON received (a router unwrapped WMON for the wallet).
        // The transaction itself tells them apart from plain transfers and deposits: value from the wallet, or a
        // call into one of the swap routers.
        let receivedOnly = received.keys.filter { sent[$0] == nil }
        let sentOnly = sent.keys.filter { received[$0] == nil }
        let oneSided = receivedOnly + sentOnly
        var blocks: [Data: UInt64] = [:]
        for hash in oneSided { blocks[hash] = (received[hash] ?? sent[hash] ?? []).map(\.block).max() ?? 0 }
        // Looked up for the ones not known yet, newest first, up to `factsPerBuild` a build; the rest at the next.
        var asked = 0, read = 0
        if reading {
            let unknown = Array(oneSided.filter { facts[$0] == nil }.sorted { blocks[$0, default: 0] > blocks[$1, default: 0] }.prefix(Self.factsPerBuild))
            asked = unknown.count
            if !unknown.isEmpty, let answers = try? await archive.batch(unknown.map { ("eth_getTransactionByHash", [JSON.string($0.hexString)]) }) {
                for (hash, answer) in zip(unknown, answers) {
                    // A node behind the one the logs came from answers null: not a fact, asked again next time.
                    guard case .success(let tx) = answer, let from = tx["from"].string.flatMap(Address.init) else { continue }
                    let value = tx["value"].string.map { BigUInt($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) ?? 0 } ?? 0
                    facts[hash] = TransactionFacts(from: from, to: tx["to"].string.flatMap(Address.init), value: value)
                    read += 1
                }
            }
        }
        for hash in oneSided {
            guard let fact = facts[hash], fact.from == wallet else { continue }
            if let recvLegs = received[hash], fact.value > 0, let bought = dominant(recvLegs, excluding: nil) {
                records.append(SwapRecord(hash: hash, block: bought.block, time: time(bought.block, bought.timestamp),
                                          soldToken: Monad.native, soldAmount: fact.value, boughtToken: bought.token, boughtAmount: bought.amount, blockTimestamp: bought.timestamp))
            } else if let sentLegs = sent[hash], let to = fact.to, Self.swapRouters.contains(to), let sold = dominant(sentLegs, excluding: nil) {
                records.append(SwapRecord(hash: hash, block: sold.block, time: time(sold.block, sold.timestamp),
                                          soldToken: sold.token, soldAmount: sold.amount, boughtToken: Monad.native, boughtAmount: 0, blockTimestamp: sold.timestamp))
            }
        }
        let unread = oneSided.filter { facts[$0] == nil }.map { blocks[$0, default: 0] }
        let built = await withNativeReceived(records.sorted { $0.block > $1.block }.prefix(limit), wallet: wallet, facts: facts, reading: reading)
        return Reconstruction(records: built.records, facts: built.facts, unreadBlocks: unread, factsAsked: asked, factsRead: read)
    }

    /// How many sales into native MON, newest first, a scan reads the MON of (`withNativeReceived`): five reads each.
    static let nativeReadLimit = 50

    /// `records` with the MON each sale into native MON paid the wallet, which no Transfer log carries: the wallet's
    /// balance after the sale's block less its balance before it, plus the gas the sale cost (`nativeReceived`). A sale
    /// whose MON can't be read keeps 0, which the app shows as unknown ("→ MON"), never as "0 MON". Read for the newest
    /// `nativeReadLimit` sales not read yet, in one batch (none when not `reading`); a sale found unknowable is never read
    /// again, nor holds a place among them.
    private func withNativeReceived(_ records: ArraySlice<SwapRecord>, wallet: Address, facts known: [Data: TransactionFacts], reading: Bool) async -> (records: [SwapRecord], facts: [Data: TransactionFacts]) {
        var records = Array(records)
        var facts = known
        // What was read before is applied; the rest is read now, the newest `nativeReadLimit` of them.
        var unread: [Int] = []
        for i in records.indices where records[i].boughtToken == Monad.native && records[i].boughtAmount == 0 && records[i].block > 0 {
            switch facts[records[i].hash]?.nativeReceived ?? .unread {
            case .read(let amount): records[i] = records[i].receiving(amount)
            case .unknowable: continue
            case .unread: if unread.count < Self.nativeReadLimit { unread.append(i) }
            }
        }
        guard reading, !unread.isEmpty else { return (records, facts) }
        var calls: [(method: String, params: [JSON])] = []
        for i in unread {
            let block = records[i].block
            calls += [("eth_getTransactionReceipt", [.string(records[i].hash.hexString)]),
                      ("eth_getBalance", [.string(wallet.hex), BlockTag.number(block - 1).json]),
                      ("eth_getBalance", [.string(wallet.hex), BlockTag.number(block).json]),
                      ("eth_getTransactionCount", [.string(wallet.hex), BlockTag.number(block - 1).json]),
                      ("eth_getTransactionCount", [.string(wallet.hex), BlockTag.number(block).json])]
        }
        guard let answers = try? await archive.batch(calls), answers.count == calls.count else { return (records, facts) }
        func quantity(_ answer: Result<JSON, RPCError>, _ key: String? = nil) -> BigUInt? {
            guard case .success(let json) = answer else { return nil }
            return (key.map { json[$0] } ?? json).string.flatMap { BigUInt(hexQuantity: $0) }
        }
        for (k, i) in unread.enumerated() {
            let answer = Array(answers[(k * 5)..<(k * 5 + 5)])
            // Every read answered, for the sale's own block: else it is read again at the next build.
            guard case .success(let receipt) = answer[0], receipt["status"].string == "0x1",
                  receipt["blockNumber"].string.flatMap({ BigUInt(hexQuantity: $0) }) == BigUInt(records[i].block),
                  let gasUsed = quantity(answer[0], "gasUsed"), let gasPrice = quantity(answer[0], "effectiveGasPrice"),
                  let before = quantity(answer[1]), let after = quantity(answer[2]),
                  let nonceBefore = quantity(answer[3]), let nonceAfter = quantity(answer[4]) else { continue }
            // Answered in full: the balance change says what the sale paid, or it never will.
            let settled: NativeReceived
            if let received = Self.nativeReceived(balanceBefore: before, balanceAfter: after, gasFee: gasUsed * gasPrice, noncesBefore: nonceBefore, noncesAfter: nonceAfter) {
                records[i] = records[i].receiving(received)
                settled = .read(received)
            } else {
                settled = .unknowable
            }
            facts[records[i].hash, default: TransactionFacts(from: nil, to: nil, value: 0)].nativeReceived = settled
        }
        return (records, facts)
    }

    /// The MON a sale into native MON paid the wallet, from its balance on each side of the sale's block and the gas the
    /// sale cost (Monad's receipt reports what was charged): `after + gasFee − before`. Only when the sale is the wallet's
    /// one transaction in that block (its count of sent transactions moved by exactly one), so nothing else it sent moved
    /// its balance; nil otherwise, or when that comes to nothing.
    static func nativeReceived(balanceBefore: BigUInt, balanceAfter: BigUInt, gasFee: BigUInt, noncesBefore: BigUInt, noncesAfter: BigUInt) -> BigUInt? {
        guard noncesAfter == noncesBefore + 1, balanceAfter + gasFee > balanceBefore else { return nil }
        return balanceAfter + gasFee - balanceBefore
    }

    /// Contracts a swap for native MON is sent to: the routers DyorHQ itself routes through.
    static let swapRouters: Set<Address> = [Uniswap.universalRouter, MondayTrade.swapRouter, Kuru.entrypoint]
}
