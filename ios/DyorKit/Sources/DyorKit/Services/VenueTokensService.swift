import Foundation

/// Builds the tradeable-asset list straight from the venues themselves — every token that has a pool on Uniswap v3,
/// Monday Trade, or Uniswap v4 on Monad — by scanning their pool-creation events. Symbols/decimals are read on-chain
/// (authoritative); logos are left for the caller to enrich (Kuru's CDN), since the venues don't serve icons and the
/// canonical token-list ships unrenderable SVGs. This is the "real assets, accurate metadata" source behind the
/// swap picker, distinct from a curated hardcoded list.
public struct VenueTokensService: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall

    /// `logsRPC` reads the venues' events from genesis. On rpc1, which answers a range of any span up to 10K logs and names
    /// the part it can answer past that (`RPCClient.answersAnyRange`), each venue's segment is one range (`segment`):
    /// about 70 requests from genesis, one at a time, where 100,000-block ranges took 2,714 and drew 1,000 HTTP 429s from
    /// the endpoint every other reader in the app shares. Elsewhere, ranges the endpoint's size (`logChunkSize`).
    public init(logsRPC: RPCClient, multicall: Multicall) {
        self.logsRPC = logsRPC
        self.multicall = multicall
    }

    // Uniswap v3 / Monday Trade share the v3 PoolCreated shape; Uniswap v4 uses the PoolManager's Initialize.
    private static let poolCreated = "PoolCreated(address,address,uint24,int24,address)"
    private static let initialize = "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"

    /// Blocks a refresh reads between saves (`refresh`), so progress survives an interruption.
    public static let segment: UInt64 = 5_000_000

    /// Blocks a refresh stays behind the chain head (`Progress.target`), read by the next one. Monad finalizes a block two
    /// rounds after it is proposed (under a second) and executes a few blocks behind consensus, and rpc1's nodes can be a
    /// few blocks apart: the head comes from one, the logs from another, which refuses a range past its own head (-32602
    /// "block range extends beyond current head block"). 100 blocks, about 30 s, covers all three many times over, so
    /// the checkpoint never passes a block that isn't final or that the node answering hasn't reached.
    public static let headMargin: UInt64 = 100

    /// A block Monad mainnet had passed when this build was made (its head was 109,160,032 on 2026-09-30): a list read to
    /// short of it is short of the chain, when no run could read the head (`VenueTokenList.isCatchingUp`).
    public static let knownHeight: UInt64 = 109_000_000

    /// Requests a refresh may make to read metadata again past each batch's first read (`ERC20.metadataReport`): a token
    /// whose symbol can't be read in its read, the first read on its own, the others (and what answered what isn't a
    /// symbol) once more together, then one by one.
    /// A real token that fails costs one. Addresses anyone can put in a Uniswap v4 pool (`initialize` takes any pair) cost
    /// a request each without it — 3,000 of them 3,060 requests, an out-of-gas call 0.6–0.8 s, on the endpoint Send, Swap
    /// and prices use — and 260 with it. Past it, what is left is unread: the segment is read again by a later run, which
    /// leaves out what this one dropped.
    public static let metadataRereads = 200

    /// The longest symbol and name the list keeps, in Unicode scalars (four UTF-8 bytes at most each, so 128 and 256
    /// bytes): a token's `symbol()` can return a string of any length, and the list is stored whole. Characters don't
    /// bound it: "A" and 50,000 combining accents are one character, 100 KB.
    public static let maxSymbol = 32
    public static let maxName = 64

    /// `token` with its symbol and name cut to `maxSymbol` and `maxName` Unicode scalars.
    public static func capped(_ token: Token) -> Token {
        guard token.symbol.unicodeScalars.count > maxSymbol || token.name.unicodeScalars.count > maxName else { return token }
        return Token(address: token.address, symbol: prefix(token.symbol, scalars: maxSymbol), name: prefix(token.name, scalars: maxName),
                     decimals: token.decimals, logoURL: token.logoURL, isLaunchpad: token.isLaunchpad)
    }

    /// The first `scalars` Unicode scalars of `text`.
    private static func prefix(_ text: String, scalars: Int) -> String {
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: text.unicodeScalars.prefix(scalars))
        return String(cut)
    }

    /// What one read of the venues found (`tokens`).
    public struct Scan: Sendable, Equatable {
        public var tokens: [Token]
        /// Whether the window was read in full: every venue's ranges (`RPCClient.chunkedLogsReport`) and the metadata of
        /// every token found. False when a range was left as a gap, a metadata read got no answer or was left for a later
        /// run past `metadataRereads`, or the read was cancelled.
        public var complete: Bool
        /// Whether more tokens gained a pool than the read's `limit`: the first are here, and a read of the same window
        /// that excludes them, and `dropped`, brings the rest.
        public var capped: Bool
        /// Addresses with no readable symbol (`ERC20.metadataReport`), left out as `ERC20.metadata` leaves them out.
        public var dropped: [Address]
        /// Metadata requests made past each batch's first read (`metadataRereads`).
        public var rereads: Int

        public init(tokens: [Token], complete: Bool, capped: Bool = false, dropped: [Address] = [], rereads: Int = 0) {
            self.tokens = tokens
            self.complete = complete
            self.capped = capped
            self.dropped = dropped
            self.rereads = rereads
        }
    }

    /// Chain head, for a caller that scans the full history in checkpointed segments.
    public func head() async -> UInt64 { (try? await logsRPC.block(.latest))?.number ?? 0 }

    /// Tokens that gained a pool on any venue between `fromBlock` and `toBlock`, resolved to on-chain metadata, and
    /// whether the window was read in full. Quote/stable/hop assets and anything in `exclude` are dropped; the first
    /// `limit` are kept (newest pools first), and the read says when there were more. The metadata is read again past
    /// each batch's first read at most `rereads` times (`metadataRereads`). Callers scan the full history from genesis in
    /// segments (`refresh`), checkpointing each segment once it is read in full.
    ///
    /// The venues are read one after the other, one request at a time (`LogScanMode.paced`: a throttle is waited out,
    /// never split), and a venue read in part ends the read there: the window is read again anyway, and the next venue
    /// would meet the same endpoint. On the logs router the requests wait in the gate's background lane
    /// (`LogsGate.Lane.background`): one at a time, only while no screen's scan and no history round waits, so a fresh
    /// install's list from genesis (about 5,600 requests) never slows the wallet's first history fill or a screen. The
    /// app holds the run while that history fills in, and a read from genesis until a wallet is signed in
    /// (`VenueTokenList.follow`).
    public func tokens(fromBlock: UInt64, toBlock: UInt64, exclude: Set<Address> = [], limit: Int = 3000, rereads: Int = Self.metadataRereads) async -> Scan {
        guard fromBlock <= toBlock else { return Scan(tokens: [], complete: true) }
        let created = ABI.eventTopic(Self.poolCreated)
        let initialized = ABI.eventTopic(Self.initialize)
        let chunk: UInt64? = logsRPC.answersAnyRange ? Self.segment : nil

        var scans: [(logs: [Log], complete: Bool)] = []
        for (venue, topic) in [(Uniswap.v3Factory, created), (MondayTrade.factory, created), (Uniswap.poolManager, initialized)] {
            let scan = await logsRPC.chunkedLogsReport(address: venue, topics: [topic], fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunk,
                                                       concurrency: 1, mode: .paced, lane: .background)
            scans.append(scan)
            if !scan.complete { break }
        }
        let read = scans.count == 3 && scans.allSatisfy(\.complete)
        let unread: (logs: [Log], complete: Bool) = ([], false)
        let (v3Scan, mondayScan, v4Scan) = (scans[0], scans.count > 1 ? scans[1] : unread, scans.count > 2 ? scans[2] : unread)

        // Exclude the quote/stable/hop assets (they're already curated) so the list is the tradeable long tail.
        var seen: Set<Address> = [Monad.native, Monad.wmon, Monad.usdc, Monad.ausd, Monad.usdt0, Monad.weth]
        seen.formUnion(exclude)
        var addresses: [Address] = []
        func consider(_ address: Address?) { if let address, seen.insert(address).inserted { addresses.append(address) } }
        // v3 / Monday: token0 = indexedAddress(0), token1 = indexedAddress(1). Newest pools first for relevance.
        for log in (v3Scan.logs + mondayScan.logs).sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(0)); consider(log.indexedAddress(1))
        }
        // v4: topic1 is the poolId; currency0 = indexedAddress(1), currency1 = indexedAddress(2).
        for log in v4Scan.logs.sorted(by: { $0.blockNumber > $1.blockNumber }) {
            consider(log.indexedAddress(1)); consider(log.indexedAddress(2))
        }
        guard !addresses.isEmpty else { return Scan(tokens: [], complete: read) }
        let capped = addresses.count > max(1, limit)
        if capped { addresses = Array(addresses.prefix(max(1, limit))) }
        let metadata = await ERC20.metadataReport(addresses, multicall: multicall, rereads: rereads)
        return Scan(tokens: metadata.tokens.map(Self.capped), complete: read && metadata.unread.isEmpty && !Task.isCancelled, capped: capped,
                    dropped: metadata.dropped, rereads: metadata.rereads)
    }

    /// Where a refresh has got to (`refresh`): the list, and the last block it is read up to in full.
    public struct Progress: Sendable, Equatable {
        public var tokens: [Token]
        public var checkpoint: UInt64
        /// Addresses read with no readable symbol, by this refresh and those before it that it was handed: left out of
        /// every read after, as the list's tokens are, so a segment read again doesn't read them again.
        public var dropped: Set<Address>
        /// The chain head the refresh read.
        public var head: UInt64
        /// The block the refresh reads up to: `headMargin` behind the head.
        public var target: UInt64 { VenueTokensService.target(head: head) }
        /// Whether the list is read up to `target`.
        public var complete: Bool { checkpoint >= target }

        public init(tokens: [Token], checkpoint: UInt64, head: UInt64, dropped: Set<Address> = []) {
            self.tokens = tokens
            self.checkpoint = checkpoint
            self.head = head
            self.dropped = dropped
        }
    }

    /// The block a refresh reads up to when the chain head is `head` (`headMargin`).
    public static func target(head: UInt64) -> UInt64 { head > headMargin ? head - headMargin : 0 }

    /// Brings a venue list up to the chain head, `headMargin` behind it (`Progress.target`): from the block after
    /// `checkpoint` (from genesis when it is 0), in segments of `segment` blocks. Each segment's new tokens are added to
    /// the list, with their logo from `logos` (read once, only when there is something to read), and the list is handed to
    /// `save` with its checkpoint. The checkpoint moves past a segment only once every venue was read in it in full, and
    /// every token found was read (`Scan`); a segment read in part keeps what it found, ends the refresh there, and is read
    /// again by the next one. A segment with more new tokens than one read keeps (`limit`) is read again at once, what it
    /// found or dropped excluded, until the rest are in. What an earlier refresh read with no readable symbol
    /// (`dropped`, `Progress.dropped`) is left out as the list's tokens are, and the metadata is read again at most
    /// `rereads` times in all (`metadataRereads`). Returns where it got to, to the target or short of it; nil when the head
    /// couldn't be read, so nothing was.
    @discardableResult
    public func refresh(tokens known: [Token], checkpoint: UInt64, dropped: Set<Address> = [], logos: @Sendable () async -> [Address: URL],
                        segment: UInt64 = Self.segment, limit: Int = 3000, rereads: Int = Self.metadataRereads,
                        save: @Sendable (Progress) async -> Void) async -> Progress? {
        var progress = Progress(tokens: known, checkpoint: checkpoint, head: await head(), dropped: dropped)
        guard progress.head > 0 else { return nil }
        let target = progress.target
        guard checkpoint < target else { return progress }
        let logos = await logos()
        var rereads = rereads
        var from = checkpoint == 0 ? 0 : checkpoint + 1
        while from <= target, !Task.isCancelled {
            let to = min(from + max(1, segment) - 1, target)
            let exclude = Set(Token.core.map(\.address)).union(progress.tokens.map(\.address)).union(progress.dropped)
            let scan = await tokens(fromBlock: from, toBlock: to, exclude: exclude, limit: limit, rereads: max(0, rereads))
            rereads -= scan.rereads
            progress.dropped.formUnion(scan.dropped)
            progress.tokens += scan.tokens.map { token -> Token in
                guard token.logoURL == nil, let logo = logos[token.address] else { return token }
                return Token(address: token.address, symbol: token.symbol, name: token.name, decimals: token.decimals, logoURL: logo, isLaunchpad: token.isLaunchpad)
            }
            if scan.complete, !scan.capped { progress.checkpoint = to }
            await save(progress)
            // A gap is left for the next refresh: asking again now would get the same answer.
            guard scan.complete else { break }
            // The same segment again, what it read now excluded: at least `limit` fewer each time, so this ends.
            if scan.capped { continue }
            guard to < target else { break }
            from = to + 1
        }
        return progress
    }
}
