import BigInt
import Foundation

/// One on-chain movement of a token in or out of a wallet — read from ERC-20 `Transfer` events, no indexer needed.
public struct TokenActivity: Identifiable, Sendable, Hashable {
    public enum Direction: Sendable { case incoming, outgoing }
    public let hash: Data
    public let direction: Direction
    public let counterparty: Address
    public let amount: BigUInt
    public let blockNumber: UInt64
    public let time: Date
    public var id: String { "\(hash.hexString)-\(direction == .incoming ? "in" : "out")" } // not localized: an identifier
}

/// Reads a wallet's recent transfers of a specific token by scanning `Transfer(address,address,uint256)` logs where
/// the wallet is the sender or the recipient. Uses the same windowed `eth_getLogs` approach as the launchpad's own
/// trade history, but scans newest blocks first and stops as soon as it has enough — so an active token (one you
/// just swapped) resolves in a round trip or two rather than sweeping the whole window.
public struct TokenActivityService: Sendable {
    private let rpc: RPCClient
    /// Turns block numbers into the times a movement shows.
    public let clock: BlockClock

    public init(rpc: RPCClient, clock: BlockClock? = nil) {
        self.rpc = rpc
        self.clock = clock ?? BlockClock(rpc: rpc)
    }

    private static let transferSig = "Transfer(address,address,uint256)"

    /// The default "recent" window: a block budget, 54,000 blocks (about 4.5 hours at Monad's pace). Wide enough to
    /// catch a session's trading, narrow enough that a wallet with no activity in it still finishes quickly.
    public static let defaultLookbackBlocks: UInt64 = 54_000

    public func recent(token: Address, wallet: Address, lookbackBlocks: UInt64 = TokenActivityService.defaultLookbackBlocks, limit: Int = 30) async -> [TokenActivity] {
        guard let anchor = try? await rpc.block(.latest) else { return [] }
        let secondsPerBlock = await clock.secondsPerBlock()
        func time(_ block: UInt64) -> Date { BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock) }
        let latest = anchor.number
        let floor = latest > lookbackBlocks ? latest - lookbackBlocks : 0
        // Native MON emits no ERC-20 Transfer events; its swap movements surface as WMON transfers, so scan WMON.
        let scanToken = token.isZero ? Monad.wmon : token
        let topic = ABI.eventTopic(Self.transferSig)
        let walletWord = wallet.data.leftPadded(to: 32)
        let chunk = max(1, rpc.logChunkSize)

        // Chunk the window into [start, end] ranges, newest first.
        var windows: [(UInt64, UInt64)] = []
        var end = latest
        while true {
            let rawStart = end >= chunk ? end - (chunk - 1) : 0
            let start = max(rawStart, floor)
            windows.append((start, end))
            if start <= floor || start == 0 { break }
            end = start - 1
        }

        // Walk the windows newest→oldest, several per round trip, and stop once we have `limit` items. Because we go
        // newest first, the first `limit` collected are the most recent — older windows can't beat them.
        var items: [TokenActivity] = []
        var i = 0
        while i < windows.count, !Task.isCancelled, items.count < limit {
            let group = windows[i ..< min(i + 6, windows.count)]
            i += group.count
            var filters: [LogFilter] = []
            for (start, stop) in group {
                filters.append(LogFilter(address: scanToken, topics: [topic, walletWord, nil], fromBlock: start, toBlock: stop))
                filters.append(LogFilter(address: scanToken, topics: [topic, nil, walletWord], fromBlock: start, toBlock: stop))
            }
            guard let results = try? await rpc.logs(filters) else { continue }
            for (idx, result) in results.enumerated() {
                guard case .success(let logs) = result else { continue }
                let outgoing = idx % 2 == 0 // filters alternate outgoing (sender) / incoming (recipient)
                for log in logs {
                    if outgoing, let to = log.indexedAddress(1) {
                        items.append(TokenActivity(hash: log.transactionHash, direction: .outgoing, counterparty: to, amount: BigUInt(log.data), blockNumber: log.blockNumber, time: time(log.blockNumber)))
                    } else if !outgoing, let sender = log.indexedAddress(0) {
                        items.append(TokenActivity(hash: log.transactionHash, direction: .incoming, counterparty: sender, amount: BigUInt(log.data), blockNumber: log.blockNumber, time: time(log.blockNumber)))
                    }
                }
            }
        }
        // Newest first; a mint/burn shows as a transfer to/from the zero address, which the UI can label.
        return Array(items.sorted { $0.blockNumber > $1.blockNumber }.prefix(limit))
    }
}
