import BigInt
import Foundation

/// The most network fee a transaction may commit to, whatever wallet signs it (security audit 2026-09-26, IOST-1).
/// The gas limit, the base fee and the tip all come from the RPC, and Monad bills the gas LIMIT, so a buggy or hostile
/// node could otherwise have even a plain transfer commit the balance to gas. `TransactionSender.prepare` refuses —
/// never clamps — a transaction outside these bounds, for the Privy wallet, an imported key and a passkey account
/// alike; a passkey account's `Mera.SigningPolicy.refusal` applies the same Monad bounds again before it signs.
///
/// Every chain: a gas limit under `maxGasLimit`, a tip no higher than the max fee, and `gasLimit × maxFeePerGas` (the
/// most the network can charge) under `maxNetworkFee`. Monad, where the fee market is known, also bounds the fee per
/// gas: under `maxFeePerGas`, and when the base fee is known, a tip no higher than twice it or `tipFloor`, whichever is
/// more (today's suggestion is 2% of the base fee; twice leaves room for congestion), and a max fee no higher than the
/// `2 × base + tip` the app sets. Other chains (the Bridge's source side) are bounded by their total alone, since tips
/// there routinely exceed the base fee.
public enum NetworkFeeLimits {
    public struct Limits: Sendable, Equatable {
        public let maxGasLimit: BigUInt
        /// The most `gasLimit × maxFeePerGas` may come to, in the chain's native coin (wei).
        public let maxNetworkFee: BigUInt
        /// The highest max fee per gas; nil where only the total is bounded.
        public let maxFeePerGas: BigUInt?
    }

    public enum Violation: Sendable, Equatable {
        /// A gas limit over the per-transaction ceiling.
        case gasLimit
        /// A max fee per gas over the chain's ceiling, or above `2 × base + tip`.
        case feePerGas
        /// A tip above the max fee, or (Monad) above twice the base fee.
        case tip
        /// `gasLimit × maxFeePerGas` over the chain's ceiling.
        case total
    }

    private static let ether = BigUInt(10).power(18)
    private static let gwei = BigUInt(10).power(9)

    /// Monad: 5 MON in all, a 15M gas limit (half Monad's per-transaction limit, over twice the largest the app sends)
    /// and 10,000 gwei per gas (today's base fee is 100 gwei). A normal swap commits about 0.07 MON; the largest
    /// transaction the app sends, a launch with its first buy (~6.2M gas limit), about 1.3 MON.
    public static let monad = Limits(maxGasLimit: 15_000_000, maxNetworkFee: 5 * ether, maxFeePerGas: 10_000 * gwei)
    /// The tip Monad always allows, whatever the base fee: twice the base fee bounds it only above this.
    static let tipFloor = 10 * gwei

    /// The bounds for `chainId`. The source chains only ever carry a Bridge deposit (a transfer), so their totals sit
    /// far above a busy day's transfer fee and far below a balance-draining one.
    public static func limits(chainId: Int) -> Limits {
        let total: BigUInt
        switch chainId {
        case Monad.chainId: return monad
        case 1: total = 5 * ether / 100                        // 0.05 ETH
        case 8453, 10, 42161, 534352: total = ether / 100      // 0.01 ETH on Base, Optimism, Arbitrum, Scroll
        case 137: total = 20 * ether                           // 20 POL
        case 56: total = 5 * ether / 100                       // 0.05 BNB
        case 43114: total = ether / 2                          // 0.5 AVAX
        default: total = ether / 20                            // 0.05 of the native coin (xDAI, BERA, …)
        }
        // A sanity bound only: rollups fold the L1 data cost into the estimate, so their limits run high.
        return Limits(maxGasLimit: 30_000_000, maxNetworkFee: total, maxFeePerGas: nil)
    }

    /// Nil when the fee is within bounds for `chainId`. `baseFee` is the latest block's, when the node gave one.
    public static func violation(gasLimit: BigUInt, maxFeePerGas: BigUInt, maxPriorityFeePerGas: BigUInt, baseFee: BigUInt?, chainId: Int) -> Violation? {
        let limits = limits(chainId: chainId)
        if gasLimit > limits.maxGasLimit { return .gasLimit }
        if maxPriorityFeePerGas > maxFeePerGas { return .tip }
        if let ceiling = limits.maxFeePerGas, maxFeePerGas > ceiling { return .feePerGas }
        if chainId == Monad.chainId, let baseFee {
            // Never below `tipFloor`: a base fee that decays toward zero (a local fork's empty blocks) must not make an
            // ordinary 1–2 gwei tip read as hostile. The per-gas ceiling and the total still bound it.
            if maxPriorityFeePerGas > max(baseFee * 2, tipFloor) { return .tip }
            if maxFeePerGas > baseFee * 2 + maxPriorityFeePerGas { return .feePerGas }
        }
        if gasLimit * maxFeePerGas > limits.maxNetworkFee { return .total }
        return nil
    }

    /// The refusal a prepared transaction outside the bounds gets. Nothing is signed.
    static func refusal(_ violation: Violation, gasLimit: BigUInt, maxFeePerGas: BigUInt, chainId: Int) -> String {
        let symbol = nativeSymbol(chainId: chainId)
        let fee = "\(NumberStyle.units(gasLimit * maxFeePerGas, decimals: 18)) \(symbol)"
        switch violation {
        case .gasLimit, .total:
            return L10n.tr("The network asked for an unusually high fee (up to \(fee)), so nothing was signed. Try again in a moment.")
        case .feePerGas, .tip:
            return L10n.tr("The network quoted an unusual gas price, so nothing was signed. Try again in a moment.")
        }
    }

    public static func nativeSymbol(chainId: Int) -> String {
        EVMChain.supported.first { $0.chainId == chainId }?.nativeSymbol ?? "ETH"
    }
}
