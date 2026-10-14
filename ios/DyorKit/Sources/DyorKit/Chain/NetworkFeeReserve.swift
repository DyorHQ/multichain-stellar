import BigInt
import Foundation

/// What a "Max" of the native coin keeps back so the transaction can still pay its own network fee (MERA-PLAN §5).
/// A node refuses a transaction unless the balance covers the value plus `gasLimit × maxFeePerGas`, and Monad charges
/// the gas limit, so the reserve is that product at today's fees, with headroom for what can move between the tap and
/// the send. `TransactionSender.maxValue` reads the fees; this is the arithmetic.
public enum NetworkFeeReserve {
    /// Kept on Monad when the fee can't be read: about a routed swap's limit at the usual 2 × 100 gwei base + tip.
    public static let monadFallback = BigUInt(6) * BigUInt(10).power(16) // 0.06 MON

    /// The gas limit budgeted for a swap when there is no route on screen to estimate: a routed swap's estimate plus
    /// the 20% margin comes to about 250–300k on Monad (a wrap is far less).
    public static let swapGasLimit: BigUInt = 300_000

    /// A plain native transfer's limit (21,000 plus the 20% margin), when the recipient isn't known yet.
    public static let transferGasLimit: BigUInt = 25_200

    /// `gasLimit × maxFeePerGas` with headroom. Monad: × 5/4, for a route that shifts a little with the new amount or a
    /// base-fee tick before the send. Elsewhere: × 2, since base fees there move faster (Ethereum's by up to 12.5% a
    /// block), plus a small allowance on the rollups that charge an L1 data fee on top (Base, Optimism, Scroll).
    public static func amount(gasLimit: BigUInt, maxFeePerGas: BigUInt, chainId: Int) -> BigUInt {
        let fee = gasLimit * maxFeePerGas
        if chainId == Monad.chainId { return fee * 5 / 4 }
        return fee * 2 + l1DataFeeAllowance(chainId: chainId)
    }

    /// The reserve when the chain's RPC can't answer. Sized for a transfer, or on Monad a swap, at a busy moment.
    public static func fallback(chainId: Int) -> BigUInt {
        let ten = BigUInt(10)
        switch chainId {
        case Monad.chainId: return monadFallback
        case 1: return 2 * ten.power(15)                     // 0.002 ETH
        case 8453, 10, 42161, 534352: return 5 * ten.power(13) // 0.00005 ETH on Base, Optimism, Arbitrum, Scroll
        case 137: return ten.power(17)                       // 0.1 POL
        case 56: return 5 * ten.power(14)                    // 0.0005 BNB
        case 43114: return 5 * ten.power(15)                 // 0.005 AVAX
        default: return ten.power(16)                        // 0.01 of the native coin (xDAI, BERA, …)
        }
    }

    /// The L1 data fee Base, Optimism and Scroll add to a transaction's cost outside its gas: well under 0.000001 ETH
    /// for a transfer today, so 0.00001 ETH covers an L1 spike. Arbitrum folds it into the gas estimate.
    static func l1DataFeeAllowance(chainId: Int) -> BigUInt {
        [8453, 10, 534352].contains(chainId) ? BigUInt(10).power(13) : 0
    }

    /// `balance − reserve`, or zero when the fee takes the whole balance.
    public static func spendable(balance: BigUInt, reserve: BigUInt) -> BigUInt {
        balance > reserve ? balance - reserve : 0
    }
}
