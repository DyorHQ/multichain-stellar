import BigInt
import Foundation

/* The wallet's own launchpad money history, for the cross-app Portfolio: every curve fill it made (with the exact
   fee and tax it paid) and every creator-fee / holder-reward claim. All of it comes from events whose wallet is an
   indexed topic, so each scan is a single filtered `eth_getLogs`. */

/// One curve fill the wallet made. Amounts are raw pair units / token wei; `fee` and `tax` are what left the trade.
public struct WalletCurveFill: Identifiable, Sendable, Hashable {
    public let hash: Data
    public let block: UInt64
    public let logIndex: Int
    public let time: Date
    /// The bonding curve the fill happened on (its token is resolved by the caller from the launch list).
    public let curve: Address
    public let isBuy: Bool
    /// Buys: gross quote paid. Sells: net quote received.
    public let quoteAmount: BigUInt
    public let tokenAmount: BigUInt
    public let fee: BigUInt
    public let tax: BigUInt
    public var id: String { "\(hash.hexString)-\(logIndex)" }

    public init(hash: Data, block: UInt64, logIndex: Int, time: Date, curve: Address, isBuy: Bool, quoteAmount: BigUInt, tokenAmount: BigUInt, fee: BigUInt, tax: BigUInt) {
        self.hash = hash
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.curve = curve
        self.isBuy = isBuy
        self.quoteAmount = quoteAmount
        self.tokenAmount = tokenAmount
        self.fee = fee
        self.tax = tax
    }
}

/// A fee claim the wallet made: creator fees from the escrow (`token == .zero` is native MON) or holder rewards
/// from a fee-sharing coin (`launchToken` set).
public struct WalletFeeClaim: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case creatorFees, holderRewards }
    public let hash: Data
    public let block: UInt64
    public let logIndex: Int
    public let time: Date
    public let kind: Kind
    /// Creator fees: the pair asset claimed (`.zero` = MON). Holder rewards are paid in the launch's pair asset,
    /// which the caller resolves from `launchToken` (this field is `.zero` for them).
    public let token: Address
    /// For holder rewards: the launch coin whose fees were shared.
    public let launchToken: Address?
    public let amount: BigUInt
    public var id: String { "\(hash.hexString)-\(logIndex)" }

    public init(hash: Data, block: UInt64, logIndex: Int, time: Date, kind: Kind, token: Address, launchToken: Address?, amount: BigUInt) {
        self.hash = hash
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.kind = kind
        self.token = token
        self.launchToken = launchToken
        self.amount = amount
    }
}

/// A creator fee an escrow sent straight to the wallet (`Paid` / `PaidToken`). The escrow pushes every fee to its
/// recipient as it is credited — a curve trade, a pool-fee sweep — and books a claimable balance only when that send
/// fails, so most creator fees reach the wallet this way, with no claim. `token == .zero` is native MON.
public struct WalletFeePayment: Identifiable, Sendable, Hashable {
    public let hash: Data
    public let block: UInt64
    public let logIndex: Int
    public let time: Date
    public let token: Address
    public let amount: BigUInt
    public var id: String { "\(hash.hexString)-\(logIndex)" }

    public init(hash: Data, block: UInt64, logIndex: Int, time: Date, token: Address, amount: BigUInt) {
        self.hash = hash
        self.block = block
        self.logIndex = logIndex
        self.time = time
        self.token = token
        self.amount = amount
    }
}

public struct LaunchpadWalletHistory: Sendable, Hashable {
    public let fills: [WalletCurveFill]
    public let claims: [WalletFeeClaim]
    /// Creator fees paid straight to the wallet, newest first.
    public let payments: [WalletFeePayment]
    public init(fills: [WalletCurveFill], claims: [WalletFeeClaim], payments: [WalletFeePayment] = []) {
        self.fills = fills
        self.claims = claims
        self.payments = payments
    }
    public static let empty = LaunchpadWalletHistory(fills: [], claims: [])
}

/// What a wallet has earned in launchpad fees, from the chain: creator fees the escrows paid straight to it, creator fees
/// it claimed from an escrow, and holder rewards it claimed from fee sharing, on every stack (the live one and every
/// retired one). Amounts are raw, per asset: native MON is `.zero`, a token its address. Holder rewards are keyed by the
/// launch coin whose fees were shared and paid in that coin's pair asset, which the caller resolves. What is still
/// claimable is read from the escrows' balances (`escrowReads`), not here.
public struct LaunchpadFeeIncome: Sendable, Hashable {
    /// Creator fees paid straight to the wallet (`Paid`, `PaidToken`).
    public let paid: [Address: BigUInt]
    /// Creator fees claimed from an escrow (`Claimed`, `ClaimedToken`).
    public let claimed: [Address: BigUInt]
    /// Holder rewards claimed (`HolderFeeSharing.Claimed`), by launch coin.
    public let rewardsClaimed: [Address: BigUInt]
    /// Every escrow and fee-sharing contract was read to the head. False: some of the history may be missing, so the
    /// totals are not shown as complete.
    public let complete: Bool

    public init(paid: [Address: BigUInt], claimed: [Address: BigUInt], rewardsClaimed: [Address: BigUInt], complete: Bool) {
        self.paid = paid
        self.claimed = claimed
        self.rewardsClaimed = rewardsClaimed
        self.complete = complete
    }

    /// Creator fees that reached the wallet, per asset: paid straight to it, plus claimed.
    public var creatorFeesReceived: [Address: BigUInt] { paid.merging(claimed, uniquingKeysWith: +) }
}

extension LaunchpadABI.Events {
    static let escrowClaimed = "Claimed(address,uint256)"
    static let escrowClaimedToken = "ClaimedToken(address,address,uint256)"
    static let escrowPaid = "Paid(address,uint256)"
    static let escrowPaidToken = "PaidToken(address,address,uint256)"
    static let sharingClaimed = "Claimed(address,address,uint256)"
    static let escrowClaimedTopic = ABI.eventTopic(escrowClaimed)
    static let escrowClaimedTokenTopic = ABI.eventTopic(escrowClaimedToken)
    static let escrowPaidTopic = ABI.eventTopic(escrowPaid)
    static let escrowPaidTokenTopic = ABI.eventTopic(escrowPaidToken)
    static let sharingClaimedTopic = ABI.eventTopic(sharingClaimed)
}

public extension LaunchpadAddresses {
    /// The block the first launchpad's escrow was deployed in (0xad3d's, 103,542,521; the other stacks' came later):
    /// no DyorHQ escrow or fee sharing emitted anything before it, so a wallet's fee history is read from here.
    static let feeHistoryStart: UInt64 = 103_542_521
}

public extension LaunchpadService {
    /// The wallet's curve fills and fee claims over the last `lookbackBlocks` blocks, newest first. Fills are
    /// matched to `curves` (curve → token) so only these factories' launches count; claims are read from the escrow
    /// and fee-sharing contracts of the live stack (once deployed) and of every retired one. The scans read newest first
    /// and don't say what they couldn't read (`RPCClient.chunkedLogs`): no screen shows this — the app's screens build the
    /// wallet's fills and fees from its history store (`WalletHistoryService`), which says how far it has read.
    func walletHistory(wallet: Address, lookbackBlocks: UInt64, curves: Set<Address>) async -> LaunchpadWalletHistory {
        guard !stacks.isEmpty, let anchor = try? await logsRPC.block(.latest) else { return .empty }
        let secondsPerBlock = await clock.secondsPerBlock()
        let from = anchor.number > lookbackBlocks ? anchor.number - lookbackBlocks : 0
        let word = wallet.data.leftPadded(to: 32)
        let escrows = Self.unique(stacks.map(\.escrow))
        let sharings = Self.unique(stacks.map(\.holderFeeSharing))
        // CurveBuy/CurveSell index the trader first; the escrow indexes the recipient; fee sharing indexes (token, account).
        async let buys = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.buyTopic, word], fromBlock: from, toBlock: anchor.number)
        async let sells = logsRPC.chunkedLogs(address: nil, topics: [LaunchpadABI.Events.sellTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowNative = logs(from: escrows, topics: [LaunchpadABI.Events.escrowClaimedTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowToken = logs(from: escrows, topics: [LaunchpadABI.Events.escrowClaimedTokenTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowPaid = logs(from: escrows, topics: [LaunchpadABI.Events.escrowPaidTopic, word], fromBlock: from, toBlock: anchor.number)
        async let escrowPaidToken = logs(from: escrows, topics: [LaunchpadABI.Events.escrowPaidTokenTopic, word], fromBlock: from, toBlock: anchor.number)
        async let sharing = logs(from: sharings, topics: [LaunchpadABI.Events.sharingClaimedTopic, nil, word], fromBlock: from, toBlock: anchor.number)
        let (buyLogs, sellLogs, escrowNativeLogs, escrowTokenLogs, sharingLogs) = await (buys, sells, escrowNative, escrowToken, sharing)
        let (paidLogs, paidTokenLogs) = await (escrowPaid, escrowPaidToken)
        return Self.walletHistory(buys: buyLogs, sells: sellLogs, escrowNative: escrowNativeLogs, escrowToken: escrowTokenLogs, sharing: sharingLogs,
                                  paid: paidLogs, paidToken: paidTokenLogs, anchor: anchor, secondsPerBlock: secondsPerBlock, curves: curves)
    }

    /// Everything the wallet has received in launchpad fees, from the first escrow's deployment to the head
    /// (`LaunchpadFeeIncome`). One wallet-filtered read per contract: every event an escrow emits names its recipient
    /// first, so a single scan per escrow finds the fees it paid the wallet and those the wallet claimed. Each reads newest
    /// first, and one that stops short (the window is wider than a scan's budget) makes `complete` false. The app reads the
    /// wallet's fees from its history store (`WalletHistoryService`), not from here.
    func feeIncome(wallet: Address) async -> LaunchpadFeeIncome {
        guard !stacks.isEmpty, let head = try? await logsRPC.blockNumber() else {
            return LaunchpadFeeIncome(paid: [:], claimed: [:], rewardsClaimed: [:], complete: false)
        }
        let from = LaunchpadAddresses.feeHistoryStart
        let word = wallet.data.leftPadded(to: 32)
        let rpc = logsRPC
        let escrows = Self.unique(stacks.map(\.escrow))
        let sharings = Self.unique(stacks.map(\.holderFeeSharing))
        let reads = await withTaskGroup(of: (escrow: Bool, logs: [Log], complete: Bool).self) { group in
            for escrow in escrows {
                group.addTask {
                    let report = await rpc.chunkedLogsReport(address: escrow, topics: [nil, word], fromBlock: from, toBlock: head, order: .descending)
                    return (true, report.logs, report.complete)
                }
            }
            for sharing in sharings {
                group.addTask {
                    let report = await rpc.chunkedLogsReport(address: sharing, topics: [LaunchpadABI.Events.sharingClaimedTopic, nil, word], fromBlock: from, toBlock: head, order: .descending)
                    return (false, report.logs, report.complete)
                }
            }
            var out: [(escrow: Bool, logs: [Log], complete: Bool)] = []
            for await read in group { out.append(read) }
            return out
        }
        let income = Self.feeIncome(escrowLogs: reads.filter(\.escrow).flatMap(\.logs), sharingLogs: reads.filter { !$0.escrow }.flatMap(\.logs))
        let complete = reads.count == escrows.count + sharings.count && reads.allSatisfy(\.complete) && !Task.isCancelled
        return LaunchpadFeeIncome(paid: income.paid, claimed: income.claimed, rewardsClaimed: income.rewardsClaimed, complete: complete)
    }

    /// Pure half of `feeIncome`: the escrow logs naming the wallet as their recipient (any event) and the fee-sharing
    /// `Claimed` logs naming it as the account, summed per asset. A log read twice counts once; an escrow log that is not
    /// a payment or a claim (`Credited`: booked as claimable, which the balance read shows) counts nowhere.
    nonisolated static func feeIncome(escrowLogs: [Log], sharingLogs: [Log]) -> LaunchpadFeeIncome {
        var paid: [Address: BigUInt] = [:], claimed: [Address: BigUInt] = [:], rewards: [Address: BigUInt] = [:]
        var seen = Set<String>()
        func fresh(_ log: Log) -> Bool { seen.insert("\(log.address.hex)-\(log.transactionHash.hexString)-\(log.logIndex)").inserted }
        for log in escrowLogs {
            guard let topic = log.topics.first, let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            switch topic {
            case LaunchpadABI.Events.escrowPaidTopic where log.topics.count == 2:
                if fresh(log) { paid[.zero, default: 0] += words[0].uint }
            case LaunchpadABI.Events.escrowPaidTokenTopic where log.topics.count == 3:
                if let token = log.indexedAddress(1), fresh(log) { paid[token, default: 0] += words[0].uint }
            case LaunchpadABI.Events.escrowClaimedTopic where log.topics.count == 2:
                if fresh(log) { claimed[.zero, default: 0] += words[0].uint }
            case LaunchpadABI.Events.escrowClaimedTokenTopic where log.topics.count == 3:
                if let token = log.indexedAddress(1), fresh(log) { claimed[token, default: 0] += words[0].uint }
            default:
                continue
            }
        }
        for log in sharingLogs where log.topics.first == LaunchpadABI.Events.sharingClaimedTopic && log.topics.count == 3 {
            // `Claimed(address indexed token, address indexed account, uint256 amount)`: `token` is the launch coin.
            guard let launchToken = log.indexedAddress(0), let words = try? ABI.decode(log.data, "uint256"), words.count == 1, fresh(log) else { continue }
            rewards[launchToken, default: 0] += words[0].uint
        }
        return LaunchpadFeeIncome(paid: paid, claimed: claimed, rewardsClaimed: rewards, complete: true)
    }

    /// `chunkedLogs` over each of `contracts`, merged.
    private func logs(from contracts: [Address], topics: [Data?], fromBlock: UInt64, toBlock: UInt64) async -> [Log] {
        let rpc = logsRPC
        return await withTaskGroup(of: [Log].self) { group in
            for contract in contracts { group.addTask { await rpc.chunkedLogs(address: contract, topics: topics, fromBlock: fromBlock, toBlock: toBlock) } }
            var out: [Log] = []
            for await logs in group { out += logs }
            return out
        }
    }

    /// The non-zero addresses of `list`, first occurrence kept.
    private nonisolated static func unique(_ list: [Address]) -> [Address] {
        var seen = Set<Address>()
        return list.filter { !$0.isZero && seen.insert($0).inserted }
    }

    /// Pure half of `walletHistory`, each row's time its block's own when the log carries it (`Log.blockTimestamp`), else
    /// estimated from `anchor` at `secondsPerBlock`.
    nonisolated static func walletHistory(buys: [Log], sells: [Log], escrowNative: [Log], escrowToken: [Log], sharing: [Log], paid: [Log] = [], paidToken: [Log] = [],
                                          anchor: BlockHeader, secondsPerBlock: Double, curves: Set<Address>) -> LaunchpadWalletHistory {
        func when(_ log: Log) -> Date {
            if let timestamp = log.blockTimestamp { return Date(timeIntervalSince1970: TimeInterval(timestamp)) }
            return Date(timeIntervalSince1970: TimeInterval(time(anchor: anchor, block: log.blockNumber, secondsPerBlock: secondsPerBlock)))
        }
        var fills: [WalletCurveFill] = []
        for log in buys where curves.contains(log.address) {
            guard let fill = LaunchpadABI.fill(log) else { continue }
            fills.append(WalletCurveFill(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), curve: log.address, isBuy: true, quoteAmount: fill.amountIn, tokenAmount: fill.amountOut, fee: fill.fee, tax: fill.tax))
        }
        for log in sells where curves.contains(log.address) {
            guard let fill = LaunchpadABI.fill(log) else { continue }
            fills.append(WalletCurveFill(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), curve: log.address, isBuy: false, quoteAmount: fill.amountOut, tokenAmount: fill.amountIn, fee: fill.fee, tax: fill.tax))
        }
        var claims: [WalletFeeClaim] = []
        for log in escrowNative {
            guard log.topics.count == 2, let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .creatorFees, token: .zero, launchToken: nil, amount: words[0].uint))
        }
        for log in escrowToken {
            guard log.topics.count == 3, let token = log.indexedAddress(1), let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .creatorFees, token: token, launchToken: nil, amount: words[0].uint))
        }
        for log in sharing {
            // `Claimed(address indexed token, address indexed account, uint256 amount)`: `token` is the launch coin; the reward is paid in its pair asset.
            guard log.topics.count == 3, let launchToken = log.indexedAddress(0), let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            claims.append(WalletFeeClaim(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), kind: .holderRewards, token: .zero, launchToken: launchToken, amount: words[0].uint))
        }
        var payments: [WalletFeePayment] = []
        for log in paid {
            guard log.topics.count == 2, let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            payments.append(WalletFeePayment(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), token: .zero, amount: words[0].uint))
        }
        for log in paidToken {
            guard log.topics.count == 3, let token = log.indexedAddress(1), let words = try? ABI.decode(log.data, "uint256"), words.count == 1 else { continue }
            payments.append(WalletFeePayment(hash: log.transactionHash, block: log.blockNumber, logIndex: log.logIndex, time: when(log), token: token, amount: words[0].uint))
        }
        return LaunchpadWalletHistory(
            fills: fills.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block },
            claims: claims.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block },
            payments: payments.sorted { a, b in a.block == b.block ? a.logIndex > b.logIndex : a.block > b.block }
        )
    }
}
