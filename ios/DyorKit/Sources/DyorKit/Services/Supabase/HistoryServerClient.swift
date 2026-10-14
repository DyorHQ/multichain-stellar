import BigInt
import Foundation

/* The server's cache of a wallet's history (supabase migration 32, `history_read`): the history-indexer Edge Function
   reads the wallet's five scans (`WalletHistoryScans`) from the same public endpoints the app does, and keeps the raw logs
   with exactly the blocks they cover, so the device can take in one paged RPC what costs it minutes of `eth_getLogs`
   ("Reading your history… 46%" on Home). The app's decoders stay the only judge of what a log means: the server holds
   logs, never totals.

   What the server says is display-only, and it only ever ADDS coverage the device can prove from the document itself
   (`ServerScan.adoptable`, the exact rule of the contract): blocks the server covered for a filter at least as wide as the
   app's (`LogsQuery.isSubset(of:)`), no nearer the head than the margin a clamping endpoint's node could have answered
   short (`HistoryServerClient.trustMargin`), never a hole the indexer couldn't read nor the block of a log it didn't
   serve (`omitted`), never below the log cap's floor, and, for a read cut short, only the blocks above the last log it
   served. A document that fails any check — any error, a status other than 2xx, a version other than 1, `serving`
   false (the owner's instant switch), another wallet, anything that doesn't parse, `tracked` or a scan's definition
   changing between pages — is discarded whole, and the device reads the chain as it always has: the server never
   blocks, slows or replaces the device's own reads, and is not even needed. `HistoryStore.adopt` takes in a scan. */

/// What the server says of the wallet's first transaction (`history_read`'s `firstTx`), found by its own bisection over
/// the wallet's nonce and confirmed on a second endpoint before it is stored. A block it found only ever moves earlier.
public enum ServerFirstTransaction: Sendable, Equatable {
    /// Not looked up yet.
    case unknown
    /// The block of the wallet's first transaction.
    case found(UInt64)
    /// The wallet has sent none.
    case none
}

/// One scan of the server's history as one read found it (`HistoryServerClient`): the first page's account of it — the
/// filter, the bounds it speaks for, what is covered and what isn't — every log the read's pages served for it, and the
/// blocks the device may take in (`adoptable`).
public struct ServerScan: Sendable, Equatable {
    /// Global scans are kept once for every wallet (the launchpad, fee sharing, Moments); wallet scans per enrolled wallet
    /// (the transfers in and out), served only while the wallet is tracked.
    public enum Kind: String, Sendable, Equatable {
        case global
        case wallet
    }

    /// The app's scan id (`WalletHistoryScans`): the server names its scans as the app does.
    public let id: String
    public let kind: Kind
    /// The version of the server's definition of the scan: a change between pages aborts the read.
    public let defVersion: Int
    /// The filter the server read: the app's scan is taken in only when its own is a subset of it (`LogsQuery.isSubset`).
    public let query: LogsQuery
    /// The server's `canonicalFingerprint` of `query`, for logs and diagnostics.
    public let fingerprint: String
    /// The oldest block the server reads for the scan: a global scan's first contract, 0 for a wallet's.
    public let floor: UInt64
    /// The highest cap floor any page of the read reported (the newest 20,000 logs kept, as `HistoryStore.logCap`):
    /// below it, logs may have been dropped while the read went on, so nothing below it is taken in. Nil: no cap.
    public let capSeen: UInt64?
    /// The blocks the document speaks for, `[from, to]` (from 1 to 0: nothing to serve).
    public let from: UInt64
    public let to: UInt64
    /// What the first page said is covered, merged, within `[from, to]`.
    public let covered: [ClosedRange<UInt64>]
    /// Ranges the indexer couldn't read: never covered, read by the device as any gap.
    public let holes: [ClosedRange<UInt64>]
    /// The head of the server's last read of the scan, and its time; nil before its first.
    public let head: UInt64?
    public let headTimestamp: Int?
    /// The server's word that `[from, to]` is covered whole.
    public let complete: Bool
    /// The blocks of logs the server keeps without their data (over 16 KiB) and so didn't serve: the device reads them.
    public let omittedBlocks: [UInt64]
    /// More such logs than the document lists: the scan is not taken in at all.
    public let omittedTruncated: Bool
    /// The read went past this scan: every log it holds within `[from, to]` was served.
    public let finished: Bool
    /// The block of the last (oldest) log served for the scan; nil when none was.
    public let lowestServedBlock: UInt64?
    /// The read asked for a range of blocks (`p_from_block` / `p_to_block`), not the whole history.
    public let bounded: Bool
    /// The read asked for the account alone, no logs (`HistoryServerClient.metadata`): never taken in.
    public let metaOnly: Bool
    /// Every log served for the scan, newest first.
    public let logs: [Log]
    /// The blocks the device may take in from this read (`adoptable(...)`), merged, ascending.
    public let adoptable: [ClosedRange<UInt64>]

    /// The blocks of the server's scan the device may take in from one read — exactly the contract's rule (§16):
    ///
    ///     capSeen = max(capFloor over every page of the read)        — a cap raised mid-read clips, never widens
    ///     A = covered(page 1) ∩ [max(from, capSeen ?? 0), min(to, head − 1,200)]
    ///     A = A − holes − {block of each omitted log}
    ///     the read stopped before it moved past the scan: A ∩ [lowestServedBlock + 1, ∞) when it served a log of it, else ∅
    ///     omittedTruncated, or no head: ∅
    ///
    /// The margin below the head (`HistoryServerClient.trustMargin`) is what a node of a clamping endpoint up to 1,200
    /// blocks behind could have answered short, the server's own follow overlap: the device reads the newest blocks itself.
    /// A read cut short served the scan newest first down to some log, whose block it may have served only in part, hence
    /// the block above it.
    public static func adoptable(covered: [ClosedRange<UInt64>], from: UInt64, to: UInt64, capSeen: UInt64?, head: UInt64?, holes: [ClosedRange<UInt64>],
                                 omittedBlocks: [UInt64], omittedTruncated: Bool, finished: Bool, lowestServedBlock: UInt64?) -> [ClosedRange<UInt64>] {
        guard !omittedTruncated, let head, head >= HistoryServerClient.trustMargin else { return [] }
        let low = max(from, capSeen ?? 0), high = min(to, head - HistoryServerClient.trustMargin)
        guard low <= high else { return [] }
        var adoptable = BlockRanges.intersect(covered, low...high)
        adoptable = BlockRanges.subtract(adoptable, holes + omittedBlocks.map { $0...$0 })
        if !finished {
            guard let lowest = lowestServedBlock, lowest < UInt64.max else { return [] }
            adoptable = BlockRanges.intersect(adoptable, (lowest + 1)...UInt64.max)
        }
        return adoptable
    }
}

/// One read of the server's history of a wallet (`HistoryServerClient`), every page of it checked and assembled.
public struct ServerHistoryRead: Sendable, Equatable {
    public let wallet: Address
    /// The wallet is enrolled (a signed-in DyorHQ user): its transfer scans are served only then.
    public let tracked: Bool
    /// The indexer's last head and its time; nil before its first run.
    public let head: UInt64?
    public let headTimestamp: Int?
    /// The wallet's first transaction, as the server found it; nil when the document says nothing (untracked).
    public let firstTransaction: ServerFirstTransaction?
    /// The scans the server served that the app knows, by the app's scan id (`WalletHistoryScans`).
    public let scans: [String: ServerScan]
    /// Every page was read (`next` came back null): false when the read stopped at its pages or seconds.
    public let finished: Bool
    public let pages: Int
    public let bounded: Bool
    public let metaOnly: Bool

    /// The server's account of `scan`: the same id. Nil when it served none (untracked, a scan the server doesn't have).
    public func scan(_ scan: HistoryScan) -> ServerScan? { scans[scan.id] }
}

/// Why a read of the server's history was discarded (the caller reads the chain as before): developer diagnostics,
/// never shown.
public enum HistoryServerError: Error, Sendable, Equatable {
    /// No answer: the network, a timeout of the request itself.
    case transport(String)
    /// An HTTP status other than 2xx.
    case http(Int)
    /// A document of another version (nil: none said).
    case version(Int?)
    /// `serving` false: the owner turned the cache off, and the next read says so at once.
    case notServing
    /// A document about another wallet.
    case otherWallet
    /// Anything that doesn't parse, or breaks the document's rules (what, for diagnostics).
    case malformed(String)
    /// `tracked`, the scans served or a scan's definition changed between pages: every page is discarded.
    case changedBetweenPages(String)
    /// No page came back within the read's seconds.
    case timedOut
    /// The caller cancelled the read.
    case cancelled
    /// Bounds the server would refuse (`from` past `to`, or past what a JSON number holds exactly).
    case badBounds
}

/// Reads the server's history of a wallet (`history_read`, supabase migration 32) in pages, checks every page and
/// assembles them (`ServerHistoryRead`), with no other state: a full read (`read(wallet:)`), a range of it (`from`/`to`,
/// on every page), or the scans' account alone (`metadata`). A read takes at most `Limits.pages` pages and
/// `Limits.seconds`, and is cancelled with its task; one cut short by either keeps what arrived, which the adoptable rule
/// clips (`ServerScan.adoptable`). Throws `HistoryServerError` for everything else, and the caller reads the chain.
public struct HistoryServerClient: Sendable {
    /// What one read may spend: pages, and seconds from the first request's start.
    public struct Limits: Sendable, Equatable {
        public var pages: Int
        public var seconds: TimeInterval

        public init(pages: Int, seconds: TimeInterval) {
            self.pages = pages
            self.seconds = seconds
        }

        /// Twelve pages (up to 24,000 logs, about 18 MB at the server's 1.5 MB a page) and fifteen seconds: a wallet's
        /// whole history on a slow network, never long enough to keep a screen waiting — the screens never wait for it.
        public static let standard = Limits(pages: 12, seconds: 15)
    }

    /// Sends one page's request, the PostgREST RPC's JSON arguments, and returns the answer's body; throws with no answer
    /// or a status other than 2xx (`SupabaseClient.rpcJSON`).
    public typealias Transport = @Sendable (_ body: [String: JSON]) async throws -> Data

    /// The PostgREST function.
    public static let function = "history_read"
    /// The document's scans in the order it pages them (`history_read`'s `c_order`): a cursor `v1:<n>:…` continues the
    /// nth, and every scan before it was served whole.
    public static let scanOrder = [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId,
                                   WalletHistoryScans.transfersOutId, WalletHistoryScans.transfersInId]
    /// Each scan's kind, as the server defines it: a document saying otherwise is malformed.
    static let kinds: [String: ServerScan.Kind] = [WalletHistoryScans.launchpadId: .global, WalletHistoryScans.feeSharingId: .global,
                                                   WalletHistoryScans.momentsId: .global, WalletHistoryScans.transfersOutId: .wallet,
                                                   WalletHistoryScans.transfersInId: .wallet]
    /// Blocks below a scan's head the device never takes in: twice the margin a clamping endpoint is kept from the head
    /// by (`LogsEndpoints.headLag`), the region the server reads again on every run (its follow overlap) because a node
    /// of a clamping endpoint that far behind could have answered it short. The device reads them itself, as it reads the
    /// same again on every round (`HistoryStore.overlap`).
    public static let trustMargin: UInt64 = 2 * LogsEndpoints.headLag
    /// The largest whole number a JSON number (a double) holds exactly: block numbers sent and read past it are refused.
    static let largestExact: UInt64 = 1 << 53

    public let limits: Limits
    private let transport: Transport

    /// Reads through `supabase` with the publishable key: `history_read` is the one function anon may call, for one
    /// exact wallet.
    public init(supabase: SupabaseClient, limits: Limits = .standard) {
        self.init(limits: limits) { body in try await supabase.rpcJSON(name: Self.function, body: body) }
    }

    public init(limits: Limits = .standard, transport: @escaping Transport) {
        self.limits = limits
        self.transport = transport
    }

    /// The wallet's history, every page until the last, within `limits`: the whole of it, or the blocks from `from` to
    /// `to` when either is given (a top-up, or the ranges a poll found newly covered) — each bound sent on every page.
    public func read(wallet: Address, from: UInt64? = nil, to: UInt64? = nil) async throws -> ServerHistoryRead {
        try await read(wallet: wallet, from: from, to: to, metaOnly: false)
    }

    /// The scans' account alone (`p_meta_only`), no logs, in one page: what a poll compares with what the device holds
    /// (`ServerHistoryPlan.newlyCovered`). Never taken in (`HistoryStore.adopt` refuses it).
    public func metadata(wallet: Address, from: UInt64? = nil, to: UInt64? = nil) async throws -> ServerHistoryRead {
        try await read(wallet: wallet, from: from, to: to, metaOnly: true)
    }

    private func read(wallet: Address, from: UInt64?, to: UInt64?, metaOnly: Bool) async throws -> ServerHistoryRead {
        if let from, let to, from > to { throw HistoryServerError.badBounds }
        guard (from ?? 0) <= Self.largestExact, (to ?? 0) <= Self.largestExact else { throw HistoryServerError.badBounds }
        let deadline = ContinuousClock.now + .seconds(limits.seconds)
        var body: [String: JSON] = ["p_wallet": .string(wallet.hex)]
        if let from { body["p_from_block"] = .number(Double(from)) }
        if let to { body["p_to_block"] = .number(Double(to)) }
        if metaOnly { body["p_meta_only"] = .bool(true) }

        var assembly: Assembly?
        var cursor: String?
        var finished = false
        var pages = 0
        while pages < max(1, limits.pages) {
            if Task.isCancelled { throw HistoryServerError.cancelled }
            let left = deadline - ContinuousClock.now
            guard left > .zero else { break }
            var request = body
            if let cursor { request["p_cursor"] = .string(cursor) }
            guard let data = try await page(request, within: left) else { break }
            let page = try Page(data, wallet: wallet, first: assembly == nil, metaOnly: metaOnly)
            pages += 1
            if assembly == nil {
                assembly = try Assembly(first: page)
            } else {
                try assembly?.add(page, after: cursor.flatMap(Self.scanNumber) ?? 1)
            }
            guard let next = page.next else { finished = true; break }
            // A meta-only answer is one page; a cursor must move on, never back to a scan already served whole.
            guard !metaOnly else { throw HistoryServerError.malformed("a next page after the metadata") }
            if let cursor, next == cursor || (Self.scanNumber(next) ?? 0) < (Self.scanNumber(cursor) ?? 0) {
                throw HistoryServerError.malformed("a cursor that doesn't move on")
            }
            cursor = next
        }
        guard let assembly else { throw Task.isCancelled ? HistoryServerError.cancelled : HistoryServerError.timedOut }
        if Task.isCancelled { throw HistoryServerError.cancelled }
        return assembly.read(wallet: wallet, finished: finished, stoppedAt: finished ? nil : cursor, pages: pages, bounded: from != nil || to != nil, metaOnly: metaOnly)
    }

    /// One page's answer within `seconds`; nil when they ran out first (the request is cancelled).
    private func page(_ body: [String: JSON], within seconds: Duration) async throws -> Data? {
        let transport = self.transport
        do {
            return try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask { try await transport(body) }
                group.addTask { try await Task.sleep(for: seconds); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            if Task.isCancelled { throw HistoryServerError.cancelled }
            if case SupabaseError.http(let status, _) = error { throw HistoryServerError.http(status) }
            if let failure = error as? URLError { throw HistoryServerError.transport("URLError \(failure.code.rawValue)") }
            throw HistoryServerError.transport(String(describing: type(of: error)))
        }
    }

    /// The scan a cursor (`v1:<n>:…`) continues, 1 to 5; nil for anything else.
    static func scanNumber(_ cursor: String) -> Int? {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "v1", let number = Int(parts[1]), (1...scanOrder.count).contains(number) else { return nil }
        return number
    }

    // MARK: Pages

    /// One scan's first-page account (`ServerScan` without what the pages add).
    private struct Account {
        let kind: ServerScan.Kind
        let query: LogsQuery
        let fingerprint: String
        let floor: UInt64
        let from: UInt64
        let to: UInt64
        let covered: [ClosedRange<UInt64>]
        let holes: [ClosedRange<UInt64>]
        let head: UInt64?
        let headTimestamp: Int?
        let complete: Bool
        let omittedBlocks: [UInt64]
        let omittedTruncated: Bool
    }

    /// What one page says of one scan.
    private struct ScanPage {
        let defVersion: Int
        let capFloor: UInt64?
        /// Newest first, as served.
        let logs: [Log]
        /// The first page's account; nil on later pages.
        let account: Account?
    }

    /// One page, parsed and checked on its own: the version, the switch, the wallet, and every field the app reads, of
    /// the scans the app knows (a scan it doesn't is left alone).
    private struct Page {
        let tracked: Bool
        let head: UInt64?
        let headTimestamp: Int?
        let firstTransaction: ServerFirstTransaction?
        let scans: [String: ScanPage]
        let next: String?

        init(_ data: Data, wallet: Address, first: Bool, metaOnly: Bool) throws {
            guard let json = try? JSONDecoder().decode(JSON.self, from: data), json.object != nil else { throw HistoryServerError.malformed("not a JSON object") }
            guard let version = Number.whole(json["version"]) else { throw HistoryServerError.version(nil) }
            guard version == 1 else { throw HistoryServerError.version(Int(version)) }
            guard let serving = json["serving"].bool else { throw HistoryServerError.malformed("serving") }
            guard serving else { throw HistoryServerError.notServing }
            guard let named = json["wallet"].string, Address(named) == wallet else { throw HistoryServerError.otherWallet }
            guard let tracked = json["tracked"].bool else { throw HistoryServerError.malformed("tracked") }
            self.tracked = tracked
            head = try Number.optional(json["head"], "head")
            headTimestamp = try Number.optional(json["headTimestamp"], "headTimestamp").map(Int.init)
            if first { firstTransaction = try Self.firstTransaction(json["firstTx"]) } else { firstTransaction = nil }
            switch json["next"] {
            case .null: next = nil
            case .string(let cursor) where scanNumber(cursor) != nil: next = cursor
            default: throw HistoryServerError.malformed("next")
            }
            guard let served = json["scans"].object else { throw HistoryServerError.malformed("scans") }
            var scans: [String: ScanPage] = [:]
            for (id, document) in served {
                guard let kind = kinds[id] else { continue }
                let page = try Self.scan(document, id: id, first: first)
                if let account = page.account {
                    guard account.kind == kind else { throw HistoryServerError.malformed("\(id): kind") }
                    guard kind == .global || tracked else { throw HistoryServerError.malformed("\(id): a wallet scan of an untracked wallet") }
                }
                guard !metaOnly || page.logs.isEmpty else { throw HistoryServerError.malformed("\(id): logs in the metadata") }
                scans[id] = page
            }
            self.scans = scans
        }

        private static func firstTransaction(_ json: JSON) throws -> ServerFirstTransaction? {
            if json.isNull { return nil }
            switch json["state"].string {
            case "unknown": return .unknown
            case "none": return ServerFirstTransaction.none
            case "found":
                guard let block = Number.whole(json["block"]) else { throw HistoryServerError.malformed("firstTx.block") }
                return .found(block)
            default: throw HistoryServerError.malformed("firstTx.state")
            }
        }

        private static func scan(_ json: JSON, id: String, first: Bool) throws -> ScanPage {
            guard json.object != nil else { throw HistoryServerError.malformed(id) }
            guard let defVersion = Number.whole(json["defVersion"]), defVersion <= UInt64(Int32.max) else { throw HistoryServerError.malformed("\(id): defVersion") }
            let capFloor = try Number.optional(json["capFloor"], "\(id): capFloor")
            guard let items = json["logs"].array else { throw HistoryServerError.malformed("\(id): logs") }
            var logs: [Log] = []
            logs.reserveCapacity(items.count)
            for item in items {
                // eth_getLogs JSON (`Log(json:)`); `removed`, when there, false: a log of a block the chain dropped is no log.
                guard let log = Log(json: item), item["removed"] == .null || item["removed"] == .bool(false) else {
                    throw HistoryServerError.malformed("\(id): a log")
                }
                logs.append(log)
            }
            var account: Account?
            if first { account = try Self.account(json, id: id) }
            return ScanPage(defVersion: Int(defVersion), capFloor: capFloor, logs: logs, account: account)
        }

        private static func account(_ json: JSON, id: String) throws -> Account {
            func whole(_ key: String) throws -> UInt64 {
                guard let value = Number.whole(json[key]) else { throw HistoryServerError.malformed("\(id): \(key)") }
                return value
            }
            func flag(_ key: String) throws -> Bool {
                guard let value = json[key].bool else { throw HistoryServerError.malformed("\(id): \(key)") }
                return value
            }
            guard let kind = json["kind"].string.flatMap(ServerScan.Kind.init(rawValue:)) else { throw HistoryServerError.malformed("\(id): kind") }
            guard let query = Self.query(json["query"]) else { throw HistoryServerError.malformed("\(id): query") }
            let head = try Number.optional(json["head"], "\(id): head")
            let headTimestamp = try Number.optional(json["headTimestamp"], "\(id): headTimestamp")
            // A head and its time come from the same commit: one without the other is no head the device can anchor to.
            guard (head == nil) == (headTimestamp == nil) else { throw HistoryServerError.malformed("\(id): head without its time") }
            guard let covered = Number.ranges(json["covered"]) else { throw HistoryServerError.malformed("\(id): covered") }
            guard let holes = Number.ranges(json["holes"]) else { throw HistoryServerError.malformed("\(id): holes") }
            guard let omitted = json["omitted"].array else { throw HistoryServerError.malformed("\(id): omitted") }
            var omittedBlocks: [UInt64] = []
            for entry in omitted {
                guard let hex = entry["blockNumber"].string, let block = BigUInt(hexQuantity: hex), block <= BigUInt(largestExact) else {
                    throw HistoryServerError.malformed("\(id): an omitted log")
                }
                omittedBlocks.append(UInt64(block))
            }
            let floor = try whole("floor"), from = try whole("from"), to = try whole("to")
            let complete = try flag("complete"), truncated = try flag("omittedTruncated")
            return Account(kind: kind, query: query, fingerprint: json["fingerprint"].string ?? "", floor: floor, from: from, to: to, covered: covered, holes: holes,
                           head: head, headTimestamp: headTimestamp.map(Int.init), complete: complete, omittedBlocks: omittedBlocks, omittedTruncated: truncated)
        }

        /// `{"addresses": ["0x…"], "topics": [["0x…"], null, …]}`: every address 20 bytes, every topic 32.
        private static func query(_ json: JSON) -> LogsQuery? {
            guard let addressList = json["addresses"].array, let topicList = json["topics"].array else { return nil }
            var addresses: [Address] = []
            for item in addressList {
                guard let text = item.string, let address = Address(text) else { return nil }
                addresses.append(address)
            }
            var topics: [[Data]?] = []
            for position in topicList {
                if position.isNull { topics.append(nil); continue }
                guard let list = position.array else { return nil }
                var words: [Data] = []
                for item in list {
                    guard let text = item.string, let word = Data(hex: text), word.count == 32 else { return nil }
                    words.append(word)
                }
                topics.append(words)
            }
            return LogsQuery(addresses: addresses, topics: topics)
        }
    }

    /// The JSON numbers of the document: block numbers and versions, whole and exact.
    private enum Number {
        /// A whole number from 0 to 2^53; nil for anything else (a fraction, a string, a number a double can't hold).
        static func whole(_ json: JSON) -> UInt64? {
            guard case .number(let value) = json, value.isFinite, value >= 0, value <= Double(largestExact), value.rounded(.towardZero) == value else { return nil }
            return UInt64(value)
        }

        /// `whole`, or nil for a JSON null or a key left out; anything else throws.
        static func optional(_ json: JSON, _ what: String) throws -> UInt64? {
            if json.isNull { return nil }
            guard let value = whole(json) else { throw HistoryServerError.malformed(what) }
            return value
        }

        /// `[[a, b], …]` with a ≤ b, merged; nil for anything else.
        static func ranges(_ json: JSON) -> [ClosedRange<UInt64>]? {
            guard let pairs = json.array else { return nil }
            var out: [ClosedRange<UInt64>] = []
            for pair in pairs {
                guard let bounds = pair.array, bounds.count == 2, let low = whole(bounds[0]), let high = whole(bounds[1]), low <= high else { return nil }
                out.append(low...high)
            }
            return LogsRead.merge(out)
        }
    }

    // MARK: Assembly

    /// The pages of one read so far: the first page's account of each scan, and what every page added — the logs, in the
    /// order served, and the highest cap floor seen — with every rule across pages checked as a page comes in.
    private struct Assembly {
        struct Scan {
            let account: Account
            let defVersion: Int
            var capSeen: UInt64?
            /// Newest first.
            var logs: [Log] = []
        }

        let tracked: Bool
        let head: UInt64?
        let headTimestamp: Int?
        let firstTransaction: ServerFirstTransaction?
        private(set) var scans: [String: Scan] = [:]

        init(first page: Page) throws {
            tracked = page.tracked
            head = page.head
            headTimestamp = page.headTimestamp
            firstTransaction = page.firstTransaction
            for (id, scan) in page.scans {
                guard let account = scan.account else { throw HistoryServerError.malformed("\(id): no account on the first page") }
                scans[id] = Scan(account: account, defVersion: scan.defVersion, capSeen: scan.capFloor)
                try append(scan.logs, to: id)
            }
        }

        /// A later page, asked with a cursor continuing scan number `after`: the same `tracked`, the same scans with the
        /// same definitions, and no log of a scan before the cursor's.
        mutating func add(_ page: Page, after cursorScan: Int) throws {
            guard page.tracked == tracked else { throw HistoryServerError.changedBetweenPages("tracked") }
            guard Set(page.scans.keys) == Set(scans.keys) else { throw HistoryServerError.changedBetweenPages("the scans served") }
            for (id, scan) in page.scans {
                guard let held = scans[id] else { continue }
                guard scan.defVersion == held.defVersion else { throw HistoryServerError.changedBetweenPages("\(id): defVersion") }
                if let cap = scan.capFloor { scans[id]?.capSeen = max(held.capSeen ?? 0, cap) }
                if !scan.logs.isEmpty, let number = HistoryServerClient.scanOrder.firstIndex(of: id).map({ $0 + 1 }), number < cursorScan {
                    throw HistoryServerError.malformed("\(id): logs after the cursor moved past it")
                }
                try append(scan.logs, to: id)
            }
        }

        /// Adds a page's logs of a scan: each within the bounds the first page promised, each strictly older than the last
        /// one served (newest first by block and log index, across pages) — the order the cut-short rule stands on.
        private mutating func append(_ logs: [Log], to id: String) throws {
            guard var scan = scans[id] else { return }
            for log in logs {
                guard scan.account.from <= scan.account.to, log.blockNumber >= scan.account.from, log.blockNumber <= scan.account.to else {
                    throw HistoryServerError.malformed("\(id): a log outside the bounds")
                }
                if let last = scan.logs.last, (log.blockNumber, log.logIndex) >= (last.blockNumber, last.logIndex) {
                    throw HistoryServerError.malformed("\(id): logs not newest first")
                }
                scan.logs.append(log)
            }
            scans[id] = scan
        }

        /// The read, its scans' adoptable blocks worked out. `stoppedAt`: the cursor the read would have asked next, when
        /// it stopped short; every scan before the cursor's was served whole.
        func read(wallet: Address, finished: Bool, stoppedAt cursor: String?, pages: Int, bounded: Bool, metaOnly: Bool) -> ServerHistoryRead {
            let stopped = finished ? Int.max : cursor.flatMap(HistoryServerClient.scanNumber) ?? 0
            var out: [String: ServerScan] = [:]
            for (id, scan) in scans {
                let account = scan.account
                let number = (HistoryServerClient.scanOrder.firstIndex(of: id) ?? 0) + 1
                let done = finished || number < stopped
                let lowest = scan.logs.last?.blockNumber
                let adoptable = ServerScan.adoptable(covered: account.covered, from: account.from, to: account.to, capSeen: scan.capSeen, head: account.head,
                                                     holes: account.holes, omittedBlocks: account.omittedBlocks, omittedTruncated: account.omittedTruncated,
                                                     finished: done, lowestServedBlock: lowest)
                out[id] = ServerScan(id: id, kind: account.kind, defVersion: scan.defVersion, query: account.query, fingerprint: account.fingerprint, floor: account.floor,
                                     capSeen: scan.capSeen, from: account.from, to: account.to, covered: account.covered, holes: account.holes, head: account.head,
                                     headTimestamp: account.headTimestamp, complete: account.complete, omittedBlocks: account.omittedBlocks,
                                     omittedTruncated: account.omittedTruncated, finished: done, lowestServedBlock: lowest, bounded: bounded, metaOnly: metaOnly,
                                     logs: scan.logs, adoptable: adoptable)
            }
            return ServerHistoryRead(wallet: wallet, tracked: tracked, head: head, headTimestamp: headTimestamp, firstTransaction: firstTransaction, scans: out,
                                     finished: finished, pages: pages, bounded: bounded, metaOnly: metaOnly)
        }
    }
}

/// Sets of blocks as merged, ascending ranges.
enum BlockRanges {
    /// `ranges` within `bound`.
    static func intersect(_ ranges: [ClosedRange<UInt64>], _ bound: ClosedRange<UInt64>) -> [ClosedRange<UInt64>] {
        LogsRead.merge(ranges).compactMap { range in
            let low = max(range.lowerBound, bound.lowerBound), high = min(range.upperBound, bound.upperBound)
            return low <= high ? low...high : nil
        }
    }

    /// `ranges` without any block of `cuts`.
    static func subtract(_ ranges: [ClosedRange<UInt64>], _ cuts: [ClosedRange<UInt64>]) -> [ClosedRange<UInt64>] {
        let cuts = LogsRead.merge(cuts)
        var out: [ClosedRange<UInt64>] = []
        for range in LogsRead.merge(ranges) {
            var low = range.lowerBound
            var whole = true
            for cut in cuts where cut.upperBound >= low && cut.lowerBound <= range.upperBound {
                if cut.lowerBound > low { out.append(low...(cut.lowerBound - 1)) }
                guard cut.upperBound < range.upperBound else { whole = false; break }
                low = cut.upperBound + 1
            }
            if whole { out.append(low...range.upperBound) }
        }
        return out
    }

    /// Whether `block` lies in one of `ranges`.
    static func contains(_ ranges: [ClosedRange<UInt64>], _ block: UInt64) -> Bool {
        ranges.contains { $0.contains(block) }
    }
}
