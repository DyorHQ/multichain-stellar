import BigInt
import Foundation

/// Discovers every ERC-20 a wallet actually holds by scanning its incoming `Transfer` logs — no indexer and no
/// curated list needed. This is what surfaces a token received on-chain (a swap on another app, an airdrop, a plain
/// transfer) that was never added by hand, so it shows in holdings and the swap picker like any curated asset.
///
/// The scan is address-filter-free — the wallet is a log topic — so ONE pass over the window finds every token that
/// has paid into the wallet; a `balanceOf` sweep then keeps only what is still held, and metadata resolves each.
public struct WalletTokenDiscovery: Sendable {
    private let logsRPC: RPCClient
    private let multicall: Multicall

    public init(logsRPC: RPCClient, multicall: Multicall) {
        self.logsRPC = logsRPC
        self.multicall = multicall
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// How far back a scan reads unless it reads the whole history: a block budget, 6,480,000 blocks (about 22.7 days at
    /// Monad's pace), kept as it was when it was called 30 days. Reading a true 30 days would cost about a third more
    /// log reads for every wallet scan.
    public static let defaultWindowBlocks: UInt64 = 6_480_000

    /// The tokens to show as Unverified once, after an upgrade from builds that stored every token found in the
    /// wallet's history as if the user had chosen it (security audit 2026-09-26, IOST-12) — discovery skips a token
    /// already stored, so it would never be marked otherwise. That is all of `stored` except native MON and the curated
    /// list, plus those already marked: nothing recorded which of them the user bought in the app, so each is marked,
    /// and a later swap into it clears the mark.
    public static func unverifiedAfterUpgrade(stored: [Token], alreadyUnverified: Set<Address>) -> Set<Address> {
        alreadyUnverified.union(stored.filter { !$0.isNative && Token.core($0.address) == nil }.map(\.address))
    }

    /// The ERC-20 tokens the wallet currently holds (balance > 0), resolved to `Token` metadata. `windowBlocks` bounds
    /// how far back the incoming-transfer scan looks; `known` addresses (already-surfaced tokens, native MON) are skipped
    /// so only NEW tokens are read.
    public func heldTokens(wallet: Address, windowBlocks: UInt64 = WalletTokenDiscovery.defaultWindowBlocks, known: Set<Address> = [], wholeHistory: Bool = false) async -> [Token] {
        await scan(wallet: wallet, windowBlocks: windowBlocks, known: known, wholeHistory: wholeHistory).tokens
    }

    /// What a scan found, and whether every read it needed answered.
    public struct Scan: Sendable, Equatable {
        public let tokens: [Token]
        /// False when the chain head, part of the history, a balance batch or a token's metadata couldn't be read: a
        /// token the wallet holds may be missing, which a list must say rather than pass off as everything it holds.
        public let complete: Bool

        public init(tokens: [Token], complete: Bool) {
            self.tokens = tokens
            self.complete = complete
        }
    }

    /// `heldTokens`, saying whether the scan was complete. `logScan` is how the history meets an endpoint that stops
    /// answering (`LogScanMode`): patient, as every other log scan, unless the caller says what it couldn't read and offers
    /// Retry, as the Send sheet and the Portfolio do (`.failFast`).
    public func scan(wallet: Address, windowBlocks: UInt64 = WalletTokenDiscovery.defaultWindowBlocks, known: Set<Address> = [], wholeHistory: Bool = false,
                     logScan: LogScanMode = .patient) async -> Scan {
        guard let anchor = try? await logsRPC.block(.latest) else { return Scan(tokens: [], complete: false) }
        let latest = anchor.number
        let from = wholeHistory ? 0 : (latest > windowBlocks ? latest - windowBlocks : 0)
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        // Every ERC-20 that has sent tokens to this wallet in the window; the emitting contract IS the token.
        let incoming = await logsRPC.chunkedLogsReport(address: nil, topics: [topic, nil, walletWord], fromBlock: from, toBlock: latest, mode: logScan)
        return await held(wallet: wallet, incoming: incoming.logs, complete: incoming.complete, known: known)
    }

    /// The tokens the wallet holds among those that ever sent it a `Transfer` (`incoming`, as the history store keeps
    /// them): balances, ERC-165 and metadata read as `scan` reads them. `complete` is whether the logs cover their window.
    public func held(wallet: Address, incoming: [Log], complete scanned: Bool, known: Set<Address> = []) async -> Scan {
        var complete = scanned

        // The emitting contract of every Transfer into the wallet. A token logs its amount as data (three topics); a few
        // index it (four topics, no data), as an ERC-721 collection indexes its token id: such a sender is a token only
        // when ERC-165 says it isn't a collection, below.
        var candidates: [Address] = []
        var indexedOnly = Set<Address>()
        var seen = Set<Address>()
        for log in incoming where !log.address.isZero && !known.contains(log.address) {
            if Self.isERC20Transfer(log) {
                indexedOnly.remove(log.address)
                if seen.insert(log.address).inserted { candidates.append(log.address) }
            } else if Self.isIndexedTransfer(log), seen.insert(log.address).inserted {
                candidates.append(log.address)
                indexedOnly.insert(log.address)
            }
        }
        guard !candidates.isEmpty else { return Scan(tokens: [], complete: complete) }

        // Keep only currently-held tokens, reading balanceOf in batches so one multicall response stays bounded and a
        // token that breaks its batch costs only itself (`ERC20.balanceReport`). A read that got no answer leaves the scan
        // incomplete; a token whose own balanceOf fails holds nothing a send could move.
        let balances = await ERC20.balanceReport(ofTokens: candidates, owner: wallet, multicall: multicall, batch: 150)
        if !balances.unread.isEmpty { complete = false }
        var held = candidates.filter { (balances.balances[$0] ?? 0) > 0 }
        guard !held.isEmpty else { return Scan(tokens: [], complete: complete) }

        // A four-topic sender is a collection unless ERC-165 says otherwise; when that can't be asked it is left out
        // (never listed as a token it may not be), and the scan says a token may be missing.
        let indexed = held.filter(indexedOnly.contains)
        if !indexed.isEmpty {
            let check = await collectionCheck(indexed)
            if !check.complete { complete = false }
            held.removeAll { indexedOnly.contains($0) && (check.collections.contains($0) || !check.asked.contains($0)) }
        }
        guard !held.isEmpty else { return Scan(tokens: [], complete: complete) }

        let resolved = await Self.metadata(held, multicall: multicall)
        return Scan(tokens: resolved.tokens, complete: complete && resolved.complete)
    }

    /// Symbol, name and decimals for each of `tokens`, 50 tokens a read. A symbol or name may be a string or, as older
    /// tokens have it, a bytes32; decimals default to 18 when unreadable, as `ERC20.metadata` does. A token whose symbol
    /// can't be read in its batch — it has none, it reverts, or a token before it starved it of gas — is read again on
    /// its own, and one whose symbol still can't be read is listed under its short address: the wallet holds it, so it
    /// is never dropped for its metadata. `complete` is false when a read got no answer: its tokens are missing.
    static func metadata(_ tokens: [Address], multicall: Multicall) async -> (tokens: [Token], complete: Bool) {
        var found: [Address: Token] = [:]
        var alone: [Address] = []
        var complete = true
        var index = 0
        while index < tokens.count {
            let batch = Array(tokens[index ..< min(index + 50, tokens.count)])
            index += batch.count
            guard let calls = try? batch.flatMap({ try [ERC20.symbol($0), ERC20.name($0), ERC20.decimals($0)] }) else { alone += batch; continue }
            let results: [Result<[ABIValue], Error>]
            do { results = try await multicall.read(calls) } catch {
                // The node refused the read as a whole (a token's return bomb): each token on its own. No answer: missing.
                if ERC20.isCallError(error) { alone += batch } else { complete = false }
                continue
            }
            for (i, token) in batch.enumerated() {
                let base = 3 * i
                guard let symbol = text(results[base]) else { alone.append(token); continue }
                found[token] = Token(address: token, symbol: symbol, name: text(results[base + 1]) ?? symbol, decimals: decimals(results[base + 2]))
            }
        }
        // Each on its own, all at once, reading the symbol and name as a bytes32 as well as a string.
        await withTaskGroup(of: (token: Address, resolved: Token?).self) { group in
            for token in alone { group.addTask { (token, await resolveAlone(token, multicall: multicall)) } }
            for await (token, resolved) in group {
                if let resolved { found[token] = resolved } else { complete = false }
            }
        }
        return (tokens.compactMap { found[$0] }, complete)
    }

    /// One token's metadata read on its own (`metadata`); nil when the read got no answer.
    private static func resolveAlone(_ token: Address, multicall: Multicall) async -> Token? {
        guard let calls = try? [ERC20.symbol(token), ContractCall(to: token, "symbol()", returns: "bytes32"),
                                ERC20.name(token), ContractCall(to: token, "name()", returns: "bytes32"), ERC20.decimals(token)] else { return unnamed(token, decimals: 18) }
        let results: [Result<[ABIValue], Error>]
        do { results = try await multicall.read(calls) } catch {
            return ERC20.isCallError(error) ? unnamed(token, decimals: 18) : nil
        }
        let name = text(results[2]) ?? text(results[3])
        guard let symbol = text(results[0]) ?? text(results[1]) else { return unnamed(token, name: name, decimals: decimals(results[4])) }
        return Token(address: token, symbol: symbol, name: name ?? symbol, decimals: decimals(results[4]))
    }

    /// A held token with no readable symbol, listed under its short address. With no readable name either, its name is
    /// `Token.unnamedName`, the same in every language: the app stores it (`KnownTokenStore`) and never reads it again,
    /// so a translated name would stay in the language it was found in. Screens show it translated (`displayName`).
    static func unnamed(_ token: Address, name: String? = nil, decimals: Int) -> Token {
        Token(address: token, symbol: token.short, name: name ?? Token.unnamedName, decimals: decimals)
    }

    /// A symbol or name as read: a string, or a bytes32 of UTF-8 text padded with zeros, with something visible in it.
    /// Nil for anything else.
    static func text(_ result: Result<[ABIValue], Error>) -> String? {
        guard case .success(let values) = result, let value = values.first else { return nil }
        let raw: String?
        switch value {
        case .string(let string): raw = string
        case .bytes(let data):
            let text = data.prefix { $0 != 0 }
            raw = data.dropFirst(text.count).allSatisfy { $0 == 0 } ? String(data: Data(text), encoding: .utf8) : nil
        default: raw = nil
        }
        guard let raw, raw.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }) else { return nil }
        return raw
    }

    /// Decimals as read; 18 when unreadable or above 36.
    private static func decimals(_ result: Result<[ABIValue], Error>) -> Int {
        if case .success(let values) = result, let value = values.first?.uintOrNil, value <= 36 { return Int(value) }
        return 18
    }

    /// An ERC-20 `Transfer`: three topics (the signature, `from`, `to`) and the amount as 32 bytes of data. An ERC-721
    /// `Transfer` has the same signature but indexes the token id (four topics, no data), as `SwapHistory` tells them
    /// apart: its contract is a collection, whose `balanceOf` counts editions, not a token a send can move.
    static func isERC20Transfer(_ log: Log) -> Bool { log.topics.count == 3 && log.data.count == 32 }

    /// A `Transfer` with its amount indexed too (four topics, no data): an ERC-721 collection's, or a token's that declares
    /// its amount indexed. Only ERC-165 tells them apart (`collectionCheck`).
    static func isIndexedTransfer(_ log: Log) -> Bool { log.topics.count == 4 && log.data.isEmpty }

    /// ERC-165 ids: ERC-721's, and the one every ERC-165 contract must answer false for.
    static let erc721Interface = Data([0x80, 0xac, 0x58, 0xcd])
    static let invalidInterface = Data([0xff, 0xff, 0xff, 0xff])

    /// Which of `tokens` are NFT collections (ERC-721, by ERC-165), so a list of tokens leaves them out: earlier builds'
    /// discovery stored collections the wallet received as if they were tokens, and a Moment edition is one too. A
    /// collection answers true for ERC-721's id and false for the invalid one; a contract answering true to both answers
    /// everything and proves nothing. MON and the curated tokens are never asked, and a contract that doesn't answer, or
    /// a read that fails, stays a token: a collection left in a list can't be sent (the review's simulation refuses it),
    /// while a real token left out couldn't be sent from the app at all.
    public func collections(among tokens: [Token]) async -> Set<Address> {
        var seen = Set<Address>()
        let candidates = tokens.filter { !$0.isNative && Token.core($0.address) == nil && seen.insert($0.address).inserted }.map(\.address)
        return await collectionCheck(candidates).collections
    }

    /// `collections`' ERC-165 check of `contracts`, 100 a read: which are collections, which were asked (a read that
    /// failed asks none of its contracts), and whether every read answered.
    func collectionCheck(_ contracts: [Address]) async -> (collections: Set<Address>, asked: Set<Address>, complete: Bool) {
        var out = Set<Address>()
        var asked = Set<Address>()
        var complete = true
        var index = 0
        while index < contracts.count {
            let batch = Array(contracts[index ..< min(index + 100, contracts.count)])
            index += batch.count
            guard let calls = try? batch.flatMap({ [try Self.supportsInterface($0, Self.erc721Interface), try Self.supportsInterface($0, Self.invalidInterface)] }),
                  let results = try? await multicall.read(calls), results.count == calls.count else { complete = false; continue }
            asked.formUnion(batch)
            for (i, token) in batch.enumerated() where Self.answersTrue(results[2 * i]) && !Self.answersTrue(results[2 * i + 1]) {
                out.insert(token)
            }
        }
        return (out, asked, complete)
    }

    static func supportsInterface(_ contract: Address, _ id: Data) throws -> ContractCall {
        try ContractCall(to: contract, "supportsInterface(bytes4)", [.bytes(id)], returns: "bool")
    }

    private static func answersTrue(_ result: Result<[ABIValue], Error>) -> Bool {
        if case .success(let values) = result, case .bool(true)? = values.first { return true }
        return false
    }
}
